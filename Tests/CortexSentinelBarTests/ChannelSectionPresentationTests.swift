import XCTest
@testable import CortexSentinelBar

final class ChannelSectionPresentationTests: XCTestCase {
    func testThreeAliveWithRunningCountsRendersExactTexts() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "2 条在跑", running: 2),
            codex: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
            codebuddy: ChannelVerdict(status: .alive, evidence: "3 条在跑", running: 3),
            liveCounts: EngineCounts(grok: 2, codex: 1, codebuddy: 3)
        )
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 1 条", "CodeBuddy 通 3 条", "Grok 通 2 条"],
                problemLines: []
            )
        )
        XCTAssertEqual(presentation.rowCount, 1)
    }

    func testBothAliveIdleWithCodeBuddyMissingRendersExactTexts() {
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
                primaryRow: ["Codex 通 闲", "CodeBuddy 还没有记录", "Grok 通 闲"],
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
                primaryRow: ["Codex 通 闲", "CodeBuddy 还没有记录", "Grok 不通"],
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
                primaryRow: ["Codex 还没有记录", "CodeBuddy 还没有记录", "Grok 还没有记录"],
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
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 还没有记录", "CodeBuddy 还没有记录", "Grok 还没有记录"]
        )
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(presentation.codex.verdict.unknownKind, .noRecord)
        XCTAssertEqual(presentation.grok.verdict.unknownKind, .noRecord)
        XCTAssertEqual(presentation.codebuddy.verdict.unknownKind, .noRecord)
    }

    func testUnreadableFileUsesUnreadableOnPrimaryRow() {
        let presentation = ChannelSectionPresentation(
            grok: .unreadable,
            codex: .unreadable,
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 状态读不出", "CodeBuddy 还没有记录", "Grok 状态读不出"]
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
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 还没有记录", "CodeBuddy 还没有记录", "Grok 通 闲"]
        )
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
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 状态看不懂", "CodeBuddy 还没有记录", "Grok 状态看不懂"]
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
            liveCounts: EngineCounts()
        )
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 查不出", "CodeBuddy 还没有记录", "Grok 查不出"]
        )
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(snapshot.grok.unknownKind, .undetermined)
        XCTAssertEqual(snapshot.codex.statusText, ChannelUnknownKind.undetermined.statusText)
    }

    func testHealthySectionHasOnlyThePrimaryRow() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "2 条在跑", running: 2),
            codex: ChannelVerdict(status: .alive, evidence: "闲", running: nil),
            codebuddy: ChannelVerdict(status: .alive, evidence: "闲", running: nil),
            liveCounts: EngineCounts(grok: 2, codex: 0)
        )
        XCTAssertEqual(presentation.problemLines, [])
        XCTAssertEqual(presentation.rowCount, 1)
        XCTAssertEqual(presentation.render.problemLines, [])
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 闲", "CodeBuddy 通 闲", "Grok 通 2 条"],
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
                primaryRow: ["Codex 通 闲", "CodeBuddy 还没有记录", "Grok 通 4 条"],
                problemLines: []
            )
        )
        XCTAssertEqual(presentation.grok.itemText, "Grok 通 4 条")
        XCTAssertEqual(presentation.codex.itemText, "Codex 通 闲")
    }

    // MARK: 三卡顺序与 CodeBuddy 档

    func testPrimaryRowIsExactlyCodexCodeBuddyGrok() {
        let presentation = ChannelSectionPresentation(
            grok: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
            codex: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
            codebuddy: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
            liveCounts: EngineCounts(grok: 1, codex: 1, codebuddy: 1)
        )
        XCTAssertEqual(presentation.items.map(\.name), ["Codex", "CodeBuddy", "Grok"])
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 通 1 条", "CodeBuddy 通 1 条", "Grok 通 1 条"]
        )
        XCTAssertEqual(presentation.codebuddy.accessibilityIdentifier, "channel-row-codebuddy")
    }

    func testChannelStatusWithCodeBuddyKeyParsesAliveRunning() {
        let json = """
        {
          "generated_at": "2026-09-14T12:00:00+08:00",
          "channels": {
            "grok": {"status": "alive", "evidence": "1 条在跑", "running": 1},
            "codex": {"status": "alive", "evidence": "2 条在跑", "running": 2},
            "codebuddy": {"status": "alive", "evidence": "2 条在跑", "running": 2}
          }
        }
        """
        let snapshot = SentinelFileReader.parseChannelStatus(data: Data(json.utf8))

        XCTAssertEqual(snapshot.codebuddy.status, .alive)
        XCTAssertEqual(snapshot.codebuddy.evidence, "2 条在跑")
        XCTAssertEqual(snapshot.codebuddy.running, 2)

        let presentation = ChannelSectionPresentation(
            grok: snapshot.grok,
            codex: snapshot.codex,
            codebuddy: snapshot.codebuddy,
            liveCounts: EngineCounts(grok: 1, codex: 2, codebuddy: 2)
        )
        XCTAssertEqual(presentation.codebuddy.itemText, "CodeBuddy 通 2 条")
    }

    func testChannelStatusWithoutCodeBuddyKeyParsesMissingNotDegraded() {
        // Cortex 侧 codebuddy 键由另一条线补，两边上线有先后：旧 JSON 不能整份判 invalid。
        let json = """
        {
          "generated_at": "2026-09-14T12:00:00+08:00",
          "channels": {
            "grok": {"status": "alive", "evidence": "1 条在跑", "running": 1},
            "codex": {"status": "alive", "evidence": "2 条在跑", "running": 2}
          }
        }
        """
        let snapshot = SentinelFileReader.parseChannelStatus(data: Data(json.utf8))

        XCTAssertEqual(snapshot.codebuddy, .missing)
        XCTAssertEqual(snapshot.codebuddy.status, .unknown)
        XCTAssertNotEqual(snapshot.codebuddy.status, .degraded)
        XCTAssertEqual(snapshot.grok.status, .alive)
        XCTAssertEqual(snapshot.codex.status, .alive)
        XCTAssertNotNil(snapshot.generatedAt)

        let presentation = ChannelSectionPresentation(
            grok: snapshot.grok,
            codex: snapshot.codex,
            codebuddy: snapshot.codebuddy,
            liveCounts: EngineCounts(grok: 1, codex: 2)
        )
        XCTAssertEqual(presentation.codebuddy.itemText, "CodeBuddy 还没有记录")
        // 还没有记录不是「不通」，不进问题行。
        XCTAssertEqual(presentation.problemLines, [])
        // 摘要没这个键时不摆条数，避免看着像通道已确认。
        XCTAssertNil(presentation.codebuddy.countText)
    }

    // MARK: ox-alpha 下架

    func testOxAlphaDataStillParsesButNeverRendersACard() {
        // 2026-09-14 Falcon 令：ox-alpha 卡下架。磁盘摘要里的 claude-oxalpha 键
        // 继续解析（历史 JSON 不能判 invalid），只是不再画成通道卡。
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
            codebuddy: .missing,
            liveCounts: EngineCounts(grok: 0, codex: 1, claudeOxAlpha: 6)
        )
        XCTAssertEqual(presentation.items.map(\.name), ["Codex", "CodeBuddy", "Grok"])
        XCTAssertFalse(presentation.items.contains { $0.name == "ox-alpha" })
        XCTAssertEqual(
            presentation.render,
            ChannelSectionPresentation.Render(
                primaryRow: ["Codex 通 1 条", "CodeBuddy 还没有记录", "Grok 查不出"],
                problemLines: []
            )
        )
    }

    func testOxAlphaCountsDoNotLeakIntoAnyChannelSlot() {
        let presentation = ChannelSectionPresentation(
            grok: .missing,
            codex: .missing,
            liveCounts: EngineCounts(claudeOxAlpha: 6)
        )
        // ox-alpha 历史线计数留在快照里，但一张通道卡都不冒充。
        XCTAssertEqual(presentation.items.count, 3)
        XCTAssertEqual(
            presentation.render.primaryRow,
            ["Codex 还没有记录", "CodeBuddy 还没有记录", "Grok 还没有记录"]
        )
    }

    func testInvalidChannelStatusMarksAllFourChannelsUnreadable() {
        let snapshot = SentinelFileReader.parseChannelStatus(data: Data("not json".utf8))

        XCTAssertEqual(snapshot, .invalid)
        XCTAssertEqual(snapshot.claudeOxAlpha.evidence, "文件读不出")
        XCTAssertEqual(snapshot.codebuddy.evidence, "文件读不出")
    }
}
