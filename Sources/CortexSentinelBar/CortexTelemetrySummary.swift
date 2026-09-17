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

        enum CodingKeys: String, CodingKey {
            case working
            case idle
            case workingNames = "working_names"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            working = try container.decodeIfPresent(Int.self, forKey: .working)
            idle = try container.decodeIfPresent(Int.self, forKey: .idle)
            workingNames = try container.decodeIfPresent([String].self, forKey: .workingNames) ?? []
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

enum CortexTelemetrySummaryFetcher {
    struct Configuration: Sendable {
        var manifestPath: String = "scripts/sentry_telemetry.files"
        var scriptArguments: [String] = ["scripts/sentry_telemetry.py", "summary"]
        var scriptTimeout: TimeInterval = 45
        var export: CortexGitScriptExport.Configuration

        init(
            manifestPath: String = "scripts/sentry_telemetry.files",
            scriptArguments: [String] = ["scripts/sentry_telemetry.py", "summary"],
            scriptTimeout: TimeInterval = 45,
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
        let working = payload.multica?.working
        let title = working.map { "三机总览（Multica 在跑 \($0)）" } ?? "三机总览"
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

/// 给本机局域网 server 的 payload：跑 cortex collect 纯采样。
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
        return run.standardOutput
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
