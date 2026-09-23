import Foundation
import XCTest

@testable import CortexSentinelBar

final class CortexTelemetrySummaryTests: XCTestCase {
    private static func payloadJSON() -> Data {
        Data(
            """
            {"schema":2,"machines":[
              {"machine":"pro","cpu_pct":34.2,"mem_free_pct":73.0,"mem_used_pct":65.7,"pressure_level":1,"load":7.7,
               "swap":{"used":"12.30G","total":"48.00G"},
               "dev_slots":{"used":2,"cap":5},
               "lines_by_model":{"custom-local:BC-GLM-5.3-Flash":2,"glm-5.3-flash":1},
               "ts":"2026-09-18T00:00:00+00:00"},
              {"machine":"mini2","cpu_pct":9.0,"mem_free_pct":83.0,"load":2.49,
               "swap":{"used":"1.10G","total":"24.00G"},
               "dev_slots":{"used":0,"cap":2},
               "lines_by_model":{},"ts":"2026-09-18T00:01:00+00:00"}
             ],
             "multica":{"working":3,"idle":9}}
            """.utf8
        )
    }

    private static func state(payload: CortexTelemetrySummaryPayload?, failure: String?) -> CortexTelemetrySummaryDisplayState {
        CortexTelemetrySummaryDisplayState(
            payload: payload,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            failureText: failure,
            failureAt: failure == nil ? nil : Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testRowsRenderHardwareAndSlotLines() throws {
        let payload = try JSONDecoder().decode(CortexTelemetrySummaryPayload.self, from: Self.payloadJSON())
        let rows = CortexTelemetrySummaryDisplay.rows(Self.state(payload: payload, failure: nil), now: Date())
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0], "三机总览（Multica 在跑 3）")
        XCTAssertEqual(rows[1], "Pro CPU 34% · 内存占 66% · 压力正常 · swap 12.30G/48.00G")
        XCTAssert(rows[1].contains("内存占 66%"))
        XCTAssert(rows[1].contains("压力正常"))
        XCTAssert(rows[1].contains("swap 12.30G/48.00G"))
        XCTAssert(rows[2].contains("槽 2/5"))
        XCTAssertEqual(rows[2], "Pro 槽 2/5 · 本机线 3（CodeBuddy×2·ZCode）")
        XCTAssert(rows[3].hasPrefix("mini2 CPU 9%"))
        XCTAssert(rows[4].contains("槽 0/2"))
        XCTAssert(rows[4].contains("本机线 0"))
    }

    func testFailureKeepsSingleLine() {
        let rows = CortexTelemetrySummaryDisplay.rows(Self.state(payload: nil, failure: "脚本退出码 1"), now: Date())
        XCTAssertEqual(rows.count, 1)
        XCTAssert(rows[0].contains("这次没读到"))
        XCTAssertTrue(CortexTelemetrySummaryDisplay.rows(nil, now: Date()).isEmpty)
    }

    func testEmptyMachinesShowsWaitingLine() throws {
        let payload = try JSONDecoder().decode(
            CortexTelemetrySummaryPayload.self,
            from: Data("{\"schema\":2,\"machines\":[],\"multica\":{\"working\":0,\"idle\":0}}".utf8)
        )
        let rows = CortexTelemetrySummaryDisplay.rows(Self.state(payload: payload, failure: nil), now: Date())
        XCTAssertEqual(rows, ["三机总览：还没有机器上报（等各机哨兵 10 分钟一轮）"])
    }

    func testTasksTotalDrivesRunningCount() throws {
        // 新脚本：徽标数「正在执行的任务」，严格对账 tasks_by_machine。
        let json = """
            {"schema":2,"machines":[{"machine":"pro","load":7.7,"ts":"2026-09-18T00:00:00+00:00"}],
             "multica":{"working":2,"idle":8,
                        "tasks_total":24,
                        "tasks_by_machine":{"pro":15,"m1max":5,"mini2":4,"unknown":0},
                        "tasks_by_agent":[{"name":"Pro 执行者(ZCode)","machine":"pro","tasks":15},
                                          {"name":"mini Grok 执行者(Cursor)","machine":"mini2","tasks":4}]}}
            """
        let payload = try JSONDecoder().decode(CortexTelemetrySummaryPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.multica?.tasksTotal, 24)
        XCTAssertEqual(payload.multica?.tasksByMachine, ["pro": 15, "m1max": 5, "mini2": 4, "unknown": 0])
        XCTAssertEqual(payload.multica?.tasksByAgent.count, 2)
        XCTAssertEqual(payload.multica?.tasksByAgent.first?.tasks, 15)
        let rows = CortexTelemetrySummaryDisplay.rows(Self.state(payload: payload, failure: nil), now: Date())
        XCTAssertEqual(rows[0], "三机总览（Multica 在跑 24）")
    }

    func testMissingTaskKeysDecodeAsNilAndEmpty() throws {
        // 旧脚本兼容：没 tasks_* 键给 nil/空，文本行退回 working 个数。
        let payload = try JSONDecoder().decode(
            CortexTelemetrySummaryPayload.self,
            from: Data("{\"schema\":2,\"machines\":[{\"machine\":\"pro\",\"load\":1.0,\"ts\":\"2026-09-18T00:00:00+00:00\"}],\"multica\":{\"working\":7,\"idle\":2}}".utf8)
        )
        XCTAssertNil(payload.multica?.tasksTotal)
        XCTAssertTrue(payload.multica?.tasksByMachine.isEmpty ?? true)
        XCTAssertTrue(payload.multica?.tasksByAgent.isEmpty ?? true)
        let rows = CortexTelemetrySummaryDisplay.rows(Self.state(payload: payload, failure: nil), now: Date())
        XCTAssertEqual(rows[0], "三机总览（Multica 在跑 7）")
    }

    func testShortModelAndMachineToken() {
        XCTAssertEqual(CortexTelemetrySummaryDisplay.shortModel("custom-local:BC-GLM-5.3-Flash"), "CodeBuddy")
        XCTAssertEqual(CortexTelemetrySummaryDisplay.shortModel("glm-5.3-flash"), "ZCode")
        XCTAssertEqual(CortexTelemetrySummaryDisplay.shortModel("cursor-grok-4.6-xhigh-fast"), "Grok Fast")
        let machine = try? JSONDecoder().decode(
            CortexTelemetrySummaryPayload.Machine.self,
            from: Data("{\"machine\":\"yedncdeMac-mini.local\"}".utf8)
        )
        XCTAssertEqual(machine.map { CortexTelemetrySummaryDisplay.machineToken(of: $0) }, "mini2")
    }
}
