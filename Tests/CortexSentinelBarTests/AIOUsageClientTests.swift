import Foundation
import XCTest
@testable import CortexSentinelBar

final class AIOUsageClientTests: XCTestCase {
    func testSubscriptionUsageParsesPlanAndExpiry() throws {
        let usage = try usageFixture(named: "usage-subscription")

        XCTAssertEqual(usage.remaining, 42.5)
        XCTAssertEqual(usage.unit, "USD")
        XCTAssertEqual(usage.planName, "CodeX Plus 季度")
        XCTAssertEqual(usage.expiresAt, "2026-09-30T00:00:00Z")
        XCTAssertEqual(usage.isValid, true)
    }

    func testMeteredUsageAllowsMissingExpiry() throws {
        let usage = try usageFixture(named: "usage-metered")

        XCTAssertEqual(usage.remaining, 7.25)
        XCTAssertEqual(usage.planName, "钱包余额")
        XCTAssertNil(usage.expiresAt)
        XCTAssertTrue(usage.isValid)
    }

    func testUsageURLStripsOnlyTrailingV1() {
        XCTAssertEqual(
            AIOUsageClient.usageURL(baseURL: "https://aio.fixture.test/v1")?.absoluteString,
            "https://aio.fixture.test/v1/usage"
        )
        XCTAssertEqual(
            AIOUsageClient.usageURL(baseURL: "https://aio.fixture.test/api/v1/")?.absoluteString,
            "https://aio.fixture.test/api/v1/usage"
        )
    }

    func testRequestUsesBearerAndFifteenSecondTimeout() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData(named: "usage-metered"))
        let target = makeTarget(id: 1, enabled: true)
        let status = await AIOUsageClient(
            requestLoader: loader
        ).fetch(target: target)

        guard case let .success(usage) = status else {
            return XCTFail("usage request did not decode")
        }
        XCTAssertEqual(usage.remaining, 7.25)
        XCTAssertEqual(loader.lastRequest?.timeoutInterval, AIOConstants.usageTimeout)
        XCTAssertEqual(
            loader.lastRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-provider-fixture"
        )
        XCTAssertNil(loader.lastRequest?.value(forHTTPHeaderField: "x-aio-provider-id"))
    }

    func testFetchAllSkipsDisabledTargets() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData(named: "usage-metered"))
        let statuses = await AIOUsageClient(
            requestLoader: loader
        ).fetchAll(
            targets: [
                makeTarget(id: 24, enabled: true),
                makeTarget(id: 19, enabled: false),
            ]
        )

        XCTAssertNotNil(statuses[24])
        XCTAssertNil(statuses[19])
        XCTAssertEqual(loader.recordedURLs, ["https://provider-24.fixture.test/v1/usage"])
    }

    func testFetchAllIncludesDisabledProvidersWhenRequested() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData(named: "usage-metered"))
        let statuses = await AIOUsageClient(
            requestLoader: loader
        ).fetchAll(
            targets: [
                makeTarget(id: 24, enabled: true),
                makeTarget(id: 19, enabled: false),
            ],
            includeDisabled: true
        )

        XCTAssertNotNil(statuses[24])
        XCTAssertNotNil(statuses[19])
        XCTAssertEqual(
            Set(loader.recordedURLs),
            Set([
                "https://provider-19.fixture.test/v1/usage",
                "https://provider-24.fixture.test/v1/usage",
            ])
        )
    }

    func testFetchSequentialFollowsGivenOrderAndWaitsHalfSecondBetweenRows() async throws {
        let loader = RecordingUsageLoader(data: try fixtureData(named: "usage-metered"))
        let sleeper = RecordingSleeper()
        let statuses = await AIOUsageClient(
            requestLoader: loader,
            sleep: { await sleeper.sleep($0) }
        ).fetchSequential(
            targets: [
                makeTarget(id: 3, enabled: true),
                makeTarget(id: 1, enabled: true),
                makeTarget(id: 2, enabled: false),
            ]
        )

        XCTAssertEqual(statuses.count, 3)
        XCTAssertEqual(
            loader.recordedURLs,
            [
                "https://provider-3.fixture.test/v1/usage",
                "https://provider-1.fixture.test/v1/usage",
                "https://provider-2.fixture.test/v1/usage",
            ]
        )
        XCTAssertEqual(sleeper.intervals, [0.5, 0.5])
        XCTAssertEqual(AIOConstants.sequentialUsageInterval, 0.5)
    }

    func testOfficialUsageDecodesWeeklyWindowFromCurrentGatewaySchema() throws {
        let data = Data(
            """
            {
              "email": "fixture@example.test",
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 4,
                  "limit_window_seconds": 604800,
                  "reset_at": 1786163959
                }
              }
            }
            """.utf8
        )

        let usage = try XCTUnwrap(AIOUsageClient.decodeUsage(data))
        XCTAssertEqual(usage.weeklyUsedPercentage, 4)
        XCTAssertEqual(usage.planName, "pro")
        XCTAssertEqual(usage.email, "fixture@example.test")
        XCTAssertTrue(usage.isValid)
    }

    private func usageFixture(named name: String) throws -> AIOUsage {
        guard let usage = AIOUsageClient.decodeUsage(try fixtureData(named: name)) else {
            throw FixtureError.invalidFixture
        }
        return usage
    }

    private func fixtureData(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw FixtureError.invalidFixture
        }
        return try Data(contentsOf: url)
    }

    private func makeTarget(
        id: Int64,
        enabled: Bool
    ) -> AIOUsageTarget {
        AIOUsageTarget(
            id: id,
            baseURL: "https://provider-\(id).fixture.test/v1",
            apiKey: "sk-provider-fixture",
            enabled: enabled,
        )
    }

    private enum FixtureError: Error {
        case invalidFixture
    }
}

private final class RecordingUsageLoader: AIOUsageRequestLoading, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var lastRequest: URLRequest? {
        lock.withLock {
            requests.last
        }
    }

    var recordedURLs: [String] {
        lock.withLock {
            requests.compactMap { $0.url?.absoluteString }
        }
    }

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            requests.append(request)
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
