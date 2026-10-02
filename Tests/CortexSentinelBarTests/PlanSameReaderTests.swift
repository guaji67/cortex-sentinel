import XCTest
@testable import CortexSentinelBar

final class PlanSameReaderTests: XCTestCase {
    private func payload() throws -> CortexPlanStatusPayload {
        let json = #"{"schema":1,"plans":[{"id":"ylao","max_parallel":5,"running":2,"executors":[{"name":"ZCode","running":2,"max_concurrent_tasks":5}]}],"dispatch_policy":{"priority_account":"ylao","priority_mode":"burn"}}"#
        return try JSONDecoder().decode(CortexPlanStatusPayload.self, from: Data(json.utf8))
    }

    func testSharedCapAndPriorityDecode() throws {
        let data = try payload()
        XCTAssertEqual(data.plans.first?.maxParallel, 5)
        XCTAssertEqual(data.plans.first?.executors.first?.maxConcurrentTasks, 5)
        XCTAssertEqual(data.dispatchPolicy?.priorityAccount, "ylao")
        XCTAssertEqual(data.dispatchPolicy?.priorityMode, "burn")
    }

    func testSuccessfulSnapshotExpiresAtSixtySeconds() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let state = CortexPlanStatusDisplayState(payload: try payload(), fetchedAt: now, failureText: nil)
        XCTAssertEqual(CortexPlanStatusDisplay.freshness(state, now: now.addingTimeInterval(59)), .fresh)
        XCTAssertEqual(CortexPlanStatusDisplay.freshness(state, now: now.addingTimeInterval(60)), .stale)
    }

    func testFailedReadImmediatelyHidesOldNumbers() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let state = CortexPlanStatusDisplayState(payload: try payload(), fetchedAt: now, failureText: "读不到")
        XCTAssertEqual(CortexPlanStatusDisplay.freshness(state, now: now), .stale)
        XCTAssertEqual(CortexPlanStatusDisplay.thirdColumnText(plan: try payload().plans[0], now: now, state: state), "读不到")
    }

    func testMissingCurrentReadingDoesNotRenderFallbackCap() throws {
        let json = #"{"schema":1,"plans":[{"id":"ylao","max_parallel":null,"running":2,"read_error":"读不到派工口径"}]}"#
        let data = try JSONDecoder().decode(CortexPlanStatusPayload.self, from: Data(json.utf8))
        XCTAssertEqual(CortexPlanStatusDisplay.thirdColumnText(plan: data.plans[0], now: Date()), "读不到")
    }
    func testMachineCountComesFromSharedScalarAndExpires() throws {
        let json = #"{"machine":"pro","running_lines":3,"lines_by_model":{"old-model":99},"ts":"1970-01-01T00:16:40Z"}"#
        let machine = try JSONDecoder().decode(CortexTelemetrySummaryPayload.Machine.self, from: Data(json.utf8))
        XCTAssertTrue(CortexTelemetrySummaryDisplay.slotLine(of: machine, now: Date(timeIntervalSince1970: 1059)).contains("本机线 3"))
        XCTAssertTrue(CortexTelemetrySummaryDisplay.slotLine(of: machine, now: Date(timeIntervalSince1970: 1060)).contains("读不到"))
    }

}
