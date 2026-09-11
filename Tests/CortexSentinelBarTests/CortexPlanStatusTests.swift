import AppKit
import XCTest
@testable import CortexSentinelBar

/// cortex 派工套餐状态的显示规则与取数流程。
/// 公开仓，全部用中性假数据：假钥匙现算指纹、套餐名「Sample 套餐 / 测试套餐」。
final class CortexPlanStatusTests: XCTestCase {
    // MARK: - 样例数据

    private static let sampleKey = "0123456789ab-key"

    private let sampleUsageJSON: Data = {
        let payload: [String: Any] = [
            "schema": 1,
            "checked_at": "2026-09-11T01:30:00Z",
            "accounts": [
                [
                    "key_sha12": "0123456789ab",
                    "source": "zcode",
                    "label": "ZCode",
                    "level": "pro",
                    "five_hour": ["percent_used": 21, "used": 100, "total": 12000, "reset_at_ms": 1],
                    "weekly": NSNull(),
                    "cash_balance": 0.62,
                    "error": NSNull(),
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }()

    /// 票面样例形状的套餐状态 JSON（值都是假的）。
    private let samplePayloadJSON: Data = {
        """
        {
          "schema": 1,
          "generated_at": "2026-09-11T01:30:00Z",
          "free_window": {"active": true, "start": "23:00", "end": "09:00", "text_zh": "现在是免费时段（北京 23:00 到 09:00）"},
          "plans": [
            {
              "id": "plan-a",
              "label": "Sample 套餐",
              "key_sha12": "\(CortexPlanStatusTests.keySHA12Static(CortexPlanStatusTests.sampleKey))",
              "max_parallel": 5,
              "running": 2,
              "executors": [{"name": "执行者 1", "running": 2}],
              "dispatchable": true,
              "skip_code": null,
              "skip_text_zh": null,
              "cooldown_until": null,
              "usage_known": true
            }
          ],
          "errors": [{"code": "multica_unavailable", "text_zh": "读不到看板，在跑几条暂时不知道"}]
        }
        """.data(using: .utf8)!
    }()

    private static func keySHA12Static(_ key: String) -> String {
        GLMUsageCLI.keySHA12(key)
    }

    private func samplePayload() throws -> CortexPlanStatusPayload {
        try JSONDecoder().decode(CortexPlanStatusPayload.self, from: samplePayloadJSON)
    }

    private func isoText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func account(
        key: String = CortexPlanStatusTests.sampleKey,
        cash: Double? = 0.62,
        fiveHourPercent: Double? = 79,
        weeklyPercent: Double? = nil
    ) -> GLMAccountUsage {
        GLMAccountUsage(
            key: key,
            label: "ZCode",
            level: "pro",
            fiveHourWindow: fiveHourPercent.map { GLMUsageWindow(totalPoints: 12000, usedPoints: 100, percentUsed: $0, resetAt: nil) },
            weeklyWindow: weeklyPercent.map { GLMUsageWindow(totalPoints: 60000, usedPoints: 100, percentUsed: $0, resetAt: nil) },
            cashBalance: cash,
            totalSpendAmount: nil,
            checkedAt: nil,
            stale: false,
            errorMessage: nil
        )
    }

    private func plan(
        label: String = "Sample 套餐",
        keySHA12: String = "0123456789ab",
        running: Int? = 2,
        maxParallel: Int? = 5,
        cooldownUntil: Date? = nil
    ) -> CortexPlanStatusPlan {
        let json: [String: Any] = [
            "id": "plan-a",
            "label": label,
            "key_sha12": keySHA12,
            "max_parallel": maxParallel ?? NSNull(),
            "running": running.map(NSNumber.init(value:)) ?? NSNull(),
            "executors": [],
            "dispatchable": running != nil,
            "skip_code": NSNull(),
            "skip_text_zh": NSNull(),
            "cooldown_until": cooldownUntil.map { isoText($0) } ?? NSNull(),
            "usage_known": true,
        ]
        return try! JSONDecoder().decode(
            CortexPlanStatusPlan.self,
            from: try! JSONSerialization.data(withJSONObject: json)
        )
    }

    // MARK: - 匹配与行名

    func testPlanMatchesByKeyFingerprint() throws {
        let payload = try samplePayload()
        let matched = CortexPlanStatusDisplay.plan(forAccountKey: Self.sampleKey, in: payload)
        XCTAssertEqual(matched?.label, "Sample 套餐")
        // 指纹算法跟 --glm-usage-json 同一份，对不上的钥匙不认。
        XCTAssertEqual(matched?.keySHA12, GLMUsageCLI.keySHA12(Self.sampleKey))
        XCTAssertNil(CortexPlanStatusDisplay.plan(forAccountKey: "别的钥匙", in: payload))
        XCTAssertNil(CortexPlanStatusDisplay.plan(forAccountKey: Self.sampleKey, in: nil))
    }

    func testUserRenameBeatsPlanLabel() throws {
        let suiteName = "plan-status-rename-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let plan = try samplePayload().plans[0]
        let account = account()
        // 没改过名：用套餐 label，不加 GLM 前缀。
        XCTAssertEqual(
            ProviderRenameStore.displayName(
                defaults: defaults,
                id: account.key,
                fallback: CortexPlanStatusDisplay.rowTitleFallback(plan: plan, account: account)
            ),
            "Sample 套餐"
        )
        // 用户改过名：照旧用用户的。
        ProviderRenameStore.setDisplayName(defaults: defaults, id: account.key, name: "主力号")
        XCTAssertEqual(
            ProviderRenameStore.displayName(
                defaults: defaults,
                id: account.key,
                fallback: CortexPlanStatusDisplay.rowTitleFallback(plan: plan, account: account)
            ),
            "主力号"
        )
        // 套餐缺失：回原样。
        XCTAssertEqual(
            CortexPlanStatusDisplay.rowTitleFallback(plan: nil, account: account),
            account.displayTitle
        )
    }

    // MARK: - 第三列

    func testThirdColumnCooldownRunningAndUnknown() throws {
        let now = Date()
        let cooling = plan(cooldownUntil: now.addingTimeInterval(30 * 60))
        let text = CortexPlanStatusDisplay.thirdColumnText(plan: cooling, now: now)
        // 长式放不下自动换短式，出图里不截断（宽 80 为准）。
        XCTAssertTrue(text.hasPrefix("冷却"), text)
        let timePart = text.replacingOccurrences(of: "冷却到 ", with: "").replacingOccurrences(of: "冷却 ", with: "")
        XCTAssertEqual(timePart.count, 5)
        XCTAssertTrue(timePart.contains(":"))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        XCTAssertLessThanOrEqual(measured, 80, "第三列文案放不下 80 宽：\(text)")

        // 冷却到点以后不算冷却。
        let expired = plan(cooldownUntil: now.addingTimeInterval(-60))
        XCTAssertEqual(CortexPlanStatusDisplay.thirdColumnText(plan: expired, now: now), "在跑 2/5")

        let running = plan()
        XCTAssertEqual(CortexPlanStatusDisplay.thirdColumnText(plan: running, now: now), "在跑 2/5")

        let unknown = plan(running: nil)
        XCTAssertEqual(CortexPlanStatusDisplay.thirdColumnText(plan: unknown, now: now), "在跑 —")
    }

    // MARK: - 状态点

    func testPlanRowDotIgnoresCashBalance() throws {
        let now = Date()
        let planRow = try samplePayload().plans[0]
        // 套餐行现金 0.5、额度充足 → 绿（不看现金）。
        XCTAssertEqual(
            CortexPlanStatusDisplay.dotColor(
                plan: planRow,
                account: account(cash: 0.5, fiveHourPercent: 10),
                now: now
            ),
            SentinelTheme.Colors.success
        )
        // 额度压线还是红。
        XCTAssertEqual(
            CortexPlanStatusDisplay.dotColor(
                plan: planRow,
                account: account(cash: 0.5, fiveHourPercent: 99.9),
                now: now
            ),
            SentinelTheme.Colors.danger
        )
        // 冷却中：额度全好也至少黄。
        let cooling = plan(cooldownUntil: now.addingTimeInterval(600))
        XCTAssertEqual(
            CortexPlanStatusDisplay.dotColor(
                plan: cooling,
                account: account(cash: 86, fiveHourPercent: 10),
                now: now
            ),
            SentinelTheme.Colors.warning
        )
        // 非套餐行照旧：现金 0.5 → 红（跟 testProviderDotSignalThresholds 一组口径）。
        XCTAssertEqual(
            SentinelBalancesSection.glmDotSignal(
                fiveHourRemaining: nil,
                weeklyRemaining: nil,
                cashBalance: 0.5,
                stale: false,
                hasDisplayableNumber: true
            ),
            SentinelTheme.Colors.danger
        )
    }

    // MARK: - 详情卡

    func testDetailLinesHideFingerprintIDAndCode() throws {
        let payload = try samplePayload()
        let plan = payload.plans[0]
        let fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let lines = CortexPlanStatusDisplay.detailLines(
            plan: plan,
            payload: payload,
            failureText: "cortex 仓里还没有这个脚本",
            fetchedAt: fetchedAt,
            cashBalance: 0.62
        )
        let allText = lines.map { [$0.label, $0.value, $0.note ?? ""].joined(separator: " ") }.joined(separator: "\n")

        // 该在的都在。
        XCTAssertTrue(allText.contains("2 条 / 上限 5"))
        XCTAssertTrue(allText.contains("执行者 1"))
        XCTAssertTrue(allText.contains("可以派"))
        XCTAssertTrue(allText.contains("北京 23:00 到 09:00"), "免费时段的值不带重复的词")
        XCTAssertFalse(allText.contains("现在是免费时段"))
        XCTAssertTrue(allText.contains("读不到看板，在跑几条暂时不知道"))
        XCTAssertTrue(allText.contains("¥0.62"))
        XCTAssertTrue(allText.contains("套餐派工不花现金"))
        // 最近一次失败的备注：读到的时刻 + 原因。
        XCTAssertTrue(allText.contains("\(CortexPlanStatusDisplay.clockText(fetchedAt)) 读到的，这次没读到（cortex 仓里还没有这个脚本）"))

        // 指纹、套餐 id、skip_code、错误 code 任何地方都不露。
        XCTAssertFalse(allText.contains(Self.sampleKey))
        XCTAssertFalse(allText.contains(GLMUsageCLI.keySHA12(Self.sampleKey)))
        XCTAssertFalse(allText.contains("plan-a"))
        XCTAssertFalse(allText.contains("multica_unavailable"))
    }

    func testDetailLinesWithoutFreeWindowAndErrors() throws {
        let plan = self.plan()
        let lines = CortexPlanStatusDisplay.detailLines(
            plan: plan,
            payload: nil,
            failureText: nil,
            fetchedAt: nil,
            cashBalance: nil
        )
        let allText = lines.map { $0.label }.joined(separator: ",")
        XCTAssertEqual(lines.first?.label, "在跑")
        XCTAssertFalse(allText.contains("免费时段"))
        XCTAssertFalse(allText.contains("提示"))
        XCTAssertFalse(allText.contains("现金余额"))
        XCTAssertFalse(allText.contains("派工状态"))
    }

    // MARK: - 失败可见性（三种情形）

    private func state(payload: CortexPlanStatusPayload?, fetchedAt: Date?, failureText: String?) -> CortexPlanStatusDisplayState {
        CortexPlanStatusDisplayState(payload: payload, fetchedAt: fetchedAt, failureText: failureText)
    }

    /// 冷却中详情卡「派工」行写到几点；免费时段的值去掉与标签重复的词。
    func testCooldownDispatchLineAndFreeWindowText() throws {
        let now = Date()
        let cooling = plan(cooldownUntil: now.addingTimeInterval(30 * 60))
        let lines = CortexPlanStatusDisplay.detailLines(
            plan: cooling,
            payload: try samplePayload(),
            failureText: nil,
            fetchedAt: nil,
            cashBalance: nil,
            now: now
        )
        let dispatch = try XCTUnwrap(lines.first { $0.label == "派工" })
        XCTAssertEqual(
            dispatch.value,
            "冷却到 \(CortexPlanStatusDisplay.clockText(try XCTUnwrap(cooling.cooldownUntil)))，暂不派工"
        )
        let free = try XCTUnwrap(lines.first { $0.label == "免费时段" })
        XCTAssertEqual(free.value, "北京 23:00 到 09:00")
        // cortex 两种真实文案形态都去干净。
        XCTAssertEqual(CortexPlanStatusDisplay.freeWindowText("免费时段北京 23:00 开始"), "北京 23:00 开始")
        XCTAssertEqual(CortexPlanStatusDisplay.freeWindowText("现在是免费时段（北京 23:00 到 09:00）"), "北京 23:00 到 09:00")
    }

    /// 成功后 30 分钟内失败：数照用，详情卡末尾加「HH:MM 读到的，这次没读到（原因）」。
    func testFreshFailureKeepsNumbersAndAddsNote() throws {
        let payload = try samplePayload()
        let now = Date()
        let fetchedAt = now.addingTimeInterval(-5 * 60)
        let failure = "cortex 仓里还没有这个脚本"
        let displayState = state(payload: payload, fetchedAt: fetchedAt, failureText: failure)

        XCTAssertEqual(CortexPlanStatusDisplay.freshness(displayState, now: now), .fresh)
        let plan = CortexPlanStatusDisplay.plan(forAccountKey: CortexPlanStatusTests.sampleKey, in: displayState.payload)
        let account = account()
        // 行名还是套餐名，第三列还是真数。
        XCTAssertEqual(CortexPlanStatusDisplay.rowTitleFallback(plan: plan, account: account), "Sample 套餐")
        XCTAssertEqual(CortexPlanStatusDisplay.thirdColumnText(plan: plan!, now: now), "在跑 2/5")

        let lines = CortexPlanStatusDisplay.detailLines(
            plan: plan!,
            payload: payload,
            failureText: failure,
            fetchedAt: fetchedAt,
            cashBalance: 0.62
        )
        XCTAssertEqual(lines.last?.label, "派工状态")
        XCTAssertEqual(lines.last?.value, "\(CortexPlanStatusDisplay.clockText(fetchedAt)) 读到的，这次没读到（\(failure)）")
        let labels = lines.map(\.label)
        XCTAssertTrue(labels.contains("执行者 1"), "时新态执行者行还在")
        XCTAssertTrue(labels.contains("免费时段"))
        XCTAssertTrue(labels.contains("派工"))
    }

    /// 超过 30 分钟失败：行名仍用套餐名，第三列「在跑 —」不显示冷却，状态点只看
    /// 订阅窗口，详情卡只留在跑/现金/派工状态三行。
    func testStaleFailureShowsIdentityOnly() throws {
        let payload = try samplePayload()
        let now = Date()
        let displayState = state(
            payload: payload,
            fetchedAt: now.addingTimeInterval(-CortexPlanStatusDisplay.reuseWindow - 10 * 60),
            failureText: "cortex 仓里还没有这个脚本"
        )

        XCTAssertEqual(CortexPlanStatusDisplay.freshness(displayState, now: now), .stale)
        let plan = try XCTUnwrap(CortexPlanStatusDisplay.plan(forAccountKey: CortexPlanStatusTests.sampleKey, in: displayState.payload))
        let accountRow = account()
        XCTAssertEqual(CortexPlanStatusDisplay.rowTitleFallback(plan: plan, account: accountRow), "Sample 套餐")
        XCTAssertEqual(CortexPlanStatusDisplay.staleThirdColumnText, "在跑 —")

        // 现金 0.5 但窗口好 → 绿（过时态同样不看现金）。
        XCTAssertEqual(
            CortexPlanStatusDisplay.staleDotColor(account: account(cash: 0.5, fiveHourPercent: 10)),
            SentinelTheme.Colors.success
        )
        XCTAssertEqual(
            CortexPlanStatusDisplay.staleDotColor(account: account(cash: 86, fiveHourPercent: 99.9)),
            SentinelTheme.Colors.danger
        )

        let lines = CortexPlanStatusDisplay.staleDetailLines(
            plan: plan,
            failureText: "cortex 仓里还没有这个脚本",
            cashBalance: 0.62
        )
        XCTAssertEqual(lines.map(\.label), ["在跑", "现金余额", "派工状态"])
        XCTAssertEqual(lines[0].value, "— / 上限 5")
        XCTAssertEqual(lines[1].value, "¥0.62")
        XCTAssertEqual(lines[2].value, "没读到（cortex 仓里还没有这个脚本）")
        let allText = lines.map { [$0.label, $0.value, $0.note ?? ""].joined(separator: " ") }.joined(separator: "\n")
        XCTAssertFalse(allText.contains("执行者 1"))
        XCTAssertFalse(allText.contains("免费时段"))
        XCTAssertFalse(allText.contains("可以派"))
        XCTAssertFalse(allText.contains(Self.sampleKey))
        XCTAssertFalse(allText.contains("plan-a"))
    }

    /// 开 App 以来一次都没成功过：行照旧（认不出哪行是套餐），dump-state 有一行排查结论。
    func testNeverSucceededKeepsRowsUntouched() throws {
        let now = Date()
        let account = account()
        let payload = try samplePayload()

        // 从没成功（payload nil，只有失败原因）→ 匹配不出套餐行。
        let failedState = state(payload: nil, fetchedAt: nil, failureText: "找不到 cortex 仓")
        XCTAssertEqual(CortexPlanStatusDisplay.freshness(failedState, now: now), .absent)
        XCTAssertNil(CortexPlanStatusDisplay.plan(forAccountKey: account.key, in: failedState.payload))
        XCTAssertEqual(
            CortexPlanStatusDisplay.rowTitleFallback(plan: nil, account: account),
            account.displayTitle,
            "行名回原样"
        )
        // 状态点照旧：现金 0.5 → 红。
        XCTAssertEqual(
            SentinelBalancesSection.glmDotSignal(
                fiveHourRemaining: nil,
                weeklyRemaining: nil,
                cashBalance: 0.5,
                stale: false,
                hasDisplayableNumber: true
            ),
            SentinelTheme.Colors.danger
        )

        // dump-state 的排查行。
        XCTAssertEqual(
            CortexPlanStatusDisplay.dumpStateText(.failure(reason: "找不到 cortex 仓")),
            "派工状态：没读到（找不到 cortex 仓）"
        )
        let dumpSuccess = CortexPlanStatusDisplay.dumpStateText(.success(payload))
        XCTAssertTrue(dumpSuccess.contains("读到 1 个套餐"))
        XCTAssertTrue(dumpSuccess.contains("Sample 套餐"))
        XCTAssertFalse(dumpSuccess.contains(Self.sampleKey))
        XCTAssertFalse(dumpSuccess.contains("plan-a"))
    }

    /// 过时边界：跨过 30 分钟自然从 fresh 变 stale。
    func testFreshnessBoundary() throws {
        let payload = try samplePayload()
        let now = Date()
        XCTAssertEqual(CortexPlanStatusDisplay.freshness(nil, now: now), .absent)
        XCTAssertEqual(
            CortexPlanStatusDisplay.freshness(state(payload: payload, fetchedAt: nil, failureText: nil), now: now),
            .fresh,
            "成功过但没有失败记录 → 时新"
        )
        let recent = state(payload: payload, fetchedAt: now.addingTimeInterval(-CortexPlanStatusDisplay.reuseWindow + 60), failureText: "x")
        XCTAssertEqual(CortexPlanStatusDisplay.freshness(recent, now: now), .fresh)
        let old = state(payload: payload, fetchedAt: now.addingTimeInterval(-CortexPlanStatusDisplay.reuseWindow - 1), failureText: "x")
        XCTAssertEqual(CortexPlanStatusDisplay.freshness(old, now: now), .stale)
    }

    // MARK: - 取数流程

    private var tempRoot: URL!
    private let realRunner = CortexProcessSubprocessRunner()

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-status-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// 假脚本：把 stdin 的字节数写进缓存目录的标记文件（证明喂进去的就是
    /// --glm-usage-json 那份字节），再打印固定形状的套餐状态。
    private static let fakeScriptThatWrapsStdin = """
        import json
        import sys

        raw = sys.stdin.buffer.read()
        with open("stdin-marker.json", "w", encoding="utf-8") as marker:
            marker.write(str(len(raw)))
        payload = {
            "schema": 1,
            "generated_at": "2026-09-11T01:30:00Z",
            "free_window": {"active": False, "start": "23:00", "end": "09:00", "text_zh": "现在是免费时段（北京 23:00 到 09:00）"},
            "plans": [
                {
                    "id": "plan-a",
                    "label": "Sample 套餐",
                    "key_sha12": "0123456789ab",
                    "max_parallel": 5,
                    "running": 2,
                    "executors": [{"name": "执行者 1", "running": 2}],
                    "dispatchable": True,
                    "skip_code": None,
                    "skip_text_zh": None,
                    "cooldown_until": None,
                    "usage_known": True,
                }
            ],
            "errors": [],
        }
        print(json.dumps(payload, ensure_ascii=False))
        """

    /// 临时 git 仓：放假清单和假脚本，并造出 refs/remotes/origin/main。
    @discardableResult
    private func makeScriptRepo(
        scriptText: String = CortexPlanStatusTests.fakeScriptThatWrapsStdin,
        manifestOverride: String? = nil,
        makeSleepingInterpreter: Bool = false
    ) async throws -> URL {
        let repo = tempRoot.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("logs"), withIntermediateDirectories: true)
        if let manifest = manifestOverride {
            try manifest.write(
                to: repo.appendingPathComponent("scripts/glm_plan_status.files"),
                atomically: true,
                encoding: .utf8
            )
        } else {
            try "# 清单\nscripts/glm_plan_status.py\n".write(
                to: repo.appendingPathComponent("scripts/glm_plan_status.files"),
                atomically: true,
                encoding: .utf8
            )
        }
        try scriptText.write(to: repo.appendingPathComponent("scripts/glm_plan_status.py"), atomically: true, encoding: .utf8)
        if makeSleepingInterpreter {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
            let interpreterURL = repo.appendingPathComponent(".venv/bin/python3")
            // exec 换身：超时 terminate 杀的就是它自己，不会留孙进程拽着管道。
            try "#!/bin/sh\nexec sleep 5\n".write(to: interpreterURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: interpreterURL.path)
        }
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

    private func commitScriptChange(_ scriptText: String, at repo: URL) async throws {
        try scriptText.write(to: repo.appendingPathComponent("scripts/glm_plan_status.py"), atomically: true, encoding: .utf8)
        try await runGit(["add", "."], at: repo)
        try await runGit(["-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-m", "bump", "--no-gpg-sign"], at: repo)
        try await runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], at: repo)
    }

    private func cacheConfiguration() -> CortexPlanStatusFetcher.Configuration {
        CortexPlanStatusFetcher.Configuration(cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true))
    }

    private func fetch(
        repo: URL,
        watchDirectory: URL? = nil,
        fallbackRepositoryRoot: URL? = nil,
        environment: [String: String] = [:],
        configuration: CortexPlanStatusFetcher.Configuration = CortexPlanStatusFetcher.Configuration(),
        usageJSON: Data? = nil
    ) async -> CortexPlanStatusOutcome {
        let resolvedConfiguration = configuration.cacheRoot == nil ? cacheConfiguration() : configuration
        return await CortexPlanStatusFetcher.fetch(
            environment: environment,
            watchDirectory: watchDirectory ?? repo.appendingPathComponent("logs"),
            fallbackRepositoryRoot: fallbackRepositoryRoot ?? repo,
            homeDirectory: repo.path,
            usageJSON: usageJSON ?? sampleUsageJSON,
            configuration: resolvedConfiguration,
            runner: realRunner
        )
    }

    private func setModificationDate(_ date: Date, on directory: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: directory.path
        )
    }

    func testFetchSuccessFeedsUsageJSONAndCaches() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo()
        let cacheRoot = tempRoot.appendingPathComponent("cache", isDirectory: true)
        let configuration = CortexPlanStatusFetcher.Configuration(cacheRoot: cacheRoot)

        // 第一次：解包 + 跑脚本，stdin 字节数对上（喂的确实是 renderJSON 那份）。
        let first = await fetch(repo: repo, configuration: configuration, usageJSON: sampleUsageJSON)
        guard case let .success(payload) = first else {
            XCTFail("第一次取数应该成功：\(first)")
            return
        }
        XCTAssertEqual(payload.plans.first?.running, 2)
        let cacheDirs = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(cacheDirs.count, 1)
        let firstCacheDirectory = cacheDirs[0]
        let markerURL = firstCacheDirectory.appendingPathComponent("stdin-marker.json")
        let markerText = try String(contentsOf: markerURL, encoding: .utf8)
        XCTAssertEqual(Int(markerText), sampleUsageJSON.count, "脚本收到的 stdin 就是喂进去那份字节")
        // 缓存目录里跑的脚本不认指纹原文，目录名是 ls-tree 输出的哈希。
        XCTAssertEqual(firstCacheDirectory.lastPathComponent.count, 64)

        // 第二次：缓存键稳定，不重解。标记放进脚本不会碰的子目录
        // （脚本每轮都会跑、会重写 stdin-marker.json，那个证明不了没重解）。
        let keepDirectory = firstCacheDirectory.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: keepDirectory, withIntermediateDirectories: true)
        try "别动我".write(to: keepDirectory.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try setModificationDate(Date(timeIntervalSince1970: 100_000), on: firstCacheDirectory)
        let second = await fetch(repo: repo, configuration: configuration)
        guard case .success = second else {
            XCTFail("第二次取数应该成功：\(second)")
            return
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: keepDirectory.appendingPathComponent("marker.txt").path),
            "第二次不该重解缓存"
        )
        // 缓存没重解，但脚本每轮都照常跑（stdin 标记被刷新成同样字节数）。
        let markerAfterSecond = try String(contentsOf: markerURL, encoding: .utf8)
        XCTAssertEqual(Int(markerAfterSecond), sampleUsageJSON.count)

        // 清单里的脚本内容变了 → 新缓存目录，旧的留着。
        try await commitScriptChange(CortexPlanStatusTests.fakeScriptThatWrapsStdin + "\n# v2\n", at: repo)
        let third = await fetch(repo: repo, configuration: configuration)
        guard case let .success(newPayload) = third else {
            XCTFail("换版后取数应该成功：\(third)")
            return
        }
        XCTAssertEqual(newPayload.plans.first?.running, 2)
        let dirsAfterChange = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirsAfterChange.count, 2, "换版后新旧两份缓存都在")
        XCTAssertTrue(dirsAfterChange.contains { $0.lastPathComponent == firstCacheDirectory.lastPathComponent })

        // 再换一版：只留最新两份，最老的（第一份）被清掉。
        try await commitScriptChange(CortexPlanStatusTests.fakeScriptThatWrapsStdin + "\n# v3\n", at: repo)
        let fourth = await fetch(repo: repo, configuration: configuration)
        guard case .success = fourth else {
            XCTFail("第三版取数应该成功：\(fourth)")
            return
        }
        let dirsFinal = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirsFinal.count, 2, "只留最新两份")
        XCTAssertFalse(
            dirsFinal.contains { $0.lastPathComponent == firstCacheDirectory.lastPathComponent },
            "最老的缓存被清掉"
        )
    }

    func testMissingManifestFailsWithPlainReason() async throws {
        // 仓里连清单文件都没有：git show 失败 → 还没有这个脚本。
        let repoWithoutManifest = tempRoot.appendingPathComponent("no-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoWithoutManifest.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try await runGit(["init"], at: repoWithoutManifest)
        try await runGit(["add", "."], at: repoWithoutManifest)
        try await runGit(["-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-m", "empty", "--no-gpg-sign", "--allow-empty"], at: repoWithoutManifest)
        try await runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], at: repoWithoutManifest)
        let outcome = await fetch(repo: repoWithoutManifest)
        XCTAssertEqual(outcome, .failure(reason: "cortex 仓里还没有这个脚本"))
    }

    func testManifestWithPathTraversalRejected() async throws {
        let repo = try await makeScriptRepo(
            scriptText: CortexPlanStatusTests.fakeScriptThatWrapsStdin,
            manifestOverride: "scripts/glm_plan_status.py\n../evil.py\n"
        )
        let outcome = await fetch(repo: repo)
        XCTAssertEqual(outcome, .failure(reason: "脚本清单不合法"))
    }

    func testMissingInterpreterFailsWithPlainReason() async throws {
        let repo = try await makeScriptRepo()
        var configuration = cacheConfiguration()
        configuration.interpreterCandidates = { _ in ["/nonexistent/python3"] }
        let outcome = await fetch(repo: repo, configuration: configuration)
        XCTAssertEqual(outcome, .failure(reason: "没找到可用的 Python"))
    }

    /// 大输出要一启动就并发读：等退出才读的实现会卡死在管道缓冲上，
    /// 直到超时被杀（导出脚本 100KB 实踩）。变异跑时这条必须红。
    func testRunnerCapturesLargeOutputWithoutDeadlock() async {
        let runner = CortexProcessSubprocessRunner()
        let started = Date()
        let result = await runner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "/bin/dd if=/dev/zero bs=1024 count=200 2>/dev/null"],
            workingDirectory: nil,
            environment: nil,
            stdin: nil,
            timeout: 10
        )
        XCTAssertFalse(result.timedOut, "不该卡到超时被杀")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.count, 204_800, "200KB 要一字不少拿到")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "要在短超时内按时退出")
    }

    func testScriptTimeoutFailsAndDoesNotHang() async throws {
        let repo = try await makeScriptRepo(makeSleepingInterpreter: true)
        var configuration = cacheConfiguration()
        configuration.scriptTimeout = 0.5
        configuration.interpreterCandidates = { repoRoot in
            [repoRoot.appendingPathComponent(".venv/bin/python3").path]
        }
        let started = Date()
        let outcome = await fetch(repo: repo, configuration: configuration)
        XCTAssertEqual(outcome, .failure(reason: "脚本跑超时了"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "超时要在远小于 sleep 时长内返回")
    }

    func testBadJSONFailsWithPlainReason() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo(scriptText: "print('不是 JSON')\n")
        let outcome = await fetch(repo: repo)
        XCTAssertEqual(outcome, .failure(reason: "脚本输出解析不了"))
    }

    func testSchemaOtherThanOneTreatedAsAbsent() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo(scriptText: "print('{\"schema\": 9, \"plans\": []}')\n")
        let outcome = await fetch(repo: repo)
        XCTAssertEqual(outcome, .failure(reason: "脚本版本不认识"))
    }

    // MARK: - 认仓

    /// Pro 装机版真实形状：监视目录是软链（~/.cortex-sentinel/logs → 仓的 logs），
    /// 不设 CORTEX_REPO_ROOT 时要顺着软链认出那个 git 仓。
    func testRepoResolutionFollowsWatchDirectorySymlink() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("本机没有 /usr/bin/python3")
        }
        let repo = try await makeScriptRepo()
        let outer = tempRoot.appendingPathComponent("installed-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        let logsLink = outer.appendingPathComponent("logs")
        try FileManager.default.createSymbolicLink(
            at: logsLink,
            withDestinationURL: repo.appendingPathComponent("logs")
        )
        let configuration = CortexPlanStatusFetcher.Configuration(
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true)
        )
        let outcome = await CortexPlanStatusFetcher.fetch(
            environment: [:],
            watchDirectory: logsLink,
            fallbackRepositoryRoot: outer,
            homeDirectory: repo.path,
            usageJSON: sampleUsageJSON,
            configuration: configuration,
            runner: realRunner
        )
        guard case let .success(payload) = outcome else {
            XCTFail("软链形状应该认出 git 仓：\(outcome)")
            return
        }
        XCTAssertEqual(payload.plans.first?.label, "Sample 套餐")
    }

    // MARK: - 子命令白名单

    /// 注入命令执行器：对 cortex 仓只准出现 rev-parse / show / ls-tree / archive 四种只读命令。
    func testGitSubcommandsAreReadOnlyWhitelist() async throws {
        let fakeRepoRoot = tempRoot.appendingPathComponent("any-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeRepoRoot, withIntermediateDirectories: true)
        let runner = FakeSubprocessRunner(revParseRoot: fakeRepoRoot.path)
        runner.responses["show"] = CortexSubprocessResult(
            exitCode: 0,
            standardOutput: Data("# 清单\nscripts/glm_plan_status.py\n".utf8),
            standardError: Data(),
            timedOut: false
        )
        runner.responses["ls-tree"] = CortexSubprocessResult(
            exitCode: 0,
            standardOutput: Data("100644 blob deadbeef\tscripts/glm_plan_status.py\n".utf8),
            standardError: Data(),
            timedOut: false
        )

        let outcome = await CortexPlanStatusFetcher.fetch(
            environment: [:],
            watchDirectory: tempRoot,
            fallbackRepositoryRoot: nil,
            homeDirectory: tempRoot.path,
            usageJSON: sampleUsageJSON,
            configuration: CortexPlanStatusFetcher.Configuration(
                cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true),
                interpreterCandidates: { _ in ["/nonexistent/python3"] }
            ),
            runner: runner
        )
        // 解释器被注入成不存在的路径，流程停在跑脚本之前；断言只看 git 调用记录。
        XCTAssertEqual(outcome, .failure(reason: "没找到可用的 Python"))

        let gitSubcommands = runner.calls
            .filter { $0.executablePath == "/usr/bin/git" }
            .map { $0.arguments.count > 2 ? $0.arguments[2] : "" }
        XCTAssertFalse(gitSubcommands.isEmpty)
        let allowed: Set<String> = ["rev-parse", "show", "ls-tree", "archive"]
        for subcommand in gitSubcommands {
            XCTAssertTrue(allowed.contains(subcommand), "出现了白名单外的 git 子命令：\(subcommand)")
        }
        XCTAssertEqual(gitSubcommands.filter { $0 == "rev-parse" }.count, 1, "认仓候选逐个探")
        XCTAssertTrue(gitSubcommands.contains("show"))
        XCTAssertTrue(gitSubcommands.contains("ls-tree"))
        // 禁止任何会改仓状态的命令。
        for forbidden in ["fetch", "checkout", "reset", "pull", "merge", "commit"] {
            XCTAssertFalse(gitSubcommands.contains(forbidden))
        }
    }
}

/// 假执行器：git 按子命令回固定结果，其余命令交真的跑。
private final class FakeSubprocessRunner: CortexSubprocessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executablePath: String
        let arguments: [String]
    }

    var responses: [String: CortexSubprocessResult] = [:]
    private let revParseRoot: String
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    init(revParseRoot: String) {
        self.revParseRoot = revParseRoot
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
        _calls.append(Call(executablePath: executablePath, arguments: arguments))
        lock.unlock()

        if executablePath == "/usr/bin/git" {
            let subcommand = arguments.count > 2 ? arguments[2] : ""
            switch subcommand {
            case "rev-parse":
                return CortexSubprocessResult(
                    exitCode: 0,
                    standardOutput: Data("\(revParseRoot)\n".utf8),
                    standardError: Data(),
                    timedOut: false
                )
            case "archive":
                // 真打个 tar 流出来，让解包那步照常走。
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("fake-archive-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: staging.appendingPathComponent("scripts"), withIntermediateDirectories: true)
                try? "print('{\"schema\": 1, \"plans\": []}')\n".write(
                    to: staging.appendingPathComponent("scripts/glm_plan_status.py"),
                    atomically: true,
                    encoding: .utf8
                )
                defer { try? FileManager.default.removeItem(at: staging) }
                return await realRunner.run(
                    executablePath: "/usr/bin/tar",
                    arguments: ["-cf", "-", "-C", staging.path, "scripts"],
                    workingDirectory: nil,
                    environment: nil,
                    stdin: nil,
                    timeout: timeout
                )
            default:
                if let response = responses[subcommand] {
                    return response
                }
                return CortexSubprocessResult(exitCode: 1, standardOutput: Data(), standardError: Data(), timedOut: false)
            }
        }
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
