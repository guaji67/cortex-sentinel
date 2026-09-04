import AppKit
import SwiftUI

enum SentinelRuntimeNotification {
    static let openSettings = Notification.Name("com.falcon.cortex.sentinelbar.openSettings")
}

@main
enum CortexSentinelBarMain {
    static let smokeWindowArgument = "--smoke-window"
    static let smokePopoverArgument = "--smoke-popover"
    static let smokeLinesArgument = "--smoke-lines"
    static let smokeExpandArgument = "--smoke-expand"
    static let cleanupDryRunArgument = "--cleanup-dry-run"
    static let cleanupRunArgument = "--cleanup-run"
    static let renderStatusBarArgument = "--render-statusbar"
    static let renderSettingsPNGArgument = "--render-settings-png"
    static let settingsFixtureArgument = "--settings-fixture"
    static let renderPanelPNGArgument = "--render-panel-png"
    static let panelFixtureArgument = "--panel-fixture"
    /// 配合 --render-panel-png：注入一套中性演示余额再出图（README 用）。
    static let demoBalancesArgument = "--demo-balances"
    static let dumpStateArgument = "--dump-state"
    static let idleRefreshArgument = "--idle-refresh"
    static let smokeSettingsArgument = "--smoke-settings"
    static let openSettingsArgument = "--open-settings"
    /// 真实 store + 真实本机环境离屏出一张面板 PNG（等余额/额度回来再渲染）。
    /// 与 --render-panel-png 的 fixture 隔离环境相对，用于改动后的真机验收。
    static let renderLivePanelPNGArgument = "--render-live-panel-png"
    static let livePanelSettleSecondsArgument = "--settle-seconds"

    @MainActor
    static func main() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(dumpStateArgument) {
            runDumpStateCLI()
            return
        }
        if arguments.contains(idleRefreshArgument) {
            await runIdleRefreshCLI()
            return
        }
        if arguments.contains(openSettingsArgument) {
            runOpenSettingsCLI()
            return
        }
        if arguments.contains(cleanupDryRunArgument) || arguments.contains(cleanupRunArgument) {
            runCleanupCLI(dryRun: arguments.contains(cleanupDryRunArgument))
            return
        }
        if let index = arguments.firstIndex(of: renderStatusBarArgument),
           index + 1 < arguments.count {
            StatusBarSnapshotter.render(to: arguments[index + 1])
            return
        }
        if let index = arguments.firstIndex(of: renderSettingsPNGArgument),
           index + 1 < arguments.count {
            runRenderSettingsPNGCLI(
                outputPath: arguments[index + 1],
                arguments: arguments
            )
            return
        }
        if let index = arguments.firstIndex(of: renderPanelPNGArgument),
           index + 1 < arguments.count {
            await runRenderPanelPNGCLI(
                outputPath: arguments[index + 1],
                arguments: arguments
            )
            return
        }
        if let index = arguments.firstIndex(of: renderLivePanelPNGArgument),
           index + 1 < arguments.count {
            await runRenderLivePanelPNGCLI(
                outputPath: arguments[index + 1],
                arguments: arguments
            )
            return
        }
        if arguments.contains(smokePopoverArgument) {
            runSmokePopoverApplication()
        } else if arguments.contains(smokeWindowArgument) {
            CortexSentinelSmokeApp.main()
        } else {
            guard SentinelSingletonGuard.enforce() else {
                return
            }
            runMenuBarApplication()
        }
    }

    @MainActor
    private static func runMenuBarApplication() {
        let application = NSApplication.shared
        let delegate = SentinelApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    @MainActor
    private static func runSmokePopoverApplication() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let controller = SentinelSmokePopoverController(store: SentinelStore())
        controller.start()
        application.run()
        withExtendedLifetime(controller) {}
    }

    /// 通知已经在跑的那一份打开设置窗，自己马上退出，避免再拉起第二个实例。
    private static func runOpenSettingsCLI() {
        DistributedNotificationCenter.default().postNotificationName(
            SentinelRuntimeNotification.openSettings,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    @MainActor
    private static func runRenderSettingsPNGCLI(outputPath: String, arguments: [String]) {
        let fixture: SettingsPreviewFixture
        if let index = arguments.firstIndex(of: settingsFixtureArgument),
           index + 1 < arguments.count,
           let parsed = SettingsPreviewFixture(rawValue: arguments[index + 1]) {
            fixture = parsed
        } else {
            fixture = .default
        }
        do {
            try SettingsPNGRenderer.render(fixture: fixture, to: outputPath)
            print("written \(outputPath)")
        } catch {
            FileHandle.standardError.write(Data("设置窗离屏渲染失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// 无界面空转：连续刷 refreshStatuses，给 `sample` 采热栈。
    /// 不启 NSApplication、不申请通知权限、不碰登录项。
    /// 产品定时器仍按设置走；这里只把「每一轮」压到前台，方便对着数栈帧。
    @MainActor
    private static func runIdleRefreshCLI() async {
        let store = SentinelStore()
        FileHandle.standardOutput.write(
            Data("idle-refresh pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        )
        await store.refreshStatuses()
        while true {
            await store.refreshStatuses()
        }
    }

    @MainActor
    private static func runRenderPanelPNGCLI(outputPath: String, arguments: [String]) async {
        let fixture: PanelPreviewFixture
        if let index = arguments.firstIndex(of: panelFixtureArgument),
           index + 1 < arguments.count {
            let name = arguments[index + 1]
            guard let parsed = PanelPreviewFixture(rawValue: name) else {
                let allowed = PanelPreviewFixture.allCases.map(\.rawValue).joined(separator: ", ")
                FileHandle.standardError.write(
                    Data("未知 --panel-fixture：\(name)。可选：\(allowed)\n".utf8)
                )
                exit(1)
            }
            fixture = parsed
        } else {
            fixture = .idle
        }
        do {
            try await PanelPNGRenderer.render(
                fixture: fixture,
                to: outputPath,
                demoBalances: arguments.contains(demoBalancesArgument)
            )
            print("written \(outputPath)")
        } catch {
            FileHandle.standardError.write(Data("面板离屏渲染失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// 真实环境的面板离屏验收：默认 SentinelStore（真实监视目录、真实 key 识别、
    /// 真实余额/额度链路），start 后等 settleSeconds 让数据回来，再按
    /// --render-panel-png 同款方式出一张 PNG。改面板后的真机检验用它，不用再抠屏幕截图。
    @MainActor
    private static func runRenderLivePanelPNGCLI(outputPath: String, arguments: [String]) async {
        let settleSeconds: TimeInterval
        if let index = arguments.firstIndex(of: livePanelSettleSecondsArgument),
           index + 1 < arguments.count,
           let parsed = TimeInterval(arguments[index + 1]), parsed > 0 {
            settleSeconds = parsed
        } else {
            settleSeconds = 10
        }
        let store = SentinelStore()
        store.start()
        try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
        let url = URL(fileURLWithPath: outputPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let view = SentinelMenuView(store: store, rendersOffscreen: true)
                .frame(width: SentinelTheme.Metrics.menuWidth)
                .fixedSize(horizontal: true, vertical: true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(
                width: SentinelTheme.Metrics.menuWidth,
                height: nil
            )
            guard let nsImage = renderer.nsImage,
                  let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]),
                  !png.isEmpty
            else {
                throw PanelPNGRenderError.emptyImage
            }
            try png.write(to: url)
            print("written \(outputPath)")
        } catch {
            FileHandle.standardError.write(Data("真实面板离屏渲染失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    /// 自检 CLI：把哨兵此刻从磁盘读到的东西原样打印出来。
    /// 「面板显示的跟实际不一样」不用再靠猜或截图——跑一次就知道是读不到文件、
    /// 解不出内容，还是读到了但分组/显示写错了。
    private static func runDumpStateCLI() {
        let paths = SentinelPaths.discover()
        let registryURL = paths.lineRegistryURL
        let registryExists = FileManager.default.fileExists(atPath: registryURL.path)
        let readStarted = Date()
        let registry = CodexLineRegistryReader.read(at: registryURL)
        let lines = SentinelFileReader.readLines(in: paths.logsDirectory)
        let readMilliseconds = Date().timeIntervalSince(readStarted) * 1_000
        let groups = SentinelAggregation.lineGroups(lines: lines, registry: registry)
        let board = SentinelBoardWindow.snapshot(groups: groups)

        print("监视目录：\(paths.logsDirectory.path)")
        let resolvedLogsDirectory = paths.logsDirectory.resolvingSymlinksInPath().path
        if resolvedLogsDirectory != paths.logsDirectory.path {
            print("监视目录实际路径：\(resolvedLogsDirectory)")
        }
        if let reason = paths.selfHealingReason {
            print("自愈原因：\(reason)")
        }
        if !paths.logsDirectoryExists {
            print(paths.missingWatchDirectoryMessage)
        }
        print("仓库根：\(paths.repositoryRoot.path)")
        let channelStatus = SentinelFileReader.readChannelStatus(at: paths.channelStatusURL)
        let localHost = LocalHostIdentity.current()
        let liveChannelCounts = groups.localActiveEngineCounts(localHost: localHost)
        let originCounts = groups.activeHostOriginCounts(localHost: localHost)
        print("本机身份：\(localHost.dumpText)")
        print("通道：\(paths.channelStatusURL.path)")
        print(
            "  Grok \(channelStatus.grok.statusText) · 文件running=\(channelStatus.grok.running.map(String.init) ?? "无") · 面板条数(本机)=\(liveChannelCounts.grok) · \(channelStatus.grok.evidence)"
        )
        print(
            "  Codex \(channelStatus.codex.statusText) · 文件running=\(channelStatus.codex.running.map(String.init) ?? "无") · 面板条数(本机)=\(liveChannelCounts.codex) · \(channelStatus.codex.evidence)"
        )
        print(
            "  ox-alpha \(channelStatus.claudeOxAlpha.statusText) · 文件running=\(channelStatus.claudeOxAlpha.running.map(String.init) ?? "无") · 面板条数(本机)=\(liveChannelCounts.claudeOxAlpha) · \(channelStatus.claudeOxAlpha.evidence)"
        )
        print(
            "  活跃口径：本机 \(originCounts.local) · 外机 \(originCounts.remote) · 机器未知 \(originCounts.unknown)（通道行和标题只数本机）"
        )
        let backgroundJobs = BackgroundJobsReader.read(at: paths.backgroundJobsHealthURL)
        let backgroundPresentation = BackgroundJobsPresentation(snapshot: backgroundJobs)
        print("后台任务：\(paths.backgroundJobsHealthURL.path)")
        print("  \(backgroundPresentation.summaryText)")
        for row in backgroundPresentation.problemRows {
            print("    - \(row.name) · \(row.detail)")
        }
        for job in backgroundJobs.jobs {
            print("    · \(job.name) [\(job.statusText)] \(job.intervalText) 上次跑：\(job.lastRunText)")
        }
        let ack = SentinelFileReader.readTerminalAck(at: paths.lineTerminalAckURL)
        let unclaimed = UnclaimedTerminalAggregation.entries(lines: lines, registry: registry, ack: ack)
        print("未认领终态：\(unclaimed.count) 条")
        for item in unclaimed {
            let dispatcher = item.dispatcherZH.isEmpty ? "未登记" : item.dispatcherZH
            print("    - \(item.slug)=\(item.state)（\(dispatcher)）")
        }
        print("登记表：\(registryURL.path)")
        print("  文件存在：\(registryExists ? "是" : "否")")
        print("  解出条数：\(registry.lines.count)")
        if registryExists && registry.lines.isEmpty {
            print("  ⚠️ 文件在但一条都没解出来 —— 多半是格式对不上，看 LineRegistry.swift")
        }
        print("状态文件：读到 \(lines.count) 条线")
        let localActiveCounts = groups.localActiveEngineCounts(localHost: localHost)
        print(
            "  活跃按引擎（本机）：Codex=\(localActiveCounts.codex) Grok=\(localActiveCounts.grok) ox-alpha=\(localActiveCounts.claudeOxAlpha) 其它=\(localActiveCounts.unknown)"
        )
        if let packaging = PackagingProgressReader.read(at: paths.packagingProgressRoot) {
            print("打包进度：\(packaging.status.displayName) · \(packaging.stepTitle) · \(packaging.etaText)")
        } else {
            print("打包进度：无")
        }
        print(String(format: "读取耗时：%.1f ms", readMilliseconds))
        print("分组结果：")
        print("  已登记派工（活跃）：\(groups.activeRegistered.count)")
        for item in groups.activeRegistered {
            print("    - \(item.line.slug) → \(item.registration?.labelZH ?? "（无中文名）") [\(item.engine.displayName) · \(item.line.state.displayName) · \(item.hostOrigin(localHost: localHost).badgeText)]")
        }
        print("  自动识别（未登记且活跃）：\(groups.activeUnregistered.count)")
        for item in groups.activeUnregistered {
            print("    - \(item.line.slug) [\(item.engine.displayName) · \(item.line.state.displayName) · \(item.hostOrigin(localHost: localHost).badgeText)]")
        }
        print("  刚完成（分组全量）：\(groups.recentlyCompleted.count)")
        for item in groups.recentlyCompleted {
            print("    - \(item.line.slug) → \(item.registration?.labelZH ?? "（无中文名）") [\(item.engine.displayName) · \(item.hostOrigin(localHost: localHost).badgeText)]")
        }
        print("  历史（分组全量）：\(groups.history.count)")
        print("看板窗口（使用者面板实际露出，不是分组全量）：")
        print("  最近完成露出：\(board.recentShown.count)  Codex=\(board.recentCounts.codex) Grok=\(board.recentCounts.grok) ox-alpha=\(board.recentCounts.claudeOxAlpha)")
        for item in board.recentShown {
            print("    - \(item.line.slug) → \(item.registration?.labelZH ?? "（无中文名）") [\(item.engine.displayName) · \(item.line.state.displayName) · \(item.hostOrigin(localHost: localHost).badgeText)]")
        }
        print("  历史露出：\(board.historyShown.count)  Codex=\(board.historyCounts.codex) Grok=\(board.historyCounts.grok) ox-alpha=\(board.historyCounts.claudeOxAlpha)")
        print("  历史隐藏：\(board.hiddenCount)  Codex=\(board.hiddenCounts.codex) Grok=\(board.hiddenCounts.grok) ox-alpha=\(board.hiddenCounts.claudeOxAlpha)")
        print("  裁剪判据：\(SentinelBoardWindow.recencyCriterion)")
        if let footerText = board.footerText {
            print("  脚注：\(footerText)")
        }
        printLoginItemDiagnostics()
        let archiveURL = paths.logsDirectory.appendingPathComponent("sentinel-history-hidden.json")
        do {
            try board.writeArchive(to: archiveURL)
            print("  隐藏归档：\(archiveURL.path)")
        } catch {
            print("  隐藏归档写入失败：\(error.localizedDescription)")
        }
        let defaults = SentinelSettings.resolvedDefaults()
        let details = LaunchdSupervisionProbe.collectFromCurrentProcess()
        for line in SentinelSettings.dumpLines(
            defaults: defaults,
            signals: details.signals
        ) {
            print(line)
        }
    }

    /// 只诊断，绝不调用 `SMAppService.register()`。
    private static func printLoginItemDiagnostics() {
        let details = LaunchdSupervisionProbe.collectFromCurrentProcess()
        let status = SMAppServiceLoginItemRegistrar().status
        for line in LoginItemDiagnostics.dumpLines(
            details: details,
            loginItemStatus: status,
            menuBarWouldRegister: false
        ) {
            print(line)
        }
    }

    /// 清理 CLI：打印计划；--cleanup-dry-run 绝不删，--cleanup-run 才真删。
    /// 目录由 SentinelPaths.discover() 决定（尊重 CORTEX_SENTINEL_WATCH_DIR / CORTEX_REPO_ROOT）。
    /// 条数规则和体积规则各打一份报告，互不覆盖。条数上限读设置，默认 `StatusFileRetention.defaultCap`。
    private static func runCleanupCLI(dryRun: Bool) {
        let defaults = SentinelSettings.resolvedDefaults()
        let paths = SentinelPaths.discover(defaults: defaults)
        let registry = CodexLineRegistryReader.read(at: paths.lineRegistryURL)
        let cap = SentinelSettings.historyRetainCount(defaults: defaults)
        let statusPlan = StatusFileCleaner.run(
            logsDirectory: paths.logsDirectory,
            registry: registry,
            dryRun: dryRun,
            cap: cap
        )
        let logPlan = LogCleaner.run(logsDirectory: paths.logsDirectory, dryRun: dryRun)
        print("logs 目录：\(paths.logsDirectory.path)")
        print(statusPlan.reportText(dryRun: dryRun))
        print(logPlan.reportText(dryRun: dryRun))
    }
}

@MainActor
private final class SentinelSmokePopoverController: NSObject, NSPopoverDelegate {
    private let store: SentinelStore
    private let popover = NSPopover()
    private let window: NSWindow
    private let button: NSButton

    init(store: SentinelStore) {
        self.store = store
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 72),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        button = NSButton(title: "打开哨兵面板", target: nil, action: nil)
        super.init()
    }

    func start() {
        window.title = "Cortex 哨兵交互验收"
        window.contentView = button
        window.center()
        window.makeKeyAndOrderFront(nil)

        button.target = self
        button.action = #selector(togglePopover(_:))

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

        store.start()
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else {
                return
            }
            self.togglePopover(self.button)
            print("SMOKE_POPOVER_SHOWN \(self.popover.isShown)")
        }
    }

    @objc
    private func togglePopover(_ sender: NSButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        Task { await store.setPanelPresented(true) }
    }

    func popoverDidClose(_ notification: Notification) {
        Task { await store.setPanelPresented(false) }
    }
}

private struct CortexSentinelSmokeApp: App {
    @State private var store: SentinelStore

    init() {
        let store = SentinelStore()
        _store = State(wrappedValue: store)
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            store.start()
        }
    }

    var body: some Scene {
        WindowGroup("Cortex 哨兵") {
            SentinelMenuView(
                store: store,
                initialSection: ProcessInfo.processInfo.arguments.contains(
                    CortexSentinelBarMain.smokeLinesArgument
                )
                    ? .dispatch
                    : .top,
                autoExpandFirstCompleted: ProcessInfo.processInfo.arguments.contains(
                    CortexSentinelBarMain.smokeExpandArgument
                )
            )
            .onAppear {
                // 截图用：把窗口钉到固定屏幕位置、置前，并把「截图矩形」写文件，
                // 让 shell 精确 screencapture -R（AX/osascript 无权限时的确定性替代）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    SmokeWindowPlacer.pinAndReport()
                    if ProcessInfo.processInfo.arguments.contains(
                        CortexSentinelBarMain.smokeSettingsArgument
                    ) {
                        store.openSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            SmokeWindowPlacer.pinAndReport(title: SentinelSettingsCopy.windowTitle)
                        }
                    }
                }
            }
        }
        .windowResizability(.contentSize)
    }
}

/// 第 1 点证据用：把菜单栏那张状态图（真实 live 探针 + 余额）渲染成放大 PNG。
/// 渲染的就是 MenuBarExtra 展示的同一张 NSImage，能直观看到三点的红黄绿是否跟面板一致。
enum StatusBarSnapshotter {
    static func render(to path: String) {
        let paths = SentinelPaths.discover()
        let semaphore = DispatchSemaphore(value: 0)
        var probes: [InputStatusDisplayProbe] = []
        var balances: [StatusBarBalanceItem] = []
        let packaging = PackagingProgressReader.read(at: paths.packagingProgressRoot)

        Task {
            if let snapshot = try? await InputStatusClient(endpoint: paths.inputStatusURL).fetch() {
                probes = snapshot.displayProbes()
            }
            let base = AIODataReader.read(
                databaseURL: paths.aioDatabaseURL,
                manifestURL: paths.aioManifestURL,
                configURL: paths.codexConfigURL
            )
            if base.sourceState == .available {
                let targets = AIODataReader.readUsageTargets(databaseURL: paths.aioDatabaseURL)
                let statuses = await AIOUsageClient().fetchAll(targets: targets)
                balances = base.replacingUsage(statuses).statusBarBalances
            }
            semaphore.signal()
        }
        semaphore.wait()

        let base = SentinelStatusBarRenderer.image(
            probes: probes,
            balances: balances,
            packaging: packaging
        )
        let scale: CGFloat = 10
        let size = NSSize(width: base.size.width * scale, height: base.size.height * scale)
        let scaled = NSImage(size: size)
        // 暗色 appearance 包住真正的栅格化（base 的 flipped 绘制块在 draw 时才跑，
        // labelColor 此刻才解析），使余额文字与真实菜单栏暗色模式一致显白。
        let drawBlock = {
            scaled.lockFocus()
            NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSGraphicsContext.current?.imageInterpolation = .none
            base.draw(in: NSRect(origin: .zero, size: size))
            scaled.unlockFocus()
        }
        if let darkAppearance = NSAppearance(named: .darkAqua) {
            darkAppearance.performAsCurrentDrawingAppearance(drawBlock)
        } else {
            drawBlock()
        }

        guard let tiff = scaled.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("状态图渲染失败\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        let tones = probes.map { "\($0.probe.model)=\(InputStatusPresentation.indicatorTone(for: $0))" }
        print("状态栏点色：\(tones.joined(separator: ", "))")
        print("written \(path)")
    }
}

/// 仅 smoke 截图用：把窗口钉到已知位置并把截图矩形（screencapture 左上原点坐标）报出来。
enum SmokeWindowPlacer {
    static func pinAndReport(title: String? = nil) {
        let window: NSWindow?
        if let title {
            window = NSApplication.shared.windows.first(where: { $0.title == title && $0.isVisible })
        } else {
            window = NSApplication.shared.windows.first(where: { $0.isVisible })
        }
        guard let window,
              let screen = window.screen ?? NSScreen.main
        else {
            return
        }
        let topLeft = NSPoint(x: 80, y: screen.frame.maxY - 80)
        window.setFrameTopLeftPoint(topLeft)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let frame = window.frame
        let x = Int(frame.minX.rounded())
        let yTop = Int((screen.frame.maxY - frame.maxY).rounded())
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        // windowNumber == CGWindowID，供 `screencapture -l<id>` 精确抓这个窗口。
        let line = "SMOKE_RECT \(x) \(yTop) \(width) \(height) WINDOW_ID \(window.windowNumber)"
        print(line)
        if let path = ProcessInfo.processInfo.environment["CORTEX_SMOKE_RECT_FILE"] {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
