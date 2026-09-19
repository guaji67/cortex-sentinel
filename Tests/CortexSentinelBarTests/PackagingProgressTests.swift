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

    /// Falcon 原话要的是「预计几点出包」这个钟点，不只是「还要多久」。
    func testEtaDisplayCarriesArrivalClockFromEtaMilliseconds() throws {
        let withEta = try JSONDecoder().decode(
            PackagingProgressSnapshot.self,
            from: progressJSON(
                status: "running",
                updatedAt: Date(),
                extra: ["eta_ms": 12 * 60 * 1000, "eta_label": "大约还要 12 分钟"]
            )
        )
        XCTAssertEqual(withEta.etaText, "大约还要 12 分钟")
        XCTAssertTrue(withEta.etaArrivalText?.hasPrefix("预计 ") == true, "钟点必须是「预计 HH:mm」的形状")
        XCTAssertTrue(withEta.etaDisplayText.contains(withEta.etaText))
        XCTAssertTrue(withEta.etaDisplayText.contains(withEta.etaArrivalText ?? ""), "右上角要时长和钟点都给")

        // 裸 JSON：progressJSON 夹具基础载荷自带 eta_ms，测「没有 eta」得绕开它。
        let withoutEta = try JSONDecoder().decode(
            PackagingProgressSnapshot.self,
            from: Data(
                #"{"schema":"cortex.packaging-progress.v1","status":"running","updated_at":"2026-09-19T02:00:00.000Z"}"#.utf8
            )
        )
        XCTAssertNil(withoutEta.etaArrivalText)
        XCTAssertEqual(withoutEta.etaDisplayText, withoutEta.etaText, "没有 eta_ms 就只剩时长，不硬造钟点")
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

    // MARK: - COR-7600 稳定落点三态投影（正本：pack_telemetry_section()）

    func testStableMirrorRunningWinsOverLegacyResidueAndCarriesFurnaceIdentity() throws {
        let fixture = try makePackFixture()
        defer { fixture.cleanUp() }
        let pid = currentProcessID
        try progressJSON(
            status: "completed",
            updatedAt: Date().addingTimeInterval(-3600)
        ).write(to: fixture.legacyRun.appendingPathComponent("progress.json"))
        try stableJSON(
            status: "running",
            pid: pid,
            processStartedAt: PackagingProgressActivity.processStartedAt(pid),
            updatedAt: Date(),
            extra: [
                "version": "9.9.9",
                "started_at": iso8601(Date().addingTimeInterval(-25 * 60)),
                "current_step_id": "dmg",
                "progress_file": "/tmp/fixture/cortex-pack-progress/run-1/progress.json",
                "steps": [
                    ["id": "build", "title": "构建 App 与 zip", "status": "done"],
                    ["id": "dmg", "title": "打 DMG", "status": "running"],
                ],
            ]
        ).write(to: fixture.stableURL)

        guard case let .running(snapshot) = PackagingProgressReader.read(
            stableURL: fixture.stableURL,
            legacyRoot: fixture.legacyRoot
        ) else {
            return XCTFail("稳定落点活线必须投影成 running")
        }
        XCTAssertEqual(snapshot.furnaceText, "9.9.9")
        XCTAssertEqual(snapshot.stepProgressText, "第 2/2 步")
        XCTAssertEqual(snapshot.progressFile, "/tmp/fixture/cortex-pack-progress/run-1/progress.json")
        XCTAssertNotNil(snapshot.startedAt)
        XCTAssertTrue(snapshot.isActive)
    }

    func testMissingStableMirrorFallsBackToLegacyRunning() throws {
        let fixture = try makePackFixture()
        defer { fixture.cleanUp() }
        let pid = currentProcessID
        try progressJSON(
            status: "running",
            pid: pid,
            processStartedAt: PackagingProgressActivity.processStartedAt(pid),
            updatedAt: Date()
        ).write(to: fixture.legacyRun.appendingPathComponent("progress.json"))

        let missingStable = fixture.root
            .appendingPathComponent("health", isDirectory: true)
            .appendingPathComponent("pack-progress.json")
        guard case let .running(snapshot) = PackagingProgressReader.read(
            stableURL: missingStable,
            legacyRoot: fixture.legacyRoot
        ) else {
            return XCTFail("稳定落点缺文件必须退回旧落点并显示 running")
        }
        XCTAssertEqual(snapshot.runID, "fixture-run")
        XCTAssertTrue(snapshot.isActive)
    }

    func testCompletedStableMirrorProjectsToIdleWithLastRun() throws {
        let fixture = try makePackFixture()
        defer { fixture.cleanUp() }
        try stableJSON(
            status: "completed",
            updatedAt: Date().addingTimeInterval(-120),
            extra: ["version": "9.9.8"]
        ).write(to: fixture.stableURL)

        guard case let .idle(reason, lastRun) = PackagingProgressReader.read(
            stableURL: fixture.stableURL,
            legacyRoot: fixture.legacyRoot
        ) else {
            return XCTFail("completed 残留必须投影成 idle")
        }
        XCTAssertEqual(reason, PackagingProgressReader.Reasons.idleNotRunning)
        XCTAssertEqual(lastRun?.status, .completed)
        XCTAssertEqual(lastRun?.furnaceText, "9.9.8")
    }

    func testMissingMirrorEverywhereProjectsToIdleWithFileReason() throws {
        let fixture = try makePackFixture()
        defer { fixture.cleanUp() }

        guard case let .idle(reason, lastRun) = PackagingProgressReader.read(
            stableURL: fixture.stableURL,
            legacyRoot: fixture.legacyRoot
        ) else {
            return XCTFail("两边都没有必须投影成 idle")
        }
        XCTAssertEqual(reason, PackagingProgressReader.Reasons.idleNoMirrorFile)
        XCTAssertNil(lastRun)
    }

    func testUnreadableStableMirrorProjectsToErrorAndNeverFallsBack() throws {
        let fixture = try makePackFixture()
        defer { fixture.cleanUp() }
        let pid = currentProcessID
        try progressJSON(
            status: "running",
            pid: pid,
            processStartedAt: PackagingProgressActivity.processStartedAt(pid),
            updatedAt: Date()
        ).write(to: fixture.legacyRun.appendingPathComponent("progress.json"))
        try Data("this-is-not-pack-progress".utf8).write(to: fixture.stableURL)

        guard case let .error(reason) = PackagingProgressReader.read(
            stableURL: fixture.stableURL,
            legacyRoot: fixture.legacyRoot
        ) else {
            return XCTFail("读不了的登记文件必须投影成 error")
        }
        XCTAssertEqual(reason, PackagingProgressReader.Reasons.unreadableMirrorFile)
    }

    func testUnresolvableStableRootReportsErrorUnlessLegacyIsRunning() throws {
        let fixture = try makePackFixture()
        defer { fixture.cleanUp() }

        guard case let .error(reason) = PackagingProgressReader.read(
            stableURL: nil,
            legacyRoot: fixture.legacyRoot
        ) else {
            return XCTFail("数据根解析不出来必须投影成 error")
        }
        XCTAssertEqual(reason, PackagingProgressReader.Reasons.unresolvableDataRoot)

        let pid = currentProcessID
        try progressJSON(
            status: "running",
            pid: pid,
            processStartedAt: PackagingProgressActivity.processStartedAt(pid),
            updatedAt: Date()
        ).write(to: fixture.legacyRun.appendingPathComponent("progress.json"))
        guard case .running = PackagingProgressReader.read(
            stableURL: nil,
            legacyRoot: fixture.legacyRoot
        ) else {
            return XCTFail("数据根解析不出来但旧落点有活线时，不许把在跑的炉藏成 error")
        }
    }

    func testPackProgressHealthURLFollowsDataRootResolutionOrder() {
        XCTAssertEqual(
            SentinelPaths.packProgressHealthURL(environment: ["CORTEX_DATA_ROOT": "/fixture-data"]),
            URL(fileURLWithPath: "/fixture-data/health/pack-progress.json")
        )
        XCTAssertEqual(
            SentinelPaths.packProgressHealthURL(environment: [
                "CORTEX_DATA_ROOT": "/fixture-data",
                "CORTEX_PACK_PROGRESS_MIRROR_DIR": "/fixture-mirror",
            ]),
            URL(fileURLWithPath: "/fixture-mirror/pack-progress.json"),
            "写方显式覆盖压过数据根"
        )
        XCTAssertNil(
            SentinelPaths.packProgressHealthURL(environment: [:]),
            "XCTest 进程没有显式数据根时不摸本机 ~/CortexData"
        )
        XCTAssertNil(
            SentinelPaths.packProgressHealthURL(
                environment: [:],
                homeDirectory: nil
            ),
            "home 取不到就放弃，不兜底写死路径"
        )
    }

    /// 打包夹具脚手架：root/health/ 放稳定落点，root/legacy/<run>/ 放旧落点。
    private struct PackFixture {
        let root: URL
        let stableURL: URL
        let legacyRoot: URL
        let legacyRun: URL

        var cleanUp: () -> Void {
            { try? FileManager.default.removeItem(at: root) }
        }
    }

    private func makePackFixture() throws -> PackFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CortexPackReading-\(UUID().uuidString)", isDirectory: true)
        let healthDirectory = root.appendingPathComponent("health", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let legacyRun = legacyDirectory.appendingPathComponent("run-1", isDirectory: true)
        try FileManager.default.createDirectory(at: healthDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyRun, withIntermediateDirectories: true)
        return PackFixture(
            root: root,
            stableURL: healthDirectory.appendingPathComponent("pack-progress.json"),
            legacyRoot: legacyDirectory,
            legacyRun: legacyRun
        )
    }

    private func stableJSON(
        status: String,
        pid: Int? = nil,
        processStartedAt: String? = nil,
        updatedAt: Date,
        extra: [String: Any] = [:]
    ) throws -> Data {
        try progressJSON(
            status: status,
            pid: pid,
            processStartedAt: processStartedAt,
            updatedAt: updatedAt,
            extra: extra
        )
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
