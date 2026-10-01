import Foundation

// MARK: - 哨兵点灰/恢复的命令侧（COR-9242）

/// 点胶囊后的一句反馈（确认 / 命令失败原因 / 别的原因灰点的解释），带时刻
/// 给显示层判超时；不落盘，面板关掉就没了。
struct DispatchToggleFeedback: Equatable, Sendable {
    let text: String
    let at: Date

    /// 显示窗：过了这秒数就不再占面板一行。
    static let displayWindow: TimeInterval = 60

    /// 现在还显不显示。
    func isVisible(now: Date) -> Bool {
        now.timeIntervalSince(at) < Self.displayWindow
    }
}

/// 调 cortex 仓 `scripts/executor_availability.py` 的 `pause` / `resume
/// --board-only`：只加/去看板说明里的固定标记行「停派：他在哨兵上点灰
/// （MM-DD HH:MM 北京）」，不查不写清单。导出走与派工预案共用的
/// CortexGitScriptExport 核心（预案清单本就带 executor_availability.py，
/// 不另立清单）；写法与判据都在 cortex 侧，Swift 不自己改看板。
enum ExecutorAvailabilityCommandFetcher {
    struct Configuration: Sendable {
        var manifestPath: String = "scripts/dispatch_route_preview.files"
        var scriptTimeout: TimeInterval = 30
        var export: CortexGitScriptExport.Configuration

        init(
            manifestPath: String = "scripts/dispatch_route_preview.files",
            scriptTimeout: TimeInterval = 30,
            cacheRoot: URL? = nil,
            export: CortexGitScriptExport.Configuration? = nil
        ) {
            self.manifestPath = manifestPath
            self.scriptTimeout = scriptTimeout
            self.export = export ?? CortexGitScriptExport.Configuration(
                cacheRoot: cacheRoot ?? CortexGitScriptExport.defaultCacheRoot("dispatch-toggle")
            )
        }
    }

    enum Outcome: Equatable, Sendable {
        /// 命令退出码 0；message 是给面板的一句确认（点变没变以重拉的预案为准）。
        case success(message: String)
        case failure(reason: String)
    }

    /// 跑一条 --board-only 命令。成败只以脚本退出码与输出为准；调用方拿到
    /// success 也只许刷预案、不许先改点的颜色。
    static func run(
        action: CortexRoutePreviewDisplay.DispatchDotAction,
        environment: [String: String],
        watchDirectory: URL?,
        fallbackRepositoryRoot: URL?,
        homeDirectory: String,
        configuration: Configuration = Configuration(),
        runner: any CortexSubprocessRunning,
        fileManager: FileManager = .default
    ) async -> Outcome {
        let subcommand: String
        let executorID: String
        switch action {
        case let .pauseBoardOnly(id):
            subcommand = "pause"
            executorID = id
        case let .resumeBoardOnly(id):
            subcommand = "resume"
            executorID = id
        case let .information(reason):
            return .failure(reason: reason)
        }
        let exported: CortexGitScriptExport.Exported
        switch await CortexGitScriptExport.run(
            manifestPath: configuration.manifestPath,
            configuration: configuration.export,
            environment: environment,
            watchDirectory: watchDirectory,
            fallbackRepositoryRoot: fallbackRepositoryRoot,
            homeDirectory: homeDirectory,
            runner: runner,
            fileManager: fileManager
        ) {
        case let .exported(value):
            exported = value
        case let .failed(reason):
            return .failure(reason: reason)
        }
        let run = await runner.run(
            executablePath: exported.interpreterPath,
            arguments: ["scripts/executor_availability.py", subcommand, executorID, "--board-only"],
            workingDirectory: exported.cacheDirectory,
            environment: CortexGitScriptExport.scriptEnvironment(homeDirectory: homeDirectory, repoRoot: exported.repoRoot),
            stdin: nil,
            timeout: configuration.scriptTimeout
        )
        guard !run.timedOut else {
            return .failure(reason: "命令跑超时了")
        }
        guard run.exitCode == 0 else {
            return .failure(reason: failureReason(
                subcommand: subcommand,
                exitCode: run.exitCode,
                standardError: run.standardError,
                standardOutput: run.standardOutput
            ))
        }
        return .success(message: subcommand == "pause"
            ? "停派已写上看板，等预案刷新变灰"
            : "停派标记已去掉，等预案刷新变绿")
    }

    /// 失败原因：脚本失败往 stderr 打一行 `EXECUTOR_AVAILABILITY_*_FAILED <人话>`，
    /// 取最后一条非空行、剥掉前缀上屏，比裸退出码有用；两路输出都没有人话时
    /// 才退回退出码。
    static func failureReason(
        subcommand: String,
        exitCode: Int32,
        standardError: Data,
        standardOutput: Data
    ) -> String {
        let verb = subcommand == "pause" ? "停派" : "恢复"
        let prefixes = [
            "EXECUTOR_AVAILABILITY_PAUSE_FAILED",
            "EXECUTOR_AVAILABILITY_RESUME_FAILED",
        ]
        for data in [standardError, standardOutput] {
            guard let text = String(data: data, encoding: .utf8) else {
                continue
            }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else {
                    continue
                }
                for prefix in prefixes where line.hasPrefix(prefix) {
                    let detail = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    return detail.isEmpty ? line : detail
                }
                return line
            }
        }
        return "\(verb)命令退出码 \(exitCode)"
    }
}
