import Foundation
import XCTest
@testable import CortexSentinelBar

final class WorkbenchTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-board-test-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    func ledger() throws -> WorkbenchLedger { try WorkbenchLedger(url: root.appendingPathComponent("ledger.json")) }
    func event(_ id: String, kind: String = "track", track: String? = nil, revision: Int = 0, patch: BoardObject = [:], eventID: String = UUID().uuidString) -> BoardObject {
        ["id": id, "event_id": eventID, "kind": kind, "base_revision": revision,
         "patch": ["track": track ?? id, "title": id].merging(patch, uniquingKeysWith: { _, new in new })]
    }
    func testGenericRegistrationAndFreeformRoundTrip() throws {
        let db = try ledger()
        for index in 0..<100 {
            let id = "module-\(index)"
            let decoded = try WorkbenchJSON.object(WorkbenchJSON.data(event(id, patch: ["arbitrary": ["nested": [1,2,3]], "body": "自由研究，不规定提纲"])))
            XCTAssertEqual(try db.update(decoded, actor: "owner", scopes: ["*"])["revision"] as? Int, 1)
        }
        let reopened = try ledger()
        XCTAssertEqual((reopened.snapshot()["entities"] as? BoardObject)?.count, 100)
        XCTAssertNotNil(reopened.entity("module-99")?["arbitrary"])
    }
    func testBooleanRevisionRejected() throws {
        let db = try ledger(); var e = event("new-module"); e["base_revision"] = true
        XCTAssertThrowsError(try db.update(e, actor: "owner", scopes: ["*"]))
    }
    func testCASAndIdempotencyDoNotOverwrite() throws {
        let db = try ledger(), first = event("research-module")
        _ = try db.update(first, actor: "owner", scopes: ["*"])
        XCTAssertEqual(try db.update(first, actor: "owner", scopes: ["*"])["replayed"] as? Bool, true)
        XCTAssertThrowsError(try db.update(event("research-module", patch: ["body": "old"]), actor: "owner", scopes: ["*"]))
        XCTAssertNil(db.entity("research-module")?["body"])
        var different = first; different["patch"] = ["track": "research-module", "title": "changed"]
        XCTAssertThrowsError(try db.update(different, actor: "owner", scopes: ["*"]))
    }
    func testScopeAndProtectedIdentity() throws {
        let db = try ledger()
        XCTAssertThrowsError(try db.update(event("third-module"), actor: "a", scopes: ["other-module"]))
        XCTAssertThrowsError(try db.update(event("third-module", patch: ["revision": 500]), actor: "a", scopes: ["*"]))
        _ = try db.update(event("third-module"), actor: "a", scopes: ["third-module"])
        XCTAssertThrowsError(try db.update(event("third-module", revision: 1, patch: ["track": "other-module"]), actor: "a", scopes: ["*"]))
    }
    func testArbitraryNestingAndCycleGuard() throws {
        let db = try ledger(); _ = try db.update(event("module"), actor: "a", scopes: ["*"])
        _ = try db.update(event("module:one", kind: "area", track: "module"), actor: "a", scopes: ["module"])
        _ = try db.update(event("module:two", kind: "area", track: "module", patch: ["parent": "module:one"]), actor: "a", scopes: ["module"])
        XCTAssertThrowsError(try db.update(event("module:one", kind: "area", track: "module", revision: 1, patch: ["parent": "module:two"]), actor: "a", scopes: ["module"]))
    }
    func testVerificationRequiresEvidenceAndNewEvidenceAfterRegression() throws {
        let db = try ledger(); _ = try db.update(event("module"), actor: "a", scopes: ["*"])
        let base: BoardObject = ["state": "verified", "classification": "confirmed_bug"]
        XCTAssertThrowsError(try db.update(event("defect", kind: "problem", track: "module", patch: base), actor: "a", scopes: ["module"]))
        let evidence = ["machine": "target", "version": "test", "action": "open", "expected": "visible", "actual": "visible", "checked_at": WorkbenchJSON.timestamp(), "reference": "synthetic receipt"]
        _ = try db.update(event("defect", kind: "problem", track: "module", patch: base.merging(["evidence": evidence], uniquingKeysWith: { _,new in new })), actor: "a", scopes: ["module"])
        _ = try db.update(event("defect", kind: "problem", track: "module", revision: 1, patch: ["state": "repairing"]), actor: "a", scopes: ["module"])
        XCTAssertThrowsError(try db.update(event("defect", kind: "problem", track: "module", revision: 2, patch: ["state": "verified"]), actor: "a", scopes: ["module"]))
    }
    func testSourcePreservesExplicitUpdatesAndRejectsStale() throws {
        let db = try ledger(); _ = try db.update(event("module"), actor: "a", scopes: ["*"])
        let source: BoardObject = ["track": "module", "observed_at": "2026-09-21T00:00:00Z", "blocks": [["id": "module:one", "track": "module", "title": "source", "source_color": "blue"]]]
        _ = try db.publish(source, scopes: ["module"])
        _ = try db.update(event("module:one", kind: "area", track: "module", revision: 1, patch: ["body": "independent judgement"]), actor: "a", scopes: ["module"])
        _ = try db.publish(source, scopes: ["module"])
        XCTAssertEqual(db.entity("module:one")?["body"] as? String, "independent judgement")
        var stale = source; stale["observed_at"] = "2026-09-20T00:00:00Z"
        XCTAssertThrowsError(try db.publish(stale, scopes: ["module"]))
        XCTAssertThrowsError(try db.publish(source, scopes: ["other-module"]))
    }
    func testCorruptionDoesNotResetLedger() throws {
        try Data("invalid".utf8).write(to: root.appendingPathComponent("ledger.json"))
        XCTAssertThrowsError(try ledger())
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("ledger.json")), "invalid")
    }
    func testDraftRevisionGuard() throws {
        let db = try ledger()
        _ = try db.saveDrafts(["base_revision": 0, "drafts": ["domains": ["d": ["owner": "owner"]]]])
        XCTAssertThrowsError(try db.saveDrafts(["base_revision": 0, "drafts": [:]]))
    }
    func testHTTPPartialDuplicateChunkedAndBounded() throws {
        XCTAssertNil(try WorkbenchRequest.parse(Data("GET / HTTP/1.1\r\nHost: localhost".utf8), loopback: true))
        let valid = try XCTUnwrap(WorkbenchRequest.parse(Data("POST /api/update HTTP/1.1\r\nHost: localhost:8935\r\nContent-Length: 2\r\n\r\n{}".utf8), loopback: true))
        XCTAssertEqual(valid.body, Data("{}".utf8)); XCTAssertTrue(valid.local)
        XCTAssertThrowsError(try WorkbenchRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}".utf8), loopback: true))
        XCTAssertThrowsError(try WorkbenchRequest.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), loopback: true))
        XCTAssertThrowsError(try WorkbenchRequest.parse(Data(repeating: 65, count: 17000), loopback: true))
    }
    func testAuthReadWriteReplayWindowAndCSRF() throws {
        let config: BoardObject = ["view_key": "view-secret", "clients": ["owner": ["secret": "writer-secret", "scopes": ["module"]]]]
        let stamp = String(Int(Date().timeIntervalSince1970))
        var request = WorkbenchRequest(method: "GET", path: "/api/overview", headers: ["host": "10.0.0.2:8935"], body: Data(), loopback: false)
        XCTAssertFalse(WorkbenchAuth.canRead(request, config: config))
        request.headers["authorization"] = "Bearer view-secret"
        XCTAssertTrue(WorkbenchAuth.canRead(request, config: config))
        XCTAssertThrowsError(try WorkbenchAuth.writer(request, config: config))
        request.headers.merge(["x-board-client": "owner", "x-board-time": stamp,
            "x-board-signature": WorkbenchAuth.signature(secret: "writer-secret", timestamp: stamp, path: request.path, body: Data())]) { _,n in n }
        XCTAssertEqual(try WorkbenchAuth.writer(request, config: config).1, ["module"])
        request.headers["x-board-time"] = "1"
        XCTAssertThrowsError(try WorkbenchAuth.writer(request, config: config))
        request.loopback = true; request.headers["host"] = "localhost:8935"; request.headers["x-sentinel-local"] = "1"
        request.headers["origin"] = "https://example.com"
        XCTAssertThrowsError(try request.localWrite())
        request.headers["origin"] = "http://localhost:8935"; XCTAssertNoThrow(try request.localWrite())
    }
    func testHubAddressBoundary() {
        for value in ["http://10.1.1.3:8935", "http://my-computer.local:8935", "http://192.168.1.2"] { XCTAssertTrue(WorkbenchRuntime.validHub(value)) }
        for value in ["https://example.com", "http://8.8.8.8", "http://user:pass@10.0.0.1", "http://10.0.0.1/path", "file:///tmp"] { XCTAssertFalse(WorkbenchRuntime.validHub(value)) }
    }
    func testUnconfiguredAndUnauthorizedRuntime() async throws {
        let runtime = try WorkbenchRuntime(directory: root, assets: root, managedInstallation: false) { ["machines": []] }
        let local = WorkbenchRequest(method: "GET", path: "/api/overview", headers: ["host": "localhost:8935"], body: Data(), loopback: true)
        let response = try await runtime.respond(local)
        let object = try WorkbenchJSON.object(response.data)
        XCTAssertEqual((object["connection"] as? BoardObject)?["mode"] as? String, "unconfigured")
        var remote = local; remote.loopback = false
        do { _ = try await runtime.respond(remote); XCTFail("remote read should require pairing") } catch let error as WorkbenchError { XCTAssertEqual(error.status, 401) }
    }
}
