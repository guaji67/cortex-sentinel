import Foundation
import XCTest
@testable import CortexSentinelBar

/// GLM Coding Plan 额度：解析、双窗归类、key 识别与键池合并。
final class GLMUsageTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_788_471_000)

    private func makePayload() -> Data {
        // 2026-09-04 真机抓的返回形态：5 小时窗（unit 3, number 5）+ 周窗（unit 6, number 1）。
        Data(
            """
            {
              "code": 200,
              "msg": "操作成功",
              "data": {
                "limits": [
                  {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":2309,"remaining":9691,"percentage":19,"nextResetTime":1788471923332},
                  {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":60000,"currentValue":3594,"remaining":56406,"percentage":5,"nextResetTime":1788977984998}
                ],
                "level": "pro"
              },
              "success": true
            }
            """.utf8
        )
    }

    func testParseMapsFiveHourAndWeeklyWindows() throws {
        let part = try GLMUsageClient.parseQuotaPayload(data: makePayload())
        XCTAssertEqual(part.level, "pro")
        XCTAssertEqual(part.windows.fiveHour?.percentUsed, 19)
        XCTAssertEqual(part.windows.fiveHour?.usedPoints, 2309)
        XCTAssertEqual(part.windows.fiveHour?.totalPoints, 12000)
        XCTAssertEqual(
            part.windows.fiveHour?.resetAt,
            Date(timeIntervalSince1970: 1_788_471_923.332)
        )
        XCTAssertEqual(part.windows.weekly?.percentUsed, 5)
        XCTAssertEqual(part.windows.weekly?.usedPoints, 3594)
        XCTAssertEqual(part.windows.weekly?.totalPoints, 60000)
    }

    func testParseBalanceReadsCashAndSpend() throws {
        let part = try GLMUsageClient.parseBalancePayload(
            data: Data(
                """
                {"code":200,"msg":"操作成功","data":{"balance":21.692944000,"rechargeAmount":200.000000,"giveAmount":0.000000,"totalSpendAmount":178.307056000,"availableBalance":21.692944000,"frozenBalance":0E-9,"isKA":false},"success":true}
                """.utf8
            )
        )
        XCTAssertEqual(part.cash, 21.692944, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(part.spend), 178.307056, accuracy: 0.0001)
    }

    func testParseThrowsOnGarbagePayload() {
        XCTAssertThrowsError(
            try GLMUsageClient.parseQuotaPayload(data: Data("{}".utf8))
        ) { error in
            XCTAssertEqual(error as? GLMUsageClientError, .invalidResponse)
        }
    }

    func testParseTreatsTimeLimitOnlyAsNoPlanInsteadOfError() throws {
        // lite 体验卡到期后的真实返回：只剩 MCP 包的 TIME_LIMIT，没有积分窗。
        let part = try GLMUsageClient.parseQuotaPayload(
            data: Data(
                """
                {"code":200,"msg":"操作成功","data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":10,"remaining":90,"percentage":10,"nextResetTime":1790426002997}],"level":"lite"},"success":true}
                """.utf8
            )
        )
        XCTAssertEqual(part.level, "lite")
        XCTAssertNil(part.windows.fiveHour)
        XCTAssertNil(part.windows.weekly)
    }

    /// fetch 把订阅窗和现金余额两个接口的结果拼进同一行；
    /// 一边挂另一边照常显示，两边全挂才抛错。
    func testFetchMergesQuotaAndBalanceIndependently() async throws {
        let quotaBody = makePayload()
        let balanceBody = Data(
            """
            {"code":200,"msg":"操作成功","data":{"balance":21.69,"availableBalance":21.69,"totalSpendAmount":178.31},"success":true}
            """.utf8
        )
        let both = RoutedGLMLoader(quotaBody: quotaBody, balanceBody: balanceBody)
        let ok = try await GLMUsageClient.fetch(
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            endpoint: quotaURL,
            balanceEndpoint: balanceURL,
            requestLoader: both,
            now: checkedAt
        )
        XCTAssertEqual(ok.fiveHourWindow?.percentUsed, 19)
        XCTAssertEqual(try XCTUnwrap(ok.cashBalance), 21.69, accuracy: 0.0001)
        XCTAssertNil(ok.errorMessage)

        // 只挂订阅：显示现金余额，tooltip 带订阅报错。
        let quotaDown = RoutedGLMLoader(
            quotaStatus: 500,
            quotaBody: Data("{}".utf8),
            balanceBody: balanceBody
        )
        let balanceOnly = try await GLMUsageClient.fetch(
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            endpoint: quotaURL,
            balanceEndpoint: balanceURL,
            requestLoader: quotaDown,
            now: checkedAt
        )
        XCTAssertNil(balanceOnly.fiveHourWindow)
        XCTAssertEqual(try XCTUnwrap(balanceOnly.cashBalance), 21.69, accuracy: 0.0001)
        XCTAssertEqual(balanceOnly.errorMessage, GLMUsageClientError.invalidResponse.userMessage)
        XCTAssertEqual(balanceOnly.hasDisplayableNumber, true)

        // 全挂：抛错走 preserve。
        let allDown = RoutedGLMLoader(quotaStatus: 500, quotaBody: Data(), balanceStatus: 500, balanceBody: Data())
        do {
            _ = try await GLMUsageClient.fetch(
                key: "fixture-key-abcdefghijklmnop",
                label: "pro",
                endpoint: quotaURL,
                balanceEndpoint: balanceURL,
                requestLoader: allDown,
                now: checkedAt
            )
            XCTFail("应当抛错")
        } catch let error as GLMUsageClientError {
            XCTAssertEqual(error, .invalidResponse)
        }

        // 接口都通但什么数字都没有（用户加了把两头都空的 key）：
        // 返回全空账号不抛错，界面显示「未知」。
        let timeLimitOnly = Data(
            """
            {"code":200,"msg":"操作成功","data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":10,"percentage":10}],"level":"lite"},"success":true}
            """.utf8
        )
        let noData = RoutedGLMLoader(quotaBody: timeLimitOnly, balanceStatus: 404, balanceBody: Data())
        let unknown = try await GLMUsageClient.fetch(
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            endpoint: quotaURL,
            balanceEndpoint: balanceURL,
            requestLoader: noData,
            now: checkedAt
        )
        XCTAssertNil(unknown.fiveHourWindow)
        XCTAssertNil(unknown.cashBalance)
        XCTAssertNil(unknown.errorMessage)
        XCTAssertEqual(unknown.hasDisplayableNumber, false)
    }

    private var quotaURL: URL { URL(string: "https://quota.example.test/limit")! }
    private var balanceURL: URL { URL(string: "https://balance.example.test/report")! }

    /// 按 URL 分发响应的假 loader，模拟两个接口各自成功/失败。
    private struct RoutedGLMLoader: GLMUsageRequestLoading {
        var quotaStatus = 200
        var quotaBody: Data
        var balanceStatus = 200
        var balanceBody: Data

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let isBalance = request.url?.host == "balance.example.test"
            let status = isBalance ? balanceStatus : quotaStatus
            let body = isBalance ? balanceBody : quotaBody
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        }
    }

    func testClassifyWindowsFallsBackToPointsWhenUnitUnknown() {
        let smaller = GLMQuotaResponse.Limit(
            type: "CREDIT_LIMIT",
            unit: 9,
            number: nil,
            usage: 8000,
            currentValue: 100,
            percentage: 1.25,
            nextResetTime: nil
        )
        let larger = GLMQuotaResponse.Limit(
            type: "CREDIT_LIMIT",
            unit: 9,
            number: nil,
            usage: 50000,
            currentValue: 200,
            percentage: 0.4,
            nextResetTime: nil
        )
        let windows = GLMUsageClient.classifyWindows([larger, smaller])
        XCTAssertEqual(windows.fiveHour?.percentUsed, 1.25)
        XCTAssertEqual(windows.weekly?.percentUsed, 0.4)
    }

    func testEffectiveEntriesUnionsDetectedAndUserMinusRemoved() {
        let detected = [
            GLMKeyEntry(label: "pro", key: "key-pro-aaaaaaaaaaaaaaaaaaaa"),
            GLMKeyEntry(label: "lite", key: "key-lite-aaaaaaaaaaaaaaaaaaa"),
        ]
        let user = [
            GLMKeyEntry(label: "自定义", key: "key-manual-bbbbbbbbbbbbbbbbb"),
            // 与自动识别重复的 key 不重复显示。
            GLMKeyEntry(label: "重复", key: "key-pro-aaaaaaaaaaaaaaaaaaaa"),
        ]
        let effective = GLMKeyStore.effectiveEntries(
            detected: detected,
            user: user,
            removedKeys: ["key-lite-aaaaaaaaaaaaaaaaaaa"]
        )
        XCTAssertEqual(effective.map(\.label), ["pro", "自定义"])
    }

    func testDetectorReadsEnvKeyPoolProxyEnvAndDeduplicates() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let accountsURL = tempDir.appendingPathComponent("accounts.json")
        try Data(
            """
            {"lite": {"label": "Lite", "key": "key-lite-from-pool-aaaaaaaa"}, "pro": {"label": "pro", "key": "key-pro-from-pool-bbbbbbbb"}}
            """.utf8
        ).write(to: accountsURL)

        let proxyEnvURL = tempDir.appendingPathComponent(".env")
        try "# 注释\nOPENAI_API_KEY=key-pro-from-pool-bbbbbbbb\nLOG_LEVEL=INFO\n".data(using: .utf8)!.write(to: proxyEnvURL)

        let detected = GLMKeyDetector.detect(
            environment: ["ZAI_API_KEY": "key-env-zai-cccccccccccccccccc"],
            accountsFileURL: accountsURL,
            proxyEnvFileURL: proxyEnvURL,
            claudeGSettingsFileURL: tempDir.appendingPathComponent("missing.json"),
            zcodeConfigDirectoryURL: tempDir.appendingPathComponent("missing-zcode"),
            fileManager: .default
        )
        XCTAssertEqual(detected.map(\.label), ["ZAI_API_KEY", "Lite", "pro"])
        XCTAssertEqual(detected.map(\.source), ["env:ZAI_API_KEY", "keypool", "keypool"])
        // 同一把 key 在键池和 .env 都出现时只留先识别到的来源命名。
        XCTAssertFalse(detected.contains { $0.label == "ClaudeZ" })
    }

    func testDetectorRejectsShortKeys() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let accountsURL = tempDir.appendingPathComponent("accounts.json")
        try Data(#"{"broken": {"label": "x", "key": "short"}}"#.utf8).write(to: accountsURL)

        let detected = GLMKeyDetector.detect(
            environment: [:],
            accountsFileURL: accountsURL,
            proxyEnvFileURL: tempDir.appendingPathComponent("missing.env"),
            claudeGSettingsFileURL: tempDir.appendingPathComponent("missing.json"),
            zcodeConfigDirectoryURL: tempDir.appendingPathComponent("missing-zcode"),
            fileManager: .default
        )
        XCTAssertTrue(detected.isEmpty)
    }

    // MARK: - ZCode 配置识别（--glm-usage-json 与面板共用）

    /// 新加的识别测试一律显式传临时目录当 zcode 配置目录：默认值指向本机
    /// 家目录的 .zcode/cli，真机上有两份真配置，不传会多认出两行还把真钥匙读进测试。
    @discardableResult
    private func makeDetectorTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func missingZCodeDir(in tempDir: URL) -> URL {
        tempDir.appendingPathComponent("missing-zcode")
    }

    private func zcodeConfigData(key: String) -> Data {
        Data(#"{"provider":{"bigmodel":{"options":{"apiKey":"\#(key)"}}}}"#.utf8)
    }

    func testDetectorReadsZCodeMainAndNamedConfigs() throws {
        let tempDir = try makeDetectorTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let zcodeDir = tempDir.appendingPathComponent("zcode", isDirectory: true)
        try FileManager.default.createDirectory(at: zcodeDir, withIntermediateDirectories: true)
        try zcodeConfigData(key: "key-zcode-main-aaaaaaaaaaaaaa")
            .write(to: zcodeDir.appendingPathComponent("config.json"))
        try zcodeConfigData(key: "key-zcode-alt-bbbbbbbbbbbbbb")
            .write(to: zcodeDir.appendingPathComponent("config.alt.json"))

        let detected = GLMKeyDetector.detect(
            environment: [:],
            accountsFileURL: tempDir.appendingPathComponent("missing-accounts.json"),
            proxyEnvFileURL: tempDir.appendingPathComponent("missing.env"),
            claudeGSettingsFileURL: tempDir.appendingPathComponent("missing.json"),
            zcodeConfigDirectoryURL: zcodeDir,
            fileManager: .default
        )
        XCTAssertEqual(detected.map(\.label), ["ZCode", "ZCode alt"])
        XCTAssertEqual(detected.map(\.source), ["zcode", "zcode:alt"])
    }

    func testDetectorKeepsEarlierSourceWhenZCodeConfigRepeatsKey() throws {
        let tempDir = try makeDetectorTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sharedKey = "key-shared-pool-zcode-cccccccc"
        let accountsURL = tempDir.appendingPathComponent("accounts.json")
        try Data(#"{"main": {"label": "PoolName", "key": "\#(sharedKey)"}}"#.utf8)
            .write(to: accountsURL)
        let zcodeDir = tempDir.appendingPathComponent("zcode", isDirectory: true)
        try FileManager.default.createDirectory(at: zcodeDir, withIntermediateDirectories: true)
        try zcodeConfigData(key: sharedKey).write(to: zcodeDir.appendingPathComponent("config.json"))

        let detected = GLMKeyDetector.detect(
            environment: [:],
            accountsFileURL: accountsURL,
            proxyEnvFileURL: tempDir.appendingPathComponent("missing.env"),
            claudeGSettingsFileURL: tempDir.appendingPathComponent("missing.json"),
            zcodeConfigDirectoryURL: zcodeDir,
            fileManager: .default
        )
        XCTAssertEqual(detected.map(\.label), ["PoolName"])
        XCTAssertEqual(detected.map(\.source), ["keypool"])
    }

    func testDetectorSkipsInvalidZCodeConfigFiles() throws {
        let tempDir = try makeDetectorTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let zcodeDir = tempDir.appendingPathComponent("zcode", isDirectory: true)
        try FileManager.default.createDirectory(at: zcodeDir, withIntermediateDirectories: true)
        // 名字不合规、.bak、坏 JSON、缺字段：一律跳过不报错，不挡认得出的那把。
        try zcodeConfigData(key: "key-zcode-skipped-spaceeeeeeeee")
            .write(to: zcodeDir.appendingPathComponent("config.Bad Name.json"))
        try zcodeConfigData(key: "key-zcode-skipped-bakbbbbbbbb")
            .write(to: zcodeDir.appendingPathComponent("config.alt.json.bak"))
        try zcodeConfigData(key: "key-zcode-skipped-upperUpper")
            .write(to: zcodeDir.appendingPathComponent("config.Upper.json"))
        try Data("not-json-at-all".utf8)
            .write(to: zcodeDir.appendingPathComponent("config.broken.json"))
        try Data(#"{"provider":{"bigmodel":{"options":{}}}}"#.utf8)
            .write(to: zcodeDir.appendingPathComponent("config.nofield.json"))
        try zcodeConfigData(key: "key-zcode-ok-dddddddddddddddd")
            .write(to: zcodeDir.appendingPathComponent("config.ok.json"))

        let detected = GLMKeyDetector.detect(
            environment: [:],
            accountsFileURL: tempDir.appendingPathComponent("missing-accounts.json"),
            proxyEnvFileURL: tempDir.appendingPathComponent("missing.env"),
            claudeGSettingsFileURL: tempDir.appendingPathComponent("missing.json"),
            zcodeConfigDirectoryURL: zcodeDir,
            fileManager: .default
        )
        XCTAssertEqual(detected.map(\.label), ["ZCode ok"])
        XCTAssertEqual(detected.map(\.source), ["zcode:ok"])
    }

    func testGLMKeyEntryDecodesLegacyJSONWithoutSource() throws {
        let entry = try JSONDecoder().decode(
            GLMKeyEntry.self,
            from: Data(#"{"label":"pro","key":"key-legacy-aaaaaaaaaaaaaaaa"}"#.utf8)
        )
        XCTAssertEqual(entry.label, "pro")
        XCTAssertNil(entry.source)
    }

    // MARK: - --glm-usage-json 的纯函数（渲染与退出码）

    private func makeUsageJSONFixture() -> (entry: GLMKeyEntry, account: GLMAccountUsage) {
        let fakeKey = "sentinel-test-key-0123456789abcdef"
        let entry = GLMKeyEntry(label: "ZCode alt", key: fakeKey, source: "zcode:alt")
        let account = GLMAccountUsage(
            key: fakeKey,
            label: entry.label,
            level: "pro",
            fiveHourWindow: GLMUsageWindow(
                totalPoints: 12000,
                usedPoints: 1500,
                percentUsed: 19,
                resetAt: Date(timeIntervalSince1970: 1_788_471_923.332)
            ),
            weeklyWindow: nil,
            cashBalance: 12.5,
            totalSpendAmount: nil,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil
        )
        return (entry, account)
    }

    func testUsageJSONRendersFingerprintsWithoutRawKey() throws {
        let fixture = makeUsageJSONFixture()
        let data = GLMUsageCLI.renderJSON(
            entries: [fixture.entry],
            accounts: [fixture.account],
            checkedAt: checkedAt
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(payload["schema"] as? Int, 1)
        let rows = try XCTUnwrap(payload["accounts"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row["key_sha12"] as? String, "12d0a2e27aaf")
        XCTAssertEqual(row["source"] as? String, "zcode:alt")
        XCTAssertEqual(row["label"] as? String, "ZCode alt")
        XCTAssertEqual(row["level"] as? String, "pro")
        let fiveHour = try XCTUnwrap(row["five_hour"] as? [String: Any])
        XCTAssertEqual((fiveHour["reset_at_ms"] as? NSNumber)?.int64Value, 1_788_471_923_332)
        XCTAssertTrue(row["weekly"] is NSNull)
        XCTAssertEqual((row["cash_balance"] as? NSNumber)?.doubleValue, 12.5)
        XCTAssertTrue(row["error"] is NSNull)
        // 钥匙原文和它的头尾掩码都不许出现在输出里。
        XCTAssertFalse(text.contains(fixture.entry.key))
        XCTAssertFalse(text.contains(String(fixture.entry.key.prefix(6))))
        XCTAssertFalse(text.contains(fixture.entry.maskedKeyText))
    }

    func testUsageJSONKeepsUsedPercentageNotRemaining() throws {
        let fakeKey = "sentinel-test-key-0123456789abcdef"
        let entry = GLMKeyEntry(label: "ZCode", key: fakeKey, source: "zcode")
        let account = GLMAccountUsage(
            key: fakeKey,
            label: entry.label,
            level: nil,
            fiveHourWindow: GLMUsageWindow(
                totalPoints: 12000,
                usedPoints: 1500,
                percentUsed: 12.5,
                resetAt: nil
            ),
            weeklyWindow: nil,
            cashBalance: nil,
            totalSpendAmount: nil,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil
        )
        let data = GLMUsageCLI.renderJSON(entries: [entry], accounts: [account], checkedAt: checkedAt)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let row = try XCTUnwrap((payload["accounts"] as? [[String: Any]])?.first)
        let fiveHour = try XCTUnwrap(row["five_hour"] as? [String: Any])
        // 接口是已用口径，直接取 percentUsed；按面板剩余口径反成 87.5 就是回归。
        XCTAssertEqual((fiveHour["percent_used"] as? NSNumber)?.doubleValue, 12.5)
        XCTAssertNotEqual((fiveHour["percent_used"] as? NSNumber)?.doubleValue, 87.5)
        XCTAssertNil(fiveHour["reset_at_ms"] as? NSNumber)
        XCTAssertTrue(fiveHour["reset_at_ms"] is NSNull)
    }

    func testUsageJSONEmptyEntriesRenderEmptyAccounts() throws {
        let data = GLMUsageCLI.renderJSON(entries: [], accounts: [], checkedAt: checkedAt)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(payload["schema"] as? Int, 1)
        XCTAssertEqual((payload["accounts"] as? [Any])?.count, 0)
    }

    func testExitCodeTwoWithoutKeysElseZero() {
        XCTAssertEqual(GLMUsageCLI.exitCode(entryCount: 0), 2)
        XCTAssertEqual(GLMUsageCLI.exitCode(entryCount: 3), 0)
    }

    private func makeGoodAccount() -> GLMAccountUsage {
        GLMAccountUsage(
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            level: "pro",
            fiveHourWindow: GLMUsageWindow(
                totalPoints: 12000,
                usedPoints: 2309,
                percentUsed: 19,
                resetAt: Date(timeIntervalSince1970: 1_788_471_923.332)
            ),
            weeklyWindow: GLMUsageWindow(
                totalPoints: 60000,
                usedPoints: 3594,
                percentUsed: 5,
                resetAt: Date(timeIntervalSince1970: 1_788_977_984.998)
            ),
            cashBalance: nil,
            totalSpendAmount: nil,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil
        )
    }

    func testMergedSnapshotKeepsPreviousNumbersOnFailure() {
        let previous = GLMUsageSnapshot(accounts: [makeGoodAccount()], checkedAt: checkedAt)
        let failure = GLMAccountUsage.unavailable(
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            errorMessage: GLMUsageClientError.network.userMessage
        )
        let merged = GLMUsageSnapshot.merged(previous: previous, fresh: [failure], now: checkedAt)
        let account = merged.accounts.first
        XCTAssertEqual(account?.fiveHourWindow?.percentUsed, 19)
        XCTAssertTrue(account?.stale ?? false)
        XCTAssertEqual(account?.errorMessage, GLMUsageClientError.network.userMessage)
    }

    func testBalanceSectionExpandsWhenGLMAccountsExist() {
        let snapshot = GLMUsageSnapshot(accounts: [makeGoodAccount()], checkedAt: checkedAt)
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: .empty, aio: .unconfigured, glm: snapshot),
            .expanded
        )
        // 没有任何 key 时维持原判：compact。
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: .empty, aio: .unconfigured, glm: .empty),
            .compact(statusText: BalanceSectionPresentation.queryingStatusText)
        )
    }

    func testPointsTextAbbreviatesTenThousand() {
        XCTAssertEqual(Self.pointsText(2201), "2201")
        XCTAssertEqual(Self.pointsText(12000), "1.2万")
        XCTAssertEqual(Self.pointsText(60000), "6万")
    }

    @MainActor
    func testSettingsModelAddAndRemoveGLMKeyPersists() {
        let suiteName = "glm-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SentinelSettingsModel(
            defaults: defaults,
            loginItem: LoginItemSettingsPresentation(isOn: false, isControlEnabled: true, trailingHint: nil),
            historyRetainCount: 10,
            preferences: .default,
            watchPath: "/tmp",
            isWatchLocked: false
        )
        var changeCount = 0
        model.applyGLMKeys = { changeCount += 1 }

        // key 前后带空格也录得进；太短的 key 拒收。
        model.glmNewLabel = " pro2 "
        model.glmNewKey = "  key-manual-cccccccccccccccccc  "
        model.addGLMKeyFromFields()
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(SentinelSettings.glmUserKeys(defaults: defaults).map(\.label), ["pro2"])
        XCTAssertEqual(model.glmNewLabel, "")
        XCTAssertEqual(model.glmNewKey, "")

        model.glmNewKey = "short"
        model.addGLMKeyFromFields()
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(SentinelSettings.glmUserKeys(defaults: defaults).count, 1)

        // 删除：手加的从用户列表走，同时进删除名单防自动识别捞回来。
        let entry = SentinelSettings.glmUserKeys(defaults: defaults)[0]
        model.removeGLMKey(entry)
        XCTAssertEqual(changeCount, 2)
        XCTAssertTrue(SentinelSettings.glmUserKeys(defaults: defaults).isEmpty)
        XCTAssertTrue(SentinelSettings.glmRemovedKeys(defaults: defaults).contains(entry.key))

        // 删除名单里的 key 再手动加回来，要从名单里捞出来。
        model.glmNewLabel = "pro2"
        model.glmNewKey = entry.key
        model.addGLMKeyFromFields()
        XCTAssertFalse(SentinelSettings.glmRemovedKeys(defaults: defaults).contains(entry.key))
        XCTAssertEqual(SentinelSettings.glmUserKeys(defaults: defaults).map(\.label), ["pro2"])
    }

    private static func pointsText(_ value: Double) -> String {
        // 与界面共用一个口径的替身：直接调 SentinelBalancesSection 的静态实现。
        SentinelBalancesSection.pointsText(value)
    }
}

private extension GLMAccountUsage {
    /// 断言用的剩余百分比文本，与界面语义一致（剩余 = 100 − 已用）。
    var remainingTexts: (fiveHour: String?, weekly: String?) {
        func text(_ window: GLMUsageWindow?) -> String? {
            window?.remainingPercentage.map { "\(Int($0.rounded()))%" }
        }
        return (text(fiveHourWindow), text(weeklyWindow))
    }
}
