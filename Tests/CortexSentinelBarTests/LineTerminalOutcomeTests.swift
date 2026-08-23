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

    /// COR-502 修改五：「最近完成」折叠态标记的渲染条件就是 markerText 是否为 nil。
    /// 写了处置结论的完成线必须给标记，没写的一个字都不加。
    func testCompletedRowMarkerAppearsOnlyWhenNoteExists() {
        let handledDone = makeLine(state: .done, note: "结论已回填")
        XCTAssertEqual(LineDispositionPresentation(line: handledDone).markerText, "有备注")

        let handledKilled = makeLine(state: .killed, note: "人工停掉，不再重拉")
        XCTAssertEqual(LineDispositionPresentation(line: handledKilled).markerText, "有备注")

        XCTAssertNil(
            LineDispositionPresentation(line: makeLine(state: .done)).markerText
        )
        XCTAssertNil(
            LineDispositionPresentation(line: makeLine(state: .killed)).markerText
        )
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
