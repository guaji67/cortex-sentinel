import Foundation

struct BackgroundJob: Codable, Equatable, Identifiable, Sendable {
    let label: String
    let name: String
    let status: String
    let statusText: String?
    let reason: String?
    let plistStatus: String?

    var id: String { label }

    var displayName: String {
        name.isEmpty ? label : name
    }

    init(
        label: String,
        name: String = "",
        status: String = "unknown",
        statusText: String? = nil,
        reason: String? = nil,
        plistStatus: String? = nil
    ) {
        self.label = label
        self.name = name
        self.status = status
        self.statusText = statusText
        self.reason = reason
        self.plistStatus = plistStatus
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case name
        case status
        case statusText = "status_text"
        case reason
        case plistStatus = "plist_status"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decode(String.self, forKey: .label)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        statusText = try values.decodeIfPresent(String.self, forKey: .statusText)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        plistStatus = try values.decodeIfPresent(String.self, forKey: .plistStatus)
    }
}

struct BackgroundJobRow: Equatable, Identifiable, Sendable {
    let job: BackgroundJob
    let isDisabled: Bool

    var id: String { job.id }
}

enum BackgroundJobsConstants {
    static let criticalLabels: Set<String> = [
        "com.falcon.cortex.web",
        "com.falcon.cortex.web-guard",
        "com.falcon.cortex.memory-monitor",
        "com.falcon.cortex.mini-mirror-sync",
    ]
}

enum BackgroundJobsPresentation {
    static func merge(
        jobs: [BackgroundJob],
        disabledLabels: Set<String>
    ) -> [BackgroundJobRow] {
        var byLabel = Dictionary(uniqueKeysWithValues: jobs.map { ($0.label, $0) })
        for label in disabledLabels where byLabel[label] == nil {
            byLabel[label] = BackgroundJob(
                label: label,
                status: "disabled",
                statusText: "已关闭"
            )
        }
        return byLabel.values
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            .map { BackgroundJobRow(job: $0, isDisabled: disabledLabels.contains($0.label)) }
    }
}

enum BackgroundJobsReader {
    private struct Payload: Decodable {
        let jobs: [BackgroundJob]
    }

    static func read(at url: URL, fileManager: FileManager = .default) -> [BackgroundJob] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return []
        }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return payload.jobs
        }
        return (try? JSONDecoder().decode([BackgroundJob].self, from: data)) ?? []
    }
}

struct DisabledJobsStore {
    let url: URL
    let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func read() -> Set<String> {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let labels = try JSONDecoder().decode([String].self, from: data)
            return Set(labels.filter { !$0.isEmpty })
        } catch {
            return []
        }
    }

    @discardableResult
    func write(_ labels: Set<String>) throws -> Set<String> {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(labels.sorted())
        try data.write(to: url, options: .atomic)
        return labels
    }

    func adding(_ label: String) throws -> Set<String> {
        var labels = read()
        labels.insert(label)
        return try write(labels)
    }

    func removing(_ label: String) throws -> Set<String> {
        var labels = read()
        labels.remove(label)
        return try write(labels)
    }
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
        let detail = (result.standardError.isEmpty ? result.standardOutput : result.standardError)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "\(action)失败（launchctl 退出码 \(result.exitCode)）"
        }
        return "\(action)失败：\(detail)"
    }
}

protocol LaunchctlRunning {
    func run(arguments: [String]) async -> LaunchctlResult
}

struct ProcessLaunchctlRunner: LaunchctlRunning {
    let executableURL = URL(fileURLWithPath: "/bin/launchctl")

    func run(arguments: [String]) async -> LaunchctlResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError
            process.terminationHandler = { process in
                let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
                let error = standardError.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: LaunchctlResult(
                        exitCode: process.terminationStatus,
                        standardOutput: String(data: output, encoding: .utf8) ?? "",
                        standardError: String(data: error, encoding: .utf8) ?? ""
                    )
                )
            }
            do {
                try process.run()
            } catch {
                continuation.resume(
                    returning: LaunchctlResult(
                        exitCode: -1,
                        standardOutput: "",
                        standardError: error.localizedDescription
                    )
                )
            }
        }
    }
}

enum LaunchctlCommandBuilder {
    static func domain(uid: Int32) -> String {
        "gui/\(uid)"
    }

    static func bootout(uid: Int32, label: String) -> [String] {
        ["bootout", "\(domain(uid: uid))/\(label)"]
    }

    static func disable(uid: Int32, label: String) -> [String] {
        ["disable", "\(domain(uid: uid))/\(label)"]
    }

    static func enable(uid: Int32, label: String) -> [String] {
        ["enable", "\(domain(uid: uid))/\(label)"]
    }

    static func bootstrap(uid: Int32, plistURL: URL) -> [String] {
        ["bootstrap", domain(uid: uid), plistURL.path]
    }
}
