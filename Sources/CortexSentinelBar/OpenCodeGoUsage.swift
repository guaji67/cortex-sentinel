import Foundation

/// OpenCode Go 订阅额度。端点是 opencode.ai 没写进公开文档、拿 API key 就能查的
/// 用量接口（官方只让在网页控制台看用量，社区在 anomalyco/opencode issue #16017
/// 要公开查询接口）：
///   GET https://opencode.ai/zen/go/v1/usage → usage.rolling(5 小时) / weekly / monthly
/// 每段 {status, percent, resetsAt}：percent 是已用百分比、resetsAt 是 ISO 重置时刻；
/// 社区另见过 reset_in_sec（相对秒数）写法，两种都认。只查用量不发模型请求，
/// 不消耗额度。接口一变只改这个文件。
struct OpenCodeGoWindow: Equatable, Sendable {
    /// 官方状态字段；"ok" 之外的值行点标红。字段缺失不当异常（不当 0% 也不标红）。
    let status: String?
    /// 已用百分比（0-100，接口原生口径）。
    let percentUsed: Double?
    /// 重置时刻：resetsAt ISO 解析，或 now + reset_in_sec 换算。
    let resetAt: Date?

    /// 剩余百分比（= 100 − 已用）。缺 percent 给 nil——绝不当 0%。
    var remainingPercentage: Double? {
        percentUsed.map { min(100, max(0, 100 - $0)) }
    }

    /// status 字段在且不是 "ok"（大小写不敏感、去空白）；缺失视为没异常。
    var statusIsNotOK: Bool {
        guard let status else {
            return false
        }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.lowercased() != "ok"
    }
}

struct OpenCodeGoUsageSnapshot: Equatable, Sendable {
    /// 5 小时滚动窗。
    let rolling: OpenCodeGoWindow?
    let weekly: OpenCodeGoWindow?
    let monthly: OpenCodeGoWindow?
    let checkedAt: Date?
    /// 上一轮成功后的数字被这轮失败沿用时置位。
    let stale: Bool
    /// 抓取/解析失败原因（人话）；成功轮为 nil。
    let errorMessage: String?

    /// 识别到 key、首次取数还没回来：行显示「等待查询」。
    static let waiting = OpenCodeGoUsageSnapshot(
        rolling: nil,
        weekly: nil,
        monthly: nil,
        checkedAt: nil,
        stale: false,
        errorMessage: nil
    )

    static func failure(errorMessage: String) -> OpenCodeGoUsageSnapshot {
        OpenCodeGoUsageSnapshot(
            rolling: nil,
            weekly: nil,
            monthly: nil,
            checkedAt: nil,
            stale: false,
            errorMessage: errorMessage
        )
    }

    var hasDisplayableNumber: Bool {
        rolling?.remainingPercentage != nil
            || weekly?.remainingPercentage != nil
            || monthly?.remainingPercentage != nil
    }

    /// 任一段 status 不是 ok（去重保序），悬停告警用。
    var nonOKStatuses: [String] {
        var seen = Set<String>()
        var statuses: [String] = []
        for window in [rolling, weekly, monthly].compactMap({ $0 }) where window.statusIsNotOK {
            let status = window.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !status.isEmpty, seen.insert(status).inserted {
                statuses.append(status)
            }
        }
        return statuses
    }

    var statusNotOK: Bool {
        !nonOKStatuses.isEmpty
    }

    /// 行右侧文案：有数字给 nil（走三段格子）；读不到 / 解析失败「不知道」；
    /// 首次取数没回来「等待查询」。任何情况下绝不出现 0%。
    var rowStatusText: String? {
        if hasDisplayableNumber {
            return nil
        }
        if errorMessage != nil || checkedAt != nil {
            return OpenCodeGoUsageConstants.unknownText
        }
        return BalanceSectionPresentation.queryingStatusText
    }

    /// 刷新失败时上一轮的好数字原样留着，只标过期和最新报错。
    func merged(old: OpenCodeGoUsageSnapshot) -> OpenCodeGoUsageSnapshot {
        guard !hasDisplayableNumber else {
            return self
        }
        return OpenCodeGoUsageSnapshot(
            rolling: old.rolling,
            weekly: old.weekly,
            monthly: old.monthly,
            // 新一轮有取数时刻（成功但空）时用新的，行才会从「等待查询」
            // 落到「不知道」而不是永远等；失败轮 checkedAt 为 nil 沿用旧值。
            checkedAt: checkedAt ?? old.checkedAt,
            stale: true,
            errorMessage: errorMessage ?? old.errorMessage
        )
    }

    /// 新一轮结果合进旧快照：失败保留上一轮数字（合并逻辑在 merged(old:)）。
    static func merged(
        previous: OpenCodeGoUsageSnapshot?,
        fresh: OpenCodeGoUsageSnapshot,
        now: Date = Date()
    ) -> OpenCodeGoUsageSnapshot {
        guard let previous else {
            return fresh
        }
        return fresh.merged(old: previous)
    }
}

enum OpenCodeGoUsageClientError: Error, Equatable {
    case unauthorized
    case timedOut
    case network
    case invalidResponse

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "OpenCode Go key 无效或已过期"
        case .timedOut:
            return "OpenCode Go 查询超时"
        case .network:
            return "OpenCode Go 接口暂不可达"
        case .invalidResponse:
            return "OpenCode Go 额度格式已变化"
        }
    }
}

enum OpenCodeGoUsageConstants {
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    /// 额度是慢变量，跟 GLM / Cursor / Command Code 同一档刷新间隔。
    static let automaticRefreshInterval: TimeInterval = 10 * 60
    static let requestTimeout: TimeInterval = 15
    static let minKeyLength = 16
    /// 哨兵自己的名字和版本（跟同仓其它额度接口同一口径，不用通用库名）。
    static let userAgent = "CortexSentinel/1.0"
    /// Go 的模型接口不带这个头会被拒，这个接口也带上（固定值）。
    static let sessionHeaderValue = "cortex-sentinel"
    /// 读不到 / 解析失败时行上显示的字，绝不当 0%。
    static let unknownText = "不知道"
}

/// 悬停卡的重置时刻文案：相对时间 + 北京钟点。三台机器三个时区，
/// 报给 Falcon 的钟点一律 Asia/Shanghai。
enum OpenCodeGoResetText {
    /// 离重置还有多久：1 小时内按分钟、1 天内按小时、再往上按天，
    /// 都四舍五入到最接近的整数；已经过了点说「已到重置时间」。
    static func relative(to date: Date, now: Date) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else {
            return "已到重置时间"
        }
        if remaining < 3600 {
            return "\(max(1, Int((remaining / 60).rounded()))) 分钟后"
        }
        if remaining < 86_400 {
            return "\(max(1, Int((remaining / 3600).rounded()))) 小时后"
        }
        return "\(max(1, Int((remaining / 86_400).rounded()))) 天后"
    }

    private static let beijingFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        formatter.timeZone = OfficialQuotaPresentation.displayTimeZone
        return formatter
    }()

    /// 北京钟点，格式 M/d HH:mm。
    static func beijingClock(_ date: Date) -> String {
        beijingFormatter.string(from: date)
    }

    /// 悬停备注整句：「2 小时后 · 14:50」（钟点为北京时间，
    /// 「北京时间」标在卡片副标题里——备注列放不下）。
    static func resetNote(resetAt: Date, now: Date) -> String {
        "\(relative(to: resetAt, now: now)) · \(beijingClock(resetAt))"
    }
}

protocol OpenCodeGoRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OpenCodeGoRequestLoading {}

struct OpenCodeGoUsageClient: Sendable {
    private let endpoint: URL
    private let requestLoader: any OpenCodeGoRequestLoading

    init(
        endpoint: URL = OpenCodeGoUsageConstants.endpoint,
        requestLoader: any OpenCodeGoRequestLoading = URLSession.shared
    ) {
        self.endpoint = endpoint
        self.requestLoader = requestLoader
    }

    /// 只查用量不发模型请求。失败不抛：落成带 errorMessage 的快照，
    /// 由 merge 决定要不要保留上一轮数字。
    func fetch(key: String, now: Date = Date()) async -> OpenCodeGoUsageSnapshot {
        do {
            let data = try await Self.authorizedGet(
                apiKey: key,
                endpoint: endpoint,
                requestLoader: requestLoader
            )
            let windows = try Self.parseWindows(data: data, now: now)
            return OpenCodeGoUsageSnapshot(
                rolling: windows.rolling,
                weekly: windows.weekly,
                monthly: windows.monthly,
                checkedAt: now,
                stale: false,
                errorMessage: nil
            )
        } catch let error as OpenCodeGoUsageClientError {
            return .failure(errorMessage: error.userMessage)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(errorMessage: OpenCodeGoUsageClientError.timedOut.userMessage)
        } catch {
            return .failure(errorMessage: OpenCodeGoUsageClientError.network.userMessage)
        }
    }

    private static func authorizedGet(
        apiKey: String,
        endpoint: URL,
        requestLoader: any OpenCodeGoRequestLoading
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = OpenCodeGoUsageConstants.requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(OpenCodeGoUsageConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(OpenCodeGoUsageConstants.sessionHeaderValue, forHTTPHeaderField: "x-opencode-session")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await requestLoader.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeGoUsageClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw OpenCodeGoUsageClientError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenCodeGoUsageClientError.invalidResponse
        }
        return data
    }

    struct Windows: Equatable, Sendable {
        let rolling: OpenCodeGoWindow?
        let weekly: OpenCodeGoWindow?
        let monthly: OpenCodeGoWindow?
    }

    /// 解析 usage.rolling / weekly / monthly 三段。JSON 读不出、没有 usage
    /// 对象算格式变化（抛错）；段内缺字段按缺处理（nil，绝不当 0%）。
    static func parseWindows(data: Data, now: Date) throws -> Windows {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any]
        else {
            throw OpenCodeGoUsageClientError.invalidResponse
        }
        return Windows(
            rolling: window(from: usage["rolling"], now: now),
            weekly: window(from: usage["weekly"], now: now),
            monthly: window(from: usage["monthly"], now: now)
        )
    }

    private static func window(from raw: Any?, now: Date) -> OpenCodeGoWindow? {
        guard let dictionary = raw as? [String: Any] else {
            return nil
        }
        let status = dictionary["status"] as? String
        let percent = flexibleDouble(dictionary["percent"])
        let resetAt = parseResetAt(dictionary, now: now)
        guard status != nil || percent != nil || resetAt != nil else {
            return nil
        }
        return OpenCodeGoWindow(status: status, percentUsed: percent, resetAt: resetAt)
    }

    /// 两种重置写法都认：resetsAt（ISO8601，带不带毫秒）优先，
    /// 社区写法 reset_in_sec（相对秒数）用查询时刻换算。
    private static func parseResetAt(_ dictionary: [String: Any], now: Date) -> Date? {
        if let iso = dictionary["resetsAt"] as? String,
           let parsed = isoFormatter.date(from: iso) ?? isoFormatterNoFraction.date(from: iso) {
            return parsed
        }
        if let seconds = flexibleDouble(dictionary["reset_in_sec"])
            ?? flexibleDouble(dictionary["resetInSec"]) {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    /// 服务端偶尔把数字序列化成字符串；布尔不算数。
    private static func flexibleDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(text)
        }
        return nil
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let isoFormatterNoFraction = ISO8601DateFormatter()
}

// MARK: - key 识别

enum OpenCodeGoKeyConstants {
    /// 环境变量两个来源，按这个先后取；哨兵是 launchd 拉起的，
    /// 环境变量只在手动前台跑时才大概率有。
    static let environmentKeyNames = [
        "OPENCODE_GO_API_KEY",
        "OPENCODE_API_KEY",
    ]
    /// Cortex 数据根 .env 里认的那一行。
    static let envFileKeyName = "OPENCODE_GO_API_KEY"
}

/// 从本机已有配置里认 OpenCode Go key。只读不写。三个来源依次取前者：
/// 环境变量 OPENCODE_GO_API_KEY → OPENCODE_API_KEY → 数据根 .env 的
/// OPENCODE_GO_API_KEY 行。数据根解析照 SentinelFileReader 的口径：
/// CORTEX_DATA_ROOT 显式覆盖 → 默认 ~/CortexData；XCTest 下不碰真数据根。
enum OpenCodeGoKeyDetector {
    static func detect(
        environment: [String: String],
        envFileURL: URL?,
        fileManager: FileManager = .default
    ) -> String? {
        for name in OpenCodeGoKeyConstants.environmentKeyNames {
            if let key = normalized(environment[name]) {
                return key
            }
        }
        guard let envFileURL,
              let content = try? String(contentsOf: envFileURL, encoding: .utf8)
        else {
            return nil
        }
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "=")
            else {
                continue
            }
            var name = String(trimmed[trimmed.startIndex..<equals])
                .trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("export ") {
                name = String(name.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard name == OpenCodeGoKeyConstants.envFileKeyName else {
                continue
            }
            if let key = normalized(String(trimmed[trimmed.index(after: equals)...])) {
                return key
            }
        }
        return nil
    }

    /// .env 落点：CORTEX_DATA_ROOT 显式数据根 → <root>/.env；
    /// XCTest 不碰本机真数据根（同 packProgressHealthURL 护栏）；
    /// 其余默认 ~/CortexData/.env。home 都取不到返回 nil，不兜底写死路径。
    static func defaultEnvFileURL(
        environment: [String: String],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser,
        testCaseClassLoaded: Bool = NSClassFromString("XCTestCase") != nil
    ) -> URL? {
        if let dataRoot = environment["CORTEX_DATA_ROOT"], !dataRoot.isEmpty {
            return URL(fileURLWithPath: dataRoot, isDirectory: true)
                .appendingPathComponent(".env")
        }
        if processEnvironment["XCTestConfigurationFilePath"] != nil
            || processEnvironment["XCTestSessionIdentifier"] != nil
            || testCaseClassLoaded {
            return nil
        }
        guard let homeDirectory, !homeDirectory.path.isEmpty else {
            return nil
        }
        return homeDirectory
            .appendingPathComponent("CortexData", isDirectory: true)
            .appendingPathComponent(".env")
    }

    /// trim + 剥掉成对引号 + 最短长度闸（太短当没有，落下一个来源）。
    private static func normalized(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        if value.count >= 2 {
            let first = value.first
            let last = value.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard value.count >= OpenCodeGoUsageConstants.minKeyLength else {
            return nil
        }
        return value
    }
}
