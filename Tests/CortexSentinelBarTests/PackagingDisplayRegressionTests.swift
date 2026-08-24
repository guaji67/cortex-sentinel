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
            _ = store?.packagingProgress
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

    private func writeRunningProgress() throws {
        let run = progressRoot.appendingPathComponent("run-1", isDirectory: true)
        try fileManager.createDirectory(at: run, withIntermediateDirectories: true)
        try Data(
            """
            {"schema":"cortex.packaging-progress.v1","run_id":"run-1","status":"running",
             "current_step_id":"build","current_detail":"打包中","updated_at":"2026-08-24T15:00:00Z",
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

/// 与生产面板同构：父层读 packagingActive，决定要不要把分区挂进 LazyVStack。
private struct LazyStackPackagingHostProbe: View {
    var store: SentinelStore
    var counter: SentinelViewBodyCounter

    var body: some View {
        let _ = store.panelPresentationGeneration
        let packagingActive = store.packagingActive
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
                if packagingActive {
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
