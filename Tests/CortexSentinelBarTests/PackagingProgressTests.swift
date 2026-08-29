import XCTest
@testable import CortexSentinelBar

final class PackagingProgressTests: XCTestCase {
    func testReaderSelectsLatestRunAndDecodesCurrentStepAndETA() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexPackagingProgress-\(UUID().uuidString)", isDirectory: true)
        let older = root.appendingPathComponent("older", isDirectory: true)
        let latest = root.appendingPathComponent("latest", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: latest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let pid = currentProcessID
        let processStartedAt = PackagingProgressActivity.processStartedAt(pid)
        try progressJSON(status: "completed", updatedAt: now.addingTimeInterval(-1))
            .write(to: older.appendingPathComponent("progress.json"))
        try progressJSON(
            status: "running",
            pid: pid,
            processStartedAt: processStartedAt,
            updatedAt: now,
            extra: ["unknown_future_field": ["ignored": true]]
        ).write(to: latest.appendingPathComponent("progress.json"))

        let snapshot = try XCTUnwrap(PackagingProgressReader.read(at: root))
        XCTAssertEqual(snapshot.runID, "fixture-run")
        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.stepTitle, "构建 App 与 zip")
        XCTAssertEqual(snapshot.detailText, "Electron 打包")
        XCTAssertEqual(snapshot.etaText, "大约还要 12 分钟")
        XCTAssertTrue(snapshot.accessibilityText.contains("构建 App 与 zip"))
    }

    func testReaderReturnsCompletedSnapshotWithoutMakingItActive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexPackagingProgressCompleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(
            #"{"status":"completed","updated_at":"2026-08-22T15:00:00Z","future":true}"#.utf8
        ).write(to: root.appendingPathComponent("progress.json"))

        let snapshot = try XCTUnwrap(
            PackagingProgressReader.read(at: root.appendingPathComponent("progress.json"))
        )
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.status, .completed)
    }

    func testReaderDoesNotShowDeadRunningProcessAsActive() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        let deadPID = Int(child.processIdentifier)
        child.waitUntilExit()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexPackagingProgressDead-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try progressJSON(
            status: "running",
            pid: deadPID,
            processStartedAt: "dead-process-(deadPID)",
            updatedAt: Date()
        ).write(to: root.appendingPathComponent("progress.json"))

        let snapshot = try XCTUnwrap(PackagingProgressReader.read(at: root))
        XCTAssertFalse(snapshot.isActive)
    }

    func testStatusBarGetsAnExplicitPackagingSegmentOnlyWhileRunning() throws {
        let snapshot = try JSONDecoder().decode(
            PackagingProgressSnapshot.self,
            from: progressJSON(
                status: "running",
                pid: currentProcessID,
                processStartedAt: PackagingProgressActivity.processStartedAt(currentProcessID),
                updatedAt: Date(),
                extra: ["eta_label": "大约还要 12 分钟"]
            )
        )
        let idle = SentinelStatusBarRenderer.image(probes: [], balances: [])
        let active = SentinelStatusBarRenderer.image(
            probes: [],
            balances: [],
            packaging: snapshot
        )

        XCTAssertGreaterThan(active.size.width, idle.size.width)
        XCTAssertNotNil(active.tiffRepresentation)
    }

    func testRunningProgressWithDeadPIDIsNotActive() throws {
        let now = Date()
        let snapshot = try decodeRunningSnapshot(
            pid: 42,
            processStartedAt: "boot-42",
            updatedAt: now
        )
        let probe = PackagingProgressActivityProbe(
            pidAlive: { _ in false },
            processStartedAt: { _ in "boot-42" }
        )

        XCTAssertFalse(snapshot.isActive(using: probe, now: now))
    }

    func testRunningProgressWithReusedPIDIsNotActive() throws {
        let now = Date()
        let snapshot = try decodeRunningSnapshot(
            pid: 42,
            processStartedAt: "old-boot-42",
            updatedAt: now
        )
        let probe = PackagingProgressActivityProbe(
            pidAlive: { _ in true },
            processStartedAt: { _ in "new-boot-42" }
        )

        XCTAssertFalse(snapshot.isActive(using: probe, now: now))
    }

    func testRunningProgressWithStaleUpdatedAtIsNotActive() throws {
        let updatedAt = Date()
        let snapshot = try decodeRunningSnapshot(
            pid: 42,
            processStartedAt: "boot-42",
            updatedAt: updatedAt
        )
        let probe = PackagingProgressActivityProbe(
            pidAlive: { _ in true },
            processStartedAt: { _ in "boot-42" }
        )

        XCTAssertFalse(
            snapshot.isActive(
                using: probe,
                now: updatedAt.addingTimeInterval(40 * 60)
            )
        )
    }

    func testRunningProgressWithCurrentProcessIsActive() throws {
        let now = Date()
        let pid = currentProcessID
        let snapshot = try decodeRunningSnapshot(
            pid: pid,
            processStartedAt: PackagingProgressActivity.processStartedAt(pid),
            updatedAt: now
        )

        XCTAssertTrue(snapshot.isActive(using: .live, now: now))
    }

    func testStaleWindowMatchesPythonSourceContract() {
        // `scripts/packaging_progress.py:61` 是这段 30 分钟窗口的唯一正本。
        XCTAssertEqual(PackagingProgressActivity.runningStaleAfterSeconds, 30 * 60)
    }

    func testCrossLanguageActivityFixtureMatchesSwiftVerdict() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "packaging_progress_activity_cases",
                withExtension: "json"
            )
        )
        let cases = try JSONDecoder().decode([ActivityFixture].self, from: Data(contentsOf: url))

        for fixture in cases {
            let now = try XCTUnwrap(SentinelDateParser.parse(fixture.now))
            let probe = PackagingProgressActivityProbe(
                pidAlive: { _ in fixture.pidAlive },
                processStartedAt: { _ in fixture.observedProcessStartedAt }
            )
            XCTAssertEqual(
                fixture.payload.isActive(using: probe, now: now),
                fixture.expected,
                fixture.name
            )
        }
    }

    private var currentProcessID: Int {
        Int(ProcessInfo.processInfo.processIdentifier)
    }

    private func decodeRunningSnapshot(
        pid: Int,
        processStartedAt: String,
        updatedAt: Date
    ) throws -> PackagingProgressSnapshot {
        try JSONDecoder().decode(
            PackagingProgressSnapshot.self,
            from: progressJSON(
                status: "running",
                pid: pid,
                processStartedAt: processStartedAt,
                updatedAt: updatedAt
            )
        )
    }

    private func progressJSON(
        status: String,
        pid: Int? = nil,
        processStartedAt: String? = nil,
        updatedAt: Date,
        extra: [String: Any] = [:]
    ) throws -> Data {
        var payload: [String: Any] = [
            "schema": "cortex.packaging-progress.v1",
            "run_id": "fixture-run",
            "entry": "release_app",
            "status": status,
            "current_step_id": "build",
            "current_detail": "Electron 打包",
            "updated_at": iso8601(updatedAt),
            "eta_ms": 720000,
            "eta_label": "大约还要 12 分钟",
            "eta_is_estimate": true,
            "steps": [["id": "build", "title": "构建 App 与 zip", "status": "running"]],
        ]
        if let pid {
            payload["pid"] = pid
        }
        if let processStartedAt {
            payload["process_started_at"] = processStartedAt
        }
        for (key, value) in extra {
            payload[key] = value
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct ActivityFixture: Decodable {
        let name: String
        let payload: PackagingProgressSnapshot
        let now: String
        let pidAlive: Bool
        let observedProcessStartedAt: String
        let expected: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case payload
            case now
            case pidAlive = "pid_alive"
            case observedProcessStartedAt = "observed_process_started_at"
            case expected
        }
    }
}
