import Foundation
import XCTest
@testable import CortexSentinelBar

/// CodeBuddy 积分余额：解析（正常 / 封禁 / 到期三态 / 非 200）、key 识别与键池、
/// 格子拆分、数值取整、颜色三档、人民币折算、刷新失败保留旧数、设置持久化。
/// 一律用夹具，不读真实的 ~/.codebuddy，夹具里只有假 key。
final class CodeBuddyCreditTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_788_471_000)

    // 假 key：bc_ 前缀 + 32 位十六进制，长 35，跟真实 key 同形但内容是编的。
    private let keyA = "bc_0123456789abcdef0123456789abcdef"
    private let keyB = "bc_fedcba9876543210fedcba9876543210"
    private let keyC = "bc_11112222333344445555666677778888"

    private func normalPayloadJSON() -> Data {
        Data(
            """
            {
              "credits": 15199.13,
              "totalUsed": 86800.87,
              "totalRecharged": 100000,
              "todayUsed": 4594.51,
              "todayRank": 3,
              "expiresAt": "2026-12-31T15:59:59.000Z",
              "userKey": "bc_0123456789abcdef0123456789abcdef"
            }
            """.utf8
        )
    }

    private func bannedPayloadJSON() -> Data {
        Data(
            """
            {
              "credits": 0,
              "totalUsed": 0,
              "totalRecharged": 0,
              "todayUsed": 0,
              "todayRank": 0,
              "banned": true,
              "userKey": "bc_0123456789abcdef0123456789abcdef"
            }
            """.utf8
        )
    }

    // MARK: - 正常返回解析

    func testParseNormalPayloadMapsAllNumbersAndExpiry() throws {
        let payload = try CodeBuddyCreditClient.parseCreditsPayload(data: normalPayloadJSON())
        XCTAssertEqual(payload.credits, 15199.13)
        XCTAssertEqual(payload.totalUsed, 86800.87)
        XCTAssertEqual(payload.totalRecharged, 100000)
        XCTAssertEqual(payload.todayUsed, 4594.51)
        XCTAssertEqual(payload.todayRank, 3)
        XCTAssertNil(payload.banned)
        XCTAssertEqual(payload.expiry, .until(CodeBuddyCreditsResponse.expiryDate(from: "2026-12-31T15:59:59.000Z")))
        // 2026-12-31T15:59:59Z 的 Unix 时间戳。
        XCTAssertEqual(
            payload.expiry,
            .until(Date(timeIntervalSince1970: 1_798_732_799))
        )
    }

    func testFetchNormalProducesDisplayableAccount() async throws {
        let account = try await CodeBuddyCreditClient.fetch(
            key: keyA,
            label: "Pro",
            endpoint: URL(string: "https://fixture.invalid/credits")!,
            requestLoader: FixedCodeBuddyLoader(status: 200, body: normalPayloadJSON()),
            now: checkedAt
        )
        XCTAssertEqual(account.key, keyA)
        XCTAssertEqual(account.label, "Pro")
        XCTAssertEqual(account.credits, 15199.13)
        XCTAssertEqual(account.todayUsed, 4594.51)
        XCTAssertEqual(account.checkedAt, checkedAt)
        XCTAssertFalse(account.banned)
        XCTAssertFalse(account.stale)
        XCTAssertNil(account.errorMessage)
        XCTAssertFalse(account.hasDisplayableNumber == false)
    }

    // MARK: - 封禁返回

    func testParseBannedPayloadFlagsBannedAndNoExpiry() throws {
        let payload = try CodeBuddyCreditClient.parseCreditsPayload(data: bannedPayloadJSON())
        XCTAssertEqual(payload.banned, true)
        XCTAssertEqual(payload.credits, 0)
        // 封禁返回没有 expiresAt 字段。
        XCTAssertEqual(payload.expiry, .absent)
    }

    func testFetchOutcomeDropsBannedAccountFromGrid() async throws {
        let account = try await CodeBuddyCreditClient.fetch(
            key: keyA,
            label: "Pro",
            endpoint: URL(string: "https://fixture.invalid/credits")!,
            requestLoader: FixedCodeBuddyLoader(status: 200, body: bannedPayloadJSON()),
            now: checkedAt
        )
        XCTAssertTrue(account.banned)

        let client = CodeBuddyCreditClient(
            creditsEndpoint: URL(string: "https://fixture.invalid/credits")!,
            settingsEndpoint: URL(string: "https://fixture.invalid/settings")!,
            requestLoader: RoutedCodeBuddyLoader(routes: [
                keyA: (200, bannedPayloadJSON()),
                keyB: (200, normalPayloadJSON()),
            ])
        )
        let outcome = await client.fetchOutcome(entries: [
            CodeBuddyKeyEntry(label: "封禁号", key: keyA),
            CodeBuddyKeyEntry(label: "Pro", key: keyB),
        ])
        // 封禁号不进格子，也不进悬停；只留可用的那个。
        XCTAssertEqual(outcome.accounts.map(\.key), [keyB])
        XCTAssertEqual(outcome.accounts.first?.credits, 15199.13)
        XCTAssertEqual(outcome.bannedCount, 1)
    }

    // MARK: - expiresAt 三态

    func testExpiryThreeStates() throws {
        // 有值。
        let withValue = try CodeBuddyCreditClient.parseCreditsPayload(data: normalPayloadJSON())
        guard case .until = withValue.expiry else {
            return XCTFail("应当解析出到期时间")
        }
        // null：永久有效。
        let permanent = try CodeBuddyCreditClient.parseCreditsPayload(data: Data(
            #"{"credits": 100, "expiresAt": null}"#.utf8
        ))
        XCTAssertEqual(permanent.expiry, .permanent)
        // 字段缺失：站点没给。
        let absent = try CodeBuddyCreditClient.parseCreditsPayload(data: Data(
            #"{"credits": 100}"#.utf8
        ))
        XCTAssertEqual(absent.expiry, .absent)

        // 界面口径：absent 不显示，permanent 显示永久有效，until 显示日期。
        let account = CodeBuddyAccountCredit(
            key: keyA,
            label: "Pro",
            credits: 100,
            todayUsed: nil,
            totalUsed: nil,
            totalRecharged: nil,
            expiry: absent.expiry,
            banned: false,
            checkedAt: nil,
            stale: false,
            errorMessage: nil
        )
        XCTAssertNil(account.expiryText)
        XCTAssertNotNil(CodeBuddyAccountCredit(
            key: keyA,
            label: "Pro",
            credits: 100,
            todayUsed: nil,
            totalUsed: nil,
            totalRecharged: nil,
            expiry: .permanent,
            banned: false,
            checkedAt: nil,
            stale: false,
            errorMessage: nil
        ).expiryText)
    }

    // MARK: - 非 200 带 error

    func testNon200WithSiteErrorSurfacesMessage() async {
        let body = Data(#"{"error": "userKey 无效"}"#.utf8)
        let client = CodeBuddyCreditClient(
            creditsEndpoint: URL(string: "https://fixture.invalid/credits")!,
            settingsEndpoint: URL(string: "https://fixture.invalid/settings")!,
            requestLoader: RoutedCodeBuddyLoader(routes: [keyA: (422, body)])
        )
        let outcome = await client.fetchOutcome(entries: [CodeBuddyKeyEntry(label: "Pro", key: keyA)])
        XCTAssertEqual(outcome.accounts.count, 1)
        XCTAssertEqual(outcome.accounts.first?.errorMessage, "userKey 无效")
        XCTAssertNil(outcome.accounts.first?.credits)
    }

    func testNon200WithoutErrorFallsBackToGenericMessage() async {
        let client = CodeBuddyCreditClient(
            creditsEndpoint: URL(string: "https://fixture.invalid/credits")!,
            settingsEndpoint: URL(string: "https://fixture.invalid/settings")!,
            requestLoader: RoutedCodeBuddyLoader(routes: [keyA: (500, Data())])
        )
        let outcome = await client.fetchOutcome(entries: [CodeBuddyKeyEntry(label: "Pro", key: keyA)])
        XCTAssertEqual(outcome.accounts.first?.errorMessage, "CodeBuddy 查询失败（HTTP 500）")
    }

    // MARK: - models.json 识别

    func testDetectorReadsFixtureFindsBCKeysDeduplicatesAndSkipsOthers() throws {
        let fixtureURL = try makeModelsJSONFixture(#"""
        {
          "models": [
            {"id": "m1", "apiKey": "bc_0123456789abcdef0123456789abcdef"},
            {"id": "m2", "apiKey": "bc_0123456789abcdef0123456789abcdef"},
            {"id": "m3", "apiKey": "sk-not-a-buddy-key-0123456789"},
            {"id": "m4", "apiKey": "bc_short"},
            {"id": "m5"}
          ]
        }
        """#)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let entries = CodeBuddyKeyDetector.detect(modelsJSONFileURL: fixtureURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.key, "bc_0123456789abcdef0123456789abcdef")
        XCTAssertEqual(entries.first?.label, "本机")
        XCTAssertEqual(entries.first?.source, "local")
    }

    func testDetectorMissingFileReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-models-\(UUID().uuidString).json")
        XCTAssertTrue(CodeBuddyKeyDetector.detect(modelsJSONFileURL: missing).isEmpty)
    }

    func testIsValidKeyRequiresBCPrefixAndLength() {
        XCTAssertTrue(CodeBuddyKeyDetector.isValidKey("bc_0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(CodeBuddyKeyDetector.isValidKey("sk_0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(CodeBuddyKeyDetector.isValidKey("bc_short"))
    }

    // MARK: - 手加名字和顺序压过「本机」

    func testEffectiveEntriesUserOrderAndNamesWinOverDetected() {
        let detected = [
            CodeBuddyKeyEntry(label: "本机", key: keyB, source: "local"),
            CodeBuddyKeyEntry(label: "本机", key: keyC, source: "local"),
        ]
        let user = [
            CodeBuddyKeyEntry(label: "Pro", key: keyA, source: "user"),
            CodeBuddyKeyEntry(label: "Max", key: keyB, source: "user"),
        ]
        let effective = CodeBuddyKeyStore.effectiveEntries(detected: detected, user: user, removedKeys: [])
        // 手加的排前面、顺序按手加顺序；同一把 key 用手加的名字。
        XCTAssertEqual(effective.map(\.key), [keyA, keyB, keyC])
        XCTAssertEqual(effective.map(\.label), ["Pro", "Max", "本机"])
    }

    func testEffectiveEntriesRemovesDeletedKeys() {
        let detected = [CodeBuddyKeyEntry(label: "本机", key: keyA, source: "local")]
        let effective = CodeBuddyKeyStore.effectiveEntries(
            detected: detected,
            user: [],
            removedKeys: [keyA]
        )
        XCTAssertTrue(effective.isEmpty)
    }

    // MARK: - 格子拆分

    func testGridSplitKeepsFirstThreeAndSendsRestToHover() {
        let accounts = [keyA, keyB, keyC, "bc_99990000111122223333444455556666"].map {
            makeAccount(key: $0, credits: 1000)
        }
        let grid = CodeBuddyCreditConstants.gridSplit(accounts)
        XCTAssertEqual(grid.visible.map(\.key), [keyA, keyB, keyC])
        XCTAssertEqual(grid.rest.map(\.key), ["bc_99990000111122223333444455556666"])

        let small = CodeBuddyCreditConstants.gridSplit(Array(accounts.prefix(3)))
        XCTAssertEqual(small.visible.count, 3)
        XCTAssertTrue(small.rest.isEmpty)
    }

    // MARK: - 数值取整

    func testCreditsTextFloorsWithoutSeparators() {
        XCTAssertEqual(CodeBuddyCreditConstants.creditsText(15199.13), "15199")
        XCTAssertEqual(CodeBuddyCreditConstants.creditsText(9960.51), "9960")
        XCTAssertEqual(CodeBuddyCreditConstants.creditsText(0), "0")
        XCTAssertEqual(CodeBuddyCreditConstants.creditsText(10200), "10200")
        XCTAssertEqual(CodeBuddyCreditConstants.creditsText(nil), "—")
    }

    // MARK: - 颜色三档边界

    func testCreditLevelBoundaries() {
        // ≥ 500 绿；< 500 黄；< 50 红。
        XCTAssertEqual(CodeBuddyCreditConstants.creditLevel(2000), .normal)
        XCTAssertEqual(CodeBuddyCreditConstants.creditLevel(500), .normal)
        XCTAssertEqual(CodeBuddyCreditConstants.creditLevel(499), .low)
        XCTAssertEqual(CodeBuddyCreditConstants.creditLevel(50), .low)
        XCTAssertEqual(CodeBuddyCreditConstants.creditLevel(49), .critical)
        XCTAssertEqual(CodeBuddyCreditConstants.creditLevel(0), .critical)
    }

    func testWorstLevelPicksMostSevere() {
        XCTAssertEqual(CodeBuddyCreditConstants.worstLevel([.normal, .normal]), .normal)
        XCTAssertEqual(CodeBuddyCreditConstants.worstLevel([.normal, .low]), .low)
        XCTAssertEqual(CodeBuddyCreditConstants.worstLevel([.normal, .critical]), .critical)
        XCTAssertEqual(CodeBuddyCreditConstants.worstLevel([.low, .critical]), .critical)
        XCTAssertNil(CodeBuddyCreditConstants.worstLevel([]))
    }

    func testExpiryDoesNotAffectColor() {
        // 颜色只看剩余积分；到期三态下同一积分同档。
        func level(expiry: CodeBuddyExpiry?) -> CodeBuddyCreditLevel {
            let account = CodeBuddyAccountCredit(
                key: keyA,
                label: "Pro",
                credits: 499,
                todayUsed: nil,
                totalUsed: nil,
                totalRecharged: nil,
                expiry: expiry,
                banned: false,
                checkedAt: nil,
                stale: false,
                errorMessage: nil
            )
            return CodeBuddyCreditConstants.creditLevel(account.credits!)
        }
        XCTAssertEqual(level(expiry: .absent), .low)
        XCTAssertEqual(level(expiry: .permanent), .low)
        XCTAssertEqual(level(expiry: .until(Date(timeIntervalSince1970: 0))), .low)
    }

    // MARK: - 人民币折算

    func testCNYUsesPayBase1000FromSite() {
        // 1000 积分 = 3 元：15199.13 → 45.60 元。
        let text = CodeBuddyCreditConstants.cnyText(credits: 15199.13, payBase1000: 3)
        XCTAssertEqual(text, "≈¥45.60")
    }

    func testCNYHiddenWhenPriceMissing() {
        XCTAssertNil(CodeBuddyCreditConstants.cnyText(credits: 15199.13, payBase1000: nil))
        XCTAssertNil(CodeBuddyCreditConstants.cnyText(credits: 15199.13, payBase1000: 0))
    }

    func testFetchPayBase1000ReadsSettingsFixture() async {
        let client = CodeBuddyCreditClient(
            creditsEndpoint: URL(string: "https://fixture.invalid/credits")!,
            settingsEndpoint: URL(string: "https://fixture.invalid/settings")!,
            requestLoader: RoutedCodeBuddyLoader(routes: [:], settingsBody: Data(#"{"payBase1000": 3}"#.utf8))
        )
        let price = await client.fetchPayBase1000()
        XCTAssertEqual(price, 3)
    }

    func testFetchPayBase1000NilWhenRequestFails() async {
        let client = CodeBuddyCreditClient(
            creditsEndpoint: URL(string: "https://fixture.invalid/credits")!,
            settingsEndpoint: URL(string: "https://fixture.invalid/settings")!,
            requestLoader: RoutedCodeBuddyLoader(routes: [:], settingsStatus: 500, settingsBody: Data())
        )
        let price = await client.fetchPayBase1000()
        XCTAssertNil(price)
    }

    // MARK: - 刷新失败保留旧数标过期

    func testMergedSnapshotKeepsPreviousNumbersOnFailure() async {
        // 上一轮拿到好数字。
        let goodClient = CodeBuddyCreditClient(
            creditsEndpoint: URL(string: "https://fixture.invalid/credits")!,
            settingsEndpoint: URL(string: "https://fixture.invalid/settings")!,
            requestLoader: RoutedCodeBuddyLoader(routes: [keyA: (200, normalPayloadJSON())])
        )
        let previous = CodeBuddyCreditSnapshot.merged(
            previous: .empty,
            fresh: await goodClient.fetchAll(entries: [CodeBuddyKeyEntry(label: "Pro", key: keyA)]),
            payBase1000: 3,
            now: checkedAt
        )
        XCTAssertEqual(previous.accounts.first?.credits, 15199.13)
        XCTAssertFalse(previous.accounts.first!.stale)

        // 这一轮接口挂了：旧数字原样保留，标过期，带最新报错。
        let downClient = CodeBuddyCreditClient(
            creditsEndpoint: URL(string: "https://fixture.invalid/credits")!,
            settingsEndpoint: URL(string: "https://fixture.invalid/settings")!,
            requestLoader: RoutedCodeBuddyLoader(routes: [keyA: (500, Data())])
        )
        let merged = CodeBuddyCreditSnapshot.merged(
            previous: previous,
            fresh: await downClient.fetchAll(entries: [CodeBuddyKeyEntry(label: "Pro", key: keyA)]),
            payBase1000: nil,
            now: checkedAt.addingTimeInterval(600)
        )
        XCTAssertEqual(merged.accounts.first?.credits, 15199.13)
        XCTAssertEqual(merged.accounts.first?.todayUsed, 4594.51)
        XCTAssertTrue(merged.accounts.first!.stale)
        XCTAssertEqual(merged.accounts.first?.errorMessage, "CodeBuddy 查询失败（HTTP 500）")
        // 现价这轮没读到，保留上一轮的。
        XCTAssertEqual(merged.payBase1000, 3)
    }

    // MARK: - 设置持久化

    func testSettingsAddAndRemoveCodeBuddyKeyPersists() {
        let suite = "codebuddy-credit-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(SentinelSettings.addCodeBuddyUserKey(
            CodeBuddyKeyEntry(label: "Pro", key: keyA, source: "user"),
            defaults: defaults
        ))
        // 同一把 key 重复添加不生效。
        XCTAssertFalse(SentinelSettings.addCodeBuddyUserKey(
            CodeBuddyKeyEntry(label: "另一个名", key: keyA, source: "user"),
            defaults: defaults
        ))
        XCTAssertEqual(SentinelSettings.codeBuddyUserKeys(defaults: defaults).map(\.label), ["Pro"])
        XCTAssertEqual(SentinelSettings.codeBuddyUserKeys(defaults: defaults).first?.key, keyA)

        // 删除名单往返。
        SentinelSettings.addCodeBuddyRemovedKey(keyB, defaults: defaults)
        XCTAssertEqual(SentinelSettings.codeBuddyRemovedKeys(defaults: defaults), [keyB])
        SentinelSettings.removeCodeBuddyRemovedKey(keyB, defaults: defaults)
        XCTAssertTrue(SentinelSettings.codeBuddyRemovedKeys(defaults: defaults).isEmpty)

        SentinelSettings.removeCodeBuddyUserKey(keyA, defaults: defaults)
        XCTAssertTrue(SentinelSettings.codeBuddyUserKeys(defaults: defaults).isEmpty)
    }

    // MARK: - CLI JSON

    func testCLIJSONMasksKeysAndHidesBanned() throws {
        let accounts = [
            CodeBuddyAccountCredit(
                key: keyA,
                label: "Pro",
                credits: 15199.13,
                todayUsed: 4594.51,
                totalUsed: 86800.87,
                totalRecharged: 100000,
                expiry: .until(Date(timeIntervalSince1970: 1_798_732_799)),
                banned: false,
                checkedAt: checkedAt,
                stale: false,
                errorMessage: nil
            ),
        ]
        let data = CodeBuddyCreditCLI.renderJSON(
            entries: [
                CodeBuddyKeyEntry(label: "Pro", key: keyA, source: "user"),
                CodeBuddyKeyEntry(label: "封禁号", key: keyB, source: "local"),
            ],
            accounts: accounts,
            bannedCount: 1,
            payBase1000: 3,
            checkedAt: checkedAt
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema"] as? Int, 1)
        XCTAssertEqual(json["banned_count"] as? Int, 1)
        XCTAssertEqual(json["pay_base_1000"] as? Double, 3)
        let rows = try XCTUnwrap(json["accounts"] as? [[String: Any]])
        // 封禁号不出现在账号列表里。
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["key_masked"] as? String, "bc_012…cdef")
        // 完整 key 任何字段都不出现。
        let raw = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains(keyA))
        XCTAssertFalse(raw.contains(keyB))
        XCTAssertEqual(row["label"] as? String, "Pro")
        XCTAssertEqual((row["credits"] as? NSNumber)?.doubleValue, 15199.13)
        XCTAssertEqual(row["expires_at"] as? String, "2026-12-31T15:59:59Z")
    }

    // MARK: - 夹具工具

    private func makeAccount(key: String, credits: Double?) -> CodeBuddyAccountCredit {
        CodeBuddyAccountCredit(
            key: key,
            label: "号",
            credits: credits,
            todayUsed: nil,
            totalUsed: nil,
            totalRecharged: nil,
            expiry: nil,
            banned: false,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil
        )
    }

    private func makeModelsJSONFixture(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codebuddy-models-\(UUID().uuidString).json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// 固定返回的加载器：每个 key 一条路由。
private struct RoutedCodeBuddyLoader: CodeBuddyCreditRequestLoading {
    var routes: [String: (status: Int, body: Data)]
    var settingsStatus: Int = 200
    var settingsBody: Data = Data(#"{"payBase1000": 3}"#.utf8)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let urlString = request.url?.absoluteString ?? ""
        let response: HTTPURLResponse
        let body: Data
        if urlString.contains("/settings") {
            response = HTTPURLResponse(
                url: request.url!,
                statusCode: settingsStatus,
                httpVersion: nil,
                headerFields: nil
            )!
            body = settingsBody
        } else {
            let key = queryValue(named: "userKey", in: urlString) ?? ""
            let route = routes[key] ?? (500, Data())
            response = HTTPURLResponse(
                url: request.url!,
                statusCode: route.status,
                httpVersion: nil,
                headerFields: nil
            )!
            body = route.body
        }
        return (body, response)
    }

    private func queryValue(named name: String, in urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else {
            return nil
        }
        return components.queryItems?.first { $0.name == name }?.value
    }
}

/// 单一返回的加载器：不分路由。
private struct FixedCodeBuddyLoader: CodeBuddyCreditRequestLoading {
    var status: Int
    var body: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}
