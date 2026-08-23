import Foundation
import XCTest
@testable import CortexSentinelBar

final class LogCleanerTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_784_880_000)

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("log-cleaner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LogCleaner.supportDirectoryOverride = nil
        if let root {
            try? fileManager.removeItem(at: inspectURL())
            try? fileManager.removeItem(at: uncertainURL())
            try? fileManager.removeItem(at: root)
        }
    }

    // MARK: 白名单识别

    func testCleanableSlugOnlyMatchesDispatchLogs() {
        XCTAssertEqual(LogCleaner.cleanableSlug(fileName: "codex-ui-settings-voice.log"), "ui-settings-voice")
        XCTAssertEqual(LogCleaner.cleanableSlug(fileName: "kimi-k3-refactor.log"), "k3-refactor")
        XCTAssertEqual(LogCleaner.cleanableSlug(fileName: "codex-babysitter-foo.stdout"), "foo")
        XCTAssertEqual(LogCleaner.cleanableSlug(fileName: "babysitter-bar.nohup.out"), "bar")

        // 白名单外一律 nil（红线保护对象）
        for protected in [
            "codex-line-registry.json",
            "codex-babysitter-foo.status.json",
            "claude-oxalpha-foo.status.json",
            "claude-oxalpha-foo.log",
            "codex-prompt-foo.md",
            "codex-foo-DELIVERY.md",
            "codex-babysitter-foo.out",
            "web-dev.log",
            "web-dev-2347.log",
            "dev-server.log",
            "cortex-daily.log",
            "realtime-loop.log",
            "contact-fact-queue.json",
            "cortex-run-now-state.json",
            "aio-usage.log",
            "switch-log.jsonl",
        ] {
            XCTAssertNil(
                LogCleaner.cleanableSlug(fileName: protected),
                "\(protected) 不应被判为可清理"
            )
        }
    }

    // MARK: 终态 / 活线 / 孤儿分类

    func testPlanDeletesTerminalAndStaleOrphansButProtectsRunningAndRecent() throws {
        // 终态：done / help / dead → 删
        writeLog("codex-alpha.log", bytes: 100, ageSeconds: 7200)
        writeStatus("alpha", state: "done")
        writeLog("codex-gamma.log", bytes: 100, ageSeconds: 7200)
        writeStatus("gamma", state: "help")
        writeLog("codex-omega.log", bytes: 100, ageSeconds: 7200)
        writeStatus("omega", state: "dead")

        // 活线：running → 永不删
        writeLog("codex-beta.log", bytes: 100, ageSeconds: 5)
        writeStatus("beta", state: "running")
        writeLog("codex-babysitter-eta.stdout", bytes: 100, ageSeconds: 5)
        writeStatus("eta", state: "running")

        // 孤儿：无 status，老 → 删；近 10 分钟仍在写（如活 kimi）→ 保护
        writeLog("codex-delta.log", bytes: 100, ageSeconds: 7200)
        writeLog("kimi-epsilon.log", bytes: 100, ageSeconds: 7200)
        writeLog("kimi-zeta.log", bytes: 100, ageSeconds: 30)

        // 白名单外：绝不动
        writeLog("web-dev.log", bytes: 100, ageSeconds: 7200)
        writeLog("dev-server.log", bytes: 100, ageSeconds: 7200)
        writeRaw("codex-line-registry.json", bytes: 100)
        writeRaw("cortex-run-now-state.json", bytes: 100)

        let plan = LogCleaner.plan(logsDirectory: root, now: now, fileManager: fileManager)
        let deleteNames = Set(plan.candidates.map(\.fileName))

        XCTAssertEqual(
            deleteNames,
            ["codex-alpha.log", "codex-gamma.log", "codex-omega.log", "codex-delta.log", "kimi-epsilon.log"]
        )
        XCTAssertTrue(plan.protectedActive.contains("codex-beta.log"))
        XCTAssertTrue(plan.protectedActive.contains("codex-babysitter-eta.stdout"))
        XCTAssertTrue(plan.protectedActive.contains("kimi-zeta.log"))
        XCTAssertFalse(deleteNames.contains("web-dev.log"))
        XCTAssertFalse(deleteNames.contains("codex-line-registry.json"))
        XCTAssertEqual(plan.whitelistFileCount, 8)
        XCTAssertEqual(plan.totalBytesBefore, 800)
    }

    func testDryRunDeletesNothingButExecuteDoes() throws {
        writeLog("codex-alpha.log", bytes: 100, ageSeconds: 7200)
        writeStatus("alpha", state: "done")
        writeLog("codex-beta.log", bytes: 100, ageSeconds: 5)
        writeStatus("beta", state: "running")
        writeLog("web-dev.log", bytes: 100, ageSeconds: 7200)

        let inspect = inspectURL()
        // 干跑：只出计划，磁盘不变
        let dryPlan = LogCleaner.run(
            logsDirectory: root,
            dryRun: true,
            now: now,
            fileManager: fileManager,
            inspectLogURL: inspect
        )
        XCTAssertEqual(dryPlan.candidates.map(\.fileName), ["codex-alpha.log"])
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("codex-alpha.log").path))

        // 实跑：删终态，留活线与白名单外
        LogCleaner.run(
            logsDirectory: root,
            dryRun: false,
            now: now,
            fileManager: fileManager,
            inspectLogURL: inspect
        )
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("codex-alpha.log").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("codex-beta.log").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("web-dev.log").path))
        XCTAssertFalse(
            fileManager.fileExists(atPath: root.appendingPathComponent("log-cleanup-inspect.log").path)
        )
    }

    // MARK: ox-alpha 活线保护

    func testOxAlphaRunningLineProtectsItsLogAndItsOwnFilesAreNeverCandidates() throws {
        // 只有 ox-alpha 状态文件、没有 babysitter 状态文件的活线：
        // 它的 codex-<slug>.log 以前会被当孤儿删掉。
        writeLog("codex-oxlive.log", bytes: 100, ageSeconds: 7200)
        writeOxAlphaStatus("oxlive", state: "running")
        // ox-alpha 自己的状态文件和日志本来就不在白名单里，任何时候都不该进计划。
        writeLog("claude-oxalpha-oxlive.log", bytes: 100, ageSeconds: 7200)
        // ox-alpha 终态线的 codex 日志照常按终态删。
        writeLog("codex-oxdone.log", bytes: 100, ageSeconds: 7200)
        writeOxAlphaStatus("oxdone", state: "done")

        let plan = LogCleaner.plan(logsDirectory: root, now: now, fileManager: fileManager)
        let deleteNames = Set(plan.candidates.map(\.fileName))

        XCTAssertFalse(deleteNames.contains("codex-oxlive.log"))
        XCTAssertTrue(plan.protectedActive.contains("codex-oxlive.log"))
        XCTAssertFalse(deleteNames.contains("claude-oxalpha-oxlive.log"))
        XCTAssertFalse(deleteNames.contains("claude-oxalpha-oxlive.status.json"))
        XCTAssertEqual(deleteNames, ["codex-oxdone.log"])
    }

    func testRunningOxAlphaStatusBeatsTerminalBabysitterStatusForTheSameSlug() throws {
        writeLog("codex-shared.log", bytes: 100, ageSeconds: 7200)
        writeStatus("shared", state: "done")
        writeOxAlphaStatus("shared", state: "running")

        let plan = LogCleaner.plan(logsDirectory: root, now: now, fileManager: fileManager)

        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertTrue(plan.protectedActive.contains("codex-shared.log"))
    }

    // MARK: 超上限清理

    func testSizeCapDeletesOldestTransientButNeverRunning() throws {
        // 过渡态（retrying/backoff）两条：老的先删；活线 running 永不删
        writeLog("codex-old.log", bytes: 1000, ageSeconds: 7200)
        writeStatus("old", state: "retrying")
        writeLog("codex-new.log", bytes: 1000, ageSeconds: 600)
        writeStatus("new", state: "backoff")
        writeLog("codex-live.log", bytes: 1000, ageSeconds: 5)
        writeStatus("live", state: "running")

        // 总量 ~3KB；上限 2600B、目标 2400B → 删最老的 codex-old(1000) 即达标，codex-new 保留
        let plan = LogCleaner.plan(
            logsDirectory: root,
            now: now,
            maxTotalBytes: 2600,
            targetBytes: 2400,
            fileManager: fileManager
        )
        XCTAssertEqual(plan.candidates.map(\.fileName), ["codex-old.log"])
        XCTAssertTrue(plan.protectedActive.contains("codex-live.log"))

        // 上限充足时过渡态不动
        let calm = LogCleaner.plan(logsDirectory: root, now: now, fileManager: fileManager)
        XCTAssertTrue(calm.candidates.isEmpty)
    }

    func testLargeTreeDoesNotForceTransientCleanupWhenWhitelistIsSmall() throws {
        writeLog("web-dev.log", bytes: 50_000, ageSeconds: 7200)
        writeLog("dev-server.log", bytes: 50_000, ageSeconds: 7200)
        let shots = root.appendingPathComponent("shots", isDirectory: true)
        try fileManager.createDirectory(at: shots, withIntermediateDirectories: true)
        fileManager.createFile(
            atPath: shots.appendingPathComponent("panel.png").path,
            contents: Data(repeating: 0x63, count: 80_000)
        )

        writeLog("codex-old.log", bytes: 200, ageSeconds: 7200)
        writeStatus("old", state: "retrying")
        writeLog("codex-live.log", bytes: 200, ageSeconds: 5)
        writeStatus("live", state: "running")

        // 整棵树 ~180KB，白名单只有 400B。阈值 1000B 若按整树量就会去补删过渡态。
        let plan = LogCleaner.plan(
            logsDirectory: root,
            now: now,
            maxTotalBytes: 1000,
            targetBytes: 500,
            fileManager: fileManager
        )
        XCTAssertEqual(plan.totalBytesBefore, 400)
        XCTAssertEqual(plan.whitelistFileCount, 2)
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertTrue(plan.protectedActive.contains("codex-live.log"))
    }

    func testInspectRecordHasRequiredFieldsAndOneLinePerRun() throws {
        writeLog("codex-alpha.log", bytes: 100, ageSeconds: 7200)
        writeStatus("alpha", state: "done")
        let inspect = inspectURL()

        LogCleaner.run(
            logsDirectory: root,
            dryRun: true,
            now: now,
            fileManager: fileManager,
            inspectLogURL: inspect
        )
        let dryLines = try inspectLines(at: inspect)
        XCTAssertEqual(dryLines.count, 1)
        XCTAssertTrue(dryLines[0].contains("ts="))
        XCTAssertTrue(dryLines[0].contains("scanned=1"))
        XCTAssertTrue(dryLines[0].contains("deleted=0"))
        XCTAssertTrue(dryLines[0].contains("reclaim_bytes=0"))
        XCTAssertTrue(dryLines[0].contains("candidate_bytes=100"))
        XCTAssertTrue(dryLines[0].hasPrefix("ts=\(LogCleaner.inspectTimestamp(now))"))
        XCTAssertTrue(LogCleaner.inspectTimestamp(now).hasSuffix("+08:00"))

        LogCleaner.run(
            logsDirectory: root,
            dryRun: false,
            now: now,
            fileManager: fileManager,
            inspectLogURL: inspect
        )
        let realLines = try inspectLines(at: inspect)
        XCTAssertEqual(realLines.count, 2)
        XCTAssertTrue(realLines[1].contains("scanned=1"))
        XCTAssertTrue(realLines[1].contains("deleted=1"))
        XCTAssertTrue(realLines[1].contains("reclaim_bytes=100"))
        XCTAssertTrue(realLines[1].contains("candidate_bytes=0"))
        XCTAssertFalse(
            fileManager.fileExists(atPath: root.appendingPathComponent("log-cleanup-inspect.log").path)
        )
    }

    func testUncertainClassesSortedByBytesAndExcludeWhitelist() throws {
        writeLog("codex-alpha.log", bytes: 8_000, ageSeconds: 7200)
        writeRaw("tiny.bin", bytes: 100)
        writeNested("shots/shot-1.png", bytes: 3_000, ageSeconds: 3_600)
        writeNested("shots/shot-99.png", bytes: 1_500, ageSeconds: 86_400)
        writeNested("dumps/keep.bin", bytes: 2_000, ageSeconds: 7_200)

        let report = LogCleaner.surveyUncertainVolume(
            logsDirectory: root,
            now: now,
            fileManager: fileManager
        )
        XCTAssertEqual(report.classes.map(\.pattern), [
            "shots/**/shot-*.png",
            "dumps/**/keep.bin",
            "tiny.bin",
        ])
        XCTAssertEqual(report.classes.map(\.totalBytes), [4_500, 2_000, 100])
        XCTAssertEqual(report.classes.map(\.fileCount), [2, 1, 1])
        XCTAssertEqual(report.whitelistSkipped, 1)
        XCTAssertFalse(report.classes.contains { $0.pattern.contains("codex-alpha") })
        XCTAssertEqual(report.classes[0].newestModifiedAt, now.addingTimeInterval(-3_600))
    }

    func testUncertainSurveyCountsFileSymlinkByTargetSize() throws {
        writeRaw("payload.bin", bytes: 4_000)
        let shots = root.appendingPathComponent("shots", isDirectory: true)
        try fileManager.createDirectory(at: shots, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: shots.appendingPathComponent("alias.bin"),
            withDestinationURL: root.appendingPathComponent("payload.bin")
        )

        let report = LogCleaner.surveyUncertainVolume(
            logsDirectory: root,
            now: now,
            fileManager: fileManager
        )
        XCTAssertTrue(
            report.classes.contains {
                $0.pattern == "shots/**/alias.bin (symlink)" && $0.totalBytes == 4_000 && $0.fileCount == 1
            },
            "symlink 应按目标体积入账，实际 \(report.classes)"
        )
        XCTAssertTrue(report.classes.contains { $0.pattern == "payload.bin" && $0.totalBytes == 4_000 })
    }

    func testUncertainReportOverwritesAndEmptyDirectoryDoesNotCrash() throws {
        writeRaw("keep.bin", bytes: 200)
        let reportURL = uncertainURL()

        LogCleaner.run(
            logsDirectory: root,
            dryRun: true,
            now: now,
            fileManager: fileManager,
            inspectLogURL: inspectURL(),
            uncertainReportURL: reportURL
        )
        let first = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(first.contains("keep.bin"))
        XCTAssertFalse(first.contains("（没有非白名单文件）"))

        try fileManager.removeItem(at: root.appendingPathComponent("keep.bin"))
        LogCleaner.run(
            logsDirectory: root,
            dryRun: true,
            now: now,
            fileManager: fileManager,
            inspectLogURL: inspectURL(),
            uncertainReportURL: reportURL
        )
        let second = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertFalse(second.contains("keep.bin"))
        XCTAssertTrue(second.contains("（没有非白名单文件）"))
        XCTAssertEqual(second.components(separatedBy: "# 拿不准的体积").count - 1, 1)

        let emptyRoot = root.appendingPathComponent("empty", isDirectory: true)
        try fileManager.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let empty = LogCleaner.surveyUncertainVolume(
            logsDirectory: emptyRoot,
            now: now,
            fileManager: fileManager
        )
        XCTAssertEqual(empty, .empty)
        LogCleaner.writeUncertainReport(
            LogCleaner.uncertainReportText(empty, now: now),
            to: reportURL,
            fileManager: fileManager
        )
        let emptyText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(emptyText.contains("shown=0"))
        XCTAssertTrue(emptyText.contains("（没有非白名单文件）"))
    }

    func testInspectPathOverrideDoesNotTouchProductionFile() throws {
        let production = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("CortexSentinel", isDirectory: true)
            .appendingPathComponent("log-cleanup-inspect.log")
        let before = try? Data(contentsOf: production)
        let isolated = root.appendingPathComponent("isolated-support", isDirectory: true)
        LogCleaner.supportDirectoryOverride = isolated

        writeLog("codex-alpha.log", bytes: 100, ageSeconds: 7200)
        writeStatus("alpha", state: "done")
        LogCleaner.run(
            logsDirectory: root,
            dryRun: true,
            now: now,
            fileManager: fileManager
        )

        let after = try? Data(contentsOf: production)
        XCTAssertEqual(before, after)
        XCTAssertTrue(
            fileManager.fileExists(atPath: LogCleaner.defaultInspectLogURL().path)
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: LogCleaner.defaultUncertainReportURL().path)
        )
        XCTAssertTrue(LogCleaner.defaultInspectLogURL().path.hasPrefix(isolated.path))
        try? fileManager.removeItem(at: isolated)
    }

    func testDefaultInspectLogIsIsolatedDuringXCTestProcess() {
        LogCleaner.supportDirectoryOverride = nil
        let url = LogCleaner.defaultInspectLogURL()
        XCTAssertFalse(
            url.path.contains("/Library/Application Support/CortexSentinel/"),
            "测试进程不得写生产留痕，实际 \(url.path)"
        )
        XCTAssertTrue(
            url.path.contains("CortexSentinel-xctest-") || url.path.contains("/T/"),
            "测试进程应落到临时目录，实际 \(url.path)"
        )
    }

    func testResolvedSupportDirectoryHonorsEnvAndFallsBack() {
        let overridden = LogCleaner.resolvedSupportDirectory(
            environment: [LogCleanupConstants.supportDirectoryEnvironmentKey: "/tmp/sentinel-support-test"]
        )
        XCTAssertEqual(overridden.path, "/tmp/sentinel-support-test")

        let production = LogCleaner.resolvedSupportDirectory(environment: [:])
        XCTAssertTrue(
            production.path.contains("Application Support"),
            "空环境应回到 Application Support，实际 \(production.path)"
        )
    }

    func testInspectLogTruncatesWhenOverMaxLines() throws {
        let inspect = inspectURL()
        let overflow = LogCleanupConstants.inspectLogMaxLines + 40
        for _ in 0..<overflow {
            LogCleaner.run(
                logsDirectory: root,
                dryRun: true,
                now: now,
                fileManager: fileManager,
                inspectLogURL: inspect
            )
        }
        let lines = try inspectLines(at: inspect)
        XCTAssertEqual(lines.count, LogCleanupConstants.inspectLogMaxLines)
    }

    // MARK: helpers

    private func inspectURL() -> URL {
        root.deletingLastPathComponent().appendingPathComponent(
            "\(root.lastPathComponent).cleanup-inspect.log"
        )
    }

    private func uncertainURL() -> URL {
        root.deletingLastPathComponent().appendingPathComponent(
            "\(root.lastPathComponent).uncertain.txt"
        )
    }

    private func inspectLines(at url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init)
    }

    private func writeLog(_ name: String, bytes: Int, ageSeconds: TimeInterval) {
        let url = root.appendingPathComponent(name)
        fileManager.createFile(atPath: url.path, contents: Data(repeating: 0x61, count: bytes))
        setModified(url, ageSeconds: ageSeconds)
    }

    private func writeRaw(_ name: String, bytes: Int) {
        let url = root.appendingPathComponent(name)
        fileManager.createFile(atPath: url.path, contents: Data(repeating: 0x62, count: bytes))
        setModified(url, ageSeconds: 7200)
    }

    private func writeNested(_ relative: String, bytes: Int, ageSeconds: TimeInterval) {
        let url = relative.split(separator: "/").reduce(root) { partial, part in
            partial.appendingPathComponent(String(part))
        }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: url.path, contents: Data(repeating: 0x63, count: bytes))
        setModified(url, ageSeconds: ageSeconds)
    }

    private func writeStatus(_ slug: String, state: String) {
        let url = root.appendingPathComponent("codex-babysitter-\(slug).status.json")
        let json = "{\"slug\":\"\(slug)\",\"state\":\"\(state)\"}"
        fileManager.createFile(atPath: url.path, contents: Data(json.utf8))
        setModified(url, ageSeconds: 60)
    }

    private func writeOxAlphaStatus(_ slug: String, state: String) {
        let url = root.appendingPathComponent("claude-oxalpha-\(slug).status.json")
        let json = "{\"engine\":\"claude\",\"slug\":\"\(slug)\",\"state\":\"\(state)\"}"
        fileManager.createFile(atPath: url.path, contents: Data(json.utf8))
        setModified(url, ageSeconds: 60)
    }

    private func setModified(_ url: URL, ageSeconds: TimeInterval) {
        try? fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ageSeconds)],
            ofItemAtPath: url.path
        )
    }
}
