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
                /// 执行者完整 UUID（COR-9242 起带）：点灰/恢复要拿它调
                /// executor_availability pause/resume --board-only；旧输出没有。
                let executorID: String?
                /// 拦截原因码（与 dispatch_executor_guard 的 BLOCK_* 闭集同名）；
                /// nil = 按派工器同一份判定当前可派。
                let blockedCode: String?
                /// 拦截原因一句话，cortex 侧判定原语给的原样。
                let blockedText: String?

                enum CodingKeys: String, CodingKey {
                    case name
                    case state
                    case basis
                    case executorID = "executor_id"
                    case blockedCode = "blocked_code"
                    case blockedText = "blocked_text"
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    name = try container.decodeIfPresent(String.self, forKey: .name)
                    state = try container.decodeIfPresent(String.self, forKey: .state)
                    basis = try container.decodeIfPresent(String.self, forKey: .basis)
                    executorID = try container.decodeIfPresent(String.self, forKey: .executorID)
                    blockedCode = try container.decodeIfPresent(String.self, forKey: .blockedCode)
                    blockedText = try container.decodeIfPresent(String.self, forKey: .blockedText)
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
        /// 花名册状态原文（state=paused 只是灰的其中一种原因）。
        let paused: Bool
        /// 执行者完整 UUID（payload v2 起带；没有 = 点不动，只提示刷新）。
        let executorID: String?
        /// 拦截原因码；nil = 按派工器同一份判定当前可派（绿）。
        let blockedCode: String?
        /// 拦截原因一句话。
        let blockedText: String?

        init(
            text: String,
            paused: Bool,
            executorID: String? = nil,
            blockedCode: String? = nil,
            blockedText: String? = nil
        ) {
            self.text = text
            self.paused = paused
            self.executorID = executorID
            self.blockedCode = blockedCode
            self.blockedText = blockedText
        }

        /// 灰不灰：预案的 blocked_code（与派工器同一份判定——清单 paused、说明/名字
        /// 停派标记、ai_hold、被拒冷却都算）或花名册 paused 任一命中。旧输出连
        /// blocked_code 都没有时退回花名册状态，行为不变。
        var isBlocked: Bool {
            blockedCode != nil || paused
        }
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
                    paused: candidate.state == "paused",
                    executorID: candidate.executorID,
                    blockedCode: candidate.blockedCode,
                    blockedText: candidate.blockedText
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
                            paused: candidate.state == "paused",
                            executorID: candidate.executorID,
                            blockedCode: candidate.blockedCode,
                            blockedText: candidate.blockedText
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

    // MARK: 点胶囊的处置（COR-9242 哨兵点灰）

    /// 点执行者胶囊该做什么：绿点停派、自己点灰的灰点恢复、别的原因只显示。
    enum DispatchDotAction: Equatable, Sendable {
        /// 绿点（当前可派）：调 executor_availability pause --board-only。
        case pauseBoardOnly(executorID: String)
        /// 灰点且灰因只是「他在哨兵上点灰」标记：调 resume --board-only 变回绿。
        case resumeBoardOnly(executorID: String)
        /// 别的原因的灰点（或预案太旧没有 id）：只把原因显示出来，不动。
        case information(String)
    }

    /// 点了给什么：纯判定，视图与 store 共用。
    /// 「他在哨兵上点灰」这半句是 cortex 仓 executor_availability.py
    /// BOARD_ONLY_MARKER_PREFIX 的固定前缀（跨仓字面契约，两边改要同一个票改）；
    /// resume --board-only 只删这一类行，别的停派标记它本来就不动，所以灰因
    /// 不是它就绝不发恢复命令。
    static func action(for chip: RouteChip) -> DispatchDotAction {
        if !chip.isBlocked {
            guard let id = chip.executorID, !id.isEmpty else {
                return .information("预案还没带上执行者 id，等下一轮刷新再点")
            }
            return .pauseBoardOnly(executorID: id)
        }
        let ownMarker = chip.blockedCode == "description_stop_phrase"
            && (chip.blockedText?.contains("他在哨兵上点灰") ?? false)
        if ownMarker {
            guard let id = chip.executorID, !id.isEmpty else {
                return .information("预案还没带上执行者 id，等下一轮刷新再点")
            }
            return .resumeBoardOnly(executorID: id)
        }
        return .information(chip.blockedText ?? "当前不可派（预案没给原因）")
    }
}
