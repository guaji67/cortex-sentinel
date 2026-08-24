import XCTest
@testable import CortexSentinelBar

final class SentinelLineControlsTests: XCTestCase {
    func testCodexGearHelpIsTheFixedHoverCopy() {
        XCTAssertTrue(SentinelBoardCopy.showsLineSettings(for: .codex))
        XCTAssertEqual(
            SentinelBoardCopy.lineSettingsHelp,
            "这条线的重试和提醒（只有 Codex 有）"
        )
        XCTAssertEqual(SentinelBoardCopy.lineSettingsTitle, "这条线的重试和提醒")
        XCTAssertTrue(SentinelBoardCopy.lineSettingsHelp.hasPrefix(SentinelBoardCopy.lineSettingsTitle))
        XCTAssertEqual(SentinelBoardCopy.escalateAfterFailuresLabel, "失败几次提醒我")
        XCTAssertEqual(
            SentinelBoardCopy.lineSettingsCloseAccessibilityLabel,
            "关闭这条线的重试和提醒"
        )
    }

    func testGrokCardsDoNotGetASettingsControl() {
        XCTAssertFalse(SentinelBoardCopy.showsLineSettings(for: .cursorGrok))
    }

    func testOneClickRecoverySelectsEveryStoppedNonterminalCodexLineOnly() throws {
        let presentations = [
            presentation("waiting", state: .waitingRelay),
            presentation("quota", state: .help),
            presentation("retry", state: .retrying),
            presentation("backoff", state: .backoff),
            presentation("dead", state: .dead),
            presentation("unknown", state: .unknown("waiting_quota")),
            presentation("running", state: .running),
            presentation("done", state: .done),
            presentation("killed", state: .killed),
            presentation("grok-waiting", state: .waitingRelay, engine: .cursorGrok),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CortexSentinelForceStartAll-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = SentinelForceStartAction.requestAll(
            in: presentations,
            logsDirectory: directory,
            now: ISO8601DateFormatter().date(from: "2026-08-24T08:20:00Z")!
        )

        XCTAssertEqual(result.selectedCount, 6)
        XCTAssertEqual(result.sentCount, 6)
        XCTAssertEqual(result.failedSlugs, [])
        XCTAssertEqual(result.feedbackText, "已发出 6 条")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(
            files,
            ["backoff", "dead", "quota", "retry", "unknown", "waiting"].map {
                "codex-babysitter-\($0).control.json"
            }.sorted()
        )
        XCTAssertFalse(files.contains("codex-babysitter-running.control.json"))
        XCTAssertFalse(files.contains("codex-babysitter-grok-waiting.control.json"))
    }

    func testForceStartBadgeOnlyAppearsAfterGuardianReportsActiveMode() {
        let inactive = line("inactive", state: .waitingRelay)
        let active = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-active.status.json"),
            slug: "active",
            workdir: nil,
            branch: nil,
            state: .retrying,
            restarts: 1,
            rolloutAgeSeconds: nil,
            updatedAt: nil,
            sourceModifiedAt: nil,
            forceStart: LineForceStart(
                active: true,
                activatedAt: "2026-08-24T16:20:01+08:00",
                activatedBy: "cortex_sentinel_panel"
            ),
            relay: nil
        )

        XCTAssertNil(SentinelForceStartAction.activeBadgeText(for: inactive))
        XCTAssertEqual(SentinelForceStartAction.activeBadgeText(for: active), "强制模式")
    }

    private func presentation(
        _ slug: String,
        state: LineState,
        engine: LineEngine = .codex
    ) -> LinePresentation {
        LinePresentation(line: line(slug, state: state, engine: engine), registration: nil)
    }

    private func line(
        _ slug: String,
        state: LineState,
        engine: LineEngine = .codex
    ) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/\(slug).status.json"),
            slug: slug,
            engine: engine,
            workdir: nil,
            branch: nil,
            state: state,
            restarts: 0,
            rolloutAgeSeconds: nil,
            updatedAt: nil,
            sourceModifiedAt: nil,
            relay: nil
        )
    }
}
