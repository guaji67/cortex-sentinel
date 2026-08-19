import AppKit
import Foundation
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
            ["idle", "busy", "unclaimed", "channel-down"]
        )
        XCTAssertNil(PanelPreviewFixture(rawValue: "unknown"))
    }

    func testIdleFixtureHasNoLinesAndAliveIdleChannels() throws {
        let session = try PanelPreviewFactory.makeSession(fixture: .idle)
        defer { session.tearDown() }

        XCTAssertEqual(session.store.lines, [])
        XCTAssertEqual(session.store.unclaimedTerminals, [])
        XCTAssertEqual(session.store.channelStatus.grok.status, .alive)
        XCTAssertEqual(session.store.channelStatus.codex.status, .alive)
        XCTAssertEqual(session.store.channelStatus.grok.running, 0)
        XCTAssertEqual(session.store.channelStatus.codex.running, 0)
        XCTAssertTrue(session.store.paths.logsDirectoryExists)
        XCTAssertFalse(session.store.watchDirectoryMissing)
    }

    func testBusyFixtureHasEnoughRunningLinesToNeedScroll() throws {
        let session = try PanelPreviewFactory.makeSession(fixture: .busy)
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

    func testUnclaimedFixtureExposesTerminalsWaitingToBeClaimed() throws {
        let session = try PanelPreviewFactory.makeSession(fixture: .unclaimed)
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

    func testChannelDownFixtureShowsDegradedOrMissingChannel() throws {
        let session = try PanelPreviewFactory.makeSession(fixture: .channelDown)
        defer { session.tearDown() }

        XCTAssertEqual(session.store.lines, [])
        XCTAssertEqual(session.store.unclaimedTerminals, [])
        XCTAssertEqual(session.store.channelStatus.grok.status, .degraded)
        XCTAssertEqual(session.store.channelStatus.grok.status.displayName, "不通")
        XCTAssertEqual(session.store.channelStatus.codex.status, .unknown)
        XCTAssertEqual(session.store.channelStatus.codex.status.displayName, "无数据")
        XCTAssertEqual(session.store.channelStatus.grok.evidence, "账单未付，进程秒退")
    }

    func testRenderPanelPNGWritesNonEmptyFileForEveryFixture() throws {
        var hashes: [String: Data] = [:]
        for fixture in PanelPreviewFixture.allCases {
            let url = root.appendingPathComponent("panel-\(fixture.rawValue).png")
            try PanelPNGRenderer.render(fixture: fixture, to: url)
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
    }
}
