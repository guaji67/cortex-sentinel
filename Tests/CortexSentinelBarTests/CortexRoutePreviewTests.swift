import Foundation
import XCTest

@testable import CortexSentinelBar

final class CortexRoutePreviewTests: XCTestCase {
    private static func payloadJSON(freeActive: Bool, beijingTime: String) -> Data {
        let order: [String] = freeActive
            ? ["ZCode 套餐（每执行者塞 3 条、共 6 条软帽）", "CodeBuddy（免费，软帽外全落这里）"]
            : ["CodeBuddy（免费）"]
        let orderArray = order.map { "\"\($0)\"" }.joined(separator: ",")
        let note = freeActive ? "免费窗中：ZCode 在前 CodeBuddy 在后" : "窗外：只落 CodeBuddy，ZCode 不追加"
        return Data(
            """
            {"schema":1,"generated_at":"2026-09-17T12:43:13+00:00",
             "free_window":{"active":\(freeActive),"beijing_time":"\(beijingTime)","window":"23:00-09:00"},
             "lanes":[
               {"lane":"frontend","label":"前端 / 文案","line":"本机 Opus 5 子代理（不建票）"},
               {"lane":["backend","research"],"label":"代码 / 调研","branches":[
                 {"condition":"难度 ≥ 85 分","line":"本机 Codex（GPT 登录在 M1 Max，派回 M1 Max）"},
                 {"condition":"难度 < 85 分","order":[\(orderArray)],"note":"\(note)"}]}
             ]}
            """.utf8
        )
    }

    private static func state(payload: CortexRoutePreviewPayload?, failure: String?) -> CortexRoutePreviewDisplayState {
        CortexRoutePreviewDisplayState(
            payload: payload,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            failureText: failure,
            failureAt: failure == nil ? nil : Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testRowsShowFreeWindowOrder() throws {
        let payload = try JSONDecoder().decode(CortexRoutePreviewPayload.self, from: Self.payloadJSON(freeActive: true, beijingTime: "02:00"))
        let rows = CortexRoutePreviewDisplay.rows(Self.state(payload: payload, failure: nil), now: Date())
        XCTAssert(rows.count == 4)
        XCTAssert(rows[0].contains("免费窗中"))
        XCTAssert(rows[0].contains("02:00"))
        XCTAssert(rows[1].contains("前端 / 文案"))
        XCTAssert(rows[2].contains("≥ 85 分"))
        XCTAssert(rows[2].contains("本机 Codex"))
        XCTAssert(rows[3].contains("ZCode"))
        XCTAssert(rows[3].contains("CodeBuddy"))
    }

    func testRowsFlipWhenOutsideWindow() throws {
        let payload = try JSONDecoder().decode(CortexRoutePreviewPayload.self, from: Self.payloadJSON(freeActive: false, beijingTime: "20:43"))
        let rows = CortexRoutePreviewDisplay.rows(Self.state(payload: payload, failure: nil), now: Date())
        XCTAssert(rows[0].contains("窗外"))
        XCTAssert(rows[3].contains("CodeBuddy"))
        XCTAssert(!rows[3].contains("ZCode"))
    }

    func testFailureKeepsSingleLineAndEmptyStateHides() {
        let failureRows = CortexRoutePreviewDisplay.rows(Self.state(payload: nil, failure: "脚本退出码 1"), now: Date())
        XCTAssert(failureRows.count == 1)
        XCTAssert(failureRows[0].contains("这次没读到"))
        XCTAssert(CortexRoutePreviewDisplay.rows(nil, now: Date()).isEmpty)
    }

    func testRowsRenderV2CandidatesWithPausedSuffix() throws {
        let json = """
        {"schema":2,"generated_at":"2026-09-17T13:00:00+00:00",
         "free_window":{"active":true,"beijing_time":"02:00","window":"23:00-09:00"},
         "lanes":[
           {"lane":"frontend","label":"前端 / 文案","line":"本机 Opus 5 子代理（不建票）"},
           {"lane":["backend","research"],"label":"代码 / 调研","branches":[
             {"condition":"难度 ≥ 85 分","line":"本机 Codex（M1 Max）"},
             {"condition":"难度 < 85 分","candidates":[
               {"name":"Pro 执行者(ZCode)","state":"available","basis":"免费窗中优先填"},
               {"name":"Pro 执行者(CodeBuddy)","state":"available","basis":"免费"},
               {"name":"Pro Grok xhigh 执行者(Cursor)","state":"paused","basis":"not_logged_in"}]}]}
         ]}
        """.utf8
        let payload = try JSONDecoder().decode(CortexRoutePreviewPayload.self, from: Data(json))
        let rows = CortexRoutePreviewDisplay.rows(Self.state(payload: payload, failure: nil), now: Date())
        XCTAssert(rows[0].contains("免费窗中"))
        XCTAssert(rows[3].contains("ZCode"))
        XCTAssert(rows[3].contains("CodeBuddy"))
        XCTAssert(rows[3].contains("Grok（暂停）"))
    }

    func testShortNameStripsRosterPrefixes() {
        XCTAssertEqual(CortexRoutePreviewDisplay.shortName("Pro 执行者(CodeBuddy BCGLM5.3 Flash Max)"), "CodeBuddy")
        XCTAssertEqual(CortexRoutePreviewDisplay.shortName("M1Max 执行者(ZCode GLM Flash·Falcon 套餐)"), "ZCode(Falcon)")
        XCTAssertEqual(CortexRoutePreviewDisplay.shortName("Pro Grok xhigh 执行者(Cursor)"), "Grok")
        XCTAssertEqual(CortexRoutePreviewDisplay.shortName("Pro Grok xhigh Fast 执行者(Cursor)"), "Grok Fast")
        XCTAssertEqual(CortexRoutePreviewDisplay.shortName(nil), "?")
    }

    func testAggregatedNamesCountsDuplicates() {
        XCTAssertEqual(
            CortexRoutePreviewDisplay.aggregatedNames([
                "Pro 执行者(CodeBuddy BCGLM5.3 Flash Max)",
                "M1Max 执行者(CodeBuddy BCGLM5.3 Flash Max)",
                "mini 执行者(CodeBuddy BCGLM5.3 Flash Max)",
            ]),
            ["CodeBuddy", "CodeBuddy(M1Max)", "CodeBuddy(mini)"],
            "同引擎多台标机器（负载分配要看）"
        )
        XCTAssertEqual(CortexRoutePreviewDisplay.aggregatedNames(["Pro 执行者(Kimi K3 Max)"]), ["Kimi"])
    }

    // MARK: - 哨兵点灰（COR-9242）：新字段解码、灰的口径、点了的处置

    private static let executorID = "06ff0149-b857-48c1-bb06-82c2290ab129"

    func testCandidateDecodesExecutorIDAndBlockedFields() throws {
        let json = """
        {"name":"Pro 执行者(CodeBuddy)","state":"available","basis":"免费",
         "executor_id":"\(Self.executorID)",
         "blocked_code":"ai_hold",
         "blocked_text":"可用性清单 ai_hold kind=quota_cooldown until=2026-09-26 12:00"}
        """
        let wrapped = "{\"schema\":2,\"lanes\":[{\"label\":\"L\",\"branches\":[{\"condition\":\"c\",\"candidates\":[\(json)]}]}]}"
        let payload = try JSONDecoder().decode(CortexRoutePreviewPayload.self, from: Data(wrapped.utf8))
        let candidate = payload.lanes[0].branches![0].candidates![0]
        XCTAssertEqual(candidate.executorID, Self.executorID)
        XCTAssertEqual(candidate.blockedCode, "ai_hold")
        XCTAssert(candidate.blockedText?.contains("quota_cooldown") == true)
        // 旧输出（没有这些字段）也解得出。
        let legacy = """
        {"schema":2,"lanes":[{"label":"L","branches":[{"condition":"c","candidates":[{"name":"X","state":"available","basis":"免费"}]}]}]}
        """
        let legacyPayload = try JSONDecoder().decode(CortexRoutePreviewPayload.self, from: Data(legacy.utf8))
        XCTAssertNil(legacyPayload.lanes[0].branches![0].candidates![0].executorID)
        XCTAssertNil(legacyPayload.lanes[0].branches![0].candidates![0].blockedCode)
    }

    func testCandidateFieldsCarryIntoChipsAndGroups() throws {
        let json = """
        {"name":"Pro 执行者(CodeBuddy)","state":"available","basis":"免费",
         "executor_id":"\(Self.executorID)","blocked_code":null,"blocked_text":null}
        """
        let wrapped = "{\"schema\":2,\"lanes\":[{\"label\":\"L\",\"branches\":[{\"condition\":\"c\",\"candidates\":[\(json)]}]}]}"
        let payload = try JSONDecoder().decode(CortexRoutePreviewPayload.self, from: Data(wrapped.utf8))
        let cards = CortexRoutePreviewDisplay.cards(payload)
        XCTAssertEqual(cards.count, 1)
        let chip = try XCTUnwrap(cards[0].chips.first)
        XCTAssertEqual(chip.executorID, Self.executorID)
        XCTAssertNil(chip.blockedCode)
        XCTAssertFalse(chip.isBlocked)
        let group = try XCTUnwrap(cards[0].machineGroups.first)
        XCTAssertEqual(group.chips.first?.executorID, Self.executorID)
    }

    func testChipIsBlockedFollowsJudgmentAndLegacyFallback() {
        // 新输出：灰只认 blocked_code（清单/标记/ai_hold/冷却都算），花名册 available
        // 但被 ai_hold 拦的也灰——不再显示成绿。
        XCTAssertTrue(CortexRoutePreviewDisplay.RouteChip(
            text: "CodeBuddy", paused: false,
            executorID: Self.executorID, blockedCode: "ai_hold", blockedText: "冷却"
        ).isBlocked)
        // 可派：blocked_code 为 nil 即绿。
        XCTAssertFalse(CortexRoutePreviewDisplay.RouteChip(
            text: "CodeBuddy", paused: false,
            executorID: Self.executorID, blockedCode: nil, blockedText: nil
        ).isBlocked)
        // 旧输出（连 blocked_code 都没有）：退回花名册状态，行为不变。
        XCTAssertTrue(CortexRoutePreviewDisplay.RouteChip(text: "CodeBuddy", paused: true).isBlocked)
        XCTAssertFalse(CortexRoutePreviewDisplay.RouteChip(text: "CodeBuddy", paused: false).isBlocked)
    }

    func testActionGreenDotPauses() {
        let chip = CortexRoutePreviewDisplay.RouteChip(
            text: "CodeBuddy", paused: false,
            executorID: Self.executorID, blockedCode: nil, blockedText: nil
        )
        XCTAssertEqual(
            CortexRoutePreviewDisplay.action(for: chip),
            .pauseBoardOnly(executorID: Self.executorID)
        )
    }

    func testActionOwnMarkerGrayDotResumes() {
        let chip = CortexRoutePreviewDisplay.RouteChip(
            text: "CodeBuddy", paused: false,
            executorID: Self.executorID,
            blockedCode: "description_stop_phrase",
            blockedText: "description 命中停派标记行「停派：他在哨兵上点灰（09-26 07:45 北京）」"
        )
        XCTAssertEqual(
            CortexRoutePreviewDisplay.action(for: chip),
            .resumeBoardOnly(executorID: Self.executorID)
        )
    }

    func testActionOtherReasonGrayDotOnlyExplains() {
        // ai_hold / 清单登记 / 名字标记 / 冷却：一律只显示原因，不发命令。
        let samples: [(String, String, String?)] = [
            ("ai_hold", "可用性清单 ai_hold kind=quota_cooldown until=2026-09-26 12:00", "quota_cooldown"),
            ("roster_stopped_note", "可用性清单登记 status=paused（since=2026-09-25 18:44）", "status=paused"),
            ("name_stop_phrase", "name 以「【停派】」开头", nil),
            ("plan_cooldown", "连续被拒冷却中（kind=rejected，到北京 09:30）", nil),
        ]
        for (code, text, contains) in samples {
            let chip = CortexRoutePreviewDisplay.RouteChip(
                text: "CodeBuddy", paused: false,
                executorID: Self.executorID, blockedCode: code, blockedText: text
            )
            guard case let .information(reason) = CortexRoutePreviewDisplay.action(for: chip) else {
                XCTFail("\(code) 应该只显示原因")
                continue
            }
            XCTAssertEqual(reason, text)
            if let contains {
                XCTAssert(reason.contains(contains), code)
            }
        }
        // 别人写死的「停派：积分将尽」标记行也不是哨兵点的，点了只解释。
        let foreign = CortexRoutePreviewDisplay.RouteChip(
            text: "CodeBuddy", paused: false,
            executorID: Self.executorID,
            blockedCode: "description_stop_phrase",
            blockedText: "description 命中停派标记行「停派：积分将尽」"
        )
        guard case let .information(reason) = CortexRoutePreviewDisplay.action(for: foreign) else {
            return XCTFail("别人的停派标记不许发恢复命令")
        }
        XCTAssert(reason.contains("积分将尽"))
    }

    func testActionWithoutExecutorIDOnlyExplains() {
        // 旧预案还没带 id：绿点与自己的灰点都只提示等刷新，不发命令。
        let green = CortexRoutePreviewDisplay.RouteChip(
            text: "CodeBuddy", paused: false, executorID: nil, blockedCode: nil, blockedText: nil
        )
        guard case .information = CortexRoutePreviewDisplay.action(for: green) else {
            return XCTFail("没有 id 不许发命令")
        }
        let ownGray = CortexRoutePreviewDisplay.RouteChip(
            text: "CodeBuddy", paused: false,
            executorID: nil,
            blockedCode: "description_stop_phrase",
            blockedText: "description 命中停派标记行「停派：他在哨兵上点灰（09-26 07:45 北京）」"
        )
        guard case .information = CortexRoutePreviewDisplay.action(for: ownGray) else {
            return XCTFail("没有 id 不许发恢复命令")
        }
    }
}
