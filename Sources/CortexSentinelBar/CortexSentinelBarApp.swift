import AppKit
import SwiftUI

@main
enum CortexSentinelBarMain {
    static let smokeWindowArgument = "--smoke-window"
    static let smokePopoverArgument = "--smoke-popover"
    static let smokeLinesArgument = "--smoke-lines"
    static let smokeExpandArgument = "--smoke-expand"
    static let cleanupDryRunArgument = "--cleanup-dry-run"
    static let cleanupRunArgument = "--cleanup-run"
    static let renderStatusBarArgument = "--render-statusbar"
    static let dumpStateArgument = "--dump-state"

    @MainActor
    static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(dumpStateArgument) {
            runDumpStateCLI()
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
        if arguments.contains(smokePopoverArgument) {
            runSmokePopoverApplication()
        } else if arguments.contains(smokeWindowArgument) {
            CortexSentinelSmokeApp.main()
        } else {
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
        if !paths.logsDirectoryExists {
            print(paths.missingWatchDirectoryMessage)
        }
        print("仓库根：\(paths.repositoryRoot.path)")
        let channelStatus = SentinelFileReader.readChannelStatus(at: paths.channelStatusURL)
        let liveChannelCounts = groups.activeEngineCounts
        print("通道：\(paths.channelStatusURL.path)")
        print(
            "  Grok \(channelStatus.grok.status.displayName) · 文件running=\(channelStatus.grok.running.map(String.init) ?? "无") · 面板条数=\(liveChannelCounts.grok) · \(channelStatus.grok.evidence)"
        )
        print(
            "  Codex \(channelStatus.codex.status.displayName) · 文件running=\(channelStatus.codex.running.map(String.init) ?? "无") · 面板条数=\(liveChannelCounts.codex) · \(channelStatus.codex.evidence)"
        )
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
        print(String(format: "读取耗时：%.1f ms", readMilliseconds))
        print("分组结果：")
        print("  已登记派工（活跃）：\(groups.activeRegistered.count)")
        for item in groups.activeRegistered {
            print("    - \(item.line.slug) → \(item.registration?.labelZH ?? "（无中文名）") [\(item.engine.displayName) · \(item.line.state.displayName)]")
        }
        print("  自动识别（未登记且活跃）：\(groups.activeUnregistered.count)")
        for item in groups.activeUnregistered {
            print("    - \(item.line.slug) [\(item.engine.displayName) · \(item.line.state.displayName)]")
        }
        print("  刚完成（分组全量）：\(groups.recentlyCompleted.count)")
        for item in groups.recentlyCompleted {
            print("    - \(item.line.slug) → \(item.registration?.labelZH ?? "（无中文名）") [\(item.engine.displayName)]")
        }
        print("  历史（分组全量）：\(groups.history.count)")
        print("看板窗口（使用者面板实际露出，不是分组全量）：")
        print("  最近完成露出：\(board.recentShown.count)  Grok=\(board.recentCounts.grok) Codex=\(board.recentCounts.codex)")
        for item in board.recentShown {
            print("    - \(item.line.slug) → \(item.registration?.labelZH ?? "（无中文名）") [\(item.engine.displayName) · \(item.line.state.displayName)]")
        }
        print("  历史露出：\(board.historyShown.count)  Grok=\(board.historyCounts.grok) Codex=\(board.historyCounts.codex)")
        print("  历史隐藏：\(board.hiddenCount)  Grok=\(board.hiddenCounts.grok) Codex=\(board.hiddenCounts.codex)")
        print("  裁剪判据：\(SentinelBoardWindow.recencyCriterion)")
        if let footerText = board.footerText {
            print("  脚注：\(footerText)")
        }
        let archiveURL = paths.logsDirectory.appendingPathComponent("sentinel-history-hidden.json")
        do {
            try board.writeArchive(to: archiveURL)
            print("  隐藏归档：\(archiveURL.path)")
        } catch {
            print("  隐藏归档写入失败：\(error.localizedDescription)")
        }
    }

    /// 日志清理 CLI（第 5 点 dry-run 证据用）：打印计划；--cleanup-dry-run 绝不删，
    /// --cleanup-run 才真删。目录由 SentinelPaths.discover() 决定（尊重 CORTEX_SENTINEL_WATCH_DIR / CORTEX_REPO_ROOT）。
    private static func runCleanupCLI(dryRun: Bool) {
        let paths = SentinelPaths.discover()
        let plan = LogCleaner.run(logsDirectory: paths.logsDirectory, dryRun: dryRun)
        print("logs 目录：\(paths.logsDirectory.path)")
        print(plan.reportText(dryRun: dryRun))
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
        store.setPanelPresented(true)
    }

    func popoverDidClose(_ notification: Notification) {
        store.setPanelPresented(false)
    }
}

private struct CortexSentinelSmokeApp: App {
    @StateObject private var store: SentinelStore

    init() {
        let store = SentinelStore()
        _store = StateObject(wrappedValue: store)
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

        let base = SentinelStatusBarRenderer.image(probes: probes, balances: balances)
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
    static func pinAndReport() {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
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
