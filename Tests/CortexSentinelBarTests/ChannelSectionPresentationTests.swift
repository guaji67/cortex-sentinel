import XCTest
@testable import CortexSentinelBar

final class ChannelSectionPresentationTests: XCTestCase {
    func testBothAliveWithRunningCountsRendersExactTexts() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "2 条在跑", running: 2),
            codex: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
            liveCounts: EngineCounts(grok: 2, codex: 1)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 1 条", "Grok 通 2 条"],
                problemLines: []
            )
        )
        XCTAssertEqual(presentation.rowCount, 1)
    }

    func testBothAliveIdleRendersExactTexts() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(
                status: .alive,
                evidence: "最近一次派工正常终态 done",
                running: 0
            ),
            codex: ChannelVerdict(
                status: .alive,
                evidence: "最近一次派工正常终态 done",
                running: 0
            ),
            liveCounts: EngineCounts(grok: 0, codex: 0)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "Grok 通 闲"],
                problemLines: []
            )
        )
        XCTAssertEqual(presentation.rowCount, 1)
    }

    func testOneDegradedOneAliveRendersExactTexts() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(
                status: .degraded,
                evidence: "账单未付，进程秒退",
                running: 0
            ),
            codex: ChannelVerdict(
                status: .alive,
                evidence: "最近一次派工正常终态 done",
                running: 0
            ),
            liveCounts: EngineCounts(grok: 0, codex: 0)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "Grok 不通"],
                problemLines: ["Grok 不通，账单未付，进程秒退"]
            )
        )
        XCTAssertEqual(presentation.rowCount, 2)
    }

    func testBothUnknownRendersExactTexts() {
        let presentation = ChannelSectionPresentation(
            grok: .missing,
            codex: .missing,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 还没有记录", "Grok 还没有记录"],
                problemLines: []
            )
        )
        XCTAssertEqual(presentation.rowCount, 1)
    }

    func testMissingFileUsesNoRecordOnPrimaryRow() {
        let presentation = ChannelSectionPresentation(
            grok: .missing,
            codex: .missing,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(presentation.render.primaryRow, ["Codex 还没有记录", "Grok 还没有记录"])
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(presentation.codex.verdict.unknownKind, .noRecord)
        XCTAssertEqual(presentation.grok.verdict.unknownKind, .noRecord)
    }

    func testUnreadableFileUsesUnreadableOnPrimaryRow() {
        let presentation = ChannelSectionPresentation(
            grok: .unreadable,
            codex: .unreadable,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(presentation.render.primaryRow, ["Codex 状态读不出", "Grok 状态读不出"])
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(presentation.codex.verdict.statusText, ChannelUnknownKind.unreadable.statusText)
    }

    func testMissingEngineEntryUsesNoRecordOnPrimaryRow() {
        let snapshot = SentinelFileReader.parseChannelStatus(
            data: Data(
                """
                {
                  "channels": {
                    "grok": {"status": "alive", "evidence": "2 条在跑", "running": 2}
                  }
                }
                """.utf8
            )
        )
        let presentation = ChannelSectionPresentation(
            grok: snapshot.grok,
            codex: snapshot.codex,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(presentation.render.primaryRow, ["Codex 还没有记录", "Grok 通 闲"])
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertNil(snapshot.grok.unknownKind)
        XCTAssertEqual(snapshot.codex.unknownKind, .noRecord)
    }

    func testUnrecognizedStatusValueUsesUnintelligibleOnPrimaryRow() {
        let snapshot = SentinelFileReader.parseChannelStatus(
            data: Data(
                """
                {
                  "channels": {
                    "grok": {},
                    "codex": {"status": "weird-value", "evidence": "x"}
                  }
                }
                """.utf8
            )
        )
        let presentation = ChannelSectionPresentation(
            grok: snapshot.grok,
            codex: snapshot.codex,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(presentation.render.primaryRow, ["Codex 状态看不懂", "Grok 状态看不懂"])
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(snapshot.grok.unknownKind, .unrecognized)
        XCTAssertEqual(snapshot.codex.unknownKind, .unrecognized)
    }

    func testCollectorUnknownUsesUndeterminedOnPrimaryRow() {
        let snapshot = SentinelFileReader.parseChannelStatus(
            data: Data(
                """
                {
                  "channels": {
                    "grok": {"status": "unknown", "evidence": "无数据"},
                    "codex": {"status": "unknown"}
                  }
                }
                """.utf8
            )
        )
        let presentation = ChannelSectionPresentation(
            grok: snapshot.grok,
            codex: snapshot.codex,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(presentation.render.primaryRow, ["Codex 查不出来", "Grok 查不出来"])
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(snapshot.grok.unknownKind, .undetermined)
        XCTAssertEqual(snapshot.codex.statusText, ChannelUnknownKind.undetermined.statusText)
    }

    func testHealthySectionHasOnlyThePrimaryRow() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "2 条在跑", running: 2),
            codex: ChannelVerdict(status: .alive, evidence: "闲", running: nil),
            liveCounts: EngineCounts(grok: 2, codex: 0)
        )
        XCTAssertEqual(presentation.problemLines, [])
        XCTAssertEqual(presentation.rowCount, 1)
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "Grok 通 2 条"],
                problemLines: []
            )
        )
    }

    func testLiveActiveLinesOverrideStaleChannelStatusRunning() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
            codex: ChannelVerdict(status: .alive, evidence: "闲", running: 0),
            liveCounts: EngineCounts(grok: 4, codex: 0)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "Grok 通 4 条"],
                problemLines: []
            )
        )
        XCTAssertEqual(presentation.grok.itemText, "Grok 通 4 条")
        XCTAssertEqual(presentation.codex.itemText, "Codex 通 闲")
    }
}
