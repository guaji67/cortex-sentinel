import XCTest
@testable import CortexSentinelBar

final class SentinelLineControlsTests: XCTestCase {
    func testCodexGearHelpIsTheFixedHoverCopy() {
        XCTAssertTrue(SentinelBoardCopy.showsLineSettings(for: .codex))
        XCTAssertEqual(
            SentinelBoardCopy.lineSettingsHelp,
            "这条线的重试设置（只有 Codex 有）"
        )
    }

    func testGrokCardsDoNotGetASettingsControl() {
        XCTAssertFalse(SentinelBoardCopy.showsLineSettings(for: .cursorGrok))
    }
}
