import XCTest
@testable import CortexSentinelBar

final class LineTerminalOutcomeTests: XCTestCase {
    func testFourTerminalStatesRenderExactFixedWords() {
        XCTAssertEqual(LineTerminalOutcomePresentation.label(for: .done), "做完了")
        XCTAssertEqual(LineTerminalOutcomePresentation.label(for: .help), "要人管")
        XCTAssertEqual(LineTerminalOutcomePresentation.label(for: .dead), "挂了")
        XCTAssertEqual(LineTerminalOutcomePresentation.label(for: .killed), "被停了")
    }

    func testNonTerminalStatesHaveNoOutcomeWord() {
        XCTAssertNil(LineTerminalOutcomePresentation.label(for: .running))
        XCTAssertNil(LineTerminalOutcomePresentation.label(for: .waitingRelay))
        XCTAssertNil(LineTerminalOutcomePresentation.label(for: .retrying))
        XCTAssertNil(LineTerminalOutcomePresentation.label(for: .backoff))
        XCTAssertNil(LineTerminalOutcomePresentation.label(for: .unknown("weird")))
    }

    func testDispositionUsesTheSameFourWordsOnEachTerminalRow() {
        XCTAssertEqual(LineDispositionPresentation(line: makeLine(state: .done)).stateText, "做完了")
        XCTAssertEqual(LineDispositionPresentation(line: makeLine(state: .help)).stateText, "要人管")
        XCTAssertEqual(LineDispositionPresentation(line: makeLine(state: .dead)).stateText, "挂了")
        XCTAssertEqual(LineDispositionPresentation(line: makeLine(state: .killed)).stateText, "被停了")
    }

    func testHandledDeadStillShowsHungLabelNotAReplacementWord() {
        let handled = makeLine(state: .dead, note: "已核对，不再重派")
        let presentation = LineDispositionPresentation(line: handled)
        XCTAssertEqual(presentation.stateText, "挂了")
        XCTAssertEqual(presentation.markerText, "已有处置记录")
        XCTAssertEqual(presentation.note, "已核对，不再重派")
        XCTAssertFalse(presentation.requiresAttention)
    }

    private func makeLine(state: LineState, note: String? = nil) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-outcome.status.json"),
            slug: "outcome",
            workdir: nil,
            branch: nil,
            state: state,
            restarts: 0,
            rolloutAgeSeconds: nil,
            updatedAt: Date(),
            sourceModifiedAt: Date(),
            relay: nil,
            note: note
        )
    }
}
