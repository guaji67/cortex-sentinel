import Foundation
import XCTest
@testable import CortexSentinelBar

final class RelayRecoveryCoordinatorTests: XCTestCase {
    private let fileManager = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_785_897_600)
    private var logsDirectory: URL!

    override func setUpWithError() throws {
        logsDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CortexSentinelRelayRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: logsDirectory)
    }

    func testWaitingInputLineWithConnectedStatusRequestsProbeOnce() throws {
        var coordinator = RelayRecoveryProbeCoordinator()

        let requested = coordinator.requestEligibleProbes(
            lines: [waitingLine()],
            aio: inputAIO(),
            inputStatus: inputStatus(allOK: true),
            logsDirectory: logsDirectory,
            now: now
        )

        XCTAssertEqual(requested, ["waiting-input"])
        let payload = try controlPayload(slug: "waiting-input")
        XCTAssertEqual(payload["action"] as? String, "probe_now")
        XCTAssertEqual(payload["requested_at"] as? String, "2026-08-05T02:40:00Z")
    }

    func testConnectedStatusDoesNotRepeatProbeDuringCooldown() throws {
        var coordinator = RelayRecoveryProbeCoordinator()
        let line = waitingLine()
        let aio = inputAIO()
        let connected = inputStatus(allOK: true)

        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [line],
                aio: aio,
                inputStatus: connected,
                logsDirectory: logsDirectory,
                now: now
            ),
            ["waiting-input"]
        )
        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [line],
                aio: aio,
                inputStatus: connected,
                logsDirectory: logsDirectory,
                now: now.addingTimeInterval(RelayRecoveryConstants.probeCooldown - 1)
            ),
            []
        )
        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [line],
                aio: aio,
                inputStatus: connected,
                logsDirectory: logsDirectory,
                now: now.addingTimeInterval(RelayRecoveryConstants.probeCooldown)
            ),
            []
        )
        XCTAssertEqual(
            try controlPayload(slug: "waiting-input")["requested_at"] as? String,
            "2026-08-05T02:40:00Z"
        )
    }

    func testConnectedStatusCanRequestAgainAfterCooldownAndFreshRefresh() throws {
        var coordinator = RelayRecoveryProbeCoordinator()
        let line = waitingLine()
        let aio = inputAIO()

        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [line],
                aio: aio,
                inputStatus: inputStatus(allOK: true),
                logsDirectory: logsDirectory,
                now: now
            ),
            ["waiting-input"]
        )
        let refreshedAt = now.addingTimeInterval(RelayRecoveryConstants.probeCooldown)
        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [line],
                aio: aio,
                inputStatus: inputStatus(allOK: true, readAt: refreshedAt),
                logsDirectory: logsDirectory,
                now: refreshedAt
            ),
            ["waiting-input"]
        )
    }

    func testWaitingInputLineWithDisconnectedStatusDoesNotRequestProbe() throws {
        var coordinator = RelayRecoveryProbeCoordinator()

        let requested = coordinator.requestEligibleProbes(
            lines: [waitingLine()],
            aio: inputAIO(),
            inputStatus: inputStatus(allOK: false),
            logsDirectory: logsDirectory,
            now: now
        )

        XCTAssertEqual(requested, [])
        XCTAssertFalse(fileManager.fileExists(atPath: try controlURL(slug: "waiting-input").path))
    }

    func testConnectedStatusRequestsProbeRegardlessOfProviderBaseURL() throws {
        var coordinator = RelayRecoveryProbeCoordinator()
        let ordinaryProvider = provider(
            name: "ordinary-provider",
            baseURL: "https://relay.example.test/v1"
        )

        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [waitingLine()],
                aio: aio(provider: ordinaryProvider),
                inputStatus: inputStatus(allOK: true),
                logsDirectory: logsDirectory,
                now: now
            ),
            ["waiting-input"]
        )
    }

    func testConnectedStatusRequestsProbeWhenRelayProbeIsMissing() throws {
        var coordinator = RelayRecoveryProbeCoordinator()
        let line = waitingLine()
        let lineWithoutRelayProbe = LineStatus(
            sourceFile: line.sourceFile,
            slug: line.slug,
            workdir: line.workdir,
            branch: line.branch,
            state: line.state,
            restarts: line.restarts,
            rolloutAgeSeconds: line.rolloutAgeSeconds,
            updatedAt: line.updatedAt,
            sourceModifiedAt: line.sourceModifiedAt,
            startedAt: line.startedAt,
            relay: line.relay,
            relayProbe: nil
        )

        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [lineWithoutRelayProbe],
                aio: inputAIO(),
                inputStatus: inputStatus(allOK: true),
                logsDirectory: logsDirectory,
                now: now
            ),
            ["waiting-input"]
        )
    }

    func testConnectedStatusRequestsProbeWhenActiveProviderIsFallback() throws {
        var coordinator = RelayRecoveryProbeCoordinator()

        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [waitingLine(activeProvider: "codex_local_access")],
                aio: inputAIO(),
                inputStatus: inputStatus(allOK: true),
                logsDirectory: logsDirectory,
                now: now
            ),
            ["waiting-input"]
        )
    }

    func testConnectedStatusRequestsProbeWhenAggregateQueueHeadHasEmptyBaseURL() throws {
        var coordinator = RelayRecoveryProbeCoordinator()
        let fallback = provider(
            id: 24,
            name: "GPT PRO",
            baseURL: ""
        )
        let aio = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [fallback],
            lastHitProviderID: fallback.id,
            lastHitProviderName: fallback.name,
            readAt: now,
            errorMessage: nil
        )

        XCTAssertEqual(
            coordinator.requestEligibleProbes(
                lines: [waitingLine()],
                aio: aio,
                inputStatus: inputStatus(allOK: true),
                logsDirectory: logsDirectory,
                now: now
            ),
            ["waiting-input"]
        )
        XCTAssertEqual(try controlPayload(slug: "waiting-input")["action"] as? String, "probe_now")
    }

    private func waitingLine(activeProvider: String? = "aio") -> LineStatus {
        LineStatus(
            sourceFile: logsDirectory.appendingPathComponent("codex-babysitter-waiting-input.status.json"),
            slug: "waiting-input",
            workdir: nil,
            branch: nil,
            state: .waitingRelay,
            restarts: 2,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now,
            startedAt: now.addingTimeInterval(-600),
            relay: nil,
            relayProbe: LineRelayProbe(
                state: "unhealthy",
                checkedAt: nil,
                lastOK: false,
                recentOK: [false],
                detail: nil,
                primaryProvider: "aio",
                activeProvider: activeProvider,
                fallbackProvider: nil,
                fallbackAttempted: nil,
                switchCount: nil,
                lastSwitchAt: nil,
                firstFailureAt: nil
            )
        )
    }

    private func inputAIO() -> AIOSnapshot {
        let input = provider(name: "input-fixture", baseURL: "https://relay.example.test/v1")
        return aio(provider: input)
    }

    private func aio(provider: AIOProvider) -> AIOSnapshot {
        return AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [provider],
            lastHitProviderID: provider.id,
            lastHitProviderName: provider.name,
            readAt: now,
            errorMessage: nil
        )
    }

    private func provider(id: Int64 = 1, name: String, baseURL: String) -> AIOProvider {
        AIOProvider(
            id: id,
            name: name,
            baseURL: baseURL,
            enabled: true,
            routeOrder: 0,
            providerOrder: 0,
            note: "",
            circuitState: .closed,
            failureCount: 0,
            usage: .idle
        )
    }

    private func inputStatus(allOK: Bool, readAt: Date? = nil) -> InputStatusSnapshot {
        InputStatusSnapshot(
            allOK: allOK,
            probes: [],
            readAt: readAt ?? now,
            errorMessage: nil
        )
    }

    private func controlURL(slug: String) throws -> URL {
        try SentinelControlFile.controlURL(slug: slug, logsDirectory: logsDirectory)
    }

    private func controlPayload(slug: String) throws -> [String: Any] {
        let data = try Data(contentsOf: controlURL(slug: slug))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - 出口感知（维护者 2026-08-12：只开 Input 且 Input 不通就别再傻试）

final class RelayExitPostureTests: XCTestCase {
    func testExitClassFollowsMaintainerNamingRule() {
        XCTAssertEqual(AIOExitClass(name: "input-quarter-500"), .input)
        XCTAssertEqual(AIOExitClass(name: "INPUT-年度100刀"), .input)
        XCTAssertEqual(AIOExitClass(name: "GPT Pro"), .officialGPT)
        XCTAssertEqual(AIOExitClass(name: "gpt plus"), .officialGPT)
        XCTAssertEqual(AIOExitClass(name: "CC-0.121"), .thirdParty)
        XCTAssertEqual(AIOExitClass(name: "  "), .thirdParty)
    }

    func testBothHitsResolveToNonInputSoWorstCaseIsOneExtraTry() {
        // 判错的代价必须是"多试一次"而不是"该试的不试"。
        XCTAssertEqual(AIOExitClass(name: "input-GPT混合号"), .officialGPT)

        let snapshot = snapshot(named: [("input-a", true), ("input-GPT混合号", true)])
        XCTAssertFalse(snapshot.onlyInputExitsEnabled)
        XCTAssertEqual(
            RelayExitPosture.resolve(aio: snapshot, inputState: .disconnected),
            .alternativeExit
        )
    }

    func testOnlyInputEnabledAndInputDownIsNoExit() {
        let snapshot = snapshot(named: [("input-a", true), ("input-b", true), ("GPT Pro", false)])
        XCTAssertTrue(snapshot.onlyInputExitsEnabled)
        XCTAssertEqual(RelayExitPosture.resolve(aio: snapshot, inputState: .disconnected), .noExit)
    }

    func testOnlyInputEnabledButInputConnectedIsNotNoExit() {
        let snapshot = snapshot(named: [("input-a", true)])
        XCTAssertEqual(RelayExitPosture.resolve(aio: snapshot, inputState: .connected), .inputUsable)
    }

    func testOtherExitEnabledKeepsOldBehaviour() {
        // 维护者 2026-08-12 下午手动打开 GPT Pro 之后的真实局面。
        let withGPT = snapshot(named: [("input-a", true), ("input-b", true), ("GPT Pro", true)])
        XCTAssertFalse(withGPT.onlyInputExitsEnabled)
        XCTAssertEqual(RelayExitPosture.resolve(aio: withGPT, inputState: .disconnected), .alternativeExit)

        let withThirdParty = snapshot(named: [("input-a", true), ("CC-0.121", true)])
        XCTAssertFalse(withThirdParty.onlyInputExitsEnabled)
        XCTAssertEqual(
            RelayExitPosture.resolve(aio: withThirdParty, inputState: .disconnected),
            .alternativeExit
        )
    }

    func testUnreadableOrEmptyExitListDegradesToOldBehaviour() {
        XCTAssertFalse(AIOSnapshot.unconfigured.onlyInputExitsEnabled)
        XCTAssertEqual(
            RelayExitPosture.resolve(aio: .unconfigured, inputState: .disconnected),
            .alternativeExit
        )

        let allDisabled = snapshot(named: [("input-a", false), ("input-b", false)])
        XCTAssertFalse(allDisabled.onlyInputExitsEnabled)

        let invalid = AIOSnapshot(
            sourceState: .invalid,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [provider(id: 1, name: "input-a", enabled: true)],
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: Date(),
            errorMessage: "broken"
        )
        XCTAssertFalse(invalid.onlyInputExitsEnabled)
    }

    func testStaleOrUnknownInputStateIsUndetermined() {
        let snapshot = snapshot(named: [("input-a", true)])
        XCTAssertEqual(RelayExitPosture.resolve(aio: snapshot, inputState: .stale), .undetermined)
        XCTAssertEqual(RelayExitPosture.resolve(aio: snapshot, inputState: .unknown), .undetermined)
    }

    private func snapshot(named entries: [(String, Bool)]) -> AIOSnapshot {
        AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: entries.enumerated().map { index, entry in
                provider(id: Int64(index + 1), name: entry.0, enabled: entry.1)
            },
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: Date(),
            errorMessage: nil
        )
    }

    private func provider(id: Int64, name: String, enabled: Bool) -> AIOProvider {
        AIOProvider(
            id: id,
            name: name,
            baseURL: "https://relay.example.test/v1",
            enabled: enabled,
            routeOrder: 0,
            providerOrder: 0,
            note: "",
            circuitState: .closed,
            failureCount: 0,
            usage: .idle
        )
    }
}

final class RelayNoExitPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_897_600)

    func testNoExitLineShowsWaitingForInputInsteadOfLookingStuck() {
        let line = waitingLine(
            noExit: true,
            noExitReason: "AIO 里启用的 3 个出口全是 Input 系，而 Input 正挂着——这时候发出去也是白发，"
                + "已暂停无谓重试；每 5 分钟看一眼 Input，它一恢复就自动继续。"
        )

        XCTAssertTrue(line.isWaitingForStructuralExit)
        XCTAssertEqual(LineDispositionPresentation(line: line).stateText, "等 Input 恢复")
        XCTAssertEqual(LineDispositionPresentation(line: line).symbolName, "hourglass")

        let details = LineRelayProbePresentation.details(for: line.relayProbe!, now: now)
        XCTAssertEqual(details.map(\.label), ["出口", "状态", "原因", "等待"])
        XCTAssertEqual(details[1].value, "等 Input 恢复（已暂停无谓重试）")
        XCTAssertTrue(details[2].value.contains("已暂停无谓重试"))
        XCTAssertTrue(details[2].value.contains("一恢复就自动继续"))
    }

    func testNoExitWithoutReasonFallsBackToPlainChineseSummary() {
        let line = waitingLine(noExit: true, noExitReason: nil)
        let details = LineRelayProbePresentation.details(for: line.relayProbe!, now: now)
        XCTAssertEqual(details[2].value, RelayExitPosture.noExitFallbackSummary)
        XCTAssertEqual(
            RelayExitPosture.noExitFallbackSummary,
            "只开了 Input 系出口，Input 挂着，已暂停无谓重试，等它恢复自动继续"
        )
    }

    func testOrdinaryWaitingLineKeepsOriginalProbeRows() {
        // 旧版守护不写 no_exit 字段，显示必须一字不改。
        let line = waitingLine(noExit: nil, noExitReason: nil)
        XCTAssertFalse(line.isWaitingForStructuralExit)
        XCTAssertEqual(LineDispositionPresentation(line: line).stateText, "等中转恢复")
        let details = LineRelayProbePresentation.details(for: line.relayProbe!, now: now)
        XCTAssertEqual(details.map(\.label), ["出口", "探针", "等待", "备用"])
    }

    func testNoExitFieldsDecodeFromBabysitterStatusPayload() throws {
        let json = """
        {
          "state": "healthy",
          "active_provider": "aio",
          "no_exit": true,
          "no_exit_reason": "只开了 Input 系出口，Input 挂着，已暂停无谓重试，等它恢复自动继续"
        }
        """
        let probe = try JSONDecoder().decode(LineRelayProbe.self, from: Data(json.utf8))
        XCTAssertTrue(probe.isNoExit)
        XCTAssertEqual(
            probe.noExitReason,
            "只开了 Input 系出口，Input 挂着，已暂停无谓重试，等它恢复自动继续"
        )
    }

    private func waitingLine(noExit: Bool?, noExitReason: String?) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-no-exit.status.json"),
            slug: "no-exit",
            workdir: nil,
            branch: nil,
            state: .waitingRelay,
            restarts: 0,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now,
            startedAt: now.addingTimeInterval(-600),
            relay: nil,
            relayProbe: LineRelayProbe(
                state: "healthy",
                checkedAt: nil,
                lastOK: true,
                recentOK: nil,
                detail: nil,
                primaryProvider: "aio",
                activeProvider: "aio",
                fallbackProvider: nil,
                fallbackAttempted: nil,
                switchCount: nil,
                lastSwitchAt: nil,
                firstFailureAt: nil,
                noExit: noExit,
                noExitReason: noExitReason
            )
        )
    }
}

final class RelayRecoveryCoordinatorPostureTests: XCTestCase {
    private let fileManager = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_785_897_600)
    private var logsDirectory: URL!

    override func setUpWithError() throws {
        logsDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CortexSentinelRelayPosture-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: logsDirectory)
    }

    func testCoordinatorRecordsNoExitPostureAndSendsNoProbe() throws {
        var coordinator = RelayRecoveryProbeCoordinator()

        let requested = coordinator.requestEligibleProbes(
            lines: [waitingLine()],
            aio: snapshot(named: [("input-a", true), ("input-b", true)]),
            inputStatus: InputStatusSnapshot(allOK: false, probes: [], readAt: now, errorMessage: nil),
            logsDirectory: logsDirectory,
            now: now
        )

        XCTAssertEqual(requested, [])
        XCTAssertEqual(coordinator.lastPosture, .noExit)
    }

    func testCoordinatorRecordsAlternativeExitPostureWhenInputIsDownButGPTIsEnabled() throws {
        var coordinator = RelayRecoveryProbeCoordinator()

        let requested = coordinator.requestEligibleProbes(
            lines: [waitingLine()],
            aio: snapshot(named: [("input-a", true), ("GPT Pro", true)]),
            inputStatus: InputStatusSnapshot(allOK: false, probes: [], readAt: now, errorMessage: nil),
            logsDirectory: logsDirectory,
            now: now
        )

        // 行为不变：Input 不通时照旧不发探测请求，但态势记成"还有别的出口"而不是"没出口"。
        XCTAssertEqual(requested, [])
        XCTAssertEqual(coordinator.lastPosture, .alternativeExit)
    }

    func testCoordinatorStillRequestsProbeWhenInputRecovers() throws {
        var coordinator = RelayRecoveryProbeCoordinator()

        let requested = coordinator.requestEligibleProbes(
            lines: [waitingLine()],
            aio: snapshot(named: [("input-a", true)]),
            inputStatus: InputStatusSnapshot(allOK: true, probes: [], readAt: now, errorMessage: nil),
            logsDirectory: logsDirectory,
            now: now
        )

        XCTAssertEqual(requested, ["waiting-input"])
        XCTAssertEqual(coordinator.lastPosture, .inputUsable)
    }

    private func waitingLine() -> LineStatus {
        LineStatus(
            sourceFile: logsDirectory.appendingPathComponent("codex-babysitter-waiting-input.status.json"),
            slug: "waiting-input",
            workdir: nil,
            branch: nil,
            state: .waitingRelay,
            restarts: 1,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now,
            startedAt: now.addingTimeInterval(-600),
            relay: nil,
            relayProbe: nil
        )
    }

    private func snapshot(named entries: [(String, Bool)]) -> AIOSnapshot {
        AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: entries.enumerated().map { index, entry in
                AIOProvider(
                    id: Int64(index + 1),
                    name: entry.0,
                    baseURL: "https://relay.example.test/v1",
                    enabled: entry.1,
                    routeOrder: 0,
                    providerOrder: 0,
                    note: "",
                    circuitState: .closed,
                    failureCount: 0,
                    usage: .idle
                )
            },
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: now,
            errorMessage: nil
        )
    }
}

// MARK: - 出口额度闸显示（维护者 2026-08-12：没有写到哨兵里面吗）

final class OfficialQuotaHoldPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_897_600)

    func testTightQuotaLineReadsAsWaitingForQuotaNotAsStuck() {
        let line = holdLine(
            hold: "quota_tight",
            reason: "现在只能走官方 GPT 那条出口，官方 GPT 这周的额度已经用掉 96%，要等到 8 月 17 日 08:00 才回血。",
            quota: quota(state: "tight", weekly: 96, weeklyReset: "2026-08-17T00:00:00+00:00", fiveHour: 40)
        )

        XCTAssertEqual(line.launchHold, .quotaTight)
        XCTAssertTrue(line.officialGPTInRoute)
        let disposition = LineDispositionPresentation(line: line)
        XCTAssertEqual(disposition.stateText, "等额度回血")
        XCTAssertEqual(disposition.symbolName, "gauge.with.needle")

        let details = LineRelayProbePresentation.details(for: line.relayProbe!, now: now)
        XCTAssertEqual(details.map(\.label), ["出口", "状态", "原因", "官方额度", "等待"])
        XCTAssertEqual(details[1].value, "等额度回血（已暂停发射）")
        XCTAssertTrue(details[2].value.contains("已经用掉 96%"))
        XCTAssertEqual(details[3].value, "周窗口已用 96% · 8/17 08:00 回血 · 5 小时窗 40% · 已达暂停线")
    }

    func testUnknownQuotaLineSaysItIsWaitingForVerificationNotThatQuotaIsFine() {
        let line = holdLine(
            hold: "quota_unknown",
            reason: "现在只能走官方 GPT 那条出口，但额度接口取不到数——不敢当成额度充足就发。",
            quota: quota(state: "unknown", weekly: nil, weeklyReset: nil, fiveHour: nil, detail: "官方额度接口暂不可达")
        )

        XCTAssertEqual(line.launchHold, .quotaUnknown)
        XCTAssertEqual(LineDispositionPresentation(line: line).stateText, "等额度核实")

        let details = LineRelayProbePresentation.details(for: line.relayProbe!, now: now)
        XCTAssertEqual(details[1].value, "等额度核实（查不到额度，先不发）")
        XCTAssertTrue(details[2].value.contains("不敢当成额度充足"))
        XCTAssertEqual(details[3].value, "查不到（官方额度接口暂不可达）")
    }

    func testQuotaHoldOnHelpStateStillExplainsItself() {
        // 额度打满会升级成 help，那时更要说清是额度的事，不是通道不通。
        let base = holdLine(
            hold: "quota_tight",
            reason: "额度打满了",
            quota: quota(state: "tight", weekly: 95, weeklyReset: nil, fiveHour: nil)
        )
        let helped = LineStatus(
            sourceFile: base.sourceFile, slug: base.slug, workdir: nil, branch: nil,
            state: .help, restarts: base.restarts, rolloutAgeSeconds: nil,
            updatedAt: now, sourceModifiedAt: now, startedAt: base.startedAt,
            relay: nil, relayProbe: base.relayProbe
        )
        XCTAssertEqual(helped.launchHold, .quotaTight)
        XCTAssertEqual(LineDispositionPresentation(line: helped).stateText, "等额度回血")
    }

    func testRunningLineIsNeverShownAsHolding() {
        let base = holdLine(hold: "quota_tight", reason: "额度打满了", quota: nil)
        let running = LineStatus(
            sourceFile: base.sourceFile, slug: base.slug, workdir: nil, branch: nil,
            state: .running, restarts: 0, rolloutAgeSeconds: nil,
            updatedAt: now, sourceModifiedAt: now, startedAt: base.startedAt,
            relay: nil, relayProbe: base.relayProbe
        )
        XCTAssertEqual(running.launchHold, .none)
        XCTAssertEqual(LineDispositionPresentation(line: running).stateText, "运行中")
    }

    func testOrdinaryLineStillShowsOfficialQuotaWhenGPTIsInRoute() {
        // 没被拦住也要看得见周额度在掉——正常派工时守护看到的是中转 USD 余额，两个桶。
        let probe = LineRelayProbe(
            state: "healthy", checkedAt: nil, lastOK: true, recentOK: nil, detail: nil,
            primaryProvider: "aio", activeProvider: "aio", fallbackProvider: nil,
            fallbackAttempted: false, switchCount: 0, lastSwitchAt: nil, firstFailureAt: nil,
            officialGPTInRoute: true,
            officialQuota: quota(state: "warn", weekly: 80, weeklyReset: nil, fiveHour: nil),
            launchHold: nil, launchHoldReason: nil
        )
        let details = LineRelayProbePresentation.details(for: probe, now: now)
        XCTAssertEqual(details.map(\.label), ["出口", "探针", "等待", "备用", "官方额度"])
        XCTAssertEqual(details[4].value, "周窗口已用 80%")
    }

    func testLineWithoutOfficialGPTKeepsTheOriginalFourRows() {
        let probe = LineRelayProbe(
            state: "unhealthy", checkedAt: nil, lastOK: false, recentOK: [false], detail: nil,
            primaryProvider: "aio", activeProvider: "aio", fallbackProvider: nil,
            fallbackAttempted: false, switchCount: 0, lastSwitchAt: nil, firstFailureAt: nil
        )
        XCTAssertEqual(probe.holdKind, .none)
        XCTAssertEqual(
            LineRelayProbePresentation.details(for: probe, now: now).map(\.label),
            ["出口", "探针", "等待", "备用"]
        )
    }

    func testQuotaFieldsDecodeFromBabysitterPayloadAndCarryNoAccountIdentity() throws {
        let json = """
        {
          "state": "healthy",
          "active_provider": "aio",
          "official_gpt_in_route": true,
          "launch_hold": "quota_tight",
          "launch_hold_reason": "现在只能走官方 GPT 那条出口，额度已经用掉 96%",
          "quota_unverified_launch_at": null,
          "official_quota": {
            "state": "tight",
            "weekly_used_pct": 96,
            "weekly_reset_at": "2026-08-17T00:00:00+00:00",
            "five_hour_used_pct": null,
            "five_hour_reset_at": null,
            "detail": "官方 GPT 这周的额度已经用掉 96%",
            "block_at_weekly_pct": 90
          }
        }
        """
        let probe = try JSONDecoder().decode(LineRelayProbe.self, from: Data(json.utf8))
        XCTAssertEqual(probe.holdKind, .quotaTight)
        XCTAssertEqual(probe.officialGPTInRoute, true)
        XCTAssertEqual(probe.officialQuota?.weeklyUsedPercentage, 96)
        XCTAssertEqual(probe.officialQuota?.blockAtWeeklyPercentage, 90)
        XCTAssertTrue(probe.officialQuota?.isTight == true)

        // 额度结构里压根没有账号标识字段可解——守护那边也不写
        let mirrorLabels = Mirror(reflecting: probe.officialQuota!).children.compactMap(\.label)
        for forbidden in ["email", "providerName", "planType", "apiKey", "token"] {
            XCTAssertFalse(mirrorLabels.contains(forbidden), "额度结构不许带 \(forbidden)")
        }
    }

    func testSnapshotKnowsWhenOfficialGPTIsInTheRoute() {
        XCTAssertTrue(snapshot(named: [("input-a", true), ("GPT Pro", true)]).hasEnabledOfficialGPTExit)
        XCTAssertFalse(snapshot(named: [("input-a", true), ("GPT Pro", false)]).hasEnabledOfficialGPTExit)
        XCTAssertFalse(snapshot(named: [("input-a", true), ("CC-0.121", true)]).hasEnabledOfficialGPTExit)
        XCTAssertFalse(AIOSnapshot.unconfigured.hasEnabledOfficialGPTExit)
    }

    private func quota(
        state: String,
        weekly: Double?,
        weeklyReset: String?,
        fiveHour: Double?,
        detail: String? = nil
    ) -> LineOfficialQuota {
        let payload: [String: Any?] = [
            "state": state,
            "weekly_used_pct": weekly,
            "weekly_reset_at": weeklyReset,
            "five_hour_used_pct": fiveHour,
            "five_hour_reset_at": fiveHour == nil ? nil : "2026-08-12T13:00:00+00:00",
            "detail": detail,
            "block_at_weekly_pct": 90,
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: payload.compactMapValues { $0 }
        )
        return try! JSONDecoder().decode(LineOfficialQuota.self, from: data)
    }

    private func holdLine(hold: String, reason: String, quota: LineOfficialQuota?) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-quota.status.json"),
            slug: "quota",
            workdir: nil,
            branch: nil,
            state: .waitingRelay,
            restarts: 0,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now,
            startedAt: now.addingTimeInterval(-900),
            relay: nil,
            relayProbe: LineRelayProbe(
                state: "healthy", checkedAt: nil, lastOK: true, recentOK: nil, detail: nil,
                primaryProvider: "aio", activeProvider: "aio", fallbackProvider: nil,
                fallbackAttempted: false, switchCount: 0, lastSwitchAt: nil,
                firstFailureAt: nil,
                officialGPTInRoute: true,
                officialQuota: quota,
                launchHold: hold,
                launchHoldReason: reason
            )
        )
    }

    private func snapshot(named entries: [(String, Bool)]) -> AIOSnapshot {
        AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: entries.enumerated().map { index, entry in
                AIOProvider(
                    id: Int64(index + 1), name: entry.0, baseURL: "https://relay.example.test/v1",
                    enabled: entry.1, routeOrder: 0, providerOrder: 0, note: "",
                    circuitState: .closed, failureCount: 0, usage: .idle
                )
            },
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: now,
            errorMessage: nil
        )
    }
}

final class OfficialQuotaUnsupportedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_897_600)

    func testUnsupportedQuotaReadsDifferentlyFromTemporarilyUnavailable() throws {
        let unsupported = try decodeQuota(
            state: "unsupported",
            detail: "这台 AIO 没有提供官方额度接口，守护查不到周额度"
        )
        XCTAssertTrue(unsupported.isUnsupported)
        XCTAssertFalse(unsupported.isUnknown)
        XCTAssertTrue(unsupported.needsAttention)
        XCTAssertEqual(
            LineRelayProbePresentation.officialQuotaText(unsupported),
            "核实不了（这台 AIO 没有提供官方额度接口，守护查不到周额度）"
        )

        let temporary = try decodeQuota(state: "unknown", detail: "官方额度接口暂不可达")
        XCTAssertEqual(
            LineRelayProbePresentation.officialQuotaText(temporary),
            "查不到（官方额度接口暂不可达）"
        )
    }

    private func decodeQuota(state: String, detail: String) throws -> LineOfficialQuota {
        let data = try JSONSerialization.data(
            withJSONObject: ["state": state, "detail": detail, "block_at_weekly_pct": 90]
        )
        return try JSONDecoder().decode(LineOfficialQuota.self, from: data)
    }
}
