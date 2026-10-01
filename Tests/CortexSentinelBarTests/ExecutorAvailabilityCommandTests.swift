import XCTest

@testable import CortexSentinelBar

/// 哨兵点灰/恢复的命令侧（COR-9242）：--board-only 命令的组装、成败折句、
/// 超时与 information 短路。临时 git 仓放假清单假脚本（与派工路由状态测试
/// 同一搭法），不碰真看板；公开仓里全部中性假数据。
final class ExecutorAvailabilityCommandTests: XCTestCase {
    private var tempRoot: URL!
    private let realRunner = CortexProcessSubprocessRunner()

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-toggle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private static let executorID = "06ff0149-b857-48c1-bb06-82c2290ab129"

    private static func script(_ body: String) -> String {
        """
        import sys
        \(body)
        """
    }

    /// 临时 git 仓：`scripts/dispatch_route_preview.files` 清单 + 假
    /// executor_availability.py（argv 记进标记文件再按脚本体行事），
    /// 并造出 refs/remotes/origin/main。
    @discardableResult
    private func makeScriptRepo(body: String) async throws -> URL {
        let repo = tempRoot.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try "# 清单\nscripts/executor_availability.py\n".write(
            to: repo.appendingPathComponent("scripts/dispatch_route_preview.files"),
            atomically: true,
            encoding: .utf8
        )
        try Self.script(body).write(
            to: repo.appendingPathComponent("scripts/executor_availability.py"),
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
        XCTAssertEqual(result.exitCode, 0, "git \(arguments.first ?? "") 失败")
    }

    private func makeConfiguration(cacheRoot: URL, timeout: TimeInterval = 30) -> ExecutorAvailabilityCommandFetcher.Configuration {
        var configuration = ExecutorAvailabilityCommandFetcher.Configuration(cacheRoot: cacheRoot)
        configuration.scriptTimeout = timeout
        return configuration
    }

    private func run(
        _ action: CortexRoutePreviewDisplay.DispatchDotAction,
        repo: URL,
        configuration: ExecutorAvailabilityCommandFetcher.Configuration
    ) async -> ExecutorAvailabilityCommandFetcher.Outcome {
        await ExecutorAvailabilityCommandFetcher.run(
            action: action,
            environment: ["CORTEX_REPO_ROOT": repo.path],
            watchDirectory: nil,
            fallbackRepositoryRoot: repo,
            homeDirectory: tempRoot.path,
            configuration: configuration,
            runner: realRunner,
            fileManager: FileManager.default
        )
    }

    private func markerText(in cacheRoot: URL) throws -> String? {
        let caches = try FileManager.default.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: nil
        )
        for directory in caches where !directory.lastPathComponent.hasPrefix(".") {
            let marker = directory.appendingPathComponent("argv-marker.txt")
            if FileManager.default.fileExists(atPath: marker.path) {
                return try String(contentsOf: marker, encoding: .utf8)
            }
        }
        return nil
    }

    // MARK: 成功：pause / resume 组的都是 --board-only 命令

    func testPauseRunsBoardOnlyCommandAndSucceeds() async throws {
        let repo = try await makeScriptRepo(body: """
        with open("argv-marker.txt", "w", encoding="utf-8") as marker:
            marker.write(" ".join(sys.argv[1:]))
        print("EXECUTOR_PAUSED_ON_BOARD target=x field=description")
        """)
        let cacheRoot = tempRoot.appendingPathComponent("cache-pause", isDirectory: true)
        let outcome = await run(
            .pauseBoardOnly(executorID: Self.executorID),
            repo: repo,
            configuration: makeConfiguration(cacheRoot: cacheRoot)
        )
        XCTAssertEqual(outcome, .success(message: "停派已写上看板，等预案刷新变灰"))
        let argv = try XCTUnwrap(try markerText(in: cacheRoot))
        XCTAssertEqual(
            argv,
            "pause \(Self.executorID) --board-only",
            "点的就是 --board-only 命令，不带 --quote/--reason"
        )
    }

    func testResumeRunsBoardOnlyCommandAndSucceeds() async throws {
        let repo = try await makeScriptRepo(body: """
        with open("argv-marker.txt", "w", encoding="utf-8") as marker:
            marker.write(" ".join(sys.argv[1:]))
        print("EXECUTOR_RESUMED_ON_BOARD target=x field=description")
        """)
        let cacheRoot = tempRoot.appendingPathComponent("cache-resume", isDirectory: true)
        let outcome = await run(
            .resumeBoardOnly(executorID: Self.executorID),
            repo: repo,
            configuration: makeConfiguration(cacheRoot: cacheRoot)
        )
        XCTAssertEqual(outcome, .success(message: "停派标记已去掉，等预案刷新变绿"))
        let argv = try XCTUnwrap(try markerText(in: cacheRoot))
        XCTAssertEqual(argv, "resume \(Self.executorID) --board-only")
    }

    // MARK: 失败：脚本的人话上屏，不吞进退出码

    func testFailureSurfacesScriptsHumanReason() async throws {
        let repo = try await makeScriptRepo(body: """
        sys.stderr.write("EXECUTOR_AVAILABILITY_RESUME_FAILED 说明里没有「停派：他在哨兵上点灰」标记行，看板没动。\\n")
        sys.exit(2)
        """)
        let outcome = await run(
            .resumeBoardOnly(executorID: Self.executorID),
            repo: repo,
            configuration: makeConfiguration(cacheRoot: tempRoot.appendingPathComponent("cache-fail", isDirectory: true))
        )
        XCTAssertEqual(
            outcome,
            .failure(reason: "说明里没有「停派：他在哨兵上点灰」标记行，看板没动。")
        )
    }

    func testFailureWithoutHumanTextFallsBackToExitCode() {
        let reason = ExecutorAvailabilityCommandFetcher.failureReason(
            subcommand: "pause",
            exitCode: 3,
            standardError: Data(),
            standardOutput: Data()
        )
        XCTAssertEqual(reason, "停派命令退出码 3")
    }

    func testFailureReasonPrefersStderrLastLineAndStripsPrefix() {
        let reason = ExecutorAvailabilityCommandFetcher.failureReason(
            subcommand: "resume",
            exitCode: 2,
            standardError: Data("EXECUTOR_AVAILABILITY_RESUME_FAILED agent get 读不到\n".utf8),
            standardOutput: Data("EXECUTOR_RESUMED_ON_BOARD nothing\n".utf8)
        )
        XCTAssertEqual(reason, "agent get 读不到")
    }

    // MARK: 超时

    func testTimeoutFoldsIntoHumanReason() async throws {
        let repo = try await makeScriptRepo(body: "import time\ntime.sleep(5)\n")
        let outcome = await run(
            .pauseBoardOnly(executorID: Self.executorID),
            repo: repo,
            configuration: makeConfiguration(
                cacheRoot: tempRoot.appendingPathComponent("cache-timeout", isDirectory: true),
                timeout: 0.5
            )
        )
        XCTAssertEqual(outcome, .failure(reason: "命令跑超时了"))
    }

    // MARK: information 短路：不发命令也不认仓

    func testInformationActionShortCircuits() async {
        // 仓根全空：真走到导出必失败「找不到 cortex 仓」；短路则原样折回原因。
        let outcome = await ExecutorAvailabilityCommandFetcher.run(
            action: .information("连续被拒冷却中"),
            environment: [:],
            watchDirectory: nil,
            fallbackRepositoryRoot: nil,
            homeDirectory: tempRoot.path,
            runner: realRunner
        )
        XCTAssertEqual(outcome, .failure(reason: "连续被拒冷却中"))
    }

    // MARK: 反馈显示窗

    func testFeedbackVisibilityWindow() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let feedback = DispatchToggleFeedback(text: "停派已写上看板", at: at)
        XCTAssertTrue(feedback.isVisible(now: at.addingTimeInterval(59)))
        XCTAssertFalse(feedback.isVisible(now: at.addingTimeInterval(61)))
    }
}
