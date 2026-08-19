import Combine
import Foundation
import XCTest
@testable import CortexSentinelBar

/// 三道省开销闸叠在一起：值没变不发刷新、面板关着不拉进程表、
/// 状态文件 mtime+size 没变不重解。单闸已有覆盖；这里走一条任务的完整生命周期。
@MainActor
final class StackedRefreshGateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private let fileManager = FileManager.default
    private let statusFileName = "codex-babysitter-alpha.status.json"

    override func setUpWithError() throws {
        suiteName = "stacked-gates-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            SentinelNotifyCadence.every.rawValue,
            forKey: SentinelSettingsKey.notifyCadence
        )
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "stacked-gates-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let root {
            try? fileManager.removeItem(at: root)
        }
    }

    // 1. 监视目录空 → 界面 0 条
    func testEmptyWatchDirectoryShowsZeroLines() async {
        let store = makeStore()
        await store.refreshStatuses()
        XCTAssertEqual(store.lines, [])
        XCTAssertEqual(store.otherCodexProcesses, [])
    }

    // 2. 写入「运行中」→ 界面必须看到这条，状态是运行中
    func testWritingRunningStatusAppearsAsRunning() async throws {
        let box = NotificationBox()
        let store = makeStore(notificationBox: box)
        try writeStatus(.running)
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.count, 1)
        XCTAssertEqual(store.lines.first?.slug, "alpha")
        XCTAssertEqual(store.lines.first?.state, .running)
        XCTAssertEqual(box.drafts, [])
    }

    // 3. 原地改写同一文件为「已完成」，文件名不变、字节数也不变
    //    → 界面必须变成已完成，通知必须发出一条。
    //    第 3 道闸按 mtime+size 判断；只看 size 就会漏掉这次。
    func testSameSizeInPlaceRewriteToDoneUpdatesPanelAndNotifies() async throws {
        let box = NotificationBox()
        let cache = LineStatusFileCache()
        let store = makeStore(cache: cache, notificationBox: box)

        try writeStatus(.running)
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.first?.state, .running)
        XCTAssertEqual(box.drafts, [])
        let before = try fileIdentity()
        XCTAssertEqual(cache.parseCount, 1)

        try rewriteStatusInPlace(.done)
        let after = try fileIdentity()
        XCTAssertEqual(
            before.size,
            after.size,
            "本步要求 running / done 两份 JSON 字节数相同，否则测不到「只看 size 会漏」"
        )

        await store.refreshStatuses()

        let identityNote = """
        复现条件：文件名 \(statusFileName)，size \(before.size) → \(after.size)，\
        mtime \(before.date.timeIntervalSince1970) → \(after.date.timeIntervalSince1970)，\
        mtime 是否相同 \(before.date == after.date)，parseCount \(cache.parseCount)
        """
        XCTAssertEqual(
            store.lines.first?.state,
            .done,
            "原地同大小改写后界面仍停在 \(String(describing: store.lines.first?.state))。\(identityNote)"
        )
        XCTAssertEqual(box.drafts.count, 1, identityNote)
        XCTAssertEqual(box.drafts.first?.category, .taskComplete)
        XCTAssertEqual(box.drafts.first?.title, "任务结束")
        XCTAssertEqual(cache.parseCount, 2, "size 相同但内容变了，必须重解。\(identityNote)")
    }

    // 4. 面板关着走 2 和 3 → 通知照发，且不拉进程表
    func testClosedPanelStillNotifiesOnSameSizeInPlaceRewrite() async throws {
        let box = NotificationBox()
        let reader = RecordingProcessReader()
        let store = makeStore(processReader: reader, notificationBox: box)

        try writeStatus(.running)
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.first?.state, .running)
        XCTAssertEqual(box.drafts, [])
        XCTAssertEqual(reader.callCount, 0)

        try rewriteStatusInPlace(.done)
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.first?.state, .done)
        XCTAssertEqual(box.drafts.count, 1)
        XCTAssertEqual(box.drafts.first?.category, .taskComplete)
        XCTAssertEqual(reader.callCount, 0, "面板关着不该拉进程表")
    }

    // 5. 面板从关到开 → 进程表那一栏要能拿到数据
    func testOpeningPanelLoadsProcessTable() async {
        let reader = RecordingProcessReader()
        reader.processes = [
            OtherCodexProcess(processID: 4242, worktreeName: "wt-alpha", elapsed: "00:12"),
        ]
        let store = makeStore(processReader: reader)
        await store.refreshStatuses()
        XCTAssertEqual(reader.callCount, 0)
        XCTAssertEqual(store.otherCodexProcesses, [])

        await store.setPanelPresented(true)
        XCTAssertEqual(reader.callCount, 1)
        XCTAssertEqual(store.otherCodexProcesses, reader.processes)
    }

    // 6. 连续两轮完全没有任何文件变化 → 界面刷新信号 0，通知也是 0
    func testTwoUnchangedRefreshesEmitZeroPublicationsAndZeroNotifications() async throws {
        let box = NotificationBox()
        let store = makeStore(notificationBox: box)
        try writeStatus(.running)
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.first?.state, .running)
        XCTAssertEqual(box.drafts, [])

        let publications = await countPublications(store) {
            await store.refreshStatuses()
            await store.refreshStatuses()
        }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(box.drafts, [])
        XCTAssertEqual(store.lines.first?.state, .running)
    }

    /// 一条任务从空目录到跑完，三道闸叠着走完，每一步都跟上。
    func testOneTaskLifecycleThroughStackedGates() async throws {
        let box = NotificationBox()
        let reader = RecordingProcessReader()
        reader.processes = [
            OtherCodexProcess(processID: 77, worktreeName: "wt-life", elapsed: "00:03"),
        ]
        let cache = LineStatusFileCache()
        let store = makeStore(
            processReader: reader,
            cache: cache,
            notificationBox: box
        )

        await store.refreshStatuses()
        XCTAssertEqual(store.lines, [])
        XCTAssertEqual(reader.callCount, 0)

        try writeStatus(.running)
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.first?.state, .running)
        XCTAssertEqual(box.drafts, [])
        XCTAssertEqual(reader.callCount, 0)
        let before = try fileIdentity()

        try rewriteStatusInPlace(.done)
        let after = try fileIdentity()
        XCTAssertEqual(before.size, after.size)
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.first?.state, .done)
        XCTAssertEqual(box.drafts.count, 1)
        XCTAssertEqual(box.drafts.first?.category, .taskComplete)
        XCTAssertEqual(reader.callCount, 0)

        await store.setPanelPresented(true)
        XCTAssertEqual(reader.callCount, 1)
        XCTAssertEqual(store.otherCodexProcesses, reader.processes)
        try await Task.sleep(nanoseconds: 80_000_000)

        let idleDraftCount = box.drafts.count
        let idlePublications = await countPublications(store) {
            await store.refreshStatuses()
            await store.refreshStatuses()
        }
        XCTAssertEqual(idlePublications, 0)
        XCTAssertEqual(box.drafts.count, idleDraftCount)
        XCTAssertEqual(store.lines.first?.state, .done)
    }

    private func makeStore(
        processReader: RecordingProcessReader = RecordingProcessReader(),
        cache: LineStatusFileCache = LineStatusFileCache(),
        notificationBox: NotificationBox? = nil
    ) -> SentinelStore {
        SentinelStore(
            defaults: defaults,
            environment: [
                "CORTEX_SENTINEL_WATCH_DIR": root.path,
                "CORTEX_DATA_ROOT": root.path,
                "CORTEX_INPUT_STATUS_URL": "http://127.0.0.1:1/status",
                "CORTEX_CODEX_AUTH_PATH": root.appendingPathComponent("missing-auth.json").path,
                "CORTEX_AIO_DB_PATH": root.appendingPathComponent("missing-aio.db").path,
            ],
            lineStatusCache: cache,
            otherCodexProcessReader: { ids in processReader.read(ids) },
            notificationSendHandler: notificationBox.map { box in
                { draft in box.drafts.append(draft) }
            }
        )
    }

    private func countPublications(_ store: SentinelStore, _ body: () async -> Void) async -> Int {
        var count = 0
        let cancellable = store.objectWillChange.sink { count += 1 }
        await body()
        withExtendedLifetime(cancellable) {}
        return count
    }

    private func writeStatus(_ state: LifecycleState) throws {
        try Data(sameSizeJSON(state).utf8).write(to: statusURL)
    }

    private func rewriteStatusInPlace(_ state: LifecycleState) throws {
        let data = Data(sameSizeJSON(state).utf8)
        let handle = try FileHandle(forWritingTo: statusURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func fileIdentity() throws -> (date: Date, size: UInt64) {
        let attributes = try fileManager.attributesOfItem(atPath: statusURL.path)
        guard let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else {
            throw NSError(
                domain: "StackedRefreshGateTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "读不到状态文件 mtime/size"]
            )
        }
        return (date, size.uint64Value)
    }

    private var statusURL: URL {
        root.appendingPathComponent(statusFileName)
    }

    /// running 和 done 字节数必须一样，才能打到「只看 size 会漏更新」这一步。
    private func sameSizeJSON(_ state: LifecycleState) -> String {
        let pad = String(repeating: "x", count: 12 - state.rawValue.count)
        let json = """
        {"slug":"alpha","state":"\(state.rawValue)","note":"\(pad)","updated_at":"2026-08-19T20:00:00Z"}
        """
        return json
    }
}

private enum LifecycleState {
    case running
    case done

    var rawValue: String {
        switch self {
        case .running:
            return "running"
        case .done:
            return "done"
        }
    }
}

private final class RecordingProcessReader: @unchecked Sendable {
    var callCount = 0
    var processes: [OtherCodexProcess] = []

    func read(_ ids: Set<Int>) -> [OtherCodexProcess] {
        _ = ids
        callCount += 1
        return processes
    }
}

private final class NotificationBox: @unchecked Sendable {
    var drafts: [SentinelNotificationDraft] = []
}
