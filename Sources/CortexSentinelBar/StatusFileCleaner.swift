import Foundation

/// 状态文件按条数保留。面板的 `historyDisplayCap` 只限制画出多少条；
/// 磁盘上曾经可以堆几千个。这个上限做成命名常量，调用方可传入覆盖——
/// 下一条线要做成可设置项时不用再翻魔法数字。
enum StatusFileRetention {
    static let defaultCap = 500
}

struct StatusFileCleanupCandidate: Equatable {
    let url: URL
    let slug: String
    let recency: Date?
    let detail: String

    var fileName: String {
        url.lastPathComponent
    }
}

struct StatusFileCleanupPlan: Equatable {
    let totalCount: Int
    let cap: Int
    let candidates: [StatusFileCleanupCandidate]
    let protectedLive: [String]
    let keptCount: Int

    static let empty = StatusFileCleanupPlan(
        totalCount: 0,
        cap: StatusFileRetention.defaultCap,
        candidates: [],
        protectedLive: [],
        keptCount: 0
    )

    func reportText(dryRun: Bool) -> String {
        var lines: [String] = []
        lines.append(
            dryRun
                ? "== 状态文件清理 · 干跑（不删任何文件）=="
                : "== 状态文件清理 · 实跑 =="
        )
        lines.append(
            "状态文件：\(totalCount) 条 → 预计留下 \(keptCount) 条"
                + "（上限 \(cap) 条；活线另计、永不删）"
        )
        lines.append(
            "排序口径：\(SentinelBoardWindow.recencyCriterion)"
        )
        lines.append(
            "本次\(dryRun ? "会" : "已")删除 \(candidates.count) 个更旧的状态文件："
        )
        if candidates.isEmpty {
            lines.append("  （无——未超过条数上限，或多出来的都是活线）")
        } else {
            for candidate in candidates {
                lines.append("  - \(candidate.fileName)  \(candidate.detail)")
            }
        }
        lines.append(
            "保护中的活线状态文件（永不删）：\(protectedLive.isEmpty ? "无" : "\(protectedLive.count) 个")"
        )
        for name in protectedLive {
            lines.append("  · \(name)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 保留最近 `cap` 条非活线状态文件，更旧的删掉。
/// 「最近」跟面板 `SentinelBoardWindow.newestFirst` 同一套口径。
/// 活线判定复用 `LineState.isCleanupProtectedLive`（即 LogCleaner 的 running / waitingRelay）。
/// 跟 `LogCleaner` 的 500MB 体积规则互不覆盖：谁先触发谁干活，各管各的文件。
enum StatusFileCleaner {
    static func plan(
        logsDirectory: URL,
        registry: CodexLineRegistry = .empty,
        cap: Int = StatusFileRetention.defaultCap,
        fileManager: FileManager = .default
    ) -> StatusFileCleanupPlan {
        let resolvedCap = max(0, cap)
        let lines = SentinelFileReader.readLines(
            in: logsDirectory,
            fileManager: fileManager
        )
        let presentations = lines.map { line in
            LinePresentation(
                line: line,
                registration: registry.registration(for: line.slug)
            )
        }
        let sorted = SentinelBoardWindow.newestFirst(presentations)
        var protectedLive: [String] = []
        var eligible: [LinePresentation] = []
        for presentation in sorted {
            if presentation.line.state.isCleanupProtectedLive {
                protectedLive.append(presentation.line.sourceFile.lastPathComponent)
            } else {
                eligible.append(presentation)
            }
        }

        let overflow = resolvedCap >= eligible.count
            ? []
            : Array(eligible.dropFirst(resolvedCap))
        let candidates = overflow.map { presentation -> StatusFileCleanupCandidate in
            let recency = SentinelBoardWindow.recencyDate(for: presentation)
            return StatusFileCleanupCandidate(
                url: presentation.line.sourceFile,
                slug: presentation.line.slug,
                recency: recency,
                detail: "超过 \(resolvedCap) 条上限 · \(recencyText(recency))"
            )
        }

        return StatusFileCleanupPlan(
            totalCount: lines.count,
            cap: resolvedCap,
            candidates: candidates,
            protectedLive: protectedLive,
            keptCount: lines.count - candidates.count
        )
    }

    @discardableResult
    static func execute(
        _ plan: StatusFileCleanupPlan,
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

    @discardableResult
    static func run(
        logsDirectory: URL,
        registry: CodexLineRegistry = .empty,
        dryRun: Bool,
        cap: Int = StatusFileRetention.defaultCap,
        fileManager: FileManager = .default
    ) -> StatusFileCleanupPlan {
        let cleanupPlan = plan(
            logsDirectory: logsDirectory,
            registry: registry,
            cap: cap,
            fileManager: fileManager
        )
        if !dryRun {
            execute(cleanupPlan, fileManager: fileManager)
        }
        return cleanupPlan
    }

    private static func recencyText(_ date: Date?) -> String {
        guard let date else {
            return "无时间戳"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
