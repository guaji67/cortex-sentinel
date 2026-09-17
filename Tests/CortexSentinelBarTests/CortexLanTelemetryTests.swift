import Foundation
import XCTest

@testable import CortexSentinelBar

final class CortexLanTelemetryTests: XCTestCase {
    private let servePort: UInt16 = 47_123
    private let deadPort: UInt16 = 47_124

    func testServerServesPayloadToClient() {
        let payload = Data(#"{"machine":"pro"}"#.utf8)
        let server = LanTelemetryServer(port: servePort) { payload }
        server.start()
        defer { server.stop() }

        let finished = expectation(description: "fetch payload")
        Task {
            let data = await LanTelemetryFetcher.fetch(host: "127.0.0.1", port: self.servePort)
            XCTAssertEqual(data, payload)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }

    func testFetcherReturnsNilOnDeadPort() {
        let started = Date()
        let finished = expectation(description: "dead port returns nil")
        Task {
            let data = await LanTelemetryFetcher.fetch(host: "127.0.0.1", port: self.deadPort, timeout: 2)
            XCTAssertNil(data)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }

    func testServerStartStopCycle() {
        let server = LanTelemetryServer(port: servePort) {
            Data(#"{"machine":"pro"}"#.utf8)
        }
        server.start()
        XCTAssertTrue(server.isRunning)
        server.stop()
        XCTAssertFalse(server.isRunning)
        server.start()
        XCTAssertTrue(server.isRunning)
        server.stop()
        XCTAssertFalse(server.isRunning)
    }
}
