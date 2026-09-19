import Darwin
import Foundation

/// Cortex 打包进度（cortex.packaging-progress.v1）。
/// 数据由 Cortex 主仓 scripts/packaging_progress.py 写：稳定登记落点
/// <数据根>/health/pack-progress.json（COR-7589 起，同一份载荷多一个
/// progress_file 指针），旧私有落点 $TMPDIR/cortex-pack-progress 仍在写、
/// 作兜底（COR-7600）。这里只读：稳定落点是单文件；旧落点目录下每个 run
/// 一个子目录，各含一份 progress.json，取 updated_at 最新的一份。
enum PackagingProgressStatus: Equatable {
    case running
    case failed
    case completed
    case unknown(String)

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "running":
            self = .running
        case "failed":
            self = .failed
        case "completed":
            self = .completed
        case let value?:
            self = .unknown(value)
        default:
            self = .unknown("")
        }
    }

    var isRunning: Bool {
        self == .running
    }

    var displayName: String {
        switch self {
        case .running:
            return "running"
        case .failed:
            return "failed"
        case .completed:
            return "completed"
        case let .unknown(value):
            return value.isEmpty ? "unknown" : value
        }
    }
}

struct PackagingProgressStep: Decodable, Equatable {
    let id: String
    let title: String?
    let status: String?
    let durationMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case durationMilliseconds = "duration_ms"
    }
}

struct PackagingProgressSnapshot: Decodable, Equatable {
    let schema: String?
    let runID: String?
    let entry: String?
    /// 这一炉的版本号（主仓起炉时写进 payload 的 identity[1]）。
    let version: String?
    /// 稳定登记落点独有的指针字段：指回私有落点的 progress.json（COR-7589）。
    let progressFile: String?
    let status: PackagingProgressStatus
    let processID: Int?
    let processStartedAt: String?
    let currentStepID: String?
    let currentDetail: String?
    let error: String?
    let etaMilliseconds: Int?
    let etaLabel: String?
    let etaIsEstimate: Bool?
    let etaBasis: String?
    let startedAt: Date?
    let updatedAt: Date?
    let steps: [PackagingProgressStep]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case entry
        case version
        case progressFile = "progress_file"
        case status
        case processID = "pid"
        case processStartedAt = "process_started_at"
        case pidStartedAt = "pid_started_at"
        case processStartTime = "process_start_time"
        case currentStepID = "current_step_id"
        case currentDetail = "current_detail"
        case error
        case etaMilliseconds = "eta_ms"
        case etaLabel = "eta_label"
        case etaIsEstimate = "eta_is_estimate"
        case etaBasis = "eta_basis"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
        entry = try container.decodeIfPresent(String.self, forKey: .entry)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        progressFile = try container.decodeIfPresent(String.self, forKey: .progressFile)
        status = PackagingProgressStatus(
            rawValue: try container.decodeIfPresent(String.self, forKey: .status)
        )
        if let pid = try container.decodeIfPresent(Int.self, forKey: .processID) {
            processID = pid
        } else if let rawPID = try container.decodeIfPresent(String.self, forKey: .processID) {
            processID = Int(rawPID.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            processID = nil
        }
        let processStartCandidates = [
            try container.decodeIfPresent(String.self, forKey: .processStartedAt),
            try container.decodeIfPresent(String.self, forKey: .pidStartedAt),
            try container.decodeIfPresent(String.self, forKey: .processStartTime),
        ]
        if let processStart = processStartCandidates.first(where: { $0 != nil }), let processStart {
            processStartedAt = processStart.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            processStartedAt = nil
        }
        currentStepID = try container.decodeIfPresent(String.self, forKey: .currentStepID)
        currentDetail = try container.decodeIfPresent(String.self, forKey: .currentDetail)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        etaMilliseconds = try container.decodeIfPresent(Int.self, forKey: .etaMilliseconds)
        etaLabel = try container.decodeIfPresent(String.self, forKey: .etaLabel)
        etaIsEstimate = try container.decodeIfPresent(Bool.self, forKey: .etaIsEstimate)
        etaBasis = try container.decodeIfPresent(String.self, forKey: .etaBasis)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
            .flatMap { SentinelDateParser.parse($0) }
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
            .flatMap { SentinelDateParser.parse($0) }
        steps = try container.decodeIfPresent([PackagingProgressStep].self, forKey: .steps) ?? []
    }

    /// 只有通过与 Python 正本相同的四道判活闸才算活跃；过期残留不占界面。
    var isActive: Bool {
        isActive(using: .live)
    }

    func isActive(
        using probe: PackagingProgressActivityProbe,
        now: Date = Date(),
        staleAfterSeconds: TimeInterval = PackagingProgressActivity.runningStaleAfterSeconds
    ) -> Bool {
        guard status.isRunning,
              let processID,
              processID > 0,
              probe.pidAlive(processID),
              let expectedStartedAt = processStartedAt,
              !expectedStartedAt.isEmpty,
              probe.processStartedAt(processID).trimmingCharacters(in: .whitespacesAndNewlines)
                == expectedStartedAt.trimmingCharacters(in: .whitespacesAndNewlines),
              let updatedAt
        else {
            return false
        }

        // 与 scripts/packaging_progress.py:148-196 保持一致：正本只用 updated_at
        // 判 heartbeat 窗口。heartbeat_at 目前不是生产写入字段，不能在 Swift 侧
        // 偷换成另一套规则，否则两边会对同一份记录给出不同结论。
        return now.timeIntervalSince(updatedAt)
            <= max(0, staleAfterSeconds)
    }

    var stepTitle: String {
        if let currentStepID,
           let title = steps.first(where: { $0.id == currentStepID })?.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return title
        }
        if let currentDetail = normalized(currentDetail) {
            return currentDetail
        }
        return "准备中"
    }

    var detailText: String? {
        guard let currentDetail = normalized(currentDetail), currentDetail != stepTitle else {
            return nil
        }
        return currentDetail
    }

    var etaText: String {
        normalized(etaLabel) ?? "剩余时间估计中"
    }

    /// 预计几点出包：现在 + eta_ms 折成钟点。Falcon 原话要的是个钟点，
    /// 不是「还要多久」；没有 eta_ms 给 nil。
    var etaArrivalText: String? {
        guard let etaMilliseconds, etaMilliseconds > 0 else {
            return nil
        }
        let arrival = Date().addingTimeInterval(TimeInterval(etaMilliseconds) / 1000)
        return "预计 \(SentinelTimeFormat.clockTime(arrival))"
    }

    /// 右上角一句话：时长 + 钟点都要（「大约还要 12 分钟 · 预计 10:22」）。
    var etaDisplayText: String {
        if let etaArrivalText {
            return "\(etaText) · \(etaArrivalText)"
        }
        return etaText
    }

    /// 哪一炉：版本优先，没有版本退 run_id；两样都没有给 nil。
    var furnaceText: String? {
        normalized(version) ?? normalized(runID)
    }

    /// 第几步：current_step_id 在 steps 里的位次（1 起）；对不上给 nil。
    var stepProgressText: String? {
        guard let currentStepID,
              let index = steps.firstIndex(where: { $0.id == currentStepID })
        else {
            return nil
        }
        return "第 \(index + 1)/\(steps.count) 步"
    }

    var accessibilityText: String {
        var parts = ["Cortex 打包中"]
        if let furnace = furnaceText {
            parts.append(furnace)
        }
        if let stepProgress = stepProgressText {
            parts.append(stepProgress)
        }
        parts.append(stepTitle)
        parts.append(etaDisplayText)
        if let detailText {
            parts.append(detailText)
        }
        return parts.joined(separator: "，")
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 打包进度判活所需的系统探针。测试可注入闭包，生产读取使用 macOS 实际进程表。
struct PackagingProgressActivityProbe {
    let pidAlive: (Int) -> Bool
    let processStartedAt: (Int) -> String

    static let live = PackagingProgressActivityProbe(
        pidAlive: PackagingProgressActivity.isPIDAlive,
        processStartedAt: PackagingProgressActivity.processStartedAt
    )
}

enum PackagingProgressActivity {
    /// 单一窗口常量的来源是主仓 Python 正本 `scripts/packaging_progress.py:61`。
    /// 若 Python 正本调整该值，必须同步这里并由单元测试的契约断言拦住漂移。
    static let runningStaleAfterSeconds: TimeInterval = 30 * 60

    static func isPIDAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        if Darwin.kill(Int32(pid), 0) == 0 {
            return true
        }
        // 与 Python `_pid_alive` 一致：权限被拒也说明该 PID 仍存在。
        return errno == EPERM
    }

    static func processStartedAt(_ pid: Int) -> String {
        guard pid > 0 else { return "" }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart="]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        guard process.terminationStatus == 0 else { return "" }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum PackagingProgressReader {
    /// 面板读侧三态 reason 文案，与主仓 scripts/packaging_progress.py 的
    /// `pack_telemetry_section()` 保持一致：跨语言对同一份文件给同一句话。
    enum Reasons {
        static let idleNoMirrorFile = "当前没有在跑的炉（稳定落点还没有登记文件）"
        static let idleNotRunning = "当前没有在跑的炉"
        static let unreadableMirrorFile = "登记文件读不了或不是 JSON"
        static let unresolvableDataRoot = "解析不了稳定落点（数据根与显式覆盖都不可用）"
    }

    /// 稳定落点优先，读不到再退回旧私有落点（COR-7600）。顺序不许反：旧
    /// $TMPDIR 落点只是兜底，稳定落点在就必须以它为准。
    ///
    /// 与 pack_telemetry_section() 的语义差异只有一处：数据根解析不出来时，
    /// 旧落点里若还有活线快照照样报 running——不让解析失败把在跑的炉藏成
    /// error；除此之外 error / idle 划分与遥测读侧一致，error 不许被兜底
    /// 洗成 idle。
    static func read(
        stableURL: URL?,
        legacyRoot: URL,
        fileManager: FileManager = .default
    ) -> PackagingProgressReading {
        guard let stableURL else {
            if case let .running(active) = readLegacyFallback(root: legacyRoot, fileManager: fileManager) {
                return .running(active)
            }
            return .error(reason: Reasons.unresolvableDataRoot)
        }
        guard fileManager.fileExists(atPath: stableURL.path) else {
            return readLegacyFallback(root: legacyRoot, fileManager: fileManager)
        }
        guard let data = try? Data(contentsOf: stableURL),
              let snapshot = try? JSONDecoder().decode(PackagingProgressSnapshot.self, from: data)
        else {
            // 登记文件在但读不了 = 数据通道坏了：报 error，不退回旧落点装没事。
            return .error(reason: Reasons.unreadableMirrorFile)
        }
        return projected(from: snapshot)
    }

    static func read(
        at root: URL,
        fileManager: FileManager = .default
    ) -> PackagingProgressSnapshot? {
        let candidates: [URL]
        if root.lastPathComponent == "progress.json" {
            candidates = [root]
        } else if fileManager.fileExists(atPath: root.appendingPathComponent("progress.json").path) {
            candidates = [root.appendingPathComponent("progress.json")]
        } else {
            candidates = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?
                .map { $0.appendingPathComponent("progress.json") }
                .filter { fileManager.fileExists(atPath: $0.path) } ?? []
        }

        return candidates.compactMap { url -> (PackagingProgressSnapshot, Date)? in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(PackagingProgressSnapshot.self, from: data)
            else {
                return nil
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (snapshot, snapshot.updatedAt ?? modified)
        }
        .max { lhs, rhs in lhs.1 < rhs.1 }?.0
    }

    /// 旧私有落点兜底：活线 → running；残留 → idle（残留就是上一炉）；
    /// 什么都没有 → idle（稳定落点还没有登记文件）。
    private static func readLegacyFallback(
        root: URL,
        fileManager: FileManager
    ) -> PackagingProgressReading {
        if let residue = read(at: root, fileManager: fileManager) {
            if residue.isActive {
                return .running(residue)
            }
            return .idle(reason: Reasons.idleNoMirrorFile, lastRun: residue)
        }
        return .idle(reason: Reasons.idleNoMirrorFile, lastRun: nil)
    }

    /// 对一份已解析的载荷做 running / idle 投影。判活只认 isActive 这一套
    /// 四道闸（status=running + PID 探活 + process_started_at 一致 +
    /// updated_at 在 30 分钟内），与主仓 read_progress_payload 同一套，
    /// 不在这里另写判定。
    private static func projected(from snapshot: PackagingProgressSnapshot) -> PackagingProgressReading {
        if snapshot.isActive {
            return .running(snapshot)
        }
        return .idle(reason: Reasons.idleNotRunning, lastRun: snapshot)
    }
}

/// 面板读侧三态（COR-7600），与主仓 scripts/packaging_progress.py 的
/// `pack_telemetry_section()` 同一套投影：running / idle / error 互斥可辨，
/// 「没在打包」和「没拿到数据」不许在界面上合成一句。
enum PackagingProgressReading: Equatable {
    /// 有炉在跑：快照已过四道活线闸（PackagingProgressSnapshot.isActive）。
    case running(PackagingProgressSnapshot)
    /// 没在打包：reason 是读侧原话；lastRun 是上一炉的残留快照（可能没有）。
    case idle(reason: String, lastRun: PackagingProgressSnapshot?)
    /// 没拿到数据：登记文件读不了或数据根解析不出来。
    case error(reason: String)
}
