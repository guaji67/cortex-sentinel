import Combine
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

    func testOpeningPanelFetchesUsageInDisplayOrder() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData())
        let sleeper = RecordingSleeper()
        let store = makeStore(loader: loader, sleeper: sleeper)

        store.setPanelPresented(true)
        try await waitUntil { loader.recordedIDs.count == 3 }

        XCTAssertEqual(loader.recordedIDs, [3, 1, 2])
        XCTAssertEqual(sleeper.intervals, [0.5, 0.5])
        XCTAssertEqual(
            store.aio.providers.map(\.id),
            [3, 1, 2]
        )
        XCTAssertEqual(
            store.aio.providers.compactMap { $0.usage.usage?.remaining },
            [7.25, 7.25, 7.25]
        )
    }

    func testPanelOpenSkipsRefreshAt29SecondsAndRefreshesAt31() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData())
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let store = makeStore(loader: loader, clock: clock)

        store.setPanelPresented(true)
        try await waitUntil { loader.recordedIDs.count == 3 }
        XCTAssertEqual(loader.recordedIDs, [3, 1, 2])

        store.setPanelPresented(false)
        clock.now = clock.now.addingTimeInterval(29)
        store.setPanelPresented(true)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(loader.recordedIDs.count, 3)

        store.setPanelPresented(false)
        clock.now = Date(timeIntervalSince1970: 1_000).addingTimeInterval(31)
        store.setPanelPresented(true)
        try await waitUntil { loader.recordedIDs.count == 5 }
        XCTAssertEqual(loader.recordedIDs, [3, 1, 2, 3, 1])
    }

    func testRapidPanelToggleDoesNotStackDuplicateRequests() async throws {
        let loader = RecordingUsageLoader(
            data: try fixtureData(),
            delayNanoseconds: 120_000_000
        )
        let store = makeStore(loader: loader)

        store.setPanelPresented(true)
        store.setPanelPresented(false)
        store.setPanelPresented(true)
        store.setPanelPresented(false)
        store.setPanelPresented(true)
        try await waitUntil(timeout: 3) { loader.recordedIDs.count >= 3 }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(loader.recordedIDs, [3, 1, 2])
    }

    func testIdleSixtySecondsWithoutOpeningPanelDoesNotFetchUsageOrPublish() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData())
        let store = makeStore(loader: loader)

        store.refreshAIO(force: true, includeUsage: false)
        try await waitUntil { store.aio.sourceState == .available }
        XCTAssertEqual(loader.recordedIDs, [])

        let count = countPublications(store) {
            for _ in 0..<12 {
                store.refreshStatuses()
            }
            store.refreshAIO(force: false, includeUsage: false)
        }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(loader.recordedIDs, [])
        XCTAssertEqual(AIOConstants.aioRefreshInterval, 60)
        XCTAssertEqual(AIOConstants.statusRefreshInterval, 5)
    }

    func testSequentialRefreshShowsLoadingBeforeEachRowSettles() async throws {
        let loader = RecordingUsageLoader(
            data: try fixtureData(),
            delayNanoseconds: 80_000_000
        )
        let store = makeStore(loader: loader)
        var sawLoading = false
        let cancellable = store.$aio.sink { snapshot in
            if snapshot.providers.contains(where: {
                if case .loading = $0.usage { return true }
                return false
            }) {
                sawLoading = true
            }
        }

        store.setPanelPresented(true)
        try await waitUntil { loader.recordedIDs.count == 3 }
        try await waitUntil {
            store.aio.providers.allSatisfy {
                if case .success = $0.usage { return true }
                return false
            }
        }
        withExtendedLifetime(cancellable) {}
        XCTAssertTrue(sawLoading)
    }

    private func makeStore(
        loader: RecordingUsageLoader,
        sleeper: RecordingSleeper = RecordingSleeper(),
        clock: TestClock = TestClock(now: Date(timeIntervalSince1970: 1_000))
    ) -> SentinelStore {
        SentinelStore(
            defaults: defaults,
            environment: [
                "CORTEX_SENTINEL_WATCH_DIR": root.path,
                "CORTEX_AIO_DB_PATH": databaseURL.path,
                "CORTEX_CODEX_CONFIG_PATH": configURL.path,
                "CORTEX_CODEX_AUTH_PATH": root.appendingPathComponent("missing-auth.json").path,
                "CORTEX_INPUT_STATUS_URL": "http://127.0.0.1:1/status",
            ],
            otherCodexProcessReader: { _ in [] },
            now: { clock.now },
            aioUsageClient: AIOUsageClient(
                requestLoader: loader,
                sleep: { await sleeper.sleep($0) }
            )
        )
    }

    private func countPublications(_ store: SentinelStore, _ body: () -> Void) -> Int {
        var count = 0
        let cancellable = store.objectWillChange.sink { count += 1 }
        body()
        withExtendedLifetime(cancellable) {}
        return count
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

private final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var intervals: [TimeInterval] {
        lock.withLock { recorded }
    }

    func sleep(_ interval: TimeInterval) async {
        lock.withLock {
            recorded.append(interval)
        }
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

    private static func providerID(from url: URL?) -> Int64? {
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
