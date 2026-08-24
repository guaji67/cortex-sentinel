import Foundation
import SQLite3
import XCTest
@testable import CortexSentinelBar

/// 面板分区隔离的回归：打开面板一次，各分区各失效几次。
///
/// 旧世界（ObservableObject + 单个 1798 行 body）的口径是 objectWillChange
/// 次数 = 整面板重算次数，Falcon 用真实数据量到冷开 22 次、热开 3 次。
/// @Observable + 分区拆分后没有「整面板失效」这回事了，新口径是**逐分区**
/// 用 withObservationTracking 数「该分区读集内的属性被写了几次」：
///   · legacy 读集（原 22 个 @Published 面）= 与旧数字直接可比的总量
///   · 各分区读集 = 该分区 body 会重算的次数上限
/// 这套读集必须与 SentinelMenuSections.swift 里各分区实际读的属性一致；
/// 改分区读什么，这里要跟着改。
@MainActor
final class PanelSectionIsolationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var databaseURL: URL!
    private var configURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        suiteName = "section-isolation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "section-isolation-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = try makeDatabaseFixture()
        configURL = root.appendingPathComponent("config.toml")
        try """
        model_provider = "aio"
        [model_providers.aio]
        base_url = "http://127.0.0.1:37123/v1"
        experimental_bearer_token = "sk-fixture"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        // 一条已登记的活跃线 + 通道状态，凑齐线列表分区的真实输入。
        let stamp = ISO8601DateFormatter().string(from: Date())
        try #"{"slug":"iso-alpha","state":"running","updated_at":"\#(stamp)","rollout_age_s":12.0}"#
            .write(
                to: root.appendingPathComponent("codex-babysitter-iso-alpha.status.json"),
                atomically: true,
                encoding: .utf8
            )
        try """
        [
          {"engine": "codex", "slug": "iso-alpha", "label_zh": "隔离甲线",
           "dispatcher_zh": "隔离测试", "registered_at": 1784823993}
        ]
        """.write(
            to: root.appendingPathComponent("codex-line-registry.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "generated_at": "2026-08-24T20:00:00Z",
          "channels": {
            "grok": {"status": "alive", "evidence": "在跑", "running": 1},
            "codex": {"status": "alive", "evidence": "在跑", "running": 1}
          }
        }
        """.write(
            to: root.appendingPathComponent("channel-status.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let root {
            try? fileManager.removeItem(at: root)
        }
        if let databaseURL {
            try? fileManager.removeItem(at: databaseURL)
        }
    }

    // MARK: - 分区读集（与 SentinelMenuSections.swift 一一对应）

    private func sectionCounters(_ store: SentinelStore) -> [(name: String, counter: StoreChangeCounter)] {
        [
            ("header", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.paths
                _ = store.lineGroups
                _ = store.boardWindow
                _ = store.localHost
            }),
            ("packaging", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.packagingProgress
            }),
            ("channel", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.channelStatus
                _ = store.lineGroups
                _ = store.localHost
            }),
            ("service", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.inputStatus
            }),
            ("balances", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.aio
                _ = store.officialUsage
                _ = store.isOfficialUsageRefreshing
                _ = store.isOfficialUsageRefreshCoolingDown
            }),
            ("dispatch", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.lineGroups
                _ = store.boardWindow
                _ = store.relayAttribution
                _ = store.localHost
                _ = store.paths
            }),
            ("automatic", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.lineGroups
                _ = store.boardWindow
                _ = store.otherCodexProcesses
                _ = store.relayAttribution
                _ = store.paths
            }),
            ("history", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.boardWindow
                _ = store.localHost
            }),
            ("backgroundJobs", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.backgroundJobs
                _ = store.backgroundJobRows
                _ = store.backgroundJobsExpanded
                _ = store.backgroundJobMessages
                _ = store.backgroundJobOperations
            }),
            ("footer", StoreChangeCounter { [weak store] in
                guard let store else { return }
                _ = store.aio
            }),
        ]
    }

    /// 冷开：状态 / 登记 / 通道 / 3 个中转账号余额逐个回来 / Input 探针失败 /
    /// 官方额度失败，全套第一次落地。断言的是隔离结构：余额分区吃掉逐账号
    /// 上屏（1 次基础快照 + 每账号 1 次），线列表分区只因线数据和归因切片
    /// 各失效一次，历史 / 后台任务 / 打包分区一次都不动。
    func testColdOpenInvalidatesBalancesPerProviderButLineSectionsStayQuiet() async throws {
        let store = makeStore(loader: RecordingUsageLoader(
            data: try fixtureData(),
            delayNanoseconds: 30_000_000
        ))
        let counters = sectionCounters(store)
        let legacy = StoreChangeCounter(reading: StoreSurfaces.legacyPanelRead(store))

        await store.setPanelPresented(true)
        try await waitUntil {
            store.aio.providers.allSatisfy { $0.usage.hasDisplayableBalanceNumber }
        }
        try await waitUntil { store.officialUsage.errorMessage != nil }

        counters.forEach { $0.counter.stop() }
        legacy.stop()
        var byName: [String: Int] = [:]
        for (name, counter) in counters {
            byName[name] = counter.count
        }
        print("SECTION_ISOLATION_COLD legacy=\(legacy.count) sections=\(byName.sorted(by: { $0.key < $1.key }))")

        let providerCount = 3
        // 余额分区：1 次 AIO 基础快照 + 每账号一次冷启动填数 + 1 次官方额度落定。
        // 允许比精确值少（网络时序里攒批），但绝不能超。
        XCTAssertLessThanOrEqual(byName["balances"]!, providerCount + 2, "余额分区失效次数超出逐账号上屏的预算")
        XCTAssertGreaterThanOrEqual(byName["balances"]!, 2, "余额分区至少要看到基础快照和官方额度")
        // 线列表分区：分组一次 + 归因切片一次，与账号数量无关。
        XCTAssertLessThanOrEqual(byName["dispatch"]!, 3, "线列表分区不许跟着逐账号余额刷新失效")
        XCTAssertLessThanOrEqual(byName["automatic"]!, 3)
        XCTAssertLessThanOrEqual(byName["header"]!, 2)
        XCTAssertLessThanOrEqual(byName["channel"]!, 2)
        XCTAssertLessThanOrEqual(byName["service"]!, 1)
        XCTAssertEqual(byName["history"]!, 0, "历史分区在冷开时一次都不该动")
        XCTAssertEqual(byName["backgroundJobs"]!, 0)
        XCTAssertEqual(byName["packaging"]!, 0)
        XCTAssertLessThanOrEqual(byName["footer"]!, providerCount + 1)
        // 与旧口径可比的总量：旧世界 = 整面板重算次数（Falcon 真机冷开 22）。
        // 新世界这个数字只是「所有面写入次数」，不再有任何 view 全量重算。
        XCTAssertLessThanOrEqual(legacy.count, providerCount + 8)
    }

    /// 热开：数字都在缓存里，关面板 31 秒后再开。旧世界整面板还要重算 3 次
    /// （aio 读取时间戳 / Input 探针 / 官方额度各一次）；新世界这三次只落在
    /// 余额和 Input 分区，线列表分区 0 次。
    func testWarmReopenKeepsLineSectionsAtZero() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let store = makeStore(
            loader: RecordingUsageLoader(data: try fixtureData()),
            clock: clock
        )
        await store.setPanelPresented(true)
        try await waitUntil {
            store.aio.providers.allSatisfy { $0.usage.hasDisplayableBalanceNumber }
        }
        try await waitUntil { store.officialUsage.errorMessage != nil }
        await store.setPanelPresented(false)
        clock.now = clock.now.addingTimeInterval(31)

        let counters = sectionCounters(store)
        let legacy = StoreChangeCounter(reading: StoreSurfaces.legacyPanelRead(store))

        await store.setPanelPresented(true)
        try await Task.sleep(nanoseconds: 250_000_000)

        counters.forEach { $0.counter.stop() }
        legacy.stop()
        var byName: [String: Int] = [:]
        for (name, counter) in counters {
            byName[name] = counter.count
        }
        print("SECTION_ISOLATION_WARM legacy=\(legacy.count) sections=\(byName.sorted(by: { $0.key < $1.key }))")

        XCTAssertEqual(byName["dispatch"]!, 0, "热开时线列表分区必须一次都不失效")
        XCTAssertEqual(byName["automatic"]!, 0)
        XCTAssertEqual(byName["header"]!, 0)
        XCTAssertEqual(byName["channel"]!, 0)
        XCTAssertEqual(byName["history"]!, 0)
        XCTAssertEqual(byName["backgroundJobs"]!, 0)
        XCTAssertEqual(byName["packaging"]!, 0)
        XCTAssertLessThanOrEqual(byName["balances"]!, 3, "热开余额分区最多 aio 时间戳 + 官方额度 + Input 各一次")
        XCTAssertLessThanOrEqual(legacy.count, 4, "旧口径下热开是 3 次整面板重算；新总量不该更差")
    }

    /// 滚动挂起：手在滑时后台刷新不上屏（数据攒在闸里），手停自动放行，
    /// 同一面后到的覆盖先到的。
    func testScrollGateDefersRefreshPublishUntilQuiescence() async throws {
        let store = makeStore(loader: RecordingUsageLoader(data: try fixtureData()))
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.map(\.slug), ["iso-alpha"])

        store.scrollPublishGate.noteScrollActivity()

        // 滚动中改状态文件并刷新：不许上屏。
        let stamp = ISO8601DateFormatter().string(from: Date())
        try #"{"slug":"iso-alpha","state":"done","updated_at":"\#(stamp)","exit_code":0}"#
            .write(
                to: root.appendingPathComponent("codex-babysitter-iso-alpha.status.json"),
                atomically: true,
                encoding: .utf8
            )
        let duringScroll = await countStoreChanges(store) {
            await store.refreshStatuses()
            store.scrollPublishGate.noteScrollActivity()
        }
        XCTAssertEqual(duringScroll, 0, "滚动期间后台刷新不许发布")
        XCTAssertEqual(store.lines.first?.state, .running, "闸里攒着，店面还是旧值")
        XCTAssertEqual(store.scrollPublishGate.pendingSurfaceCountForTests, 1)

        // 手停 220ms 之后自动放行。
        try await waitUntil(timeout: 2) {
            store.lines.first?.state == .done
        }
        XCTAssertFalse(store.scrollPublishGate.isScrolling)
        XCTAssertEqual(store.scrollPublishGate.pendingSurfaceCountForTests, 0)
    }

    /// 面板关闭立即放行攒着的数据，不让它过夜。
    func testClosingPanelFlushesPendingPublishes() async throws {
        let store = makeStore(loader: RecordingUsageLoader(data: try fixtureData()))
        await store.setPanelPresented(true)
        try await waitUntil { !store.lines.isEmpty }

        store.scrollPublishGate.noteScrollActivity()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try #"{"slug":"iso-alpha","state":"done","updated_at":"\#(stamp)","exit_code":0}"#
            .write(
                to: root.appendingPathComponent("codex-babysitter-iso-alpha.status.json"),
                atomically: true,
                encoding: .utf8
            )
        await store.refreshStatuses()
        XCTAssertEqual(store.lines.first?.state, .running)

        await store.setPanelPresented(false)
        XCTAssertEqual(store.lines.first?.state, .done, "关面板必须立即放行攒着的上屏")
    }

    // MARK: - fixtures

    private func makeStore(
        loader: AIOUsageRequestLoading,
        clock: TestClock = TestClock(now: Date(timeIntervalSince1970: 1_000))
    ) -> SentinelStore {
        SentinelStore(
            defaults: defaults,
            environment: [
                "CORTEX_SENTINEL_WATCH_DIR": root.path,
                "CORTEX_DATA_ROOT": root.path,
                "CORTEX_AIO_DB_PATH": databaseURL.path,
                "CORTEX_CODEX_CONFIG_PATH": configURL.path,
                "CORTEX_CODEX_AUTH_PATH": root.appendingPathComponent("missing-auth.json").path,
                "CORTEX_INPUT_STATUS_URL": "http://127.0.0.1:1/status",
            ],
            otherCodexProcessReader: { _ in [] },
            now: { clock.now },
            aioUsageClient: AIOUsageClient(requestLoader: loader)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for condition", file: file, line: line)
    }

    private func fixtureData() throws -> Data {
        guard let url = Bundle.module.url(forResource: "usage-metered", withExtension: "json") else {
            throw IsolationFixtureError.invalidFixture
        }
        return try Data(contentsOf: url)
    }

    private func makeDatabaseFixture() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("section-isolation-\(UUID().uuidString).db")
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            throw IsolationFixtureError.sqlite(openCode)
        }
        defer {
            sqlite3_close_v2(database)
        }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let sql = """
        CREATE TABLE providers (
            id INTEGER PRIMARY KEY,
            cli_key TEXT NOT NULL,
            name TEXT NOT NULL,
            base_url TEXT NOT NULL,
            api_key_plaintext TEXT NOT NULL,
            enabled INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            note TEXT NOT NULL
        );
        CREATE TABLE default_route_providers (
            cli_key TEXT NOT NULL,
            provider_id INTEGER NOT NULL,
            sort_order INTEGER NOT NULL
        );
        CREATE TABLE provider_circuit_breakers (
            provider_id INTEGER PRIMARY KEY,
            state TEXT NOT NULL,
            failure_count INTEGER NOT NULL
        );
        CREATE TABLE request_logs (
            id INTEGER PRIMARY KEY,
            cli_key TEXT NOT NULL,
            status INTEGER,
            attempts_json TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        INSERT INTO providers VALUES
            (1, 'codex', 'alpha', 'https://aio.fixture.test/alpha/v1', 'KKKKKKKKKKKKKKKKKKKK', 1, 10, 'fixture alpha'),
            (2, 'codex', 'beta', 'https://aio.fixture.test/beta/v1', 'KKKKKKKKKKKKKKKKKKKK', 0, 20, 'fixture beta'),
            (3, 'codex', 'gamma', 'https://aio.fixture.test/gamma/v1', 'KKKKKKKKKKKKKKKKKKKK', 1, 30, 'fixture gamma');
        INSERT INTO default_route_providers VALUES
            ('codex', 3, 0),
            ('codex', 1, 1),
            ('codex', 2, 2);
        """
        let code = sql.withCString {
            sqlite3_exec(database, $0, nil, nil, &errorMessage)
        }
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard code == SQLITE_OK else {
            throw IsolationFixtureError.sqlite(code)
        }
        return url
    }

    private enum IsolationFixtureError: Error {
        case sqlite(Int32)
        case invalidFixture
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class RecordingUsageLoader: AIOUsageRequestLoading, @unchecked Sendable {
    private let data: Data
    private let delayNanoseconds: UInt64

    init(data: Data, delayNanoseconds: UInt64 = 0) {
        self.data = data
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
