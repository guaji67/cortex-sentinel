import Foundation

/// 使用者面板实际能看见的那一窗：最近完成 8 条、历史最多 500 条。
///
/// 分组仍按 mtime 切活跃 / 24h 终态 / 更早历史；这一层只决定**露出顺序和条数**。
/// 不写 `codex-line-registry.json`，也不删 status 文件。被裁的线源文件仍在 logs/。
struct SentinelBoardWindow: Equatable {
    static let historyDisplayCap = 500
    static let recencyCriterion = "按状态文件 mtime 倒序（无 mtime 则 updated_at，再无则登记时间）；最近完成最多 8 条，历史最多 500 条"

    let recentShown: [LinePresentation]
    let historyShown: [LinePresentation]
    let hidden: [LinePresentation]

    var hiddenCount: Int {
        hidden.count
    }

    var recentCounts: EngineCounts {
        EngineCounts(recentShown)
    }

    var historyCounts: EngineCounts {
        EngineCounts(historyShown)
    }

    var hiddenCounts: EngineCounts {
        EngineCounts(hidden)
    }

    var footerText: String? {
        guard hiddenCount > 0 else {
            return nil
        }
        return "另有 \(hiddenCount) 条更早记录未显示。按状态文件时间倒序只留最近 \(Self.historyDisplayCap) 条；源文件仍在 logs/，登记表未改。"
    }

    static func snapshot(
        groups: SentinelLineGroups,
        recentCap: Int = SentinelAggregation.recentDisplayCap,
        historyCap: Int = historyDisplayCap
    ) -> SentinelBoardWindow {
        let recentRegistered = groups.recentlyCompleted.filter { $0.registration != nil }
        let recentSorted = newestFirst(recentRegistered)
        let split = SentinelAggregation.splitRecentDisplay(recentSorted, cap: recentCap)
        let historyPool = newestFirst(split.overflow + groups.history)
        if historyPool.count <= historyCap {
            return SentinelBoardWindow(
                recentShown: split.shown,
                historyShown: historyPool,
                hidden: []
            )
        }
        return SentinelBoardWindow(
            recentShown: split.shown,
            historyShown: Array(historyPool.prefix(historyCap)),
            hidden: Array(historyPool.dropFirst(historyCap))
        )
    }

    static func newestFirst(_ items: [LinePresentation]) -> [LinePresentation] {
        items.sorted { lhs, rhs in
            recencyPrecedes(lhs: lhs, rhs: rhs)
        }
    }

    static func recencyDate(for presentation: LinePresentation) -> Date? {
        presentation.line.effectiveUpdatedAt
            ?? presentation.registration.map { Date(timeIntervalSince1970: $0.registeredAt) }
    }

    func archive() -> HistoryTrimArchive {
        HistoryTrimArchive(
            criterion: Self.recencyCriterion,
            kept: historyShown.count,
            hiddenCount: hiddenCount,
            hidden: hidden.map { presentation in
                HistoryTrimArchive.Entry(
                    slug: presentation.line.slug,
                    engine: presentation.engine.displayName,
                    labelZH: presentation.registration?.labelZH,
                    recency: Self.recencyDate(for: presentation).map(Self.isoString)
                )
            }
        )
    }

    func writeArchive(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive())
        try data.write(to: url, options: .atomic)
    }

    private static func recencyPrecedes(lhs: LinePresentation, rhs: LinePresentation) -> Bool {
        switch (recencyDate(for: lhs), recencyDate(for: rhs)) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.line.slug < rhs.line.slug
        }
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct EngineCounts: Equatable {
    var grok: Int
    var codex: Int
    var unknown: Int

    init(_ items: [LinePresentation]) {
        var grok = 0
        var codex = 0
        var unknown = 0
        for item in items {
            switch item.engine {
            case .cursorGrok:
                grok += 1
            case .codex:
                codex += 1
            case .unknown:
                unknown += 1
            }
        }
        self.grok = grok
        self.codex = codex
        self.unknown = unknown
    }

    init(grok: Int = 0, codex: Int = 0, unknown: Int = 0) {
        self.grok = grok
        self.codex = codex
        self.unknown = unknown
    }
}

extension SentinelLineGroups {
    /// 通道行「N 条」与派工列表共用：非终态且 status 文件 10 分钟内，按引擎拆开。
    /// 不读 `channel-status.json` 的 `running`，那份摘要会和下面卡片打架。
    var activeEngineCounts: EngineCounts {
        EngineCounts(activeRegistered + activeUnregistered)
    }
}

struct HistoryTrimArchive: Equatable, Encodable {
    let criterion: String
    let kept: Int
    let hiddenCount: Int
    let hidden: [Entry]

    struct Entry: Equatable, Encodable {
        let slug: String
        let engine: String
        let labelZH: String?
        let recency: String?

        enum CodingKeys: String, CodingKey {
            case slug
            case engine
            case labelZH = "label_zh"
            case recency
        }
    }
}
