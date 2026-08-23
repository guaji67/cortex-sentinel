import XCTest
@testable import CortexSentinelBar

final class ChannelSectionPresentationTests: XCTestCase {
    func testBothAliveWithRunningCountsRendersExactTexts() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "2 条在跑", running: 2),
            codex: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts(grok: 2, codex: 1)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 1 条", "Grok 通 2 条", "ox-alpha 还没有记录"],
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
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts(grok: 0, codex: 0)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "Grok 通 闲", "ox-alpha 还没有记录"],
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
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts(grok: 0, codex: 0)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "Grok 不通", "ox-alpha 还没有记录"],
                problemLines: ["Grok 不通，账单未付，进程秒退"]
            )
        )
        XCTAssertEqual(presentation.rowCount, 2)
    }

    func testBothUnknownRendersExactTexts() {
        let presentation = ChannelSectionPresentation(
            grok: .missing,
            codex: .missing,
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 还没有记录", "Grok 还没有记录", "ox-alpha 还没有记录"],
                problemLines: []
            )
        )
        XCTAssertEqual(presentation.rowCount, 1)
    }

    func testMissingFileUsesNoRecordOnPrimaryRow() {
        let presentation = ChannelSectionPresentation(
            grok: .missing,
            codex: .missing,
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 还没有记录", "Grok 还没有记录", "ox-alpha 还没有记录"]
        )
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(presentation.codex.verdict.unknownKind, .noRecord)
        XCTAssertEqual(presentation.grok.verdict.unknownKind, .noRecord)
    }

    func testUnreadableFileUsesUnreadableOnPrimaryRow() {
        let presentation = ChannelSectionPresentation(
            grok: .unreadable,
            codex: .unreadable,
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 状态读不出", "Grok 状态读不出", "ox-alpha 还没有记录"]
        )
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
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(presentation.render.primaryRow, ["Codex 还没有记录", "Grok 通 闲", "ox-alpha 还没有记录"])
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
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 状态看不懂", "Grok 状态看不懂", "ox-alpha 还没有记录"]
        )
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
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 查不出来", "Grok 查不出来", "ox-alpha 还没有记录"]
        )
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(snapshot.grok.unknownKind, .undetermined)
        XCTAssertEqual(snapshot.codex.statusText, ChannelUnknownKind.undetermined.statusText)
    }

    func testHealthySectionHasOnlyThePrimaryRow() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "2 条在跑", running: 2),
            codex: ChannelVerdict(status: .alive, evidence: "闲", running: nil),
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts(grok: 2, codex: 0)
        )
        XCTAssertEqual(presentation.problemLines, [])
        XCTAssertEqual(presentation.rowCount, 1)
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "Grok 通 2 条", "ox-alpha 还没有记录"],
                problemLines: []
            )
        )
    }

    func testLiveActiveLinesOverrideStaleChannelStatusRunning() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
            codex: ChannelVerdict(status: .alive, evidence: "闲", running: 0),
            claudeOxAlpha: .missing,
            liveCounts: EngineCounts(grok: 4, codex: 0)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "Grok 通 4 条", "ox-alpha 还没有记录"],
                problemLines: []
            )
        )
        XCTAssertEqual(presentation.grok.itemText, "Grok 通 4 条")
        XCTAssertEqual(presentation.codex.itemText, "Codex 通 闲")
    }

    // MARK: ox-alpha 第三张卡

    func testChannelStatusWithThirdKeyRendersThreeCards() {
        let json = """
        {
          "generated_at": "2026-08-23T02:57:33+08:00",
          "channels": {
            "grok": {"status": "unknown", "evidence": "待一次真派工确认", "running": 0},
            "codex": {"status": "alive", "evidence": "1 条在跑，57 条终态", "running": 1},
            "claude-oxalpha": {"status": "alive", "evidence": "6 条在跑，21 条终态", "running": 6}
          }
        }
        """
        let snapshot = SentinelFileReader.parseChannelStatus(data: Data(json.utf8))

        XCTAssertEqual(snapshot.claudeOxAlpha.status, .alive)
        XCTAssertEqual(snapshot.claudeOxAlpha.evidence, "6 条在跑，21 条终态")
        XCTAssertEqual(snapshot.claudeOxAlpha.running, 6)

        let presentation = ChannelSectionPresentation(
            grok: snapshot.grok,
            codex: snapshot.codex,
            claudeOxAlpha: snapshot.claudeOxAlpha,
            liveCounts: EngineCounts(grok: 0, codex: 1, claudeOxAlpha: 6)
        )
        XCTAssertEqual(presentation.items.count, 3)
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 1 条", "Grok 查不出来", "ox-alpha 通 6 条"],
                problemLines: []
            )
        )
        XCTAssertEqual(
            presentation.claudeOxAlpha.accessibilityIdentifier,
            "channel-row-ox-alpha"
        )
    }

    func testChannelStatusWithoutThirdKeyKeepsOxAlphaCardAsMissingNotDegraded() {
        // 本机 channel-status.json 此刻就是这个形状：只有 grok / codex 两键。
        let json = """
        {
          "generated_at": "2026-08-23T02:57:33+08:00",
          "channels": {
            "grok": {"status": "alive", "evidence": "最近一次派工正常终态 done", "running": 0},
            "codex": {"status": "alive", "evidence": "1 条在跑，57 条终态", "running": 1}
          }
        }
        """
        let snapshot = SentinelFileReader.parseChannelStatus(data: Data(json.utf8))

        XCTAssertEqual(snapshot.claudeOxAlpha, .missing)
        XCTAssertEqual(snapshot.claudeOxAlpha.status, .unknown)
        XCTAssertNotEqual(snapshot.claudeOxAlpha.status, .degraded)
        XCTAssertNotNil(snapshot.generatedAt)

        let presentation = ChannelSectionPresentation(
            grok: snapshot.grok,
            codex: snapshot.codex,
            claudeOxAlpha: snapshot.claudeOxAlpha,
            liveCounts: EngineCounts(grok: 0, codex: 1, claudeOxAlpha: 3)
        )
        XCTAssertEqual(presentation.items.count, 3)
        XCTAssertEqual(presentation.claudeOxAlpha.itemText, "ox-alpha 还没有记录")
        // 还没有记录不是「不通」，不进问题行。
        XCTAssertEqual(presentation.problemLines, [])
        // 摘要没这个键时也不摆条数，避免看着像通道已确认。
        XCTAssertNil(presentation.claudeOxAlpha.countText)
    }

    func testInvalidChannelStatusMarksAllThreeChannelsUnreadable() {
        let snapshot = SentinelFileReader.parseChannelStatus(data: Data("not json".utf8))

        XCTAssertEqual(snapshot, .invalid)
        XCTAssertEqual(snapshot.claudeOxAlpha.evidence, "文件读不出")
    }
}
