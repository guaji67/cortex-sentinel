import Combine
import Foundation
import XCTest
@testable import CortexSentinelBar

@MainActor
final class IdleRefreshCostTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        suiteName = "idle-refresh-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            SentinelNotifyCadence.every.rawValue,
            forKey: SentinelSettingsKey.notifyCadence
        )
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "idle-refresh-\(UUID().uuidString)",
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

    func testClosedPanelDoesNotReadProcessTable() async {
        let reader = RecordingProcessReader()
        let store = makeStore(processReader: reader)
        for _ in 0..<6 {
            await store.refreshStatuses()
        }
        XCTAssertEqual(reader.callCount, 0)
        XCTAssertEqual(store.otherCodexProcesses, [])
        XCTAssertEqual(AIOConstants.statusRefreshInterval, 5)
        XCTAssertEqual(AIOConstants.statusRefreshIntervalWhenClosed, 120)
        XCTAssertFalse(store.lastStatusDiskReadWasOnMainThreadForTests)
    }

    func testStatusDiskReadLeavesTheMainThread() async {
        let store = makeStore()
        await store.refreshStatuses()
        XCTAssertEqual(store.statusDiskRefreshCountForTests, 1)
        XCTAssertFalse(store.lastStatusDiskReadWasOnMainThreadForTests)
    }

    func testRefreshIntervalSettingTakesEffectWithoutRestart() async {
        let store = makeStore()
        store.start()
        XCTAssertEqual(store.scheduledStatusTimerInterval, 120)
        store.settingsModel.setPanelClosedRefreshInterval(.thirtySeconds)
        XCTAssertEqual(store.scheduledStatusTimerInterval, 30)
        store.settingsModel.setPanelOpenRefreshInterval(.twoSeconds)
        XCTAssertEqual(store.scheduledStatusTimerInterval, 30)
    }

    func testOpeningPanelSwitchesToOpenRefreshIntervalImmediately() async {
        let store = makeStore()
        store.start()
        store.settingsModel.setPanelOpenRefreshInterval(.tenSeconds)
        await store.setPanelPresented(true)
        XCTAssertEqual(store.scheduledStatusTimerInterval, 10)
        await store.setPanelPresented(false)
        XCTAssertEqual(store.scheduledStatusTimerInterval, 120)
    }

    func testClosedPanelIdleSixtySecondsKeepsPublicationsInSingleDigits() async throws {
        let reader = RecordingProcessReader()
        let store = makeStore(processReader: reader)
        await store.refreshStatuses()
        store.start()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        var count = 0
        let cancellable = store.objectWillChange.sink { count += 1 }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        withExtendedLifetime(cancellable) {}
        XCTAssertLessThan(count, 10, "面板关着静置 60 秒 objectWillChange=\(count)")
        XCTAssertEqual(reader.callCount, 0)
    }

    func testOpenPanelReadsProcessTable() async {
        let reader = RecordingProcessReader()
        reader.processes = [
            OtherCodexProcess(processID: 4242, worktreeName: "wt-alpha", elapsed: "00:12"),
        ]
        let store = makeStore(processReader: reader)
        await store.setPanelPresented(true)
        XCTAssertEqual(reader.callCount, 1)
        XCTAssertEqual(store.otherCodexProcesses, reader.processes)

        await store.refreshStatuses()
        XCTAssertEqual(reader.callCount, 2)
        XCTAssertEqual(store.otherCodexProcesses, reader.processes)
    }

    func testClosedPanelStillNotifiesWhenStatusFileChanges() async throws {
        let box = NotificationBox()
        let reader = RecordingProcessReader()
        let store = makeStore(processReader: reader, notificationBox: box)
        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"running","updated_at":"2026-08-19T20:00:00Z"}"#
        )
        await store.refreshStatuses()
        XCTAssertEqual(box.drafts, [])
        XCTAssertEqual(reader.callCount, 0)

        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"done","updated_at":"2026-08-19T20:01:00Z"}"#
        )
        await store.refreshStatuses()
        XCTAssertEqual(reader.callCount, 0)
        XCTAssertEqual(box.drafts.count, 1)
        XCTAssertEqual(box.drafts.first?.category, .taskComplete)
        XCTAssertEqual(box.drafts.first?.title, "任务结束")
        XCTAssertEqual(store.lines.first?.state, .done)
    }

    func testUnchangedStatusFileIsNotReparsed() async throws {
        let cache = LineStatusFileCache()
        let store = makeStore(cache: cache)
        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"running","updated_at":"2026-08-19T20:00:00Z"}"#
        )
        await store.refreshStatuses()
        XCTAssertEqual(cache.parseCount, 1)
        XCTAssertEqual(store.lines.first?.slug, "alpha")

        await store.refreshStatuses()
        await store.refreshStatuses()
        XCTAssertEqual(cache.parseCount, 1)

        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"waiting_relay","updated_at":"2026-08-19T20:02:00Z"}"#
        )
        await store.refreshStatuses()
        XCTAssertEqual(cache.parseCount, 2)
        XCTAssertEqual(store.lines.first?.state, .waitingRelay)
    }

    func testIdleSixtySecondsWithoutOpeningPanelDoesNotPublish() async throws {
        let reader = RecordingProcessReader()
        let store = makeStore(processReader: reader)
        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"running","updated_at":"2026-08-19T20:00:00Z"}"#
        )
        await store.refreshStatuses()
        let count = await countPublications(store) {
            for _ in 0..<12 {
                await store.refreshStatuses()
            }
        }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(reader.callCount, 0)
        XCTAssertEqual(AIOConstants.statusRefreshInterval, 5)
        XCTAssertEqual(AIOConstants.statusRefreshIntervalWhenClosed, 120)
    }

    func testBackgroundJobsFileIsReadOffMainThread() async throws {
        try write(
            "background-jobs-health.json",
            """
            {
              "generated_at": "2026-08-20T01:40:00+08:00",
              "jobs": [
                {
                  "label": "com.falcon.cortex.web",
                  "name": "界面常驻服务",
                  "status": "ok",
                  "plist_status": "loaded"
                }
              ]
            }
            """
        )
        let store = makeStore()
        await store.refreshStatuses()
        XCTAssertFalse(store.lastStatusDiskReadWasOnMainThreadForTests)
        XCTAssertEqual(store.backgroundJobs.sourceState, .available)
        XCTAssertEqual(store.backgroundJobs.jobs.count, 1)
        XCTAssertEqual(store.backgroundJobs.jobs[0].name, "界面常驻服务")
        XCTAssertEqual(store.backgroundJobs.jobs[0].plistStatus, .loaded)
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

    private func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: root.appendingPathComponent(name))
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
