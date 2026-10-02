import Foundation
import XCTest
@testable import CortexSentinelBar

final class TelemetryBoardItemsTests: XCTestCase {
    func testOldAgentDecodesWithEmptyItems() throws {
        let data = Data("{\"name\":\"Codex\",\"machine\":\"m1max\",\"tasks\":2}".utf8)
        let row = try JSONDecoder().decode(CortexTelemetrySummaryPayload.Multica.AgentTasks.self, from: data)
        XCTAssertTrue(row.items.isEmpty)
        XCTAssertEqual(row.tasks, 2)
    }

    func testRunningAndQueuedItemsReachHoverCard() throws {
        let data = Data("""
        {"name":"Codex Sol High","machine":"m1max","tasks":1,"items":[
          {"identifier":"COR-1","title":"合成测试标题足够长","status":"running","elapsed_text":"1小时51分","source":"board"},
          {"identifier":"COR-2","title":"","status":"queued","elapsed_text":"2分","source":"board"}]}
        """.utf8)
        let row = try JSONDecoder().decode(CortexTelemetrySummaryPayload.Multica.AgentTasks.self, from: data)
        let lines = TelemetryBoardItemsDisplay.lines(for: [row])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].value, "Codex Sol High")
        XCTAssertEqual(lines[0].note, "1 条")
        XCTAssertEqual(lines[1].label, "COR-1")
        XCTAssertTrue(lines[1].value.contains("已跑 1小时51分 · 看板"))
        XCTAssertEqual(lines[2].value, "排队 2分 · 看板")
        XCTAssertTrue(lines[1].wraps)
    }

    func testLongHoverUsesBoundedRowsAndHiddenCount() {
        let agents = (0..<20).map { index in
            CortexTelemetrySummaryPayload.Multica.AgentTasks(name: "Agent \(index)", machine: "pro", tasks: 1)
        }
        let content = TelemetryBoardItemsDisplay.content(
            title: "Multica 在跑 20", subtitle: "", lines: TelemetryBoardItemsDisplay.lines(for: agents)
        )
        XCTAssertEqual(content.lines.count, 12)
        XCTAssertEqual(content.footer, "另有 8 行未展开")
    }
}
