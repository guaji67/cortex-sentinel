import XCTest
@testable import CortexSentinelBar

/// 派工路由状态的显示规则与取数流程。
/// 公开仓，全部用中性假数据：sha 用占位串，文案用「路由已是最新」这类样例句。
final class CortexGateRuntimeStatusTests: XCTestCase {
    // MARK: - 解码

    /// schema 1 七个态全部解得出，字段一一对应。
    func testDecodeSevenStates() throws {
        let states: [(state: String, textZH: String)] = [
            ("ok", "路由已是最新"),
            ("behind", "落后 3 个提交，已自动补"),
            ("not_installed", "路由还没装"),
            ("refresh_failed", "刷新没踢成"),
            ("repo_missing", "找不到 cortex 仓"),
            ("venv_missing", "没找到可用的 Python"),
            ("unknown", "路由状态未知"),
        ]
        for sample in states {
            let payload = try Self.decode(
                state: sample.state,
                textZH: sample.textZH,
                behind: sample.state == "behind" ? 3 : nil
            )
            XCTAssertEqual(payload.schema, 1, sample.state)
            XCTAssertEqual(payload.state, sample.state, sample.state)
            XCTAssertEqual(payload.textZH, sample.textZH, sample.state)
            XCTAssertNotNil(payload.checkedAtText, sample.state)
            // 布尔随样例走：not_installed / repo_missing 没装，ok 才就绪。
            XCTAssertEqual(
                payload.installed,
                sample.state != "not_installed" && sample.state != "repo_missing",
                sample.state
            )
            XCTAssertEqual(payload.routerReady, sample.state == "ok", sample.state)
            if sample.state == "behind" {
                XCTAssertEqual(payload.behind, 3, sample.state)
            } else {
                XCTAssertNil(payload.behind, sample.state)
            }
            XCTAssertNotNil(payload.ensure, sample.state)
        }
        // ok 才是 ok。
        XCTAssertTrue(try Self.decode(state: "ok", textZH: "路由已是最新").stateIsOK)
        XCTAssertFalse(try Self.decode(state: "behind", textZH: "落后").stateIsOK)
        XCTAssertFalse(try Self.decode(state: "unknown", textZH: "未知").stateIsOK)
    }

    /// 缺 ensure / 布尔缺省也能解（宽松解码，只 schema 必填）。
    func testDecodeToleratesMissingOptionalFields() throws {
        let data = Data("""
        {"schema": 1, "state": "not_installed", "text_zh": "路由还没装"}
        """.utf8)
        let payload = try JSONDecoder().decode(CortexGateRuntimeStatusPayload.self, from: data)
        XCTAssertEqual(payload.state, "not_installed")
        XCTAssertEqual(payload.textZH, "路由还没装")
        XCTAssertFalse(payload.installed)
        XCTAssertFalse(payload.routerReady)
        XCTAssertNil(payload.ensure)
        XCTAssertNil(payload.behind)
        XCTAssertNil(payload.binStale)
    }

    // MARK: - 取数流程

    private var tempRoot: URL!
    private let realRunner = CortexProcessSubprocessRunner()

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// 假脚本：把 argv 写进缓存目录的标记文件（证明跑的确实是 --json --ensure），
    /// 再打印固定形状的派工路由状态。
    private static let fakeScriptThatRecordsArguments = """
        import json
        import sys

        with open("argv-marker.txt", "w", encoding="utf-8") as marker:
            marker.write(" ".join(sys.argv[1:]))
        payload = {
            "schema": 1,
            "checked_at": "2026-09-14T02:00:00Z",
            "state": "ok",
            "text_zh": "路由已是最新",
            "installed": True,
            "current_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "origin_main_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "behind": None,
            "router_ready": True,
            "bin_stale": False,
            "refresh_failed": None,
            "marker_age_seconds": 12,
            "ensure": {"action": "none", "detail": "路由没旧，不用动"},
        }
        print(json.dumps(payload, ensure_ascii=False))
        """

    private static func gatePayloadJSON(state: String, textZH: String, behind: Int?) -> Data {
        let payload: [String: Any] = [
            "schema": 1,
            "checked_at": "2026-09-14T02:00:00Z",
            "state": state,
            "text_zh": textZH,
            "installed": state != "not_installed" && state != "repo_missing",
            "current_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "origin_main_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "behind": behind.map(NSNumber.init(value:)) ?? NSNull(),
            "router_ready": state == "ok",
            "bin_stale": NSNull(),
            "refresh_failed": state == "refresh_failed" ? "踢刷新失败" : NSNull(),
            "marker_age_seconds": 12,
            "ensure": ["action": "none", "detail": ""],
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private static func decode(state: String, textZH: String, behind: Int? = nil) throws -> CortexGateRuntimeStatusPayload {
        try JSONDecoder().decode(CortexGateRuntimeStatusPayload.self, from: gatePayloadJSON(state: state, textZH: textZH, behind: behind))
    }

    /// 临时 git 仓：放假清单和假脚本，并造出 refs/remotes/origin/main。
    @discardableResult
    private func makeScriptRepo(
        scriptText: String = CortexGateRuntimeStatusTests.fakeScriptThatRecordsArguments,
        withManifest: Bool = true
    ) async throws -> URL {
        let repo = tempRoot.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("scripts/gates"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("logs"), withIntermediateDirectories: true)
        if withManifest {
            try "# 清单\nscripts/gates/gate_runtime_status.py\n".write(
                to: repo.appendingPathComponent("scripts/gate_runtime_status.files"),
                atomically: true,
                encoding: .utf8
            )
        }
        try scriptText.write(
            to: repo.appendingPathComponent("scripts/gates/gate_runtime_status.py"),
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
        XCTAssertEqual(
            result.exitCode,
            0,
            "git \(arguments.first ?? "") 失败：\(String(data: result.standardError, encoding: .utf8) ?? "")"
        )
    }

    private func fetch(
        repo: URL,
        configuration: CortexGateRuntimeStatusFetcher.Configuration
    ) async -> CortexGateRuntimeStatusOutcome {
        await CortexGateRuntimeStatusFetcher.fetch(
            environment: [:],
            watchDirectory: repo.appendingPathComponent("logs"),
            fallbackRepositoryRoot: repo,
            homeDirectory: repo.path,
            configuration: configuration,
            runner: realRunner
        )
    }

    private func cacheConfiguration() -> CortexGateRuntimeStatusFetcher.Configuration {
        CortexGateRuntimeStatusFetcher.Configuration(
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true)
        )
    }

    /// 成功路径：脚本在缓存目录里跑、收到 --json --ensure、payload 解出来，
    /// 脚本内容没变时不重导缓存。
    func testFetchSuccessPassesEnsureArgumentsAndCaches() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo()
        let cacheRoot = tempRoot.appendingPathComponent("cache", isDirectory: true)
        let configuration = CortexGateRuntimeStatusFetcher.Configuration(cacheRoot: cacheRoot)

        let first = await fetch(repo: repo, configuration: configuration)
        guard case let .success(payload) = first else {
            XCTFail("第一次取数应该成功：\(first)")
            return
        }
        XCTAssertEqual(payload.state, "ok")
        XCTAssertEqual(payload.textZH, "路由已是最新")
        XCTAssertTrue(payload.stateIsOK)
        XCTAssertEqual(payload.ensure?.action, "none")

        // 脚本收到的 argv 就是 --json --ensure。
        let cacheDirs = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(cacheDirs.count, 1)
        XCTAssertEqual(cacheDirs[0].lastPathComponent.count, 64, "缓存目录名是 ls-tree 输出的哈希")
        let markerURL = cacheDirs[0].appendingPathComponent("argv-marker.txt")
        let markerText = try String(contentsOf: markerURL, encoding: .utf8)
        XCTAssertEqual(markerText, "--json --ensure")

        // 第二轮：缓存键稳定，标记文件没被清（没重导缓存），脚本照常跑。
        let keepURL = cacheDirs[0].appendingPathComponent("argv-marker.txt")
        let second = await fetch(repo: repo, configuration: configuration)
        guard case .success = second else {
            XCTFail("第二次取数应该成功：\(second)")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepURL.path), "第二次不该重导缓存")
    }

    /// 清单读不到：cortex 侧脚本没落地时走这条失败路径，折成人话。
    func testMissingManifestFailsWithPlainReason() async throws {
        let repo = try await makeScriptRepo(withManifest: false)
        let outcome = await fetch(repo: repo, configuration: cacheConfiguration())
        XCTAssertEqual(outcome, .failure(reason: "cortex 仓里还没有这个脚本"))
    }

    /// 找不到仓：折成人话。
    func testMissingRepoFailsWithPlainReason() async throws {
        let nowhere = tempRoot.appendingPathComponent("nowhere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: nowhere, withIntermediateDirectories: true)
        let outcome = await CortexGateRuntimeStatusFetcher.fetch(
            environment: [:],
            watchDirectory: nowhere,
            fallbackRepositoryRoot: nowhere,
            homeDirectory: nowhere.path,
            configuration: cacheConfiguration(),
            runner: realRunner
        )
        XCTAssertEqual(outcome, .failure(reason: "找不到 cortex 仓"))
    }

    /// 起脚本的环境：注入的 runner 收到的 CORTEX_REPO_ROOT 是本轮认到并通过
    /// rev-parse 校验的仓根，PATH 仍在，HOME 照旧。
    func testScriptEnvironmentCarriesRecognizedRepoRoot() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo()
        let runner = RecordingSubprocessRunner()
        let outcome = await CortexGateRuntimeStatusFetcher.fetch(
            environment: [:],
            watchDirectory: repo.appendingPathComponent("logs"),
            fallbackRepositoryRoot: repo,
            homeDirectory: repo.path,
            configuration: cacheConfiguration(),
            runner: runner
        )
        guard case .success = outcome else {
            XCTFail("取数应该成功：\(outcome)")
            return
        }

        // 期望的仓根 = 对夹具仓跑同一条 rev-parse 的结果（生产代码认仓就这么认的）。
        let probe = await realRunner.run(
            executablePath: "/usr/bin/git",
            arguments: ["-C", repo.path, "rev-parse", "--show-toplevel"],
            workingDirectory: nil,
            environment: nil,
            stdin: nil,
            timeout: 60
        )
        let expectedRoot = String(data: probe.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(expectedRoot.isEmpty)

        // 起脚本那次调用（解释器路径，非 git / tar）收到的环境。
        let scriptCalls = runner.calls.filter { $0.executablePath != "/usr/bin/git" && $0.executablePath != "/usr/bin/tar" }
        XCTAssertEqual(scriptCalls.count, 1, "脚本只起一次")
        let environment = try XCTUnwrap(scriptCalls.first?.environment)
        XCTAssertEqual(environment["CORTEX_REPO_ROOT"], expectedRoot, "仓根就是本轮认到的那个")
        XCTAssertEqual(
            environment["PATH"],
            "/usr/bin:/bin:/usr/sbin:/sbin:\(repo.path)/.local/bin:/opt/homebrew/bin",
            "PATH 还是那条固定路径"
        )
        XCTAssertEqual(environment["HOME"], repo.path)
    }

    /// 起脚本的纯函数：HOME、固定 PATH、CORTEX_REPO_ROOT 三样，不多不少。
    func testScriptEnvironmentDictionary() {
        let root = URL(fileURLWithPath: "/tmp/fixture-repo", isDirectory: true)
        let environment = CortexGitScriptExport.scriptEnvironment(homeDirectory: "/tmp/fixture-home", repoRoot: root)
        XCTAssertEqual(environment["HOME"], "/tmp/fixture-home")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/tmp/fixture-home/.local/bin:/opt/homebrew/bin")
        XCTAssertEqual(environment["CORTEX_REPO_ROOT"], "/tmp/fixture-repo")
        XCTAssertEqual(environment.count, 3)
    }

    /// 认仓失败：不起脚本（原行为），只有认仓的 git 探测。
    func testRepoRecognitionFailureDoesNotStartScript() async throws {
        let nowhere = tempRoot.appendingPathComponent("nowhere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: nowhere, withIntermediateDirectories: true)
        let runner = RecordingSubprocessRunner()
        let outcome = await CortexGateRuntimeStatusFetcher.fetch(
            environment: [:],
            watchDirectory: nowhere,
            fallbackRepositoryRoot: nowhere,
            homeDirectory: nowhere.path,
            configuration: cacheConfiguration(),
            runner: runner
        )
        XCTAssertEqual(outcome, .failure(reason: "找不到 cortex 仓"))
        let nonGitCalls = runner.calls.filter { $0.executablePath != "/usr/bin/git" }
        XCTAssertTrue(nonGitCalls.isEmpty, "认仓失败就不该起脚本")
    }

    /// schema 不是 1：整份当没有。
    func testSchemaOtherThanOneTreatedAsAbsent() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo(scriptText: "print('{\"schema\": 9, \"state\": \"ok\"}')\n")
        let outcome = await fetch(repo: repo, configuration: cacheConfiguration())
        XCTAssertEqual(outcome, .failure(reason: "脚本版本不认识"))
    }

    /// 输出不是 JSON：折成人话。
    func testBadJSONFailsWithPlainReason() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo(scriptText: "print('不是 JSON')\n")
        let outcome = await fetch(repo: repo, configuration: cacheConfiguration())
        XCTAssertEqual(outcome, .failure(reason: "脚本输出解析不了"))
    }

    // MARK: - 面板那一行

    private func state(
        payload: CortexGateRuntimeStatusPayload?,
        fetchedAt: Date?,
        failureText: String?,
        failureAt: Date? = nil
    ) -> CortexGateRuntimeStatusDisplayState {
        CortexGateRuntimeStatusDisplayState(
            payload: payload,
            fetchedAt: fetchedAt,
            failureText: failureText,
            failureAt: failureAt
        )
    }

    /// 面板行：读到了 → text_zh 原样上屏 + 读取时刻；ok 与 behind 普通色，其余态提醒色。
    func testRowLineShowsScriptSentenceVerbatim() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetchedAt = now.addingTimeInterval(-5 * 60)

        let okPayload = try Self.decode(state: "ok", textZH: "路由已是最新")
        let okRow = CortexGateRuntimeStatusDisplay.rowLine(
            state(payload: okPayload, fetchedAt: fetchedAt, failureText: nil),
            now: now
        )
        XCTAssertEqual(
            okRow?.text,
            "派工路由：路由已是最新（\(CortexGateRuntimeStatusDisplay.clockText(fetchedAt))）",
            "text_zh 原样上屏，哨兵不自己拼判断"
        )
        XCTAssertEqual(okRow?.isWarning, false, "ok 用普通色")

        let behindPayload = try Self.decode(state: "behind", textZH: "落后 3 个提交，已自动补", behind: 3)
        let behindRow = CortexGateRuntimeStatusDisplay.rowLine(
            state(payload: behindPayload, fetchedAt: fetchedAt, failureText: nil),
            now: now
        )
        XCTAssertEqual(behindRow?.text, "派工路由：落后 3 个提交，已自动补（\(CortexGateRuntimeStatusDisplay.clockText(fetchedAt))）")
        XCTAssertEqual(behindRow?.isWarning, false, "behind 是热仓库常态，不当提醒")

        let refreshFailedPayload = try Self.decode(state: "refresh_failed", textZH: "更新失败：fetch 挂了")
        let refreshFailedRow = CortexGateRuntimeStatusDisplay.rowLine(
            state(payload: refreshFailedPayload, fetchedAt: fetchedAt, failureText: nil),
            now: now
        )
        XCTAssertEqual(refreshFailedRow?.isWarning, true, "真失败仍亮提醒色")
    }

    /// 面板行：最近一轮失败 → HH:MM 这次没读到（原因）；从没成功过也一样。
    func testRowLineShowsFreshFailureWithAttemptTime() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failureAt = now.addingTimeInterval(-2 * 60)

        // 成功过一次之后失败：失败时刻跟着最近一轮走。
        let payload = try Self.decode(state: "ok", textZH: "路由已是最新")
        let row = CortexGateRuntimeStatusDisplay.rowLine(
            state(
                payload: payload,
                fetchedAt: now.addingTimeInterval(-10 * 60),
                failureText: "cortex 仓里还没有这个脚本",
                failureAt: failureAt
            ),
            now: now
        )
        XCTAssertEqual(
            row?.text,
            "派工路由：\(CortexGateRuntimeStatusDisplay.clockText(failureAt)) 这次没读到（cortex 仓里还没有这个脚本）"
        )
        XCTAssertEqual(row?.isWarning, true)

        // 从没成功过（脚本没落地的真机形状）：照样报这次没读到。
        let neverSucceeded = CortexGateRuntimeStatusDisplay.rowLine(
            state(payload: nil, fetchedAt: nil, failureText: "cortex 仓里还没有这个脚本", failureAt: failureAt),
            now: now
        )
        XCTAssertEqual(
            neverSucceeded?.text,
            "派工路由：\(CortexGateRuntimeStatusDisplay.clockText(failureAt)) 这次没读到（cortex 仓里还没有这个脚本）"
        )
    }

    /// 面板行：上次成功超过 30 分钟 → 不显示旧句，改等下一轮；跨过边界自然切换。
    func testRowLineTurnsStaleAfterReuseWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = try Self.decode(state: "ok", textZH: "路由已是最新")

        let fresh = CortexGateRuntimeStatusDisplay.rowLine(
            state(
                payload: payload,
                fetchedAt: now.addingTimeInterval(-CortexGateRuntimeStatusDisplay.reuseWindow + 60),
                failureText: nil
            ),
            now: now
        )
        XCTAssertTrue(fresh?.text.contains("路由已是最新") == true, "窗内旧句照常显示")

        let stale = CortexGateRuntimeStatusDisplay.rowLine(
            state(
                payload: payload,
                fetchedAt: now.addingTimeInterval(-CortexGateRuntimeStatusDisplay.reuseWindow - 1),
                failureText: nil
            ),
            now: now
        )
        XCTAssertEqual(stale?.text, "派工路由：状态过时了，等下一轮")
        XCTAssertEqual(stale?.isWarning, true)
        XCTAssertFalse(stale?.text.contains("路由已是最新") == true, "旧句不再显示")
    }

    /// 面板行：还没跑过任何一轮 → 不占位。
    func testRowLineHiddenBeforeFirstRound() {
        XCTAssertNil(CortexGateRuntimeStatusDisplay.rowLine(nil, now: Date()))
        XCTAssertNil(
            CortexGateRuntimeStatusDisplay.rowLine(
                state(payload: nil, fetchedAt: nil, failureText: nil),
                now: Date()
            )
        )
    }

    // MARK: - --dump-state

    /// dump-state 那行结论：格式同套餐状态那行。
    func testDumpStateText() throws {
        let payload = try Self.decode(state: "ok", textZH: "路由已是最新")
        XCTAssertEqual(
            CortexGateRuntimeStatusDisplay.dumpStateText(.success(payload)),
            "派工路由：路由已是最新"
        )
        // text_zh 缺失时退回 state 原文。
        let bare = try JSONDecoder().decode(
            CortexGateRuntimeStatusPayload.self,
            from: Data("{\"schema\": 1, \"state\": \"behind\"}".utf8)
        )
        XCTAssertEqual(
            CortexGateRuntimeStatusDisplay.dumpStateText(.success(bare)),
            "派工路由：behind"
        )
        XCTAssertEqual(
            CortexGateRuntimeStatusDisplay.dumpStateText(.failure(reason: "cortex 仓里还没有这个脚本")),
            "派工路由：这次没读到（cortex 仓里还没有这个脚本）"
        )
    }
}

/// 记录型执行器：每一次调用原样转交真执行器，只把收到的环境记下来供断言。
private final class RecordingSubprocessRunner: CortexSubprocessRunning, @unchecked Sendable {
    struct Call {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    private let realRunner = CortexProcessSubprocessRunner()

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        stdin: Data?,
        timeout: TimeInterval
    ) async -> CortexSubprocessResult {
        lock.lock()
        _calls.append(Call(executablePath: executablePath, arguments: arguments, environment: environment))
        lock.unlock()
        return await realRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            stdin: stdin,
            timeout: timeout
        )
    }
}
