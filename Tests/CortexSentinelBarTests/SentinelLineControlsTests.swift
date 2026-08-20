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
}
