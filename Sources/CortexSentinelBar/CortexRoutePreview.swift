import Foundation

// MARK: - 派工路由预案（判据唯一来源是 cortex 仓路由表，本仓只显示）

/// cortex 仓 `scripts/dispatch_route_preview.py --json` 的输出模型。
/// 此刻谁优先、窗内窗外怎么翻，判据全在 cortex 侧单源路由表，Swift 只解码显示。
struct CortexRoutePreviewPayload: Decodable, Equatable, Sendable {
    let schema: Int
    let generatedAtText: String?
    let freeWindow: FreeWindow?
    let lanes: [Lane]

    enum CodingKeys: String, CodingKey {
        case schema
        case generated_at
        case free_window
        case lanes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        generatedAtText = try container.decodeIfPresent(String.self, forKey: .generated_at)
        freeWindow = try container.decodeIfPresent(FreeWindow.self, forKey: .free_window)
        lanes = try container.decodeIfPresent([Lane].self, forKey: .lanes) ?? []
    }

    struct FreeWindow: Decodable, Equatable, Sendable {
        let active: Bool
        let beijingTime: String?
        let window: String?

        enum CodingKeys: String, CodingKey {
            case active
            case beijingTime = "beijing_time"
            case window
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
            beijingTime = try container.decodeIfPresent(String.self, forKey: .beijingTime)
            window = try container.decodeIfPresent(String.self, forKey: .window)
        }
    }

    struct Lane: Decodable, Equatable, Sendable {
        let label: String?
        /// 单出口车道（frontend）用 line；分支出车道（代码）用 branches。
        let line: String?
        let branches: [Branch]?

        enum CodingKeys: String, CodingKey {
            case label
            case line
            case branches
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            line = try container.decodeIfPresent(String.self, forKey: .line)
            branches = try container.decodeIfPresent([Branch].self, forKey: .branches)
        }

        struct Branch: Decodable, Equatable, Sendable {
            let condition: String?
            let line: String?
            let order: [String]?
            let note: String?
            /// v2：本分支当前可派的候选（花名册 + 额度算好，哨兵只显示）。
            let candidates: [Candidate]?

            enum CodingKeys: String, CodingKey {
                case condition
                case line
                case order
                case note
                case candidates
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                condition = try container.decodeIfPresent(String.self, forKey: .condition)
                line = try container.decodeIfPresent(String.self, forKey: .line)
                order = try container.decodeIfPresent([String].self, forKey: .order)
                note = try container.decodeIfPresent(String.self, forKey: .note)
                candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates)
            }

            struct Candidate: Decodable, Equatable, Sendable {
                let name: String?
                let state: String?
                let basis: String?

                enum CodingKeys: String, CodingKey {
                    case name
                    case state
                    case basis
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    name = try container.decodeIfPresent(String.self, forKey: .name)
                    state = try container.decodeIfPresent(String.self, forKey: .state)
                    basis = try container.decodeIfPresent(String.self, forKey: .basis)
                }
            }
        }
    }
}

/// 面板显示状态：最近一次成功结果 + 失败原因（与套餐 / 派工路由状态行同一形状）。
struct CortexRoutePreviewDisplayState: Equatable, Sendable {
    let payload: CortexRoutePreviewPayload?
    let fetchedAt: Date?
    let failureText: String?
    let failureAt: Date?
}

enum CortexRoutePreviewOutcome: Equatable, Sendable {
    case success(CortexRoutePreviewPayload)
    case failure(reason: String)
}

// MARK: - 取数（与派工路由状态行共用导出核心，只换清单与脚本参数）

enum CortexRoutePreviewFetcher {
    struct Configuration: Sendable {
        var manifestPath: String = "scripts/dispatch_route_preview.files"
        var scriptArguments: [String] = ["scripts/dispatch_route_preview.py", "--json"]
        var scriptTimeout: TimeInterval = 30
        var export: CortexGitScriptExport.Configuration

        init(
            manifestPath: String = "scripts/dispatch_route_preview.files",
            scriptArguments: [String] = ["scripts/dispatch_route_preview.py", "--json"],
            scriptTimeout: TimeInterval = 30,
            cacheRoot: URL? = nil,
            export: CortexGitScriptExport.Configuration? = nil
        ) {
            self.manifestPath = manifestPath
            self.scriptArguments = scriptArguments
            self.scriptTimeout = scriptTimeout
            self.export = export ?? CortexGitScriptExport.Configuration(
                cacheRoot: cacheRoot ?? CortexGitScriptExport.defaultCacheRoot("route-preview")
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
    ) async -> CortexRoutePreviewOutcome {
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
        guard let payload = try? JSONDecoder().decode(CortexRoutePreviewPayload.self, from: run.standardOutput) else {
            return .failure(reason: "脚本输出解析不了")
        }
        guard payload.schema == 1 || payload.schema == 2 else {
            return .failure(reason: "脚本版本不认识")
        }
        return .success(payload)
    }
}

// MARK: - 显示规则（纯函数，便于测试）

enum CortexRoutePreviewDisplay {
    /// 面板行：每行一条出口，读不到给失败行。行数恒 ≤4，超小屏也不挤。
    static func rows(_ state: CortexRoutePreviewDisplayState?, now: Date) -> [String] {
        guard let state else {
            return []
        }
        if let failureText = state.failureText, !failureText.isEmpty {
            return ["派工预案：\(clockText(state.failureAt ?? now)) 这次没读到（\(failureText)）"]
        }
        guard let payload = state.payload else {
            return []
        }
        var lines: [String] = []
        let freeActive = payload.freeWindow?.active ?? false
        let clock = payload.freeWindow?.beijingTime ?? clockText(state.fetchedAt ?? now)
        for lane in payload.lanes {
            if let line = lane.line {
                lines.append("\(lane.label ?? laneTitle(lane)) → \(line)")
                continue
            }
            for branch in lane.branches ?? [] {
                if let line = branch.line {
                    lines.append("\(lane.label ?? "") · \(branch.condition ?? "") → \(line)")
                } else if let candidates = branch.candidates, !candidates.isEmpty {
                    // v2 多候选：短名 + 同名聚合（×N），paused 组聚合放尾部；basis 不上屏。
                    let available = candidates.filter { $0.state != "paused" }
                    let paused = candidates.filter { $0.state == "paused" }
                    var names = aggregatedNames(available.map { $0.name })
                    if paused.count == 1 {
                        names += aggregatedNames(paused.map { $0.name }).map { "\($0)（暂停）" }
                    } else if paused.count > 1 {
                        let token = shortName(paused.first?.name)
                        names.append("\(token) ×\(paused.count)（暂停）")
                    }
                    let joined = names.joined(separator: " · ")
                    let note = paused.isEmpty ? branch.note.map { "（\($0)）" } ?? "" : ""
                    lines.append("\(lane.label ?? "") · \(branch.condition ?? "") → \(joined)\(note)")
                } else if let order = branch.order, !order.isEmpty {
                    // 单出口不带说明（一条没有「顺序」语义），多条才附窗态说明，行更直观。
                    let joined = order.joined(separator: " → ")
                    let note = order.count > 1 ? branch.note.map { "（\($0)）" } ?? "" : ""
                    lines.append("\(lane.label ?? "") · \(branch.condition ?? "") → \(joined)\(note)")
                }
            }
        }
        if lines.isEmpty {
            return ["派工预案：\(clock) 这次没读到（脚本没给出口）"]
        }
        let windowMark = freeActive ? "免费窗中" : "窗外"
        return ["派工预案（北京 \(clock) · \(windowMark)）"] + lines
    }

    private static func laneTitle(_ lane: CortexRoutePreviewPayload.Lane) -> String {
        "车道"
    }

    /// 同名短名聚合成「名 ×N」；只有一个就原样。
    static func aggregatedNames(_ rawNames: [String?]) -> [String] {
        let shorts = rawNames.map { shortName($0) }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for name in shorts {
            counts[name, default: 0] += 1
            if counts[name] == 1 {
                order.append(name)
            }
        }
        return order.map { (counts[$0] ?? 1) > 1 ? "\($0) ×\(counts[$0]!)" : $0 }
    }

    /// 花名册全名剥成面板短名：「Pro 执行者(CodeBuddy BCGLM5.3 Flash Max)」→
    /// CodeBuddy；「M1Max 执行者(ZCode GLM Flash·Falcon 套餐)」→ ZCode(Falcon)；
    /// 「Pro Grok xhigh 执行者(Cursor)」→ Grok(Cursor)。显示层格式化，判据不动。
    static func shortName(_ raw: String?) -> String {
        guard var name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return "?"
        }
        var rolePrefix = ""
        var machineToken = ""
        for prefix in ["Pro Grok xhigh Fast ", "Pro Grok xhigh ", "M1Max Grok ", "mini Grok ", "Pro ", "M1Max ", "mini ", "ryan 机 "] {
            if name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                rolePrefix = prefix.trimmingCharacters(in: .whitespaces)
                let first = prefix.split(separator: " ").first.map(String.init) ?? ""
                machineToken = first == "Pro" ? "" : first
                break
            }
        }
        if name.hasPrefix("执行者") {
            name = String(name.dropFirst("执行者".count))
        }
        if let open = name.firstIndex(of: "("), name.hasSuffix(")") {
            let inner = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
            let parts = inner.components(separatedBy: "·")
            var engine = parts[0].split(separator: " ").first.map(String.init) ?? inner
            // 机器/角色前缀里的引擎词要保留（Grok xhigh 剥成 Cursor 就丢了是谁）。
            if !rolePrefix.isEmpty, rolePrefix.contains("Grok") {
                engine = rolePrefix.contains("Fast") ? "Grok Fast" : "Grok"
            }
            if parts.count > 1 {
                let plan = parts[1].replacingOccurrences(of: "套餐", with: "").trimmingCharacters(in: .whitespaces)
                return plan.isEmpty ? engine : "\(engine)(\(plan))"
            }
            // 无套餐后缀的同引擎多台（M1Max 的 ZCode）：用机器 token 区分，Pro 本机裸名。
            if !machineToken.isEmpty {
                return "\(engine)(\(machineToken))"
            }
            return engine
        }
        return name
    }

    static func clockText(_ date: Date) -> String {
        CortexPlanStatusDisplay.clockText(date)
    }

    // MARK: 图形化卡片模型（视图直接画卡与胶囊，不再拼长句）

    struct RouteChip: Equatable, Sendable {
        let text: String
        let paused: Bool
    }

    struct RouteCard: Equatable, Sendable {
        let title: String
        let target: String
        let note: String?
        /// 一般票候选胶囊；单出口卡片为空。
        let chips: [RouteChip]
        let windowActive: Bool
        /// 按机器分组的候选（机器 token 从花名册名剥出，动态不写死）。
        let machineGroups: [MachineGroup]

        init(
            title: String,
            target: String,
            note: String? = nil,
            chips: [RouteChip] = [],
            windowActive: Bool,
            machineGroups: [MachineGroup] = []
        ) {
            self.title = title
            self.target = target
            self.note = note
            self.chips = chips
            self.windowActive = windowActive
            self.machineGroups = machineGroups
        }

        struct MachineGroup: Equatable, Sendable {
            let machine: String
            let chips: [RouteChip]
        }
    }

    /// 候选按机器分组：机器 token 从花名册名前缀动态剥出（Pro/M1Max/mini/ryan 机…），
    /// 名单里加新机器自动多一组，不写死（Falcon 09-18 令）。
    static func machineGroups(of candidates: [CortexRoutePreviewPayload.Lane.Branch.Candidate]) -> [RouteCard.MachineGroup] {
        var order: [String] = []
        var byMachine: [String: [RouteChip]] = [:]
        for candidate in candidates {
            let machine = machineTokenOfName(candidate.name)
            if byMachine[machine] == nil {
                order.append(machine)
            }
            byMachine[machine, default: []].append(
                RouteChip(
                    text: shortName(candidate.name),
                    paused: candidate.state == "paused"
                )
            )
        }
        return order.map { RouteCard.MachineGroup(machine: $0, chips: byMachine[$0] ?? []) }
    }

    /// 花名册名 → 机器 token（与显示短名同一剥法，保留机器词）。
    static func machineTokenOfName(_ raw: String?) -> String {
        guard let name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return "其他"
        }
        // 归一到机器 token（Pro / M1Max / mini / ryan），与模型车道无关——
        // 「Pro Grok xhigh」「mini Grok」这类角色短语都归到各自机器。
        for (prefix, token) in [("Pro", "Pro"), ("M1Max", "M1Max"), ("mini", "mini"), ("ryan 机", "ryan")] {
            if name.hasPrefix(prefix) {
                return token
            }
        }
        return "其他"
    }

    /// 两张固定小卡（前端 / 高难）+ 一张候选胶囊卡（一般票）。解析失败给 nil。
    static func cards(_ payload: CortexRoutePreviewPayload?) -> [RouteCard] {
        guard let payload else {
            return []
        }
        let freeActive = payload.freeWindow?.active ?? false
        var cards: [RouteCard] = []
        for lane in payload.lanes {
            if let line = lane.line {
                cards.append(RouteCard(title: lane.label ?? "车道", target: line, note: nil, chips: [], windowActive: freeActive))
                continue
            }
            for branch in lane.branches ?? [] {
                if let line = branch.line {
                    cards.append(RouteCard(
                        title: "\(lane.label ?? "") · \(branch.condition ?? "")",
                        target: line,
                        note: nil,
                        chips: [],
                        windowActive: freeActive
                    ))
                } else if let candidates = branch.candidates, !candidates.isEmpty {
                    let chips = candidates.map { candidate in
                        RouteChip(
                            text: shortName(candidate.name),
                            paused: candidate.state == "paused"
                        )
                    }
                    cards.append(RouteCard(
                        title: "\(lane.label ?? "") · \(branch.condition ?? "")",
                        target: "",
                        note: branch.note,
                        chips: chips,
                        windowActive: freeActive,
                        machineGroups: machineGroups(of: candidates)
                    ))
                }
            }
        }
        return cards
    }
}
