import AppKit
import Observation
import SwiftUI

@MainActor
final class SentinelApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: SentinelStatusBarController?
    /// `didFinishLaunching` 时 `currentAppleEvent` 往往已经空了，必须更早截住。
    private var launchAppleEvent: LaunchAppleEventSummary?

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchAppleEvent = LaunchAppleEventSummary.fromCurrentAppleEvent()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = SentinelStatusBarController(store: SentinelStore())
        statusBarController = controller
        controller.start()
        let signals = LaunchdSupervisionProbe.collectFromCurrentProcess().signals
        if PanelOpenPolicy.shouldPresentOnColdLaunch(
            signals: signals,
            automaticallyLaunched: LaunchAppleEventSummary.isAutomaticLaunch(launchAppleEvent)
        ) {
            controller.presentPanel()
        }
    }

    /// 已经在跑时，用户从「应用程序」再点一次图标：系统只发 reopen，不走冷启动。
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusBarController?.presentPanel()
        return false
    }
}

@MainActor
final class SentinelStatusBarController: NSObject, NSPopoverDelegate {
    private let store: SentinelStore
    private let popover: NSPopover
    private var statusItem: NSStatusItem?
    private var statusObservationActive = false
    private var outsideClickMonitor: Any?
    private var openSettingsObserver: NSObjectProtocol?

    init(store: SentinelStore) {
        self.store = store
        popover = NSPopover()
        super.init()
    }

    deinit {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let openSettingsObserver {
            DistributedNotificationCenter.default().removeObserver(openSettingsObserver)
        }
    }

    func start() {
        guard statusItem == nil else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        statusItem = item
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.contentSize = NSSize(
            width: SentinelTheme.Metrics.menuWidth,
            height: SentinelTheme.Metrics.menuHeight
        )
        let hosting = NSHostingController(
            rootView: SentinelMenuView(store: store)
        )
        // 面板尺寸由 SentinelMenuView 的固定 frame 钉死。不给 sizingOptions 留任何
        // 选项，NSHostingView 就不会在每次内容失效后再跑 minSize → sizeThatFits
        // 那一整套约束重算——基线 Time Profiler 里 hang 窗口的大头就是这条链
        // （updateConstraints → minSize → 整图再求值 + NSISEngine）。
        hosting.sizingOptions = []
        popover.contentViewController = hosting

        statusObservationActive = true
        observeStatusItemInputs()

        updateStatusItem()
        openSettingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: SentinelRuntimeNotification.openSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.store.openSettings()
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else {
                    return
                }
                self.popover.performClose(nil)
            }
        }
        store.scrollPublishGate.installLocalScrollWheelMonitor()
        store.start()
    }

    /// 状态栏那张图只观察 `statusBarRenderState` 这一份合成快照（Input / 余额 / 打包）。
    /// 旧实现是 Combine 订三个 @Published；@Observable 迁过来之后，Optional 的
    /// packagingProgress 从 nil 跳到 running 在隐藏宿主里不可靠，所以改成非 Optional 结构体。
    private func observeStatusItemInputs() {
        guard statusObservationActive else {
            return
        }
        withObservationTracking { [weak self] in
            guard let self else {
                return
            }
            _ = self.store.statusBarRenderState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.updateStatusItem()
                self.observeStatusItemInputs()
            }
        }
    }

    /// 把菜单栏那块面板弹出来。已打开则不动，避免 reopen 把面板关掉。
    func presentPanel() {
        guard let button = statusItem?.button else {
            return
        }
        if popover.isShown {
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    private func updateStatusItem() {
        guard let statusItem, let button = statusItem.button else {
            return
        }

        let paint = store.statusBarRenderState
        let image = SentinelStatusBarRenderer.image(
            probes: paint.inputStatus.displayProbes(),
            balances: paint.aio.statusBarBalances,
            packaging: paint.packagingProgress
        )
        statusItem.length = image.size.width
        button.image = image
        button.toolTip = store.statusBarTooltip
        button.setAccessibilityLabel(
            store.statusBarAccessibilityLabel.isEmpty
                ? "Cortex 哨兵"
                : store.statusBarAccessibilityLabel
        )
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        popover.show(
            relativeTo: sender.bounds,
            of: sender,
            preferredEdge: .minY
        )
    }

    func popoverWillShow(_ notification: Notification) {
        Task { await store.setPanelPresented(true) }
    }

    func popoverDidClose(_ notification: Notification) {
        Task { await store.setPanelPresented(false) }
    }
}
