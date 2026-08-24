import Foundation
import SQLite3
import XCTest
@testable import CortexSentinelBar

@MainActor
final class PanelBalanceRefreshTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var databaseURL: URL!
    private var configURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        suiteName = "panel-balance-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "panel-balance-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = try makeDatabaseFixture()
        configURL = try writeTemporary(
            contents: """
            model_provider = "aio"
            [model_providers.aio]
            base_url = "http://127.0.0.1:37123/v1"
            experimental_bearer_token = "sk-fixture"
            """
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
        if let configURL {
            try? fileManager.removeItem(at: configURL)
        }
    }

    func testOpeningPanelFetchesUsageConcurrentlyAndAppliesEachResult() async throws {
        let loader = ConcurrentUsageLoader(
            data: try fixtureData(),
            expectedStarts: 3,
            finishDelayNanoseconds: [
                3: 20_000_000,
                1: 80_000_000,
                2: 160_000_000,
            ]
        )
        let store = makeStore(loader: loader)
        // 逐笔发布的取值序列（willSet 旧值 + 收尾现值，等价于旧 $aio.sink 序列）。
        let recorder = ValueSequenceRecorder(
            reading: { [weak store] () -> Int in
                guard let store else {
                    return -1
                }
                return store.aio.providers.filter {
                    if case .success = $0.usage { return true }
                    return false
                }.count
            },
            dedupBy: ==
        )

        await store.setPanelPresented(true)

        let successCounts = recorder.finish()
        XCTAssertEqual(Set(loader.recordedIDs), [1, 2, 3])
        XCTAssertEqual(loader.peakInFlight, 3)
        XCTAssertTrue(
            successCounts.contains(1),
            "每个结果应单独上屏，不能攒齐才从 0 跳到 3。实际：\(successCounts)"
        )
        XCTAssertTrue(
            successCounts.contains(2),
            "每个结果应单独上屏。实际：\(successCounts)"
        )
        XCTAssertEqual(successCounts.last, 3)
        XCTAssertEqual(store.aio.providers.map(\.id), [3, 1, 2])
        XCTAssertEqual(
            store.aio.providers.compactMap { $0.usage.usage?.remaining },
            [7.25, 7.25, 7.25]
        )
    }

    func testPanelOpenSkipsRefreshAt29SecondsAndRefreshesAt31() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData())
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let store = makeStore(loader: loader, clock: clock)

        await store.setPanelPresented(true)
        XCTAssertEqual(Set(loader.recordedIDs), [1, 2, 3])

        await store.setPanelPresented(false)
        clock.now = clock.now.addingTimeInterval(29)
        await store.setPanelPresented(true)
        XCTAssertEqual(loader.recordedIDs.count, 3)

        await store.setPanelPresented(false)
        clock.now = Date(timeIntervalSince1970: 1_000).addingTimeInterval(31)
        await store.setPanelPresented(true)
        XCTAssertEqual(loader.recordedIDs.count, 5)
        XCTAssertEqual(Set(loader.recordedIDs.prefix(3)), [1, 2, 3])
        XCTAssertEqual(Set(loader.recordedIDs.suffix(2)), [1, 3])
    }

    func testPanelOpenAfterThirtySecondsRefreshesEverySurface() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData())
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let store = makeStore(loader: loader, clock: clock)

        await store.setPanelPresented(true)
        let afterFirst = (
            status: store.statusDiskRefreshCountForTests,
            usage: store.aioUsageRefreshCountForTests,
            input: store.inputStatusRefreshCountForTests,
            official: store.officialUsageRefreshCountForTests
        )
        XCTAssertGreaterThanOrEqual(afterFirst.status, 1)
        XCTAssertEqual(afterFirst.usage, 1)
        XCTAssertEqual(afterFirst.input, 1)
        XCTAssertEqual(afterFirst.official, 1)

        await store.setPanelPresented(false)
        clock.now = clock.now.addingTimeInterval(29)
        await store.setPanelPresented(true)
        // 磁盘状态（含打包）每次打开都刷，不跟余额 30 秒闸绑死。
        XCTAssertEqual(store.statusDiskRefreshCountForTests, afterFirst.status + 1)
        XCTAssertEqual(store.aioUsageRefreshCountForTests, afterFirst.usage)
        XCTAssertEqual(store.inputStatusRefreshCountForTests, afterFirst.input)
        XCTAssertEqual(store.officialUsageRefreshCountForTests, afterFirst.official)

        await store.setPanelPresented(false)
        clock.now = Date(timeIntervalSince1970: 1_000).addingTimeInterval(31)
        await store.setPanelPresented(true)
        XCTAssertEqual(store.statusDiskRefreshCountForTests, afterFirst.status + 2)
        XCTAssertEqual(store.aioUsageRefreshCountForTests, afterFirst.usage + 1)
        XCTAssertEqual(store.inputStatusRefreshCountForTests, afterFirst.input + 1)
        XCTAssertEqual(store.officialUsageRefreshCountForTests, afterFirst.official + 1)
        XCTAssertFalse(store.lastStatusDiskReadWasOnMainThreadForTests)
    }

    func testRapidPanelToggleDoesNotStackDuplicateRequests() async throws {
        let loader = RecordingUsageLoader(
            data: try fixtureData(),
            delayNanoseconds: 40_000_000
        )
        let store = makeStore(loader: loader)

        await store.setPanelPresented(true)
        await store.setPanelPresented(false)
        await store.setPanelPresented(true)
        await store.setPanelPresented(false)
        await store.setPanelPresented(true)

        XCTAssertEqual(Set(loader.recordedIDs), [1, 2, 3])
        XCTAssertEqual(loader.recordedIDs.count, 3)
    }

    func testIdleSixtySecondsWithoutOpeningPanelDoesNotFetchUsageOrPublish() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData())
        let store = makeStore(loader: loader)

        await store.refreshAIO(force: true, includeUsage: false)
        try await waitUntil { store.aio.sourceState == .available }
        XCTAssertEqual(loader.recordedIDs, [])

        let count = await countPublications(store) {
            for _ in 0..<12 {
                await store.refreshStatuses()
            }
            await store.refreshAIO(force: false, includeUsage: false)
        }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(loader.recordedIDs, [])
        XCTAssertEqual(AIOConstants.aioRefreshInterval, 60)
        XCTAssertEqual(AIOConstants.statusRefreshInterval, 5)
    }

    /// Falcon 2026-08-24 原话：「你能不能不要把查询中那个状态给我显示出来？查询完了
    /// 直接更新数字不就好了吗」。这条替换了原来断言「刷新时要先闪一次 .loading」的
    /// 测试——那条断言的是被他否掉的行为，不是回归。
    func testRefreshNeverShowsLoadingState() async throws {
        let loader = RecordingUsageLoader(
            data: try fixtureData(),
            delayNanoseconds: 80_000_000
        )
        let store = makeStore(loader: loader)
        // 每笔发布都会以「下一笔的旧值」或「收尾现值」的身份被看到，
        // 任何一次写入过 .loading 的中间态都逃不过这份序列。
        let recorder = ValueSequenceRecorder(
            reading: { [weak store] () -> Bool in
                guard let store else {
                    return false
                }
                return store.aio.providers.contains(where: {
                    if case .loading = $0.usage { return true }
                    return false
                })
            },
            dedupBy: { _, _ in false }
        )

        await store.setPanelPresented(true)
        try await waitUntil { loader.recordedIDs.count == 3 }
        try await waitUntil {
            store.aio.providers.allSatisfy {
                if case .success = $0.usage { return true }
                return false
            }
        }
        let sawLoading = recorder.finish().contains(true)
        XCTAssertFalse(sawLoading, "刷新余额期间任何一行都不许进入查询中")
    }

    /// 他真正在骂的那个手感：面板已经有数字了，点开往下滑，刷新把整块面板连着刷好几次。
    /// 这条把它量化——已经有数字的那一轮刷新，整面板通知次数必须收敛到 1 次以内，
    /// 且过程中不许有任何一行把数字丢掉（丢数字会让余额块从展开塌成一行，
    /// 面板高度一缩一涨，滚动位置被夹回去，那就是「卡死」的来源）。
    func testRefreshWithExistingNumbersKeepsThemAndPublishesAtMostOnce() async throws {
        let loader = RecordingUsageLoader(
            data: try fixtureData(),
            delayNanoseconds: 40_000_000
        )
        let store = makeStore(loader: loader)

        await store.setPanelPresented(true)
        try await waitUntil {
            store.aio.providers.allSatisfy { $0.usage.hasDisplayableBalanceNumber }
        }

        let recorder = ValueSequenceRecorder(
            reading: { [weak store] () -> (loading: Bool, missingNumber: Bool) in
                guard let store else {
                    return (false, false)
                }
                let loading = store.aio.providers.contains(where: {
                    if case .loading = $0.usage { return true }
                    return false
                })
                let missing = store.aio.providers.contains(where: {
                    !$0.usage.hasDisplayableBalanceNumber
                })
                return (loading, missing)
            },
            dedupBy: { _, _ in false }
        )

        // 官方额度那条线自己也会发通知，先让它落定，这条测的是余额刷新那一段。
        try await Task.sleep(nanoseconds: 200_000_000)

        let publications = await countPublications(store) {
            await store.refreshAIO(
                force: true,
                includeUsage: true,
                bypassMinimumInterval: true
            )
        }
        let observed = recorder.finish()
        let sawLoading = observed.contains(where: \.loading)
        let sawNumberDisappear = observed.contains(where: \.missingNumber)

        XCTAssertFalse(sawLoading, "已经有数字了，刷新不许把行变成查询中")
        XCTAssertFalse(
            sawNumberDisappear,
            "刷新期间每一行都得保留上一次的数字，一行都不许空出来"
        )
        // 实测就是 1 次（余额数字本身没变，这一次来自快照的读取时间戳）。
        // 修之前同一段窗口是 4 次，而且那还没算被砍掉的 .loading 预刷新那一轮。
        XCTAssertLessThanOrEqual(
            publications,
            1,
            "已有数字的行必须攒到最后一次性换；实际发了 \(publications) 次整面板刷新"
        )
    }

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

    private func countPublications(_ store: SentinelStore, _ body: () async -> Void) async -> Int {
        await countStoreChanges(store, during: body)
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
            throw FixtureError.invalidFixture
        }
        return try Data(contentsOf: url)
    }

    private func makeDatabaseFixture() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("sentinel-aio-\(UUID().uuidString).db")
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            throw FixtureError.sqlite(openCode)
        }
        defer {
            sqlite3_close_v2(database)
        }

        try execute(
            """
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
            """,
            database: database
        )
        return url
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let code = sql.withCString {
            sqlite3_exec(database, $0, nil, nil, &errorMessage)
        }
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard code == SQLITE_OK else {
            throw FixtureError.sqlite(code)
        }
    }

    private func writeTemporary(contents: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "sentinel-config-\(UUID().uuidString).toml"
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private enum FixtureError: Error {
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

private final class ConcurrentUsageLoader: AIOUsageRequestLoading, @unchecked Sendable {
    private let data: Data
    private let expectedStarts: Int
    private let finishDelayNanoseconds: [Int64: UInt64]
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var started = 0
    private var inFlight = 0
    private var peak = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    var recordedIDs: [Int64] {
        lock.withLock {
            requests.compactMap { RecordingUsageLoader.providerID(from: $0.url) }
        }
    }

    var peakInFlight: Int {
        lock.withLock { peak }
    }

    init(
        data: Data,
        expectedStarts: Int,
        finishDelayNanoseconds: [Int64: UInt64]
    ) {
        self.data = data
        self.expectedStarts = expectedStarts
        self.finishDelayNanoseconds = finishDelayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            requests.append(request)
            started += 1
            inFlight += 1
            peak = max(peak, inFlight)
            if started >= expectedStarts {
                let waiters = startWaiters + [continuation]
                startWaiters.removeAll()
                lock.unlock()
                waiters.forEach { $0.resume() }
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
        let id = RecordingUsageLoader.providerID(from: request.url)
        if let id, let delay = finishDelayNanoseconds[id], delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        lock.withLock {
            inFlight -= 1
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

private final class RecordingUsageLoader: AIOUsageRequestLoading, @unchecked Sendable {
    private let data: Data
    private let delayNanoseconds: UInt64
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var recordedIDs: [Int64] {
        lock.withLock {
            requests.compactMap { request in
                Self.providerID(from: request.url)
            }
        }
    }

    init(data: Data, delayNanoseconds: UInt64 = 0) {
        self.data = data
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            requests.append(request)
        }
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

    static func providerID(from url: URL?) -> Int64? {
        guard let path = url?.path else {
            return nil
        }
        if path.contains("/gamma/") {
            return 3
        }
        if path.contains("/alpha/") {
            return 1
        }
        if path.contains("/beta/") {
            return 2
        }
        return nil
    }
}
