import Foundation

// MARK: - 通道汇总过期自刷（logs/channel-status.json）

/// 面板通道三卡读监视目录里的 channel-status.json，写它的是 cortex 的
/// scripts/channel_status.py。以前只有 grok / codex 派工器和 Claude 提问钩子
/// 顺手刷新；钩子关了、codebuddy 派工器从不刷，CodeBuddy 线跑着，卡上仍是
/// 两小时前的「查不出」，下面的派工列表却显示在跑。
/// 哨兵每轮读完盘看一眼：汇总比最新的派工线状态文件旧、或放得太久，就按
/// cortex 仓 scripts/channel_status.files 导出判据脚本，在监视目录上重算一次。
/// 判据单源在 cortex，哨兵只管「什么时候叫它算」，不自己判通不通。
enum CortexChannelStatusRefresh {
    /// 两次重算之间至少隔这么久。跟 cortex 侧 channel_status.FRESH_SECONDS 同一把尺。
    static let minimumInterval: TimeInterval = 60
    /// 没有新状态文件也重算的上限：线静默死掉、Grok 登录态变化都靠它跟上。
    static let maximumSnapshotAge: TimeInterval = 10 * 60
    /// 上次没算成（找不到仓、脚本报错）就退到这么久再试，不每轮空跑 git。
    static let failureBackoff: TimeInterval = 10 * 60

    struct Attempt: Equatable, Sendable {
        let at: Date
        let failed: Bool
    }

    struct Request: Sendable {
        let environment: [String: String]
        let watchDirectory: URL
        let fallbackRepositoryRoot: URL?
        let homeDirectory: String
    }

    enum Outcome: Equatable, Sendable {
        case refreshed
        case failure(reason: String)
    }

    typealias Refresher = @Sendable (Request) async -> Outcome

    struct Configuration: Sendable {
        var manifestPath: String = "scripts/channel_status.files"
        var scriptPath: String = "scripts/channel_status.py"
        /// Grok 登录探针最坏 4s + 2s 退避 + 8s 重试，再加收死线，留足余量。
        var scriptTimeout: TimeInterval = 60
        var export: CortexGitScriptExport.Configuration

        init(cacheRoot: URL? = nil, export: CortexGitScriptExport.Configuration? = nil) {
            self.export = export ?? CortexGitScriptExport.Configuration(
                cacheRoot: cacheRoot ?? CortexGitScriptExport.defaultCacheRoot("channel-status")
            )
        }
    }

    /// 这一轮要不要叫 cortex 重算。纯函数，时刻全由调用方给。
    static func shouldRefresh(
        snapshotModifiedAt: Date?,
        newestLineStatusModifiedAt: Date?,
        lastAttempt: Attempt?,
        now: Date
    ) -> Bool {
        if let lastAttempt {
            let wait = lastAttempt.failed ? failureBackoff : minimumInterval
            if now.timeIntervalSince(lastAttempt.at) < wait {
                return false
            }
        }
        guard let snapshotModifiedAt else {
            // 还没有汇总：有派工线才值得算，空目录不去碰 git。
            return newestLineStatusModifiedAt != nil
        }
        if let newest = newestLineStatusModifiedAt, newest > snapshotModifiedAt {
            return true
        }
        return now.timeIntervalSince(snapshotModifiedAt) > maximumSnapshotAge
    }

    /// 产品用的重算器；跑单元测试时给 nil，测试不许顺着闸运行时摸到真 cortex 仓去写盘。
    static func productionRefresherUnlessTesting(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Refresher? {
        if processEnvironment["XCTestConfigurationFilePath"] != nil
            || processEnvironment["XCTestSessionIdentifier"] != nil {
            return nil
        }
        return { request in
            await refresh(request: request, runner: CortexProcessSubprocessRunner())
        }
    }

    static func refresh(
        request: Request,
        configuration: Configuration = Configuration(),
        runner: any CortexSubprocessRunning,
        fileManager: FileManager = .default
    ) async -> Outcome {
        let exported: CortexGitScriptExport.Exported
        switch await CortexGitScriptExport.run(
            manifestPath: configuration.manifestPath,
            configuration: configuration.export,
            environment: request.environment,
            watchDirectory: request.watchDirectory,
            fallbackRepositoryRoot: request.fallbackRepositoryRoot,
            homeDirectory: request.homeDirectory,
            runner: runner,
            fileManager: fileManager
        ) {
        case let .exported(value):
            exported = value
        case let .failed(reason):
            return .failure(reason: reason)
        }
        // 汇总写回监视目录本身（面板读的就是这一份），不落导出缓存。
        let run = await runner.run(
            executablePath: exported.interpreterPath,
            arguments: [configuration.scriptPath, "--logs-dir", request.watchDirectory.path],
            workingDirectory: exported.cacheDirectory,
            environment: CortexGitScriptExport.scriptEnvironment(
                homeDirectory: request.homeDirectory,
                repoRoot: exported.repoRoot,
                logsDirectory: request.watchDirectory
            ),
            stdin: nil,
            timeout: configuration.scriptTimeout
        )
        guard !run.timedOut else {
            return .failure(reason: "脚本跑超时了")
        }
        guard run.exitCode == 0 else {
            return .failure(reason: "脚本退出码 \(run.exitCode)")
        }
        return .refreshed
    }
}
