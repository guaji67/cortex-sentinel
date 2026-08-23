import Foundation

/// Cortex 打包进度（cortex.packaging-progress.v1）。
/// 数据由 Cortex 主仓 scripts/packaging_progress.py 写进 $TMPDIR/cortex-pack-progress，
/// 这里只读：目录下每个 run 一个子目录，各含一份 progress.json，取 updated_at 最新的一份。
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
    let status: PackagingProgressStatus
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
        case status
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
        status = PackagingProgressStatus(
            rawValue: try container.decodeIfPresent(String.self, forKey: .status)
        )
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

    /// 只有 running 才算活跃；failed / completed 的残留文件不该占着界面。
    var isActive: Bool {
        status.isRunning
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

    var accessibilityText: String {
        var parts = ["Cortex 打包中", stepTitle, etaText]
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

enum PackagingProgressReader {
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
}
