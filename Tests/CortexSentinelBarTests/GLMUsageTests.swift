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
        let account = try GLMUsageClient.parse(
            data: makePayload(),
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            checkedAt: checkedAt
        )
        XCTAssertEqual(account.level, "pro")
        XCTAssertFalse(account.stale)
        XCTAssertNil(account.errorMessage)
        XCTAssertEqual(account.fiveHourWindow?.percentUsed, 19)
        XCTAssertEqual(account.fiveHourWindow?.usedPoints, 2309)
        XCTAssertEqual(account.fiveHourWindow?.totalPoints, 12000)
        XCTAssertEqual(
            account.fiveHourWindow?.resetAt,
            Date(timeIntervalSince1970: 1_788_471_923.332)
        )
        XCTAssertEqual(account.weeklyWindow?.percentUsed, 5)
        XCTAssertEqual(account.weeklyWindow?.usedPoints, 3594)
        XCTAssertEqual(account.weeklyWindow?.totalPoints, 60000)
        XCTAssertEqual(account.hasDisplayableNumber, true)
        XCTAssertEqual(account.displayTitle, "GLM pro")
        XCTAssertEqual(account.remainingTexts.fiveHour, "81%")
    }

    func testParseThrowsOnGarbagePayload() {
        XCTAssertThrowsError(
            try GLMUsageClient.parse(
                data: Data("{}".utf8),
                key: "fixture-key-abcdefghijklmnop",
                label: "pro",
                checkedAt: checkedAt
            )
        ) { error in
            XCTAssertEqual(error as? GLMUsageClientError, .invalidResponse)
        }
    }

    func testParseTreatsTimeLimitOnlyAsNoPlanInsteadOfError() throws {
        // lite 体验卡到期后的真实返回：只剩 MCP 包的 TIME_LIMIT，没有积分窗。
        let account = try GLMUsageClient.parse(
            data: Data(
                """
                {"code":200,"msg":"操作成功","data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":10,"remaining":90,"percentage":10,"nextResetTime":1790426002997}],"level":"lite"},"success":true}
                """.utf8
            ),
            key: "fixture-key-abcdefghijklmnop",
            label: "lite",
            checkedAt: checkedAt
        )
        XCTAssertEqual(account.level, "lite")
        XCTAssertNil(account.errorMessage)
        XCTAssertFalse(account.hasDisplayableNumber)
        XCTAssertNil(account.fiveHourWindow)
        XCTAssertNil(account.weeklyWindow)
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
            fileManager: .default
        )
        XCTAssertEqual(detected.map(\.label), ["ZAI_API_KEY", "Lite", "pro"])
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
            fileManager: .default
        )
        XCTAssertTrue(detected.isEmpty)
    }

    func testMergedSnapshotKeepsPreviousNumbersOnFailure() throws {
        let good = try GLMUsageClient.parse(
            data: makePayload(),
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            checkedAt: checkedAt
        )
        let previous = GLMUsageSnapshot(accounts: [good], checkedAt: checkedAt)
        let failure = GLMAccountUsage.unavailable(
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            errorMessage: GLMUsageClientError.network.userMessage
        )
        let merged = GLMUsageSnapshot.merged(previous: previous, fresh: [failure], now: checkedAt)
        let account = try XCTUnwrap(merged.accounts.first)
        XCTAssertEqual(account.fiveHourWindow?.percentUsed, 19)
        XCTAssertTrue(account.stale)
        XCTAssertEqual(account.errorMessage, GLMUsageClientError.network.userMessage)
    }

    func testBalanceSectionExpandsWhenGLMAccountsExist() throws {
        let good = try GLMUsageClient.parse(
            data: makePayload(),
            key: "fixture-key-abcdefghijklmnop",
            label: "pro",
            checkedAt: checkedAt
        )
        let snapshot = GLMUsageSnapshot(accounts: [good], checkedAt: checkedAt)
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
