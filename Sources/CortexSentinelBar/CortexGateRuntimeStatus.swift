import Foundation

// MARK: - 派工路由状态（判据的唯一来源是 cortex 仓，本仓只显示）

/// cortex 仓 `scripts/gates/gate_runtime_status.py --json --ensure` 的输出模型。
/// 路由装没装、落后多少、刷新踢没踢成，全在 cortex 侧算好，Swift 只解码和
/// 显示，不在公开仓里再写一遍判据。schema 不是 1 整份当没有。
struct CortexGateRuntimeStatusPayload: Decodable, Equatable, Sendable {
    let schema: Int
    /// UTC ISO 时刻文本；解析失败只影响内部判断，不进界面。
    let checkedAtText: String?
    /// ok / behind / not_installed / refresh_failed / repo_missing / venv_missing / unknown。
    let state: String?
    /// 一句人话，面板原样上屏，哨兵不自己拼判断。
    let textZH: String?
    let installed: Bool
    let currentSHA: String?
    let originMainSHA: String?
    let behind: Int?
    let routerReady: Bool
    let binStale: Bool?
    let refreshFailed: String?
    let markerAgeSeconds: Int?
    let ensure: Ensure?

    var stateIsOK: Bool { state == "ok" }

    enum CodingKeys: String, CodingKey {
        case schema
        case checked_at
        case state
        case text_zh
        case installed
        case current_sha
        case origin_main_sha
        case behind
        case router_ready
        case bin_stale
        case refresh_failed
        case marker_age_seconds
        case ensure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        checkedAtText = try container.decodeIfPresent(String.self, forKey: .checked_at)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        textZH = try container.decodeIfPresent(String.self, forKey: .text_zh)
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        currentSHA = try container.decodeIfPresent(String.self, forKey: .current_sha)
        originMainSHA = try container.decodeIfPresent(String.self, forKey: .origin_main_sha)
        behind = try container.decodeIfPresent(Int.self, forKey: .behind)
        routerReady = try container.decodeIfPresent(Bool.self, forKey: .router_ready) ?? false
        binStale = try container.decodeIfPresent(Bool.self, forKey: .bin_stale)
        refreshFailed = try container.decodeIfPresent(String.self, forKey: .refresh_failed)
        markerAgeSeconds = try container.decodeIfPresent(Int.self, forKey: .marker_age_seconds)
        ensure = try container.decodeIfPresent(Ensure.self, forKey: .ensure)
    }

    struct Ensure: Decodable, Equatable, Sendable {
        /// none / refresh_kicked / throttled / skipped_not_installed / failed。
        let action: String?
        let detail: String?

        enum CodingKeys: String, CodingKey {
            case action
            case detail
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decodeIfPresent(String.self, forKey: .action)
            detail = try container.decodeIfPresent(String.self, forKey: .detail)
        }
    }
}

/// 面板行的显示状态：最新一次成功的结果 + 失败时的人话原因与失败时刻。
struct CortexGateRuntimeStatusDisplayState: Equatable, Sendable {
    let payload: CortexGateRuntimeStatusPayload?
    /// 最近一次成功读取的时刻；失败不改它。
    let fetchedAt: Date?
    /// 最近一次失败的人话原因；成功后清空。
    let failureText: String?
    /// 最近一次失败尝试的时刻（「HH:MM 这次没读到」用）。
    let failureAt: Date?
}

enum CortexGateRuntimeStatusOutcome: Equatable, Sendable {
    case success(CortexGateRuntimeStatusPayload)
    case failure(reason: String)
}

// MARK: - 取数

/// 从 cortex 仓 origin/main 取派工路由判据脚本并跑一轮（带 --ensure，
/// 路由旧了由 cortex 侧脚本自己踢刷新）。导出流程（认仓 / 清单 / 内容寻址
/// 缓存 / 解释器）走与套餐状态共用的 CortexGitScriptExport 核心，这里只多
/// 「跑脚本 + 解码」两步；判据在 cortex 侧算好，这边不喂任何输入。
enum CortexGateRuntimeStatusFetcher {
    struct Configuration: Sendable {
        var manifestPath: String = "scripts/gate_runtime_status.files"
        var scriptArguments: [String] = ["scripts/gates/gate_runtime_status.py", "--json", "--ensure"]
        var scriptTimeout: TimeInterval = 30
        var export: CortexGitScriptExport.Configuration

        init(
            manifestPath: String = "scripts/gate_runtime_status.files",
            scriptArguments: [String] = ["scripts/gates/gate_runtime_status.py", "--json", "--ensure"],
            scriptTimeout: TimeInterval = 30,
            cacheRoot: URL? = nil,
            export: CortexGitScriptExport.Configuration? = nil
        ) {
            self.manifestPath = manifestPath
            self.scriptArguments = scriptArguments
            self.scriptTimeout = scriptTimeout
            if let export {
                self.export = export
            } else {
                self.export = CortexGitScriptExport.Configuration(
                    cacheRoot: cacheRoot ?? CortexGateRuntimeStatusFetcher.defaultCacheRoot()
                )
            }
        }
    }

    /// 缓存根：用户 Caches 下本 App 自己的子目录（与套餐状态的缓存分开）。
    static func defaultCacheRoot(fileManager: FileManager = .default) -> URL {
        CortexGitScriptExport.defaultCacheRoot("gate-runtime-status", fileManager: fileManager)
    }

    static func fetch(
        environment: [String: String],
        watchDirectory: URL?,
        fallbackRepositoryRoot: URL?,
        homeDirectory: String,
        configuration: Configuration = Configuration(),
        runner: any CortexSubprocessRunning,
        fileManager: FileManager = .default
    ) async -> CortexGateRuntimeStatusOutcome {
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

        // 在缓存目录里跑脚本。
        let run = await runner.run(
            executablePath: exported.interpreterPath,
            arguments: configuration.scriptArguments,
            workingDirectory: exported.cacheDirectory,
            environment: CortexGitScriptExport.scriptEnvironment(homeDirectory: homeDirectory, repoRoot: exported.repoRoot),
            stdin: nil,
            timeout: configuration.scriptTimeout
        )
        guard !run.timedOut else {
            return .failure(reason: "脚本跑超时了")
        }
        guard run.exitCode == 0 else {
            return .failure(reason: "脚本退出码 \(run.exitCode)")
        }

        // 解码；schema 不是 1 整份当没有。
        guard let payload = try? JSONDecoder().decode(CortexGateRuntimeStatusPayload.self, from: run.standardOutput) else {
            return .failure(reason: "脚本输出解析不了")
        }
        guard payload.schema == 1 else {
            return .failure(reason: "脚本版本不认识")
        }
        return .success(payload)
    }
}

// MARK: - 显示规则（纯函数，便于测试）

enum CortexGateRuntimeStatusDisplay {
    /// 上次成功的结果超过这个窗就不再显示旧句。
    static let reuseWindow: TimeInterval = 30 * 60

    struct RowLine: Equatable, Sendable {
        /// 整句（含「派工路由：」前缀），面板原样上屏。
        let text: String
        /// state 为 ok 用普通色；其余态用面板现有提醒色。
        let isWarning: Bool
    }

    /// 面板那一行。nil = 还没跑过任何一轮，不占位。
    static func rowLine(
        _ state: CortexGateRuntimeStatusDisplayState?,
        now: Date
    ) -> RowLine? {
        guard let state else {
            return nil
        }
        // 最近一轮失败：「HH:MM 这次没读到（原因）」。HH:MM 是这次失败尝试的
        // 时刻，每轮都会再试、时刻跟着滚；从没成功过（脚本没落地）也走这句。
        if let failureText = state.failureText, !failureText.isEmpty {
            let clock = clockText(state.failureAt ?? state.fetchedAt ?? now)
            return RowLine(
                text: "派工路由：\(clock) 这次没读到（\(failureText)）",
                isWarning: true
            )
        }
        guard let payload = state.payload, let fetchedAt = state.fetchedAt else {
            return nil
        }
        // 上次成功超过 30 分钟：旧句不再显示，改等下一轮。
        if now.timeIntervalSince(fetchedAt) >= reuseWindow {
            return RowLine(text: "派工路由：状态过时了，等下一轮", isWarning: true)
        }
        // 读到了：text_zh 直接用脚本给的那句，哨兵不自己拼判断。
        let conclusion = Self.conclusionText(of: payload)
        return RowLine(
            text: "派工路由：\(conclusion)（\(clockText(fetchedAt))）",
            isWarning: !payload.stateIsOK
        )
    }

    /// --dump-state 的那行结论：格式同套餐状态那行。
    static func dumpStateText(_ outcome: CortexGateRuntimeStatusOutcome) -> String {
        switch outcome {
        case let .success(payload):
            return "派工路由：\(Self.conclusionText(of: payload))"
        case let .failure(reason):
            return "派工路由：这次没读到（\(reason)）"
        }
    }

    /// --dump-state 现场跑一轮派工路由取数并给出一行结论（独立进程拿不到
    /// 哨兵 App 的内存状态，所以是现场跑）。
    static func dumpStateLine(
        environment: [String: String],
        watchDirectory: URL?,
        fallbackRepositoryRoot: URL?,
        configuration: CortexGateRuntimeStatusFetcher.Configuration = CortexGateRuntimeStatusFetcher.Configuration(),
        runner: any CortexSubprocessRunning = CortexProcessSubprocessRunner()
    ) async -> String {
        let outcome = await CortexGateRuntimeStatusFetcher.fetch(
            environment: environment,
            watchDirectory: watchDirectory,
            fallbackRepositoryRoot: fallbackRepositoryRoot,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            configuration: configuration,
            runner: runner
        )
        return dumpStateText(outcome)
    }

    /// 结论句：优先脚本给的人话，脚本没给就退回 state 原文。
    private static func conclusionText(of payload: CortexGateRuntimeStatusPayload) -> String {
        if let text = payload.textZH, !text.isEmpty {
            return text
        }
        return payload.state ?? "unknown"
    }

    /// 时间用本机时间显示（同套餐状态行的口径）。
    static func clockText(_ date: Date) -> String {
        CortexPlanStatusDisplay.clockText(date)
    }
}
