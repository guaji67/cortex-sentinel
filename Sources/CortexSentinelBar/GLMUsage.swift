import Foundation

/// 智谱 GLM Coding Plan 订阅额度。
/// 端点是智谱没写进文档、社区通用的账务接口（ClaudePanel 用的同一条）：
/// GET https://open.bigmodel.cn/api/monitor/usage/quota/limit，Bearer key。
/// 返回 data.limits[] 两个 CREDIT_LIMIT 窗：5 小时滚动（unit=3, number=5）和
/// 周（unit=6, number=1），percentage 是已用百分比，usage 总积分，
/// currentValue 已用积分，nextResetTime 毫秒时间戳。只查账务不烧对话额度。
struct GLMUsageWindow: Equatable, Sendable {
    /// 窗口总积分（响应里的 `usage` 字段是总量，不是已用）。
    let totalPoints: Double?
    /// 已用积分（`currentValue`）。
    let usedPoints: Double?
    /// 已用百分比（`percentage`，0-100）。
    let percentUsed: Double?
    let resetAt: Date?

    var remainingPercentage: Double? {
        percentUsed.map { min(100, max(0, 100 - $0)) }
    }
}

struct GLMAccountUsage: Equatable, Sendable, Identifiable {
    let key: String
    let label: String
    /// 官方返回的订阅档位（pro / lite），随额度一起回来。
    let level: String?
    let fiveHourWindow: GLMUsageWindow?
    let weeklyWindow: GLMUsageWindow?
    let checkedAt: Date?
    let stale: Bool
    let errorMessage: String?

    var id: String { key }

    var hasDisplayableNumber: Bool {
        fiveHourWindow?.percentUsed != nil || weeklyWindow?.percentUsed != nil
    }

    /// 面板行标题：pro / lite 这类短档位名接在 GLM 后面，环境变量名原样当名字。
    var displayTitle: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "GLM"
        }
        return trimmed.lowercased().hasPrefix("glm") ? trimmed : "GLM \(trimmed)"
    }

    /// 只露出头尾，完整 key 不进界面不进日志。
    var maskedKeyText: String {
        guard key.count > 12 else {
            return "••••"
        }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }

    static func unavailable(key: String, label: String, errorMessage: String) -> GLMAccountUsage {
        GLMAccountUsage(
            key: key,
            label: label,
            level: nil,
            fiveHourWindow: nil,
            weeklyWindow: nil,
            checkedAt: nil,
            stale: false,
            errorMessage: errorMessage
        )
    }

    /// 刷新失败时上一轮的好数字原样留着，只标过期和最新报错。
    func merged(old: GLMAccountUsage) -> GLMAccountUsage {
        guard !hasDisplayableNumber else {
            return self
        }
        return GLMAccountUsage(
            key: key,
            label: label,
            level: level ?? old.level,
            fiveHourWindow: old.fiveHourWindow,
            weeklyWindow: old.weeklyWindow,
            checkedAt: old.checkedAt,
            stale: true,
            errorMessage: errorMessage ?? old.errorMessage
        )
    }
}

struct GLMUsageSnapshot: Equatable, Sendable {
    let accounts: [GLMAccountUsage]
    let checkedAt: Date?

    static let empty = GLMUsageSnapshot(accounts: [], checkedAt: nil)

    func account(forKey key: String) -> GLMAccountUsage? {
        accounts.first { $0.key == key }
    }

    /// 新一轮结果按 key 合进旧快照：失败的账号保留上一轮数字（合并逻辑在
    /// GLMAccountUsage.merged），账号列表整体以最新识别的 key 集合为准。
    static func merged(previous: GLMUsageSnapshot, fresh: [GLMAccountUsage], now: Date = Date()) -> GLMUsageSnapshot {
        let accounts = fresh.map { account -> GLMAccountUsage in
            guard let old = previous.account(forKey: account.key) else {
                return account
            }
            return account.merged(old: old)
        }
        return GLMUsageSnapshot(accounts: accounts, checkedAt: now)
    }
}

enum GLMUsageClientError: Error, Equatable {
    case unauthorized
    case timedOut
    case network
    case invalidResponse

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "智谱 key 无效或已过期"
        case .timedOut:
            return "智谱查询超时"
        case .network:
            return "智谱接口暂不可达"
        case .invalidResponse:
            return "智谱额度格式已变化"
        }
    }
}

enum GLMUsageConstants {
    static let endpoint = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    /// 余额属于慢变量，跟 Cursor / GPT 官方同一档刷新间隔。
    static let automaticRefreshInterval: TimeInterval = 10 * 60
    static let requestTimeout: TimeInterval = 15
}

protocol GLMUsageRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GLMUsageRequestLoading {}

struct GLMUsageClient: Sendable {
    private let endpoint: URL
    private let requestLoader: any GLMUsageRequestLoading

    init(
        endpoint: URL = GLMUsageConstants.endpoint,
        requestLoader: any GLMUsageRequestLoading = URLSession.shared
    ) {
        self.endpoint = endpoint
        self.requestLoader = requestLoader
    }

    /// 并发查所有 key，结果按 entries 顺序排好；失败不抛出，
    /// 落成带 errorMessage 的账号行，由 merge 决定要不要保留旧数字。
    func fetchAll(entries: [GLMKeyEntry]) async -> [GLMAccountUsage] {
        await withTaskGroup(of: GLMAccountUsage.self) { group in
            for entry in entries {
                group.addTask { [endpoint, requestLoader] in
                    do {
                        return try await Self.fetch(
                            key: entry.key,
                            label: entry.label,
                            endpoint: endpoint,
                            requestLoader: requestLoader
                        )
                    } catch let error as GLMUsageClientError {
                        return .unavailable(key: entry.key, label: entry.label, errorMessage: error.userMessage)
                    } catch {
                        return .unavailable(key: entry.key, label: entry.label, errorMessage: GLMUsageClientError.network.userMessage)
                    }
                }
            }
            var results: [String: GLMAccountUsage] = [:]
            for await account in group {
                results[account.key] = account
            }
            return entries.compactMap { results[$0.key] }
        }
    }

    static func fetch(
        key: String,
        label: String,
        endpoint: URL,
        requestLoader: any GLMUsageRequestLoading,
        now: Date = Date()
    ) async throws -> GLMAccountUsage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = GLMUsageConstants.requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CortexSentinel/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestLoader.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw GLMUsageClientError.timedOut
        } catch {
            throw GLMUsageClientError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GLMUsageClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw GLMUsageClientError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GLMUsageClientError.invalidResponse
        }
        return try parse(data: data, key: key, label: label, checkedAt: now)
    }

    static func parse(data: Data, key: String, label: String, checkedAt: Date) throws -> GLMAccountUsage {
        guard let payload = try? JSONDecoder().decode(GLMQuotaResponse.self, from: data),
              let limits = payload.data?.limits
        else {
            throw GLMUsageClientError.invalidResponse
        }
        let credits = limits.filter { $0.type == nil || $0.type == "CREDIT_LIMIT" }
        guard !credits.isEmpty else {
            // key 有效但账号没有积分窗（Coding Plan 体验卡到期就是这样，
        // 只剩 MCP 包的 TIME_LIMIT）：不算格式变化，如实显示无订阅额度。
            return GLMAccountUsage(
                key: key,
                label: label,
                level: payload.data?.level,
                fiveHourWindow: nil,
                weeklyWindow: nil,
                checkedAt: checkedAt,
                stale: false,
                errorMessage: nil
            )
        }
        let windows = Self.classifyWindows(credits)
        return GLMAccountUsage(
            key: key,
            label: label,
            level: payload.data?.level,
            fiveHourWindow: windows.fiveHour,
            weeklyWindow: windows.weekly,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil
        )
    }

    /// 两个窗哪个是 5 小时、哪个是周：先认官方的 unit 编号（3=小时窗、6=周窗），
    /// 编号没见过再按总积分猜——5 小时窗的池子一定比周窗小。
    static func classifyWindows(
        _ limits: [GLMQuotaResponse.Limit]
    ) -> (fiveHour: GLMUsageWindow?, weekly: GLMUsageWindow?) {
        func window(_ limit: GLMQuotaResponse.Limit) -> GLMUsageWindow { limit.window }
        if let hour = limits.first(where: { $0.unit == 3 }) {
            return (window(hour), limits.first(where: { $0.unit != 3 }).map(window))
        }
        if let week = limits.first(where: { $0.unit == 6 }) {
            return (limits.first(where: { $0.unit != 6 }).map(window), window(week))
        }
        let sorted = limits.sorted { ($0.usage ?? 0) < ($1.usage ?? 0) }
        guard let first = sorted.first else {
            return (nil, nil)
        }
        return (window(first), sorted.count > 1 ? window(sorted[sorted.count - 1]) : nil)
    }
}

struct GLMQuotaResponse: Decodable {
    let data: Payload?

    struct Payload: Decodable {
        let limits: [Limit]?
        let level: String?
    }

    struct Limit: Decodable {
        let type: String?
        let unit: Int?
        let number: Int?
        /// 总积分。
        let usage: Double?
        /// 已用积分。
        let currentValue: Double?
        /// 已用百分比。
        let percentage: Double?
        /// 毫秒时间戳。
        let nextResetTime: Double?

        enum CodingKeys: String, CodingKey {
            case type
            case unit
            case number
            case usage
            case currentValue
            case percentage
            case nextResetTime
        }

        init(
            type: String?,
            unit: Int?,
            number: Int?,
            usage: Double?,
            currentValue: Double?,
            percentage: Double?,
            nextResetTime: Double?
        ) {
            self.type = type
            self.unit = unit
            self.number = number
            self.usage = usage
            self.currentValue = currentValue
            self.percentage = percentage
            self.nextResetTime = nextResetTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            unit = try container.decodeFlexibleIntIfPresent(forKey: .unit)
            number = try container.decodeFlexibleIntIfPresent(forKey: .number)
            usage = try container.decodeFlexibleDoubleIfPresent(forKey: .usage)
            currentValue = try container.decodeFlexibleDoubleIfPresent(forKey: .currentValue)
            percentage = try container.decodeFlexibleDoubleIfPresent(forKey: .percentage)
            nextResetTime = try container.decodeFlexibleDoubleIfPresent(forKey: .nextResetTime)
        }

        var window: GLMUsageWindow {
            GLMUsageWindow(
                totalPoints: usage,
                usedPoints: currentValue,
                percentUsed: percentage,
                resetAt: nextResetTime.map {
                    Date(timeIntervalSince1970: $0 / 1000)
                }
            )
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

struct GLMKeyEntry: Equatable, Codable, Sendable, Identifiable {
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

enum GLMKeyConstants {
    static let minKeyLength = 20
    /// 常见的环境变量名；哨兵是 launchd 拉起的，这些只在手动前台跑时才大概率有。
    static let environmentKeyNames = [
        "ZAI_API_KEY",
        "ZHIPU_API_KEY",
        "ZHIPUAI_API_KEY",
        "GLM_API_KEY",
        "BIGMODEL_API_KEY",
    ]
    /// ClaudeZ 键池（ClaudePanel 体系在用的那把正本，600 权限）。
    static var accountsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-zx-accounts/accounts.json")
    }
    /// ClaudeZ 转换层 .env 里的余额 key。
    static var proxyEnvFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude-zhipu-proxy/.env")
    }
    /// ClaudeG 免费池的登录 token（settings-claudeg.json 的 ANTHROPIC_AUTH_TOKEN）。
    static var claudeGSettingsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings-claudeg.json")
    }
}

/// 从本机已有的配置里把智谱 key 认出来。只读文件，不写不改；
/// 同一把 key 多处出现时保留先识别到的来源命名。
enum GLMKeyDetector {
    static func detect(
        environment: [String: String],
        accountsFileURL: URL = GLMKeyConstants.accountsFileURL,
        proxyEnvFileURL: URL = GLMKeyConstants.proxyEnvFileURL,
        claudeGSettingsFileURL: URL = GLMKeyConstants.claudeGSettingsFileURL,
        fileManager: FileManager = .default
    ) -> [GLMKeyEntry] {
        var byKey: [String: GLMKeyEntry] = [:]
        var order: [String] = []

        func add(_ entry: GLMKeyEntry) {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.count >= GLMKeyConstants.minKeyLength else {
                return
            }
            if byKey[key] == nil {
                byKey[key] = GLMKeyEntry(label: entry.label, key: key)
                order.append(key)
            }
        }

        for name in GLMKeyConstants.environmentKeyNames {
            if let value = environment[name] {
                add(GLMKeyEntry(label: name, key: value))
            }
        }

        if fileManager.fileExists(atPath: accountsFileURL.path),
           let data = try? Data(contentsOf: accountsFileURL),
           let accounts = try? JSONDecoder().decode([String: GLMKeyPoolAccount].self, from: data) {
            // 字典遍历顺序不稳定，按账号名排序保证 key 列表顺序确定。
            for name in accounts.keys.sorted() {
                guard let account = accounts[name], let key = account.key else {
                    continue
                }
                add(GLMKeyEntry(label: account.label ?? name, key: key))
            }
        }

        if fileManager.fileExists(atPath: claudeGSettingsFileURL.path),
           let data = try? Data(contentsOf: claudeGSettingsFileURL),
           let payload = try? JSONDecoder().decode([String: String].self, from: data),
           let token = payload["ANTHROPIC_AUTH_TOKEN"] {
            add(GLMKeyEntry(label: "免费池", key: token))
        }

        if fileManager.fileExists(atPath: proxyEnvFileURL.path),
           let content = try? String(contentsOf: proxyEnvFileURL, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "OPENAI_API_KEY" else {
                    continue
                }
                add(GLMKeyEntry(label: "ClaudeZ", key: String(parts[1])))
            }
        }

        return order.compactMap { byKey[$0] }
    }

    private struct GLMKeyPoolAccount: Decodable {
        let label: String?
        let key: String?
    }
}

/// 用户在设置里手维护的 key 列表 + 删掉的自动识别 key（防止下次启动又认回来）。
/// 都落 UserDefaults，JSON 编码。
enum GLMKeyStore {
    static func effectiveEntries(
        detected: [GLMKeyEntry],
        user: [GLMKeyEntry],
        removedKeys: Set<String>
    ) -> [GLMKeyEntry] {
        var byKey: [String: GLMKeyEntry] = [:]
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
