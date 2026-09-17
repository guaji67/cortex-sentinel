import CryptoKit
import Foundation

// MARK: - cortex 判据脚本导出共用核心（套餐状态与派工路由两处同源）

/// 从 cortex 仓 origin/main 导出判据脚本并备好解释器的共用流程。
/// 同源说明：整段抽自 CortexPlanStatus.swift 的 CortexPlanStatusFetcher.fetch
/// 第 1-4 步（认仓 / 清单 / 内容寻址缓存 / 解释器）及其配套小函数，两处
/// 共用这一份，别再长出第二套导出逻辑。
/// 对仓只跑只读四命令（rev-parse / show / ls-tree / archive），不 fetch、
/// 不 checkout、不往那个仓写任何东西；脚本按清单 ls-tree 输出的 sha256
/// 缓存在本 App 的 Caches 子目录，没变就不重写盘。
enum CortexGitScriptExport {
    struct Configuration: Sendable {
        var gitExecutablePath: String = "/usr/bin/git"
        var tarExecutablePath: String = "/usr/bin/tar"
        var ref: String = "origin/main"
        var gitTimeout: TimeInterval = 15
        /// 缓存根，调用方各自给（套餐状态与派工路由各占一个子目录）。
        var cacheRoot: URL
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

    /// 导出结果：认出的仓根、脚本所在的缓存目录、选中的解释器。
    struct Exported: Sendable {
        let repoRoot: URL
        let cacheDirectory: URL
        let interpreterPath: String
    }

    /// 导出核心的结局：成功给 Exported，失败折成一句人话。
    enum Outcome: Sendable {
        case exported(Exported)
        case failed(reason: String)
    }

    /// 闸运行时根下的 repo 文件：装机时写进去的本机 cortex 检出位置（一行路径）。
    /// 根取环境变量 CORTEX_GATE_RUNTIME_BASE，没设就用家目录下的
    /// Library/Application Support/Cortex/GateRuntime。只读这一个文件，
    /// 不往闸运行时目录写任何东西。读第一行去首尾空白，空或读不到给 nil，
    /// 认仓流程就跳过这条候选。
    static func gateRuntimeRepoRoot(
        environment: [String: String],
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let runtimeBase: URL
        if let configured = environment["CORTEX_GATE_RUNTIME_BASE"], !configured.isEmpty {
            runtimeBase = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            runtimeBase = URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent("Library/Application Support/Cortex/GateRuntime", isDirectory: true)
        }
        let repoFile = runtimeBase.appendingPathComponent("repo", isDirectory: false)
        guard let data = fileManager.contents(atPath: repoFile.path),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !firstLine.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: firstLine, isDirectory: true)
    }

    /// 缓存根：用户 Caches 下本 App 自己的子目录（每个调用方一个子目录名）。
    static func defaultCacheRoot(_ subdirectory: String, fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("CortexSentinel/\(subdirectory)", isDirectory: true)
    }

    /// 跑完导出核心。失败一律折成一句人话，调用方原样上屏。
    static func run(
        manifestPath: String,
        configuration: Configuration,
        environment: [String: String],
        watchDirectory: URL?,
        fallbackRepositoryRoot: URL?,
        homeDirectory: String,
        runner: any CortexSubprocessRunning,
        fileManager: FileManager = .default
    ) async -> Outcome {
        // 1. 认仓：第一个能跑通 rev-parse 的候选。
        var repoRoot: URL?
        for candidate in repositoryRootCandidates(
            environment: environment,
            watchDirectory: watchDirectory,
            gateRuntimeRepoRoot: gateRuntimeRepoRoot(
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
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
            return .failed(reason: "找不到 cortex 仓")
        }

        // 2. 清单：跳过 # 行和空行；每条必须是 scripts/ 下、不含 .. 的相对路径，
        //    一条不合法整份当没有。
        let manifest = await runner.run(
            executablePath: configuration.gitExecutablePath,
            arguments: ["-C", repoRoot.path, "show", "\(configuration.ref):\(manifestPath)"],
            workingDirectory: nil,
            environment: nil,
            stdin: nil,
            timeout: configuration.gitTimeout
        )
        guard manifest.exitCode == 0 else {
            return .failed(reason: "cortex 仓里还没有这个脚本")
        }
        guard let paths = manifestPaths(from: manifest.standardOutput) else {
            return .failed(reason: "脚本清单不合法")
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
            return .failed(reason: "对不上脚本版本")
        }
        let cacheKey = sha256Hex(lsTree.standardOutput)
        let cacheDirectory = configuration.cacheRoot.appendingPathComponent(cacheKey, isDirectory: true)

        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            // 先解到同级临时目录再改名，半截的目录不许留成缓存。
            let stagingDirectory = configuration.cacheRoot.appendingPathComponent(
                ".tmp-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            } catch {
                return .failed(reason: "缓存目录建不了")
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
                return .failed(reason: "脚本导不出来")
            }
            pruneCache(at: configuration.cacheRoot, keeping: configuration.maxCacheCopies, fileManager: fileManager)
        }

        // 4. 解释器：仓里自带的 venv 优先，然后 Homebrew、系统。
        let interpreter = configuration.interpreterCandidates(repoRoot)
            .first { fileManager.fileExists(atPath: $0) }
        guard let interpreter else {
            return .failed(reason: "没找到可用的 Python")
        }
        return .exported(Exported(repoRoot: repoRoot, cacheDirectory: cacheDirectory, interpreterPath: interpreter))
    }

    /// 脚本进程只给 HOME、一条固定 PATH 和认到的 cortex 仓根，不吃哨兵进程
    /// 的整个环境。仓根来自本轮认仓通过 rev-parse 校验的那个根，判据脚本拿
    /// CORTEX_REPO_ROOT 直接认仓，没装过闸运行时的机器上不用再猜；套餐脚本
    /// 不读这个变量，多个键无害。logsDirectory 存在时一并给 CORTEX_LOG_ROOT
    /// （合法根词表成员），遥测脚本据此数本机线，不再依赖仓根下恰好有 logs。
    static func scriptEnvironment(
        homeDirectory: String,
        repoRoot: URL,
        logsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String: String] {
        var environment = [
            "HOME": homeDirectory,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(homeDirectory)/.local/bin:/opt/homebrew/bin",
            "CORTEX_REPO_ROOT": repoRoot.path,
        ]
        if let logsDirectory,
           fileManager.fileExists(atPath: logsDirectory.path) {
            environment["CORTEX_LOG_ROOT"] = logsDirectory.path
        }
        return environment
    }

    /// 认仓候选（按顺序）：环境变量 CORTEX_REPO_ROOT、监视目录解析软链后的上一级、
    /// 闸运行时 repo 文件记下的仓库位置（装机时落盘，跟着闸运行时走，换机器装完
    /// 就有）、装机版 WatchDirectoryResolution 给的 repositoryRoot（软链没解析，
    /// 往往不是 git 仓，只当兜底）。每条候选照样过 rev-parse 认仓校验，不是
    /// git 仓的落空往下一跳。
    static func repositoryRootCandidates(
        environment: [String: String],
        watchDirectory: URL?,
        gateRuntimeRepoRoot: URL?,
        fallbackRepositoryRoot: URL?
    ) -> [URL] {
        var candidates: [URL] = []
        if let configured = environment["CORTEX_REPO_ROOT"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        if let watchDirectory {
            candidates.append(watchDirectory.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        if let gateRuntimeRepoRoot {
            candidates.append(gateRuntimeRepoRoot)
        }
        if let fallbackRepositoryRoot {
            candidates.append(fallbackRepositoryRoot)
        }
        return candidates
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
            // scripts/ 之外放行 src/（遥测 v2 槽位采样传递依赖 src/core/config，
            // Falcon 2026-09-18 令三机总览）：仍是仓内相对路径，.. 与绝对路径照旧拒。
            guard line.hasPrefix("scripts/") || line.hasPrefix("src/"),
                  !line.contains(".."), !line.hasPrefix("/") else {
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
