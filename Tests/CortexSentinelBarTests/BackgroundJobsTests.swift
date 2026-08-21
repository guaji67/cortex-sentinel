import Foundation
import XCTest
@testable import CortexSentinelBar

final class BackgroundJobsTests: XCTestCase {
    func testReaderDecodesJobsAndMalformedDataFallsBackToEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-background-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            #"{"jobs":[{"label":"com.fixture.job","name":"样例","status":"ok","status_text":"正常","plist_status":"loaded"}]}"#.utf8
        ).write(to: root)

        let jobs = BackgroundJobsReader.read(at: root)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.label, "com.fixture.job")
        XCTAssertEqual(jobs.first?.statusText, "正常")

        try Data("not json".utf8).write(to: root)
        XCTAssertEqual(BackgroundJobsReader.read(at: root), [])
    }

    func testDisabledJobsReadWriteAndMergeKeepsMissingLabelsVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-disabled-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DisabledJobsStore(url: root)

        _ = try store.adding("com.fixture.deleted")
        XCTAssertEqual(store.read(), ["com.fixture.deleted"])

        let rows = BackgroundJobsPresentation.merge(
            jobs: [BackgroundJob(label: "com.fixture.live", name: "仍在")],
            disabledLabels: store.read()
        )
        XCTAssertEqual(rows.map(\.job.label), ["com.fixture.deleted", "com.fixture.live"])
        XCTAssertTrue(rows.first(where: { $0.job.label == "com.fixture.deleted" })?.isDisabled == true)

        _ = try store.removing("com.fixture.deleted")
        XCTAssertEqual(store.read(), [])
        try Data("broken".utf8).write(to: root)
        XCTAssertEqual(store.read(), [])
    }

    func testLaunchctlCommandsUseGuiDomainAndExpectedArguments() {
        XCTAssertEqual(
            LaunchctlCommandBuilder.bootout(uid: 503, label: "com.fixture.job"),
            ["bootout", "gui/503/com.fixture.job"]
        )
        XCTAssertEqual(
            LaunchctlCommandBuilder.disable(uid: 503, label: "com.fixture.job"),
            ["disable", "gui/503/com.fixture.job"]
        )
        XCTAssertEqual(
            LaunchctlCommandBuilder.enable(uid: 503, label: "com.fixture.job"),
            ["enable", "gui/503/com.fixture.job"]
        )
        XCTAssertEqual(
            LaunchctlCommandBuilder.bootstrap(
                uid: 503,
                plistURL: URL(fileURLWithPath: "/Users/fixture/Library/LaunchAgents/com.fixture.job.plist")
            ),
            ["bootstrap", "gui/503", "/Users/fixture/Library/LaunchAgents/com.fixture.job.plist"]
        )
    }

    func testCriticalLabelsRequireConfirmation() {
        XCTAssertEqual(BackgroundJobsConstants.criticalLabels.count, 4)
        XCTAssertTrue(BackgroundJobsConstants.criticalLabels.contains("com.falcon.cortex.web"))
        XCTAssertFalse(BackgroundJobsConstants.criticalLabels.contains("com.fixture.job"))
    }

    @MainActor
    func testStoreDisableUsesInjectedRunnerInOrderAndPersistsLabel() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("sentinel-store-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let paths = SentinelPaths(
            repositoryRoot: root,
            poolDirectory: root,
            aioDatabaseURL: root.appendingPathComponent("aio.db"),
            aioManifestURL: root.appendingPathComponent("manifest.json"),
            codexConfigURL: root.appendingPathComponent("config.toml"),
            codexAuthURL: root.appendingPathComponent("auth.json"),
            inputStatusURL: URL(string: "https://status.fixture.test/api/status")!,
            logsDirectory: root
        )
        let disabledURL = root.appendingPathComponent("disabled-jobs.json")
        let runner = RecordingLaunchctlRunner(results: [
            LaunchctlResult(exitCode: 0, standardOutput: "", standardError: ""),
            LaunchctlResult(exitCode: 0, standardOutput: "", standardError: ""),
        ])
        let store = SentinelStore(
            paths: paths,
            launchctlRunner: runner,
            disabledJobsURL: disabledURL,
            launchctlUID: 503
        )

        store.disableBackgroundJob("com.fixture.job")
        for _ in 0..<20 {
            if !(await runner.recordedArguments().isEmpty) {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let recordedArguments = await runner.recordedArguments()
        XCTAssertEqual(
            recordedArguments,
            [
                ["bootout", "gui/503/com.fixture.job"],
                ["disable", "gui/503/com.fixture.job"],
            ]
        )
        XCTAssertEqual(DisabledJobsStore(url: disabledURL).read(), ["com.fixture.job"])
    }
}

private actor RecordingLaunchctlRunner: LaunchctlRunning {
    private var queuedResults: [LaunchctlResult]
    private var arguments: [[String]] = []

    init(results: [LaunchctlResult]) {
        queuedResults = results
    }

    func run(arguments: [String]) async -> LaunchctlResult {
        self.arguments.append(arguments)
        if queuedResults.isEmpty {
            return LaunchctlResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return queuedResults.removeFirst()
    }

    func recordedArguments() -> [[String]] {
        return arguments
    }
}
