import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import CortexSentinelBar

@MainActor
final class PanelPNGRendererTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "panel-png-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testFixtureRawValuesMatchCLINames() {
        XCTAssertEqual(PanelPreviewFixture.idle.rawValue, "idle")
        XCTAssertEqual(PanelPreviewFixture.busy.rawValue, "busy")
        XCTAssertEqual(PanelPreviewFixture.unclaimed.rawValue, "unclaimed")
        XCTAssertEqual(PanelPreviewFixture.channelDown.rawValue, "channel-down")
        XCTAssertEqual(
            PanelPreviewFixture.allCases.map(\.rawValue),
            [
                "idle",
                "busy",
                "unclaimed",
                "channel-down",
                "bgjobs-problems",
                "four-outcomes",
                "balance-unread",
                "route-unread",
                "split-counts",
                "channel-no-record",
                "channel-unreadable",
                "channel-unrecognized",
                "channel-undetermined",
                "off-host-active",
            ]
        )
        XCTAssertNil(PanelPreviewFixture(rawValue: "unknown"))
    }

    func testIdleFixtureHasNoLinesAndAliveIdleChannels() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .idle)
        defer { session.tearDown() }

        XCTAssertEqual(session.store.lines, [])
        XCTAssertEqual(session.store.unclaimedTerminals, [])
        XCTAssertEqual(session.store.channelStatus.grok.status, .alive)
        XCTAssertEqual(session.store.channelStatus.codex.status, .alive)
        XCTAssertEqual(session.store.channelStatus.grok.running, 0)
        XCTAssertEqual(session.store.channelStatus.codex.running, 0)
        XCTAssertTrue(session.store.paths.logsDirectoryExists)
        XCTAssertFalse(session.store.watchDirectoryMissing)
        let jobs = BackgroundJobsPresentation(snapshot: session.store.backgroundJobs)
        XCTAssertEqual(session.store.backgroundJobs.jobs.count, 5)
        XCTAssertFalse(jobs.hasProblems)
        XCTAssertEqual(jobs.summaryText, "后台任务 5 个，全部正常")
        XCTAssertEqual(jobs.healthyRows.count, 5)
    }

    func testBusyFixtureHasEnoughRunningLinesToNeedScroll() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .busy)
        defer { session.tearDown() }

        XCTAssertGreaterThanOrEqual(session.store.lines.count, 8)
        XCTAssertTrue(session.store.lines.allSatisfy { $0.state == .running })
        XCTAssertGreaterThanOrEqual(session.store.lineGroups.activeRegistered.count, 8)
        XCTAssertEqual(session.store.unclaimedTerminals, [])
        XCTAssertEqual(session.store.channelStatus.grok.status, .alive)
        XCTAssertEqual(session.store.channelStatus.codex.status, .alive)
        XCTAssertGreaterThan(session.store.channelStatus.grok.runningCount, 0)
        XCTAssertGreaterThan(session.store.channelStatus.codex.runningCount, 0)
    }

    func testUnclaimedFixtureExposesTerminalsWaitingToBeClaimed() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .unclaimed)
        defer { session.tearDown() }

        XCTAssertFalse(session.store.unclaimedTerminals.isEmpty)
        XCTAssertEqual(
            Set(session.store.unclaimedTerminals.map(\.slug)),
            Set(session.store.lines.map(\.slug))
        )
        XCTAssertTrue(session.store.lines.allSatisfy(\.state.isTerminal))
        XCTAssertTrue(session.store.lineGroups.activeRegistered.isEmpty)
        XCTAssertFalse(session.store.lineGroups.recentlyCompleted.isEmpty)
        XCTAssertEqual(session.store.channelStatus.grok.status, .alive)
        XCTAssertEqual(session.store.channelStatus.codex.status, .alive)
    }

    func testChannelDownFixtureShowsDegradedOrMissingChannel() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .channelDown)
        defer { session.tearDown() }

        XCTAssertEqual(session.store.lines, [])
        XCTAssertEqual(session.store.unclaimedTerminals, [])
        XCTAssertEqual(session.store.channelStatus.grok.status, .degraded)
        XCTAssertEqual(session.store.channelStatus.grok.status.displayName, "不通")
        XCTAssertEqual(session.store.channelStatus.codex.status, .unknown)
        XCTAssertEqual(session.store.channelStatus.codex.statusText, "查不出来")
        XCTAssertEqual(session.store.channelStatus.grok.evidence, "账单未付，进程秒退")
    }

    func testBgjobsProblemsFixtureExpandsTwoProblems() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .bgjobsProblems)
        defer { session.tearDown() }

        let presentation = BackgroundJobsPresentation(snapshot: session.store.backgroundJobs)
        XCTAssertTrue(presentation.hasProblems)
        // 红行只收 launchd 实际状态真坏的 job；plist 异常留在绿行做备注。
        XCTAssertEqual(presentation.problemRows.count, 2)
        XCTAssertEqual(presentation.problemRows[0].name, "界面常驻服务")
        XCTAssertEqual(
            presentation.problemRows[0].detail,
            "上次跑：查不到上次运行 · 常驻进程不在了，上次退出码 78"
        )
        XCTAssertEqual(presentation.problemRows[1].name, "内存与回收巡检")
        XCTAssertEqual(
            presentation.problemRows[1].detail,
            "上次跑：14 分钟前 · 本轮 312 秒，已超过 10 分钟间隔的一半"
        )
        let sentinelRow = presentation.healthyRows
            .first { $0.id == "com.cortex.sentinelbar" }
        XCTAssertTrue(sentinelRow?.detail.contains("配置读不了（") == true)
        XCTAssertTrue(sentinelRow?.detail.contains("…") == true)
        XCTAssertTrue(sentinelRow?.detail.contains("服务正常运行") == true)
        let mirrorRow = presentation.healthyRows
            .first { $0.id == "com.falcon.cortex.mini-mirror-sync" }
        XCTAssertTrue(mirrorRow?.detail.contains("状态看不懂，按运行状态显示") == true)
        XCTAssertEqual(presentation.summaryText, "后台任务 5 个，2 个不正常")
    }

    func testRenderPanelPNGWritesNonEmptyFileForEveryFixture() async throws {
        var hashes: [String: Data] = [:]
        for fixture in PanelPreviewFixture.allCases {
            let url = root.appendingPathComponent("panel-\(fixture.rawValue).png")
            try await PanelPNGRenderer.render(fixture: fixture, to: url)
            let data = try Data(contentsOf: url)
            XCTAssertGreaterThan(data.count, 30_000, fixture.rawValue)
            XCTAssertEqual(
                Array(data.prefix(8)),
                [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                fixture.rawValue
            )
            hashes[fixture.rawValue] = data
        }
        XCTAssertNotEqual(hashes["idle"], hashes["busy"])
        XCTAssertNotEqual(hashes["idle"], hashes["unclaimed"])
        XCTAssertNotEqual(hashes["idle"], hashes["channel-down"])
        XCTAssertNotEqual(hashes["busy"], hashes["unclaimed"])
        XCTAssertNotEqual(hashes["idle"], hashes["bgjobs-problems"])
        XCTAssertNotEqual(hashes["idle"], hashes["four-outcomes"])
        XCTAssertNotEqual(hashes["idle"], hashes["balance-unread"])
        XCTAssertNotEqual(hashes["idle"], hashes["route-unread"])
        XCTAssertNotEqual(hashes["idle"], hashes["split-counts"])
        XCTAssertNotEqual(hashes["idle"], hashes["channel-no-record"])
        XCTAssertNotEqual(hashes["channel-no-record"], hashes["channel-unreadable"])
        XCTAssertNotEqual(hashes["channel-unreadable"], hashes["channel-unrecognized"])
        XCTAssertNotEqual(hashes["channel-unrecognized"], hashes["channel-undetermined"])
        XCTAssertNotEqual(hashes["idle"], hashes["off-host-active"])
        XCTAssertNotEqual(hashes["split-counts"], hashes["off-host-active"])
    }

    func testSplitCountsFixtureKeepsTheTwoNumbersOnDifferentSets() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .splitCounts)
        defer { session.tearDown() }

        let localHost = LocalHostIdentity.current()
        let groups = session.store.lineGroups
        let localActive = groups.localActivePresentations(localHost: localHost).count
        XCTAssertEqual(groups.activeUnregistered.map(\.line.slug), ["local-unregistered"])
        XCTAssertEqual(groups.activeRegistered.map(\.line.slug), ["remote-registered"])
        XCTAssertEqual(localActive, 0)
        XCTAssertEqual(groups.activeRegistered.count, 1)
        XCTAssertNotEqual(localActive, groups.activeRegistered.count)
    }

    func testFourChannelUnknownFixturesMatchPrimaryRowCopy() async throws {
        let cases: [(PanelPreviewFixture, String, ChannelUnknownKind)] = [
            (.channelNoRecord, "还没有记录", .noRecord),
            (.channelUnreadable, "状态读不出", .unreadable),
            (.channelUnrecognized, "状态看不懂", .unrecognized),
            (.channelUndetermined, "查不出来", .undetermined),
        ]
        for (fixture, phrase, kind) in cases {
            let session = try await PanelPreviewFactory.makeSession(fixture: fixture)
            defer { session.tearDown() }
            let presentation = ChannelSectionPresentation(
                grok: session.store.channelStatus.grok,
                codex: session.store.channelStatus.codex,
                claudeOxAlpha: session.store.channelStatus.claudeOxAlpha,
                liveCounts: EngineCounts()
            )
            let oxAlphaPhrase = session.store.channelStatus.claudeOxAlpha.statusText
            XCTAssertEqual(
                presentation.render.primaryRow,
                ["Codex \(phrase)", "Grok \(phrase)", "ox-alpha \(oxAlphaPhrase)"],
                fixture.rawValue
            )
            XCTAssertEqual(presentation.render.problemLines, [], fixture.rawValue)
            XCTAssertEqual(session.store.channelStatus.codex.unknownKind, kind, fixture.rawValue)
            XCTAssertEqual(session.store.channelStatus.grok.unknownKind, kind, fixture.rawValue)
        }
    }

    func testIdlePanelHeightAccountsForCriticalBackgroundJobs() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .idle)
        defer { session.tearDown() }
        let view = SentinelMenuView(store: session.store, rendersOffscreen: true)
            .frame(width: SentinelTheme.Metrics.menuWidth)
            .fixedSize(horizontal: true, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(
            width: SentinelTheme.Metrics.menuWidth,
            height: nil
        )
        let height = try XCTUnwrap(renderer.nsImage?.size.height)
        // COR-1862 fixtures now include four critical services plus the sentinel
        // operation rows; offscreen rendering may exceed the fixed menu viewport.
        XCTAssertLessThanOrEqual(height, SentinelTheme.Metrics.menuHeight + 100)
        XCTAssertGreaterThan(height, 300)
    }

    func testFourOutcomesFixtureExposesAllFourTerminalStates() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .fourOutcomes)
        defer { session.tearDown() }

        let states = session.store.lines.map(\.state)
        XCTAssertEqual(states.count, 4)
        XCTAssertTrue(states.contains(.done))
        XCTAssertTrue(states.contains(.help))
        XCTAssertTrue(states.contains(.dead))
        XCTAssertTrue(states.contains(.killed))
        for line in session.store.lines {
            XCTAssertEqual(
                LineTerminalOutcomePresentation.label(for: line.state),
                expectedOutcome(for: line.state)
            )
            XCTAssertEqual(
                LineDispositionPresentation(line: line).stateText,
                expectedOutcome(for: line.state)
            )
        }
    }

    func testBalanceUnreadFixtureShowsFixedUnreadCopy() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .balanceUnread)
        defer { session.tearDown() }

        XCTAssertEqual(session.store.aio.sourceState, .invalid)
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(
                official: session.store.officialUsage,
                aio: session.store.aio
            ),
            .unread
        )
        let route = SentinelTopChannelPresentation(aio: session.store.aio)
        XCTAssertEqual(route.routeSummary, "还不知道走的哪条路")
        XCTAssertNil(route.routeModeBadge)
    }

    func testRouteUnreadFixtureHidesConnectionBadge() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .routeUnread)
        defer { session.tearDown() }

        XCTAssertEqual(session.store.aio.sourceState, .unconfigured)
        XCTAssertEqual(session.store.lines.count, 2)
        XCTAssertTrue(session.store.lines.allSatisfy { $0.state == .running })
        let route = SentinelTopChannelPresentation(aio: session.store.aio)
        XCTAssertEqual(route.routeSummary, "没在用本地网关")
        XCTAssertNil(route.routeModeBadge)
        XCTAssertNotEqual(
            BalanceSectionPresentation.resolve(
                official: session.store.officialUsage,
                aio: session.store.aio
            ),
            .unread
        )
    }

    func testOffHostActiveFixturePutsRemoteAndUnknownIntoTheHeader() async throws {
        let session = try await PanelPreviewFactory.makeSession(fixture: .offHostActive)
        defer { session.tearDown() }

        let localHost = LocalHostIdentity.current()
        let groups = session.store.lineGroups
        let origins = groups.activeHostOriginCounts(localHost: localHost)
        XCTAssertEqual(origins.local, 0)
        XCTAssertEqual(origins.remote, 1)
        XCTAssertEqual(origins.unknown, 1)
        XCTAssertEqual(Set(session.store.lines.map(\.slug)), ["remote-registered", "unknown-host"])
        XCTAssertTrue(session.store.lines.allSatisfy { $0.state == .running })
        XCTAssertEqual(
            SentinelBoardCopy.headerSubtitle(
                localActiveCount: groups.localActivePresentations(localHost: localHost).count,
                recentCount: SentinelBoardWindow.snapshot(groups: groups).recentShown.count,
                offHostActiveCount: origins.remote + origins.unknown
            ),
            "这台机上在跑 0 条 · 另外 2 条不在这台机上 · 0 条最近完成"
        )
    }

    private func expectedOutcome(for state: LineState) -> String {
        switch state {
        case .done:
            return "做完了"
        case .help:
            return "要人管"
        case .dead:
            return "挂了"
        case .killed:
            return "被停了"
        default:
            return ""
        }
    }
}
