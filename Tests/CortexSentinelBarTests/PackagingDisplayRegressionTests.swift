import AppKit
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import CortexSentinelBar

/// 打包显示回归：packagingProgress 从 nil 跳到 running 时，
/// 面板分区和状态栏观察循环必须跟上。不碰真实监视目录。
@MainActor
final class PackagingDisplayRegressionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var progressRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        suiteName = "pack-display-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "pack-display-\(UUID().uuidString)",
            isDirectory: true
        )
        progressRoot = root.appendingPathComponent("pack-progress", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: progressRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let root {
            try? fileManager.removeItem(at: root)
        }
    }

    func testNilToRunningProducesPanelSnapshotAndStatusBarPackagingText() async throws {
        let store = makeStore()
        XCTAssertNil(SentinelPackagingPresentation.activeSnapshot(from: store))
        XCTAssertFalse(statusBarContainsPackaging(store))

        try writeRunningProgress()
        await store.refreshStatuses()

        let snapshot = try XCTUnwrap(SentinelPackagingPresentation.activeSnapshot(from: store))
        XCTAssertTrue(snapshot.isActive)
        XCTAssertTrue(store.packagingActive)
        XCTAssertTrue(statusBarContainsPackaging(store), "状态栏渲染必须含打包字样")
        XCTAssertNotNil(store.statusBarRenderState.packagingProgress)
    }

    func testPackagingUpdateInvalidatesOnlyPackagingSectionAndStatusBarInputs() async throws {
        let store = makeStore()
        await store.refreshStatuses()

        let packaging = StoreChangeCounter { [weak store] in
            // COR-7600：分区读三态面 packagingReading。
            _ = store?.packagingReading
        }
        let header = StoreChangeCounter { [weak store] in
            guard let store else { return }
            _ = store.paths
            _ = store.lineGroups
            _ = store.boardWindow
            _ = store.localHost
        }
        let channel = StoreChangeCounter { [weak store] in
            guard let store else { return }
            _ = store.channelStatus
            _ = store.lineGroups
            _ = store.localHost
        }
        let dispatch = StoreChangeCounter { [weak store] in
            guard let store else { return }
            _ = store.lineGroups
            _ = store.boardWindow
            _ = store.relayAttribution
            _ = store.localHost
            _ = store.paths
        }
        let balances = StoreChangeCounter { [weak store] in
            guard let store else { return }
            _ = store.aio
            _ = store.officialUsage
        }
        let statusBar = StoreChangeCounter { [weak store] in
            _ = store?.statusBarRenderState
        }

        try writeRunningProgress()
        await store.refreshStatuses()

        packaging.stop()
        header.stop()
        channel.stop()
        dispatch.stop()
        balances.stop()
        statusBar.stop()

        XCTAssertEqual(packaging.count, 1, "打包面必须失效打包分区")
        XCTAssertEqual(statusBar.count, 1, "打包面必须失效状态栏读集")
        XCTAssertEqual(header.count, 0, "打包面不许惊动标题")
        XCTAssertEqual(channel.count, 0, "打包面不许惊动通道")
        XCTAssertEqual(dispatch.count, 0, "打包面不许惊动派工区")
        XCTAssertEqual(balances.count, 0, "打包面不许惊动余额")
    }

    func testPackagingRefreshesWhilePanelStaysClosed() async throws {
        let store = makeStore()
        XCTAssertEqual(store.statusPollInterval(), 120, "关面板默认 120 秒，证明没走面板打开档")
        XCTAssertNil(store.packagingProgress)
        XCTAssertFalse(store.packagingActive)

        try writeRunningProgress()
        await store.refreshStatuses()

        XCTAssertEqual(store.packagingProgress?.isActive, true)
        XCTAssertTrue(store.packagingActive)
        XCTAssertEqual(store.statusPollInterval(), 120, "刷新打包不得把面板当成打开")
    }

    func testOpeningPanelStillPicksUpPackagingWhenBalanceRefreshIsSkipped() async throws {
        let store = makeStore()
        await store.setPanelPresented(true)
        await store.setPanelPresented(false)
        XCTAssertFalse(store.packagingActive)

        try writeRunningProgress()
        await store.setPanelPresented(true)

        XCTAssertEqual(store.packagingProgress?.isActive, true)
        XCTAssertTrue(store.packagingActive, "二次打开面板即使跳过余额刷新也必须刷到打包")
    }

    func testObservationLoopFiresForPackagingNilToRunning() async throws {
        let store = makeStore()
        var paints = 0
        var sawPackaging = false
        var armed = true

        func arm() {
            guard armed else { return }
            withObservationTracking {
                _ = store.statusBarRenderState
            } onChange: {
                Task { @MainActor in
                    guard armed else { return }
                    paints += 1
                    sawPackaging = store.statusBarRenderState.packagingProgress?.isActive == true
                    arm()
                }
            }
        }
        arm()

        try writeRunningProgress()
        await store.refreshStatuses()
        try await Task.sleep(nanoseconds: 80_000_000)

        armed = false
        XCTAssertTrue(store.packagingProgress?.isActive == true, "store 已写入 running")
        XCTAssertGreaterThan(paints, 0, "状态栏观察循环必须为 statusBarRenderState 触发")
        XCTAssertTrue(sawPackaging, "onChange 下一拍必须读到打包中")
    }

    func testHostedMenuMountsPackagingSectionOnNilToRunning() async throws {
        _ = NSApplication.shared
        let store = makeStore()
        let counter = SentinelViewBodyCounter()
        let host = NSHostingController(
            rootView: LazyStackPackagingHostProbe(store: store, counter: counter)
        )
        host.view.frame = NSRect(
            x: 0,
            y: 0,
            width: SentinelTheme.Metrics.menuWidth,
            height: SentinelTheme.Metrics.menuHeight
        )
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.count, 0, "未 running 时分区不应挂进树")

        try writeRunningProgress()
        await store.refreshStatuses()
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(counter.count, 0, "packagingActive 翻转后必须挂上打包分区")
        XCTAssertGreaterThan(
            offscreenPanelHeight(store: store),
            offscreenPanelHeight(store: makeStore()),
            "离屏面板在 running 时必须比空闲更高（打包块占位）"
        )
    }

    private func makeStore() -> SentinelStore {
        SentinelStore(
            defaults: defaults,
            environment: [
                "CORTEX_SENTINEL_WATCH_DIR": root.path,
                "CORTEX_DATA_ROOT": root.path,
                "CORTEX_PACK_PROGRESS_DIR": progressRoot.path,
                "CORTEX_CODEX_AUTH_PATH": root.appendingPathComponent("missing-auth.json").path,
                "CORTEX_AIO_DB_PATH": root.appendingPathComponent("missing-aio.db").path,
                "CORTEX_INPUT_STATUS_URL": "http://127.0.0.1:1/status",
            ],
            otherCodexProcessReader: { _ in [] }
        )
    }

    // MARK: - COR-7600 三态分区

    /// 稳定落点在但没炉在跑（completed 残留）：面板必须显示 idle 和读侧 reason，
    /// 顺带显示上一炉时间；状态栏「打包」段保持安静。
    func testPanelShowsIdleReasonWithLastRunFromStableMirror() async throws {
        let store = makeStore()
        try writeStablePackProgress(status: "completed")
        await store.refreshStatuses()

        guard case let .idle(reason, lastRun) = store.packagingReading else {
            return XCTFail("completed 残留必须投影成 idle，实际 \(String(describing: store.packagingReading))")
        }
        XCTAssertEqual(reason, "当前没有在跑的炉")
        XCTAssertEqual(lastRun?.status, .completed)
        XCTAssertNotNil(lastRun?.updatedAt)
        XCTAssertNil(store.packagingProgress, "状态栏面不收 idle")
        XCTAssertFalse(store.packagingActive)
    }

    /// 登记文件读不了：必须落 error，和 idle 分开，不许被兜底洗成「没在打包」。
    func testPanelShowsErrorDistinctFromIdleWhenMirrorUnreadable() async throws {
        let store = makeStore()
        let healthDirectory = root.appendingPathComponent("health", isDirectory: true)
        try fileManager.createDirectory(at: healthDirectory, withIntermediateDirectories: true)
        try Data("this-is-not-pack-progress".utf8)
            .write(to: healthDirectory.appendingPathComponent("pack-progress.json"))
        await store.refreshStatuses()

        guard case let .error(reason) = store.packagingReading else {
            return XCTFail("读不了的登记文件必须投影成 error，实际 \(String(describing: store.packagingReading))")
        }
        XCTAssertEqual(reason, "登记文件读不了或不是 JSON")
        XCTAssertFalse(store.packagingActive)
    }

    /// 稳定落点的活线：面板读侧翻成 running，状态栏「打包」段点亮。
    func testPanelReadingFlipsToRunningFromStableMirror() async throws {
        let store = makeStore()
        try writeStablePackProgress(status: "running")
        await store.refreshStatuses()

        guard case let .running(snapshot) = store.packagingReading else {
            return XCTFail("稳定落点活线必须投影成 running，实际 \(String(describing: store.packagingReading))")
        }
        XCTAssertEqual(snapshot.furnaceText, "9.9.9")
        XCTAssertEqual(snapshot.stepProgressText, "第 2/2 步")
        XCTAssertTrue(snapshot.isActive)
        XCTAssertTrue(store.packagingActive)
        XCTAssertTrue(statusBarContainsPackaging(store))
    }

    /// 稳定落点还没有登记文件：idle 用「还没有登记文件」那句 reason，与
    /// 「炉刚跑完」的 idle 区分得开。
    func testPanelShowsIdleWhenStableMirrorFileIsMissing() async throws {
        let store = makeStore()
        await store.refreshStatuses()

        guard case let .idle(reason, lastRun) = store.packagingReading else {
            return XCTFail("无文件必须投影成 idle，实际 \(String(describing: store.packagingReading))")
        }
        XCTAssertEqual(reason, "当前没有在跑的炉（稳定落点还没有登记文件）")
        XCTAssertNil(lastRun)
    }

    // MARK: - COR-7600 返工：error 人话上屏、与 running 视觉分档

    /// running 与 error 必须一眼可分：图标、颜色、行档位三样都得不一样。
    /// 曾经两者同为橙框橙图标，「在打包」和「出错了」扫一眼混掉。
    func testErrorMoodDiffersFromRunningInIconColorAndTone() {
        let running = SentinelPackagingSectionMood.running
        let error = SentinelPackagingSectionMood.error
        XCTAssertNotEqual(running.iconName, error.iconName, "running 与 error 图标必须不同")
        XCTAssertNotEqual(running.accent, error.accent, "running 与 error 前景色必须不同")
        XCTAssertNotEqual(running.tone, error.tone, "running 与 error 行档位必须不同")
        // idle 保持安静档，也不许跟 error 撞。
        XCTAssertNotEqual(SentinelPackagingSectionMood.idle.accent, error.accent)
    }

    /// 上屏文案一律人话：没看过我们代码的人要能读懂发生了什么、要不要做事。
    /// JSON / 数据根 / 稳定落点 / 登记文件这些内部词只许进 --dump-state 诊断口。
    func testOnScreenPackagingCopySpeaksHumanWithoutInternalJargon() {
        let onScreenTexts = [
            SentinelPackagingCopy.sectionTitle,
            SentinelPackagingCopy.idleLine,
            SentinelPackagingCopy.errorLine,
            SentinelPackagingCopy.errorHint,
        ]
        let forbiddenJargon = ["JSON", "json", "数据根", "稳定落点", "登记", "解析", "镜像", "schema", "文件"]
        for word in forbiddenJargon {
            for text in onScreenTexts {
                XCTAssertFalse(
                    text.contains(word),
                    "上屏文案不许出现内部词「\(word)」：\(text)"
                )
            }
        }
        // error 那句要同时说清「什么状态」和「要不要管」。
        XCTAssertEqual(SentinelPackagingCopy.errorLine, "读不到打包状态")
        XCTAssertEqual(SentinelPackagingCopy.errorHint, "下一炉起来会自己恢复")
    }

    private func writeStablePackProgress(status: String) throws {
        let healthDirectory = root.appendingPathComponent("health", isDirectory: true)
        try fileManager.createDirectory(at: healthDirectory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let processStartedAt = PackagingProgressActivity.processStartedAt(pid)
        let isRunning = status == "running"
        let steps = isRunning
            ? #"{"id":"build","title":"构建 App 与 zip","status":"done"},{"id":"dmg","title":"打 DMG","status":"running"}"#
            : #"{"id":"build","title":"构建 App 与 zip","status":"done"}"#
        let currentStep = isRunning ? "dmg" : "build"
        let liveFields = isRunning
            ? "\"pid\":\(pid),\"process_started_at\":\"\(processStartedAt)\","
            : ""
        let payload = """
        {"schema":"cortex.packaging-progress.v1","run_id":"run-stable","entry":"release_app",
         "version":"9.9.9","status":"\(status)",
         \(liveFields)
         "current_step_id":"\(currentStep)","current_detail":"打包中",
         "started_at":"\(formatter.string(from: Date().addingTimeInterval(-20 * 60)))",
         "updated_at":"\(formatter.string(from: Date()))",
         "eta_label":"大约还要 9 分钟",
         "progress_file":"\(progressRoot.appendingPathComponent("run-stable/progress.json").path)",
         "steps":[\(steps)]}
        """
        try Data(payload.utf8).write(
            to: healthDirectory.appendingPathComponent("pack-progress.json")
        )
    }

    private func writeRunningProgress() throws {
        let run = progressRoot.appendingPathComponent("run-1", isDirectory: true)
        try fileManager.createDirectory(at: run, withIntermediateDirectories: true)
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let processStartedAt = PackagingProgressActivity.processStartedAt(pid)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try Data(
            """
            {"schema":"cortex.packaging-progress.v1","run_id":"run-1","status":"running",
             "pid":\(pid),"process_started_at":"\(processStartedAt)",
             "current_step_id":"build","current_detail":"打包中","updated_at":"\(formatter.string(from: Date()))",
             "eta_label":"大约还要 9 分钟",
             "steps":[{"id":"build","title":"构建 App 与 zip","status":"running"}]}
            """.utf8
        ).write(to: run.appendingPathComponent("progress.json"))
    }

    private func statusBarContainsPackaging(_ store: SentinelStore) -> Bool {
        let image = SentinelStatusBarRenderer.image(
            probes: store.statusBarRenderState.inputStatus.displayProbes(),
            balances: store.statusBarRenderState.aio.statusBarBalances,
            packaging: store.statusBarRenderState.packagingProgress
        )
        let idle = SentinelStatusBarRenderer.image(
            probes: store.statusBarRenderState.inputStatus.displayProbes(),
            balances: store.statusBarRenderState.aio.statusBarBalances
        )
        return image.size.width > idle.size.width
    }

    private func offscreenPanelHeight(store: SentinelStore) -> CGFloat {
        let view = SentinelMenuView(store: store, rendersOffscreen: true)
            .frame(width: SentinelTheme.Metrics.menuWidth)
            .fixedSize(horizontal: true, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(
            width: SentinelTheme.Metrics.menuWidth,
            height: nil
        )
        return renderer.nsImage?.size.height ?? 0
    }
}

/// 与生产面板同构：父层读 packagingReading 在不在，决定要不要把分区挂进 LazyVStack。
private struct LazyStackPackagingHostProbe: View {
    var store: SentinelStore
    var counter: SentinelViewBodyCounter

    var body: some View {
        let _ = store.panelPresentationGeneration
        let packagingMounted = store.packagingReading != nil
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
                if packagingMounted {
                    SentinelPackagingSection(store: store, bodyCounter: counter)
                }
                Text("below")
                    .font(SentinelTheme.Fonts.subtitle)
            }
            .padding(SentinelTheme.Spacing.panel)
        }
        .frame(
            width: SentinelTheme.Metrics.menuWidth,
            height: SentinelTheme.Metrics.menuHeight
        )
    }
}
