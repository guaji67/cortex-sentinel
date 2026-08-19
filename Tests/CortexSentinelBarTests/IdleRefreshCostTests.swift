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

    func testClosedPanelDoesNotReadProcessTable() {
        let reader = RecordingProcessReader()
        let store = makeStore(processReader: reader)
        for _ in 0..<6 {
            store.refreshStatuses()
        }
        XCTAssertEqual(reader.callCount, 0)
        XCTAssertEqual(store.otherCodexProcesses, [])
        XCTAssertEqual(AIOConstants.statusRefreshInterval, 5)
    }

    func testOpenPanelReadsProcessTable() {
        let reader = RecordingProcessReader()
        reader.processes = [
            OtherCodexProcess(processID: 4242, worktreeName: "wt-alpha", elapsed: "00:12"),
        ]
        let store = makeStore(processReader: reader)
        store.setPanelPresented(true)
        XCTAssertEqual(reader.callCount, 1)
        XCTAssertEqual(store.otherCodexProcesses, reader.processes)

        store.refreshStatuses()
        XCTAssertEqual(reader.callCount, 2)
        XCTAssertEqual(store.otherCodexProcesses, reader.processes)
    }

    func testClosedPanelStillNotifiesWhenStatusFileChanges() throws {
        let box = NotificationBox()
        let reader = RecordingProcessReader()
        let store = makeStore(processReader: reader, notificationBox: box)
        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"running","updated_at":"2026-08-19T20:00:00Z"}"#
        )
        store.refreshStatuses()
        XCTAssertEqual(box.drafts, [])
        XCTAssertEqual(reader.callCount, 0)

        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"done","updated_at":"2026-08-19T20:01:00Z"}"#
        )
        store.refreshStatuses()
        XCTAssertEqual(reader.callCount, 0)
        XCTAssertEqual(box.drafts.count, 1)
        XCTAssertEqual(box.drafts.first?.category, .taskComplete)
        XCTAssertEqual(box.drafts.first?.title, "任务结束")
        XCTAssertEqual(store.lines.first?.state, .done)
    }

    func testUnchangedStatusFileIsNotReparsed() throws {
        let cache = LineStatusFileCache()
        let store = makeStore(cache: cache)
        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"running","updated_at":"2026-08-19T20:00:00Z"}"#
        )
        store.refreshStatuses()
        XCTAssertEqual(cache.parseCount, 1)
        XCTAssertEqual(store.lines.first?.slug, "alpha")

        store.refreshStatuses()
        store.refreshStatuses()
        XCTAssertEqual(cache.parseCount, 1)

        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"waiting_relay","updated_at":"2026-08-19T20:02:00Z"}"#
        )
        store.refreshStatuses()
        XCTAssertEqual(cache.parseCount, 2)
        XCTAssertEqual(store.lines.first?.state, .waitingRelay)
    }

    func testIdleSixtySecondsWithoutOpeningPanelDoesNotPublish() throws {
        let reader = RecordingProcessReader()
        let store = makeStore(processReader: reader)
        try write(
            "codex-babysitter-alpha.status.json",
            #"{"slug":"alpha","state":"running","updated_at":"2026-08-19T20:00:00Z"}"#
        )
        store.refreshStatuses()
        let count = countPublications(store) {
            for _ in 0..<12 {
                store.refreshStatuses()
            }
        }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(reader.callCount, 0)
        XCTAssertEqual(AIOConstants.statusRefreshInterval, 5)
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
                "CORTEX_INPUT_STATUS_URL": "http://127.0.0.1:1/status",
            ],
            lineStatusCache: cache,
            otherCodexProcessReader: { ids in processReader.read(ids) },
            notificationSendHandler: notificationBox.map { box in
                { draft in box.drafts.append(draft) }
            }
        )
    }

    private func countPublications(_ store: SentinelStore, _ body: () -> Void) -> Int {
        var count = 0
        let cancellable = store.objectWillChange.sink { count += 1 }
        body()
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
