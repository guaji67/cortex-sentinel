import Foundation
import SQLite3
import XCTest
@testable import CortexSentinelBar

final class AIODataReaderTests: XCTestCase {
    func testReadOnlyDatabasePreservesRouteOrderCircuitAndLastHit() throws {
        let fixture = try makeDatabaseFixture()
        let manifest = try writeTemporary(
            contents: #"{"enabled":true}"#,
            fileExtension: "json"
        )
        let config = try writeTemporary(
            contents: """
            model_provider = "aio"
            [model_providers.aio]
            base_url = "http://127.0.0.1:37123/v1"
            experimental_bearer_token = "sk-fixture"
            """,
            fileExtension: "toml"
        )
        defer {
            removeTemporary(fixture)
            removeTemporary(manifest)
            removeTemporary(config)
        }

        let snapshot = AIODataReader.read(
            databaseURL: fixture,
            manifestURL: manifest,
            configURL: config
        )

        XCTAssertEqual(snapshot.sourceState, .available)
        XCTAssertTrue(snapshot.gatewayEnabled)
        XCTAssertEqual(snapshot.routeMode, .aggregate)
        XCTAssertEqual(snapshot.providers.map(\.id), [3, 1, 2])
        XCTAssertEqual(snapshot.providers.first?.name, "gamma")
        XCTAssertEqual(snapshot.providers.first?.circuitState, .open)
        XCTAssertEqual(snapshot.providers.first?.failureCount, 4)
        XCTAssertEqual(snapshot.providers.last?.enabled, false)
        XCTAssertEqual(snapshot.providers[1].baseURL, "https://aio.fixture.test/alpha/v1")
        XCTAssertEqual(snapshot.lastHitProviderID, 1)
        XCTAssertEqual(snapshot.lastHitProviderName, "alpha")

        let targets = AIODataReader.readUsageTargets(databaseURL: fixture)
        XCTAssertEqual(targets.map(\.id), [1, 2, 3])
        XCTAssertEqual(targets[0].baseURL, "https://aio.fixture.test/alpha/v1")
        XCTAssertEqual(targets[0].apiKey, String(repeating: "K", count: 20))
        XCTAssertFalse(targets[1].enabled)
    }

    func testConfigReaderOnlyUsesRootModelProvider() throws {
        let config = try writeTemporary(
            contents: """
            model_provider = "direct"
            [model_providers.aio]
            model_provider = "aio"
            """,
            fileExtension: "toml"
        )
        defer {
            removeTemporary(config)
        }

        XCTAssertEqual(
            CodexConfigReader.readModelProvider(at: config),
            "direct"
        )
    }

    func testConfigReaderLoadsAIOGatewayWithoutExposingProviderCredentials() throws {
        let config = try writeTemporary(
            contents: """
            model_provider = "aio"
            [model_providers.aio]
            base_url = "http://127.0.0.1:37123/v1"
            experimental_bearer_token = "sk-gateway-fixture"
            [model_providers.other]
            experimental_bearer_token = "sk-other"
            """,
            fileExtension: "toml"
        )
        defer {
            removeTemporary(config)
        }

        XCTAssertEqual(
            CodexConfigReader.readAIOGatewayConfiguration(at: config),
            AIOGatewayConfiguration(
                baseURL: "http://127.0.0.1:37123/v1",
                bearerToken: "sk-gateway-fixture"
            )
        )
    }

    func testMissingLegacyManifestStillReadsCurrentAIOData() throws {
        let fixture = try makeDatabaseFixture()
        let missingManifest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-missing-\(UUID().uuidString).json")
        let config = try writeTemporary(
            contents: """
            model_provider = "aio"
            [model_providers.aio]
            base_url = "http://127.0.0.1:37123/v1"
            experimental_bearer_token = "sk-fixture"
            """,
            fileExtension: "toml"
        )
        defer {
            removeTemporary(fixture)
            removeTemporary(config)
        }

        let snapshot = AIODataReader.read(
            databaseURL: fixture,
            manifestURL: missingManifest,
            configURL: config
        )

        XCTAssertEqual(snapshot.sourceState, .available)
        XCTAssertTrue(snapshot.gatewayEnabled)
        XCTAssertEqual(snapshot.routeMode, .aggregate)
        XCTAssertEqual(snapshot.providers.map(\.id), [3, 1, 2])
    }

    private func makeDatabaseFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
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
            """,
            database: database
        )

        let generatedKey = String(repeating: "K", count: 20)
        try execute(
            """
            INSERT INTO providers VALUES
                (1, 'codex', 'alpha', 'https://aio.fixture.test/alpha/v1', '\(generatedKey)', 1, 10, 'fixture alpha'),
                (2, 'codex', 'beta', 'https://aio.fixture.test/beta/v1', '\(generatedKey)', 0, 20, 'fixture beta'),
                (3, 'codex', 'gamma', 'https://aio.fixture.test/gamma/v1', '\(generatedKey)', 1, 30, 'fixture gamma');
            INSERT INTO default_route_providers VALUES
                ('codex', 3, 0),
                ('codex', 1, 1),
                ('codex', 2, 2);
            INSERT INTO provider_circuit_breakers VALUES
                (3, 'OPEN', 4);
            INSERT INTO request_logs VALUES
                (1, 'codex', 200,
                 '[{"provider_id":3,"provider_name":"gamma","outcome":"failure","status":503},{"provider_id":1,"provider_name":"alpha","outcome":"success","status":200}]',
                 100);
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

    private func writeTemporary(contents: String, fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-fixture-\(UUID().uuidString).\(fileExtension)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func removeTemporary(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private enum FixtureError: Error {
        case sqlite(Int32)
    }
}
