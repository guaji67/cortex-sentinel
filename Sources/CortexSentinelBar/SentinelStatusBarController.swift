import AppKit
import Combine
import SwiftUI

@MainActor
final class SentinelApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: SentinelStatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = SentinelStatusBarController(store: SentinelStore())
        statusBarController = controller
        controller.start()
    }
}

@MainActor
final class SentinelStatusBarController: NSObject, NSPopoverDelegate {
    private let store: SentinelStore
    private let popover: NSPopover
    private var statusItem: NSStatusItem?
    private var statusObservation: AnyCancellable?
    private var outsideClickMonitor: Any?

    init(store: SentinelStore) {
        self.store = store
        popover = NSPopover()
        super.init()
    }

    deinit {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
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
        popover.contentViewController = NSHostingController(
            rootView: SentinelMenuView(store: store)
        )

        statusObservation = store.$inputStatus
            .combineLatest(store.$aio)
            .sink { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateStatusItem()
                }
            }

        updateStatusItem()
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
        store.start()
    }

    private func updateStatusItem() {
        guard let statusItem, let button = statusItem.button else {
            return
        }

        let image = SentinelStatusBarRenderer.image(
            probes: store.inputStatus.displayProbes(),
            balances: store.statusBarBalances
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
        store.setPanelPresented(true)
    }

    func popoverDidClose(_ notification: Notification) {
        store.setPanelPresented(false)
    }
}
