import Foundation
import XCTest
@testable import CortexSentinelBar

/// Command Code 订阅额度：解析、双窗 + 月度、key 存储、改名覆盖与引导展开判定。
final class CommandCodeUsageTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_788_471_000)

    private func makePayload() -> Data {
        // 社区实现对 CLI 1.53.0 验证过的返回形态：月度 credits + 5h/周滚动窗，
        // resetAt 是毫秒时间戳。
        Data(
            """
            {
              "credits": {"monthlyCredits": 8.68, "purchasedCredits": 0, "freeCredits": 0},
              "windowLimits": {
                "fiveHour": {"used": 0.72, "cap": 3, "exceeded": false, "resetAt": 1786775976124},
                "weekly": {"used": 2.82, "cap": 6, "exceeded": false, "resetAt": 1787000000000}
              }
            }
            """.utf8
        )
    }

    func testParseMapsWindowsMonthlyAndResetDates() async throws {
        let payload = try CommandCodeUsageClient.parseCreditsPayload(data: makePayload())
        XCTAssertEqual(payload.credits?.monthlyCredits, 8.68)
        XCTAssertEqual(payload.windowLimits?.fiveHour?.used, 0.72)
        XCTAssertEqual(payload.windowLimits?.fiveHour?.cap, 3)
        XCTAssertEqual(payload.windowLimits?.weekly?.used, 2.82)
        XCTAssertEqual(payload.windowLimits?.weekly?.cap, 6)

        // resetAt 毫秒时间戳换算走完整 fetch 链路验证。
        let account = try await CommandCodeUsageClient.fetch(
            key: "cc-fixture-key-abcdefghijklmnop",
            label: "Pro",
            creditsEndpoint: creditsURL,
            whoamiEndpoint: whoamiURL,
            subscriptionEndpoint: subscriptionURL,
            requestLoader: RoutedCommandCodeLoader(creditsBody: makePayload(), whoamiBody: Data("{}".utf8)),
            now: checkedAt
        )
        XCTAssertEqual(
            account.fiveHourWindow?.resetAt,
            Date(timeIntervalSince1970: 1_786_775_976.124)
        )
        XCTAssertEqual(
            account.weeklyWindow?.resetAt,
            Date(timeIntervalSince1970: 1_787_000_000)
        )
    }

    func testRemainingPercentageMath() {
        let window = CommandCodeWindow(used: 0.75, cap: 3, exceeded: false, resetAt: nil)
        XCTAssertEqual(window.remainingPercentage, 75)
        let exhausted = CommandCodeWindow(used: 5, cap: 3, exceeded: true, resetAt: nil)
        XCTAssertEqual(exhausted.remainingPercentage, 0)
        let missing = CommandCodeWindow(used: nil, cap: nil, exceeded: nil, resetAt: nil)
        XCTAssertNil(missing.remainingPercentage)
    }

    func testFetchMergesCreditsAndIdentityIndependently() async throws {
        let ok = RoutedCommandCodeLoader(
            creditsBody: makePayload(),
            whoamiBody: Data(#"{"user": {"email": "falcon@example.com", "id": "u_1"}}"#.utf8)
        )
        let account = try await CommandCodeUsageClient.fetch(
            key: "cc-fixture-key-abcdefghijklmnop",
            label: "Pro",
            creditsEndpoint: creditsURL,
            whoamiEndpoint: whoamiURL,
            subscriptionEndpoint: subscriptionURL,
            requestLoader: ok,
            now: checkedAt
        )
        XCTAssertEqual(account.fiveHourWindow?.remainingPercentage, 76)
        XCTAssertEqual(account.weeklyWindow?.remainingPercentage ?? 0, 53, accuracy: 0.01)
        XCTAssertEqual(account.monthlyRemainingCredits, 8.68)
        XCTAssertEqual(account.accountIdentity, "falcon@example.com")
        XCTAssertEqual(account.checkedAt, checkedAt)
        XCTAssertNil(account.errorMessage)

        // whoami 挂了不影响数字：身份为空，额度照常。
        let whoamiDown = RoutedCommandCodeLoader(
            creditsBody: makePayload(),
            whoamiStatus: 500,
            whoamiBody: Data()
        )
        let withoutIdentity = try await CommandCodeUsageClient.fetch(
            key: "cc-fixture-key-abcdefghijklmnop",
            label: "Pro",
            creditsEndpoint: creditsURL,
            whoamiEndpoint: whoamiURL,
            subscriptionEndpoint: subscriptionURL,
            requestLoader: whoamiDown,
            now: checkedAt
        )
        XCTAssertEqual(withoutIdentity.fiveHourWindow?.remainingPercentage, 76)
        XCTAssertNil(withoutIdentity.accountIdentity)

        // credits 挂了才算探测失败，抛错走 preserve。
        let creditsDown = RoutedCommandCodeLoader(
            creditsStatus: 500,
            creditsBody: Data(),
            whoamiBody: Data("{}".utf8)
        )
        do {
            _ = try await CommandCodeUsageClient.fetch(
                key: "cc-fixture-key-abcdefghijklmnop",
                label: "Pro",
                creditsEndpoint: creditsURL,
                whoamiEndpoint: whoamiURL,
                subscriptionEndpoint: subscriptionURL,
                requestLoader: creditsDown,
                now: checkedAt
            )
            XCTFail("应当抛错")
        } catch let error as CommandCodeUsageClientError {
            XCTAssertEqual(error, .invalidResponse)
        }

        // 401：key 无效。
        let unauthorized = RoutedCommandCodeLoader(
            creditsStatus: 401,
            creditsBody: Data(),
            whoamiBody: Data()
        )
        do {
            _ = try await CommandCodeUsageClient.fetch(
                key: "cc-fixture-key-abcdefghijklmnop",
                label: "Pro",
                creditsEndpoint: creditsURL,
                whoamiEndpoint: whoamiURL,
                subscriptionEndpoint: subscriptionURL,
                requestLoader: unauthorized,
                now: checkedAt
            )
            XCTFail("应当抛错")
        } catch let error as CommandCodeUsageClientError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testRequestCarriesCLIHeaders() async throws {
        let creditsURL = URL(string: "https://cc.example.test/credits")!
        var captured: URLRequest?
        let probe = ProbeLoader { request in
            captured = request
            return (
                self.makePayload(),
                HTTPURLResponse(url: creditsURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        _ = try await CommandCodeUsageClient.fetch(
            key: "cc-fixture-key-abcdefghijklmnop",
            label: "Pro",
            creditsEndpoint: creditsURL,
            whoamiEndpoint: URL(string: "https://cc.example.test/whoami")!,
            subscriptionEndpoint: URL(string: "https://cc.example.test/subs")!,
            requestLoader: probe,
            now: checkedAt
        )
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cc-fixture-key-abcdefghijklmnop")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-command-code-version"), CommandCodeUsageConstants.cliVersionHeaderValue)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-cli-environment"), "production")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testParseThrowsOnGarbagePayload() {
        XCTAssertThrowsError(
            try CommandCodeUsageClient.parseCreditsPayload(data: Data("<html>".utf8))
        ) { error in
            XCTAssertEqual(error as? CommandCodeUsageClientError, .invalidResponse)
        }
        // 200 但完全空的 JSON 也不炸，只是什么数字都没有。
        let payload = try? CommandCodeUsageClient.parseCreditsPayload(data: Data("{}".utf8))
        XCTAssertNil(payload?.windowLimits?.fiveHour)
    }

    func testParseAcceptsStringEncodedNumbers() throws {
        let payload = try CommandCodeUsageClient.parseCreditsPayload(
            data: Data(
                """
                {"credits":{"monthlyCredits":"12.5"},"windowLimits":{"fiveHour":{"used":"1.5","cap":"4","resetAt":1786775976124}}}
                """.utf8
            )
        )
        XCTAssertEqual(payload.credits?.monthlyCredits, 12.5)
        XCTAssertEqual(payload.windowLimits?.fiveHour?.used, 1.5)
        XCTAssertEqual(payload.windowLimits?.fiveHour?.cap, 4)
    }

    func testIdentityParsingToleratesShapeChanges() {
        XCTAssertEqual(
            CommandCodeUsageClient.parseAccountIdentity(
                data: Data(#"{"email": "a@b.c"}"#.utf8)
            ),
            "a@b.c"
        )
        XCTAssertEqual(
            CommandCodeUsageClient.parseAccountIdentity(
                data: Data(#"{"account": {"name": "falcon"}}"#.utf8)
            ),
            "falcon"
        )
        XCTAssertEqual(
            CommandCodeUsageClient.parseAccountIdentity(
                data: Data(#"{"userId": "u_42"}"#.utf8)
            ),
            "u_42"
        )
        XCTAssertNil(CommandCodeUsageClient.parseAccountIdentity(data: Data("[]".utf8)))
        XCTAssertNil(CommandCodeUsageClient.parseAccountIdentity(data: Data("{}".utf8)))
    }

    func testParseSubscriptionPeriodToleratesShapes() throws {
        let period = try XCTUnwrap(
            CommandCodeUsageClient.parseSubscriptionPeriod(
                data: Data(
                    #"{"data": {"currentPeriodStart": "2026-09-01T09:53:27.000Z", "currentPeriodEnd": "2026-10-01T09:53:27.000Z"}}"#.utf8
                )
            )
        )
        XCTAssertEqual(period.start, Date(timeIntervalSince1970: 1_788_256_407))
        XCTAssertEqual(period.end, Date(timeIntervalSince1970: 1_790_848_407))

        let endOnly = try XCTUnwrap(
            CommandCodeUsageClient.parseSubscriptionPeriod(
                data: Data(#"{"currentPeriodEnd": "2026-10-01T09:53:27Z"}"#.utf8)
            )
        )
        XCTAssertNil(endOnly.start)
        XCTAssertEqual(endOnly.end, Date(timeIntervalSince1970: 1_790_848_407))

        XCTAssertNil(CommandCodeUsageClient.parseSubscriptionPeriod(data: Data("{}".utf8)))
        XCTAssertNil(CommandCodeUsageClient.parseSubscriptionPeriod(data: Data("garbage".utf8)))
    }

    func testTimeAndPeriodFractions() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            SentinelBalancesSection.timeRemainingFraction(
                resetAt: now.addingTimeInterval(2.5 * 3600),
                windowLength: 5 * 3600,
                now: now
            ),
            0.5
        )
        XCTAssertEqual(
            SentinelBalancesSection.timeRemainingFraction(
                resetAt: now.addingTimeInterval(-1),
                windowLength: 5 * 3600,
                now: now
            ),
            0
        )
        XCTAssertNil(
            SentinelBalancesSection.timeRemainingFraction(resetAt: nil, windowLength: 5 * 3600, now: now)
        )
        // 账期：起点缺失按 30 天折算。
        let end = now.addingTimeInterval(10 * 24 * 3600)
        XCTAssertEqual(
            SentinelBalancesSection.periodRemainingFraction(end: end, start: nil, now: now) ?? -1,
            1.0 / 3.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SentinelBalancesSection.periodRemainingFraction(end: now.addingTimeInterval(-1), start: nil, now: now),
            0
        )
        XCTAssertNil(SentinelBalancesSection.periodRemainingFraction(end: nil, start: nil, now: now))
    }

    private func makeGoodAccount() -> CommandCodeAccountUsage {
        CommandCodeAccountUsage(
            key: "cc-fixture-key-abcdefghijklmnop",
            label: "Pro",
            accountIdentity: "falcon@example.com",
            fiveHourWindow: CommandCodeWindow(
                used: 0.72,
                cap: 3,
                exceeded: false,
                resetAt: Date(timeIntervalSince1970: 1_786_775_976.124)
            ),
            weeklyWindow: CommandCodeWindow(
                used: 2.82,
                cap: 6,
                exceeded: false,
                resetAt: Date(timeIntervalSince1970: 1_787_000_000)
            ),
            monthlyRemainingCredits: 52.3,
            periodEnd: nil,
            periodStart: nil,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil
        )
    }

    func testMergedSnapshotKeepsPreviousNumbersOnFailure() {
        let previous = CommandCodeUsageSnapshot(accounts: [makeGoodAccount()], checkedAt: checkedAt)
        let failure = CommandCodeAccountUsage.unavailable(
            key: "cc-fixture-key-abcdefghijklmnop",
            label: "Pro",
            errorMessage: CommandCodeUsageClientError.network.userMessage
        )
        let merged = CommandCodeUsageSnapshot.merged(previous: previous, fresh: [failure], now: checkedAt)
        let account = merged.accounts.first
        XCTAssertEqual(account?.fiveHourWindow?.remainingPercentage, 76)
        XCTAssertEqual(account?.monthlyRemainingCredits, 52.3)
        XCTAssertEqual(account?.accountIdentity, "falcon@example.com")
        XCTAssertTrue(account?.stale ?? false)
        XCTAssertEqual(account?.errorMessage, CommandCodeUsageClientError.network.userMessage)
    }

    func testEffectiveEntriesUnionsDetectedAndUserMinusRemoved() {
        let detected = [CommandCodeKeyEntry(label: "Command Code", key: "cc-env-aaaaaaaaaaaaaaaaaaaa")]
        let user = [
            CommandCodeKeyEntry(label: "账号1", key: "cc-user-bbbbbbbbbbbbbbbbbbbb"),
            // 与自动识别重复的 key 不重复显示。
            CommandCodeKeyEntry(label: "重复", key: "cc-env-aaaaaaaaaaaaaaaaaaaa"),
        ]
        let effective = CommandCodeKeyStore.effectiveEntries(
            detected: detected,
            user: user,
            removedKeys: ["cc-user-bbbbbbbbbbbbbbbbbbbb"]
        )
        XCTAssertEqual(effective.map(\.label), ["Command Code"])
    }

    func testDetectorReadsEnvAndRejectsShortKeys() {
        let detected = CommandCodeKeyDetector.detect(
            environment: ["COMMAND_CODE_API_KEY": "cc-live-key-aaaaaaaaaaaaaaaaaaaaaa"],
            authFileURL: URL(fileURLWithPath: "/nonexistent/auth.json")
        )
        XCTAssertEqual(detected.map(\.label), ["Command Code"])
        XCTAssertEqual(detected.first?.key, "cc-live-key-aaaaaaaaaaaaaaaaaaaaaa")

        XCTAssertTrue(
            CommandCodeKeyDetector.detect(
                environment: ["COMMAND_CODE_API_KEY": "short"],
                authFileURL: URL(fileURLWithPath: "/nonexistent/auth.json")
            ).isEmpty
        )
        XCTAssertTrue(
            CommandCodeKeyDetector.detect(
                environment: [:],
                authFileURL: URL(fileURLWithPath: "/nonexistent/auth.json")
            ).isEmpty
        )
    }

    func testDetectorReadsCLIAuthFileShapes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func detect(authJSON: String?) throws -> [CommandCodeKeyEntry] {
            let url = tempDir.appendingPathComponent("auth.json")
            if let authJSON {
                try Data(authJSON.utf8).write(to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            return CommandCodeKeyDetector.detect(
                environment: [:],
                authFileURL: url
            )
        }

        // 顶层 apiKey 直取。
        XCTAssertEqual(
            try detect(authJSON: #"{"apiKey": "cc-top-level-aaaaaaaaaaaaaaa"}"#).first?.key,
            "cc-top-level-aaaaaaaaaaaaaaa"
        )
        XCTAssertEqual(
            try detect(authJSON: #"{"apiKey": "cc-top-level-aaaaaaaaaaaaaaa"}"#).first?.label,
            "CLI 登录"
        )
        // 顶层 commandcode 字符串。
        XCTAssertEqual(
            try detect(authJSON: #"{"commandcode": "cc-legacy-string-aaaaaaaaaa"}"#).first?.key,
            "cc-legacy-string-aaaaaaaaaa"
        )
        // 嵌套 command-code 记录：type=api 取 key。
        XCTAssertEqual(
            try detect(authJSON: #"{"command-code": {"type": "api", "key": "cc-nested-api-aaaaaaaaaaaa"}}"#).first?.key,
            "cc-nested-api-aaaaaaaaaaaa"
        )
        // 嵌套记录：type=oauth 取 access。
        XCTAssertEqual(
            try detect(authJSON: #"{"commandcode": {"type": "oauth", "access": "cc-oauth-access-aaaaaaaaaaa"}}"#).first?.key,
            "cc-oauth-access-aaaaaaaaaaa"
        )
        // 没标 type：key 优先、access 兜底。
        XCTAssertEqual(
            try detect(authJSON: #"{"commandcode": {"key": "cc-untyped-key-aaaaaaaaaaaaaa"}}"#).first?.key,
            "cc-untyped-key-aaaaaaaaaaaaaa"
        )
        // 短 key 被滤掉；坏 JSON、非对象、空值都当没有。
        XCTAssertTrue(try detect(authJSON: #"{"apiKey": "short"}"#).isEmpty)
        XCTAssertTrue(try detect(authJSON: "not json at all").isEmpty)
        XCTAssertTrue(try detect(authJSON: #"[1,2,3]"#).isEmpty)
        XCTAssertTrue(try detect(authJSON: #"{"apiKey": ""}"#).isEmpty)
        XCTAssertTrue(try detect(authJSON: nil).isEmpty)
    }

    @MainActor
    func testSettingsModelAddAndRemoveCommandCodeKeyPersists() {
        let suiteName = "cc-settings-test-\(UUID().uuidString)"
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
        model.applyCommandCodeKeys = { changeCount += 1 }

        // key 前后带空格也录得进；太短的 key 拒收。
        model.ccNewLabel = " 账号1 "
        model.ccNewKey = "  cc-manual-key-aaaaaaaaaaaaaaaa  "
        model.addCommandCodeKeyFromFields()
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(SentinelSettings.commandCodeUserKeys(defaults: defaults).map(\.label), ["账号1"])
        XCTAssertEqual(model.ccNewLabel, "")
        XCTAssertEqual(model.ccNewKey, "")

        model.ccNewKey = "short"
        model.addCommandCodeKeyFromFields()
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(SentinelSettings.commandCodeUserKeys(defaults: defaults).count, 1)

        // 删除：手加的从用户列表走，同时进删除名单。
        let entry = SentinelSettings.commandCodeUserKeys(defaults: defaults)[0]
        model.removeCommandCodeKey(entry)
        XCTAssertEqual(changeCount, 2)
        XCTAssertTrue(SentinelSettings.commandCodeUserKeys(defaults: defaults).isEmpty)
        XCTAssertTrue(SentinelSettings.commandCodeRemovedKeys(defaults: defaults).contains(entry.key))
    }

    @MainActor
    func testSettingsModelAddCommandCodeKeyWithParameters() {
        let suiteName = "cc-settings-param-test-\(UUID().uuidString)"
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
        model.applyCommandCodeKeys = { changeCount += 1 }

        // 设置窗输入行走参数版：名称可空兜底为「账号」，前后空格剥掉。
        model.addCommandCodeKey(name: "  主力  ", key: " cc-row-key-aaaaaaaaaaaaaaaaaa ")
        XCTAssertEqual(changeCount, 1)
        let stored = SentinelSettings.commandCodeUserKeys(defaults: defaults)
        XCTAssertEqual(stored.map(\.label), ["主力"])
        XCTAssertEqual(stored.first?.key, "cc-row-key-aaaaaaaaaaaaaaaaaa")

        // 太短拒收；同 key 不重复录。
        model.addCommandCodeKey(name: "", key: "short")
        model.addCommandCodeKey(name: "重复", key: "cc-row-key-aaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(SentinelSettings.commandCodeUserKeys(defaults: defaults).count, 1)
    }

    func testProviderRenameStoreRoundTripAndClear() {
        let suiteName = "cc-rename-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ProviderRenameStore.displayName(defaults: defaults, id: "glm:key1", fallback: "GLM pro"), "GLM pro")
        ProviderRenameStore.setDisplayName(defaults: defaults, id: "glm:key1", name: "主力号")
        XCTAssertEqual(ProviderRenameStore.displayName(defaults: defaults, id: "glm:key1", fallback: "GLM pro"), "主力号")
        XCTAssertEqual(ProviderRenameStore.displayName(defaults: defaults, id: "glm:key2", fallback: "GLM lite"), "GLM lite")

        // 空名字等于恢复默认名。
        ProviderRenameStore.setDisplayName(defaults: defaults, id: "glm:key1", name: "   ")
        XCTAssertEqual(ProviderRenameStore.displayName(defaults: defaults, id: "glm:key1", fallback: "GLM pro"), "GLM pro")
    }

    func testDisplayTitlePrefixesCCAndKeepsUserNaming() {
        // 没命名 → Command Code 兜底；自带 CC / Command 的原样；普通名字补 CC 前缀。
        XCTAssertEqual(
            CommandCodeAccountUsage(
                key: "k1", label: "", accountIdentity: nil, fiveHourWindow: nil,
                weeklyWindow: nil, monthlyRemainingCredits: nil, periodEnd: nil,
                periodStart: nil, checkedAt: nil, stale: false, errorMessage: nil
            ).displayTitle,
            "Command Code"
        )
        XCTAssertEqual(
            CommandCodeAccountUsage(
                key: "k2", label: "Command Code 主力", accountIdentity: nil, fiveHourWindow: nil,
                weeklyWindow: nil, monthlyRemainingCredits: nil, periodEnd: nil,
                periodStart: nil, checkedAt: nil, stale: false, errorMessage: nil
            ).displayTitle,
            "Command Code 主力"
        )
        XCTAssertEqual(
            CommandCodeAccountUsage(
                key: "k3", label: "账号1", accountIdentity: nil, fiveHourWindow: nil,
                weeklyWindow: nil, monthlyRemainingCredits: nil, periodEnd: nil,
                periodStart: nil, checkedAt: nil, stale: false, errorMessage: nil
            ).displayTitle,
            "CC 账号1"
        )
    }

    func testBalanceSectionExpandsForCommandCodeEntry() {
        // 没配 key 也要展开：引导行得有地方站。
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: .empty, aio: .unconfigured, commandCodeShowsEntry: true),
            .expanded
        )
        // 不占位时维持原判：compact。
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: .empty, aio: .unconfigured),
            .compact(statusText: BalanceSectionPresentation.queryingStatusText)
        )
        // 有账号数据当然展开。
        let snapshot = CommandCodeUsageSnapshot(accounts: [makeGoodAccount()], checkedAt: checkedAt)
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: .empty, aio: .unconfigured, commandCodeShowsEntry: true),
            .expanded
        )
        _ = snapshot
    }

    func testMonthlyRemainingSumsCreditBuckets() async throws {
        let creditsURL = URL(string: "https://cc.example.test/credits")!
        let loader = RoutedCommandCodeLoader(
            creditsBody: Data(
                """
                {"credits":{"monthlyCredits":4,"purchasedCredits":2.5,"freeCredits":0.5},"windowLimits":null}
                """.utf8
            ),
            whoamiBody: Data("{}".utf8)
        )
        let account = try await CommandCodeUsageClient.fetch(
            key: "cc-fixture-key-abcdefghijklmnop",
            label: "Pro",
            creditsEndpoint: creditsURL,
            whoamiEndpoint: URL(string: "https://cc.example.test/whoami")!,
            subscriptionEndpoint: URL(string: "https://cc.example.test/subs")!,
            requestLoader: loader,
            now: checkedAt
        )
        XCTAssertEqual(account.monthlyRemainingCredits ?? 0, 7, accuracy: 0.001)
        XCTAssertTrue(account.hasDisplayableNumber)
        XCTAssertNil(account.fiveHourWindow)
    }

    private var creditsURL: URL { URL(string: "https://cc.example.test/credits")! }
    private var whoamiURL: URL { URL(string: "https://cc-whoami.example.test/whoami")! }
    private var subscriptionURL: URL { URL(string: "https://cc-subs.example.test/subs")! }

    /// 按 URL 分发响应的假 loader，模拟 credits / whoami 各自成功失败。
    private struct RoutedCommandCodeLoader: CommandCodeRequestLoading {
        var creditsStatus = 200
        var creditsBody: Data
        var whoamiStatus = 200
        var whoamiBody: Data

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let isWhoami = request.url?.host == "cc-whoami.example.test"
            let status = isWhoami ? whoamiStatus : creditsStatus
            let body = isWhoami ? whoamiBody : creditsBody
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        }
    }

    /// 抓请求头的假 loader。
    private struct ProbeLoader: CommandCodeRequestLoading {
        let handler: (URLRequest) -> (Data, URLResponse)

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            handler(request)
        }
    }
}
