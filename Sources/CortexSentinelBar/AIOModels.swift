import Foundation

enum AIODataSourceState: Equatable, Sendable {
    case available
    case unconfigured
    case invalid
}

enum AIORouteMode: Equatable, Sendable {
    case aggregate
    case direct

    var displayName: String {
        switch self {
        case .aggregate:
            return "聚合"
        case .direct:
            return "直连"
        }
    }
}

enum AIOCircuitState: Equatable, Sendable {
    case closed
    case open
    case halfOpen
    case unknown(String)

    init(rawValue: String?) {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "CLOSED":
            self = .closed
        case "OPEN":
            self = .open
        case "HALF_OPEN", "HALF-OPEN", "HALFOPEN":
            self = .halfOpen
        default:
            self = .unknown(rawValue ?? "UNKNOWN")
        }
    }

    var displayName: String {
        switch self {
        case .closed:
            return "正常"
        case .open:
            return "熔断"
        case .halfOpen:
            return "半开"
        case .unknown:
            return "未知"
        }
    }

    var isOpen: Bool {
        self == .open
    }
}

struct AIOUsageResponse: Decodable, Equatable, Sendable {
    let remaining: Double?
    let unit: String?
    let planName: String?
    let subscription: AIOUsageSubscription?
    let isValid: Bool

    enum CodingKeys: String, CodingKey {
        case remaining
        case unit
        case planName
        case legacyPlanName = "plan_name"
        case subscription
        case isValid
    }

    init(
        remaining: Double?,
        unit: String?,
        planName: String?,
        subscription: AIOUsageSubscription?,
        isValid: Bool
    ) {
        self.remaining = remaining
        self.unit = unit
        self.planName = planName
        self.subscription = subscription
        self.isValid = isValid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remaining = try container.decodeIfPresent(Double.self, forKey: .remaining)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
            ?? container.decodeIfPresent(String.self, forKey: .legacyPlanName)
        subscription = try container.decodeIfPresent(AIOUsageSubscription.self, forKey: .subscription)
        isValid = try container.decode(Bool.self, forKey: .isValid)
    }
}

struct AIOUsageSubscription: Decodable, Equatable, Sendable {
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case expiresAt = "expires_at"
    }
}

struct AIOUsage: Equatable, Sendable {
    let remaining: Double?
    let unit: String?
    let planName: String?
    let expiresAt: String?
    let weeklyUsedPercentage: Double?
    let weeklyResetAt: Date?
    let email: String?
    let isValid: Bool

    init(response: AIOUsageResponse) {
        remaining = response.remaining
        unit = response.unit
        planName = response.planName
        expiresAt = response.subscription?.expiresAt
        weeklyUsedPercentage = nil
        weeklyResetAt = nil
        email = nil
        isValid = response.isValid
    }

    init(official response: AIOOfficialUsageResponse) {
        remaining = nil
        unit = nil
        planName = response.planType
        expiresAt = nil
        weeklyUsedPercentage = response.weeklyWindow?.usedPercentage
        weeklyResetAt = response.weeklyWindow?.resetDate
        email = response.email
        isValid = weeklyUsedPercentage != nil
    }
}

struct AIOOfficialUsageResponse: Decodable, Equatable, Sendable {
    let planType: String?
    let email: String?
    let rateLimit: AIOOfficialRateLimit

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case email
        case rateLimit = "rate_limit"
    }

    var weeklyWindow: AIOOfficialUsageWindow? {
        rateLimit.weeklyWindow
            ?? [rateLimit.primaryWindow, rateLimit.secondaryWindow]
                .compactMap { $0 }
                .first(where: { ($0.limitWindowSeconds ?? 0) >= 6 * 24 * 60 * 60 })
    }
}

struct AIOOfficialRateLimit: Decodable, Equatable, Sendable {
    let primaryWindow: AIOOfficialUsageWindow?
    let secondaryWindow: AIOOfficialUsageWindow?
    let weeklyWindow: AIOOfficialUsageWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
        case weeklyWindow = "weekly_window"
    }
}

struct AIOOfficialUsageWindow: Decodable, Equatable, Sendable {
    let usedPercentage: Double?
    let limitWindowSeconds: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    var resetDate: Date? {
        resetAt.map(Date.init(timeIntervalSince1970:))
    }
}

enum AIOUsageStatus: Equatable, Sendable {
    case idle
    case loading
    case success(AIOUsage)
    case failed
    case timedOut
    case invalid

    var usage: AIOUsage? {
        guard case let .success(usage) = self else {
            return nil
        }
        return usage
    }

    var hasFailure: Bool {
        switch self {
        case .failed, .timedOut, .invalid:
            return true
        case .idle, .loading, .success:
            return false
        }
    }
}

/// AIO 出口按名字分类。规则是维护者 2026-08-12 亲口定的，与守护脚本
/// `scripts/codex_babysitter.py` 的 `classify_exit_name` 保持同一套，两边不许各判各的：
/// 进口中转名字里一定写明 input；官方 GPT（Plus 或 Pro）名字里一定带 GPT；
/// 其他第三方中转不会带 GPT。
enum AIOExitClass: Equatable, Sendable {
    case officialGPT
    case input
    case thirdParty

    /// 先判 GPT 再判 input 是刻意选的容错方向，不是随手排的顺序：只有"启用的全是 Input 系"
    /// 才会让守护暂停重试，所以名字同时命中两边时判成非 Input，最坏代价是多试一次；
    /// 反过来判成 Input 就可能把还有活路的线停掉。名字为空同理落 thirdParty。
    init(name: String) {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty {
            self = .thirdParty
        } else if lowered.contains("gpt") {
            self = .officialGPT
        } else if lowered.contains("input") {
            self = .input
        } else {
            self = .thirdParty
        }
    }
}

struct AIOProvider: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let baseURL: String
    let enabled: Bool
    let routeOrder: Int
    let providerOrder: Int
    let note: String
    let circuitState: AIOCircuitState
    let failureCount: Int
    let usage: AIOUsageStatus

    /// AIO 的 Codex OAuth provider 没有第三方 base URL；额度由 auth.json 直查官方。
    var isOfficialOAuthProvider: Bool {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isLowBalance: Bool {
        guard enabled, let usage = usage.usage else {
            return false
        }
        if let remaining = usage.remaining {
            return remaining < AIOConstants.lowBalanceThreshold
        }
        return (usage.weeklyUsedPercentage ?? 0) >= AIOConstants.quotaWarningThreshold
    }

    /// 余额行状态点色义（维护者 2026-07-24 拍板）：
    /// 停用=灰；熔断开=红；半开=橙（告警，不与停用混灰）；正常低余额=橙；正常=绿。
    var statusSeverity: SentinelSeverity {
        guard enabled else {
            return .gray
        }
        switch circuitState {
        case .open:
            return .red
        case .halfOpen:
            return .amber
        case .closed, .unknown:
            return isLowBalance ? .amber : .green
        }
    }

    func replacing(usage: AIOUsageStatus) -> AIOProvider {
        AIOProvider(
            id: id,
            name: name,
            baseURL: baseURL,
            enabled: enabled,
            routeOrder: routeOrder,
            providerOrder: providerOrder,
            note: note,
            circuitState: circuitState,
            failureCount: failureCount,
            usage: usage
        )
    }
}

struct StatusBarBalanceItem: Equatable, Identifiable, Sendable {
    let providerID: Int64
    let providerName: String
    let text: String
    let isLowBalance: Bool

    var id: Int64 {
        providerID
    }
}

struct AIOSnapshot: Equatable, Sendable {
    let sourceState: AIODataSourceState
    let gatewayEnabled: Bool
    let routeMode: AIORouteMode
    let providers: [AIOProvider]
    let lastHitProviderID: Int64?
    let lastHitProviderName: String?
    let readAt: Date?
    let errorMessage: String?

    static let unconfigured = AIOSnapshot(
        sourceState: .unconfigured,
        gatewayEnabled: false,
        routeMode: .direct,
        providers: [],
        lastHitProviderID: nil,
        lastHitProviderName: nil,
        readAt: nil,
        errorMessage: nil
    )

    var enabledProviders: [AIOProvider] {
        providers.filter(\.enabled)
    }

    /// 启用名单里有没有官方 GPT 家族。它烧的是 ChatGPT 的周窗口，跟中转那份 USD 余额
    /// 是两个桶；只要它在路由里，界面上就该说出来，别让人以为还在花中转余额。
    var hasEnabledOfficialGPTExit: Bool {
        guard sourceState == .available else {
            return false
        }
        return enabledProviders.contains { AIOExitClass(name: $0.name) == .officialGPT }
    }

    /// 启用的出口是不是清一色 Input 系——只有这样才谈得上"结构上没有别的出口"。
    /// 名单读不到（未配置 / 库损坏）或名单为空一律返回 false，降级成老行为继续试；
    /// 这条闸只许少停、不许多停。
    var onlyInputExitsEnabled: Bool {
        guard sourceState == .available else {
            return false
        }
        let enabled = enabledProviders
        guard !enabled.isEmpty else {
            return false
        }
        return enabled.allSatisfy { AIOExitClass(name: $0.name) == .input }
    }

    var hasOpenCircuit: Bool {
        enabledProviders.contains(where: \.circuitState.isOpen)
    }

    var hasLowBalance: Bool {
        providers.contains(where: \.isLowBalance)
    }

    var hasUsageFailure: Bool {
        providers.contains(where: { $0.enabled && $0.usage.hasFailure })
    }

    var aggregateHealthy: Bool {
        sourceState == .available
            && gatewayEnabled
            && !enabledProviders.isEmpty
            && enabledProviders.contains(where: { !$0.circuitState.isOpen })
    }

    var statusBarBalances: [StatusBarBalanceItem] {
        Array(providers.compactMap { provider -> StatusBarBalanceItem? in
            guard let remaining = provider.usage.usage?.remaining else {
                return nil
            }
            return StatusBarBalanceItem(
                providerID: provider.id,
                providerName: provider.name,
                text: "$\(Int(max(0, remaining).rounded()))",
                isLowBalance: provider.isLowBalance
            )
        }.prefix(2))
    }

    func replacingUsage(_ statuses: [Int64: AIOUsageStatus]) -> AIOSnapshot {
        AIOSnapshot(
            sourceState: sourceState,
            gatewayEnabled: gatewayEnabled,
            routeMode: routeMode,
            providers: providers.map { provider in
                provider.replacing(usage: statuses[provider.id] ?? provider.usage)
            },
            lastHitProviderID: lastHitProviderID,
            lastHitProviderName: lastHitProviderName,
            readAt: readAt,
            errorMessage: errorMessage
        )
    }
}

struct SentinelTopChannelPresentation: Equatable {
    let balanceCountText: String
    let routeSummary: String

    init(aio: AIOSnapshot) {
        let relayBalanceCount = aio.providers.filter { !$0.isOfficialOAuthProvider }.count
        balanceCountText = aio.sourceState == .available
            ? "官方 + \(relayBalanceCount) 把"
            : "官方"

        guard aio.sourceState == .available else {
            routeSummary = "路由数据未就绪"
            return
        }

        var summary: String
        if aio.routeMode == .aggregate {
            summary = aio.lastHitProviderName.map {
                "最后命中：\($0)"
            } ?? "暂时没有命中记录"
        } else {
            summary = "Codex 当前使用直连"
        }
        if aio.hasEnabledOfficialGPTExit {
            summary += " · 含官方 GPT（烧周额度）"
        }
        routeSummary = summary
    }
}

enum AIOConstants {
    static let lowBalanceThreshold = 10.0
    static let quotaWarningThreshold = 80.0
    static let statusRefreshInterval: TimeInterval = 5
    static let aioRefreshInterval: TimeInterval = 60
    static let disabledUsageRefreshInterval: TimeInterval = 10 * 60
    static let manualRefreshThrottle: TimeInterval = 10
    static let usageTimeout: TimeInterval = 15
    static let databaseBusyRetryCount = 3
    static let databaseBusyRetryDelay: TimeInterval = 0.15
    static let databaseBusyTimeoutMilliseconds: Int32 = 750
}

enum AIOUsageRefreshPolicy {
    static func shouldRefreshDisabledUsage(lastRefreshAt: Date?, now: Date) -> Bool {
        guard let lastRefreshAt else {
            return true
        }
        return now.timeIntervalSince(lastRefreshAt) >= AIOConstants.disabledUsageRefreshInterval
    }

    static func merge(
        cached: [Int64: AIOUsageStatus],
        fresh: [Int64: AIOUsageStatus],
        providers: [AIOProvider]
    ) -> [Int64: AIOUsageStatus] {
        let providerIDs = Set(providers.map(\.id))
        var merged = cached.filter { providerIDs.contains($0.key) }

        for provider in providers {
            guard let freshStatus = fresh[provider.id] else {
                continue
            }
            if !provider.enabled,
               freshStatus.hasFailure,
               cached[provider.id]?.usage != nil {
                continue
            }
            merged[provider.id] = freshStatus
        }
        return merged
    }
}
