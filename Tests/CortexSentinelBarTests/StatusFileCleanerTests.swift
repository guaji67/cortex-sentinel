import Foundation
import XCTest
@testable import CortexSentinelBar

final class StatusFileCleanerTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_784_880_000)

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("status-cleaner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    func testNamedCapIsTheHookAndMatchesDisplayNumberToday() {
        XCTAssertEqual(StatusFileRetention.defaultCap, 500)
        XCTAssertEqual(StatusFileRetention.defaultCap, SentinelBoardWindow.historyDisplayCap)
        let plan = StatusFileCleaner.plan(logsDirectory: root, cap: 3, fileManager: fileManager)
        XCTAssertEqual(plan.cap, 3)
    }

    func testKeepsNewestNonLiveFilesAndNeverDeletesRunning() throws {
        // 4 条终态 + 1 条最老的活线；上限 3 → 删最旧终态，活线留下。
        writeStatus("old-done", state: "done", engine: .codex, ageSeconds: 5000)
        writeStatus("mid-done", state: "done", engine: .codex, ageSeconds: 3000)
        writeStatus("new-done", state: "done", engine: .codex, ageSeconds: 100)
        writeStatus("grok-old", state: "done", engine: .cursorGrok, ageSeconds: 4000)
        writeStatus("ancient-live", state: "running", engine: .codex, ageSeconds: 8000)

        writeRaw("codex-line-registry.json")
        writeRaw("channel-status.json")
        writeLog("codex-old-done.log")

        let plan = StatusFileCleaner.plan(
            logsDirectory: root,
            cap: 3,
            fileManager: fileManager
        )
        let deleteNames = plan.candidates.map(\.fileName)
        XCTAssertEqual(deleteNames, ["codex-babysitter-old-done.status.json"])
        XCTAssertEqual(plan.protectedLive, ["codex-babysitter-ancient-live.status.json"])
        XCTAssertEqual(plan.keptCount, 4)
        XCTAssertFalse(deleteNames.contains("codex-line-registry.json"))
        XCTAssertFalse(deleteNames.contains("channel-status.json"))
        XCTAssertFalse(deleteNames.contains("codex-old-done.log"))
    }

    func testWaitingRelayIsProtectedLikeLogCleaner() {
        writeStatus("wait", state: "waiting_relay", engine: .codex, ageSeconds: 9000)
        writeStatus("a", state: "done", engine: .codex, ageSeconds: 300)
        writeStatus("b", state: "done", engine: .codex, ageSeconds: 200)
        writeStatus("c", state: "done", engine: .codex, ageSeconds: 100)

        let plan = StatusFileCleaner.plan(
            logsDirectory: root,
            cap: 2,
            fileManager: fileManager
        )
        XCTAssertTrue(
            plan.protectedLive.contains("codex-babysitter-wait.status.json")
        )
        XCTAssertFalse(
            plan.candidates.map(\.fileName).contains("codex-babysitter-wait.status.json")
        )
        XCTAssertEqual(plan.candidates.map(\.slug), ["a"])
    }

    func testSortOrderMatchesBoardWindowNewestFirst() {
        writeStatus("alpha", state: "done", engine: .codex, ageSeconds: 300)
        writeStatus("beta", state: "done", engine: .cursorGrok, ageSeconds: 100)
        writeStatus("gamma", state: "done", engine: .codex, ageSeconds: 200)

        let lines = SentinelFileReader.readLines(in: root, fileManager: fileManager)
        let presentations = lines.map { LinePresentation(line: $0, registration: nil) }
        let boardOrder = SentinelBoardWindow.newestFirst(presentations).map(\.line.slug)
        XCTAssertEqual(boardOrder, ["beta", "gamma", "alpha"])

        let plan = StatusFileCleaner.plan(
            logsDirectory: root,
            cap: 2,
            fileManager: fileManager
        )
        XCTAssertEqual(plan.candidates.map(\.slug), ["alpha"])
    }

    func testDryRunDeletesNothingButExecuteDoes() {
        writeStatus("old", state: "done", engine: .codex, ageSeconds: 400)
        writeStatus("new", state: "done", engine: .codex, ageSeconds: 10)
        let oldURL = root.appendingPathComponent("codex-babysitter-old.status.json")

        let dry = StatusFileCleaner.run(
            logsDirectory: root,
            dryRun: true,
            cap: 1,
            fileManager: fileManager
        )
        XCTAssertEqual(dry.candidates.map(\.slug), ["old"])
        XCTAssertTrue(fileManager.fileExists(atPath: oldURL.path))

        StatusFileCleaner.run(
            logsDirectory: root,
            dryRun: false,
            cap: 1,
            fileManager: fileManager
        )
        XCTAssertFalse(fileManager.fileExists(atPath: oldURL.path))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: root.appendingPathComponent("codex-babysitter-new.status.json").path
            )
        )
    }

    func testVolumeCleanerStillDoesNotDeleteStatusFiles() {
        writeStatus("done-line", state: "done", engine: .codex, ageSeconds: 7200)
        writeLog("codex-done-line.log")

        let logPlan = LogCleaner.plan(
            logsDirectory: root,
            now: now,
            fileManager: fileManager
        )
        XCTAssertEqual(logPlan.candidates.map(\.fileName), ["codex-done-line.log"])
        XCTAssertFalse(
            logPlan.candidates.contains { $0.fileName.hasSuffix(".status.json") }
        )
    }

    func testExactlyAtCapDeletesNothing() {
        writeStatus("one", state: "done", engine: .codex, ageSeconds: 30)
        writeStatus("two", state: "done", engine: .codex, ageSeconds: 20)
        let plan = StatusFileCleaner.plan(
            logsDirectory: root,
            cap: 2,
            fileManager: fileManager
        )
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertEqual(plan.keptCount, 2)
    }

    // MARK: helpers

    private func writeStatus(
        _ slug: String,
        state: String,
        engine: LineEngine,
        ageSeconds: TimeInterval
    ) {
        let fileName: String
        if engine.isCursorGrok {
            fileName = "grok-\(slug).status.json"
        } else {
            fileName = "codex-babysitter-\(slug).status.json"
        }
        let url = root.appendingPathComponent(fileName)
        let payload = """
        {"slug":"\(slug)","state":"\(state)","engine":"\(engine.isCursorGrok ? "cursor-grok" : "codex")"}
        """
        fileManager.createFile(atPath: url.path, contents: Data(payload.utf8))
        try? fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ageSeconds)],
            ofItemAtPath: url.path
        )
    }

    private func writeRaw(_ name: String) {
        let url = root.appendingPathComponent(name)
        fileManager.createFile(atPath: url.path, contents: Data("{}".utf8))
    }

    private func writeLog(_ name: String) {
        let url = root.appendingPathComponent(name)
        fileManager.createFile(atPath: url.path, contents: Data(repeating: 0x61, count: 80))
        try? fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7200)],
            ofItemAtPath: url.path
        )
    }
}
