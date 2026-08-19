import XCTest
@testable import CortexSentinelBar

final class RelayAddFailureMessageTests: XCTestCase {
    func testHealthClassProducesSpecificHumanMessage() throws {
        let healthData = Data(
            """
            {
              "checked_at": "2026-07-23T11:00:00Z",
              "ok": false,
              "http_class": "auth",
              "latency_ms": 30
            }
            """.utf8
        )
        let health = try JSONDecoder().decode(RelayHealth.self, from: healthData)

        XCTAssertEqual(
            RelayAddFailureMessage.resolve(output: "", health: health),
            "鉴权失败，请检查 API Key"
        )
    }

    func testRawOutputIsClassifiedWithoutBeingReturned() {
        let secretBearingOutput = "request failed with 503 using sk-test-secret"

        XCTAssertEqual(
            RelayAddFailureMessage.resolve(output: secretBearingOutput, health: nil),
            "中转暂时不可用"
        )
        XCTAssertFalse(
            RelayAddFailureMessage.resolve(output: secretBearingOutput, health: nil)
                .contains("sk-test-secret")
        )
    }
}
