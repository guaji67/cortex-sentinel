import Darwin
import Foundation

struct SentinelControlSettings: Equatable {
    let maxRestartsOverride: Int?
    let escalateAfterFailures: Int?
}

enum SentinelControlError: LocalizedError, Equatable {
    case invalidSlug
    case invalidMaxRestarts
    case invalidEscalationThreshold

    var errorDescription: String? {
        switch self {
        case .invalidSlug:
            return "任务标识格式无效"
        case .invalidMaxRestarts:
            return "最多重试须为 0 到 100"
        case .invalidEscalationThreshold:
            return "上报门槛须为 1 到 100"
        }
    }
}

enum SentinelControlFile {
    private static let slugPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._-]+$"#)

    @discardableResult
    static func requestProbe(
        slug: String,
        logsDirectory: URL,
        now: Date = Date()
    ) throws -> URL {
        try writeMerged(
            slug: slug,
            logsDirectory: logsDirectory,
            values: [
                "action": "probe_now",
                "requested_at": timestamp(now),
            ]
        )
    }

    @discardableResult
    static func updateSettings(
        slug: String,
        maxRestartsOverride: Int,
        escalateAfterFailures: Int,
        logsDirectory: URL,
        now: Date = Date()
    ) throws -> URL {
        guard 0...100 ~= maxRestartsOverride else {
            throw SentinelControlError.invalidMaxRestarts
        }
        guard 1...100 ~= escalateAfterFailures else {
            throw SentinelControlError.invalidEscalationThreshold
        }
        return try writeMerged(
            slug: slug,
            logsDirectory: logsDirectory,
            values: [
                "max_restarts_override": maxRestartsOverride,
                "escalate_after_failures": escalateAfterFailures,
                "updated_at": timestamp(now),
            ]
        )
    }

    static func readSettings(slug: String, logsDirectory: URL) throws -> SentinelControlSettings {
        let url = try controlURL(slug: slug, logsDirectory: logsDirectory)
        let payload = readPayload(at: url)
        return SentinelControlSettings(
            maxRestartsOverride: integer(payload["max_restarts_override"]),
            escalateAfterFailures: integer(payload["escalate_after_failures"])
        )
    }

    static func controlURL(slug: String, logsDirectory: URL) throws -> URL {
        let range = NSRange(slug.startIndex..<slug.endIndex, in: slug)
        guard !slug.isEmpty,
              slugPattern.firstMatch(in: slug, range: range)?.range == range
        else {
            throw SentinelControlError.invalidSlug
        }
        return logsDirectory.appendingPathComponent(
            "codex-babysitter-\(slug).control.json",
            isDirectory: false
        )
    }

    private static func writeMerged(
        slug: String,
        logsDirectory: URL,
        values: [String: Any]
    ) throws -> URL {
        let fileManager = FileManager.default
        let target = try controlURL(slug: slug, logsDirectory: logsDirectory)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        var payload = readPayload(at: target)
        values.forEach { payload[$0.key] = $0.value }
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )

        let temporary = logsDirectory.appendingPathComponent(
            ".\(target.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: temporary)
        }
        try data.write(to: temporary, options: .withoutOverwriting)
        try atomicRename(from: temporary, to: target)
        return target
    }

    private static func readPayload(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else {
            return [:]
        }
        return payload
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.intValue
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func atomicRename(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result != 0 else {
            return
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
