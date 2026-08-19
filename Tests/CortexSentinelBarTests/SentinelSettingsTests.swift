import AppKit
import Foundation
import SwiftUI
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
        XCTAssertTrue(SentinelSettingsKey.notifyCategoryTaskComplete.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertTrue(SentinelSettingsKey.notifyCategoryTaskProblem.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertTrue(SentinelSettingsKey.notifyCategoryChannelAlert.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertTrue(SentinelSettingsKey.notifyCadence.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertTrue(SentinelSettingsKey.watchDirectory.hasPrefix(SentinelSettingsKey.bundlePrefix + "."))
        XCTAssertEqual(SentinelSettingsCopy.windowTitle, "哨兵设置")
        XCTAssertEqual(SentinelSettingsCopy.notifyGroupTitle, "通知")
        XCTAssertEqual(SentinelSettingsCopy.notifyMasterTitle, "通知我")
        XCTAssertEqual(SentinelSettingsCopy.notifyTaskCompleteTitle, "任务干完了")
        XCTAssertEqual(SentinelSettingsCopy.notifyTaskProblemTitle, "任务出问题了")
        XCTAssertEqual(SentinelSettingsCopy.notifyTaskProblemHint, "卡住、失败、被中止")
        XCTAssertEqual(SentinelSettingsCopy.notifyChannelTitle, "AI 通道出问题或余额不够")
        XCTAssertEqual(SentinelSettingsCopy.notifyChannelHint, "连不上、被熔断、你的额度快用完")
        XCTAssertEqual(SentinelSettingsCopy.notifyCadenceTitle, "什么时候说")
        XCTAssertEqual(SentinelSettingsCopy.notifyCadenceHint, "攒起来的会合成一条，比如「3 个任务干完了」。")
        XCTAssertEqual(SentinelSettingsCopy.notifyCadenceEvery, "每条都弹")
        XCTAssertEqual(SentinelSettingsCopy.notifyCadence1m, "攒 1 分钟一起说")
        XCTAssertEqual(SentinelSettingsCopy.notifyCadence5m, "攒 5 分钟一起说")
        XCTAssertEqual(SentinelSettingsCopy.historyGroupTitle, "历史")
        XCTAssertEqual(SentinelSettingsCopy.loginItemTitle, "开机时自动启动")
        XCTAssertEqual(SentinelSettingsCopy.loginItemManagedHint, "由系统服务托管，改这里没用")
        XCTAssertEqual(SentinelSettingsCopy.historyTitle, "最多留")
        XCTAssertEqual(SentinelSettingsCopy.historyUnit, "条")
        XCTAssertEqual(SentinelSettingsCopy.historyHint, "超出的旧记录会自动清掉，正在跑的任务不会被清。")
        XCTAssertEqual(SentinelSettingsCopy.startupGroupTitle, "启动与文件夹")
        XCTAssertEqual(SentinelTheme.Metrics.settingsCountFieldWidth, 60)
        XCTAssertEqual(SentinelSettingsCopy.watchTitle, "盯这个文件夹")
        XCTAssertEqual(SentinelSettingsCopy.watchChoose, "选择")
        XCTAssertEqual(SentinelSettingsCopy.watchHint, "派工工具把任务状态写在这里，一般不用改。")
        XCTAssertEqual(SentinelSettingsCopy.watchLockedHint, "装的时候定好的，要换得重装。")
        XCTAssertEqual(SentinelSettingsCopy.versionPrefix, "版本")
        XCTAssertEqual(SentinelSettingsCopy.versionDevLabel, "开发版")
        XCTAssertEqual(
            SentinelAppVersion.displayLine(shortVersion: "1.0", bundleVersion: "ede0793"),
            "版本 1.0（ede0793）"
        )
        XCTAssertEqual(
            SentinelAppVersion.displayLine(shortVersion: "1.0", bundleVersion: "adaf73cbcd51"),
            "版本 1.0（adaf73c）"
        )
        XCTAssertEqual(
            SentinelAppVersion.displayLine(shortVersion: "1.0", bundleVersion: "dev"),
            "版本 1.0（开发版）"
        )
        XCTAssertEqual(SettingsPreviewFixture.watchLocked.rawValue, "watch-locked")
    }

    @MainActor
    func testWatchLockedPreviewFixtureLocksDirectoryChoice() {
        XCTAssertTrue(SentinelSettingsModel.preview(fixture: .watchLocked).isWatchLocked)
        XCTAssertFalse(SentinelSettingsModel.preview(fixture: .default).isWatchLocked)
        XCTAssertFalse(SentinelSettingsModel.preview(fixture: .masterOff).isWatchLocked)
    }

    @MainActor
    func testWatchPathDisplayAbbreviatesHomeWithoutChangingStoredPath() {
        let stored = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cortex-sentinel/logs")
        let model = SentinelSettingsModel.preview(fixture: .default)
        model.watchPath = stored
        XCTAssertEqual(model.watchPath, stored)
        XCTAssertEqual(model.watchPathDisplay, "~/.cortex-sentinel/logs")
        XCTAssertEqual(
            model.watchPathDisplay,
            (stored as NSString).abbreviatingWithTildeInPath
        )
    }

    func testSwitchAndCountDefaultsThenRoundTrip() {
        XCTAssertTrue(SentinelSettings.loginItemEnabled(defaults: defaults))
        XCTAssertTrue(SentinelSettings.notifyOnTaskComplete(defaults: defaults))
        let notify = SentinelNotifyPreferences.load(defaults: defaults)
        XCTAssertTrue(notify.masterEnabled)
        XCTAssertTrue(notify.taskCompleteEnabled)
        XCTAssertTrue(notify.taskProblemEnabled)
        XCTAssertTrue(notify.channelAlertEnabled)
        XCTAssertEqual(notify.cadence, .coalesce1m)
        XCTAssertEqual(notify.cadence.title, "攒 1 分钟一起说")
        XCTAssertEqual(
            SentinelSettings.historyRetainCount(defaults: defaults),
            StatusFileRetention.defaultCap
        )
        XCTAssertEqual(StatusFileRetention.defaultCap, 500)

        SentinelSettings.setLoginItemEnabled(false, defaults: defaults)
        SentinelSettings.setNotifyOnTaskComplete(false, defaults: defaults)
        SentinelSettings.setNotifyCategoryEnabled(
            false,
            key: SentinelSettingsKey.notifyCategoryTaskComplete,
            defaults: defaults
        )
        SentinelSettings.setNotifyCadence(.every, defaults: defaults)
        SentinelSettings.setHistoryRetainCount(12, defaults: defaults)

        XCTAssertFalse(SentinelSettings.loginItemEnabled(defaults: defaults))
        XCTAssertFalse(SentinelSettings.notifyOnTaskComplete(defaults: defaults))
        XCTAssertFalse(SentinelSettings.notifyMasterEnabled(defaults: defaults))
        XCTAssertEqual(SentinelSettings.notifyCadence(defaults: defaults), .every)
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

    @MainActor
    func testSettingsViewBodyDoesNotReevaluateWhenStoreStatusPublishes() {
        let store = SentinelStore(defaults: defaults, environment: [:])
        let settingsCounter = SentinelViewBodyCounter()
        let storeCounter = SentinelViewBodyCounter()
        let settingsHost = NSHostingController(
            rootView: SentinelSettingsView(model: store.settingsModel, bodyCounter: settingsCounter)
        )
        let storeHost = NSHostingController(
            rootView: SettingsViewRedrawProbe.storeObservingProbe(store: store, counter: storeCounter)
        )
        settingsHost.view.frame = NSRect(x: 0, y: 0, width: 460, height: 800)
        storeHost.view.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        settingsHost.view.layoutSubtreeIfNeeded()
        storeHost.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let settingsBaseline = settingsCounter.count
        let storeBaseline = storeCounter.count
        XCTAssertGreaterThan(settingsBaseline, 0)
        XCTAssertGreaterThan(storeBaseline, 0)

        for _ in 0..<4 {
            store.emitStatusRefreshPublicationsForTests()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            settingsCounter.count,
            settingsBaseline,
            "store 刷新不应让设置窗 body 再求值"
        )
        XCTAssertGreaterThan(
            storeCounter.count,
            storeBaseline,
            "对照：订阅整个 store 的视图必须随刷新重绘"
        )
    }

    @MainActor
    func testRenderSettingsPNGWritesNonEmptyFile() throws {
        let url = root.appendingPathComponent("settings-default.png")
        try SettingsPNGRenderer.render(fixture: .default, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(
            Array(data.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        )
    }

    @MainActor
    func testRenderWatchLockedSettingsPNGWritesNonEmptyFile() throws {
        let url = root.appendingPathComponent("settings-watch-locked.png")
        try SettingsPNGRenderer.render(fixture: .watchLocked, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(
            Array(data.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        )
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
