import Foundation
import XCTest
@testable import CortexSentinelBar

final class SentinelNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testSingleCompletedLineKeepsOriginalWording() {
        let coalescer = SentinelNotificationCoalescer()
        let prefs = prefs(cadence: .coalesce1m)
        let running = [line(slug: "alpha", state: .running)]
        let done = [line(slug: "alpha", state: .done)]

        XCTAssertTrue(
            coalescer.observe(
                lines: running,
                aio: .unconfigured,
                registry: registry(["alpha": "中文甲"]),
                preferences: prefs,
                now: now
            ).isEmpty
        )
        XCTAssertTrue(
            coalescer.observe(
                lines: done,
                aio: .unconfigured,
                registry: registry(["alpha": "中文甲"]),
                preferences: prefs,
                now: now
            ).isEmpty
        )

        let flushed = coalescer.observe(
            lines: done,
            aio: .unconfigured,
            registry: registry(["alpha": "中文甲"]),
            preferences: prefs,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].title, "任务结束")
        XCTAssertEqual(flushed[0].body, "中文甲 已完成")
        XCTAssertFalse(flushed[0].body.contains("条线干完了"))
    }

    func testMultipleCompletedLinesMergeAfterWindow() {
        let coalescer = SentinelNotificationCoalescer()
        let prefs = prefs(cadence: .coalesce1m)
        let running = [
            line(slug: "alpha", state: .running),
            line(slug: "beta", state: .running),
            line(slug: "gamma", state: .running),
        ]
        let done = [
            line(slug: "alpha", state: .done),
            line(slug: "beta", state: .done),
            line(slug: "gamma", state: .done),
        ]

        _ = coalescer.observe(
            lines: running,
            aio: .unconfigured,
            registry: registry(["alpha": "甲", "beta": "乙", "gamma": "丙"]),
            preferences: prefs,
            now: now
        )
        XCTAssertTrue(
            coalescer.observe(
                lines: done,
                aio: .unconfigured,
                registry: registry(["alpha": "甲", "beta": "乙", "gamma": "丙"]),
                preferences: prefs,
                now: now
            ).isEmpty
        )

        let flushed = coalescer.observe(
            lines: done,
            aio: .unconfigured,
            registry: .empty,
            preferences: prefs,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(flushed.map(\.body), ["3 条线干完了"])
        XCTAssertEqual(flushed.map(\.title), ["任务结束"])
    }

    func testCrossCategoryEventsDoNotMerge() {
        let coalescer = SentinelNotificationCoalescer()
        let prefs = prefs(cadence: .coalesce1m)
        let running = [
            line(slug: "alpha", state: .running),
            line(slug: "beta", state: .running),
        ]
        let mixed = [
            line(slug: "alpha", state: .done),
            line(slug: "beta", state: .help),
        ]

        _ = coalescer.observe(
            lines: running,
            aio: .unconfigured,
            registry: registry(["alpha": "甲", "beta": "乙"]),
            preferences: prefs,
            now: now
        )
        XCTAssertTrue(
            coalescer.observe(
                lines: mixed,
                aio: .unconfigured,
                registry: registry(["alpha": "甲", "beta": "乙"]),
                preferences: prefs,
                now: now
            ).isEmpty
        )

        let flushed = coalescer.observe(
            lines: mixed,
            aio: .unconfigured,
            registry: registry(["alpha": "甲", "beta": "乙"]),
            preferences: prefs,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(Set(flushed.map(\.category)), [.taskComplete, .taskProblem])
        XCTAssertEqual(flushed.count, 2)
        XCTAssertEqual(
            flushed.first { $0.category == .taskComplete }?.body,
            "甲 已完成"
        )
        XCTAssertEqual(
            flushed.first { $0.category == .taskProblem }?.body,
            "乙 进入 求助"
        )
    }

    func testMasterSwitchOffSendsNothing() {
        let coalescer = SentinelNotificationCoalescer()
        var preferences = prefs(cadence: .every)
        preferences.masterEnabled = false
        let running = [line(slug: "alpha", state: .running)]
        let done = [line(slug: "alpha", state: .done)]

        _ = coalescer.observe(
            lines: running,
            aio: .unconfigured,
            registry: .empty,
            preferences: preferences,
            now: now
        )
        let deliveries = coalescer.observe(
            lines: done,
            aio: .unconfigured,
            registry: .empty,
            preferences: preferences,
            now: now
        )
        XCTAssertTrue(deliveries.isEmpty)
    }

    private func prefs(cadence: SentinelNotifyCadence) -> SentinelNotifyPreferences {
        SentinelNotifyPreferences(
            masterEnabled: true,
            taskCompleteEnabled: true,
            taskProblemEnabled: true,
            channelAlertEnabled: true,
            cadence: cadence
        )
    }

    private func registry(_ labels: [String: String]) -> CodexLineRegistry {
        let items = labels.map { slug, label in
            """
            {"slug":"\(slug)","label_zh":"\(label)","dispatcher_zh":"测","registered_at":1787000000}
            """
        }
        let data = Data("[\(items.joined(separator: ","))]".utf8)
        return CodexLineRegistryReader.decode(data) ?? .empty
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
