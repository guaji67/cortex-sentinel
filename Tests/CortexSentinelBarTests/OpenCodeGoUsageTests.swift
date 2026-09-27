import Foundation
import XCTest
@testable import CortexSentinelBar

/// OpenCode Go 额度：两种返回写法解析、状态非 ok、缺字段、key 三来源先后、
/// 请求头、key 不进任何文本、行文案与状态点。
final class OpenCodeGoUsageTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_790_488_000)

    /// 官方实测返回形态（2026-09-27 抓的真实结构）：percent 已用、resetsAt ISO。
    private func makePayload() -> Data {
        Data(
            """
            {
              "usage": {
                "rolling": {"status": "ok", "percent": 12.5, "resetsAt": "2026-09-27T06:50:23.370Z"},
                "weekly": {"status": "ok", "percent": 47, "resetsAt": "2026-09-28T00:00:00.000Z"},
                "monthly": {"status": "ok", "percent": 3, "resetsAt": "2026-10-27T01:38:48.000Z"}
              }
            }
            """.utf8
        )
    }

    // MARK: - 解析

    func testParseMapsThreeWindowsAndResetDates() throws {
        let windows = try OpenCodeGoUsageClient.parseWindows(data: makePayload(), now: checkedAt)
        XCTAssertEqual(windows.rolling?.status, "ok")
        XCTAssertEqual(windows.rolling?.percentUsed, 12.5)
        XCTAssertEqual(windows.rolling?.remainingPercentage, 87.5)
        XCTAssertEqual(
            windows.rolling?.resetAt,
            Date(timeIntervalSince1970: 1_790_491_823.37)
        )
        XCTAssertEqual(windows.weekly?.percentUsed, 47)
        XCTAssertEqual(windows.weekly?.remainingPercentage, 53)
        XCTAssertEqual(windows.weekly?.resetAt, Date(timeIntervalSince1970: 1_790_553_600))
        XCTAssertEqual(windows.monthly?.percentUsed, 3)
        XCTAssertEqual(windows.monthly?.remainingPercentage, 97)
        XCTAssertEqual(windows.monthly?.resetAt, Date(timeIntervalSince1970: 1_793_065_128))
    }

    /// 社区写法：reset_in_sec 相对秒数，按查询时刻换算；resetInSec 驼峰也认。
    func testParseAcceptsResetInSecVariant() throws {
        let payload = Data(
            """
            {"usage":{"rolling":{"status":"ok","percent":50,"reset_in_sec":3600},
                      "weekly":{"status":"ok","percent":10,"resetInSec":86400}}}
            """.utf8
        )
        let windows = try OpenCodeGoUsageClient.parseWindows(data: payload, now: checkedAt)
        XCTAssertEqual(windows.rolling?.resetAt, checkedAt.addingTimeInterval(3600))
        XCTAssertEqual(windows.weekly?.resetAt, checkedAt.addingTimeInterval(86_400))
        XCTAssertEqual(windows.rolling?.remainingPercentage, 50)
        XCTAssertNil(windows.monthly)
    }

    func testRemainingNeverGoesBelowZeroOrAboveHundred() throws {
        let payload = Data(
            """
            {"usage":{"rolling":{"status":"ok","percent":130,"resetsAt":"2026-09-27T06:50:23Z"}}}
            """.utf8
        )
        let windows = try OpenCodeGoUsageClient.parseWindows(data: payload, now: checkedAt)
        XCTAssertEqual(windows.rolling?.remainingPercentage, 0)

        let stringPercent = Data(
            """
            {"usage":{"rolling":{"status":"ok","percent":"25","resetsAt":"2026-09-27T06:50:23Z"}}}
            """.utf8
        )
        let stringWindows = try OpenCodeGoUsageClient.parseWindows(data: stringPercent, now: checkedAt)
        XCTAssertEqual(stringWindows.rolling?.percentUsed, 25)
        XCTAssertEqual(stringWindows.rolling?.remainingPercentage, 75)
    }

    // MARK: - 状态非 ok

    func testNonOkStatusMarksSnapshotAndDotRed() throws {
        let payload = Data(
            """
            {"usage":{"rolling":{"status":"exhausted","percent":80,"reset_in_sec":600},
                      "weekly":{"status":"ok","percent":10}}}
            """.utf8
        )
        let snapshot = makeSnapshot(from: payload)
        XCTAssertTrue(snapshot.statusNotOK)
        XCTAssertEqual(snapshot.nonOKStatuses, ["exhausted"])
        XCTAssertEqual(
            SentinelBalancesSection.openCodeGoDotSignal(snapshot: snapshot),
            SentinelTheme.Colors.danger
        )

        // status 缺失不当异常，也不标红。
        let noStatus = makeSnapshot(from: Data(#"{"usage":{"rolling":{"percent":50,"reset_in_sec":60}}}"#.utf8))
        XCTAssertFalse(noStatus.statusNotOK)
        XCTAssertTrue(noStatus.nonOKStatuses.isEmpty)
        // 状态非 ok 但数字照样显示，行文案不顶替三列。
        XCTAssertNil(noStatus.rowStatusText)
    }

    func testStatusOKIsNotFlagged() {
        XCTAssertTrue(OpenCodeGoWindow(status: "ok", percentUsed: 1, resetAt: nil).statusIsNotOK == false)
        XCTAssertTrue(OpenCodeGoWindow(status: nil, percentUsed: nil, resetAt: nil).statusIsNotOK == false)
        XCTAssertTrue(OpenCodeGoWindow(status: "  OK  ", percentUsed: nil, resetAt: nil).statusIsNotOK == false)
        XCTAssertTrue(OpenCodeGoWindow(status: "degraded", percentUsed: nil, resetAt: nil).statusIsNotOK)
    }

    // MARK: - 缺字段 / 坏数据

    func testMissingFieldsStayNilAndRowSaysUnknown() throws {
        // 段缺 percent：不是 0%，是 nil → 行显示「不知道」。
        let payload = Data(
            """
            {"usage":{"rolling":{"status":"ok","resetsAt":"2026-09-27T06:50:23.370Z"}}}
            """.utf8
        )
        let snapshot = makeSnapshot(from: payload)
        XCTAssertNil(snapshot.rolling?.percentUsed)
        XCTAssertNil(snapshot.rolling?.remainingPercentage)
        XCTAssertFalse(snapshot.hasDisplayableNumber)
        XCTAssertEqual(snapshot.rowStatusText, OpenCodeGoUsageConstants.unknownText)
        XCTAssertEqual(OpenCodeGoUsageConstants.unknownText, "不知道")

        // 整个 usage 缺失 = 格式变化，抛 invalidResponse。
        XCTAssertThrowsError(
            try OpenCodeGoUsageClient.parseWindows(data: Data("{}".utf8), now: checkedAt)
        ) { error in
            XCTAssertEqual(error as? OpenCodeGoUsageClientError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try OpenCodeGoUsageClient.parseWindows(data: Data("<html>".utf8), now: checkedAt)
        ) { error in
            XCTAssertEqual(error as? OpenCodeGoUsageClientError, .invalidResponse)
        }

        // 空 usage 对象：三段全缺，不炸，行显示「不知道」。
        let empty = makeSnapshot(from: Data(#"{"usage":{}}"#.utf8))
        XCTAssertFalse(empty.hasDisplayableNumber)
        XCTAssertEqual(empty.rowStatusText, OpenCodeGoUsageConstants.unknownText)

        // 首次取数没回来：「等待查询」。
        XCTAssertEqual(OpenCodeGoUsageSnapshot.waiting.rowStatusText, BalanceSectionPresentation.queryingStatusText)
        // 有数字：行不给文案，走三列。
        XCTAssertNil(makeSnapshot(from: makePayload()).rowStatusText)
    }

    func testFailedFetchKeepsPreviousNumbers() async {
        let good = makeSnapshot(from: makePayload())
        let previous = OpenCodeGoUsageSnapshot.merged(previous: nil, fresh: good, now: checkedAt)

        let client = OpenCodeGoUsageClient(
            endpoint: URL(string: "https://opencode.example.test/zen/go/v1/usage")!,
            requestLoader: StatusLoader(status: 500, body: Data())
        )
        let fresh = await client.fetch(key: "oc_fixture_key_aaaaaaaaaaaaaaaaaa", now: checkedAt)
        XCTAssertEqual(fresh.errorMessage, OpenCodeGoUsageClientError.invalidResponse.userMessage)

        let merged = OpenCodeGoUsageSnapshot.merged(previous: previous, fresh: fresh, now: checkedAt)
        XCTAssertEqual(merged.rolling?.remainingPercentage, 87.5)
        XCTAssertEqual(merged.weekly?.remainingPercentage, 53)
        XCTAssertTrue(merged.stale)
        XCTAssertEqual(merged.errorMessage, fresh.errorMessage)
        // 上一轮的数字还在，行照旧走三列。
        XCTAssertNil(merged.rowStatusText)

        // 首轮就失败：没有旧数字可保，行显示「不知道」。
        let firstFailure = OpenCodeGoUsageSnapshot.merged(previous: OpenCodeGoUsageSnapshot.waiting, fresh: fresh, now: checkedAt)
        XCTAssertEqual(firstFailure.rowStatusText, OpenCodeGoUsageConstants.unknownText)
    }

    // MARK: - key 三个来源的先后

    func testKeySourcesOrderEnvThenEnvThenDotEnvFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oc-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let envFile = tempDir.appendingPathComponent(".env")
        try Data("OPENCODE_GO_API_KEY=oc_envfile_bbbbbbbbbbbbbbbbbb\n".utf8).write(to: envFile)

        // 1. OPENCODE_GO_API_KEY 环境变量最优先。
        XCTAssertEqual(
            OpenCodeGoKeyDetector.detect(
                environment: [
                    "OPENCODE_GO_API_KEY": "oc_env_aaaaaaaaaaaaaaaaaa",
                    "OPENCODE_API_KEY": "oc_env2_cccccccccccccccccc",
                ],
                envFileURL: envFile
            ),
            "oc_env_aaaaaaaaaaaaaaaaaa"
        )
        // 2. 退到 OPENCODE_API_KEY。
        XCTAssertEqual(
            OpenCodeGoKeyDetector.detect(
                environment: ["OPENCODE_API_KEY": "oc_env2_cccccccccccccccccc"],
                envFileURL: envFile
            ),
            "oc_env2_cccccccccccccccccc"
        )
        // 3. 环境变量都没有才读 .env 的 OPENCODE_GO_API_KEY 行。
        XCTAssertEqual(
            OpenCodeGoKeyDetector.detect(environment: [:], envFileURL: envFile),
            "oc_envfile_bbbbbbbbbbbbbbbbbb"
        )
        // 环境变量太短不算数，落到 .env。
        XCTAssertEqual(
            OpenCodeGoKeyDetector.detect(
                environment: ["OPENCODE_GO_API_KEY": "short"],
                envFileURL: envFile
            ),
            "oc_envfile_bbbbbbbbbbbbbbbbbb"
        )
        // 都没有 → nil（面板整行不占位）。
        XCTAssertNil(OpenCodeGoKeyDetector.detect(environment: [:], envFileURL: nil))
        XCTAssertNil(OpenCodeGoKeyDetector.detect(environment: [:], envFileURL: tempDir.appendingPathComponent("missing.env")))
    }

    func testDotEnvParsingSkipsCommentsAndOtherKeys() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oc-key2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let envFile = tempDir.appendingPathComponent(".env")
        try Data(
            """
            # 注释行
            OTHER_API_KEY=oc_should_not_pick_this_aaaaaaa
            OPENCODE_GO_API_KEY="oc_quoted_dddddddddddddddd"
            """
            .utf8
        ).write(to: envFile)
        XCTAssertEqual(
            OpenCodeGoKeyDetector.detect(environment: [:], envFileURL: envFile),
            "oc_quoted_dddddddddddddddd"
        )
    }

    /// 数据根解析：CORTEX_DATA_ROOT 显式覆盖优先，XCTest 不碰真数据根。
    func testDefaultEnvFileURLResolution() {
        XCTAssertEqual(
            OpenCodeGoKeyDetector.defaultEnvFileURL(
                environment: ["CORTEX_DATA_ROOT": "/fixture-data"],
                testCaseClassLoaded: true
            )?.path,
            "/fixture-data/.env"
        )
        XCTAssertNil(
            OpenCodeGoKeyDetector.defaultEnvFileURL(
                environment: [:],
                processEnvironment: ["XCTestConfigurationFilePath": "/xctest"],
                testCaseClassLoaded: false
            )
        )
        XCTAssertNil(
            OpenCodeGoKeyDetector.defaultEnvFileURL(
                environment: [:],
                processEnvironment: [:],
                homeDirectory: nil,
                testCaseClassLoaded: false
            )
        )
        XCTAssertEqual(
            OpenCodeGoKeyDetector.defaultEnvFileURL(
                environment: [:],
                processEnvironment: [:],
                homeDirectory: URL(fileURLWithPath: "/home/fixture", isDirectory: true),
                testCaseClassLoaded: false
            )?.path,
            "/home/fixture/CortexData/.env"
        )
    }

    // MARK: - 请求头

    func testRequestCarriesSentinelHeadersAndBearer() async throws {
        let endpoint = URL(string: "https://opencode.example.test/zen/go/v1/usage")!
        var captured: URLRequest?
        let probe = ProbeLoader { request in
            captured = request
            return (
                self.makePayload(),
                HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = OpenCodeGoUsageClient(endpoint: endpoint, requestLoader: probe)
        let snapshot = await client.fetch(key: "oc_fixture_key_aaaaaaaaaaaaaaaaaa", now: checkedAt)
        XCTAssertNil(snapshot.errorMessage)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oc_fixture_key_aaaaaaaaaaaaaaaaaa")
        // User-Agent 是哨兵自己的名字和版本，不是通用库名。
        let userAgent = try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(userAgent, OpenCodeGoUsageConstants.userAgent)
        XCTAssertEqual(userAgent, "CortexSentinel/1.0")
        XCTAssertFalse(userAgent.lowercased().contains("urlsession"))
        XCTAssertFalse(userAgent.lowercased().contains("alamofire"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), OpenCodeGoUsageConstants.sessionHeaderValue)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session")?.isEmpty, false)
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testUnauthorizedAndGarbageBodyBecomeFailureSnapshots() async {
        let endpoint = URL(string: "https://opencode.example.test/zen/go/v1/usage")!
        let key = "oc_fixture_key_aaaaaaaaaaaaaaaaaa"

        let unauthorized = await OpenCodeGoUsageClient(
            endpoint: endpoint,
            requestLoader: StatusLoader(status: 401, body: Data())
        ).fetch(key: key, now: checkedAt)
        XCTAssertEqual(unauthorized.errorMessage, OpenCodeGoUsageClientError.unauthorized.userMessage)

        let garbage = await OpenCodeGoUsageClient(
            endpoint: endpoint,
            requestLoader: StatusLoader(status: 200, body: Data("<html>nope</html>".utf8))
        ).fetch(key: key, now: checkedAt)
        XCTAssertEqual(garbage.errorMessage, OpenCodeGoUsageClientError.invalidResponse.userMessage)
        XCTAssertFalse(garbage.hasDisplayableNumber)
        XCTAssertEqual(garbage.rowStatusText, OpenCodeGoUsageConstants.unknownText)
    }

    // MARK: - key 不进任何文本

    func testKeyNeverAppearsInErrorMessagesOrSnapshotText() async {
        let key = "oc_super_secret_zzzzzzzzzzzzzzzzzzzzz"
        let endpoint = URL(string: "https://opencode.example.test/zen/go/v1/usage")!
        let failures = await withTaskGroup(of: OpenCodeGoUsageSnapshot.self) { group in
            for status in [401, 403, 500, 200] {
                group.addTask {
                    await OpenCodeGoUsageClient(
                        endpoint: endpoint,
                        requestLoader: StatusLoader(
                            status: status,
                            body: status == 200 ? Data("<html>".utf8) : Data()
                        )
                    ).fetch(key: key, now: self.checkedAt)
                }
            }
            var collected: [OpenCodeGoUsageSnapshot] = []
            for await snapshot in group {
                collected.append(snapshot)
            }
            return collected
        }

        for error in [
            OpenCodeGoUsageClientError.unauthorized,
            .timedOut,
            .network,
            .invalidResponse,
        ] {
            XCTAssertFalse(error.userMessage.contains(key))
            XCTAssertFalse(error.userMessage.contains(String(key.prefix(6))))
        }
        for snapshot in failures {
            let texts = [
                snapshot.errorMessage ?? "",
                snapshot.rowStatusText ?? "",
                String(describing: snapshot),
            ]
            for text in texts {
                XCTAssertFalse(text.contains(key), "key 泄进了文本：\(text)")
                XCTAssertFalse(text.contains(String(key.prefix(6))))
            }
        }
        // 快照结构里根本不存 key（fetch 只把它放进请求头）。
        XCTAssertFalse(String(describing: OpenCodeGoUsageSnapshot.waiting).contains(key))
    }

    // MARK: - 重置时刻文案

    func testResetTextCombinesRelativeAndBeijingClock() {
        let now = Date(timeIntervalSince1970: 1_790_488_000)
        XCTAssertEqual(OpenCodeGoResetText.relative(to: now.addingTimeInterval(30 * 60), now: now), "30 分钟后")
        XCTAssertEqual(OpenCodeGoResetText.relative(to: now.addingTimeInterval(2.4 * 3600), now: now), "2 小时后")
        XCTAssertEqual(OpenCodeGoResetText.relative(to: now.addingTimeInterval(3 * 86_400), now: now), "3 天后")
        // 过了重置点。
        XCTAssertEqual(OpenCodeGoResetText.relative(to: now.addingTimeInterval(-60), now: now), "已到重置时间")
        // 北京钟点：UTC 2026-09-27T06:50:23Z = 北京 14:50。
        let resetAt = Date(timeIntervalSince1970: 1_790_491_823.37)
        XCTAssertEqual(OpenCodeGoResetText.beijingClock(resetAt), "9/27 14:50")
        // now 到 resetAt 差 3823 秒 ≈ 1 小时（四舍五入）；备注列放不下
        // 「北京」前缀，时区标在卡片副标题。
        XCTAssertEqual(
            OpenCodeGoResetText.resetNote(resetAt: resetAt, now: now),
            "1 小时后 · 9/27 14:50"
        )
    }

    // MARK: - 行状态点

    func testDotSignalFollowsProviderThresholds() {
        // 状态点沿用余额区通用档位：5h 剩 15% 黄、剩 0.5% 红、正常绿、没数据灰。
        XCTAssertEqual(
            SentinelBalancesSection.openCodeGoDotSignal(snapshot: makeSnapshot(from: Data(
                #"{"usage":{"rolling":{"status":"ok","percent":85,"reset_in_sec":600}}}"#.utf8
            ))),
            SentinelTheme.Colors.warning
        )
        XCTAssertEqual(
            SentinelBalancesSection.openCodeGoDotSignal(snapshot: makeSnapshot(from: Data(
                #"{"usage":{"rolling":{"status":"ok","percent":99.5,"reset_in_sec":600}}}"#.utf8
            ))),
            SentinelTheme.Colors.danger
        )
        XCTAssertEqual(
            SentinelBalancesSection.openCodeGoDotSignal(snapshot: makeSnapshot(from: makePayload())),
            SentinelTheme.Colors.success
        )
        XCTAssertEqual(
            SentinelBalancesSection.openCodeGoDotSignal(snapshot: .waiting),
            SentinelTheme.Colors.secondaryForeground
        )
        // status 非 ok 压过一切：哪怕数字看着还多也红。
        XCTAssertEqual(
            SentinelBalancesSection.openCodeGoDotSignal(snapshot: makeSnapshot(from: Data(
                #"{"usage":{"rolling":{"status":"limited","percent":1,"reset_in_sec":600}}}"#.utf8
            ))),
            SentinelTheme.Colors.danger
        )
    }

    // MARK: - helpers

    private func makeSnapshot(from payload: Data) -> OpenCodeGoUsageSnapshot {
        let windows = try! OpenCodeGoUsageClient.parseWindows(data: payload, now: checkedAt)
        return OpenCodeGoUsageSnapshot(
            rolling: windows.rolling,
            weekly: windows.weekly,
            monthly: windows.monthly,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil
        )
    }

    /// 抓请求头的假 loader。
    private struct ProbeLoader: OpenCodeGoRequestLoading {
        let handler: (URLRequest) -> (Data, URLResponse)

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            handler(request)
        }
    }

    /// 固定状态码 + body 的假 loader。
    private struct StatusLoader: OpenCodeGoRequestLoading {
        let status: Int
        let body: Data

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            (
                body,
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }
}
