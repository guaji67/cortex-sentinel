import Foundation

/// 设置窗口文案。工单逐字指定，测试按常量对齐，不要在界面里另写一份。
enum SentinelSettingsCopy {
    static let windowTitle = "设置"
    static let loginItemTitle = "开机时自动启动"
    static let loginItemManagedHint = "由系统服务托管，改这里没用"
    static let historyTitle = "历史最多保留"
    static let historyUnit = "条"
    static let historyHint = "超出的旧记录会自动清掉，正在跑的线不会被清。"
    static let notifyTitle = "任务结束时通知我"
    static let watchTitle = "盯这个文件夹"
    static let watchChoose = "选择…"
    static let watchHint = "派工工具把状态文件写在这里。"
    static let watchLockedHint = "由启动配置指定"
}

/// UserDefaults 键。一律带 bundle 前缀，避免跟别的 app 撞。
enum SentinelSettingsKey {
    static let bundlePrefix = "com.falcon.cortex.sentinelbar"
    static let loginItemEnabled = "\(bundlePrefix).loginItemEnabled"
    static let historyRetainCount = "\(bundlePrefix).historyRetainCount"
    static let notifyOnTaskComplete = "\(bundlePrefix).notifyOnTaskComplete"
    static let watchDirectory = "\(bundlePrefix).watchDirectory"
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
        if defaults.object(forKey: SentinelSettingsKey.loginItemEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: SentinelSettingsKey.loginItemEnabled)
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

    static func notifyOnTaskComplete(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: SentinelSettingsKey.notifyOnTaskComplete) == nil {
            return true
        }
        return defaults.bool(forKey: SentinelSettingsKey.notifyOnTaskComplete)
    }

    static func setNotifyOnTaskComplete(_ value: Bool, defaults: UserDefaults) {
        defaults.set(value, forKey: SentinelSettingsKey.notifyOnTaskComplete)
    }

    static func watchDirectoryPath(defaults: UserDefaults) -> String? {
        defaults.string(forKey: SentinelSettingsKey.watchDirectory)
    }

    static func setWatchDirectory(_ url: URL, defaults: UserDefaults) {
        defaults.set(url.path, forKey: SentinelSettingsKey.watchDirectory)
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
        let loginState = login.isOn ? "开" : "关"
        let loginLock = login.trailingHint.map { "（\($0)）" } ?? ""
        let watchLock = watch.source.isLockedByEnvironment
            ? "（\(SentinelSettingsCopy.watchLockedHint)）"
            : ""
        return [
            "设置：",
            "  \(SentinelSettingsCopy.loginItemTitle)：\(loginState)\(loginLock)",
            "  \(SentinelSettingsCopy.historyTitle)：\(historyRetainCount(defaults: defaults)) \(SentinelSettingsCopy.historyUnit)（默认 \(StatusFileRetention.defaultCap)，常量 StatusFileRetention.defaultCap）",
            "  \(SentinelSettingsCopy.notifyTitle)：\(notifyOnTaskComplete(defaults: defaults) ? "开" : "关")",
            "  \(SentinelSettingsCopy.watchTitle)：\(watch.logsDirectory.path)\(watchLock)",
        ]
    }
}
