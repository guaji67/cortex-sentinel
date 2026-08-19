import Foundation

/// v3.2 第 5 点：派工日志长效自动清理。
///
/// 红线（严格照工单）——只碰这四类「派工日志」白名单，白名单外一律不动：
///   1. `codex-<slug>.log`（排除 `codex-babysitter-*`）
///   2. `kimi-*.log`
///   3. `*babysitter*.stdout`
///   4. `*babysitter*.nohup.out`
///
/// 绝不动：`codex-line-registry.json`、状态文件（条数清理见 `StatusFileCleaner`）、
/// `aio-*`/switch-log、以及一切非派工域文件（web-dev*、dev-server.log、
/// cortex-daily.log、realtime-loop.log、screen_cortex/、contact-fact-queue.json、
/// cortex-run-now-* 等）。因为采用「只列白名单」而非「黑名单排除」，这些文件天然不进候选。
///
/// 删除判定（对白名单内文件）：
///   - 有 `codex-babysitter-<slug>.status.json` 且 state=running → 活线，永不删
///   - state ∈ done/dead/help → 终态，删
///   - state ∈ retrying/backoff/unknown → 非活线过渡态，正常保留，仅在超 500MB 上限时按旧到新清理
///   - 无 status 文件（含 kimi）→ 孤儿；但近 10 分钟内仍在写的按活线保护（防误删仍在跑、
///     只是没写 babysitter status 的 kimi 线，见记忆 kimi-cli-liveness），静默超 10 分钟才删
///   - 白名单候选集总量 > 500MB 时，把上面「过渡态」候选按 mtime 从旧到新补删，直到 ≤ 400MB。
///     体积只统计白名单文件，不拿整棵 logs 树跟阈值比。
enum LogCleanupConstants {
    static let maxTotalBytes: Int64 = 500 * 1024 * 1024
    static let targetBytes: Int64 = 400 * 1024 * 1024
    /// 孤儿日志判活的空闲护栏：与全局活线阈值(10min)一致。
    static let orphanActiveGraceSeconds: TimeInterval = SentinelAggregation.activeStatusSeconds
    /// 自动清理巡检周期：启动时跑一次，之后每小时一次。
    static let sweepInterval: TimeInterval = 60 * 60
    /// 巡检痕迹最多保留这么多行，超了丢最旧的。
    static let inspectLogMaxLines = 200
}

enum LogCleanupReason: String, Equatable {
    case terminal
    case staleOrphan
    case overCap
}

struct LogCleanupCandidate: Equatable {
    let url: URL
    let sizeBytes: Int64
    let modifiedAt: Date?
    let reason: LogCleanupReason
    let detail: String

    var fileName: String {
        url.lastPathComponent
    }
}

struct LogCleanupPlan: Equatable {
    /// 白名单候选集字节数，不是整棵 logs 树。
    let totalBytesBefore: Int64
    let whitelistFileCount: Int
    let candidates: [LogCleanupCandidate]
    /// 被当作活线保护、明确不删的白名单文件名（供报告佐证「活线不动」）。
    let protectedActive: [String]

    static let empty = LogCleanupPlan(
        totalBytesBefore: 0,
        whitelistFileCount: 0,
        candidates: [],
        protectedActive: []
    )

    var reclaimBytes: Int64 {
        candidates.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalBytesAfter: Int64 {
        max(0, totalBytesBefore - reclaimBytes)
    }
}

enum LogCleaner {
    // MARK: 计划（纯函数，dry-run 只走这里、不删任何东西）

    static func plan(
        logsDirectory: URL,
        now: Date = Date(),
        maxTotalBytes: Int64 = LogCleanupConstants.maxTotalBytes,
        targetBytes: Int64 = LogCleanupConstants.targetBytes,
        fileManager: FileManager = .default
    ) -> LogCleanupPlan {
        let dir = logsDirectory.resolvingSymlinksInPath()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        let fileNames = entries.map { $0.lastPathComponent }
        let stateMap = statusStateMap(in: dir, fileNames: fileNames, fileManager: fileManager)

        var phase1: [LogCleanupCandidate] = []
        var transient: [LogCleanupCandidate] = []
        var protectedActive: [String] = []
        var whitelistBytes: Int64 = 0
        var whitelistFileCount = 0

        for url in entries {
            let name = url.lastPathComponent
            guard let slug = cleanableSlug(fileName: name) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            guard values?.isRegularFile == true else {
                continue
            }
            let size = Int64(values?.fileSize ?? 0)
            let modifiedAt = values?.contentModificationDate
            whitelistBytes += size
            whitelistFileCount += 1

            if let state = stateMap[slug] {
                if state.isCleanupProtectedLive {
                    protectedActive.append(name)
                    continue
                }
                switch state {
                case .running, .waitingRelay:
                    break
                case .done, .dead, .killed, .help:
                    phase1.append(
                        LogCleanupCandidate(
                            url: url,
                            sizeBytes: size,
                            modifiedAt: modifiedAt,
                            reason: .terminal,
                            detail: "终态 \(state.displayName)"
                        )
                    )
                case .retrying, .backoff, .unknown:
                    transient.append(
                        LogCleanupCandidate(
                            url: url,
                            sizeBytes: size,
                            modifiedAt: modifiedAt,
                            reason: .overCap,
                            detail: "过渡态 \(state.displayName) · 仅超限清理"
                        )
                    )
                }
            } else {
                let idle = modifiedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                if idle < LogCleanupConstants.orphanActiveGraceSeconds {
                    protectedActive.append(name)
                } else {
                    phase1.append(
                        LogCleanupCandidate(
                            url: url,
                            sizeBytes: size,
                            modifiedAt: modifiedAt,
                            reason: .staleOrphan,
                            detail: "无状态文件 · \(idleText(idle))未写"
                        )
                    )
                }
            }
        }

        let totalBytesBefore = whitelistBytes
        var candidates = phase1
        var projected = totalBytesBefore - phase1.reduce(0) { $0 + $1.sizeBytes }

        if totalBytesBefore > maxTotalBytes,
           projected > targetBytes {
            let sorted = transient.sorted {
                ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
            }
            for candidate in sorted {
                if projected <= targetBytes {
                    break
                }
                candidates.append(
                    LogCleanupCandidate(
                        url: candidate.url,
                        sizeBytes: candidate.sizeBytes,
                        modifiedAt: candidate.modifiedAt,
                        reason: .overCap,
                        detail: "超 500MB 上限 · 旧线清理"
                    )
                )
                projected -= candidate.sizeBytes
            }
        }

        return LogCleanupPlan(
            totalBytesBefore: totalBytesBefore,
            whitelistFileCount: whitelistFileCount,
            candidates: candidates,
            protectedActive: protectedActive.sorted()
        )
    }

    // MARK: 执行

    @discardableResult
    static func execute(
        _ plan: LogCleanupPlan,
        fileManager: FileManager = .default
    ) -> [URL] {
        var deleted: [URL] = []
        for candidate in plan.candidates {
            do {
                try fileManager.removeItem(at: candidate.url)
                deleted.append(candidate.url)
            } catch {
                continue
            }
        }
        return deleted
    }

    /// 跑一轮：dryRun=true 仅返回计划、绝不删；false 才真正删除。
    /// 无论干跑还是实跑，都在 `logs/` 外面写一行巡检痕迹。
    @discardableResult
    static func run(
        logsDirectory: URL,
        dryRun: Bool,
        now: Date = Date(),
        maxTotalBytes: Int64 = LogCleanupConstants.maxTotalBytes,
        targetBytes: Int64 = LogCleanupConstants.targetBytes,
        fileManager: FileManager = .default,
        inspectLogURL: URL? = nil
    ) -> LogCleanupPlan {
        let cleanupPlan = plan(
            logsDirectory: logsDirectory,
            now: now,
            maxTotalBytes: maxTotalBytes,
            targetBytes: targetBytes,
            fileManager: fileManager
        )
        var deletedURLs: [URL] = []
        if !dryRun {
            deletedURLs = execute(cleanupPlan, fileManager: fileManager)
        }
        let deletedSet = Set(deletedURLs)
        let reclaimBytes = cleanupPlan.candidates
            .filter { deletedSet.contains($0.url) }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let inspectURL = inspectLogURL ?? defaultInspectLogURL(fileManager: fileManager)
        appendInspectLine(
            inspectLine(
                at: now,
                scanned: cleanupPlan.whitelistFileCount,
                deleted: deletedURLs.count,
                reclaimBytes: reclaimBytes,
                candidateBytes: max(0, cleanupPlan.totalBytesBefore - reclaimBytes)
            ),
            to: inspectURL,
            fileManager: fileManager
        )
        return cleanupPlan
    }

    // MARK: 白名单分类

    /// 返回可清理文件对应的 slug；非白名单文件返回 nil。
    static func cleanableSlug(fileName: String) -> String? {
        // 1. codex 派工日志：codex-<slug>.log（排除 codex-babysitter-*）
        if fileName.hasPrefix("codex-"),
           fileName.hasSuffix(".log"),
           !fileName.hasPrefix("codex-babysitter-") {
            let slug = String(fileName.dropFirst("codex-".count).dropLast(".log".count))
            return slug.isEmpty ? nil : slug
        }
        // 2. kimi 派工日志：kimi-<slug>.log
        if fileName.hasPrefix("kimi-"), fileName.hasSuffix(".log") {
            let slug = String(fileName.dropFirst("kimi-".count).dropLast(".log".count))
            return slug.isEmpty ? nil : slug
        }
        // 3/4. 守护自身 stdout/nohup：(codex-)?babysitter-<slug>.stdout / .nohup.out
        for suffix in [".nohup.out", ".stdout"] where fileName.hasSuffix(suffix) {
            var base = String(fileName.dropLast(suffix.count))
            if base.hasPrefix("codex-babysitter-") {
                base = String(base.dropFirst("codex-babysitter-".count))
            } else if base.hasPrefix("babysitter-") {
                base = String(base.dropFirst("babysitter-".count))
            } else {
                continue
            }
            return base.isEmpty ? nil : base
        }
        return nil
    }

    // MARK: 内部工具

    private static func statusStateMap(
        in dir: URL,
        fileNames: [String],
        fileManager: FileManager
    ) -> [String: LineState] {
        let prefix = "codex-babysitter-"
        let suffix = ".status.json"
        var map: [String: LineState] = [:]
        for name in fileNames where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let slug = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard !slug.isEmpty else {
                continue
            }
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(StatePayload.self, from: data),
                  let raw = payload.state, !raw.isEmpty
            else {
                continue
            }
            map[slug] = LineState(rawValue: raw)
        }
        return map
    }

    /// 整棵树体积，只给排查用。阈值判断走白名单候选集，不再读这个数。
    static func directorySize(_ dir: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }

    /// 巡检痕迹不进被监视的 `logs/`，写到 Application Support。
    static func defaultInspectLogURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("CortexSentinel", isDirectory: true)
            .appendingPathComponent("log-cleanup-inspect.log")
    }

    static func inspectTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }

    static func inspectLine(
        at: Date,
        scanned: Int,
        deleted: Int,
        reclaimBytes: Int64,
        candidateBytes: Int64
    ) -> String {
        "ts=\(inspectTimestamp(at)) scanned=\(scanned) deleted=\(deleted) reclaim_bytes=\(reclaimBytes) candidate_bytes=\(candidateBytes)"
    }

    static func appendInspectLine(
        _ line: String,
        to url: URL,
        maxLines: Int = LogCleanupConstants.inspectLogMaxLines,
        fileManager: FileManager = .default
    ) {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var lines: [String] = []
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init)
        }
        lines.append(line)
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func idleText(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 {
            return "\(Int(seconds / 86_400)) 天"
        }
        if seconds >= 3600 {
            return "\(Int(seconds / 3600)) 小时"
        }
        return "\(max(1, Int(seconds / 60))) 分钟"
    }

    private struct StatePayload: Decodable {
        let state: String?
    }
}

extension LogCleanupPlan {
    /// 供 CLI dry-run / 日志打印的人话报告。
    func reportText(dryRun: Bool) -> String {
        var lines: [String] = []
        lines.append(dryRun ? "== 日志清理 · 干跑（不删任何文件）==" : "== 日志清理 · 实跑 ==")
        lines.append(
            "白名单候选集：\(LogCleaner.formatBytes(totalBytesBefore))"
                + " / \(whitelistFileCount) 个"
                + " → 预计 \(LogCleaner.formatBytes(totalBytesAfter))"
                + "（上限 500MB / 目标 400MB）"
        )
        lines.append("本次\(dryRun ? "会" : "已")删除 \(candidates.count) 个文件，回收 \(LogCleaner.formatBytes(reclaimBytes))：")
        if candidates.isEmpty {
            lines.append("  （无——白名单内没有可清理的终态/孤儿日志）")
        } else {
            for candidate in candidates.sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
                lines.append(
                    "  - \(candidate.fileName)"
                        + "  [\(LogCleaner.formatBytes(candidate.sizeBytes))]"
                        + "  \(candidate.detail)"
                )
            }
        }
        lines.append("保护中的活线日志（永不删）：\(protectedActive.isEmpty ? "无" : "\(protectedActive.count) 个")")
        for name in protectedActive {
            lines.append("  · \(name)")
        }
        return lines.joined(separator: "\n")
    }
}
