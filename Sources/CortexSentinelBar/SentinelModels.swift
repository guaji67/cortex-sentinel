import Foundation

enum ChannelHealth: Equatable {
    case alive
    case degraded
    case unknown

    init(rawValue: String?) {
        switch rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "alive":
            self = .alive
        case "degraded":
            self = .degraded
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .alive:
            return "通"
        case .degraded:
            return "不通"
        case .unknown:
            return "无数据"
        }
    }

    var tone: SentinelRowTone {
        switch self {
        case .alive:
            return .success
        case .degraded:
            return .warning
        case .unknown:
            return .normal
        }
    }
}

enum ChannelUnknownKind: Equatable {
    case noRecord
    case unreadable
    case unrecognized
    case undetermined

    static let aliveText = "通"
    static let degradedText = "不通"

    var statusText: String {
        switch self {
        case .noRecord:
            return "还没有记录"
        case .unreadable:
            return "状态读不出"
        case .unrecognized:
            return "状态看不懂"
        case .undetermined:
            return "查不出来"
        }
    }
}

struct ChannelVerdict: Equatable {
    let status: ChannelHealth
    let evidence: String
    let running: Int?
    let unknownKind: ChannelUnknownKind?

    init(
        status: ChannelHealth,
        evidence: String,
        running: Int? = nil,
        unknownKind: ChannelUnknownKind? = nil
    ) {
        self.status = status
        self.evidence = evidence
        self.running = running
        if status == .unknown {
            self.unknownKind = unknownKind ?? .undetermined
        } else {
            self.unknownKind = nil
        }
    }

    init(payload: ChannelVerdictPayload?) {
        let trimmed = payload?.evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        evidence = trimmed.isEmpty ? "无数据" : trimmed
        running = payload?.running
        guard let payload else {
            status = .unknown
            unknownKind = .noRecord
            return
        }
        let raw = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch raw.lowercased() {
        case "alive":
            status = .alive
            unknownKind = nil
        case "degraded":
            status = .degraded
            unknownKind = nil
        case "unknown":
            status = .unknown
            unknownKind = .undetermined
        default:
            status = .unknown
            unknownKind = .unrecognized
        }
    }

    var runningCount: Int {
        running ?? 0
    }

    var statusText: String {
        switch status {
        case .alive:
            return ChannelUnknownKind.aliveText
        case .degraded:
            return ChannelUnknownKind.degradedText
        case .unknown:
            return (unknownKind ?? .undetermined).statusText
        }
    }

    static let missing = ChannelVerdict(
        status: .unknown,
        evidence: "无数据",
        unknownKind: .noRecord
    )

    static let unreadable = ChannelVerdict(
        status: .unknown,
        evidence: "文件读不出",
        unknownKind: .unreadable
    )
}

enum SentinelBoardCopy {
    static let registeredSectionTitle = "有登记的"
    static let unregisteredSectionTitle = "没登记的"
    static let lineSettingsTitle = "这条线的重试和提醒"
    static let lineSettingsHelp = "这条线的重试和提醒（只有 Codex 有）"
    static let escalateAfterFailuresLabel = "失败几次提醒我"
    static let lineSettingsCloseAccessibilityLabel = "关闭这条线的重试和提醒"

    static func headerSubtitle(
        localActiveCount: Int,
        recentCount: Int,
        offHostActiveCount: Int = 0
    ) -> String {
        if offHostActiveCount > 0 {
            return "这台机上在跑 \(localActiveCount) 条 · 另外 \(offHostActiveCount) 条不在这台机上 · \(recentCount) 条最近完成"
        }
        return "这台机上在跑 \(localActiveCount) 条 · \(recentCount) 条最近完成"
    }

    static func showsLineSettings(for engine: LineEngine) -> Bool {
        !engine.isCursorGrok
    }
}

struct ChannelStatusSnapshot: Equatable {
    let generatedAt: Date?
    let grok: ChannelVerdict
    let codex: ChannelVerdict
    /// ox-alpha 通道。摘要文件还没写这个键时保持 `.missing`，不画成不通。
    let claudeOxAlpha: ChannelVerdict

    init(
        generatedAt: Date?,
        grok: ChannelVerdict,
        codex: ChannelVerdict,
        claudeOxAlpha: ChannelVerdict = .missing
    ) {
        self.generatedAt = generatedAt
        self.grok = grok
        self.codex = codex
        self.claudeOxAlpha = claudeOxAlpha
    }

    static let missing = ChannelStatusSnapshot(
        generatedAt: nil,
        grok: .missing,
        codex: .missing
    )

    static let invalid = ChannelStatusSnapshot(
        generatedAt: nil,
        grok: .unreadable,
        codex: .unreadable,
        claudeOxAlpha: .unreadable
    )
}

struct ChannelItemPresentation: Equatable {
    let name: String
    let verdict: ChannelVerdict
    /// 当前屏上该引擎的活跃派工条数，与下面列表同一口径。
    let liveRunning: Int

    var accessibilityIdentifier: String {
        "channel-row-\(name.lowercased())"
    }

    var countText: String? {
        guard verdict.status == .alive else {
            return nil
        }
        return liveRunning > 0 ? "\(liveRunning) 条" : "闲"
    }

    var itemText: String {
        if let countText {
            return "\(name) \(verdict.statusText) \(countText)"
        }
        return "\(name) \(verdict.statusText)"
    }

    var problemLine: String? {
        guard verdict.status == .degraded else {
            return nil
        }
        return "\(name) \(verdict.statusText)，\(verdict.evidence)"
    }
}

struct ChannelSectionPresentation: Equatable {
    struct Render: Equatable {
        let primaryRow: [String]
        let problemLines: [String]
    }

    let grok: ChannelItemPresentation
    let codex: ChannelItemPresentation
    let claudeOxAlpha: ChannelItemPresentation
    private let includesClaudeOxAlpha: Bool

    init(
        grok: ChannelVerdict,
        codex: ChannelVerdict,
        liveCounts: EngineCounts
    ) {
        self.init(
            grok: grok,
            codex: codex,
            claudeOxAlpha: nil,
            liveCounts: liveCounts
        )
    }

    /// 新版调用点显式传入 ox-alpha，才把第三张卡加入渲染；旧的两通道调用点
    /// 保留原有两行契约，避免缺失摘要键时改变 host/未知状态等无关诊断的输出。
    init(
        grok: ChannelVerdict,
        codex: ChannelVerdict,
        claudeOxAlpha: ChannelVerdict,
        liveCounts: EngineCounts
    ) {
        self.init(
            grok: grok,
            codex: codex,
            claudeOxAlpha: claudeOxAlpha,
            liveCounts: liveCounts,
            includesClaudeOxAlpha: true
        )
    }

    private init(
        grok: ChannelVerdict,
        codex: ChannelVerdict,
        claudeOxAlpha: ChannelVerdict?,
        liveCounts: EngineCounts,
        includesClaudeOxAlpha: Bool = false
    ) {
        self.grok = ChannelItemPresentation(name: "Grok", verdict: grok, liveRunning: liveCounts.grok)
        self.codex = ChannelItemPresentation(name: "Codex", verdict: codex, liveRunning: liveCounts.codex)
        self.claudeOxAlpha = ChannelItemPresentation(
            name: "ox-alpha",
            verdict: claudeOxAlpha ?? .missing,
            liveRunning: liveCounts.claudeOxAlpha
        )
        self.includesClaudeOxAlpha = includesClaudeOxAlpha
    }

    var items: [ChannelItemPresentation] {
        if includesClaudeOxAlpha {
            return [codex, grok, claudeOxAlpha]
        }
        return [codex, grok]
    }

    var problemLines: [String] {
        items.compactMap(\.problemLine)
    }

    var rowCount: Int {
        1 + problemLines.count
    }

    var render: Render {
        Render(primaryRow: items.map(\.itemText), problemLines: problemLines)
    }
}

enum SentinelSeverity: String, Equatable {
    case green
    case amber
    case red
    case gray

    var symbolName: String {
        switch self {
        case .green:
            return "shield.fill"
        case .amber:
            return "exclamationmark.shield.fill"
        case .red:
            return "xmark.shield.fill"
        case .gray:
            return "shield"
        }
    }

    var displayName: String {
        switch self {
        case .green:
            return "正常"
        case .amber:
            return "留意"
        case .red:
            return "需要处理"
        case .gray:
            return "未配置"
        }
    }

}

enum LineEngine: Equatable, Sendable {
    case codex
    case cursorGrok
    /// ox-alpha 派工线（`scripts/oxalpha_dispatch.py`）。状态文件里 engine 字段写的是
    /// `claude`，通道/认领口径用的是 `claude-oxalpha`，两个 rawValue 都要认。
    case claudeOxAlpha
    case unknown(String)

    init(rawValue: String?) {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else {
            self = .codex
            return
        }

        switch normalized {
        case "codex":
            self = .codex
        case "cursor-grok":
            self = .cursorGrok
        case "claude", "claude-oxalpha":
            self = .claudeOxAlpha
        default:
            self = .unknown(normalized)
        }
    }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .cursorGrok:
            return "Grok"
        case .claudeOxAlpha:
            return "ox-alpha"
        case let .unknown(rawValue):
            return rawValue
        }
    }

    var isCursorGrok: Bool {
        self == .cursorGrok
    }

    var ackChannel: String {
        switch self {
        case .codex:
            return "codex"
        case .cursorGrok:
            return "grok"
        case .claudeOxAlpha:
            return "claude-oxalpha"
        case let .unknown(rawValue):
            return rawValue
        }
    }

    func prefixedAckKey(slug: String) -> String {
        "\(ackChannel):\(slug)"
    }
}

enum LineState: Equatable {
    case running
    case waitingRelay
    case retrying
    case backoff
    case help
    case dead
    case done
    case killed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "running":
            self = .running
        case "waiting_relay":
            self = .waitingRelay
        case "retrying", "restarting":
            self = .retrying
        case "backoff":
            self = .backoff
        case "help":
            self = .help
        case "dead":
            self = .dead
        case "done":
            self = .done
        case "killed":
            self = .killed
        default:
            self = .unknown(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .running:
            return "运行中"
        case .waitingRelay:
            return "等中转恢复"
        case .retrying:
            return "重试中"
        case .backoff:
            return "退避中"
        case .help:
            return "求助"
        case .dead:
            return "已失联"
        case .done:
            return "已完成"
        case .killed:
            return "已停止"
        case .unknown:
            return "状态异常"
        }
    }

    var symbolName: String {
        switch self {
        case .running:
            return "play.fill"
        case .waitingRelay:
            return "hourglass"
        case .retrying:
            return "arrow.clockwise"
        case .backoff:
            return "clock.fill"
        case .help:
            return "exclamationmark.bubble.fill"
        case .dead:
            return "xmark.circle.fill"
        case .done:
            return "checkmark.circle.fill"
        case .killed:
            return "stop.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var wireName: String {
        switch self {
        case .running:
            return "running"
        case .waitingRelay:
            return "waiting_relay"
        case .retrying:
            return "retrying"
        case .backoff:
            return "backoff"
        case .help:
            return "help"
        case .dead:
            return "dead"
        case .done:
            return "done"
        case .killed:
            return "killed"
        case let .unknown(rawValue):
            return rawValue
        }
    }

    var isTerminal: Bool {
        self == .done || self == .killed
    }

    var isCritical: Bool {
        self == .help || self == .dead
    }

    var isRetrying: Bool {
        self == .retrying || self == .backoff
    }

    /// 清理时当作活线：派工日志和状态文件都不许删。
    /// 口径跟 `LogCleaner` 原来的 running / waitingRelay 保护一致。
    var isCleanupProtectedLive: Bool {
        switch self {
        case .running, .waitingRelay:
            return true
        default:
            return false
        }
    }
}

struct LineRelay: Decodable, Equatable {
    let activeID: String?
    let activeLabel: String?
    let switchCount: Int?
    let lastSwitchAt: String?
    let baseURLAtSpawn: String?

    enum CodingKeys: String, CodingKey {
        case activeID = "active_id"
        case activeLabel = "active_label"
        case switchCount = "switch_count"
        case lastSwitchAt = "last_switch_at"
        case baseURLAtSpawn = "base_url_at_spawn"
    }
}

struct LineRelayProbe: Decodable, Equatable {
    let state: String?
    let checkedAt: String?
    let lastOK: Bool?
    let recentOK: [Bool]?
    let detail: String?
    let primaryProvider: String?
    let activeProvider: String?
    let fallbackProvider: String?
    let fallbackAttempted: Bool?
    let switchCount: Int?
    let lastSwitchAt: String?
    let firstFailureAt: String?
    /// 守护判定的"结构性无出口"：启用的出口全是 Input 系且 Input 挂着。
    /// 旧版守护不写这两个字段，解码成 nil 即按老样子显示。
    let noExit: Bool?
    let noExitReason: String?
    /// 官方 GPT 家族在不在 AIO 的路由里。它烧的是 ChatGPT 周窗口，跟中转那份 USD 余额
    /// 是两个桶——守护过去只看得见 USD 那个桶。
    let officialGPTInRoute: Bool?
    let officialQuota: LineOfficialQuota?
    /// 守护为什么这轮不发射：no_exit / quota_tight / quota_unknown。
    let launchHold: String?
    let launchHoldReason: String?
    /// 额度查不到、等满宽限后放行的那一次的时刻——这轮消耗没核实过。
    let quotaUnverifiedLaunchAt: String?

    init(
        state: String?,
        checkedAt: String?,
        lastOK: Bool?,
        recentOK: [Bool]?,
        detail: String?,
        primaryProvider: String?,
        activeProvider: String?,
        fallbackProvider: String?,
        fallbackAttempted: Bool?,
        switchCount: Int?,
        lastSwitchAt: String?,
        firstFailureAt: String?,
        noExit: Bool? = nil,
        noExitReason: String? = nil,
        officialGPTInRoute: Bool? = nil,
        officialQuota: LineOfficialQuota? = nil,
        launchHold: String? = nil,
        launchHoldReason: String? = nil,
        quotaUnverifiedLaunchAt: String? = nil
    ) {
        self.state = state
        self.checkedAt = checkedAt
        self.lastOK = lastOK
        self.recentOK = recentOK
        self.detail = detail
        self.primaryProvider = primaryProvider
        self.activeProvider = activeProvider
        self.fallbackProvider = fallbackProvider
        self.fallbackAttempted = fallbackAttempted
        self.switchCount = switchCount
        self.lastSwitchAt = lastSwitchAt
        self.firstFailureAt = firstFailureAt
        self.noExit = noExit
        self.noExitReason = noExitReason
        self.officialGPTInRoute = officialGPTInRoute
        self.officialQuota = officialQuota
        self.launchHold = launchHold
        self.launchHoldReason = launchHoldReason
        self.quotaUnverifiedLaunchAt = quotaUnverifiedLaunchAt
    }

    enum CodingKeys: String, CodingKey {
        case state
        case checkedAt = "checked_at"
        case lastOK = "last_ok"
        case recentOK = "recent_ok"
        case detail
        case primaryProvider = "primary_provider"
        case activeProvider = "active_provider"
        case fallbackProvider = "fallback_provider"
        case fallbackAttempted = "fallback_attempted"
        case switchCount = "switch_count"
        case lastSwitchAt = "last_switch_at"
        case firstFailureAt = "first_failure_at"
        case noExit = "no_exit"
        case noExitReason = "no_exit_reason"
        case officialGPTInRoute = "official_gpt_in_route"
        case officialQuota = "official_quota"
        case launchHold = "launch_hold"
        case launchHoldReason = "launch_hold_reason"
        case quotaUnverifiedLaunchAt = "quota_unverified_launch_at"
    }

    var isNoExit: Bool {
        noExit == true
    }

    var holdKind: LineLaunchHold {
        LineLaunchHold(rawValue: launchHold, noExit: noExit == true)
    }
}

/// 守护为什么这轮不发射。界面靠它把"没动静"解释清楚，而不是让线看着像卡死。
enum LineLaunchHold: Equatable {
    case none
    /// 只开了 Input 系出口，Input 挂着。
    case noExit
    /// 现在只能走官方 GPT，而它的周窗口额度已经打得差不多了。
    case quotaTight
    /// 现在只能走官方 GPT，但额度查不到——不敢当额度充足就发。
    case quotaUnknown

    init(rawValue: String?, noExit: Bool) {
        switch rawValue {
        case "quota_tight":
            self = .quotaTight
        case "quota_unknown":
            self = .quotaUnknown
        case "no_exit":
            self = .noExit
        default:
            self = noExit ? .noExit : .none
        }
    }

    /// 徽章上那几个字：一眼看出它在等什么。
    var badgeText: String? {
        switch self {
        case .none:
            return nil
        case .noExit:
            return "等 Input 恢复"
        case .quotaTight:
            return "等额度回血"
        case .quotaUnknown:
            return "等额度核实"
        }
    }

    var isHolding: Bool {
        self != .none
    }
}

/// 官方 GPT 周窗口快照。**只有百分比和重置时刻，没有账号标识、没有凭据**——
/// 守护那边就是按这个口径写的，哨兵这边不许自己加回来。
struct LineOfficialQuota: Decodable, Equatable {
    let state: String?
    let weeklyUsedPercentage: Double?
    let weeklyResetAt: String?
    let fiveHourUsedPercentage: Double?
    let fiveHourResetAt: String?
    let detail: String?
    let blockAtWeeklyPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case state
        case weeklyUsedPercentage = "weekly_used_pct"
        case weeklyResetAt = "weekly_reset_at"
        case fiveHourUsedPercentage = "five_hour_used_pct"
        case fiveHourResetAt = "five_hour_reset_at"
        case detail
        case blockAtWeeklyPercentage = "block_at_weekly_pct"
    }

    var isTight: Bool {
        state == "tight"
    }

    var isUnknown: Bool {
        state == "unknown"
    }

    /// 这台 AIO 没有额度接口——守护永远核实不了额度，不是暂时查不到。
    var isUnsupported: Bool {
        state == "unsupported"
    }

    var needsAttention: Bool {
        state == "tight" || state == "warn" || state == "unknown" || state == "unsupported"
    }
}

struct RelayProbeDetail: Equatable {
    let label: String
    let value: String
}

enum LineRelayProbePresentation {
    static func details(
        for probe: LineRelayProbe,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RelayProbeDetail] {
        let hold = probe.holdKind
        if hold.isHolding {
            // 守护主动停下时摆"探针可用/不可用"只会误导——本地网关一直是可用的，
            // 出问题的是它背后（没出口 / 额度打满 / 额度查不到）。换成人话直说在等什么。
            var rows: [RelayProbeDetail] = [
                RelayProbeDetail(
                    label: "出口",
                    value: normalized(probe.activeProvider) ?? "未上报"
                ),
                RelayProbeDetail(
                    label: "状态",
                    value: holdStateText(hold)
                ),
                RelayProbeDetail(
                    label: "原因",
                    value: holdReasonText(probe, hold: hold)
                ),
            ]
            if let quotaRow = officialQuotaText(probe.officialQuota) {
                rows.append(RelayProbeDetail(label: "官方额度", value: quotaRow))
            }
            rows.append(
                RelayProbeDetail(
                    label: "等待",
                    value: waitingText(probe, now: now)
                )
            )
            return rows
        }

        var rows: [RelayProbeDetail] = [
            RelayProbeDetail(
                label: "出口",
                value: normalized(probe.activeProvider) ?? "未上报"
            ),
            RelayProbeDetail(
                label: "探针",
                value: probeText(probe, now: now, calendar: calendar)
            ),
            RelayProbeDetail(
                label: "等待",
                value: waitingText(probe, now: now)
            ),
            RelayProbeDetail(
                label: "备用",
                value: fallbackText(probe)
            ),
        ]
        // 没被拦住也要把官方额度亮出来：正常派工时守护看到的是中转 USD 余额，
        // 跟官方 GPT 烧的周窗口是两个桶，不显式写出来使用者根本看不见它在掉。
        if probe.officialGPTInRoute == true, let quotaRow = officialQuotaText(probe.officialQuota) {
            rows.append(RelayProbeDetail(label: "官方额度", value: quotaRow))
        }
        return rows
    }

    private static func holdStateText(_ hold: LineLaunchHold) -> String {
        switch hold {
        case .noExit:
            return "等 Input 恢复（已暂停无谓重试）"
        case .quotaTight:
            return "等额度回血（已暂停发射）"
        case .quotaUnknown:
            return "等额度核实（查不到额度，先不发）"
        case .none:
            return "正常"
        }
    }

    private static func holdReasonText(_ probe: LineRelayProbe, hold: LineLaunchHold) -> String {
        if let reported = normalized(probe.launchHoldReason) {
            return reported
        }
        if let legacy = normalized(probe.noExitReason), hold == .noExit {
            return legacy
        }
        switch hold {
        case .noExit:
            return RelayExitPosture.noExitFallbackSummary
        case .quotaTight:
            return "现在只能走官方 GPT，它的额度快用完了，已暂停发射等回血"
        case .quotaUnknown:
            return "现在只能走官方 GPT，但额度查不到，不敢当成额度充足就发"
        case .none:
            return "正常"
        }
    }

    /// 官方周窗口一行。只显示百分比和重置时刻，不显示任何账号标识。
    static func officialQuotaText(_ quota: LineOfficialQuota?) -> String? {
        guard let quota else {
            return nil
        }
        if let weekly = quota.weeklyUsedPercentage {
            var text = "周窗口已用 \(percentText(weekly))%"
            if let reset = officialResetText(quota.weeklyResetAt) {
                text += " · \(reset) 回血"
            }
            if let fiveHour = quota.fiveHourUsedPercentage {
                text += " · 5 小时窗 \(percentText(fiveHour))%"
            }
            if quota.isTight {
                text += " · 已达暂停线"
            }
            return text
        }
        if quota.isUnsupported {
            // 跟"暂时查不到"分开说：这是永远拿不到，守护不会为它扣着不发，
            // 但也不会假装额度充足——这行会一直挂在这里提醒你额度没人核实。
            return normalized(quota.detail).map { "核实不了（\($0)）" } ?? "核实不了"
        }
        if quota.isUnknown {
            return normalized(quota.detail).map { "查不到（\($0)）" } ?? "查不到"
        }
        return normalized(quota.detail)
    }

    private static func percentText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func officialResetText(_ value: String?) -> String? {
        guard let parsed = SentinelDateParser.parse(value) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: parsed)
    }

    private static func probeText(
        _ probe: LineRelayProbe,
        now: Date,
        calendar: Calendar
    ) -> String {
        let stateText: String
        switch normalized(probe.state)?.lowercased() {
        case "healthy":
            stateText = "可用"
        case "unhealthy":
            stateText = "不可用"
        case "unknown":
            stateText = "未知"
        case "not_applicable":
            stateText = "不适用"
        case let raw?:
            stateText = "未知（\(raw)）"
        case nil:
            stateText = "未上报"
        }

        var parts = [stateText]
        if let lastOK = probe.lastOK {
            parts.append(lastOK ? "最近成功" : "最近失败")
        }
        if let recentOK = probe.recentOK, !recentOK.isEmpty {
            let result = recentOK.allSatisfy { $0 } ? "均成功" : "有失败"
            parts.append("近 \(recentOK.count) 次\(result)")
        }
        if let checkedAt = SentinelDateParser.parse(probe.checkedAt) {
            parts.append(SentinelTimeFormat.shortTime(checkedAt, now: now, calendar: calendar))
        }
        return parts.joined(separator: " · ")
    }

    private static func waitingText(_ probe: LineRelayProbe, now: Date) -> String {
        guard let firstFailureAt = SentinelDateParser.parse(probe.firstFailureAt) else {
            return "未上报"
        }
        let seconds = max(0, now.timeIntervalSince(firstFailureAt))
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 1 {
            return "已等不到 1 分钟"
        }
        if totalMinutes < 60 {
            return "已等 \(totalMinutes) 分钟"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return "已等 \(hours) 小时"
        }
        return "已等 \(hours) 小时 \(minutes) 分钟"
    }

    private static func fallbackText(_ probe: LineRelayProbe) -> String {
        guard let attempted = probe.fallbackAttempted else {
            return "未上报"
        }
        let provider = normalized(probe.fallbackProvider) ?? "备用出口"
        var value = attempted ? "已尝试 \(provider)" : "未尝试 \(provider)"
        if attempted, let switchCount = probe.switchCount, switchCount > 0 {
            value += " · 切换 \(switchCount) 次"
        }
        return value
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct LineStatus: Identifiable, Equatable {
    let sourceFile: URL
    let slug: String
    let engine: LineEngine
    let workdir: String?
    let branch: String?
    let state: LineState
    let restarts: Int
    let reportsRestarts: Bool
    let rolloutAgeSeconds: Double?
    let updatedAt: Date?
    let sourceModifiedAt: Date?
    let startedAt: Date?
    let processID: Int?
    let model: String?
    let logBytes: Int?
    let exitCode: Int?
    let relay: LineRelay?
    let relayProbe: LineRelayProbe?
    let balance: RelayBalance?
    let note: String?
    let maxRestartsOverride: Int?
    let escalateAfterFailures: Int?
    let updatedAtRaw: String?

    init(
        sourceFile: URL,
        slug: String,
        engine: LineEngine = .codex,
        workdir: String?,
        branch: String?,
        state: LineState,
        restarts: Int,
        reportsRestarts: Bool = true,
        rolloutAgeSeconds: Double?,
        updatedAt: Date?,
        sourceModifiedAt: Date?,
        startedAt: Date? = nil,
        processID: Int? = nil,
        model: String? = nil,
        logBytes: Int? = nil,
        exitCode: Int? = nil,
        relay: LineRelay?,
        relayProbe: LineRelayProbe? = nil,
        balance: RelayBalance? = nil,
        note: String? = nil,
        maxRestartsOverride: Int? = nil,
        escalateAfterFailures: Int? = nil,
        updatedAtRaw: String? = nil
    ) {
        self.sourceFile = sourceFile
        self.slug = slug
        self.engine = engine
        self.workdir = workdir
        self.branch = branch
        self.state = state
        self.restarts = restarts
        self.reportsRestarts = reportsRestarts
        self.rolloutAgeSeconds = rolloutAgeSeconds
        self.updatedAt = updatedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.startedAt = startedAt
        self.processID = processID
        self.model = model
        self.logBytes = logBytes
        self.exitCode = exitCode
        self.relay = relay
        self.relayProbe = relayProbe
        self.balance = balance
        self.note = note
        self.maxRestartsOverride = maxRestartsOverride
        self.escalateAfterFailures = escalateAfterFailures
        self.updatedAtRaw = updatedAtRaw
    }

    var id: String {
        sourceFile.path
    }

    var worktreeName: String? {
        guard let workdir, !workdir.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: workdir).lastPathComponent
    }

    /// 守护上报"结构性无出口"的等待线：只开了 Input 系出口而 Input 挂着，
    /// 已按维护者的规矩主动停掉无谓重试，在等 Input 回来。
    var isWaitingForStructuralExit: Bool {
        state == .waitingRelay && relayProbe?.isNoExit == true
    }

    /// 守护主动停下不发射的原因（没出口 / 额度紧 / 额度查不到）。
    /// `help` 也算：额度打满会升级成 help，那时更要说清是额度的事，不是通道不通。
    var launchHold: LineLaunchHold {
        guard state == .waitingRelay || state == .help else {
            return .none
        }
        return relayProbe?.holdKind ?? .none
    }

    /// 官方 GPT 家族在不在这条线的路由里。
    var officialGPTInRoute: Bool {
        relayProbe?.officialGPTInRoute == true
    }

    /// Grok 契约不写这些 Codex 通道字段。UI 以字段是否存在为准，避免为 Grok
    /// 推导或占位展示中转、余额与重拉信息。
    var reportsCodexChannelTelemetry: Bool {
        reportsRestarts
            || rolloutAgeSeconds != nil
            || relay != nil
            || relayProbe != nil
            || balance != nil
    }

    var effectiveUpdatedAt: Date? {
        sourceModifiedAt ?? updatedAt
    }

    func isActive(
        now: Date,
        threshold: TimeInterval = SentinelAggregation.activeStatusSeconds
    ) -> Bool {
        guard !state.isTerminal, let sourceModifiedAt else {
            return false
        }
        let age = now.timeIntervalSince(sourceModifiedAt)
        return age >= 0 && age < threshold
    }

    func isRecentlyCompleted(
        now: Date,
        threshold: TimeInterval = SentinelAggregation.recentCompletionSeconds
    ) -> Bool {
        guard state.isTerminal, let sourceModifiedAt else {
            return false
        }
        let age = now.timeIntervalSince(sourceModifiedAt)
        return age >= 0 && age < threshold
    }

    var hasStaleRollout: Bool {
        guard let rolloutAgeSeconds else {
            return false
        }
        return rolloutAgeSeconds > SentinelAggregation.staleRolloutSeconds
    }

    var requiresAttention: Bool {
        state.isCritical && !(state == .dead && note != nil)
    }
}

/// 完成列表上四个终态必须出现的词。颜色不算数。一个字不许改。
enum LineTerminalOutcomePresentation {
    static let done = "做完了"
    static let help = "要人管"
    static let dead = "挂了"
    static let killed = "被停了"

    static func label(for state: LineState) -> String? {
        switch state {
        case .done:
            return done
        case .help:
            return help
        case .dead:
            return dead
        case .killed:
            return killed
        default:
            return nil
        }
    }
}

struct LineDispositionPresentation: Equatable {
    let stateText: String
    let symbolName: String
    let markerText: String?
    let note: String?
    let requiresAttention: Bool

    init(line: LineStatus) {
        note = line.note
        requiresAttention = line.requiresAttention
        if line.state == .dead, line.note != nil {
            stateText = LineTerminalOutcomePresentation.dead
            symbolName = "checkmark.seal.fill"
            markerText = "已有处置记录"
        } else if let holdText = line.launchHold.badgeText {
            // 线照常留在列表里，只是把"等中转恢复"改写成它到底在等谁——
            // 这条线不是卡死，是守护按维护者的规矩主动停下了无谓重试。
            stateText = holdText
            symbolName = line.launchHold == .noExit ? "hourglass" : "gauge.with.needle"
            markerText = line.note == nil ? nil : "有备注"
        } else if let outcome = LineTerminalOutcomePresentation.label(for: line.state) {
            stateText = outcome
            symbolName = line.state.symbolName
            markerText = line.note == nil ? nil : "有备注"
        } else {
            stateText = line.state.displayName
            symbolName = line.state.symbolName
            markerText = line.note == nil ? nil : "有备注"
        }
    }
}

struct RelayAttribution: Equatable {
    let text: String
    let isReported: Bool

    static func resolve(line: LineStatus, aio: AIOSnapshot) -> RelayAttribution {
        if aio.routeMode == .aggregate {
            guard aio.gatewayEnabled else {
                return RelayAttribution(text: "聚合→网关关闭", isReported: false)
            }
            return RelayAttribution(
                text: "聚合→\(aio.lastHitProviderName ?? "未命中")",
                isReported: aio.lastHitProviderName != nil
            )
        }

        guard let baseURL = line.relay?.baseURLAtSpawn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseURL.isEmpty
        else {
            return RelayAttribution(text: "", isReported: false)
        }

        if let provider = aio.providers.first(where: {
            normalizedBaseURL($0.baseURL) == normalizedBaseURL(baseURL)
        }) {
            return RelayAttribution(text: provider.name, isReported: true)
        }

        let host = URLComponents(string: baseURL)?.host
        return RelayAttribution(
            text: host?.isEmpty == false ? host! : "未知出口",
            isReported: true
        )
    }

    static func resolve(line: LineStatus, relay: RelaySnapshot) -> RelayAttribution {
        guard let baseURL = line.relay?.baseURLAtSpawn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseURL.isEmpty
        else {
            return RelayAttribution(text: "", isReported: false)
        }

        if let entry = relay.entries.first(where: {
            normalizedBaseURL($0.baseURL) == normalizedBaseURL(baseURL)
        }) {
            return RelayAttribution(text: entry.label, isReported: true)
        }

        let host = URLComponents(string: baseURL)?.host
        return RelayAttribution(
            text: host?.isEmpty == false ? host! : "未知出口",
            isReported: true
        )
    }

    private static func normalizedBaseURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        guard var components = URLComponents(string: value) else {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/v1" {
            components.path = ""
        } else if components.path.hasSuffix("/v1") {
            components.path.removeLast(3)
        }
        return components.string
    }
}

struct OtherCodexProcess: Identifiable, Equatable {
    let processID: Int
    let worktreeName: String
    let elapsed: String

    var id: Int {
        processID
    }
}

enum RelayOwner: Equatable {
    case selfOwned
    case friend
    case unknown

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "self":
            self = .selfOwned
        case "friend":
            self = .friend
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .selfOwned:
            return "自己"
        case .friend:
            return "朋友"
        case .unknown:
            return "未标注"
        }
    }
}

struct RelayEntry: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let baseURL: String?
    let authMode: String?
    let apiKey: String?
    let authSnapshot: String?
    let owner: RelayOwner
    let priority: Int?
    let enabled: Bool
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case baseURL = "base_url"
        case authMode = "auth_mode"
        case apiKey = "api_key"
        case authSnapshot = "auth_snapshot"
        case owner
        case priority
        case enabled
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? id
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        authSnapshot = try container.decodeIfPresent(String.self, forKey: .authSnapshot)
        owner = RelayOwner(rawValue: try container.decodeIfPresent(String.self, forKey: .owner))
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    var maskedAPIKey: String? {
        guard let apiKey, apiKey.count > 4 else {
            return apiKey == nil ? nil : "sk-..."
        }
        return "sk-...\(apiKey.suffix(4))"
    }
}

struct RelayBalance: Decodable, Equatable {
    let remaining: Double?
    let currency: String?
    let scope: String?
    let planType: String?
    let providerName: String?
    let email: String?
    let weeklyUsedPercentage: Double?
    let weeklyResetAt: String?
    let fiveHourUsedPercentage: Double?
    let fiveHourResetAt: String?
    let checkedAt: String?
    let refreshFailedAt: String?
    let stale: Bool?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case remaining
        case currency
        case scope
        case planType = "plan_type"
        case providerName = "provider_name"
        case email
        case weeklyUsedPercentage = "weekly_used_pct"
        case weeklyResetAt = "weekly_reset_at"
        case fiveHourUsedPercentage = "five_hour_used_pct"
        case fiveHourResetAt = "five_hour_reset_at"
        case checkedAt = "checked_at"
        case refreshFailedAt = "refresh_failed_at"
        case stale
        case note
    }
}

struct OfficialQuotaRow: Equatable {
    let text: String
    let isWarning: Bool
}

enum OfficialQuotaPresentation {
    private static let displayTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    static func rows(for balance: RelayBalance?) -> [OfficialQuotaRow] {
        guard balance?.scope == "official_weekly", let balance else {
            return []
        }

        var rows: [OfficialQuotaRow] = []
        if let used = balance.weeklyUsedPercentage {
            let label = officialAccountLabel(balance).map { "\($0)·周额度" } ?? "官方周额度"
            var text = quotaText(
                label: label,
                used: used,
                resetAt: balance.weeklyResetAt,
                dateFormat: "M/d"
            )
            if balance.stale == true {
                text += " · 数据已过期"
            }
            rows.append(
                OfficialQuotaRow(
                    text: text,
                    isWarning: balance.stale == true
                )
            )
        }

        if let note = normalized(balance.note) {
            rows.append(OfficialQuotaRow(text: note, isWarning: true))
        } else if balance.weeklyUsedPercentage == nil {
            rows.append(OfficialQuotaRow(text: "官方周额度暂不可用", isWarning: true))
        }

        if let used = balance.fiveHourUsedPercentage {
            rows.append(
                OfficialQuotaRow(
                    text: quotaText(
                        label: "5 小时额度",
                        used: used,
                        resetAt: balance.fiveHourResetAt,
                        dateFormat: "M/d HH:mm"
                    ),
                    isWarning: false
                )
            )
        }
        return rows
    }

    static func remainingPercentage(fromUsed used: Double) -> Double {
        max(0, min(100, 100 - used))
    }

    private static func officialAccountLabel(_ balance: RelayBalance) -> String? {
        if let providerName = normalized(balance.providerName) {
            return providerName
        }
        guard let email = normalized(balance.email) else {
            return nil
        }
        let user = email.split(separator: "@", maxSplits: 1).first.map(String.init)
        return normalized(user)
    }

    private static func quotaText(
        label: String,
        used: Double,
        resetAt: String?,
        dateFormat: String
    ) -> String {
        var text = "\(label)剩 \(percentageText(remainingPercentage(fromUsed: used)))%"
        if let date = SentinelDateParser.parse(resetAt) {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = displayTimeZone
            formatter.dateFormat = dateFormat
            text += " · \(formatter.string(from: date)) 重置"
        }
        return text
    }

    private static func percentageText(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct RelayHealth: Decodable, Equatable {
    let checkedAt: String?
    let ok: Bool?
    let httpClass: String?
    let balance: RelayBalance?
    let latencyMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case checkedAt = "checked_at"
        case ok
        case httpClass = "http_class"
        case balance
        case latencyMilliseconds = "latency_ms"
    }
}

struct ActiveRelay: Decodable, Equatable {
    let activeID: String?
    let since: String?
    let generation: Int?

    enum CodingKeys: String, CodingKey {
        case activeID = "active_id"
        case since
        case generation
    }
}

struct SwitchLogEntry: Decodable, Equatable {
    let at: String?
    let fromID: String?
    let toID: String?
    let reason: String?
    let probeOK: Bool?
    let caller: String?

    enum CodingKeys: String, CodingKey {
        case at
        case fromID = "from_id"
        case toID = "to_id"
        case reason
        case probeOK = "probe_ok"
        case caller
    }
}

enum RelaySourceState: Equatable {
    case available
    case unconfigured
    case invalid
}

struct RelaySnapshot: Equatable {
    let sourceState: RelaySourceState
    let entries: [RelayEntry]
    let healthByID: [String: RelayHealth]
    let active: ActiveRelay?
    let latestSwitch: SwitchLogEntry?

    static let unconfigured = RelaySnapshot(
        sourceState: .unconfigured,
        entries: [],
        healthByID: [:],
        active: nil,
        latestSwitch: nil
    )

    var activeEntry: RelayEntry? {
        guard let activeID = active?.activeID else {
            return nil
        }
        return entries.first { $0.id == activeID }
    }

    var activeHealth: RelayHealth? {
        guard let activeID = active?.activeID else {
            return nil
        }
        return healthByID[activeID]
    }

    var hasUnhealthyEnabledRelay: Bool {
        entries.contains { entry in
            entry.enabled && healthByID[entry.id]?.ok == false
        }
    }
}

enum BalancePresentation: Equatable {
    case amount(Double, String?)
    case unavailable
    case depleted
    case unsupported

    init(health: RelayHealth?) {
        guard let balance = health?.balance else {
            self = .unavailable
            return
        }
        if let remaining = balance.remaining {
            self = remaining <= 0 ? .depleted : .amount(remaining, balance.currency)
            return
        }
        if balance.note?.contains("不支持") == true {
            self = .unsupported
            return
        }
        self = .unavailable
    }
}

enum SentinelTimeFormat {
    /// 同日 "HH:mm"，跨日 "M-d HH:mm"。
    static func shortTime(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now)
            ? "HH:mm"
            : "M-d HH:mm"
        return formatter.string(from: date)
    }

    static func clockTime(
        _ date: Date,
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

enum BalanceRowPresentation {
    /// 单行余额行的次要文本：到期短格式 > 倍率 > 套餐名。
    static func secondaryText(
        expiresAt: String?,
        note: String?,
        planName: String?
    ) -> String? {
        if let expiresAt, let short = shortExpiry(expiresAt) {
            return short
        }
        if let rate = rateText(from: note) {
            return rate
        }
        if let planName, !planName.isEmpty {
            return planName
        }
        return nil
    }

    /// "2026-10-19…" / "2026/10/19" -> "26-10-19"
    static func shortExpiry(_ raw: String) -> String? {
        let head = String(raw.prefix(10)).replacingOccurrences(of: "/", with: "-")
        let parts = head.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              parts[0].count == 4
        else {
            return nil
        }
        return "\(year % 100)-\(parts[1])-\(parts[2])"
    }

    /// 备注 "按量 0.04 倍率" -> "0.04x"
    static func rateText(from note: String?) -> String? {
        guard let note else {
            return nil
        }
        let pattern = #"(\d+(?:\.\d+)?)\s*倍率"#
        guard let range = note.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let digits = note[range].prefix { character in
            character.isNumber || character == "."
        }
        return digits.isEmpty ? nil : "\(digits)x"
    }
}

enum SentinelAggregation {
    static let activeStatusSeconds: TimeInterval = 10 * 60
    static let recentCompletionSeconds: TimeInterval = 24 * 60 * 60
    static let staleRolloutSeconds: TimeInterval = 10 * 60
    static let recentDisplayCap = 8

    /// 最近完成最多露出 cap 条，溢出并入历史组。
    static func splitRecentDisplay(
        _ presentations: [LinePresentation],
        cap: Int = recentDisplayCap
    ) -> (shown: [LinePresentation], overflow: [LinePresentation]) {
        guard presentations.count > cap else {
            return (presentations, [])
        }
        return (
            Array(presentations.prefix(cap)),
            Array(presentations.dropFirst(cap))
        )
    }

    static func severity(lines: [LineStatus], relay: RelaySnapshot, now: Date = Date()) -> SentinelSeverity {
        let activeLines = lines.filter { $0.isActive(now: now) }
        guard !activeLines.isEmpty else {
            return .gray
        }

        if activeLines.contains(where: \.requiresAttention) {
            return .red
        }

        let allRunning = activeLines.allSatisfy { $0.state == .running }
        let currentRelayHealthy = relay.activeHealth?.ok == true
        let hasWarning = activeLines.contains { line in
            line.state.isRetrying || line.hasStaleRollout || {
                if case .unknown = line.state {
                    return true
                }
                return false
            }()
        }

        if !allRunning || !currentRelayHealthy || relay.hasUnhealthyEnabledRelay || hasWarning {
            return .amber
        }
        return .green
    }

    static func severity(lines: [LineStatus], aio: AIOSnapshot, now: Date = Date()) -> SentinelSeverity {
        let activeLines = lines.filter { $0.isActive(now: now) }
        guard !activeLines.isEmpty else {
            return .gray
        }

        if activeLines.contains(where: \.requiresAttention) {
            return .red
        }

        let allRunning = activeLines.allSatisfy { $0.state == .running }
        let hasLineWarning = activeLines.contains { line in
            line.state.isRetrying || line.hasStaleRollout || {
                if case .unknown = line.state {
                    return true
                }
                return false
            }()
        }
        let hasAIOWarning = aio.routeMode == .aggregate
            && (!aio.aggregateHealthy || aio.hasOpenCircuit || aio.hasLowBalance || aio.hasUsageFailure)

        if !allRunning || hasLineWarning || hasAIOWarning {
            return .amber
        }
        return .green
    }

    static func sortedLines(_ lines: [LineStatus], now: Date = Date()) -> [LineStatus] {
        lines.sorted { lhs, rhs in
            precedes(
                lhsDate: lhs.startedAt,
                lhsSlug: lhs.slug,
                rhsDate: rhs.startedAt,
                rhsSlug: rhs.slug
            )
        }
    }

    static func lineGroups(
        lines: [LineStatus],
        registry: CodexLineRegistry,
        now: Date = Date()
    ) -> SentinelLineGroups {
        let presentations = lines.map { line in
            LinePresentation(
                line: line,
                registration: registry.registration(for: line.slug)
            )
        }
        .sorted { lhs, rhs in
            precedes(
                lhsDate: establishmentDate(for: lhs),
                lhsSlug: lhs.line.slug,
                rhsDate: establishmentDate(for: rhs),
                rhsSlug: rhs.line.slug
            )
        }

        var activeRegistered: [LinePresentation] = []
        var activeUnregistered: [LinePresentation] = []
        var recentlyCompleted: [LinePresentation] = []
        var history: [LinePresentation] = []

        for presentation in presentations {
            if presentation.line.isActive(now: now) {
                if presentation.registration == nil {
                    activeUnregistered.append(presentation)
                } else {
                    activeRegistered.append(presentation)
                }
            } else if presentation.line.isRecentlyCompleted(now: now) {
                recentlyCompleted.append(presentation)
            } else {
                history.append(presentation)
            }
        }

        return SentinelLineGroups(
            activeRegistered: activeRegistered,
            activeUnregistered: activeUnregistered,
            recentlyCompleted: recentlyCompleted,
            history: history
        )
    }

    private static func establishmentDate(for presentation: LinePresentation) -> Date? {
        presentation.registration.map { Date(timeIntervalSince1970: $0.registeredAt) }
            ?? presentation.line.startedAt
    }

    private static func precedes(
        lhsDate: Date?,
        lhsSlug: String,
        rhsDate: Date?,
        rhsSlug: String
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhsSlug < rhsSlug
        }
    }
}
