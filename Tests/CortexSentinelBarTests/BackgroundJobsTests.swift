import Foundation
import XCTest
@testable import CortexSentinelBar

final class BackgroundJobsTests: XCTestCase {
    func testReaderDecodesJobsAndMalformedDataFallsBackToEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-background-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            #"{"jobs":[{"label":"com.fixture.job","name":"样例","status":"ok","status_text":"正常","plist_status":"loaded"}]}"#.utf8
        ).write(to: root)

        let jobs = BackgroundJobsReader.read(at: root)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.label, "com.fixture.job")
        XCTAssertEqual(jobs.first?.statusText, "正常")

        try Data("not json".utf8).write(to: root)
        XCTAssertEqual(BackgroundJobsReader.read(at: root), [])
    }

    func testDisabledJobsReadWriteAndMergeKeepsMissingLabelsVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-disabled-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DisabledJobsStore(url: root)

        _ = try store.adding("com.fixture.deleted")
        XCTAssertEqual(store.read(), ["com.fixture.deleted"])

        let rows = BackgroundJobsPresentation.merge(
            jobs: [BackgroundJob(label: "com.fixture.live", name: "仍在")],
            disabledLabels: store.read()
        )
        XCTAssertEqual(rows.map(\.job.label), ["com.fixture.deleted", "com.fixture.live"])
        XCTAssertTrue(rows.first(where: { $0.job.label == "com.fixture.deleted" })?.isDisabled == true)

        _ = try store.removing("com.fixture.deleted")
        XCTAssertEqual(store.read(), [])
        try Data("broken".utf8).write(to: root)
        XCTAssertEqual(store.read(), [])
    }

    func testLaunchctlCommandsUseGuiDomainAndExpectedArguments() {
        XCTAssertEqual(
            LaunchctlCommandBuilder.bootout(uid: 503, label: "com.fixture.job"),
            ["bootout", "gui/503/com.fixture.job"]
        )
        XCTAssertEqual(
            LaunchctlCommandBuilder.disable(uid: 503, label: "com.fixture.job"),
            ["disable", "gui/503/com.fixture.job"]
        )
        XCTAssertEqual(
            LaunchctlCommandBuilder.enable(uid: 503, label: "com.fixture.job"),
            ["enable", "gui/503/com.fixture.job"]
        )
        XCTAssertEqual(
            LaunchctlCommandBuilder.bootstrap(
                uid: 503,
                plistURL: URL(fileURLWithPath: "/Users/fixture/Library/LaunchAgents/com.fixture.job.plist")
            ),
            ["bootstrap", "gui/503", "/Users/fixture/Library/LaunchAgents/com.fixture.job.plist"]
        )
    }

    func testCriticalLabelsRequireConfirmation() {
        XCTAssertEqual(BackgroundJobsConstants.criticalLabels.count, 4)
        XCTAssertTrue(BackgroundJobsConstants.criticalLabels.contains("com.falcon.cortex.web"))
        XCTAssertFalse(BackgroundJobsConstants.criticalLabels.contains("com.fixture.job"))
    }

    @MainActor
    func testStoreDisableUsesInjectedRunnerInOrderAndPersistsLabel() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("sentinel-store-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = SentinelPaths(
            repositoryRoot: root,
            poolDirectory: root,
            aioDatabaseURL: root.appendingPathComponent("aio.db"),
            aioManifestURL: root.appendingPathComponent("manifest.json"),
            codexConfigURL: root.appendingPathComponent("config.toml"),
            codexAuthURL: root.appendingPathComponent("auth.json"),
            inputStatusURL: URL(string: "https://status.fixture.test/api/status")!,
            logsDirectory: root
        )
        let disabledURL = root.appendingPathComponent("disabled-jobs.json")
        let runner = RecordingLaunchctlRunner(results: [
            LaunchctlResult(exitCode: 0, standardOutput: "", standardError: ""),
            LaunchctlResult(exitCode: 0, standardOutput: "", standardError: ""),
        ])
        let store = SentinelStore(
            paths: paths,
            launchctlRunner: runner,
            disabledJobsURL: disabledURL,
            launchctlUID: 503
        )

        store.disableBackgroundJob("com.fixture.job")
        for _ in 0..<20 {
            if !(await runner.recordedArguments().isEmpty) {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let recordedArguments = await runner.recordedArguments()
        XCTAssertEqual(
            recordedArguments,
            [
                ["bootout", "gui/503/com.fixture.job"],
                ["disable", "gui/503/com.fixture.job"],
            ]
        )
        XCTAssertEqual(DisabledJobsStore(url: disabledURL).read(), ["com.fixture.job"])
    }
}

private actor RecordingLaunchctlRunner: LaunchctlRunning {
    private var queuedResults: [LaunchctlResult]
    private var arguments: [[String]] = []

    init(results: [LaunchctlResult]) {
        queuedResults = results
    }

    func run(arguments: [String]) async -> LaunchctlResult {
        self.arguments.append(arguments)
        if queuedResults.isEmpty {
            return LaunchctlResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return queuedResults.removeFirst()
    }

    func recordedArguments() -> [[String]] {
        return arguments
    }
}


// PR 腿的健康快照解析与展示断言；与私有腿的 launchctl 操作测试并存。
import XCTest
@testable import CortexSentinelBar

final class BackgroundJobsPresentationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-08-20T01:40:00+08:00")!

    func testAllHealthyOccupiesOneSummaryLine() {
        let snapshot = BackgroundJobsSnapshot(
            sourceState: .available,
            generatedAt: now,
            okCount: 5,
            problemCount: 0,
            jobs: [
                job(label: "com.falcon.cortex.web", name: "界面常驻服务", status: .ok),
                job(label: "com.cortex.sentinelbar", name: "Cortex 哨兵", status: .ok),
            ]
        )
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(presentation.summaryText, "后台任务 2 个，全部正常")
        XCTAssertFalse(presentation.hasProblems)
        XCTAssertEqual(presentation.problemRows, [])
        XCTAssertEqual(presentation.healthyRows.count, 2)
        XCTAssertEqual(presentation.tone, .success)
    }

    func testProblemsExpandWithNameLastRunAndReason() {
        let snapshot = BackgroundJobsSnapshot(
            sourceState: .available,
            generatedAt: now,
            okCount: 1,
            problemCount: 1,
            jobs: [
                job(
                    label: "com.falcon.cortex.memory-monitor",
                    name: "内存与回收巡检",
                    status: .stalled,
                    lastRunText: "25 小时前",
                    reason: "超过两个周期没有新记录"
                ),
                job(label: "com.falcon.cortex.web", name: "界面常驻服务", status: .ok),
            ]
        )
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(presentation.summaryText, "后台任务 2 个，1 个不正常")
        XCTAssertTrue(presentation.hasProblems)
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.problemRows.count, 1)
        XCTAssertEqual(presentation.problemRows[0].name, "内存与回收巡检")
        XCTAssertEqual(
            presentation.problemRows[0].detail,
            "上次跑：25 小时前 · 超过两个周期没有新记录"
        )
        XCTAssertEqual(presentation.healthyRows.map(\.name), ["界面常驻服务"])
    }

    func testMissingSnapshotIsOneQuietLine() {
        let presentation = BackgroundJobsPresentation(snapshot: .missing, now: now)
        XCTAssertEqual(presentation.summaryText, "后台任务 无数据")
        XCTAssertFalse(presentation.hasProblems)
        XCTAssertEqual(presentation.problemRows, [])
    }

    func testStaleSnapshotAddsAProblemEvenWhenJobsAreOk() {
        let generatedAt = now.addingTimeInterval(-40 * 60)
        let snapshot = BackgroundJobsSnapshot(
            sourceState: .available,
            generatedAt: generatedAt,
            okCount: 1,
            problemCount: 0,
            jobs: [job(label: "com.falcon.cortex.web", name: "界面常驻服务", status: .ok)]
        )
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertTrue(presentation.hasProblems)
        XCTAssertEqual(presentation.problemRows.first?.name, "健康快照")
        XCTAssertTrue(presentation.problemRows.first?.detail.contains("分钟未更新") == true)
    }

    func testParsesHealthContractJSON() throws {
        let json = """
        {
          "schema": "cortex.background-jobs-health.v1",
          "generated_at": "2026-08-20T01:40:00+08:00",
          "ok_count": 1,
          "problem_count": 1,
          "jobs": [
            {
              "label": "com.falcon.cortex.memory-monitor",
              "name": "内存与回收巡检",
              "interval_text": "每 10 分钟",
              "last_run_at": "2026-08-19T00:04:41+08:00",
              "last_run_text": "25 小时前",
              "status": "stalled",
              "status_text": "出错",
              "reason": "超过两个周期没有新记录",
              "last_exit_code": 0
            },
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "interval_text": "常驻",
              "last_run_text": "正在运行",
              "status": "ok",
              "status_text": "正常",
              "reason": ""
            }
          ]
        }
        """
        let snapshot = BackgroundJobsReader.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.sourceState, .available)
        XCTAssertEqual(snapshot.jobs.count, 2)
        XCTAssertEqual(snapshot.jobs[0].name, "内存与回收巡检")
        XCTAssertEqual(snapshot.jobs[0].status, .stalled)
        XCTAssertEqual(snapshot.jobs[0].status.displayName, "出错")
        XCTAssertTrue(snapshot.jobs[0].isProblem)
        XCTAssertEqual(snapshot.jobs[1].status, .ok)
        XCTAssertNotNil(snapshot.generatedAt)
        XCTAssertEqual(
            BackgroundJobsReader.parse(data: Data("{}".utf8)).sourceState,
            .available
        )
        XCTAssertEqual(
            BackgroundJobsReader.parse(data: Data("not-json".utf8)).sourceState,
            .invalid
        )
    }

    func testMissingPlistStatusFieldTreatsJobAsLoaded() {
        let json = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "status_text": "正常"
            }
          ]
        }
        """
        let snapshot = BackgroundJobsReader.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertEqual(snapshot.jobs[0].plistStatus, .loaded)
        XCTAssertFalse(snapshot.jobs[0].isProblem)
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.hasProblems)
        XCTAssertEqual(presentation.summaryText, "后台任务 1 个，全部正常")
        XCTAssertEqual(presentation.problemRows, [])
    }

    func testMissingPlistStatusIsAProblemWithFixedCopy() {
        let json = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": "missing"
            }
          ]
        }
        """
        let snapshot = BackgroundJobsReader.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.jobs[0].plistStatus, .missing)
        XCTAssertTrue(snapshot.jobs[0].isProblem)
        XCTAssertEqual(
            snapshot.jobs[0].problemDetail,
            BackgroundJobPlistStatus.missingDisplayText
        )
        XCTAssertEqual(snapshot.jobs[0].problemDetail, "配置不在了")
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertTrue(presentation.hasProblems)
        XCTAssertEqual(presentation.problemRows.count, 1)
        XCTAssertEqual(presentation.problemRows[0].detail, "配置不在了")
        XCTAssertEqual(presentation.summaryText, "后台任务 1 个，1 个不正常")
    }

    func testUnreadablePlistStatusShowsFixedCopyAndDetail() {
        let withoutDetail = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": "unreadable"
            }
          ]
        }
        """
        let without = BackgroundJobsReader.parse(data: Data(withoutDetail.utf8))
        XCTAssertEqual(without.jobs[0].plistStatus, .unreadable)
        XCTAssertTrue(without.jobs[0].isProblem)
        XCTAssertEqual(without.jobs[0].problemDetail, "配置读不了")
        let withoutPresentation = BackgroundJobsPresentation(snapshot: without, now: now)
        XCTAssertTrue(withoutPresentation.hasProblems)
        XCTAssertEqual(withoutPresentation.problemRows[0].detail, "配置读不了")

        let withDetail = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": "unreadable",
              "plist_error_detail": "permission denied"
            }
          ]
        }
        """
        let with = BackgroundJobsReader.parse(data: Data(withDetail.utf8))
        XCTAssertEqual(with.jobs[0].plistStatus, .unreadable)
        XCTAssertTrue(with.jobs[0].isProblem)
        XCTAssertEqual(with.jobs[0].problemDetail, "配置读不了 · permission denied")
        let withPresentation = BackgroundJobsPresentation(snapshot: with, now: now)
        XCTAssertEqual(withPresentation.problemRows[0].detail, "配置读不了 · permission denied")
        XCTAssertFalse(withPresentation.problemRows[0].detail.contains("\n"))
    }

    func testPrefersWatchDirectoryFileOverDataRoot() throws {
        let fileManager = FileManager.default
        let logs = fileManager.temporaryDirectory.appendingPathComponent(
            "bgjobs-logs-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: logs) }
        let file = logs.appendingPathComponent("background-jobs-health.json")
        try Data("{}".utf8).write(to: file)
        let url = SentinelPaths.backgroundJobsHealthURL(
            logsDirectory: logs,
            environment: [:],
            fileManager: fileManager
        )
        XCTAssertEqual(url.path, file.path)
    }

    func testFallsBackToDataRootWhenWatchDirectoryHasNoSnapshot() throws {
        let fileManager = FileManager.default
        let logs = fileManager.temporaryDirectory.appendingPathComponent(
            "bgjobs-empty-logs-\(UUID().uuidString)",
            isDirectory: true
        )
        let dataRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "bgjobs-data-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: logs)
            try? fileManager.removeItem(at: dataRoot)
        }
        let url = SentinelPaths.backgroundJobsHealthURL(
            logsDirectory: logs,
            environment: ["CORTEX_DATA_ROOT": dataRoot.path],
            fileManager: fileManager
        )
        XCTAssertEqual(
            url.path,
            dataRoot.appendingPathComponent("health/background-jobs-health.json").path
        )
    }

    func testUnknownPlistStatusIsAProblemWithFixedCopy() {
        let json = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": "unexpected_enum"
            }
          ]
        }
        """
        let snapshot = BackgroundJobsReader.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.jobs[0].plistStatus, .unrecognized)
        XCTAssertTrue(snapshot.jobs[0].isProblem)
        XCTAssertEqual(snapshot.jobs[0].problemDetail, "状态看不懂")
        XCTAssertEqual(
            snapshot.jobs[0].problemDetail,
            BackgroundJobPlistStatus.unrecognizedDisplayText
        )
        XCTAssertEqual(
            BackgroundJobPlistStatus.unrecognizedDisplayText,
            ChannelUnknownKind.unrecognized.statusText
        )
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertTrue(presentation.hasProblems)
        XCTAssertEqual(presentation.problemRows.count, 1)
        XCTAssertEqual(presentation.problemRows[0].detail, "状态看不懂")
        XCTAssertEqual(presentation.summaryText, "后台任务 1 个，1 个不正常")
    }

    func testNullAndEmptyPlistStatusAreUnrecognized() {
        let nullJSON = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": null
            }
          ]
        }
        """
        let emptyJSON = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": ""
            }
          ]
        }
        """
        let nullSnapshot = BackgroundJobsReader.parse(data: Data(nullJSON.utf8))
        XCTAssertEqual(nullSnapshot.jobs[0].plistStatus, .unrecognized)
        XCTAssertTrue(nullSnapshot.jobs[0].isProblem)
        XCTAssertEqual(nullSnapshot.jobs[0].problemDetail, "状态看不懂")

        let emptySnapshot = BackgroundJobsReader.parse(data: Data(emptyJSON.utf8))
        XCTAssertEqual(emptySnapshot.jobs[0].plistStatus, .unrecognized)
        XCTAssertTrue(emptySnapshot.jobs[0].isProblem)
        XCTAssertEqual(emptySnapshot.jobs[0].problemDetail, "状态看不懂")
    }

    func testExplicitLoadedPlistStatusStaysHealthy() {
        let json = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": "loaded"
            }
          ]
        }
        """
        let snapshot = BackgroundJobsReader.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.jobs[0].plistStatus, .loaded)
        XCTAssertFalse(snapshot.jobs[0].isProblem)
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.hasProblems)
    }

    func testPlistErrorDetailLongerThan40CharactersIsTruncatedForDisplay() {
        let detail = String(repeating: "长", count: 41)
        let json = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": "unreadable",
              "plist_error_detail": "\(detail)"
            }
          ]
        }
        """
        let snapshot = BackgroundJobsReader.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.jobs[0].plistErrorDetail, detail)
        XCTAssertEqual(snapshot.jobs[0].plistErrorDetail.count, 41)
        let displayed = snapshot.jobs[0].problemDetail
        XCTAssertTrue(displayed.hasSuffix("…"))
        XCTAssertEqual(
            displayed,
            "配置读不了 · " + String(repeating: "长", count: 40) + "…"
        )
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(presentation.problemRows[0].detail, displayed)
        XCTAssertTrue(presentation.problemRows[0].detail.hasSuffix("…"))
    }

    func testPlistErrorDetailExactly40CharactersIsNotTruncated() {
        let detail = String(repeating: "短", count: 40)
        let json = """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            {
              "label": "com.falcon.cortex.web",
              "name": "界面常驻服务",
              "status": "ok",
              "plist_status": "unreadable",
              "plist_error_detail": "\(detail)"
            }
          ]
        }
        """
        let snapshot = BackgroundJobsReader.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.jobs[0].plistErrorDetail, detail)
        XCTAssertEqual(snapshot.jobs[0].problemDetail, "配置读不了 · \(detail)")
        XCTAssertFalse(snapshot.jobs[0].problemDetail.hasSuffix("…"))
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(presentation.problemRows[0].detail, "配置读不了 · \(detail)")
        XCTAssertFalse(presentation.problemRows[0].detail.hasSuffix("…"))
    }

    private func job(
        label: String,
        name: String,
        status: BackgroundJobStatus,
        lastRunText: String = "14 分钟前",
        reason: String = ""
    ) -> BackgroundJob {
        BackgroundJob(
            label: label,
            name: name,
            intervalText: "每 10 分钟",
            lastRunAt: now,
            lastRunText: lastRunText,
            status: status,
            statusText: status.displayName,
            reason: reason,
            lastExitCode: nil,
            plistStatus: .loaded,
            plistErrorDetail: ""
        )
    }
}
