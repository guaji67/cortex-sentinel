import XCTest
@testable import CortexSentinelBar

/// 通道汇总过期自刷：什么时候叫 cortex 重算、怎么叫、店里怎么接。
/// 公开仓，全部用中性假数据。
final class CortexChannelStatusRefreshTests: XCTestCase {
    private var tempRoot: URL!
    private let realRunner = CortexProcessSubprocessRunner()
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-status-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - 判定

    func testNoSnapshotRefreshesOnlyWhenLinesExist() {
        XCTAssertFalse(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: nil, newestLineStatusModifiedAt: nil, lastAttempt: nil, now: base
        ), "空目录不去碰 git")
        XCTAssertTrue(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: nil, newestLineStatusModifiedAt: base, lastAttempt: nil, now: base
        ))
    }

    /// 实锤场景：汇总停在 18:35，CodeBuddy 线 19:49 起跑、一直在写状态。
    func testLineNewerThanSnapshotRefreshes() {
        XCTAssertTrue(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: base,
            newestLineStatusModifiedAt: base.addingTimeInterval(74 * 60),
            lastAttempt: nil,
            now: base.addingTimeInterval(75 * 60)
        ))
    }

    func testFreshSnapshotAheadOfLinesSkips() {
        XCTAssertFalse(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: base,
            newestLineStatusModifiedAt: base.addingTimeInterval(-30),
            lastAttempt: nil,
            now: base.addingTimeInterval(5 * 60)
        ))
    }

    func testOldSnapshotRefreshesEvenWithoutNewLines() {
        XCTAssertTrue(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: base,
            newestLineStatusModifiedAt: nil,
            lastAttempt: nil,
            now: base.addingTimeInterval(CortexChannelStatusRefresh.maximumSnapshotAge + 1)
        ))
    }

    func testRecentAttemptThrottles() {
        let now = base.addingTimeInterval(75 * 60)
        let recent = CortexChannelStatusRefresh.Attempt(at: now.addingTimeInterval(-30), failed: false)
        XCTAssertFalse(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: base, newestLineStatusModifiedAt: now, lastAttempt: recent, now: now
        ))
        let older = CortexChannelStatusRefresh.Attempt(
            at: now.addingTimeInterval(-CortexChannelStatusRefresh.minimumInterval - 1), failed: false
        )
        XCTAssertTrue(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: base, newestLineStatusModifiedAt: now, lastAttempt: older, now: now
        ))
    }

    func testFailedAttemptBacksOffLonger() {
        let now = base.addingTimeInterval(75 * 60)
        let failedRecently = CortexChannelStatusRefresh.Attempt(at: now.addingTimeInterval(-5 * 60), failed: true)
        XCTAssertFalse(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: base, newestLineStatusModifiedAt: now, lastAttempt: failedRecently, now: now
        ))
        let failedLongAgo = CortexChannelStatusRefresh.Attempt(
            at: now.addingTimeInterval(-CortexChannelStatusRefresh.failureBackoff - 1), failed: true
        )
        XCTAssertTrue(CortexChannelStatusRefresh.shouldRefresh(
            snapshotModifiedAt: base, newestLineStatusModifiedAt: now, lastAttempt: failedLongAgo, now: now
        ))
    }

    func testNoProductionRefresherUnderXCTest() {
        XCTAssertNil(CortexChannelStatusRefresh.productionRefresherUnlessTesting(
            processEnvironment: ["XCTestConfigurationFilePath": "/tmp/fixture.xctestconfiguration"]
        ))
        XCTAssertNotNil(CortexChannelStatusRefresh.productionRefresherUnlessTesting(processEnvironment: [:]))
    }

    // MARK: - 取数流程

    /// 假脚本：记下 argv 与环境，把汇总写进 --logs-dir 指的目录。
    private static let fakeScript = """
        import json
        import os
        import sys

        with open("argv-marker.txt", "w", encoding="utf-8") as marker:
            marker.write(" ".join(sys.argv[1:]) + "\\n" + os.environ.get("CORTEX_LOG_ROOT", ""))
        logs = sys.argv[sys.argv.index("--logs-dir") + 1]
        payload = {
            "generated_at": "2026-09-24T20:40:00+08:00",
            "channels": {"codebuddy": {"status": "alive", "evidence": "1 条在跑", "running": 1}},
        }
        with open(os.path.join(logs, "channel-status.json"), "w", encoding="utf-8") as out:
            json.dump(payload, out)
        """

    private static let failingScript = "import sys\nsys.exit(3)\n"

    private func makeScriptRepo(scriptText: String = fakeScript, withManifest: Bool = true) async throws -> URL {
        let repo = tempRoot.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("logs"), withIntermediateDirectories: true)
        if withManifest {
            try "# 清单\nscripts/channel_status.py\n".write(
                to: repo.appendingPathComponent("scripts/channel_status.files"),
                atomically: true,
                encoding: .utf8
            )
        }
        try scriptText.write(
            to: repo.appendingPathComponent("scripts/channel_status.py"),
            atomically: true,
            encoding: .utf8
        )
        try await runGit(["init"], at: repo)
        try await runGit(["add", "."], at: repo)
        try await runGit(["-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-m", "fixture", "--no-gpg-sign"], at: repo)
        try await runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], at: repo)
        return repo
    }

    private func runGit(_ arguments: [String], at repo: URL) async throws {
        let result = await realRunner.run(
            executablePath: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: repo,
            environment: nil,
            stdin: nil,
            timeout: 60
        )
        XCTAssertEqual(result.exitCode, 0, "git \(arguments.first ?? "") 失败：\(String(data: result.standardError, encoding: .utf8) ?? "")")
    }

    private func refresh(repo: URL, watchDirectory: URL) async -> CortexChannelStatusRefresh.Outcome {
        await CortexChannelStatusRefresh.refresh(
            request: CortexChannelStatusRefresh.Request(
                environment: [:],
                watchDirectory: watchDirectory,
                fallbackRepositoryRoot: repo,
                homeDirectory: repo.path
            ),
            configuration: CortexChannelStatusRefresh.Configuration(
                cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true)
            ),
            runner: realRunner
        )
    }

    /// 成功路径：脚本在导出缓存里跑，收到 --logs-dir <监视目录>，汇总写回监视目录。
    func testRefreshRunsExportedScriptAgainstWatchDirectory() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo()
        let watch = repo.appendingPathComponent("logs", isDirectory: true)
        let outcome = await refresh(repo: repo, watchDirectory: watch)
        XCTAssertEqual(outcome, .refreshed)

        let snapshot = SentinelFileReader.readChannelStatus(at: watch.appendingPathComponent("channel-status.json"))
        XCTAssertEqual(snapshot.codebuddy.status, .alive)
        XCTAssertEqual(snapshot.codebuddy.running, 1)

        let cacheRoot = tempRoot.appendingPathComponent("cache", isDirectory: true)
        let cacheDirs = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(cacheDirs.count, 1)
        let marker = try String(contentsOf: cacheDirs[0].appendingPathComponent("argv-marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, "--logs-dir \(watch.path)\n\(watch.path)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheDirs[0].appendingPathComponent("channel-status.json").path),
            "汇总不许落进导出缓存"
        )
    }

    func testMissingManifestFailsWithPlainReason() async throws {
        let repo = try await makeScriptRepo(withManifest: false)
        let outcome = await refresh(repo: repo, watchDirectory: repo.appendingPathComponent("logs"))
        XCTAssertEqual(outcome, .failure(reason: "cortex 仓里还没有这个脚本"))
    }

    func testScriptFailureReportsExitCode() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo(scriptText: Self.failingScript)
        let outcome = await refresh(repo: repo, watchDirectory: repo.appendingPathComponent("logs"))
        XCTAssertEqual(outcome, .failure(reason: "脚本退出码 3"))
    }

    // MARK: - 店里的接线

    /// 汇总停在旧的「无数据」、CodeBuddy 线在写状态：读一轮盘就叫重算，算完立刻
    /// 上屏新卡；紧接着再读一轮不重复叫（节流）。
    @MainActor
    func testStoreRefreshesStaleSnapshotOnceAndShowsNewCard() async throws {
        let logs = tempRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let channelURL = logs.appendingPathComponent("channel-status.json")
        try """
            {"generated_at":"2026-09-24T18:35:13+08:00","channels":{"codebuddy":{"status":"unknown","evidence":"无数据","running":0}}}
            """.write(to: channelURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 3600)],
            ofItemAtPath: channelURL.path
        )
        try """
            {"engine":"codebuddy","slug":"fixture-line","state":"running","agent_pid":\(ProcessInfo.processInfo.processIdentifier),
             "started_at":"2026-09-24T19:49:28+08:00","updated_at":"2026-09-24T20:33:11+08:00"}
            """.write(to: logs.appendingPathComponent("codebuddy-fixture-line.status.json"), atomically: true, encoding: .utf8)

        let calls = CallCounter()
        let refresher: CortexChannelStatusRefresh.Refresher = { request in
            await calls.increment()
            try? """
                {"generated_at":"2026-09-24T20:40:00+08:00","channels":{"codebuddy":{"status":"alive","evidence":"1 条在跑","running":1}}}
                """.write(
                    to: request.watchDirectory.appendingPathComponent("channel-status.json"),
                    atomically: true,
                    encoding: .utf8
                )
            return .refreshed
        }
        let paths = SentinelPaths(
            repositoryRoot: tempRoot,
            poolDirectory: tempRoot,
            aioDatabaseURL: tempRoot.appendingPathComponent("aio.db"),
            aioManifestURL: tempRoot.appendingPathComponent("manifest.json"),
            codexConfigURL: tempRoot.appendingPathComponent("config.toml"),
            codexAuthURL: tempRoot.appendingPathComponent("auth.json"),
            inputStatusURL: URL(string: "https://status.fixture.test/api/status")!,
            logsDirectory: logs
        )
        let store = SentinelStore(paths: paths, environment: [:], channelStatusRefresher: refresher)

        await store.refreshStatuses()
        for _ in 0..<200 where store.channelStatus.codebuddy.status != .alive {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.channelStatus.codebuddy.status, .alive, "重算后应立刻上屏新卡")
        XCTAssertEqual(store.channelStatus.codebuddy.running, 1)

        await store.refreshStatuses()
        try await Task.sleep(nanoseconds: 50_000_000)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1, "节流窗内不重复叫重算")
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
