import Foundation

/// 设置窗口文案。工单逐字指定，测试按常量对齐，不要在界面里另写一份。
enum SentinelSettingsCopy {
    static let windowTitle = "哨兵设置"

    static let notifyGroupTitle = "通知"
    static let notifyMasterTitle = "通知我"
    static let notifyTaskCompleteTitle = "任务干完了"
    static let notifyTaskProblemTitle = "任务出问题了"
    static let notifyTaskProblemHint = "卡住、失败、被中止"
    static let notifyChannelTitle = "AI 通道出问题或余额不够"
    static let notifyChannelHint = "连不上、被熔断、你的额度快用完"
    static let notifyCadenceTitle = "什么时候说"
    static let notifyCadenceHint = "攒起来的会合成一条，比如「3 个任务干完了」。"
    static let notifyCadenceEvery = "每条都弹"
    static let notifyCadence1m = "攒 1 分钟一起说"
    static let notifyCadence5m = "攒 5 分钟一起说"

    static let historyGroupTitle = "历史"
    static let historyTitle = "最多留"
    static let historyUnit = "条"
    static let historyHint = "超出的旧记录会自动清掉，正在跑的任务不会被清。"

    static let refreshGroupTitle = "刷新"
    static let panelOpenRefreshTitle = "面板开着时"
    static let panelOpenRefreshHint = "你正看着的时候查得勤一点。"
    static let panelClosedRefreshTitle = "面板关着时"
    static let panelClosedRefreshHint = "没人看的时候慢一点，省电。"
    static let balanceRecheckTitle = "余额隔多久重查"
    static let balanceRecheckHint = "点开面板时，上次查过超过这个时间就重查，没超过就用现成的。"
    static let refreshInterval2s = "2 秒"
    static let refreshInterval5s = "5 秒"
    static let refreshInterval10s = "10 秒"
    static let refreshInterval30s = "30 秒"
    static let refreshInterval1m = "1 分钟"
    static let refreshInterval2m = "2 分钟"
    static let refreshInterval5m = "5 分钟"

    static let startupGroupTitle = "启动与文件夹"
    static let loginItemTitle = "开机时自动启动"
    static let loginItemManagedHint = "由系统服务托管，改这里没用"
    static let watchTitle = "盯这个文件夹"
    static let watchChoose = "选择"
    static let watchHint = "派工工具把任务状态写在这里，一般不用改。"
    static let watchLockedHint = "装的时候定好的，要换得重装。"
    static let versionPrefix = "版本"
    static let versionDevLabel = "开发版"
}

enum SentinelAppVersion {
    static let devBundleVersion = "dev"

    static let gitHashDisplayLength = 7

    static func displayLine(
        shortVersion: String,
        bundleVersion: String
    ) -> String {
        let buildLabel = bundleVersion == devBundleVersion
            ? SentinelSettingsCopy.versionDevLabel
            : shortenedGitHash(bundleVersion)
        return "\(SentinelSettingsCopy.versionPrefix) \(shortVersion)（\(buildLabel)）"
    }

    /// 出包写入的是 12 位短哈希；设置窗只显示 7 位。非哈希版本号原样留下。
    static func shortenedGitHash(_ bundleVersion: String) -> String {
        guard bundleVersion.count > gitHashDisplayLength else {
            return bundleVersion
        }
        let isGitHash = bundleVersion.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x61 && scalar.value <= 0x66)
                || (scalar.value >= 0x41 && scalar.value <= 0x46)
        }
        guard isGitHash else {
            return bundleVersion
        }
        return String(bundleVersion.prefix(gitHashDisplayLength))
    }

    static func displayLine(bundle: Bundle = .main) -> String {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ""
        let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? devBundleVersion
        return displayLine(shortVersion: shortVersion, bundleVersion: bundleVersion)
    }
}

/// UserDefaults 键。一律带 bundle 前缀，避免跟别的 app 撞。
enum SentinelSettingsKey {
    static let bundlePrefix = "com.falcon.cortex.sentinelbar"
    static let loginItemEnabled = "\(bundlePrefix).loginItemEnabled"
    static let historyRetainCount = "\(bundlePrefix).historyRetainCount"
    /// 主开关。沿用旧键：以前关掉等于四种通知全关。
    static let notifyOnTaskComplete = "\(bundlePrefix).notifyOnTaskComplete"
    static let notifyCategoryTaskComplete = "\(bundlePrefix).notifyCategoryTaskComplete"
    static let notifyCategoryTaskProblem = "\(bundlePrefix).notifyCategoryTaskProblem"
    static let notifyCategoryChannelAlert = "\(bundlePrefix).notifyCategoryChannelAlert"
    static let notifyCadence = "\(bundlePrefix).notifyCadence"
    static let watchDirectory = "\(bundlePrefix).watchDirectory"
    static let panelOpenRefreshInterval = "\(bundlePrefix).panelOpenRefreshInterval"
    static let panelClosedRefreshInterval = "\(bundlePrefix).panelClosedRefreshInterval"
    static let balanceRecheckInterval = "\(bundlePrefix).balanceRecheckInterval"
}

protocol SentinelRefreshIntervalOption: Hashable, RawRepresentable where RawValue == TimeInterval {
    var title: String { get }
}

enum SentinelPanelOpenRefreshInterval: TimeInterval, CaseIterable, Equatable, SentinelRefreshIntervalOption {
    case twoSeconds = 2
    case fiveSeconds = 5
    case tenSeconds = 10

    static let `default` = SentinelPanelOpenRefreshInterval.fiveSeconds

    var title: String {
        switch self {
        case .twoSeconds:
            return SentinelSettingsCopy.refreshInterval2s
        case .fiveSeconds:
            return SentinelSettingsCopy.refreshInterval5s
        case .tenSeconds:
            return SentinelSettingsCopy.refreshInterval10s
        }
    }
}

enum SentinelPanelClosedRefreshInterval: TimeInterval, CaseIterable, Equatable, SentinelRefreshIntervalOption {
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    static let `default` = SentinelPanelClosedRefreshInterval.twoMinutes

    var title: String {
        switch self {
        case .thirtySeconds:
            return SentinelSettingsCopy.refreshInterval30s
        case .oneMinute:
            return SentinelSettingsCopy.refreshInterval1m
        case .twoMinutes:
            return SentinelSettingsCopy.refreshInterval2m
        case .fiveMinutes:
            return SentinelSettingsCopy.refreshInterval5m
        }
    }
}

enum SentinelBalanceRecheckInterval: TimeInterval, CaseIterable, Equatable, SentinelRefreshIntervalOption {
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300

    static let `default` = SentinelBalanceRecheckInterval.thirtySeconds

    var title: String {
        switch self {
        case .thirtySeconds:
            return SentinelSettingsCopy.refreshInterval30s
        case .oneMinute:
            return SentinelSettingsCopy.refreshInterval1m
        case .fiveMinutes:
            return SentinelSettingsCopy.refreshInterval5m
        }
    }
}

enum SentinelNotifyCadence: String, CaseIterable, Equatable {
    case every
    case coalesce1m
    case coalesce5m

    static let `default` = SentinelNotifyCadence.coalesce1m

    var title: String {
        switch self {
        case .every:
            return SentinelSettingsCopy.notifyCadenceEvery
        case .coalesce1m:
            return SentinelSettingsCopy.notifyCadence1m
        case .coalesce5m:
            return SentinelSettingsCopy.notifyCadence5m
        }
    }

    var windowLength: TimeInterval? {
        switch self {
        case .every:
            return nil
        case .coalesce1m:
            return 60
        case .coalesce5m:
            return 300
        }
    }
}

struct SentinelNotifyPreferences: Equatable {
    var masterEnabled: Bool
    var taskCompleteEnabled: Bool
    var taskProblemEnabled: Bool
    var channelAlertEnabled: Bool
    var cadence: SentinelNotifyCadence

    static let `default` = SentinelNotifyPreferences(
        masterEnabled: true,
        taskCompleteEnabled: true,
        taskProblemEnabled: true,
        channelAlertEnabled: true,
        cadence: .default
    )

    static func load(defaults: UserDefaults) -> SentinelNotifyPreferences {
        SentinelNotifyPreferences(
            masterEnabled: SentinelSettings.notifyMasterEnabled(defaults: defaults),
            taskCompleteEnabled: SentinelSettings.notifyCategoryEnabled(
                key: SentinelSettingsKey.notifyCategoryTaskComplete,
                defaults: defaults
            ),
            taskProblemEnabled: SentinelSettings.notifyCategoryEnabled(
                key: SentinelSettingsKey.notifyCategoryTaskProblem,
                defaults: defaults
            ),
            channelAlertEnabled: SentinelSettings.notifyCategoryEnabled(
                key: SentinelSettingsKey.notifyCategoryChannelAlert,
                defaults: defaults
            ),
            cadence: SentinelSettings.notifyCadence(defaults: defaults)
        )
    }

    func allows(_ category: SentinelNotifyCategory) -> Bool {
        guard masterEnabled else {
            return false
        }
        switch category {
        case .taskComplete:
            return taskCompleteEnabled
        case .taskProblem:
            return taskProblemEnabled
        case .channelAlert:
            return channelAlertEnabled
        }
    }
}

/// 监视目录从哪来。环境变量在时设置项只读，不参与解析。
struct WatchDirectoryResolution: Equatable {
    enum Source: Equatable {
        case environmentWatchDir
        case environmentRepoRoot
        case userDefaults
        case defaultHome

        var isLockedByEnvironment: Bool {
            switch self {
            case .environmentWatchDir, .environmentRepoRoot:
                return true
            case .userDefaults, .defaultHome:
                return false
            }
        }
    }

    var logsDirectory: URL
    var repositoryRoot: URL
    var source: Source

    static func resolve(
        environment: [String: String],
        defaults: UserDefaults
    ) -> WatchDirectoryResolution {
        if let watch = environment["CORTEX_SENTINEL_WATCH_DIR"], !watch.isEmpty {
            let logs = URL(fileURLWithPath: watch, isDirectory: true)
            let repo: URL
            if let configured = environment["CORTEX_REPO_ROOT"], !configured.isEmpty {
                repo = URL(fileURLWithPath: configured, isDirectory: true)
            } else {
                repo = logs.deletingLastPathComponent()
            }
            return WatchDirectoryResolution(
                logsDirectory: logs,
                repositoryRoot: repo,
                source: .environmentWatchDir
            )
        }
        if let configured = environment["CORTEX_REPO_ROOT"], !configured.isEmpty {
            let repo = URL(fileURLWithPath: configured, isDirectory: true)
            return WatchDirectoryResolution(
                logsDirectory: repo.appendingPathComponent("logs", isDirectory: true),
                repositoryRoot: repo,
                source: .environmentRepoRoot
            )
        }
        if let stored = SentinelSettings.watchDirectoryPath(defaults: defaults), !stored.isEmpty {
            let logs = URL(fileURLWithPath: stored, isDirectory: true)
            return WatchDirectoryResolution(
                logsDirectory: logs,
                repositoryRoot: logs.deletingLastPathComponent(),
                source: .userDefaults
            )
        }
        let logs = SentinelPaths.defaultWatchDirectory
        return WatchDirectoryResolution(
            logsDirectory: logs,
            repositoryRoot: logs.deletingLastPathComponent(),
            source: .defaultHome
        )
    }
}

/// 设置窗开机自启那一行：复用 `LaunchdSupervisionProbe` 的托管判定，不另写一套。
struct LoginItemSettingsPresentation: Equatable {
    var isOn: Bool
    var isControlEnabled: Bool
    var trailingHint: String?

    static func make(signals: LaunchdSupervisionSignals, wantsEnabled: Bool) -> LoginItemSettingsPresentation {
        if signals.isLaunchdManaged {
            return LoginItemSettingsPresentation(
                isOn: true,
                isControlEnabled: false,
                trailingHint: SentinelSettingsCopy.loginItemManagedHint
            )
        }
        return LoginItemSettingsPresentation(
            isOn: wantsEnabled,
            isControlEnabled: true,
            trailingHint: nil
        )
    }
}

enum SentinelNotificationPlanner {
    /// 从非终态走进终态（done / killed）的线。开关关掉时调用方根本不 send。
    static func completedLines(
        priorStates: [String: LineState],
        lines: [LineStatus]
    ) -> [LineStatus] {
        lines.filter { line in
            guard line.state.isTerminal else {
                return false
            }
            guard let prior = priorStates[line.id] else {
                return false
            }
            return !prior.isTerminal
        }
    }

    static func newlyCriticalLines(
        priorStates: [String: LineState],
        lines: [LineStatus],
        now: Date
    ) -> [LineStatus] {
        lines.filter { line in
            line.isActive(now: now)
                && line.state.isCritical
                && priorStates[line.id]?.isCritical != true
        }
    }

    static func newlyOpenedCircuits(
        prior: [Int64: Bool]?,
        providers: [AIOProvider]
    ) -> [AIOProvider] {
        providers.filter { provider in
            provider.circuitState.isOpen && prior?[provider.id] != true
        }
    }

    static func newlyLowBalanceProviders(
        prior: Set<Int64>?,
        providers: [AIOProvider]
    ) -> [AIOProvider] {
        providers.filter { provider in
            provider.isLowBalance && prior?.contains(provider.id) != true
        }
    }
}

enum SentinelSettings {
    static let isolatedTestsSuite = "com.falcon.cortex.sentinelbar.xctest"
    static let isolatedDiagnosticsSuite = "com.falcon.cortex.sentinelbar.diagnostics"

    static func resolvedDefaults(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return UserDefaults(suiteName: isolatedTestsSuite) ?? .standard
        }
        if arguments.contains(where: { LoginItemRuntime.diagnosticArguments.contains($0) }) {
            return UserDefaults(suiteName: isolatedDiagnosticsSuite) ?? .standard
        }
        return .standard
    }

    static func loginItemEnabled(defaults: UserDefaults) -> Bool {
        bool(forKey: SentinelSettingsKey.loginItemEnabled, defaults: defaults, fallback: true)
    }

    static func setLoginItemEnabled(_ value: Bool, defaults: UserDefaults) {
        defaults.set(value, forKey: SentinelSettingsKey.loginItemEnabled)
    }

    /// 默认走另一条线留下的 `StatusFileRetention.defaultCap`，不另造上限。
    static func historyRetainCount(defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: SentinelSettingsKey.historyRetainCount) else {
            return StatusFileRetention.defaultCap
        }
        let value: Int
        if let int = stored as? Int {
            value = int
        } else if let number = stored as? NSNumber {
            value = number.intValue
        } else {
            return StatusFileRetention.defaultCap
        }
        return max(1, value)
    }

    static func setHistoryRetainCount(_ value: Int, defaults: UserDefaults) {
        defaults.set(max(1, value), forKey: SentinelSettingsKey.historyRetainCount)
    }

    static func notifyMasterEnabled(defaults: UserDefaults) -> Bool {
        notifyOnTaskComplete(defaults: defaults)
    }

    static func setNotifyMasterEnabled(_ value: Bool, defaults: UserDefaults) {
        setNotifyOnTaskComplete(value, defaults: defaults)
    }

    static func notifyOnTaskComplete(defaults: UserDefaults) -> Bool {
        bool(forKey: SentinelSettingsKey.notifyOnTaskComplete, defaults: defaults, fallback: true)
    }

    static func setNotifyOnTaskComplete(_ value: Bool, defaults: UserDefaults) {
        defaults.set(value, forKey: SentinelSettingsKey.notifyOnTaskComplete)
    }

    static func notifyCategoryEnabled(key: String, defaults: UserDefaults) -> Bool {
        bool(forKey: key, defaults: defaults, fallback: true)
    }

    static func setNotifyCategoryEnabled(_ value: Bool, key: String, defaults: UserDefaults) {
        defaults.set(value, forKey: key)
    }

    static func notifyCadence(defaults: UserDefaults) -> SentinelNotifyCadence {
        guard let raw = defaults.string(forKey: SentinelSettingsKey.notifyCadence),
              let cadence = SentinelNotifyCadence(rawValue: raw)
        else {
            return .default
        }
        return cadence
    }

    static func setNotifyCadence(_ value: SentinelNotifyCadence, defaults: UserDefaults) {
        defaults.set(value.rawValue, forKey: SentinelSettingsKey.notifyCadence)
    }

    static func watchDirectoryPath(defaults: UserDefaults) -> String? {
        defaults.string(forKey: SentinelSettingsKey.watchDirectory)
    }

    static func setWatchDirectory(_ url: URL, defaults: UserDefaults) {
        defaults.set(url.path, forKey: SentinelSettingsKey.watchDirectory)
    }

    static func panelOpenRefreshInterval(defaults: UserDefaults) -> SentinelPanelOpenRefreshInterval {
        interval(
            forKey: SentinelSettingsKey.panelOpenRefreshInterval,
            defaults: defaults,
            fallback: .default
        )
    }

    static func setPanelOpenRefreshInterval(
        _ value: SentinelPanelOpenRefreshInterval,
        defaults: UserDefaults
    ) {
        defaults.set(value.rawValue, forKey: SentinelSettingsKey.panelOpenRefreshInterval)
    }

    static func panelClosedRefreshInterval(defaults: UserDefaults) -> SentinelPanelClosedRefreshInterval {
        interval(
            forKey: SentinelSettingsKey.panelClosedRefreshInterval,
            defaults: defaults,
            fallback: .default
        )
    }

    static func setPanelClosedRefreshInterval(
        _ value: SentinelPanelClosedRefreshInterval,
        defaults: UserDefaults
    ) {
        defaults.set(value.rawValue, forKey: SentinelSettingsKey.panelClosedRefreshInterval)
    }

    static func balanceRecheckInterval(defaults: UserDefaults) -> SentinelBalanceRecheckInterval {
        interval(
            forKey: SentinelSettingsKey.balanceRecheckInterval,
            defaults: defaults,
            fallback: .default
        )
    }

    static func setBalanceRecheckInterval(
        _ value: SentinelBalanceRecheckInterval,
        defaults: UserDefaults
    ) {
        defaults.set(value.rawValue, forKey: SentinelSettingsKey.balanceRecheckInterval)
    }

    private static func interval<Value: RawRepresentable>(
        forKey key: String,
        defaults: UserDefaults,
        fallback: Value
    ) -> Value where Value.RawValue == TimeInterval {
        guard let stored = defaults.object(forKey: key) else {
            return fallback
        }
        let raw: TimeInterval
        if let number = stored as? NSNumber {
            raw = number.doubleValue
        } else if let value = stored as? TimeInterval {
            raw = value
        } else {
            return fallback
        }
        return Value(rawValue: raw) ?? fallback
    }

    static func dumpLines(
        defaults: UserDefaults,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        signals: LaunchdSupervisionSignals
    ) -> [String] {
        let watch = WatchDirectoryResolution.resolve(environment: environment, defaults: defaults)
        let login = LoginItemSettingsPresentation.make(
            signals: signals,
            wantsEnabled: loginItemEnabled(defaults: defaults)
        )
        let notify = SentinelNotifyPreferences.load(defaults: defaults)
        let loginState = login.isOn ? "开" : "关"
        let loginLock = login.trailingHint.map { "（\($0)）" } ?? ""
        let watchLock = watch.source.isLockedByEnvironment
            ? "（\(SentinelSettingsCopy.watchLockedHint)）"
            : ""
        return [
            "设置：",
            "  \(SentinelSettingsCopy.notifyMasterTitle)：\(notify.masterEnabled ? "开" : "关")",
            "  \(SentinelSettingsCopy.notifyTaskCompleteTitle)：\(notify.taskCompleteEnabled ? "开" : "关")",
            "  \(SentinelSettingsCopy.notifyTaskProblemTitle)：\(notify.taskProblemEnabled ? "开" : "关")",
            "  \(SentinelSettingsCopy.notifyChannelTitle)：\(notify.channelAlertEnabled ? "开" : "关")",
            "  \(SentinelSettingsCopy.notifyCadenceTitle)：\(notify.cadence.title)",
            "  \(SentinelSettingsCopy.panelOpenRefreshTitle)：\(panelOpenRefreshInterval(defaults: defaults).title)",
            "  \(SentinelSettingsCopy.panelClosedRefreshTitle)：\(panelClosedRefreshInterval(defaults: defaults).title)",
            "  \(SentinelSettingsCopy.balanceRecheckTitle)：\(balanceRecheckInterval(defaults: defaults).title)",
            "  \(SentinelSettingsCopy.historyTitle)：\(historyRetainCount(defaults: defaults)) \(SentinelSettingsCopy.historyUnit)（默认 \(StatusFileRetention.defaultCap)，常量 StatusFileRetention.defaultCap）",
            "  \(SentinelSettingsCopy.loginItemTitle)：\(loginState)\(loginLock)",
            "  \(SentinelSettingsCopy.watchTitle)：\(watch.logsDirectory.path)\(watchLock)",
        ]
    }

    private static func bool(forKey key: String, defaults: UserDefaults, fallback: Bool) -> Bool {
        if defaults.object(forKey: key) == nil {
            return fallback
        }
        return defaults.bool(forKey: key)
    }
}
