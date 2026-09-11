import Foundation

/// Command Code 订阅额度。端点是 Command Code 没写进公开文档、CLI 在用的
/// 账务接口（社区实现持续对着 CLI 1.53.0 验证）：
///   GET https://api.commandcode.ai/alpha/billing/credits  → 月度 credits + 5h/周滚动窗
///   GET https://api.commandcode.ai/alpha/whoami           → 账号身份（tooltip 用）
/// 只查账务不发模型请求，不消耗 credits。接口一变只改这个文件。
struct CommandCodeWindow: Equatable, Sendable {
    /// 已用额度。
    let used: Double?
    /// 窗口上限。
    let cap: Double?
    let exceeded: Bool?
    /// 毫秒时间戳。
    let resetAt: Date?

    var remainingPercentage: Double? {
        guard let used, let cap, cap > 0 else {
            return nil
        }
        return max(0, min(100, (1 - used / cap) * 100))
    }
}

struct CommandCodeAccountUsage: Equatable, Sendable, Identifiable {
    let key: String
    let label: String
    /// /alpha/whoami 返回的账号身份（邮箱或账号名），只进 tooltip。
    let accountIdentity: String?
    let fiveHourWindow: CommandCodeWindow?
    let weeklyWindow: CommandCodeWindow?
    /// 月度剩余 credits（monthly + purchased + free 合计，按返回值算）。
    let monthlyRemainingCredits: Double?
    /// 订阅账期结束时间 = 月度 credits 重置时间（subscriptions 接口拿，失败为空）。
    let periodEnd: Date?
    /// 订阅账期开始时间，算月度倒计时的分母用。
    let periodStart: Date?
    let checkedAt: Date?
    let stale: Bool
    let errorMessage: String?

    var id: String { key }

    var hasDisplayableNumber: Bool {
        fiveHourWindow?.remainingPercentage != nil
            || weeklyWindow?.remainingPercentage != nil
            || monthlyRemainingCredits != nil
    }

    /// 面板行标题：没命名的用「Command Code」兜底；自带名字的补 CC 前缀
    ///（CC Pro / CC 账号1），名字里已经带 CC / Command 的原样显示。
    var displayTitle: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Command Code"
        }
        let lowered = trimmed.lowercased()
        if lowered.contains("command") || lowered.hasPrefix("cc") {
            return trimmed
        }
        return "CC \(trimmed)"
    }

    /// 只露出头尾，完整 key 不进界面不进日志。
    var maskedKeyText: String {
        guard key.count > 12 else {
            return "••••"
        }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }

    static func unavailable(key: String, label: String, errorMessage: String) -> CommandCodeAccountUsage {
        CommandCodeAccountUsage(
            key: key,
            label: label,
            accountIdentity: nil,
            fiveHourWindow: nil,
            weeklyWindow: nil,
            monthlyRemainingCredits: nil,
            periodEnd: nil,
            periodStart: nil,
            checkedAt: nil,
            stale: false,
            errorMessage: errorMessage
        )
    }

    /// 刷新失败时上一轮的好数字原样留着，只标过期和最新报错。
    func merged(old: CommandCodeAccountUsage) -> CommandCodeAccountUsage {
        guard !hasDisplayableNumber else {
            return self
        }
        return CommandCodeAccountUsage(
            key: key,
            label: label,
            accountIdentity: accountIdentity ?? old.accountIdentity,
            fiveHourWindow: old.fiveHourWindow,
            weeklyWindow: old.weeklyWindow,
            monthlyRemainingCredits: old.monthlyRemainingCredits,
            periodEnd: periodEnd ?? old.periodEnd,
            periodStart: periodStart ?? old.periodStart,
            checkedAt: old.checkedAt,
            stale: true,
            errorMessage: errorMessage ?? old.errorMessage
        )
    }
}

struct CommandCodeUsageSnapshot: Equatable, Sendable {
    let accounts: [CommandCodeAccountUsage]
    let checkedAt: Date?

    static let empty = CommandCodeUsageSnapshot(accounts: [], checkedAt: nil)

    func account(forKey key: String) -> CommandCodeAccountUsage? {
        accounts.first { $0.key == key }
    }

    /// 新一轮结果按 key 合进旧快照：失败的账号保留上一轮数字，账号列表以最新 key 集合为准。
    static func merged(
        previous: CommandCodeUsageSnapshot,
        fresh: [CommandCodeAccountUsage],
        now: Date = Date()
    ) -> CommandCodeUsageSnapshot {
        let accounts = fresh.map { account -> CommandCodeAccountUsage in
            guard let old = previous.account(forKey: account.key) else {
                return account
            }
            return account.merged(old: old)
        }
        return CommandCodeUsageSnapshot(accounts: accounts, checkedAt: now)
    }
}

enum CommandCodeUsageClientError: Error, Equatable {
    case unauthorized
    case timedOut
    case network
    case invalidResponse

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "Command Code key 无效或已过期"
        case .timedOut:
            return "Command Code 查询超时"
        case .network:
            return "Command Code 接口暂不可达"
        case .invalidResponse:
            return "Command Code 额度格式已变化"
        }
    }
}

enum CommandCodeUsageConstants {
    static let creditsEndpoint = URL(string: "https://api.commandcode.ai/alpha/billing/credits")!
    static let whoamiEndpoint = URL(string: "https://api.commandcode.ai/alpha/whoami")!
    static let subscriptionEndpoint = URL(string: "https://api.commandcode.ai/alpha/billing/subscriptions")!
    /// CLI 的 account routes 对版本头敏感，跟着已验证的 CLI 版本走。
    static let cliVersionHeaderValue = "1.53.0"
    static let cliEnvironmentHeaderValue = "production"
    /// 额度是慢变量，跟 GLM / Cursor / GPT 官方同一档刷新间隔。
    static let automaticRefreshInterval: TimeInterval = 10 * 60
    static let requestTimeout: TimeInterval = 15
    static let minKeyLength = 16
    /// 月度 credits 低于这个数（美元）行点变橙提醒。
    static let lowMonthlyCredits: Double = 5
}

protocol CommandCodeRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CommandCodeRequestLoading {}

struct CommandCodeUsageClient: Sendable {
    private let creditsEndpoint: URL
    private let whoamiEndpoint: URL
    private let subscriptionEndpoint: URL
    private let requestLoader: any CommandCodeRequestLoading

    init(
        creditsEndpoint: URL = CommandCodeUsageConstants.creditsEndpoint,
        whoamiEndpoint: URL = CommandCodeUsageConstants.whoamiEndpoint,
        subscriptionEndpoint: URL = CommandCodeUsageConstants.subscriptionEndpoint,
        requestLoader: any CommandCodeRequestLoading = URLSession.shared
    ) {
        self.creditsEndpoint = creditsEndpoint
        self.whoamiEndpoint = whoamiEndpoint
        self.subscriptionEndpoint = subscriptionEndpoint
        self.requestLoader = requestLoader
    }

    /// 并发查所有 key，结果按 entries 顺序排好；失败不抛出，
    /// 落成带 errorMessage 的账号行，由 merge 决定要不要保留旧数字。
    func fetchAll(entries: [CommandCodeKeyEntry]) async -> [CommandCodeAccountUsage] {
        await withTaskGroup(of: CommandCodeAccountUsage.self) { group in
            for entry in entries {
                group.addTask { [creditsEndpoint, whoamiEndpoint, subscriptionEndpoint, requestLoader] in
                    do {
                        return try await Self.fetch(
                            key: entry.key,
                            label: entry.label,
                            creditsEndpoint: creditsEndpoint,
                            whoamiEndpoint: whoamiEndpoint,
                            subscriptionEndpoint: subscriptionEndpoint,
                            requestLoader: requestLoader
                        )
                    } catch let error as CommandCodeUsageClientError {
                        return .unavailable(key: entry.key, label: entry.label, errorMessage: error.userMessage)
                    } catch {
                        return .unavailable(key: entry.key, label: entry.label, errorMessage: CommandCodeUsageClientError.network.userMessage)
                    }
                }
            }
            var results: [String: CommandCodeAccountUsage] = [:]
            for await account in group {
                results[account.key] = account
            }
            return entries.compactMap { results[$0.key] }
        }
    }

    /// 额度是主接口，whoami 只是身份补充：额度挂了才算探测失败走 preserve，
    /// whoami 挂了不影响数字。
    static func fetch(
        key: String,
        label: String,
        creditsEndpoint: URL,
        whoamiEndpoint: URL,
        subscriptionEndpoint: URL,
        requestLoader: any CommandCodeRequestLoading,
        now: Date = Date()
    ) async throws -> CommandCodeAccountUsage {
        async let creditsOutcome = authorizedGet(apiKey: key, endpoint: creditsEndpoint, requestLoader: requestLoader)
        async let whoamiOutcome = try? authorizedGet(apiKey: key, endpoint: whoamiEndpoint, requestLoader: requestLoader)
        async let subscriptionOutcome = try? authorizedGet(apiKey: key, endpoint: subscriptionEndpoint, requestLoader: requestLoader)
        let creditsData = try await creditsOutcome
        let whoamiData = await whoamiOutcome
        let subscriptionData = await subscriptionOutcome

        let payload = try parseCreditsPayload(data: creditsData)
        let identity = whoamiData.flatMap(Self.parseAccountIdentity(data:))
        let period = subscriptionData.flatMap(Self.parseSubscriptionPeriod(data:))
        let periodEnd = period?.end
        let periodStart = period?.start
        let monthlyRemaining = [payload.credits?.monthlyCredits,
                                payload.credits?.purchasedCredits,
                                payload.credits?.freeCredits]
            .compactMap { $0 }
            .reduce(0, +)
        let hasMonthlyFigure = payload.credits?.monthlyCredits != nil
            || payload.credits?.purchasedCredits != nil
            || payload.credits?.freeCredits != nil
        return CommandCodeAccountUsage(
            key: key,
            label: label,
            accountIdentity: identity,
            fiveHourWindow: payload.windowLimits?.fiveHour.map(Self.window(from:)),
            weeklyWindow: payload.windowLimits?.weekly.map(Self.window(from:)),
            monthlyRemainingCredits: hasMonthlyFigure ? monthlyRemaining : nil,
            periodEnd: periodEnd,
            periodStart: periodStart,
            checkedAt: now,
            stale: false,
            errorMessage: nil
        )
    }

    private static func window(from raw: CommandCodeUsageResponse.Window) -> CommandCodeWindow {
        CommandCodeWindow(
            used: raw.used,
            cap: raw.cap,
            exceeded: raw.exceeded,
            resetAt: raw.resetAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    private static func authorizedGet(
        apiKey: String,
        endpoint: URL,
        requestLoader: any CommandCodeRequestLoading
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = CommandCodeUsageConstants.requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(CommandCodeUsageConstants.cliVersionHeaderValue, forHTTPHeaderField: "x-command-code-version")
        request.setValue(CommandCodeUsageConstants.cliEnvironmentHeaderValue, forHTTPHeaderField: "x-cli-environment")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CortexSentinel/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await requestLoader.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommandCodeUsageClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CommandCodeUsageClientError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CommandCodeUsageClientError.invalidResponse
        }
        return data
    }

    static func parseCreditsPayload(data: Data) throws -> CommandCodeUsageResponse {
        do {
            return try JSONDecoder().decode(CommandCodeUsageResponse.self, from: data)
        } catch {
            throw CommandCodeUsageClientError.invalidResponse
        }
    }

    struct SubscriptionPeriod: Equatable, Sendable {
        let start: Date?
        let end: Date?
    }

    /// /alpha/billing/subscriptions 的 data.currentPeriodStart/End（ISO8601 带毫秒），
    /// 账期结束即月度 credits 重置时间。解析不了返回 nil，不影响额度数字。
    static func parseSubscriptionPeriod(data: Data) -> SubscriptionPeriod? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (object["data"] as? [String: Any]) ?? object
        let end = (payload["currentPeriodEnd"] as? String).flatMap {
            Self.isoFormatter.date(from: $0) ?? Self.isoFormatterNoFraction.date(from: $0)
        }
        let start = (payload["currentPeriodStart"] as? String).flatMap {
            Self.isoFormatter.date(from: $0) ?? Self.isoFormatterNoFraction.date(from: $0)
        }
        guard end != nil || start != nil else {
            return nil
        }
        return SubscriptionPeriod(start: start, end: end)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let isoFormatterNoFraction = ISO8601DateFormatter()

    /// whoami 的返回形态没进公开文档，用 JSONSerialization 容错提取：
    /// 顶层或 user/account 嵌套里，优先邮箱，其次 name，最后 id。
    static func parseAccountIdentity(data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        var candidates: [[String: Any]] = [dictionary]
        for nestedKey in ["user", "account", "data"] {
            if let nested = dictionary[nestedKey] as? [String: Any] {
                candidates.append(nested)
            }
        }
        for candidate in candidates {
            if let identity = identityString(in: candidate, containing: "email") {
                return identity
            }
        }
        for candidate in candidates {
            if let identity = identityString(in: candidate, containing: "name") {
                return identity
            }
        }
        for candidate in candidates {
            if let identity = identityString(in: candidate, containing: "id") {
                return identity
            }
        }
        return nil
    }

    private static func identityString(in dictionary: [String: Any], containing fragment: String) -> String? {
        for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) {
            guard key.lowercased().contains(fragment), let text = value as? String, !text.isEmpty else {
                continue
            }
            return text
        }
        return nil
    }
}

/// /alpha/billing/credits 的返回。数值容错：服务端偶尔把数字序列化成字符串。
struct CommandCodeUsageResponse: Decodable {
    let credits: Credits?
    let windowLimits: WindowLimits?

    struct Credits: Decodable {
        let monthlyCredits: Double?
        let purchasedCredits: Double?
        let freeCredits: Double?

        enum CodingKeys: String, CodingKey {
            case monthlyCredits
            case purchasedCredits
            case freeCredits
        }

        init(monthlyCredits: Double?, purchasedCredits: Double?, freeCredits: Double?) {
            self.monthlyCredits = monthlyCredits
            self.purchasedCredits = purchasedCredits
            self.freeCredits = freeCredits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            monthlyCredits = try container.decodeFlexibleDoubleIfPresent(forKey: .monthlyCredits)
            purchasedCredits = try container.decodeFlexibleDoubleIfPresent(forKey: .purchasedCredits)
            freeCredits = try container.decodeFlexibleDoubleIfPresent(forKey: .freeCredits)
        }
    }

    struct WindowLimits: Decodable {
        let fiveHour: Window?
        let weekly: Window?
    }

    struct Window: Decodable {
        let used: Double?
        let cap: Double?
        let exceeded: Bool?
        /// 毫秒时间戳。
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case used
            case cap
            case exceeded
            case resetAt
        }

        init(used: Double?, cap: Double?, exceeded: Bool?, resetAt: Double?) {
            self.used = used
            self.cap = cap
            self.exceeded = exceeded
            self.resetAt = resetAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = try container.decodeFlexibleDoubleIfPresent(forKey: .used)
            cap = try container.decodeFlexibleDoubleIfPresent(forKey: .cap)
            if let bool = try? container.decodeIfPresent(Bool.self, forKey: .exceeded) {
                exceeded = bool
            } else {
                exceeded = nil
            }
            resetAt = try container.decodeFlexibleDoubleIfPresent(forKey: .resetAt)
        }
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
}

// MARK: - key 识别与键池

struct CommandCodeKeyEntry: Equatable, Codable, Sendable, Identifiable {
    let label: String
    let key: String

    var id: String { key }

    /// 设置列表里只露头尾，完整 key 不进界面。
    var maskedKeyText: String {
        guard key.count > 12 else {
            return "••••"
        }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }
}

enum CommandCodeKeyConstants {
    /// 哨兵是 launchd 拉起的，环境变量只在手动前台跑时才大概率有。
    static let environmentKeyNames = [
        "COMMAND_CODE_API_KEY",
        "COMMANDCODE_API_KEY",
    ]
    /// 官方 CLI `cmd login` 写下的登录态（社区实现通用的读取口径）。
    static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".commandcode/auth.json")
    }
}

/// 从本机已有的配置里把 Command Code key 认出来。只读，不写不改：
/// 先环境变量，再官方 CLI 的 auth.json（`cmd login` 生成）。
/// auth.json 形态参照 CLI 生态通用解析：顶层 apiKey / commandcode 直取，
/// 或 commandcode / command-code 嵌套记录按 type 取 key（api）或 access（oauth）。
enum CommandCodeKeyDetector {
    static func detect(
        environment: [String: String],
        authFileURL: URL = CommandCodeKeyConstants.authFileURL,
        fileManager: FileManager = .default
    ) -> [CommandCodeKeyEntry] {
        var entries: [CommandCodeKeyEntry] = []
        for name in CommandCodeKeyConstants.environmentKeyNames {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.count >= CommandCodeUsageConstants.minKeyLength else {
                continue
            }
            entries.append(CommandCodeKeyEntry(label: "Command Code", key: value))
        }
        if let key = Self.authFileKey(at: authFileURL, fileManager: fileManager),
           key.count >= CommandCodeUsageConstants.minKeyLength {
            entries.append(CommandCodeKeyEntry(label: "CLI 登录", key: key))
        }
        return entries
    }

    /// 解析 auth.json；坏文件当没有，绝不抛错拖慢刷新。
    static func authFileKey(at url: URL, fileManager: FileManager = .default) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let direct = stringField(parsed["apiKey"]) ?? stringField(parsed["commandcode"]) {
            return direct
        }
        return credentialRecordKey(parsed["commandcode"])
            ?? credentialRecordKey(parsed["command-code"])
    }

    /// 嵌套凭证记录：type=api 取 key，type=oauth 取 access，没标 type 依次兜底。
    private static func credentialRecordKey(_ value: Any?) -> String? {
        guard let record = value as? [String: Any] else {
            return nil
        }
        switch stringField(record["type"]) {
        case "api":
            return stringField(record["key"])
        case "oauth":
            return stringField(record["access"])
        default:
            return stringField(record["key"]) ?? stringField(record["access"])
        }
    }

    private static func stringField(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 用户手维护的 key 列表 + 删掉的自动识别 key（防止下次启动又认回来）。
/// 与 GLM 同一套结构，落 UserDefaults，JSON 编码。
enum CommandCodeKeyStore {
    static func effectiveEntries(
        detected: [CommandCodeKeyEntry],
        user: [CommandCodeKeyEntry],
        removedKeys: Set<String>
    ) -> [CommandCodeKeyEntry] {
        var byKey: [String: CommandCodeKeyEntry] = [:]
        var order: [String] = []
        for entry in detected + user where !removedKeys.contains(entry.key) {
            if byKey[entry.key] == nil {
                byKey[entry.key] = entry
                order.append(entry.key)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

// MARK: - 供应商改名

/// 面板点名字改名的命名空间。AIO 那一堆不参与（名字跟网关库走）。
enum ProviderRenameNamespace {
    static let glm = "glm"
    static let commandCode = "commandcode"
}

/// 拖拽排序的纯逻辑：可单测。登记过的 key 按用户顺序，没登记过的保持原相对顺序。
enum ProviderOrdering {
    static func ordered<T: ProviderAccount>(_ accounts: [T], order: [String]) -> [T] {
        accounts.enumerated().sorted { l, r in
            let li = order.firstIndex(of: l.element.key) ?? Int.max
            let ri = order.firstIndex(of: r.element.key) ?? Int.max
            if li != ri {
                return li < ri
            }
            return l.offset < r.offset
        }.map(\.element)
    }

    /// 把 key 挪到 target 位；key 不在表里或位置没变时原样返回。
    static func moved(keys: [String], key: String, toIndex target: Int) -> [String] {
        var next = keys.filter { $0 != key }
        guard next.count == keys.count - 1 else {
            return keys
        }
        next.insert(key, at: max(0, min(next.count, target)))
        return next
    }
}

/// 面板里直接点名字改显示名的持久化层。
/// 覆盖名按「命名空间:完整 key」存，key 换了覆盖自然失效。
enum ProviderRenameStore {
    static func displayName(
        defaults: UserDefaults,
        id: String,
        fallback: String
    ) -> String {
        renames(defaults: defaults)[id] ?? fallback
    }

    /// 空名字等于清除覆盖，回到默认名。
    static func setDisplayName(defaults: UserDefaults, id: String, name: String) {
        var table = renames(defaults: defaults)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            table.removeValue(forKey: id)
            defaults.set(encode(table), forKey: SentinelSettingsKey.providerRenames)
            return
        }
        table[id] = trimmed
        defaults.set(encode(table), forKey: SentinelSettingsKey.providerRenames)
    }

    static func renames(defaults: UserDefaults) -> [String: String] {
        guard let data = defaults.data(forKey: SentinelSettingsKey.providerRenames) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func encode(_ table: [String: String]) -> Data? {
        try? JSONEncoder().encode(table)
    }
}
