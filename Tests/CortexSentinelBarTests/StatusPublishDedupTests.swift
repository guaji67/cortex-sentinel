import Foundation
import XCTest
@testable import CortexSentinelBar

@MainActor
final class StatusPublishDedupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        suiteName = "status-publish-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "status-publish-\(UUID().uuidString)",
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

    func testUnchangedDiskEmitsZeroPublicationsAcrossRepeatedRefreshes() async {
        let store = makeStore()
        let count = await countPublications(store) {
            for _ in 0..<5 {
                await store.refreshStatuses()
            }
        }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.lines, [])
        XCTAssertEqual(store.aio, .unconfigured)
        XCTAssertEqual(store.otherCodexProcesses, [])
        XCTAssertEqual(store.lineRegistry, .empty)
        XCTAssertEqual(store.inputStatus, .empty)
        XCTAssertEqual(store.channelStatus, .missing)
        XCTAssertEqual(store.unclaimedTerminals, [])
    }

    func testLinesChangePublishesOnceAndKeepsNewValue() async throws {
        let store = makeStore()
        let count = await countPublications(store) {
            try? write(
                "codex-babysitter-alpha.status.json",
                #"{"slug":"alpha","state":"running","updated_at":"2026-08-19T20:00:00Z"}"#
            )
            await store.refreshStatuses()
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.lines.map(\.slug), ["alpha"])
        XCTAssertEqual(store.lines.first?.state, .running)
        XCTAssertEqual(store.unclaimedTerminals, [])
        let second = await countPublications(store) { await store.refreshStatuses() }
        XCTAssertEqual(second, 0, "同一份状态文件再刷不应再发")
    }

    func testAIOChangePublishesOnceAndKeepsNewValue() async {
        let store = makeStore()
        let next = fixtureAIO()
        let count = await countPublications(store) {
            store.apply(
                lines: store.lines,
                aio: next,
                otherCodexProcesses: store.otherCodexProcesses,
                lineRegistry: store.lineRegistry,
                inputStatus: store.inputStatus
            )
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.aio, next)
        XCTAssertEqual(store.lines, [])
        let again = await countPublications(store) {
            store.apply(
                lines: store.lines,
                aio: next,
                otherCodexProcesses: store.otherCodexProcesses,
                lineRegistry: store.lineRegistry,
                inputStatus: store.inputStatus
            )
        }
        XCTAssertEqual(again, 0)
    }

    func testOtherCodexProcessesChangePublishesOnceAndKeepsNewValue() async throws {
        let box = OtherCodexProcessBox()
        let store = makeStore(
            otherCodexProcessReader: { _ in box.value },
            extraEnvironment: ["CORTEX_INPUT_STATUS_URL": "http://127.0.0.1:1/status"]
        )
        await store.setPanelPresented(true)
        try await Task.sleep(nanoseconds: 80_000_000)
        let next = [
            OtherCodexProcess(processID: 4242, worktreeName: "wt-alpha", elapsed: "00:12"),
        ]
        let count = await countPublications(store) {
            box.value = next
            await store.refreshStatuses()
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.otherCodexProcesses, next)
        XCTAssertEqual(store.lines, [])
        let again = await countPublications(store) { await store.refreshStatuses() }
        XCTAssertEqual(again, 0)
    }

    func testLineRegistryChangePublishesOnceAndKeepsNewValue() async throws {
        let store = makeStore()
        let count = await countPublications(store) {
            try? write("codex-line-registry.json", registryJSON(slug: "alpha", label: "甲线"))
            await store.refreshStatuses()
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.lineRegistry.lines.map(\.slug), ["alpha"])
        XCTAssertEqual(store.lineRegistry.lines.first?.labelZH, "甲线")
        XCTAssertEqual(store.lines, [])
        XCTAssertEqual(store.unclaimedTerminals, [])
        let again = await countPublications(store) { await store.refreshStatuses() }
        XCTAssertEqual(again, 0)
    }

    func testInputStatusChangePublishesOnceAndKeepsNewValue() async {
        let store = makeStore()
        let next = fixtureInputStatus()
        let count = await countPublications(store) {
            store.apply(
                lines: store.lines,
                aio: store.aio,
                otherCodexProcesses: store.otherCodexProcesses,
                lineRegistry: store.lineRegistry,
                inputStatus: next
            )
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.inputStatus, next)
        XCTAssertEqual(store.aio, .unconfigured)
        let again = await countPublications(store) {
            store.apply(
                lines: store.lines,
                aio: store.aio,
                otherCodexProcesses: store.otherCodexProcesses,
                lineRegistry: store.lineRegistry,
                inputStatus: next
            )
        }
        XCTAssertEqual(again, 0)
    }

    func testChannelStatusChangePublishesOnceAndKeepsNewValue() async throws {
        let store = makeStore()
        let count = await countPublications(store) {
            try? write("channel-status.json", channelJSON(running: 2))
            await store.refreshStatuses()
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.channelStatus.grok.status, .alive)
        XCTAssertEqual(store.channelStatus.grok.running, 2)
        XCTAssertEqual(store.channelStatus.codex.status, .degraded)
        XCTAssertEqual(store.lines, [])
        let again = await countPublications(store) { await store.refreshStatuses() }
        XCTAssertEqual(again, 0)
    }

    func testUnclaimedTerminalsChangePublishesOnceAndKeepsNewValue() async throws {
        let stamp = isoNow()
        try write(
            "codex-babysitter-done-line.status.json",
            "{\"slug\":\"done-line\",\"state\":\"done\",\"updated_at\":\"\(stamp)\",\"exit_code\":0}"
        )
        let store = makeStore()
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.map(\.slug), ["done-line"])
        XCTAssertEqual(store.unclaimedTerminals.map(\.slug), ["done-line"])

        let count = await countPublications(store) {
            try? write(
                "line-terminal-ack.json",
                "{\"acks\":{\"done-line\":{\"state\":\"done\",\"updated_at\":\"\(stamp)\"}}}"
            )
            await store.refreshStatuses()
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.unclaimedTerminals, [])
        XCTAssertEqual(store.lines.map(\.slug), ["done-line"])
        let again = await countPublications(store) { await store.refreshStatuses() }
        XCTAssertEqual(again, 0)
    }

    func testOfficialUsageChangePublishesOnceAndKeepsNewValue() async {
        let store = makeStore()
        let next = OfficialUsageSnapshot(
            planType: "plus",
            email: "plus@example.test",
            weeklyWindow: nil,
            fiveHourWindow: nil,
            checkedAt: Date(timeIntervalSince1970: 1_787_000_000),
            stale: false,
            errorMessage: nil,
            refreshFailedAt: nil
        )
        let count = await countPublications(store) {
            store.setOfficialUsageIfChanged(next)
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.officialUsage, next)
        let again = await countPublications(store) { store.setOfficialUsageIfChanged(next) }
        XCTAssertEqual(again, 0)
    }

    func testMultipleSourcesInOneRefreshPublishOnlyChangedCount() async throws {
        let store = makeStore()
        let count = await countPublications(store) {
            try? write(
                "codex-babysitter-alpha.status.json",
                #"{"slug":"alpha","state":"running","updated_at":"2026-08-19T20:00:00Z"}"#
            )
            try? write("codex-line-registry.json", registryJSON(slug: "alpha", label: "甲线"))
            try? write("channel-status.json", channelJSON(running: 1))
            await store.refreshStatuses()
        }
        XCTAssertEqual(count, 3, "三条数据源变了，应发合并后的 3 次，不是 0 也不是整表 7 次")
        XCTAssertEqual(store.lines.map(\.slug), ["alpha"])
        XCTAssertEqual(store.lineRegistry.lines.first?.labelZH, "甲线")
        XCTAssertEqual(store.channelStatus.grok.running, 1)
        XCTAssertEqual(store.unclaimedTerminals, [])
        XCTAssertEqual(store.aio, .unconfigured)
        XCTAssertEqual(store.inputStatus, .empty)
        XCTAssertEqual(store.otherCodexProcesses, [])
    }

    private func makeStore(
        otherCodexProcessReader: @escaping @Sendable (Set<Int>) -> [OtherCodexProcess] = { _ in [] },
        extraEnvironment: [String: String] = [:]
    ) -> SentinelStore {
        var environment = [
            "CORTEX_SENTINEL_WATCH_DIR": root.path,
            "CORTEX_DATA_ROOT": root.path,
            "CORTEX_INPUT_STATUS_URL": "http://127.0.0.1:1/status",
            "CORTEX_CODEX_AUTH_PATH": root.appendingPathComponent("missing-auth.json").path,
            "CORTEX_AIO_DB_PATH": root.appendingPathComponent("missing-aio.db").path,
        ]
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        return SentinelStore(
            defaults: defaults,
            environment: environment,
            otherCodexProcessReader: otherCodexProcessReader
        )
    }

    private func countPublications(_ store: SentinelStore, _ body: () async -> Void) async -> Int {
        await countStoreChanges(store, during: body)
    }

    private func write(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: root.appendingPathComponent(name))
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private func registryJSON(slug: String, label: String) -> String {
        """
        [
          {
            "engine": "codex",
            "slug": "\(slug)",
            "label_zh": "\(label)",
            "dispatcher_zh": "测试派工",
            "registered_at": 1784823993
          }
        ]
        """
    }

    private func channelJSON(running: Int) -> String {
        """
        {
          "generated_at": "2026-08-18T23:40:00Z",
          "channels": {
            "grok": {"status": "alive", "evidence": "在跑", "running": \(running)},
            "codex": {"status": "degraded", "evidence": "不通"}
          }
        }
        """
    }

    private func fixtureAIO() -> AIOSnapshot {
        AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .direct,
            providers: [],
            lastHitProviderID: 12,
            lastHitProviderName: "fixture-aio",
            readAt: Date(timeIntervalSince1970: 1_787_000_000),
            errorMessage: nil
        )
    }

    private func fixtureInputStatus() -> InputStatusSnapshot {
        InputStatusSnapshot(
            allOK: true,
            probes: [
                InputStatusProbe(
                    model: "gpt-5.6-sol",
                    uptimePercentage: 99.5,
                    isOK: true,
                    latencyMilliseconds: 120
                ),
            ],
            readAt: Date(timeIntervalSince1970: 1_787_000_000),
            errorMessage: nil
        )
    }
}

private final class OtherCodexProcessBox: @unchecked Sendable {
    var value: [OtherCodexProcess] = []
}
