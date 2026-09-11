import AppKit
import CryptoKit
import Foundation
import SwiftUI

// MARK: - cortex 派工套餐状态（派工判据的唯一来源是 cortex 仓，本仓只显示）

/// cortex 仓 `scripts/glm_plan_status.py --json` 的输出模型。
/// 套餐名、钥匙指纹、在跑数、能不能派全在 cortex 侧算好，Swift 只解码和显示，
/// 不在公开仓里再写一遍判据。schema 不是 1 整份当没有。
struct CortexPlanStatusPayload: Decodable, Equatable, Sendable {
    let schema: Int
    /// UTC ISO 时刻文本；解析失败只影响内部判断，不进界面。
    let generatedAtText: String?
    let freeWindow: FreeWindow?
    let plans: [CortexPlanStatusPlan]
    let errors: [Notice]

    enum CodingKeys: String, CodingKey {
        case schema
        case generated_at
        case free_window
        case plans
        case errors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        generatedAtText = try container.decodeIfPresent(String.self, forKey: .generated_at)
        freeWindow = try container.decodeIfPresent(FreeWindow.self, forKey: .free_window)
        plans = try container.decodeIfPresent([CortexPlanStatusPlan].self, forKey: .plans) ?? []
        errors = try container.decodeIfPresent([Notice].self, forKey: .errors) ?? []
    }

    var generatedAt: Date? {
        generatedAtText.flatMap(CortexPlanStatusDate.parse)
    }

    struct FreeWindow: Decodable, Equatable, Sendable {
        let active: Bool?
        let start: String?
        let end: String?
        let textZH: String?

        enum CodingKeys: String, CodingKey {
            case active
            case start
            case end
            case text_zh
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            active = try container.decodeIfPresent(Bool.self, forKey: .active)
            start = try container.decodeIfPresent(String.self, forKey: .start)
            end = try container.decodeIfPresent(String.self, forKey: .end)
            textZH = try container.decodeIfPresent(String.self, forKey: .text_zh)
        }
    }

    struct Notice: Decodable, Equatable, Sendable {
        let code: String?
        let textZH: String?

        enum CodingKeys: String, CodingKey {
            case code
            case text_zh
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decodeIfPresent(String.self, forKey: .code)
            textZH = try container.decodeIfPresent(String.self, forKey: .text_zh)
        }
    }
}

struct CortexPlanStatusPlan: Decodable, Equatable, Sendable {
    let id: String
    let label: String
    let keySHA12: String
    let maxParallel: Int?
    /// 读不到看板时是 nil（此时派工判据也是 nil）。
    let running: Int?
    let executors: [Executor]
    let dispatchable: Bool?
    let skipCode: String?
    let skipTextZH: String?
    /// UTC ISO 时刻或 nil。
    let cooldownUntilText: String?
    let usageKnown: Bool?

    var cooldownUntil: Date? {
        cooldownUntilText.flatMap(CortexPlanStatusDate.parse)
    }

    /// 冷却到点以后不算冷却中。
    func isCoolingDown(now: Date) -> Bool {
        cooldownUntil.map { $0 > now } ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case key_sha12
        case max_parallel
        case running
        case executors
        case dispatchable
        case skip_code
        case skip_text_zh
        case cooldown_until
        case usage_known
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        keySHA12 = try container.decodeIfPresent(String.self, forKey: .key_sha12) ?? ""
        maxParallel = try container.decodeIfPresent(Int.self, forKey: .max_parallel)
        running = try container.decodeIfPresent(Int.self, forKey: .running)
        executors = try container.decodeIfPresent([Executor].self, forKey: .executors) ?? []
        dispatchable = try container.decodeIfPresent(Bool.self, forKey: .dispatchable)
        skipCode = try container.decodeIfPresent(String.self, forKey: .skip_code)
        skipTextZH = try container.decodeIfPresent(String.self, forKey: .skip_text_zh)
        cooldownUntilText = try container.decodeIfPresent(String.self, forKey: .cooldown_until)
        usageKnown = try container.decodeIfPresent(Bool.self, forKey: .usage_known)
    }

    struct Executor: Decodable, Equatable, Sendable {
        let name: String
        let running: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case running
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            running = try container.decodeIfPresent(Int.self, forKey: .running)
        }
    }
}

/// UTC ISO 时刻解析：容忍 Z 结尾和 +00:00 结尾、有无小数秒。
enum CortexPlanStatusDate {
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let normalized = trimmed.hasSuffix("Z")
            ? String(trimmed.dropLast()) + "+00:00"
            : trimmed
        for formatter in Self.formatters {
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
    }

    private static let formatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plain.timeZone = TimeZone(identifier: "UTC")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(identifier: "UTC")
        return [plain, fractional]
    }()
}

/// 面板行的套餐显示状态：最新一次成功的结果 + 失败时的人话原因。
struct CortexPlanStatusDisplayState: Equatable, Sendable {
    let payload: CortexPlanStatusPayload?
    let fetchedAt: Date?
    let failureText: String?
}

enum CortexPlanStatusOutcome: Equatable, Sendable {
    case success(CortexPlanStatusPayload)
    case failure(reason: String)
}

// MARK: - 取数

/// 子进程统一入口：哨兵只对 cortex 仓跑四种只读 git 命令，其余命令只对
/// 自己导出的缓存目录和自己的解释器，测试靠注入假执行器断言这一点。
protocol CortexSubprocessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        stdin: Data?,
        timeout: TimeInterval
    ) async -> CortexSubprocessResult
}

struct CortexSubprocessResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
    let timedOut: Bool
}

/// 真正拉子进程。超时只 terminate 自己起的这一个子进程。
struct CortexProcessSubprocessRunner: CortexSubprocessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        stdin: Data?,
        timeout: TimeInterval
    ) async -> CortexSubprocessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let output = Pipe()
            let errorPipe = Pipe()
            let input = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            process.environment = environment
            process.standardOutput = output
            process.standardError = errorPipe
            process.standardInput = input

            let state = TimeoutState()
            let timeoutItem = DispatchWorkItem {
                if state.markTimedOut() {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            process.terminationHandler = { finished in
                timeoutItem.cancel()
                let timedOut = state.consumeTimedOut()
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = errorPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: CortexSubprocessResult(
                    exitCode: finished.terminationStatus,
                    standardOutput: out,
                    standardError: err,
                    timedOut: timedOut
                ))
            }
            do {
                try process.run()
                if let stdin {
                    input.fileHandleForWriting.write(stdin)
                }
                input.fileHandleForWriting.closeFile()
            } catch {
                timeoutItem.cancel()
                state.markFinished()
                continuation.resume(returning: CortexSubprocessResult(
                    exitCode: -1,
                    standardOutput: Data(),
                    standardError: Data(error.localizedDescription.utf8),
                    timedOut: false
                ))
            }
        }
    }

    /// 超时旗标：超时回调和退出回调并发，加锁读写。
    private final class TimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false
        private var finished = false

        func markTimedOut() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished {
                return false
            }
            timedOut = true
            return true
        }

        func markFinished() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        func consumeTimedOut() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            finished = true
            return timedOut
        }
    }
}

/// 从 cortex 仓 origin/main 取套餐状态脚本并跑一轮。
/// 对仓只跑只读四命令（rev-parse / show / ls-tree / archive），不 fetch、
/// 不 checkout、不往那个仓写任何东西；脚本按 blob 哈希缓存在本 App 的
/// Caches 子目录，没变就不重写盘（思路同 cortex 自己的 land_pr.sh 取
/// origin/main，多一层按内容寻址的缓存）。
enum CortexPlanStatusFetcher {
    struct Configuration: Sendable {
        var gitExecutablePath: String = "/usr/bin/git"
        var tarExecutablePath: String = "/usr/bin/tar"
        var ref: String = "origin/main"
        var manifestPath: String = "scripts/glm_plan_status.files"
        var scriptTimeout: TimeInterval = 30
        var gitTimeout: TimeInterval = 15
        var cacheRoot: URL?
        var maxCacheCopies: Int = 2
        /// 解释器按顺序取第一个存在的；测试注入假路径。
        var interpreterCandidates: @Sendable (URL) -> [String] = { repoRoot in
            [
                repoRoot.appendingPathComponent(".venv/bin/python3").path,
                "/opt/homebrew/bin/python3",
                "/usr/bin/python3",
            ]
        }
    }

    /// 缓存根：用户 Caches 下本 App 自己的子目录。
    static func defaultCacheRoot(fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("CortexSentinel/plan-status", isDirectory: true)
    }

    /// 脚本进程只给 HOME 和一条固定 PATH，不吃哨兵进程的整个环境。
    static func scriptEnvironment(homeDirectory: String) -> [String: String] {
        [
            "HOME": homeDirectory,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(homeDirectory)/.local/bin:/opt/homebrew/bin",
        ]
    }

    /// 认仓候选（按顺序）：环境变量 CORTEX_REPO_ROOT、监视目录解析软链后的上一级、
    /// 装机版 WatchDirectoryResolution 给的 repositoryRoot（软链没解析，往往不是
    /// git 仓，只当兜底）。
    static func repositoryRootCandidates(
        environment: [String: String],
        watchDirectory: URL?,
        fallbackRepositoryRoot: URL?
    ) -> [URL] {
        var candidates: [URL] = []
        if let configured = environment["CORTEX_REPO_ROOT"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        if let watchDirectory {
            candidates.append(watchDirectory.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let fallbackRepositoryRoot {
            candidates.append(fallbackRepositoryRoot)
        }
        return candidates
    }

    static func fetch(
        environment: [String: String],
        watchDirectory: URL?,
        fallbackRepositoryRoot: URL?,
        homeDirectory: String,
        usageJSON: Data,
        configuration: Configuration = Configuration(),
        runner: any CortexSubprocessRunning,
        fileManager: FileManager = .default
    ) async -> CortexPlanStatusOutcome {
        // 1. 认仓：第一个能跑通 rev-parse 的候选。
        var repoRoot: URL?
        for candidate in repositoryRootCandidates(
            environment: environment,
            watchDirectory: watchDirectory,
            fallbackRepositoryRoot: fallbackRepositoryRoot
        ) {
            let probe = await runner.run(
                executablePath: configuration.gitExecutablePath,
                arguments: ["-C", candidate.path, "rev-parse", "--show-toplevel"],
                workingDirectory: nil,
                environment: nil,
                stdin: nil,
                timeout: configuration.gitTimeout
            )
            if probe.exitCode == 0,
               let line = String(data: probe.standardOutput, encoding: .utf8)?
                   .split(separator: "\n", omittingEmptySubsequences: true)
                   .first,
               fileManager.fileExists(atPath: String(line))
            {
                repoRoot = URL(fileURLWithPath: String(line), isDirectory: true)
                break
            }
        }
        guard let repoRoot else {
            return .failure(reason: "没读到派工状态：找不到 cortex 仓")
        }

        // 2. 清单：跳过 # 行和空行；每条必须是 scripts/ 下、不含 .. 的相对路径，
        //    一条不合法整份当没有。
        let manifest = await runner.run(
            executablePath: configuration.gitExecutablePath,
            arguments: ["-C", repoRoot.path, "show", "\(configuration.ref):\(configuration.manifestPath)"],
            workingDirectory: nil,
            environment: nil,
            stdin: nil,
            timeout: configuration.gitTimeout
        )
        guard manifest.exitCode == 0 else {
            return .failure(reason: "没读到派工状态：cortex 仓里还没有这个脚本")
        }
        guard let paths = manifestPaths(from: manifest.standardOutput) else {
            return .failure(reason: "没读到派工状态：脚本清单不合法")
        }

        // 3. 缓存键：ls-tree 整段输出的 sha256，脚本内容没变就不重导。
        let lsTree = await runner.run(
            executablePath: configuration.gitExecutablePath,
            arguments: ["-C", repoRoot.path, "ls-tree", configuration.ref, "--"] + paths,
            workingDirectory: nil,
            environment: nil,
            stdin: nil,
            timeout: configuration.gitTimeout
        )
        guard lsTree.exitCode == 0 else {
            return .failure(reason: "没读到派工状态：对不上脚本版本")
        }
        let cacheKey = sha256Hex(lsTree.standardOutput)
        let cacheRoot = configuration.cacheRoot ?? defaultCacheRoot(fileManager: fileManager)
        let cacheDirectory = cacheRoot.appendingPathComponent(cacheKey, isDirectory: true)

        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            // 先解到同级临时目录再改名，半截的目录不许留成缓存。
            let stagingDirectory = cacheRoot.appendingPathComponent(
                ".tmp-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            } catch {
                return .failure(reason: "没读到派工状态：缓存目录建不了")
            }
            let archive = await runner.run(
                executablePath: configuration.gitExecutablePath,
                arguments: ["-C", repoRoot.path, "archive", "--format=tar", configuration.ref, "--"] + paths,
                workingDirectory: nil,
                environment: nil,
                stdin: nil,
                timeout: configuration.gitTimeout
            )
            var extractionSucceeded = false
            if archive.exitCode == 0 {
                let extraction = await runner.run(
                    executablePath: configuration.tarExecutablePath,
                    arguments: ["-x", "-C", stagingDirectory.path],
                    workingDirectory: nil,
                    environment: nil,
                    stdin: archive.standardOutput,
                    timeout: configuration.gitTimeout
                )
                if extraction.exitCode == 0 {
                    do {
                        if fileManager.fileExists(atPath: cacheDirectory.path) {
                            // 并发轮已经先放好了同一份，丢掉自己这份。
                            try fileManager.removeItem(at: stagingDirectory)
                            extractionSucceeded = true
                        } else {
                            try fileManager.moveItem(at: stagingDirectory, to: cacheDirectory)
                            extractionSucceeded = true
                        }
                    } catch {
                        extractionSucceeded = false
                    }
                }
            }
            // 半截的临时目录一律清掉，成功与否都不留。
            try? fileManager.removeItem(at: stagingDirectory)
            guard extractionSucceeded else {
                return .failure(reason: "没读到派工状态：脚本导不出来")
            }
            pruneCache(at: cacheRoot, keeping: configuration.maxCacheCopies, fileManager: fileManager)
        }

        // 4. 解释器：仓里自带的 venv 优先，然后 Homebrew、系统。
        let interpreter = configuration.interpreterCandidates(repoRoot)
            .first { fileManager.fileExists(atPath: $0) }
        guard let interpreter else {
            return .failure(reason: "没读到派工状态：没找到可用的 Python")
        }

        // 5. 在缓存目录里跑脚本，stdin 喂 --glm-usage-json 同一份字节。
        let run = await runner.run(
            executablePath: interpreter,
            arguments: ["scripts/glm_plan_status.py", "--json"],
            workingDirectory: cacheDirectory,
            environment: scriptEnvironment(homeDirectory: homeDirectory),
            stdin: usageJSON,
            timeout: configuration.scriptTimeout
        )
        guard !run.timedOut else {
            return .failure(reason: "没读到派工状态：脚本跑超时了")
        }
        guard run.exitCode == 0 else {
            return .failure(reason: "没读到派工状态：脚本退出码 \(run.exitCode)")
        }

        // 6. 解码；schema 不是 1 整份当没有。
        guard let payload = try? JSONDecoder().decode(CortexPlanStatusPayload.self, from: run.standardOutput) else {
            return .failure(reason: "没读到派工状态：脚本输出解析不了")
        }
        guard payload.schema == 1 else {
            return .failure(reason: "没读到派工状态：脚本版本不认识")
        }
        return .success(payload)
    }

    /// 清单文本 → 相对路径列表。有一条不合法整份作废（返回 nil）。
    static func manifestPaths(from data: Data) -> [String]? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var paths: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard line.hasPrefix("scripts/"), !line.contains(".."), !line.hasPrefix("/") else {
                return nil
            }
            paths.append(line)
        }
        return paths.isEmpty ? nil : paths
    }

    /// 只留最新 N 份缓存目录，.tmp 半成品不参与。
    static func pruneCache(at cacheRoot: URL, keeping keep: Int, fileManager: FileManager) {
        guard keep > 0,
              let contents = try? fileManager.contentsOfDirectory(
                  at: cacheRoot,
                  includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else {
            return
        }
        let cacheDirectories = contents.filter { !$0.lastPathComponent.hasPrefix(".tmp-") }
        let sorted = cacheDirectories.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if leftDate == rightDate {
                return left.lastPathComponent > right.lastPathComponent
            }
            return leftDate > rightDate
        }
        for url in sorted.dropFirst(max(0, keep)) {
            try? fileManager.removeItem(at: url)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - 显示规则（纯函数，便于测试）

enum CortexPlanStatusDisplay {
    /// 钥匙指纹对上哪个套餐，这一行就是那个套餐的行。
    static func plan(forAccountKey key: String, in payload: CortexPlanStatusPayload?) -> CortexPlanStatusPlan? {
        guard let payload else {
            return nil
        }
        let sha = GLMUsageCLI.keySHA12(key)
        return payload.plans.first { $0.keySHA12 == sha }
    }

    /// 行名：用户改过名照旧用用户的（外层 providerDisplayName 管覆盖），
    /// 没改过用套餐 label，不加「GLM 」前缀；套餐缺失回原样。
    static func rowTitleFallback(
        plan: CortexPlanStatusPlan?,
        account: GLMAccountUsage
    ) -> String {
        guard let plan, !plan.label.trimmingCharacters(in: .whitespaces).isEmpty else {
            return account.displayTitle
        }
        return plan.label
    }

    /// 第三列（原现金那格）文案：冷却中写「冷却到 HH:MM」（本机时间，
    /// 宽 80 放不下就改写「冷却 HH:MM」，以不出图截断为准）；
    /// 不在冷却按在跑写；读不到看板写「在跑 —」。
    static func thirdColumnText(
        plan: CortexPlanStatusPlan,
        now: Date,
        columnWidth: CGFloat = 80
    ) -> String {
        if plan.isCoolingDown(now: now) {
            let time = clockText(plan.cooldownUntil ?? now)
            let long = "冷却到 \(time)"
            if measuredWidth(long) <= columnWidth {
                return long
            }
            return "冷却 \(time)"
        }
        guard let running = plan.running else {
            return "在跑 —"
        }
        let cap = plan.maxParallel.map(String.init) ?? "—"
        return "在跑 \(running)/\(cap)"
    }

    /// 第三列字号同款（Theme.Metrics 13 semibold monospaced）量宽，只挑文案不排版。
    private static func measuredWidth(_ text: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// 套餐行的状态点：只看订阅窗口和冷却，现金不参与（套餐派工不花现金）。
    /// 冷却中至少黄。非套餐行走原有 glmDotSignal，不由这里管。
    static func dotColor(
        plan: CortexPlanStatusPlan,
        account: GLMAccountUsage,
        now: Date
    ) -> Color {
        let base = SentinelBalancesSection.providerDotSignal(
            fiveHourRemaining: account.fiveHourWindow?.remainingPercentage,
            weeklyRemaining: account.weeklyWindow?.remainingPercentage,
            balanceAmount: nil,
            stale: account.stale,
            hasDisplayableNumber: account.hasDisplayableQuota
        )
        if plan.isCoolingDown(now: now), base == SentinelTheme.Colors.success {
            return SentinelTheme.Colors.warning
        }
        return base
    }

    /// 详情卡追加行：在跑 / 派工 / 免费时段 / 提示 / 现金余额 / 取数失败原因。
    /// 指纹、套餐 id、skip_code、错误 code 任何地方都不露。
    static func detailLines(
        plan: CortexPlanStatusPlan,
        payload: CortexPlanStatusPayload?,
        failureText: String?,
        cashBalance: Double?
    ) -> [BalanceHoverLine] {
        var lines: [BalanceHoverLine] = []
        let runningText = plan.running.map { "\($0) 条" } ?? "—"
        let capText = plan.maxParallel.map(String.init) ?? "—"
        lines.append(BalanceHoverLine(
            label: "在跑",
            value: "\(runningText) / 上限 \(capText)",
            note: nil
        ))
        for executor in plan.executors {
            lines.append(BalanceHoverLine(
                label: executor.name,
                value: executor.running.map { "\($0) 条" } ?? "—",
                note: nil
            ))
        }
        lines.append(BalanceHoverLine(
            label: "派工",
            value: plan.skipTextZH ?? "可以派",
            note: nil
        ))
        if let freeWindow = payload?.freeWindow, let text = freeWindow.textZH {
            lines.append(BalanceHoverLine(label: "免费时段", value: text, note: nil))
        }
        for error in payload?.errors ?? [] {
            if let text = error.textZH {
                lines.append(BalanceHoverLine(label: "提示", value: text, note: nil))
            }
        }
        if let cash = cashBalance {
            lines.append(BalanceHoverLine(
                label: "现金余额",
                value: String(format: "¥%.2f", cash),
                note: "套餐派工不花现金"
            ))
        }
        if let failureText {
            lines.append(BalanceHoverLine(label: "派工状态", value: failureText, note: nil))
        }
        return lines
    }

    /// 冷却时间用本机时间显示。
    static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
