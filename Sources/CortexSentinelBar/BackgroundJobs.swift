import Foundation
import SwiftUI

enum BackgroundJobStatus: String, Equatable, Sendable {
    case ok
    case error
    case stalled
    case hung
    case neverRan = "never_ran"
    case unknown

    init(rawValue: String?) {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok", "healthy", "running": self = .ok
        case "error", "failed": self = .error
        case "stalled": self = .stalled
        case "hung": self = .hung
        case "never_ran": self = .neverRan
        default: self = .unknown
        }
    }

    var isProblem: Bool { self != .ok }

    var displayName: String {
        switch self {
        case .ok: return "正常"
        case .neverRan: return "从来没跑过"
        case .error, .stalled, .hung, .unknown: return "出错"
        }
    }
}

enum BackgroundJobPlistStatus: String, Equatable, Sendable {
    case loaded
    case missing
    case unreadable
    case unrecognized

    static let missingDisplayText = "配置不在了"
    static let unreadableDisplayText = "配置读不了"
    static let unrecognizedDisplayText = ChannelUnknownKind.unrecognized.statusText
    static let detailCharacterLimit = 40
    static let detailEllipsis = "…"

    fileprivate static func parse(_ field: JSONStringField) -> BackgroundJobPlistStatus {
        switch field {
        case .absent:
            return .loaded
        case let .present(rawValue):
            switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "loaded": return .loaded
            case "missing": return .missing
            case "unreadable": return .unreadable
            default: return .unrecognized
            }
        }
    }

    var isProblem: Bool { self != .loaded }

    static func truncatedDetail(_ text: String) -> String {
        text.count <= detailCharacterLimit
            ? text
            : String(text.prefix(detailCharacterLimit)) + detailEllipsis
    }
}

struct BackgroundJob: Identifiable, Equatable, Codable, Sendable {
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
    var displayName: String { name.isEmpty ? label : name }
    var isProblem: Bool { status.isProblem || plistStatus.isProblem }

    var problemDetail: String {
        switch plistStatus {
        case .missing:
            return BackgroundJobPlistStatus.missingDisplayText
        case .unreadable:
            if plistErrorDetail.isEmpty { return BackgroundJobPlistStatus.unreadableDisplayText }
            return [BackgroundJobPlistStatus.unreadableDisplayText,
                    BackgroundJobPlistStatus.truncatedDetail(plistErrorDetail)].joined(separator: " · ")
        case .unrecognized:
            return BackgroundJobPlistStatus.unrecognizedDisplayText
        case .loaded:
            break
        }
        var parts: [String] = []
        if !lastRunText.isEmpty { parts.append("上次跑：\(lastRunText)") }
        if !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    var healthyDetail: String {
        [intervalText, lastRunText.isEmpty ? "" : "上次跑：\(lastRunText)", statusText]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    init(
        label: String,
        name: String = "",
        intervalText: String = "",
        lastRunAt: Date? = nil,
        lastRunText: String = "",
        status: BackgroundJobStatus = .unknown,
        statusText: String? = nil,
        reason: String = "",
        lastExitCode: Int? = nil,
        plistStatus: BackgroundJobPlistStatus = .loaded,
        plistErrorDetail: String = ""
    ) {
        self.label = label
        self.name = name
        self.intervalText = intervalText
        self.lastRunAt = lastRunAt
        self.lastRunText = lastRunText
        self.status = status
        self.statusText = statusText ?? status.displayName
        self.reason = reason
        self.lastExitCode = lastExitCode
        self.plistStatus = plistStatus
        self.plistErrorDetail = plistErrorDetail
    }

    /// 私有腿旧快照的字符串构造签名，保留给 launchctl 操作测试与旧调用方。
    init(
        label: String,
        name: String = "",
        status: String,
        statusText: String? = nil,
        reason: String? = nil,
        plistStatus: String? = nil
    ) {
        self.init(
            label: label,
            name: name,
            status: BackgroundJobStatus(rawValue: status),
            statusText: statusText,
            reason: reason ?? "",
            plistStatus: BackgroundJobPlistStatus.parse(
                plistStatus == nil ? .absent : .present(plistStatus)
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case label, name
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
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decode(String.self, forKey: .label)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        intervalText = try values.decodeIfPresent(String.self, forKey: .intervalText) ?? ""
        lastRunAt = try values.decodeIfPresent(String.self, forKey: .lastRunAt).flatMap(SentinelDateParser.parse)
        lastRunText = try values.decodeIfPresent(String.self, forKey: .lastRunText) ?? ""
        status = BackgroundJobStatus(rawValue: try values.decodeIfPresent(String.self, forKey: .status))
        statusText = try values.decodeIfPresent(String.self, forKey: .statusText) ?? status.displayName
        reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? ""
        lastExitCode = try values.decodeIfPresent(Int.self, forKey: .lastExitCode)
        if values.contains(.plistStatus) {
            plistStatus = BackgroundJobPlistStatus.parse(.present(try values.decodeIfPresent(String.self, forKey: .plistStatus)))
        } else {
            plistStatus = .loaded
        }
        plistErrorDetail = try values.decodeIfPresent(String.self, forKey: .plistErrorDetail) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(label, forKey: .label)
        try values.encode(name, forKey: .name)
        try values.encode(intervalText, forKey: .intervalText)
        try values.encodeIfPresent(lastRunAt.map { ISO8601DateFormatter().string(from: $0) }, forKey: .lastRunAt)
        try values.encode(lastRunText, forKey: .lastRunText)
        try values.encode(status.rawValue, forKey: .status)
        try values.encode(statusText, forKey: .statusText)
        try values.encode(reason, forKey: .reason)
        try values.encodeIfPresent(lastExitCode, forKey: .lastExitCode)
        try values.encode(plistStatus.rawValue, forKey: .plistStatus)
        try values.encode(plistErrorDetail, forKey: .plistErrorDetail)
    }
}

/// 同时承载健康快照行和 launchctl 操作行：展示行保留 `name/detail`，操作行保留 `job/isDisabled`。
struct BackgroundJobRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let isProblem: Bool
    let job: BackgroundJob
    let isDisabled: Bool

    init(job: BackgroundJob, isDisabled: Bool) {
        self.id = job.id
        self.name = job.displayName
        self.detail = job.isProblem ? job.problemDetail : job.healthyDetail
        self.isProblem = job.isProblem
        self.job = job
        self.isDisabled = isDisabled
    }

    init(id: String, name: String, detail: String, isProblem: Bool) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isProblem = isProblem
        self.job = BackgroundJob(
            label: id,
            name: name,
            status: isProblem ? .error : .ok,
            statusText: isProblem ? "出错" : "正常",
            reason: detail
        )
        self.isDisabled = false
    }
}

struct BackgroundJobsSnapshot: Equatable, Sendable, RandomAccessCollection, ExpressibleByArrayLiteral {
    enum SourceState: Equatable, Sendable { case available, missing, invalid }

    let sourceState: SourceState
    let generatedAt: Date?
    let okCount: Int
    let problemCount: Int
    let jobs: [BackgroundJob]

    static let missing = BackgroundJobsSnapshot(sourceState: .missing, generatedAt: nil, okCount: 0, problemCount: 0, jobs: [])
    static let invalid = BackgroundJobsSnapshot(sourceState: .invalid, generatedAt: nil, okCount: 0, problemCount: 0, jobs: [])

    init(sourceState: SourceState, generatedAt: Date?, okCount: Int, problemCount: Int, jobs: [BackgroundJob]) {
        self.sourceState = sourceState
        self.generatedAt = generatedAt
        self.okCount = okCount
        self.problemCount = problemCount
        self.jobs = jobs
    }

    init(arrayLiteral elements: BackgroundJob...) {
        self.init(sourceState: .invalid, generatedAt: nil, okCount: 0, problemCount: 0, jobs: elements)
    }

    public var startIndex: Int { jobs.startIndex }
    public var endIndex: Int { jobs.endIndex }
    public func index(after i: Int) -> Int { jobs.index(after: i) }
    public func index(before i: Int) -> Int { jobs.index(before: i) }
    public subscript(position: Int) -> BackgroundJob { jobs[position] }
}

struct BackgroundJobsPresentation: Equatable {
    static let snapshotStaleSeconds: TimeInterval = 30 * 60
    let summaryText: String
    let hasProblems: Bool
    let snapshotStale: Bool
    let tone: SentinelRowTone
    let problemRows: [BackgroundJobRow]
    let healthyRows: [BackgroundJobRow]

    init(snapshot: BackgroundJobsSnapshot, now: Date = Date()) {
        switch snapshot.sourceState {
        case .missing:
            summaryText = "后台任务 无数据"; hasProblems = false; snapshotStale = false; tone = .normal; problemRows = []; healthyRows = []; return
        case .invalid:
            summaryText = "后台任务 读不出"; hasProblems = true; snapshotStale = false; tone = .warning
            problemRows = [BackgroundJobRow(id: "invalid", name: "健康快照", detail: "文件读不出", isProblem: true)]; healthyRows = []; return
        case .available: break
        }
        let stale = snapshot.generatedAt.map { now.timeIntervalSince($0) > Self.snapshotStaleSeconds } ?? true
        snapshotStale = stale
        var problems = snapshot.jobs.filter(\.isProblem).map { BackgroundJobRow(id: $0.label, name: $0.displayName, detail: $0.problemDetail, isProblem: true) }
        if stale {
            let ageText = snapshot.generatedAt.map { "\(max(1, Int(now.timeIntervalSince($0) / 60))) 分钟未更新" } ?? "没有生成时间"
            problems.insert(BackgroundJobRow(id: "snapshot-stale", name: "健康快照", detail: ageText, isProblem: true), at: 0)
        }
        let healthy = snapshot.jobs.filter { !$0.isProblem }.map { BackgroundJobRow(id: $0.label, name: $0.displayName, detail: $0.healthyDetail, isProblem: false) }
        let total = snapshot.jobs.count
        hasProblems = !problems.isEmpty
        problemRows = problems
        healthyRows = healthy
        if hasProblems { summaryText = "后台任务 \(total) 个，\(problems.count) 个不正常"; tone = .warning }
        else if total == 0 { summaryText = "后台任务 0 个"; tone = .normal }
        else { summaryText = "后台任务 \(total) 个，全部正常"; tone = .success }
    }

    /// 私有腿的 launchctl UI 需要把禁用标签并入可操作列表。
    static func merge(jobs: [BackgroundJob], disabledLabels: Set<String>) -> [BackgroundJobRow] {
        var byLabel = Dictionary(uniqueKeysWithValues: jobs.map { ($0.label, $0) })
        for label in disabledLabels where byLabel[label] == nil {
            byLabel[label] = BackgroundJob(label: label, status: .unknown, statusText: "已关闭")
        }
        return byLabel.values
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            .map { BackgroundJobRow(job: $0, isDisabled: disabledLabels.contains($0.label)) }
    }
}

private enum JSONStringField: Equatable { case absent, present(String?) }

private struct BackgroundJobsPayload: Decodable {
    let generatedAt: String?
    let okCount: Int?
    let problemCount: Int?
    let jobs: [BackgroundJob]?
    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at", okCount = "ok_count", problemCount = "problem_count", jobs
    }
}

enum BackgroundJobsReader {
    static func parse(data: Data) -> BackgroundJobsSnapshot {
        guard let payload = try? JSONDecoder().decode(BackgroundJobsPayload.self, from: data) else {
            if let jobs = try? JSONDecoder().decode([BackgroundJob].self, from: data) {
                return BackgroundJobsSnapshot(sourceState: .available, generatedAt: nil, okCount: jobs.filter { !$0.isProblem }.count, problemCount: jobs.filter(\.isProblem).count, jobs: jobs)
            }
            return .invalid
        }
        let jobs = payload.jobs ?? []
        return BackgroundJobsSnapshot(
            sourceState: .available,
            generatedAt: SentinelDateParser.parse(payload.generatedAt),
            okCount: payload.okCount ?? jobs.filter { !$0.isProblem }.count,
            problemCount: payload.problemCount ?? jobs.filter(\.isProblem).count,
            jobs: jobs
        )
    }

    static func read(at url: URL, fileManager: FileManager = .default) -> BackgroundJobsSnapshot {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        return parse(data: (try? Data(contentsOf: url)) ?? Data())
    }
}

enum BackgroundJobsConstants {
    static let criticalLabels: Set<String> = [
        "com.falcon.cortex.web", "com.falcon.cortex.web-guard",
        "com.falcon.cortex.memory-monitor", "com.falcon.cortex.mini-mirror-sync",
    ]
}

struct DisabledJobsStore {
    let url: URL
    let fileManager: FileManager
    init(url: URL, fileManager: FileManager = .default) { self.url = url; self.fileManager = fileManager }
    func read() -> Set<String> {
        guard let data = try? Data(contentsOf: url), let labels = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(labels.filter { !$0.isEmpty })
    }
    @discardableResult func write(_ labels: Set<String>) throws -> Set<String> {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(labels.sorted()).write(to: url, options: .atomic)
        return labels
    }
    func adding(_ label: String) throws -> Set<String> { var labels = read(); labels.insert(label); return try write(labels) }
    func removing(_ label: String) throws -> Set<String> { var labels = read(); labels.remove(label); return try write(labels) }
}

struct LaunchctlResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    var succeeded: Bool { exitCode == 0 }
}

struct BackgroundJobOperationFailure: Error, Equatable, Sendable {
    let message: String
    static func message(action: String, result: LaunchctlResult) -> String {
        let detail = (result.standardError.isEmpty ? result.standardOutput : result.standardError).trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "\(action)失败（launchctl 退出码 \(result.exitCode)）" : "\(action)失败：\(detail)"
    }
}

protocol LaunchctlRunning: Sendable {
    func run(arguments: [String]) async -> LaunchctlResult
}

struct ProcessLaunchctlRunner: LaunchctlRunning {
    let executableURL = URL(fileURLWithPath: "/bin/launchctl")
    func run(arguments: [String]) async -> LaunchctlResult {
        await withCheckedContinuation { continuation in
            let process = Process(); let output = Pipe(); let error = Pipe()
            process.executableURL = executableURL; process.arguments = arguments; process.standardOutput = output; process.standardError = error
            process.terminationHandler = { process in
                continuation.resume(returning: LaunchctlResult(
                    exitCode: process.terminationStatus,
                    standardOutput: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                    standardError: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                ))
            }
            do { try process.run() } catch {
                continuation.resume(returning: LaunchctlResult(exitCode: -1, standardOutput: "", standardError: error.localizedDescription))
            }
        }
    }
}

enum LaunchctlCommandBuilder {
    static func domain(uid: Int32) -> String { "gui/\(uid)" }
    static func bootout(uid: Int32, label: String) -> [String] { ["bootout", "\(domain(uid: uid))/\(label)"] }
    static func disable(uid: Int32, label: String) -> [String] { ["disable", "\(domain(uid: uid))/\(label)"] }
    static func enable(uid: Int32, label: String) -> [String] { ["enable", "\(domain(uid: uid))/\(label)"] }
    static func bootstrap(uid: Int32, plistURL: URL) -> [String] { ["bootstrap", domain(uid: uid), plistURL.path] }
}

struct BackgroundJobsSectionView: View {
    let snapshot: BackgroundJobsSnapshot
    @Binding var showsHealthy: Bool
    var now: Date = Date()
    private var presentation: BackgroundJobsPresentation { BackgroundJobsPresentation(snapshot: snapshot, now: now) }
    var body: some View {
        let p = presentation
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            if p.hasProblems {
                summaryLine(p, discloses: false)
                ForEach(p.problemRows) { problemRow($0) }
                if !p.healthyRows.isEmpty { healthyDisclosure(p) }
            } else if p.healthyRows.isEmpty { summaryLine(p, discloses: false) }
            else {
                Button { withAnimation(.easeInOut(duration: 0.15)) { showsHealthy.toggle() } } label: { summaryLine(p, discloses: true).contentShape(Rectangle()) }.buttonStyle(.plain)
                if showsHealthy { ForEach(p.healthyRows) { healthyRow($0) } }
            }
        }.accessibilityIdentifier("background-jobs-section")
    }
    private func summaryLine(_ p: BackgroundJobsPresentation, discloses: Bool) -> some View {
        HStack(spacing: SentinelTheme.Spacing.md) {
            if discloses { Image(systemName: "chevron.right").rotationEffect(.degrees(showsHealthy ? 90 : 0)).frame(width: SentinelTheme.Metrics.disclosureChevron, height: SentinelTheme.Metrics.disclosureChevron).foregroundStyle(SentinelTheme.Colors.secondaryForeground) }
            Circle().fill(p.hasProblems ? SentinelTheme.Colors.warning : (p.healthyRows.isEmpty ? SentinelTheme.Colors.secondaryForeground : SentinelTheme.Colors.success)).frame(width: SentinelTheme.Metrics.statusDot, height: SentinelTheme.Metrics.statusDot)
            Text(p.summaryText).font(p.hasProblems ? SentinelTheme.Fonts.rowTitle : SentinelTheme.Fonts.subtitle).foregroundStyle(p.hasProblems ? SentinelTheme.Colors.warning : SentinelTheme.Colors.secondaryForeground).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.accessibilityIdentifier("background-jobs-summary").accessibilityLabel(p.summaryText)
    }
    private func problemRow(_ row: BackgroundJobRow) -> some View { VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) { Text(row.name).font(SentinelTheme.Fonts.rowTitle).foregroundStyle(SentinelTheme.Colors.foreground); Text(row.detail).font(SentinelTheme.Fonts.metadata).foregroundStyle(SentinelTheme.Colors.warning).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading).sentinelRow(tone: .warning).accessibilityIdentifier("background-jobs-problem-\(row.id)") }
    private func healthyRow(_ row: BackgroundJobRow) -> some View { VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) { Text(row.name).font(SentinelTheme.Fonts.body).foregroundStyle(SentinelTheme.Colors.foreground); Text(row.detail).font(SentinelTheme.Fonts.metadata).foregroundStyle(SentinelTheme.Colors.secondaryForeground).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading).sentinelRow(tone: .normal).accessibilityIdentifier("background-jobs-ok-\(row.id)") }
    private func healthyDisclosure(_ p: BackgroundJobsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { showsHealthy.toggle() } } label: { HStack { Image(systemName: "chevron.right").rotationEffect(.degrees(showsHealthy ? 90 : 0)); Text("其余正常"); Spacer(); Text("\(p.healthyRows.count)") }.contentShape(Rectangle()) }.buttonStyle(.plain)
            if showsHealthy { VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) { ForEach(p.healthyRows) { healthyRow($0) } }.padding(.top, SentinelTheme.Spacing.sm) }
        }
    }
}
