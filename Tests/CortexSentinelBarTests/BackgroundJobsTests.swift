import XCTest
@testable import CortexSentinelBar

final class BackgroundJobsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-08-20T01:40:00+08:00")!

    func testAllHealthyOccupiesOneSummaryLine() {
        let snapshot = BackgroundJobsSnapshot(
            sourceState: .available,
            generatedAt: now,
            okCount: 4,
            problemCount: 0,
            jobs: [
                job(label: "com.falcon.cortex.web", name: "界面常驻服务", status: .ok),
                job(label: "com.falcon.cortex.web-guard", name: "界面守护", status: .ok),
                job(label: "com.falcon.cortex.memory-monitor", name: "内存与回收巡检", status: .ok),
                job(label: "com.falcon.cortex.mini-mirror-sync", name: "数据镜像同步", status: .ok),
            ]
        )
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(presentation.summaryText, "后台任务 4 个，全部正常")
        XCTAssertFalse(presentation.hasProblems)
        XCTAssertEqual(presentation.problemRows, [])
        XCTAssertEqual(presentation.healthyRows.count, 4)
        XCTAssertEqual(presentation.tone, .success)
    }

    func testProblemsExpandWithNameLastRunAndReason() {
        let snapshot = BackgroundJobsSnapshot(
            sourceState: .available,
            generatedAt: now,
            okCount: 3,
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
                job(label: "com.falcon.cortex.web-guard", name: "界面守护", status: .ok),
                job(label: "com.falcon.cortex.mini-mirror-sync", name: "数据镜像同步", status: .ok),
            ]
        )
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(presentation.summaryText, "后台任务 4 个，1 个不正常")
        XCTAssertTrue(presentation.hasProblems)
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.problemRows.count, 1)
        XCTAssertEqual(presentation.problemRows[0].name, "内存与回收巡检")
        XCTAssertEqual(
            presentation.problemRows[0].detail,
            "上次跑：25 小时前 · 超过两个周期没有新记录"
        )
        XCTAssertEqual(
            presentation.healthyRows.map(\.name),
            ["界面常驻服务", "界面守护", "数据镜像同步"]
        )
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

    /// COR-1862 主判据：服务活着（launchd 有 pid、退出码 0），配置文件不在
    /// 只做备注，不许把整行判红。
    func testAliveJobWithMissingPlistStaysGreenWithHint() {
        let json = fullSnapshotJSON(
            withWeb: """
            {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
            "interval_text": "常驻", "last_run_text": "正在运行", \
            "status": "ok", "status_text": "正常", "plist_status": "missing"}
            """
        )
        let snapshot = BackgroundJobsReader.parse(data: Data(json.utf8))
        XCTAssertEqual(snapshot.jobs[0].plistStatus, .missing)
        XCTAssertFalse(snapshot.jobs[0].isProblem)
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.hasProblems)
        XCTAssertEqual(presentation.problemRows, [])
        XCTAssertEqual(presentation.summaryText, "后台任务 4 个，全部正常")
        XCTAssertEqual(presentation.tone, .success)
        let webRow = presentation.healthyRows.first { $0.id == "com.falcon.cortex.web" }
        XCTAssertEqual(webRow?.detail, "常驻 · 上次跑：正在运行 · 正常 · 配置不在了，服务正常运行")
    }

    func testMissingPlistStatusFieldTreatsJobAsLoaded() {
        let snapshot = BackgroundJobsReader.parse(data: Data(fullSnapshotJSON().utf8))
        XCTAssertEqual(snapshot.jobs.count, 4)
        XCTAssertEqual(snapshot.jobs[0].plistStatus, .loaded)
        XCTAssertFalse(snapshot.jobs[0].isProblem)
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.hasProblems)
        XCTAssertEqual(presentation.summaryText, "后台任务 4 个，全部正常")
        XCTAssertEqual(presentation.problemRows, [])
    }

    func testUnreadablePlistStaysGreenWithHintAndDetail() {
        let withoutDetail = BackgroundJobsReader.parse(
            data: Data(
                fullSnapshotJSON(
                    withWeb: """
                    {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
                    "status": "ok", "plist_status": "unreadable"}
                    """
                )
                .utf8
            )
        )
        XCTAssertEqual(withoutDetail.jobs[0].plistStatus, .unreadable)
        XCTAssertFalse(withoutDetail.jobs[0].isProblem)
        let withoutPresentation = BackgroundJobsPresentation(
            snapshot: withoutDetail,
            now: now
        )
        XCTAssertFalse(withoutPresentation.hasProblems)
        let withoutRow = withoutPresentation.healthyRows
            .first { $0.id == "com.falcon.cortex.web" }
        XCTAssertEqual(withoutRow?.detail, "正常 · 配置读不了，服务正常运行")

        let withDetail = BackgroundJobsReader.parse(
            data: Data(
                fullSnapshotJSON(
                    withWeb: """
                    {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
                    "status": "ok", "plist_status": "unreadable", \
                    "plist_error_detail": "permission denied"}
                    """
                )
                .utf8
            )
        )
        XCTAssertFalse(withDetail.jobs[0].isProblem)
        let withPresentation = BackgroundJobsPresentation(snapshot: withDetail, now: now)
        XCTAssertFalse(withPresentation.hasProblems)
        let withRow = withPresentation.healthyRows
            .first { $0.id == "com.falcon.cortex.web" }
        XCTAssertEqual(withRow?.detail, "正常 · 配置读不了（permission denied），服务正常运行")
        XCTAssertFalse(withRow?.detail.contains("\n") == true)
    }

    func testUnknownPlistStatusStaysGreenWithHint() {
        let snapshot = BackgroundJobsReader.parse(
            data: Data(
                fullSnapshotJSON(
                    withWeb: """
                    {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
                    "status": "ok", "plist_status": "unexpected_enum"}
                    """
                )
                .utf8
            )
        )
        XCTAssertEqual(snapshot.jobs[0].plistStatus, .unrecognized)
        XCTAssertFalse(snapshot.jobs[0].isProblem)
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.hasProblems)
        XCTAssertEqual(presentation.problemRows, [])
        let webRow = presentation.healthyRows.first { $0.id == "com.falcon.cortex.web" }
        XCTAssertEqual(webRow?.detail, "正常 · 状态看不懂，按运行状态显示")
        XCTAssertEqual(
            BackgroundJobPlistStatus.unrecognizedDisplayText,
            ChannelUnknownKind.unrecognized.statusText
        )
    }

    func testNullAndEmptyPlistStatusAreUnrecognized() {
        let nullSnapshot = BackgroundJobsReader.parse(
            data: Data(
                fullSnapshotJSON(
                    withWeb: """
                    {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
                    "status": "ok", "plist_status": null}
                    """
                )
                .utf8
            )
        )
        XCTAssertEqual(nullSnapshot.jobs[0].plistStatus, .unrecognized)
        XCTAssertFalse(nullSnapshot.jobs[0].isProblem)

        let emptySnapshot = BackgroundJobsReader.parse(
            data: Data(
                fullSnapshotJSON(
                    withWeb: """
                    {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
                    "status": "ok", "plist_status": ""}
                    """
                )
                .utf8
            )
        )
        XCTAssertEqual(emptySnapshot.jobs[0].plistStatus, .unrecognized)
        XCTAssertFalse(emptySnapshot.jobs[0].isProblem)
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

    func testExplicitLoadedPlistStatusStaysHealthy() {
        let snapshot = BackgroundJobsReader.parse(data: Data(fullSnapshotJSON().utf8))
        XCTAssertEqual(snapshot.jobs[0].plistStatus, .loaded)
        XCTAssertFalse(snapshot.jobs[0].isProblem)
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.hasProblems)
    }

    func testPlistErrorDetailLongerThan40CharactersIsTruncatedInHint() {
        let detail = String(repeating: "长", count: 41)
        let snapshot = BackgroundJobsReader.parse(
            data: Data(
                fullSnapshotJSON(
                    withWeb: """
                    {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
                    "status": "ok", "plist_status": "unreadable", \
                    "plist_error_detail": "\(detail)"}
                    """
                )
                .utf8
            )
        )
        XCTAssertEqual(snapshot.jobs[0].plistErrorDetail, detail)
        XCTAssertEqual(snapshot.jobs[0].plistErrorDetail.count, 41)
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.hasProblems)
        let row = presentation.healthyRows.first { $0.id == "com.falcon.cortex.web" }
        XCTAssertEqual(
            row?.detail,
            "正常 · 配置读不了（" + String(repeating: "长", count: 40) + "…），服务正常运行"
        )
    }

    func testPlistErrorDetailExactly40CharactersIsNotTruncated() {
        let detail = String(repeating: "短", count: 40)
        let snapshot = BackgroundJobsReader.parse(
            data: Data(
                fullSnapshotJSON(
                    withWeb: """
                    {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
                    "status": "ok", "plist_status": "unreadable", \
                    "plist_error_detail": "\(detail)"}
                    """
                )
                .utf8
            )
        )
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.hasProblems)
        let row = presentation.healthyRows.first { $0.id == "com.falcon.cortex.web" }
        XCTAssertEqual(row?.detail, "正常 · 配置读不了（\(detail)），服务正常运行")
        XCTAssertFalse(row?.detail.contains("…") == true)
    }

    /// COR-1862 验收判据 2 的显示侧：关键常驻服务从快照里消失
    /// （launchctl list 里没有它 = 真没在跑）必须红。
    func testCriticalJobMissingFromFreshSnapshotIsRed() {
        let snapshot = BackgroundJobsReader.parse(data: Data(fullSnapshotJSON(withWeb: nil).utf8))
        XCTAssertEqual(snapshot.jobs.count, 3)
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertTrue(presentation.hasProblems)
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.problemRows.count, 1)
        XCTAssertEqual(presentation.problemRows[0].id, "com.falcon.cortex.web")
        XCTAssertEqual(presentation.problemRows[0].name, "界面常驻服务")
        XCTAssertEqual(
            presentation.problemRows[0].detail,
            "不在系统服务里，launchctl 里没有这个任务"
        )
        XCTAssertEqual(presentation.summaryText, "后台任务 3 个，1 个不正常")
    }

    func testCriticalJobBackInSnapshotClearsAbsentRow() {
        let snapshot = BackgroundJobsReader.parse(data: Data(fullSnapshotJSON().utf8))
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertFalse(presentation.problemRows.contains { $0.id == "com.falcon.cortex.web" })
        XCTAssertFalse(presentation.hasProblems)
    }

    /// 快照过期时只报「未更新」，缺席检查让位，不叠双份噪音。
    func testStaleSnapshotDoesNotStackAbsentCriticalRowOnTopOfStaleWarning() {
        let generatedAt = now.addingTimeInterval(-40 * 60)
        let payload = fullSnapshotJSON(withWeb: nil)
            .replacingOccurrences(
                of: "\"generated_at\": \"2026-08-20T01:40:00+08:00\"",
                with: "\"generated_at\": \"2026-08-20T01:00:00+08:00\""
            )
        let snapshot = BackgroundJobsReader.parse(data: Data(payload.utf8))
        let presentation = BackgroundJobsPresentation(snapshot: snapshot, now: now)
        XCTAssertTrue(presentation.snapshotStale)
        XCTAssertTrue(presentation.problemRows.contains { $0.name == "健康快照" })
        XCTAssertFalse(presentation.problemRows.contains { $0.id == "com.falcon.cortex.web" })
    }

    private func fullSnapshotJSON(withWeb webObject: String? = BackgroundJobsTests.loadedWebJob) -> String {
        var objects: [String] = []
        if let webObject {
            objects.append(webObject)
        }
        objects.append(
            Self.okCriticalJob(label: "com.falcon.cortex.web-guard", name: "界面守护")
        )
        objects.append(
            Self.okCriticalJob(label: "com.falcon.cortex.memory-monitor", name: "内存与回收巡检")
        )
        objects.append(
            Self.okCriticalJob(label: "com.falcon.cortex.mini-mirror-sync", name: "数据镜像同步")
        )
        return """
        {
          "generated_at": "2026-08-20T01:40:00+08:00",
          "jobs": [
            \(objects.joined(separator: ",\n            "))
          ]
        }
        """
    }

    private static let loadedWebJob = """
    {"label": "com.falcon.cortex.web", "name": "界面常驻服务", \
    "interval_text": "常驻", "last_run_text": "14 分钟前", \
    "status": "ok", "status_text": "正常", "plist_status": "loaded"}
    """

    private static func okCriticalJob(label: String, name: String) -> String {
        """
        {"label": "\(label)", "name": "\(name)", "interval_text": "每 10 分钟", \
        "last_run_text": "14 分钟前", "status": "ok", "status_text": "正常", \
        "plist_status": "loaded"}
        """
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
