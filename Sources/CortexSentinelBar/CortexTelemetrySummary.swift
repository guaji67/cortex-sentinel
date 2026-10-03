import Foundation

// MARK: - 三机总览（跨机遥测，判据与采样在 cortex 仓 sentry_telemetry.py，本仓只显示）

/// cortex 仓 `scripts/sentry_telemetry.py summary` 的输出模型（schema 2）。
/// 机器 KV（负载/内存/swap/槽位/线数模型分布）由各机哨兵定时写入 Multica 票
/// COR-6761 的 metadata，本侧只拉取渲染。
struct CortexTelemetrySummaryPayload: Decodable, Equatable, Sendable {
    let schema: Int
    let machines: [Machine]
    let multica: Multica?

    enum CodingKeys: String, CodingKey {
        case schema
        case machines
        case multica
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        machines = try container.decodeIfPresent([Machine].self, forKey: .machines) ?? []
        multica = try container.decodeIfPresent(Multica.self, forKey: .multica)
    }

    struct Machine: Decodable, Equatable, Sendable {
        let machine: String?
        let cpuPct: Double?
        let memFreePct: Double?
        /// 活动监视器同源占用口径（active+wired+压缩占用），cortex 侧算好。
        let memUsedPct: Double?
        /// 内核内存压力等级：1 正常 / 2 警告 / 4 危急。
        let pressureLevel: Int?
        let load: Double?
        let swap: Swap?
        let devSlots: DevSlots?
        let linesByModel: [String: Int]?
        let ts: String?
        /// 这台在跑的哨兵版本（CFBundleShortVersionString），LAN 上报时盖进载荷；
        /// KV 老数据与没升级的旧哨兵没这键 → nil，面板版本行写「没读到」。
        let sentinelVersion: String?
        /// 这台哨兵的构建号（CFBundleVersion）：正式版是日期（如 20260924），
        /// 开发构建是 dev 或 git 短哈希，版本行靠它分「正式版号 / 开发版 <哈希>」。
        let sentinelBuild: String?

        enum CodingKeys: String, CodingKey {
            case machine
            case cpuPct = "cpu_pct"
            case memFreePct = "mem_free_pct"
            case memUsedPct = "mem_used_pct"
            case pressureLevel = "pressure_level"
            case load
            case swap
            case devSlots = "dev_slots"
            case linesByModel = "lines_by_model"
            case ts
            case sentinelVersion = "sentinel_version"
            case sentinelBuild = "sentinel_build"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            machine = try container.decodeIfPresent(String.self, forKey: .machine)
            cpuPct = try container.decodeIfPresent(Double.self, forKey: .cpuPct)
            memFreePct = try container.decodeIfPresent(Double.self, forKey: .memFreePct)
            memUsedPct = try container.decodeIfPresent(Double.self, forKey: .memUsedPct)
            pressureLevel = try container.decodeIfPresent(Int.self, forKey: .pressureLevel)
            load = try container.decodeIfPresent(Double.self, forKey: .load)
            swap = try container.decodeIfPresent(Swap.self, forKey: .swap)
            devSlots = try container.decodeIfPresent(DevSlots.self, forKey: .devSlots)
            linesByModel = try container.decodeIfPresent([String: Int].self, forKey: .linesByModel)
            ts = try container.decodeIfPresent(String.self, forKey: .ts)
            sentinelVersion = try container.decodeIfPresent(String.self, forKey: .sentinelVersion)
            sentinelBuild = try container.decodeIfPresent(String.self, forKey: .sentinelBuild)
        }
    }

    struct Swap: Decodable, Equatable, Sendable {
        let used: String?
        let total: String?

        enum CodingKeys: String, CodingKey {
            case used
            case total
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = try container.decodeIfPresent(String.self, forKey: .used)
            total = try container.decodeIfPresent(String.self, forKey: .total)
        }
    }

    struct DevSlots: Decodable, Equatable, Sendable {
        let used: Int?
        let cap: Int?

        enum CodingKeys: String, CodingKey {
            case used
            case cap
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = try container.decodeIfPresent(Int.self, forKey: .used)
            cap = try container.decodeIfPresent(Int.self, forKey: .cap)
        }
    }

    struct Multica: Decodable, Equatable, Sendable {
        let working: Int?
        let idle: Int?
        /// 在跑执行者名单（cortex 侧 agent list 取 name）；旧脚本没这键，给空。
        let workingNames: [String]
        /// 在跑执行者按机器归属拆账（键 pro/m1max/mini2/unknown），cortex 侧按
        /// 执行者名里的机器词分好；旧脚本没这键，给空。机器卡「在跑」用它对账。
        let workingByMachine: [String: [String]]
        /// 正在执行的**任务**总数（一个执行者可同时背多条，cortex 侧按 run 状态
        /// 数：running/dispatched/waiting_local_directory；queued 排队不算）。
        /// 旧脚本没这键，给 nil——顶部徽标据此隐藏，别拿 working 冒充。
        let tasksTotal: Int?
        /// 在飞任务按机器拆账（键 pro/m1max/mini2/unknown），严格等于 tasksTotal。
        /// 旧脚本没这键，给空。
        let tasksByMachine: [String: Int]
        /// 每执行者在飞任务数（hover 拆账用）；旧脚本没这键，给空。
        let tasksByAgent: [AgentTasks]

        struct AgentTasks: Decodable, Equatable, Sendable {
            let name: String
            let machine: String?
            let tasks: Int
            let items: [TaskItem]

            struct TaskItem: Decodable, Equatable, Sendable {
                let identifier: String
                let title: String
                let status: String
                let elapsedText: String
                let source: String

                enum CodingKeys: String, CodingKey {
                    case identifier, title, status, source
                    case elapsedText = "elapsed_text"
                }
            }

            enum CodingKeys: String, CodingKey {
                case name, machine, tasks, items
            }

            init(name: String, machine: String?, tasks: Int, items: [TaskItem] = []) {
                self.name = name
                self.machine = machine
                self.tasks = tasks
                self.items = items
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                machine = try container.decodeIfPresent(String.self, forKey: .machine)
                tasks = try container.decode(Int.self, forKey: .tasks)
                items = try container.decodeIfPresent([TaskItem].self, forKey: .items) ?? []
            }
        }

        enum CodingKeys: String, CodingKey {
            case working
            case idle
            case workingNames = "working_names"
            case workingByMachine = "working_by_machine"
            case tasksTotal = "tasks_total"
            case tasksByMachine = "tasks_by_machine"
            case tasksByAgent = "tasks_by_agent"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            working = try container.decodeIfPresent(Int.self, forKey: .working)
            idle = try container.decodeIfPresent(Int.self, forKey: .idle)
            workingNames = try container.decodeIfPresent([String].self, forKey: .workingNames) ?? []
            workingByMachine = try container.decodeIfPresent(
                [String: [String]].self, forKey: .workingByMachine
            ) ?? [:]
            tasksTotal = try container.decodeIfPresent(Int.self, forKey: .tasksTotal)
            tasksByMachine = try container.decodeIfPresent(
                [String: Int].self, forKey: .tasksByMachine
            ) ?? [:]
            tasksByAgent = try container.decodeIfPresent([AgentTasks].self, forKey: .tasksByAgent) ?? []
        }
    }
}

/// 面板显示状态（与预案同形状：最近一次成功 + 失败原因）。
struct CortexTelemetrySummaryDisplayState: Equatable, Sendable {
    let payload: CortexTelemetrySummaryPayload?
    let fetchedAt: Date?
    let failureText: String?
    let failureAt: Date?
}

enum CortexTelemetrySummaryOutcome: Equatable, Sendable {
    case success(CortexTelemetrySummaryPayload)
    case failure(reason: String)
}

// MARK: - 取数

enum CortexTelemetrySummaryConstants {
    /// KV 汇总的独立后台轮：各机哨兵 10 分钟写一轮 KV，拉得再勤也看不到新数据，
    /// 后台跟这个拍子对齐；开面板那轮仍跟 GLM 用量同一拍触发。
    static let automaticRefreshInterval: TimeInterval = 10 * 60
}

enum CortexTelemetrySummaryFetcher {
    struct Configuration: Sendable {
        var manifestPath: String = "scripts/sentry_telemetry.files"
        var scriptArguments: [String] = ["scripts/sentry_telemetry.py", "summary"]
        /// summary 会并发拉每个在跑执行者的 run 历史（10 分钟一轮后台跑），
        /// 实测整轮 20-60s，45s 的旧上限会把它掐成「这次没读到」。
        var scriptTimeout: TimeInterval = 240
        var export: CortexGitScriptExport.Configuration

        init(
            manifestPath: String = "scripts/sentry_telemetry.files",
            scriptArguments: [String] = ["scripts/sentry_telemetry.py", "summary"],
            scriptTimeout: TimeInterval = 240,
            cacheRoot: URL? = nil,
            export: CortexGitScriptExport.Configuration? = nil
        ) {
            self.manifestPath = manifestPath
            self.scriptArguments = scriptArguments
            self.scriptTimeout = scriptTimeout
            self.export = export ?? CortexGitScriptExport.Configuration(
                cacheRoot: cacheRoot ?? CortexGitScriptExport.defaultCacheRoot("telemetry-summary")
            )
        }
    }

    static func fetch(
        environment: [String: String],
        watchDirectory: URL?,
        fallbackRepositoryRoot: URL?,
        homeDirectory: String,
        configuration: Configuration = Configuration(),
        runner: any CortexSubprocessRunning,
        fileManager: FileManager = .default
    ) async -> CortexTelemetrySummaryOutcome {
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
            arguments: configuration.scriptArguments,
            workingDirectory: exported.cacheDirectory,
            environment: CortexGitScriptExport.scriptEnvironment(
                homeDirectory: homeDirectory,
                repoRoot: exported.repoRoot,
                logsDirectory: watchDirectory
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
        guard let payload = try? JSONDecoder().decode(CortexTelemetrySummaryPayload.self, from: run.standardOutput) else {
            return .failure(reason: "脚本输出解析不了")
        }
        guard payload.schema == 2 else {
            return .failure(reason: "脚本版本不认识")
        }
        return .success(payload)
    }
}

// MARK: - 显示规则（纯函数，便于测试）

enum CortexTelemetrySummaryDisplay {
    /// 面板行。每台两行：硬件一行、槽位线数一行；首行标题带 Multica 在跑数。
    static func rows(_ state: CortexTelemetrySummaryDisplayState?, now: Date) -> [String] {
        guard let state else {
            return []
        }
        if let failureText = state.failureText, !failureText.isEmpty {
            return ["三机总览：\(clockText(state.failureAt ?? now)) 这次没读到（\(failureText)）"]
        }
        guard let payload = state.payload else {
            return []
        }
        guard !payload.machines.isEmpty else {
            return ["三机总览：还没有机器上报（等各机哨兵 10 分钟一轮）"]
        }
        var lines: [String] = []
        // 顶部数改成「正在执行的任务」（一个执行者可背多条）；旧脚本没 tasks_total
        // 时退回 working 个数兜底显示。
        let running = payload.multica?.tasksTotal ?? payload.multica?.working
        let title = running.map { "三机总览（Multica 在跑 \($0)）" } ?? "三机总览"
        lines.append(title)
        for machine in payload.machines {
            lines.append(hardwareLine(of: machine))
            lines.append(slotLine(of: machine))
        }
        return lines
    }

    static func hardwareLine(of machine: CortexTelemetrySummaryPayload.Machine) -> String {
        let name = machineToken(of: machine)
        var parts: [String] = []
        if let cpu = machine.cpuPct {
            parts.append("CPU \(Int(cpu.rounded()))%")
        } else if let load = machine.load {
            parts.append("load \(String(format: "%.1f", load))")
        }
        if let used = machine.memUsedPct {
            // 新口径：占用百分比 + 内核压力等级（Falcon 09-18 令看得准）。
            parts.append("内存占 \(Int(used.rounded()))%")
            if let level = machine.pressureLevel {
                parts.append(level == 2 ? "压力警告" : (level >= 4 ? "压力危急" : "压力正常"))
            }
        } else if let free = machine.memFreePct {
            // 旧数据（升级前的 KV）只有空闲口径，先兜底显示。
            parts.append("内存余 \(Int(free))%")
        }
        if let swap = machine.swap, let used = swap.used {
            let total = swap.total.map { "/\($0)" } ?? ""
            parts.append("swap \(used)\(total)")
        }
        return "\(name) \(parts.joined(separator: " · "))"
    }

    static func slotLine(of machine: CortexTelemetrySummaryPayload.Machine) -> String {
        let name = machineToken(of: machine)
        var parts: [String] = []
        if let slots = machine.devSlots, let cap = slots.cap {
            parts.append("槽 \(slots.used ?? 0)/\(cap)")
        }
        if let byModel = machine.linesByModel, !byModel.isEmpty {
            let text = byModel
                .sorted { $0.value > $1.value }
                .map { key, count in count > 1 ? "\(shortModel(key))×\(count)" : shortModel(key) }
                .joined(separator: "·")
            parts.append("本机线 \(byModel.values.reduce(0, +))（\(text)）")
        } else {
            parts.append("本机线 0")
        }
        return "\(name) \(parts.joined(separator: " · "))"
    }

    /// 模型串短名（显示格式化，判据不动）。
    static func shortModel(_ model: String) -> String {
        if model.contains("BC-GLM") { return "CodeBuddy" }
        if model.contains("glm-5.3") { return "ZCode" }
        if model.contains("cursor-grok") { return model.contains("fast") ? "Grok Fast" : "Grok" }
        if model.contains("gpt-5") { return "Codex" }
        if model.contains("kimi") { return "Kimi" }
        if model.contains("deepseek") { return "DSH" }
        return model
    }

    static func machineToken(of machine: CortexTelemetrySummaryPayload.Machine) -> String {
        guard let raw = machine.machine, !raw.isEmpty else {
            return "?"
        }
        let lower = raw.lowercased()
        if lower.contains("mini") { return "mini2" }
        if lower.contains("m1max") || lower.contains("book-pro") { return "M1Max" }
        return "Pro"
    }

    static func clockText(_ date: Date) -> String {
        CortexPlanStatusDisplay.clockText(date)
    }
}

// MARK: - 局域网直连（Falcon 09-18 令：同网直连优先，Multica KV 兜底）

/// 给本机局域网 server 的 payload：跑 cortex collect 采样，再盖上本机哨兵版本
/// （CFBundleShortVersionString + CFBundleVersion）。三台的版本行就吃这把钥匙：
/// 各台哨兵报自己，别的台只管显示，读不到写「没读到」。
enum CortexLanCollect {
    static func data(
        environment: [String: String],
        watchDirectory: URL?,
        fallbackRepositoryRoot: URL?,
        homeDirectory: String,
        runner: any CortexSubprocessRunning,
        fileManager: FileManager = .default
    ) async -> Data? {
        let configuration = CortexTelemetrySummaryFetcher.Configuration()
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
        case .failed:
            return nil
        }
        let run = await runner.run(
            executablePath: exported.interpreterPath,
            arguments: ["scripts/sentry_telemetry.py", "collect"],
            workingDirectory: exported.cacheDirectory,
            environment: CortexGitScriptExport.scriptEnvironment(
                homeDirectory: homeDirectory,
                repoRoot: exported.repoRoot,
                logsDirectory: watchDirectory
            ),
            stdin: nil,
            timeout: 15
        )
        guard run.exitCode == 0, !run.standardOutput.isEmpty else {
            return nil
        }
        return injectingSentinelVersion(into: run.standardOutput)
    }

    /// 在 collect 采样 JSON 上盖本机哨兵版本两键。顶层不是对象（脚本换了形状）
    /// 就原样返回——宁可面板写「没读到」，不发半截数据。版本号读不到时按缺省盖，
    /// 与设置窗版本行同源（SentinelUpdateVersion.current / currentBuild）。
    static func injectingSentinelVersion(
        into data: Data,
        shortVersion: String = SentinelUpdateVersion.current,
        bundleVersion: String = SentinelUpdateVersion.currentBuild
    ) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return data
        }
        object["sentinel_version"] = shortVersion
        object["sentinel_build"] = bundleVersion
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
}

extension CortexTelemetrySummaryDisplay {
    /// LAN 直连数据优先覆盖同机器的 KV 条目；LAN-only 机器追加在尾部。
    static func mergedMachines(
        kvPayload: CortexTelemetrySummaryPayload?,
        lanMachines: [CortexTelemetrySummaryPayload.Machine]
    ) -> [CortexTelemetrySummaryPayload.Machine] {
        guard !lanMachines.isEmpty else {
            return kvPayload?.machines ?? []
        }
        func token(_ raw: String?) -> String {
            (raw ?? "").lowercased()
        }
        var lanByToken: [String: CortexTelemetrySummaryPayload.Machine] = [:]
        for machine in lanMachines {
            lanByToken[token(machine.machine)] = machine
        }
        var merged: [CortexTelemetrySummaryPayload.Machine] = []
        var consumed = Set<String>()
        for machine in kvPayload?.machines ?? [] {
            let key = token(machine.machine)
            if let fresh = lanByToken[key] {
                merged.append(fresh)
                consumed.insert(key)
            } else {
                merged.append(machine)
            }
        }
        for machine in lanMachines where !consumed.contains(token(machine.machine)) {
            merged.append(machine)
        }
        return merged
    }
}

// MARK: - 哨兵版本行（三台各自在跑的哨兵版本，Falcon 09-27 令）

extension CortexTelemetrySummaryDisplay {
    /// 面板一行「哨兵版本」：Pro / mini2 / M1Max 逐台列出。
    /// 正式版显示号（0.1.52），开发版显示「开发版」或「开发版 <哈希>」，
    /// 读不到的机器写「没读到」——不写 0、不猜。三台没全读到或读到的不一致
    /// → emphasized（面板标黄），落后于最新正式版的机器在行尾点名。
    /// 数据来源就是机器总览那条合并后的机器行，没有第二个数据源。
    static func sentinelVersionRow(
        _ machines: [CortexTelemetrySummaryPayload.Machine]
    ) -> (text: String, emphasized: Bool)? {
        guard !machines.isEmpty else {
            return nil
        }
        let tokens = ["Pro", "mini2", "M1Max"]
        var versionTexts: [String: String] = [:]
        for token in tokens {
            // 同一台可能 KV、LAN 各有一条：优先拿报了版本的那条。
            let rows = machines.filter { machineToken(of: $0) == token }
            if let reported = rows.first(where: { $0.sentinelVersion != nil }) {
                versionTexts[token] = sentinelVersionText(reported)
            }
        }
        let slots = tokens.map { token in
            "\(token) \(versionTexts[token] ?? "没读到")"
        }
        // 落后：报出来的机器里，文案能被更新的一台压过（开发版文案压不过正式版号，
        // 正式版号压得过开发版；两边都是不同哈希的开发版比不出，不点名只标黄）。
        let lagging = tokens.compactMap { token -> String? in
            guard let mine = versionTexts[token] else { return nil }
            let hasNewerPeer = tokens.contains { other in
                guard other != token, let theirs = versionTexts[other] else { return false }
                return versionTextIsNewer(theirs, than: mine)
            }
            return hasNewerPeer ? token : nil
        }
        let allRead = versionTexts.count == tokens.count
        let allSame = Set(versionTexts.values).count == 1
        let emphasized = !(allRead && allSame)
        var text = "哨兵版本 " + slots.joined(separator: " · ")
        if !lagging.isEmpty {
            text += "（\(lagging.joined(separator: "、")) 落后）"
        }
        return (text, emphasized)
    }

    /// 一台机器的版本文案：正式版给号，开发版给「开发版」（构建号是哈希时带短哈希）。
    /// 开发版判定与更新器共用 SentinelAppVersion.isDevelopmentBuild；「开发版」
    /// 三个字沿用设置窗的 versionDevLabel。
    static func sentinelVersionText(_ machine: CortexTelemetrySummaryPayload.Machine) -> String {
        let shortVersion = machine.sentinelVersion ?? ""
        let build = machine.sentinelBuild ?? ""
        if SentinelAppVersion.isDevelopmentBuild(shortVersion: shortVersion, bundleVersion: build) {
            if build == SentinelAppVersion.devBundleVersion || build.isEmpty {
                return SentinelSettingsCopy.versionDevLabel
            }
            return "\(SentinelSettingsCopy.versionDevLabel) \(SentinelAppVersion.shortenedGitHash(build))"
        }
        return shortVersion
    }

    /// 两条版本文案比新旧：同文案不算；都能解析号走严格比大小；只有一边能解析
    /// 就是正式版更新（另一边是开发版文案）；两边都解析不了比不出，不算。
    static func versionTextIsNewer(_ candidate: String, than current: String) -> Bool {
        if candidate == current {
            return false
        }
        if SentinelUpdateVersion.parse(candidate) != nil,
           SentinelUpdateVersion.parse(current) != nil {
            return SentinelUpdateVersion.isNewer(candidate, than: current)
        }
        return SentinelUpdateVersion.parse(candidate) != nil
    }
}
