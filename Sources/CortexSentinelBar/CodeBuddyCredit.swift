import Foundation

/// CodeBuddy（buddy.credit）积分余额。
/// 端点是站点自己前端在用的账务接口（站点 app.js 的 doQuery 就调这一条）：
///   GET https://buddy.credit/api/user/credits?userKey=<key>   不用请求头，只查账务不消耗积分
///   GET https://buddy.credit/api/settings                     现价（payBase1000：1000 积分 = N 元）
/// 积分没有时间窗，越用越少，用到 0 为止；颜色只看剩余积分，不看到期时间。
/// expiresAt 三态：字段缺失 = 站点没给不显示；null = 永久有效；有值 = 到期时间。

/// 到期三态。absent（字段缺失）和 permanent（null）是两回事，界面口径不同。
enum CodeBuddyExpiry: Equatable, Sendable {
    /// 响应里没有这个字段：站点没给，界面不显示到期信息。
    case absent
    /// null：永久有效。
    case permanent
    /// 有值：到期时间。
    case until(Date)
}

struct CodeBuddyAccountCredit: Equatable, Sendable, Identifiable {
    let key: String
    let label: String
    /// 剩余积分。查询失败时为 nil（界面显示「—」）。
    let credits: Double?
    let todayUsed: Double?
    let totalUsed: Double?
    let totalRecharged: Double?
    let expiry: CodeBuddyExpiry?
    /// 封禁的号（banned=true）在抓取层就被剔除，格子与悬停都不出现。
    let banned: Bool
    let checkedAt: Date?
    let stale: Bool
    let errorMessage: String?

    var id: String { key }

    var hasDisplayableNumber: Bool {
        credits != nil
    }

    /// 只露出头尾，完整 key 不进界面不进日志。
    var maskedKeyText: String {
        guard key.count > 12 else {
            return "••••"
        }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }

    /// 到期只进悬停当信息看，不影响颜色。
    var expiryText: String? {
        switch expiry {
        case .absent, nil:
            return nil
        case .permanent:
            return "永久有效"
        case .until(let date):
            return "\(Self.expiryFormatter.string(from: date)) 到期"
        }
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    static func unavailable(key: String, label: String, errorMessage: String) -> CodeBuddyAccountCredit {
        CodeBuddyAccountCredit(
            key: key,
            label: label,
            credits: nil,
            todayUsed: nil,
            totalUsed: nil,
            totalRecharged: nil,
            expiry: nil,
            banned: false,
            checkedAt: nil,
            stale: false,
            errorMessage: errorMessage
        )
    }

    /// 刷新失败时上一轮的好数字原样留着，只标过期和最新报错。
    func merged(old: CodeBuddyAccountCredit) -> CodeBuddyAccountCredit {
        guard !hasDisplayableNumber else {
            return self
        }
        return CodeBuddyAccountCredit(
            key: key,
            label: label,
            credits: old.credits,
            todayUsed: old.todayUsed,
            totalUsed: old.totalUsed,
            totalRecharged: old.totalRecharged,
            expiry: expiry ?? old.expiry,
            banned: banned || old.banned,
            checkedAt: old.checkedAt,
            stale: true,
            errorMessage: errorMessage ?? old.errorMessage
        )
    }
}

struct CodeBuddyCreditSnapshot: Equatable, Sendable {
    /// 只含可显示的号：封禁的号在抓取层就被剔除，格子与悬停都不出现。
    let accounts: [CodeBuddyAccountCredit]
    let checkedAt: Date?
    /// 现价（1000 积分 = N 元）。读不到时保留上一轮的，再读不到就不显示人民币。
    let payBase1000: Double?

    static let empty = CodeBuddyCreditSnapshot(accounts: [], checkedAt: nil, payBase1000: nil)

    func account(forKey key: String) -> CodeBuddyAccountCredit? {
        accounts.first { $0.key == key }
    }

    /// 新一轮结果按 key 合进旧快照：失败的账号保留上一轮数字（合并逻辑在
    /// CodeBuddyAccountCredit.merged），账号列表以最新 key 集合为准。
    /// payBase1000 传 nil 表示这轮没拿到现价，保留旧值。
    static func merged(
        previous: CodeBuddyCreditSnapshot,
        fresh: [CodeBuddyAccountCredit],
        payBase1000: Double?,
        now: Date = Date()
    ) -> CodeBuddyCreditSnapshot {
        let accounts = fresh.map { account -> CodeBuddyAccountCredit in
            guard let old = previous.account(forKey: account.key) else {
                return account
            }
            return account.merged(old: old)
        }
        return CodeBuddyCreditSnapshot(
            accounts: accounts,
            checkedAt: now,
            payBase1000: payBase1000 ?? previous.payBase1000
        )
    }
}

enum CodeBuddyCreditClientError: Error, Equatable {
    case unauthorized
    case timedOut
    case network
    case invalidResponse
    /// 非 200 且返回体带了 error 字段：把站点的话原样带给用户。
    case siteError(String)

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "CodeBuddy key 无效或已过期"
        case .timedOut:
            return "CodeBuddy 查询超时"
        case .network:
            return "CodeBuddy 接口暂不可达"
        case .invalidResponse:
            return "CodeBuddy 余额格式已变化"
        case .siteError(let message):
            return message.isEmpty ? "CodeBuddy 查询失败" : message
        }
    }
}

/// 颜色三档（Falcon 定）：剩余 ≥ 500 绿；< 500 黄；< 50 红。
/// 只看剩余积分，不看到期时间。
enum CodeBuddyCreditLevel: Equatable, Sendable {
    case normal
    case low
    case critical
}

enum CodeBuddyCreditConstants {
    static let creditsEndpoint = URL(string: "https://buddy.credit/api/user/credits")!
    static let settingsEndpoint = URL(string: "https://buddy.credit/api/settings")!
    /// 余额属于慢变量，跟 GLM / Cursor 同一档刷新间隔。
    static let automaticRefreshInterval: TimeInterval = 10 * 60
    static let requestTimeout: TimeInterval = 10
    /// key 形态：bc_ 开头加 32 位十六进制（长 35）。录入校验用前缀 + 最短长度。
    static let keyPrefix = "bc_"
    static let minKeyLength = 20
    /// 格子最多放三个号，其余只进悬停。
    static let maxGridAccounts = 3
    /// 自动识别 key 的格子短名。
    static let autoDetectedLabel = "本机"
    /// 本机 CodeBuddy 配置里的 key 清单（models[].apiKey，同一把 key 会被多个模型重复引用）。
    static var modelsJSONFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codebuddy/models.json")
    }

    /// 剩余积分颜色档位。
    static func creditLevel(_ credits: Double) -> CodeBuddyCreditLevel {
        if credits < 50 {
            return .critical
        }
        if credits < 500 {
            return .low
        }
        return .normal
    }

    /// 三格里最坏的一档。
    static func worstLevel(_ levels: [CodeBuddyCreditLevel]) -> CodeBuddyCreditLevel? {
        guard !levels.isEmpty else {
            return nil
        }
        if levels.contains(.critical) {
            return .critical
        }
        if levels.contains(.low) {
            return .low
        }
        return .normal
    }

    /// 格子数值：剩余积分向下取整，不加千分位、不写「万」。
    static func creditsText(_ credits: Double?) -> String {
        guard let credits else {
            return "—"
        }
        return String(Int(credits.rounded(.down)))
    }

    /// 约合人民币：现价读站点的 payBase1000，读不到就不显示（返回 nil）。
    static func cnyText(credits: Double, payBase1000: Double?) -> String? {
        guard let payBase1000, payBase1000 > 0 else {
            return nil
        }
        return String(format: "≈¥%.2f", credits / 1000 * payBase1000)
    }

    /// 进格子的号与只进悬停的号：可用的号超过三个时只取前三个。
    static func gridSplit(
        _ accounts: [CodeBuddyAccountCredit]
    ) -> (visible: [CodeBuddyAccountCredit], rest: [CodeBuddyAccountCredit]) {
        guard accounts.count > maxGridAccounts else {
            return (accounts, [])
        }
        return (Array(accounts.prefix(maxGridAccounts)), Array(accounts.dropFirst(maxGridAccounts)))
    }
}

// MARK: - 网络与解析

protocol CodeBuddyCreditRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CodeBuddyCreditRequestLoading {}

/// /api/user/credits 的返回。数值容错：服务端可能把数字序列化成字符串。
struct CodeBuddyCreditsResponse: Decodable {
    let credits: Double?
    let totalUsed: Double?
    let totalRecharged: Double?
    let todayUsed: Double?
    let todayRank: Int?
    let banned: Bool?
    /// 三态在解码器里区分：缺失 = .absent，null = .permanent，有值 = .until。
    let expiry: CodeBuddyExpiry?
    /// 非 200 时返回体里的错误说明。
    let error: String?

    enum CodingKeys: String, CodingKey {
        case credits
        case totalUsed
        case totalRecharged
        case todayUsed
        case todayRank
        case banned
        case expiresAt
        case error
    }

    init(
        credits: Double?,
        totalUsed: Double?,
        totalRecharged: Double?,
        todayUsed: Double?,
        todayRank: Int?,
        banned: Bool?,
        expiry: CodeBuddyExpiry?,
        error: String?
    ) {
        self.credits = credits
        self.totalUsed = totalUsed
        self.totalRecharged = totalRecharged
        self.todayUsed = todayUsed
        self.todayRank = todayRank
        self.banned = banned
        self.expiry = expiry
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credits = try container.decodeFlexibleDoubleIfPresent(forKey: .credits)
        totalUsed = try container.decodeFlexibleDoubleIfPresent(forKey: .totalUsed)
        totalRecharged = try container.decodeFlexibleDoubleIfPresent(forKey: .totalRecharged)
        todayUsed = try container.decodeFlexibleDoubleIfPresent(forKey: .todayUsed)
        todayRank = try container.decodeFlexibleIntIfPresent(forKey: .todayRank)
        banned = try container.decodeIfPresent(Bool.self, forKey: .banned)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        if container.contains(.expiresAt) {
            if try container.decodeNil(forKey: .expiresAt) {
                expiry = .permanent
            } else {
                let raw = try container.decode(String.self, forKey: .expiresAt)
                expiry = .until(Self.expiryDate(from: raw))
            }
        } else {
            expiry = .absent
        }
    }

    /// expiresAt 形如 2026-12-31T15:59:59.000Z（UTC）。解析不了就按 permanent 兜底——
    /// 到期只是悬停里的信息，不值得为格式抖动报错。
    static func expiryDate(from raw: String) -> Date {
        if let date = expiryFormatterWithFraction.date(from: raw)
            ?? expiryFormatter.date(from: raw) {
            return date
        }
        return .distantFuture
    }

    private static let expiryFormatterWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let expiryFormatter = ISO8601DateFormatter()
}

struct CodeBuddyCreditClient: Sendable {
    private let creditsEndpoint: URL
    private let settingsEndpoint: URL
    private let requestLoader: any CodeBuddyCreditRequestLoading

    init(
        creditsEndpoint: URL = CodeBuddyCreditConstants.creditsEndpoint,
        settingsEndpoint: URL = CodeBuddyCreditConstants.settingsEndpoint,
        requestLoader: any CodeBuddyCreditRequestLoading = URLSession.shared
    ) {
        self.creditsEndpoint = creditsEndpoint
        self.settingsEndpoint = settingsEndpoint
        self.requestLoader = requestLoader
    }

    /// 并发查所有 key，结果按 entries 顺序排好。封禁的号在这里就剔除
    /// （格子与悬停都不出现），查询失败落成带 errorMessage 的账号行，
    /// 由 merge 决定要不要保留旧数字。
    func fetchAll(entries: [CodeBuddyKeyEntry]) async -> [CodeBuddyAccountCredit] {
        await fetchOutcome(entries: entries).accounts
    }

    /// 一轮结果：可显示账号 + 被剔除的封禁号个数。
    struct FetchOutcome: Equatable, Sendable {
        let accounts: [CodeBuddyAccountCredit]
        let bannedCount: Int
    }

    func fetchOutcome(entries: [CodeBuddyKeyEntry]) async -> FetchOutcome {
        await withTaskGroup(of: CodeBuddyAccountCredit.self) { group in
            for entry in entries {
                group.addTask { [creditsEndpoint, requestLoader] in
                    do {
                        return try await Self.fetch(
                            key: entry.key,
                            label: entry.label,
                            endpoint: creditsEndpoint,
                            requestLoader: requestLoader
                        )
                    } catch let error as CodeBuddyCreditClientError {
                        return .unavailable(key: entry.key, label: entry.label, errorMessage: error.userMessage)
                    } catch {
                        return .unavailable(key: entry.key, label: entry.label, errorMessage: CodeBuddyCreditClientError.network.userMessage)
                    }
                }
            }
            var results: [String: CodeBuddyAccountCredit] = [:]
            var bannedCount = 0
            for await account in group {
                if account.banned {
                    // 封禁的号相当于没钱了，直接不显示。
                    bannedCount += 1
                    continue
                }
                results[account.key] = account
            }
            return FetchOutcome(
                accounts: entries.compactMap { results[$0.key] },
                bannedCount: bannedCount
            )
        }
    }

    /// 现价（payBase1000）。请求挂了或字段没了都返回 nil，由调用方决定保留旧值。
    func fetchPayBase1000() async -> Double? {
        var request = URLRequest(url: settingsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = CodeBuddyCreditConstants.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CortexSentinel/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await requestLoader.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let number = object["payBase1000"] as? NSNumber {
            return number.doubleValue
        }
        if let text = object["payBase1000"] as? String {
            return Double(text)
        }
        return nil
    }

    static func fetch(
        key: String,
        label: String,
        endpoint: URL,
        requestLoader: any CodeBuddyCreditRequestLoading,
        now: Date = Date()
    ) async throws -> CodeBuddyAccountCredit {
        let data = try await authorizedGet(key: key, endpoint: endpoint, requestLoader: requestLoader)
        let payload = try parseCreditsPayload(data: data)
        // 封禁返回 HTTP 200 + banned=true（credits 全 0、没有 expiresAt）；
        // 号已经没钱了，交由 fetchOutcome 剔除。
        return CodeBuddyAccountCredit(
            key: key,
            label: label,
            credits: payload.credits,
            todayUsed: payload.todayUsed,
            totalUsed: payload.totalUsed,
            totalRecharged: payload.totalRecharged,
            expiry: payload.expiry,
            banned: payload.banned == true,
            checkedAt: now,
            stale: false,
            errorMessage: nil
        )
    }

    static func parseCreditsPayload(data: Data) throws -> CodeBuddyCreditsResponse {
        do {
            return try JSONDecoder().decode(CodeBuddyCreditsResponse.self, from: data)
        } catch {
            throw CodeBuddyCreditClientError.invalidResponse
        }
    }

    private static func authorizedGet(
        key: String,
        endpoint: URL,
        requestLoader: any CodeBuddyCreditRequestLoading
    ) async throws -> Data {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "userKey", value: key)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = CodeBuddyCreditConstants.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CortexSentinel/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await requestLoader.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodeBuddyCreditClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CodeBuddyCreditClientError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // 非 200 时返回体里有 error 字段，原样带给用户。
            let siteMessage = (try? JSONDecoder().decode(CodeBuddyCreditsResponse.self, from: data))?
                .error
            throw CodeBuddyCreditClientError.siteError(
                siteMessage ?? "CodeBuddy 查询失败（HTTP \(httpResponse.statusCode)）"
            )
        }
        return data
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), !(try decodeNil(forKey: key)) else {
            return nil
        }
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value)
        }
        return try decode(Double.self, forKey: key)
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), !(try decodeNil(forKey: key)) else {
            return nil
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decode(String.self, forKey: key),
           let value = Double(value) {
            return Int(value)
        }
        return try decode(Int.self, forKey: key)
    }
}

// MARK: - key 识别与键池

struct CodeBuddyKeyEntry: Equatable, Codable, Sendable, Identifiable {
    let label: String
    let key: String
    /// key 从哪认出来的：user = 设置里手加；local = 本机 models.json 自动识别。
    /// 老数据没这个字段，解出来是 nil，只在 --codebuddy-credit-json 里露出。
    var source: String? = nil

    var id: String { key }

    /// 设置列表里只露头尾，完整 key 不进界面。
    var maskedKeyText: String {
        guard key.count > 12 else {
            return "••••"
        }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }
}

/// 从本机 CodeBuddy 配置里把 key 认出来。只读文件，不写不改；
/// 同一把 key 被多个模型重复引用时只留一条。
enum CodeBuddyKeyDetector {
    static func detect(
        modelsJSONFileURL: URL = CodeBuddyCreditConstants.modelsJSONFileURL,
        fileManager: FileManager = .default
    ) -> [CodeBuddyKeyEntry] {
        guard fileManager.fileExists(atPath: modelsJSONFileURL.path),
              let data = try? Data(contentsOf: modelsJSONFileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else {
            return []
        }
        var keys: [String] = []
        var seen: Set<String> = []
        for model in models {
            guard let apiKey = model["apiKey"] as? String else {
                continue
            }
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidKey(trimmed), !seen.contains(trimmed) else {
                continue
            }
            seen.insert(trimmed)
            keys.append(trimmed)
        }
        return keys.map { CodeBuddyKeyEntry(label: CodeBuddyCreditConstants.autoDetectedLabel, key: $0, source: "local") }
    }

    static func isValidKey(_ key: String) -> Bool {
        key.hasPrefix(CodeBuddyCreditConstants.keyPrefix)
            && key.count >= CodeBuddyCreditConstants.minKeyLength
    }
}

/// 用户手维护的 key 列表 + 删掉的自动识别 key（防止下次启动又认回来）。
/// 手加的排前面（格子顺序按手加顺序），本机自动识别的排后面；
/// 同一把 key 两处都有时用手加的名字和位置。落 UserDefaults，JSON 编码。
enum CodeBuddyKeyStore {
    static func effectiveEntries(
        detected: [CodeBuddyKeyEntry],
        user: [CodeBuddyKeyEntry],
        removedKeys: Set<String>
    ) -> [CodeBuddyKeyEntry] {
        var byKey: [String: CodeBuddyKeyEntry] = [:]
        var order: [String] = []
        for entry in user + detected where !removedKeys.contains(entry.key) {
            if byKey[entry.key] == nil {
                byKey[entry.key] = entry
                order.append(entry.key)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

// MARK: - 命令行读数

/// `--codebuddy-credit-json`：按本机来源解析 key、查一轮、打印 JSON 退出，
/// 不占哨兵实例。key 只露头尾，完整 key 不进输出不进日志。
enum CodeBuddyCreditCLI {
    static func renderJSON(
        entries: [CodeBuddyKeyEntry],
        accounts: [CodeBuddyAccountCredit],
        bannedCount: Int,
        payBase1000: Double?,
        checkedAt: Date
    ) -> Data {
        let accountByKey = Dictionary(
            accounts.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let accountRows: [[String: Any]] = entries.compactMap { entry in
            guard let account = accountByKey[entry.key] else {
                return nil
            }
            return [
                "key_masked": account.maskedKeyText,
                "source": entry.source ?? NSNull(),
                "label": entry.label,
                "credits": optionalJSONNumber(account.credits),
                "today_used": optionalJSONNumber(account.todayUsed),
                "total_used": optionalJSONNumber(account.totalUsed),
                "total_recharged": optionalJSONNumber(account.totalRecharged),
                "expires_at": expiryJSON(account.expiry),
                "error": optionalJSONString(account.errorMessage),
            ] as [String: Any]
        }
        let payload: [String: Any] = [
            "schema": 1,
            "checked_at": timestampText(checkedAt),
            "pay_base_1000": optionalJSONNumber(payBase1000),
            "banned_count": bannedCount,
            "accounts": accountRows,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else {
            return Data()
        }
        return data
    }

    /// 真正跑：认 key（手加 + 本机自动识别 − 已删）→ 没有就出空表退出 2；
    /// 有就现价 + 全部账号并发查一轮 → 出 JSON 退出 0。单号失败不影响退出码。
    static func run() async -> Never {
        let defaults = SentinelSettings.resolvedDefaults()
        let detected = CodeBuddyKeyDetector.detect()
        let user = SentinelSettings.codeBuddyUserKeys(defaults: defaults)
        let removed = SentinelSettings.codeBuddyRemovedKeys(defaults: defaults)
        let entries = CodeBuddyKeyStore.effectiveEntries(
            detected: detected,
            user: user,
            removedKeys: removed
        )
        guard !entries.isEmpty else {
            write(renderJSON(entries: [], accounts: [], bannedCount: 0, payBase1000: nil, checkedAt: Date()))
            exit(2)
        }
        let client = CodeBuddyCreditClient()
        async let payBase1000 = client.fetchPayBase1000()
        let outcome = await client.fetchOutcome(entries: entries)
        let price = await payBase1000
        write(renderJSON(
            entries: entries,
            accounts: outcome.accounts,
            bannedCount: outcome.bannedCount,
            payBase1000: price,
            checkedAt: Date()
        ))
        exit(0)
    }

    private static func expiryJSON(_ expiry: CodeBuddyExpiry?) -> Any {
        switch expiry {
        case .until(let date):
            return ISO8601DateFormatter().string(from: date)
        case .permanent:
            return "permanent"
        case .absent, nil:
            return NSNull()
        }
    }

    private static func optionalJSONString(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func optionalJSONNumber(_ value: Double?) -> Any {
        value.map { NSNumber(value: $0) } ?? NSNull()
    }

    private static func timestampText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
