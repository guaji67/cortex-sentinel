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
}
