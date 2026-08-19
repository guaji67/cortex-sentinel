import Foundation
import XCTest
@testable import CortexSentinelBar

final class UnclaimedTerminalTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-08-19T04:00:00Z")!

    func testUnclaimedKeepsVisibleUntilMatchingSignatureAcked() throws {
        let registry = try makeRegistry([
            ("wake-a", "叫醒全场", "主控窗口派四条 Grok"),
        ])
        let lines = [
            makeLine(slug: "wake-a", state: .done, updatedAt: "2026-08-19T03:30:00Z"),
            makeLine(slug: "still-on", state: .running, updatedAt: "2026-08-19T03:30:00Z"),
            makeLine(slug: "too-old", state: .help, updatedAt: "2026-08-18T10:00:00Z"),
        ]

        let shown = UnclaimedTerminalAggregation.entries(
            lines: lines,
            registry: registry,
            ack: .empty,
            now: now
        )
        XCTAssertEqual(shown.map(\.slug), ["wake-a"])
        XCTAssertEqual(shown[0].state, "done")
        XCTAssertEqual(shown[0].dispatcherZH, "主控窗口派四条 Grok")
        XCTAssertEqual(shown[0].labelZH, "叫醒全场")

        let acked = TerminalAckLedger(acks: [
            "wake-a": TerminalAckRecord(state: "done", updatedAt: "2026-08-19T03:30:00Z"),
        ])
        XCTAssertTrue(
            UnclaimedTerminalAggregation.entries(
                lines: lines,
                registry: registry,
                ack: acked,
                now: now
            ).isEmpty
        )
    }

    func testSameSlugNewUpdatedAtReappearsAfterOldAck() throws {
        let lines = [
            makeLine(slug: "one", state: .done, updatedAt: "2026-08-19T03:50:00Z"),
        ]
        let oldAck = TerminalAckLedger(acks: [
            "one": TerminalAckRecord(state: "help", updatedAt: "2026-08-19T03:10:00Z"),
        ])
        let shown = UnclaimedTerminalAggregation.entries(
            lines: lines,
            registry: .empty,
            ack: oldAck,
            now: now
        )
        XCTAssertEqual(shown.map(\.slug), ["one"])
        XCTAssertEqual(shown[0].state, "done")
        XCTAssertEqual(shown[0].updatedAt, "2026-08-19T03:50:00Z")
    }

    func testBadAckJSONIsEmptyLedgerAndDoesNotHideTerminals() {
        let ledger = SentinelFileReader.parseTerminalAck(data: Data("{not json".utf8))
        XCTAssertEqual(ledger, .empty)

        let shown = UnclaimedTerminalAggregation.entries(
            lines: [makeLine(slug: "good", state: .killed, updatedAt: "2026-08-19T03:40:00Z")],
            registry: .empty,
            ack: ledger,
            now: now
        )
        XCTAssertEqual(shown.map(\.slug), ["good"])
    }

    func testPrefixedEngineSlugAckKeyCountsAsClaimed() {
        let ledger = TerminalAckLedger(acks: [
            "grok:foo": TerminalAckRecord(state: "done", updatedAt: "2026-08-19T03:30:00Z"),
        ])
        XCTAssertTrue(
            ledger.matches(slug: "foo", engine: .cursorGrok, state: "done", updatedAt: "2026-08-19T03:30:00Z")
        )
        XCTAssertTrue(
            UnclaimedTerminalAggregation.entries(
                lines: [makeLine(slug: "foo", state: .done, updatedAt: "2026-08-19T03:30:00Z")],
                registry: .empty,
                ack: ledger,
                now: now
            ).isEmpty
        )
    }

    func testEmptyWhenNoTerminalsInWindow() {
        let shown = UnclaimedTerminalAggregation.entries(
            lines: [makeLine(slug: "run", state: .running, updatedAt: "2026-08-19T03:40:00Z")],
            registry: .empty,
            ack: .empty,
            now: now
        )
        XCTAssertTrue(shown.isEmpty)
    }

    func testParseAckEnvelopeAndMissingUpdatedAtRawIsSkipped() throws {
        let json = """
        {"acks":{"wake-a":{"state":"done","updated_at":"2026-08-19T03:30:00Z"}}}
        """.data(using: .utf8)!
        let ledger = SentinelFileReader.parseTerminalAck(data: json)
        XCTAssertTrue(ledger.matches(slug: "wake-a", engine: .cursorGrok, state: "done", updatedAt: "2026-08-19T03:30:00Z"))
        XCTAssertFalse(ledger.matches(slug: "wake-a", engine: .cursorGrok, state: "done", updatedAt: "other"))

        let withoutRaw = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/grok-missing.status.json"),
            slug: "missing",
            engine: .cursorGrok,
            workdir: nil,
            branch: nil,
            state: .done,
            restarts: 0,
            reportsRestarts: false,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now,
            relay: nil,
            updatedAtRaw: nil
        )
        XCTAssertTrue(
            UnclaimedTerminalAggregation.entries(
                lines: [withoutRaw],
                registry: .empty,
                ack: .empty,
                now: now
            ).isEmpty
        )
    }

    private func makeRegistry(
        _ rows: [(slug: String, label: String, dispatcher: String)]
    ) throws -> CodexLineRegistry {
        let objects = rows.map { row -> [String: Any] in
            [
                "slug": row.slug,
                "engine": "cursor-grok",
                "label_zh": row.label,
                "dispatcher_zh": row.dispatcher,
                "registered_at": now.timeIntervalSince1970,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: objects)
        return try XCTUnwrap(CodexLineRegistryReader.decode(data))
    }

    private func makeLine(slug: String, state: LineState, updatedAt: String) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/grok-\(slug).status.json"),
            slug: slug,
            engine: .cursorGrok,
            workdir: "/tmp/\(slug)",
            branch: "codex/\(slug)",
            state: state,
            restarts: 0,
            reportsRestarts: false,
            rolloutAgeSeconds: nil,
            updatedAt: SentinelDateParser.parse(updatedAt),
            sourceModifiedAt: SentinelDateParser.parse(updatedAt),
            exitCode: 0,
            relay: nil,
            updatedAtRaw: updatedAt
        )
    }
}
