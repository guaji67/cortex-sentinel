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

        try Data(
            #"{"status":"completed","updated_at":"2026-08-22T14:00:00Z"}"#.utf8
        ).write(to: older.appendingPathComponent("progress.json"))
        try Data(
            """
            {
              "schema": "cortex.packaging-progress.v1",
              "run_id": "latest-42",
              "entry": "release_app",
              "status": "running",
              "current_step_id": "build",
              "current_detail": "Electron 打包",
              "updated_at": "2026-08-22T15:00:00Z",
              "eta_ms": 720000,
              "eta_label": "大约还要 12 分钟",
              "eta_is_estimate": true,
              "steps": [
                {"id": "build", "title": "构建 App 与 zip", "status": "running"}
              ],
              "unknown_future_field": {"ignored": true}
            }
            """.utf8
        ).write(to: latest.appendingPathComponent("progress.json"))

        let snapshot = try XCTUnwrap(PackagingProgressReader.read(at: root))
        XCTAssertEqual(snapshot.runID, "latest-42")
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

    func testStatusBarGetsAnExplicitPackagingSegmentOnlyWhileRunning() throws {
        let snapshot = try JSONDecoder().decode(
            PackagingProgressSnapshot.self,
            from: Data(#"{"status":"running","eta_label":"大约还要 12 分钟"}"#.utf8)
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
}
