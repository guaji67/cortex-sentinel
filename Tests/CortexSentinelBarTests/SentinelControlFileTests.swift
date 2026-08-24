import XCTest
@testable import CortexSentinelBar

final class SentinelControlFileTests: XCTestCase {
    private let fileManager = FileManager.default
    private var logsDirectory: URL!

    override func setUpWithError() throws {
        logsDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CortexSentinelControl-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: logsDirectory)
    }

    func testAtomicMergePreservesSettingsAndPendingProbe() throws {
        let target = try SentinelControlFile.controlURL(
            slug: "waiting-line",
            logsDirectory: logsDirectory
        )
        try Data(
            """
            {
              "max_restarts_override": 7,
              "escalate_after_failures": 4,
              "future_field": "keep"
            }
            """.utf8
        ).write(to: target)

        try SentinelControlFile.requestProbe(
            slug: "waiting-line",
            logsDirectory: logsDirectory,
            now: date("2026-08-02T08:10:00Z")
        )
        try SentinelControlFile.updateSettings(
            slug: "waiting-line",
            maxRestartsOverride: 9,
            escalateAfterFailures: 5,
            logsDirectory: logsDirectory,
            now: date("2026-08-02T08:11:00Z")
        )

        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
        )
        XCTAssertEqual(payload["action"] as? String, "probe_now")
        XCTAssertEqual(payload["requested_at"] as? String, "2026-08-02T08:10:00Z")
        XCTAssertEqual(payload["max_restarts_override"] as? Int, 9)
        XCTAssertEqual(payload["escalate_after_failures"] as? Int, 5)
        XCTAssertEqual(payload["updated_at"] as? String, "2026-08-02T08:11:00Z")
        XCTAssertEqual(payload["future_field"] as? String, "keep")

        let files = try fileManager.contentsOfDirectory(atPath: logsDirectory.path)
        XCTAssertEqual(files, [target.lastPathComponent])
    }

    func testForceStartWritesPanelRequestContractAndPreservesSettings() throws {
        let target = try SentinelControlFile.controlURL(
            slug: "manual-line",
            logsDirectory: logsDirectory
        )
        try Data(#"{"max_restarts_override":7}"#.utf8).write(to: target)

        let written = try SentinelControlFile.requestForceStart(
            slug: "manual-line",
            logsDirectory: logsDirectory,
            now: date("2026-08-24T08:10:00Z")
        )

        XCTAssertEqual(written, target)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
        )
        XCTAssertEqual(payload["action"] as? String, "force_start")
        XCTAssertEqual(payload["requested_at"] as? String, "2026-08-24T08:10:00Z")
        XCTAssertEqual(payload["requested_by"] as? String, "cortex_sentinel_panel")
        XCTAssertEqual(payload["max_restarts_override"] as? Int, 7)
    }

    func testSettingsAcceptContractBoundaryValues() throws {
        try SentinelControlFile.updateSettings(
            slug: "boundary.line-1",
            maxRestartsOverride: 0,
            escalateAfterFailures: 1,
            logsDirectory: logsDirectory
        )
        XCTAssertEqual(
            try SentinelControlFile.readSettings(
                slug: "boundary.line-1",
                logsDirectory: logsDirectory
            ),
            SentinelControlSettings(maxRestartsOverride: 0, escalateAfterFailures: 1)
        )

        try SentinelControlFile.updateSettings(
            slug: "boundary.line-1",
            maxRestartsOverride: 100,
            escalateAfterFailures: 100,
            logsDirectory: logsDirectory
        )
        XCTAssertEqual(
            try SentinelControlFile.readSettings(
                slug: "boundary.line-1",
                logsDirectory: logsDirectory
            ),
            SentinelControlSettings(maxRestartsOverride: 100, escalateAfterFailures: 100)
        )
    }

    func testInvalidValuesAndSlugAreRejectedBeforeWriting() {
        XCTAssertThrowsError(
            try SentinelControlFile.updateSettings(
                slug: "line",
                maxRestartsOverride: -1,
                escalateAfterFailures: 1,
                logsDirectory: logsDirectory
            )
        ) { error in
            XCTAssertEqual(error as? SentinelControlError, .invalidMaxRestarts)
        }
        XCTAssertThrowsError(
            try SentinelControlFile.updateSettings(
                slug: "line",
                maxRestartsOverride: 101,
                escalateAfterFailures: 1,
                logsDirectory: logsDirectory
            )
        )
        XCTAssertThrowsError(
            try SentinelControlFile.updateSettings(
                slug: "line",
                maxRestartsOverride: 7,
                escalateAfterFailures: 0,
                logsDirectory: logsDirectory
            )
        ) { error in
            XCTAssertEqual(error as? SentinelControlError, .invalidEscalationThreshold)
        }
        XCTAssertThrowsError(
            try SentinelControlFile.updateSettings(
                slug: "line",
                maxRestartsOverride: 7,
                escalateAfterFailures: 101,
                logsDirectory: logsDirectory
            )
        )
        XCTAssertThrowsError(
            try SentinelControlFile.requestProbe(
                slug: "../real-line",
                logsDirectory: logsDirectory
            )
        ) { error in
            XCTAssertEqual(error as? SentinelControlError, .invalidSlug)
        }
        XCTAssertEqual(try? fileManager.contentsOfDirectory(atPath: logsDirectory.path), [])
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
