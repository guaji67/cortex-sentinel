import Foundation
import XCTest
@testable import CortexSentinelBar

final class OfficialUsageTests: XCTestCase {
    func testClientReadsCodexAuthAndClassifiesPrimarySevenDayWindowAsWeekly() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_786_100_000)
        let loader = RecordingOfficialUsageLoader(
            data: Data(
                """
                {
                  "email": "fixture@example.test",
                  "plan_type": "pro",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 4,
                      "limit_window_seconds": 604800,
                      "reset_at": 1786620000
                    }
                  }
                }
                """.utf8
            )
        )
        let authURL = try makeAuthFixture()
        defer { try? FileManager.default.removeItem(at: authURL.deletingLastPathComponent()) }

        let snapshot = try await OfficialUsageClient(
            authURL: authURL,
            endpoint: URL(string: "https://chatgpt.example.test/backend-api/wham/usage")!,
            requestLoader: loader,
            now: { checkedAt }
        ).fetch()

        XCTAssertEqual(snapshot.weeklyRemainingPercentage, 96)
        XCTAssertEqual(snapshot.weeklyWindow?.limitWindowSeconds, 604800)
        XCTAssertNil(snapshot.fiveHourWindow)
        XCTAssertEqual(snapshot.planDisplayName, "GPT PRO")
        XCTAssertEqual(snapshot.accountLabel, "Codex 登录号：fixture")
        XCTAssertEqual(snapshot.checkedAt, checkedAt)
        XCTAssertFalse(snapshot.stale)
        XCTAssertEqual(loader.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(
            loader.lastRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-access-token"
        )
        XCTAssertEqual(
            loader.lastRequest?.value(forHTTPHeaderField: "ChatGPT-Account-Id"),
            "fixture-account-id"
        )
        XCTAssertEqual(loader.lastRequest?.timeoutInterval, OfficialUsageConstants.requestTimeout)
    }

    func testClientKeepsFiveHourAndWeeklyWindowsDistinct() async throws {
        let loader = RecordingOfficialUsageLoader(
            data: Data(
                """
                {
                  "email": "fixture@example.test",
                  "plan_type": "plus",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 12.5,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 600
                    },
                    "secondary_window": {
                      "used_percent": 25,
                      "limit_window_seconds": 604800,
                      "reset_after_seconds": 3600
                    }
                  }
                }
                """.utf8
            )
        )
        let authURL = try makeAuthFixture()
        defer { try? FileManager.default.removeItem(at: authURL.deletingLastPathComponent()) }

        let snapshot = try await OfficialUsageClient(
            authURL: authURL,
            requestLoader: loader,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).fetch()

        XCTAssertEqual(snapshot.fiveHourWindow?.remainingPercentage, 87.5)
        XCTAssertEqual(snapshot.weeklyRemainingPercentage, 75)
        XCTAssertEqual(snapshot.weeklyResetDate, Date(timeIntervalSince1970: 4_600))
    }

    func testFailedRefreshPreservesLastSuccessAndMarksItStale() {
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        let failedAt = Date(timeIntervalSince1970: 1_300)
        let success = OfficialUsageSnapshot(
            planType: "pro",
            email: "fixture@example.test",
            weeklyWindow: OfficialUsageWindow(
                usedPercentage: 4,
                limitWindowSeconds: 604800,
                resetAt: 2_000,
                resetAfterSeconds: nil
            ),
            fiveHourWindow: nil,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil,
            refreshFailedAt: nil
        )

        let stale = success.preservingLastSuccess(
            errorMessage: "GPT 官方接口暂不可达",
            failedAt: failedAt
        )

        XCTAssertEqual(stale.weeklyRemainingPercentage, 96)
        XCTAssertEqual(stale.checkedAt, checkedAt)
        XCTAssertEqual(stale.planType, "pro")
        XCTAssertEqual(stale.email, "fixture@example.test")
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.refreshFailedAt, failedAt)
        XCTAssertEqual(stale.errorMessage, "GPT 官方接口暂不可达")
    }

    func testAutomaticRefreshRequiresTenMinutes() {
        let lastAttemptAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            OfficialUsageRefreshPolicy.shouldStart(
                reason: .automatic,
                lastAttemptAt: lastAttemptAt,
                isInFlight: false,
                now: lastAttemptAt.addingTimeInterval(599.9)
            )
        )
        XCTAssertTrue(
            OfficialUsageRefreshPolicy.shouldStart(
                reason: .automatic,
                lastAttemptAt: lastAttemptAt,
                isInFlight: false,
                now: lastAttemptAt.addingTimeInterval(600)
            )
        )
        XCTAssertEqual(OfficialUsageConstants.automaticRefreshInterval, 600)
    }

    func testMetadataLabelsCheckedAtAsUpdateTime() {
        let checkedAt = Date(timeIntervalSince1970: 1_786_100_000)

        XCTAssertEqual(
            OfficialUsagePresentation.metadata(
                planDisplayName: "GPT PRO",
                checkedAt: checkedAt,
                stale: false
            ),
            "GPT PRO · \(SentinelTimeFormat.clockTime(checkedAt)) 更新"
        )
        XCTAssertEqual(
            OfficialUsagePresentation.metadata(
                planDisplayName: nil,
                checkedAt: nil,
                stale: true
            ),
            "已过期"
        )
    }

    func testManualRefreshUsesFiveSecondDebounceAndBlocksConcurrentRequest() {
        let lastAttemptAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            OfficialUsageRefreshPolicy.shouldStart(
                reason: .manual,
                lastAttemptAt: lastAttemptAt,
                isInFlight: false,
                now: lastAttemptAt.addingTimeInterval(4.9)
            )
        )
        XCTAssertTrue(
            OfficialUsageRefreshPolicy.shouldStart(
                reason: .manual,
                lastAttemptAt: lastAttemptAt,
                isInFlight: false,
                now: lastAttemptAt.addingTimeInterval(5)
            )
        )
        XCTAssertFalse(
            OfficialUsageRefreshPolicy.shouldStart(
                reason: .manual,
                lastAttemptAt: nil,
                isInFlight: true,
                now: lastAttemptAt
            )
        )
        XCTAssertEqual(OfficialUsageConstants.manualRefreshThrottle, 5)
    }

    func testPanelOpenRefreshUsesThirtySecondFreshnessGate() {
        let lastAttemptAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            OfficialUsageRefreshPolicy.shouldStart(
                reason: .panelOpen,
                lastAttemptAt: lastAttemptAt,
                isInFlight: false,
                now: lastAttemptAt.addingTimeInterval(29)
            )
        )
        XCTAssertTrue(
            OfficialUsageRefreshPolicy.shouldStart(
                reason: .panelOpen,
                lastAttemptAt: lastAttemptAt,
                isInFlight: false,
                now: lastAttemptAt.addingTimeInterval(31)
            )
        )
        XCTAssertFalse(
            OfficialUsageRefreshPolicy.shouldStart(
                reason: .panelOpen,
                lastAttemptAt: lastAttemptAt,
                isInFlight: true,
                now: lastAttemptAt.addingTimeInterval(31)
            )
        )
        XCTAssertEqual(AIOConstants.panelOpenFreshnessInterval, 30)
        XCTAssertEqual(OfficialUsageConstants.automaticRefreshInterval, 600)
    }

    func testAuthReaderRejectsMissingAccessToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexSentinel-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"account_id":"fixture"}}"#.utf8).write(to: url)

        XCTAssertThrowsError(try CodexAuthReader.read(at: url)) { error in
            XCTAssertEqual(error as? CodexAuthReaderError, .invalid)
        }
    }

    private func makeAuthFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexSentinel-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("auth.json")
        try Data(
            """
            {
              "tokens": {
                "access_token": "fixture-access-token",
                "account_id": "fixture-account-id",
                "refresh_token": "fixture-refresh-token"
              }
            }
            """.utf8
        ).write(to: url)
        return url
    }
}

private final class RecordingOfficialUsageLoader: OfficialUsageRequestLoading, @unchecked Sendable {
    private let data: Data
    private let statusCode: Int
    private let lock = NSLock()
    private var request: URLRequest?

    var lastRequest: URLRequest? {
        lock.withLock { request }
    }

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            self.request = request
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
