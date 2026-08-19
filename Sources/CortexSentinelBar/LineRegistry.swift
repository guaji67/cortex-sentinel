import Foundation

struct CodexLineRegistration: Decodable, Equatable, Sendable {
    let slug: String
    let engine: LineEngine
    let labelZH: String
    let dispatcherZH: String
    let registeredAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case slug
        case engine
        case labelZH = "label_zh"
        case dispatcherZH = "dispatcher_zh"
        case registeredAt = "registered_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        engine = LineEngine(rawValue: try container.decodeIfPresent(String.self, forKey: .engine))
        labelZH = try container.decode(String.self, forKey: .labelZH)
        dispatcherZH = try container.decode(String.self, forKey: .dispatcherZH)
        registeredAt = try container.decodeTimestamp(forKey: .registeredAt)
    }
}

struct CodexLineRegistry: Decodable, Equatable, Sendable {
    let version: Int
    let lines: [CodexLineRegistration]

    static let empty = CodexLineRegistry(version: 0, lines: [])

    init(version: Int, lines: [CodexLineRegistration]) {
        self.version = version
        self.lines = lines
    }

    /// 登记表历史上有两种写法，两种都要认：
    /// 1. 裸数组 `[{...}, {...}]` —— 派工窗口按 CLAUDE.md「追加 {slug, label_zh, ...}」直接写出来的形态，
    ///    也是磁盘上真实文件的形态。
    /// 2. 带信封 `{"version": 1, "lines": [...]}`。
    /// 只认信封会让整张表解不出来、所有线掉进「未登记」，2026-07-25 已实际发生过一次。
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let lines = try? container.decode([LenientRegistration].self) {
            self.version = 1
            self.lines = lines.compactMap(\.value)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let lenient = try container.decodeIfPresent([LenientRegistration].self, forKey: .lines) ?? []
        lines = lenient.compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey {
        case version
        case lines
    }

    func registration(for slug: String) -> CodexLineRegistration? {
        lines.first { $0.slug == slug }
    }
}

/// 单条登记的容错壳：某一条写坏了（缺字段、时间戳格式没见过）只丢那一条，
/// 不能让整张表解不出来。2026-07-25 实际发生过：6 条时间戳漏写时区，
/// 结果 32 条全军覆没、面板上所有线都成了「未登记」。
private struct LenientRegistration: Decodable {
    let value: CodexLineRegistration?

    init(from decoder: Decoder) throws {
        value = try? CodexLineRegistration(from: decoder)
    }
}

enum CodexLineRegistryReader {
    static func read(
        at url: URL,
        fileManager: FileManager = .default
    ) -> CodexLineRegistry {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let registry = decode(data)
        else {
            return .empty
        }
        return registry
    }

    static func decode(_ data: Data) -> CodexLineRegistry? {
        try? JSONDecoder().decode(CodexLineRegistry.self, from: data)
    }
}

struct LinePresentation: Equatable, Identifiable {
    let line: LineStatus
    let registration: CodexLineRegistration?

    var id: String {
        line.id
    }

    /// 状态文件写了 Grok 时，登记表缺 engine 也不能把它画成 Codex。
    /// 旧登记条目没有 engine 字段，解码会落成 Codex；若仍优先登记表，
    /// grok-*.status.json 就会在历史上全部变成 Codex 徽章。
    var engine: LineEngine {
        if line.engine.isCursorGrok {
            return .cursorGrok
        }
        if let registered = registration?.engine, registered.isCursorGrok {
            return .cursorGrok
        }
        return registration?.engine ?? line.engine
    }
}

struct SentinelLineGroups: Equatable {
    let activeRegistered: [LinePresentation]
    let activeUnregistered: [LinePresentation]
    let recentlyCompleted: [LinePresentation]
    let history: [LinePresentation]
}

private extension KeyedDecodingContainer {
    func decodeTimestamp(forKey key: Key) throws -> TimeInterval {
        if let seconds = try? decode(TimeInterval.self, forKey: key) {
            return seconds
        }

        let value = try decode(String.self, forKey: key)
        if let seconds = TimeInterval(value) {
            return seconds
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date.timeIntervalSince1970
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) {
            return date.timeIntervalSince1970
        }

        // 不带时区的本地时间（`2026-07-25T12:45:11`）。Python 的 datetime.isoformat()
        // 默认就不带时区，登记表里真实存在这种写法，按本机时区解。
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            naive.dateFormat = format
            if let date = naive.date(from: value) {
                return date.timeIntervalSince1970
            }
        }

        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "registered_at must be Unix seconds or ISO8601"
        )
    }
}
