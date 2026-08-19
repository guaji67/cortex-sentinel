import Foundation
import XCTest
@testable import CortexSentinelBar

final class SentinelSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private let fileManager = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    override func setUpWithError() throws {
        suiteName = "sentinel-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        root = fileManager.temporaryDirectory
            .appendingPathComponent("sentinel-settings-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let root {
            try? fileManager.removeItem(at: root)
        }
    }

    func testKeysUseBundlePrefixAndCopyIsExact() {
        XCTAssertEqual(SentinelSettingsKey.bundlePrefix, "com.falcon.cortex.sentinelbar")
        XCTAssertTrue(SentinelSettingsKey.loginItemEnabled.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertTrue(SentinelSettingsKey.historyRetainCount.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertTrue(SentinelSettingsKey.notifyOnTaskComplete.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertTrue(SentinelSettingsKey.watchDirectory.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertEqual(SentinelSettingsCopy.loginItemTitle, "开机时自动启动")
        XCTAssertEqual(SentinelSettingsCopy.loginItemManagedHint, "由系统服务托管，改这里没用")
        XCTAssertEqual(SentinelSettingsCopy.historyTitle, "历史最多保留")
        XCTAssertEqual(SentinelSettingsCopy.historyUnit, "条")
        XCTAssertEqual(SentinelSettingsCopy.historyHint, "超出的旧记录会自动清掉，正在跑的线不会被清。")
        XCTAssertEqual(SentinelSettingsCopy.notifyTitle, "任务结束时通知我")
        XCTAssertEqual(SentinelSettingsCopy.watchTitle, "盯这个文件夹")
        XCTAssertEqual(SentinelSettingsCopy.watchChoose, "选择…")
        XCTAssertEqual(SentinelSettingsCopy.watchHint, "派工工具把状态文件写在这里。")
        XCTAssertEqual(SentinelSettingsCopy.watchLockedHint, "由启动配置指定")
    }

    func testSwitchAndCountDefaultsThenRoundTrip() {
        XCTAssertTrue(SentinelSettings.loginItemEnabled(defaults: defaults))
        XCTAssertTrue(SentinelSettings.notifyOnTaskComplete(defaults: defaults))
        XCTAssertEqual(
            SentinelSettings.historyRetainCount(defaults: defaults),
            StatusFileRetention.defaultCap
        )
        XCTAssertEqual(StatusFileRetention.defaultCap, 500)

        SentinelSettings.setLoginItemEnabled(false, defaults: defaults)
        SentinelSettings.setNotifyOnTaskComplete(false, defaults: defaults)
        SentinelSettings.setHistoryRetainCount(12, defaults: defaults)

        XCTAssertFalse(SentinelSettings.loginItemEnabled(defaults: defaults))
        XCTAssertFalse(SentinelSettings.notifyOnTaskComplete(defaults: defaults))
        XCTAssertEqual(SentinelSettings.historyRetainCount(defaults: defaults), 12)
    }

    func testHistoryRetainCountChangeDrivesStatusFileCleanup() throws {
        writeStatus("keep-new", state: "done", ageSeconds: 10)
        writeStatus("keep-mid", state: "done", ageSeconds: 20)
        writeStatus("drop-old", state: "done", ageSeconds: 90)
        writeStatus("drop-older", state: "done", ageSeconds: 120)
        writeStatus("live", state: "running", ageSeconds: 5)

        SentinelSettings.setHistoryRetainCount(2, defaults: defaults)
        let cap = SentinelSettings.historyRetainCount(defaults: defaults)
        XCTAssertEqual(cap, 2)

        let plan = StatusFileCleaner.plan(
            logsDirectory: root,
            cap: cap,
            fileManager: fileManager
        )
        XCTAssertEqual(plan.cap, 2)
        XCTAssertEqual(Set(plan.candidates.map(\.slug)), ["drop-old", "drop-older"])
        XCTAssertTrue(plan.protectedLive.contains("codex-babysitter-live.status.json"))

        let dry = StatusFileCleaner.run(
            logsDirectory: root,
            dryRun: true,
            cap: cap,
            fileManager: fileManager
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: root.appendingPathComponent("codex-babysitter-drop-old.status.json").path
            )
        )

        StatusFileCleaner.run(
            logsDirectory: root,
            dryRun: false,
            cap: cap,
            fileManager: fileManager
        )
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: root.appendingPathComponent("codex-babysitter-drop-old.status.json").path
            )
        )
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: root.appendingPathComponent("codex-babysitter-drop-older.status.json").path
            )
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: root.appendingPathComponent("codex-babysitter-keep-new.status.json").path
            )
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: root.appendingPathComponent("codex-babysitter-live.status.json").path
            )
        )
        XCTAssertEqual(dry.cap, 2)
    }

    func testEnvironmentWatchDirLocksAndIgnoresUserDefaults() {
        let chosen = root.appendingPathComponent("from-settings", isDirectory: true)
        SentinelSettings.setWatchDirectory(chosen, defaults: defaults)

        let lockedWatch = WatchDirectoryResolution.resolve(
            environment: ["CORTEX_SENTINEL_WATCH_DIR": "/tmp/env-watch-dir"],
            defaults: defaults
        )
        XCTAssertEqual(lockedWatch.logsDirectory.path, "/tmp/env-watch-dir")
        XCTAssertTrue(lockedWatch.source.isLockedByEnvironment)
        XCTAssertEqual(lockedWatch.source, .environmentWatchDir)

        let lockedRepo = WatchDirectoryResolution.resolve(
            environment: ["CORTEX_REPO_ROOT": "/tmp/env-repo"],
            defaults: defaults
        )
        XCTAssertEqual(lockedRepo.logsDirectory.path, "/tmp/env-repo/logs")
        XCTAssertTrue(lockedRepo.source.isLockedByEnvironment)

        let unlocked = WatchDirectoryResolution.resolve(environment: [:], defaults: defaults)
        XCTAssertEqual(unlocked.logsDirectory.path, chosen.path)
        XCTAssertFalse(unlocked.source.isLockedByEnvironment)
        XCTAssertEqual(unlocked.source, .userDefaults)

        let paths = SentinelPaths.discover(
            environment: ["CORTEX_SENTINEL_WATCH_DIR": "/tmp/env-watch-dir"],
            defaults: defaults
        )
        XCTAssertEqual(paths.logsDirectory.path, "/tmp/env-watch-dir")
    }

    @MainActor
    func testStoreWatchDirectoryAppliesImmediatelyUnlessEnvLocked() {
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try? fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: second, withIntermediateDirectories: true)

        let store = SentinelStore(
            defaults: defaults,
            environment: [:]
        )
        XCTAssertFalse(store.isWatchDirectoryLocked)
        store.setWatchDirectory(second)
        XCTAssertEqual(store.paths.logsDirectory.path, second.path)

        let locked = SentinelStore(
            defaults: defaults,
            environment: ["CORTEX_SENTINEL_WATCH_DIR": first.path]
        )
        XCTAssertTrue(locked.isWatchDirectoryLocked)
        locked.setWatchDirectory(second)
        XCTAssertEqual(locked.paths.logsDirectory.path, first.path)
    }

    func testNotificationPlannerFindsCompletedLines() {
        let running = line(slug: "alpha", state: .running)
        let done = line(slug: "alpha", state: .done)
        let prior = [running.id: LineState.running]
        XCTAssertEqual(
            SentinelNotificationPlanner.completedLines(priorStates: prior, lines: [done]).map(\.slug),
            ["alpha"]
        )
        XCTAssertTrue(
            SentinelNotificationPlanner.completedLines(priorStates: prior, lines: [running]).isEmpty
        )
    }

    private func writeStatus(_ slug: String, state: String, ageSeconds: TimeInterval) {
        let url = root.appendingPathComponent("codex-babysitter-\(slug).status.json")
        let json = "{\"slug\":\"\(slug)\",\"state\":\"\(state)\"}"
        fileManager.createFile(atPath: url.path, contents: Data(json.utf8))
        try? fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ageSeconds)],
            ofItemAtPath: url.path
        )
    }

    private func line(slug: String, state: LineState) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-\(slug).status.json"),
            slug: slug,
            workdir: nil,
            branch: nil,
            state: state,
            restarts: 0,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now,
            relay: nil
        )
    }
}
