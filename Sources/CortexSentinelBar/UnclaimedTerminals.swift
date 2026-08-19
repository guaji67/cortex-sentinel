import Foundation

struct UnclaimedTerminalEntry: Identifiable, Equatable {
    let slug: String
    let state: String
    let updatedAt: String
    let exitCode: Int?
    let branch: String?
    let workdir: String?
    let labelZH: String
    let dispatcherZH: String

    var id: String {
        "\(slug)|\(state)|\(updatedAt)"
    }
}

struct TerminalAckRecord: Equatable {
    let state: String
    let updatedAt: String
}

struct TerminalAckLedger: Equatable {
    let acks: [String: TerminalAckRecord]

    static let empty = TerminalAckLedger(acks: [:])

    func matches(slug: String, engine: LineEngine, state: String, updatedAt: String) -> Bool {
        let record = acks[engine.prefixedAckKey(slug: slug)] ?? acks[slug]
        guard let record else {
            return false
        }
        return record.state == state && record.updatedAt == updatedAt
    }
}

enum UnclaimedTerminalAggregation {
    static let window: TimeInterval = 12 * 60 * 60
    static let terminalStates: Set<String> = ["done", "help", "dead", "killed"]

    static func entries(
        lines: [LineStatus],
        registry: CodexLineRegistry,
        ack: TerminalAckLedger,
        now: Date = Date()
    ) -> [UnclaimedTerminalEntry] {
        lines.compactMap { line in
            let state = line.state.wireName
            guard terminalStates.contains(state),
                  let updatedAt = line.updatedAtRaw, !updatedAt.isEmpty
            else {
                return nil
            }
            guard let parsed = line.updatedAt ?? SentinelDateParser.parse(updatedAt) else {
                return nil
            }
            let age = now.timeIntervalSince(parsed)
            guard age >= 0, age <= window else {
                return nil
            }
            guard !ack.matches(slug: line.slug, engine: line.engine, state: state, updatedAt: updatedAt) else {
                return nil
            }
            let registration = registry.registration(for: line.slug)
            return UnclaimedTerminalEntry(
                slug: line.slug,
                state: state,
                updatedAt: updatedAt,
                exitCode: line.exitCode,
                branch: line.branch,
                workdir: line.workdir,
                labelZH: registration?.labelZH ?? "",
                dispatcherZH: registration?.dispatcherZH ?? ""
            )
        }
        .sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.slug < rhs.slug
        }
    }
}

extension SentinelFileReader {
    static func readTerminalAck(
        at url: URL,
        fileManager: FileManager = .default
    ) -> TerminalAckLedger {
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        return parseTerminalAck(data: data)
    }

    static func parseTerminalAck(data: Data) -> TerminalAckLedger {
        guard let payload = try? JSONSerialization.jsonObject(with: data) else {
            return .empty
        }
        let rawAcks: [String: Any]
        if let envelope = payload as? [String: Any],
           let nested = envelope["acks"] as? [String: Any] {
            rawAcks = nested
        } else if let flat = payload as? [String: Any] {
            rawAcks = flat
        } else {
            return .empty
        }

        var acks: [String: TerminalAckRecord] = [:]
        for (slug, value) in rawAcks {
            guard let row = value as? [String: Any],
                  let state = (row["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let updatedAt = (row["updated_at"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !state.isEmpty,
                  !updatedAt.isEmpty
            else {
                continue
            }
            acks[slug] = TerminalAckRecord(state: state, updatedAt: updatedAt)
        }
        return TerminalAckLedger(acks: acks)
    }
}
