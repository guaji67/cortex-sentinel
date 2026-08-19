import Foundation
import SwiftUI

enum BackgroundJobStatus: String, Equatable {
    case ok
    case error
    case stalled
    case hung
    case neverRan = "never_ran"
    case unknown

    init(rawValue: String?) {
        switch rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "ok":
            self = .ok
        case "error":
            self = .error
        case "stalled":
            self = .stalled
        case "hung":
            self = .hung
        case "never_ran":
            self = .neverRan
        default:
            self = .unknown
        }
    }

    var isProblem: Bool {
        self != .ok
    }

    var displayName: String {
        switch self {
        case .ok:
            return "正常"
        case .neverRan:
            return "从来没跑过"
        case .error, .stalled, .hung, .unknown:
            return "出错"
        }
    }
}

enum BackgroundJobPlistStatus: String, Equatable {
    case loaded
    case missing
    case unreadable
    case unrecognized

    static let missingDisplayText = "配置不在了"
    static let unreadableDisplayText = "配置读不了"
    static let unrecognizedDisplayText = "状态看不懂"
    static let detailCharacterLimit = 40
    static let detailEllipsis = "…"

    /// 缺字段按 loaded，保老快照。字段在但值不认识（含空串、JSON null）算有问题。
    fileprivate static func parse(_ field: JSONStringField) -> BackgroundJobPlistStatus {
        switch field {
        case .absent:
            return .loaded
        case let .present(rawValue):
            switch rawValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            {
            case "loaded":
                return .loaded
            case "missing":
                return .missing
            case "unreadable":
                return .unreadable
            default:
                return .unrecognized
            }
        }
    }

    var isProblem: Bool {
        self != .loaded
    }

    static func truncatedDetail(_ text: String) -> String {
        if text.count <= detailCharacterLimit {
            return text
        }
        return String(text.prefix(detailCharacterLimit)) + detailEllipsis
    }
}

struct BackgroundJob: Identifiable, Equatable {
    let label: String
    let name: String
    let intervalText: String
    let lastRunAt: Date?
    let lastRunText: String
    let status: BackgroundJobStatus
    let statusText: String
    let reason: String
    let lastExitCode: Int?
    let plistStatus: BackgroundJobPlistStatus
    let plistErrorDetail: String

    var id: String { label }

    var isProblem: Bool { status.isProblem || plistStatus.isProblem }

    var problemDetail: String {
        switch plistStatus {
        case .missing:
            return BackgroundJobPlistStatus.missingDisplayText
        case .unreadable:
            if plistErrorDetail.isEmpty {
                return BackgroundJobPlistStatus.unreadableDisplayText
            }
            return [
                BackgroundJobPlistStatus.unreadableDisplayText,
                BackgroundJobPlistStatus.truncatedDetail(plistErrorDetail),
            ].joined(separator: " · ")
        case .unrecognized:
            return BackgroundJobPlistStatus.unrecognizedDisplayText
        case .loaded:
            break
        }
        var parts: [String] = []
        if !lastRunText.isEmpty {
            parts.append("上次跑：\(lastRunText)")
        }
        if !reason.isEmpty {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    var healthyDetail: String {
        var parts = [intervalText]
        if !lastRunText.isEmpty {
            parts.append("上次跑：\(lastRunText)")
        }
        parts.append(statusText)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct BackgroundJobsSnapshot: Equatable {
    enum SourceState: Equatable {
        case available
        case missing
        case invalid
    }

    let sourceState: SourceState
    let generatedAt: Date?
    let okCount: Int
    let problemCount: Int
    let jobs: [BackgroundJob]

    static let missing = BackgroundJobsSnapshot(
        sourceState: .missing,
        generatedAt: nil,
        okCount: 0,
        problemCount: 0,
        jobs: []
    )

    static let invalid = BackgroundJobsSnapshot(
        sourceState: .invalid,
        generatedAt: nil,
        okCount: 0,
        problemCount: 0,
        jobs: []
    )
}

struct BackgroundJobRow: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let isProblem: Bool
}

struct BackgroundJobsPresentation: Equatable {
    static let snapshotStaleSeconds: TimeInterval = 30 * 60

    let summaryText: String
    let hasProblems: Bool
    let snapshotStale: Bool
    let tone: SentinelRowTone
    let problemRows: [BackgroundJobRow]
    let healthyRows: [BackgroundJobRow]

    init(
        snapshot: BackgroundJobsSnapshot,
        now: Date = Date()
    ) {
        switch snapshot.sourceState {
        case .missing:
            summaryText = "后台任务 无数据"
            hasProblems = false
            snapshotStale = false
            tone = .normal
            problemRows = []
            healthyRows = []
            return
        case .invalid:
            summaryText = "后台任务 读不出"
            hasProblems = true
            snapshotStale = false
            tone = .warning
            problemRows = [
                BackgroundJobRow(
                    id: "invalid",
                    name: "健康快照",
                    detail: "文件读不出",
                    isProblem: true
                ),
            ]
            healthyRows = []
            return
        case .available:
            break
        }

        let stale: Bool
        if let generatedAt = snapshot.generatedAt {
            stale = now.timeIntervalSince(generatedAt) > Self.snapshotStaleSeconds
        } else {
            stale = true
        }
        snapshotStale = stale

        var problems = snapshot.jobs.filter(\.isProblem).map { job in
            BackgroundJobRow(
                id: job.label,
                name: job.name,
                detail: job.problemDetail,
                isProblem: true
            )
        }
        if stale {
            let ageText: String
            if let generatedAt = snapshot.generatedAt {
                let minutes = max(1, Int(now.timeIntervalSince(generatedAt) / 60))
                ageText = "\(minutes) 分钟未更新"
            } else {
                ageText = "没有生成时间"
            }
            problems.insert(
                BackgroundJobRow(
                    id: "snapshot-stale",
                    name: "健康快照",
                    detail: ageText,
                    isProblem: true
                ),
                at: 0
            )
        }

        let healthy = snapshot.jobs.filter { !$0.isProblem }.map { job in
            BackgroundJobRow(
                id: job.label,
                name: job.name,
                detail: job.healthyDetail,
                isProblem: false
            )
        }

        let total = snapshot.jobs.count
        hasProblems = !problems.isEmpty
        problemRows = problems
        healthyRows = healthy
        if hasProblems {
            summaryText = "后台任务 \(total) 个，\(problems.count) 个不正常"
            tone = .warning
        } else if total == 0 {
            summaryText = "后台任务 0 个"
            tone = .normal
        } else {
            summaryText = "后台任务 \(total) 个，全部正常"
            tone = .success
        }
    }
}

private struct BackgroundJobsPayload: Decodable {
    let generatedAt: String?
    let okCount: Int?
    let problemCount: Int?
    let jobs: [BackgroundJobPayload]?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case okCount = "ok_count"
        case problemCount = "problem_count"
        case jobs
    }
}

private enum JSONStringField: Equatable {
    case absent
    case present(String?)
}

private struct BackgroundJobPayload: Decodable {
    let label: String?
    let name: String?
    let intervalText: String?
    let lastRunAt: String?
    let lastRunText: String?
    let status: String?
    let statusText: String?
    let reason: String?
    let lastExitCode: Int?
    let plistStatusField: JSONStringField
    let plistErrorDetail: String?

    enum CodingKeys: String, CodingKey {
        case label
        case name
        case intervalText = "interval_text"
        case lastRunAt = "last_run_at"
        case lastRunText = "last_run_text"
        case status
        case statusText = "status_text"
        case reason
        case lastExitCode = "last_exit_code"
        case plistStatus = "plist_status"
        case plistErrorDetail = "plist_error_detail"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        intervalText = try container.decodeIfPresent(String.self, forKey: .intervalText)
        lastRunAt = try container.decodeIfPresent(String.self, forKey: .lastRunAt)
        lastRunText = try container.decodeIfPresent(String.self, forKey: .lastRunText)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        lastExitCode = try container.decodeIfPresent(Int.self, forKey: .lastExitCode)
        if container.contains(.plistStatus) {
            plistStatusField = .present(
                try container.decodeIfPresent(String.self, forKey: .plistStatus)
            )
        } else {
            plistStatusField = .absent
        }
        plistErrorDetail = try container.decodeIfPresent(String.self, forKey: .plistErrorDetail)
    }
}

enum BackgroundJobsReader {
    static func parse(data: Data) -> BackgroundJobsSnapshot {
        guard let payload = try? JSONDecoder().decode(BackgroundJobsPayload.self, from: data) else {
            return .invalid
        }
        let jobs = (payload.jobs ?? []).compactMap(job(from:))
        return BackgroundJobsSnapshot(
            sourceState: .available,
            generatedAt: SentinelDateParser.parse(payload.generatedAt),
            okCount: payload.okCount ?? jobs.filter { !$0.isProblem }.count,
            problemCount: payload.problemCount ?? jobs.filter(\.isProblem).count,
            jobs: jobs
        )
    }

    static func read(
        at url: URL,
        fileManager: FileManager = .default
    ) -> BackgroundJobsSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        return parse(data: data)
    }

    private static func job(from payload: BackgroundJobPayload) -> BackgroundJob? {
        let label = payload.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty else {
            return nil
        }
        let name = normalized(payload.name) ?? label
        let status = BackgroundJobStatus(rawValue: payload.status)
        return BackgroundJob(
            label: label,
            name: name,
            intervalText: normalized(payload.intervalText) ?? "",
            lastRunAt: SentinelDateParser.parse(payload.lastRunAt),
            lastRunText: normalized(payload.lastRunText) ?? "",
            status: status,
            statusText: normalized(payload.statusText) ?? status.displayName,
            reason: normalized(payload.reason) ?? "",
            lastExitCode: payload.lastExitCode,
            plistStatus: BackgroundJobPlistStatus.parse(payload.plistStatusField),
            plistErrorDetail: normalized(payload.plistErrorDetail) ?? ""
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct BackgroundJobsSectionView: View {
    let snapshot: BackgroundJobsSnapshot
    @Binding var showsHealthy: Bool
    var now: Date = Date()

    private var presentation: BackgroundJobsPresentation {
        BackgroundJobsPresentation(snapshot: snapshot, now: now)
    }

    var body: some View {
        let presentation = self.presentation
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            if presentation.hasProblems {
                summaryLine(presentation, discloses: false)
                ForEach(presentation.problemRows) { row in
                    problemRow(row)
                }
                if !presentation.healthyRows.isEmpty {
                    healthyDisclosure(presentation)
                }
            } else if presentation.healthyRows.isEmpty {
                summaryLine(presentation, discloses: false)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showsHealthy.toggle()
                    }
                } label: {
                    summaryLine(presentation, discloses: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(presentation.summaryText)，\(showsHealthy ? "已展开" : "已折叠")"
                )

                if showsHealthy {
                    ForEach(presentation.healthyRows) { row in
                        healthyRow(row)
                    }
                }
            }
        }
        .accessibilityIdentifier("background-jobs-section")
    }

    private func summaryLine(
        _ presentation: BackgroundJobsPresentation,
        discloses: Bool
    ) -> some View {
        HStack(spacing: SentinelTheme.Spacing.md) {
            if discloses {
                Image(systemName: "chevron.right")
                    .font(SentinelTheme.Fonts.axisLabel.weight(.semibold))
                    .rotationEffect(.degrees(showsHealthy ? 90 : 0))
                    .frame(
                        width: SentinelTheme.Metrics.disclosureChevron,
                        height: SentinelTheme.Metrics.disclosureChevron
                    )
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }

            Circle()
                .fill(summaryColor(presentation))
                .frame(
                    width: SentinelTheme.Metrics.statusDot,
                    height: SentinelTheme.Metrics.statusDot
                )

            Text(presentation.summaryText)
                .font(
                    presentation.hasProblems
                        ? SentinelTheme.Fonts.rowTitle
                        : SentinelTheme.Fonts.subtitle
                )
                .foregroundStyle(
                    presentation.hasProblems
                        ? SentinelTheme.Colors.warning
                        : SentinelTheme.Colors.secondaryForeground
                )
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("background-jobs-summary")
        .accessibilityLabel(presentation.summaryText)
    }

    private func problemRow(_ row: BackgroundJobRow) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            Text(row.name)
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            Text(row.detail)
                .font(SentinelTheme.Fonts.metadata)
                .foregroundStyle(SentinelTheme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sentinelRow(tone: .warning)
        .accessibilityIdentifier("background-jobs-problem-\(row.id)")
        .accessibilityLabel("\(row.name)，\(row.detail)")
    }

    private func healthyRow(_ row: BackgroundJobRow) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            Text(row.name)
                .font(SentinelTheme.Fonts.body)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            Text(row.detail)
                .font(SentinelTheme.Fonts.metadata)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sentinelRow(tone: .normal)
        .accessibilityIdentifier("background-jobs-ok-\(row.id)")
    }

    private func healthyDisclosure(_ presentation: BackgroundJobsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showsHealthy.toggle()
                }
            } label: {
                HStack(spacing: SentinelTheme.Spacing.md) {
                    Image(systemName: "chevron.right")
                        .font(SentinelTheme.Fonts.axisLabel.weight(.semibold))
                        .rotationEffect(.degrees(showsHealthy ? 90 : 0))
                        .frame(
                            width: SentinelTheme.Metrics.disclosureChevron,
                            height: SentinelTheme.Metrics.disclosureChevron
                        )
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    Text("其余正常")
                        .font(SentinelTheme.Fonts.section)
                        .kerning(0.5)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    Spacer()
                    Text("\(presentation.healthyRows.count)")
                        .sentinelBadge(
                            foreground: SentinelTheme.Colors.secondaryForeground,
                            background: SentinelTheme.Colors.inset
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("其余正常，\(showsHealthy ? "已展开" : "已折叠")")

            if showsHealthy {
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                    ForEach(presentation.healthyRows) { row in
                        healthyRow(row)
                    }
                }
                .padding(.top, SentinelTheme.Spacing.sm)
            }
        }
    }

    private func summaryColor(_ presentation: BackgroundJobsPresentation) -> Color {
        if presentation.hasProblems {
            return SentinelTheme.Colors.warning
        }
        if presentation.healthyRows.isEmpty {
            return SentinelTheme.Colors.secondaryForeground
        }
        return SentinelTheme.Colors.success
    }
}
