import Foundation
import XCTest
@testable import CortexSentinelBar

/// 心跳年龄显示档位归一化 + 分组发布门（显示等价才拦、像素会变就放）的回归。
/// 背景：活跃线的 rolloutAgeSeconds 每轮磁盘刷新必变，2026-08-24 之前它让
/// 线列表分区每 5 秒失效一次，正落在 Falcon 滑动的手指底下。
@MainActor
final class RolloutDisplayFingerprintTests: XCTestCase {
    /// 所有 fixture 行共用同一个 mtime；显示等价比较的就该只剩心跳档位差异。
    private let fixtureModifiedAt = Date()
    func testBucketRepresentativesFollowDisplayPhrases() {
        // (原始秒数, 期望档位代表值)
        let cases: [(Double, Double)] = [
            (0, 0),
            (12.4, 0),
            (59.9, 0),
            (60, 60),
            (61.2, 60),
            (119.9, 60),
            (120, 120),
            (599.9, 540),
            (600, 600),
            (600.1, 601),
            (1_000, 601),
        ]
        for (raw, expected) in cases {
            let canonical = line(rolloutAge: raw).displayCanonicalized()
            XCTAssertEqual(
                canonical.rolloutAgeSeconds,
                expected,
                "raw=\(raw) 应归到档位 \(expected)，实际 \(String(describing: canonical.rolloutAgeSeconds))"
            )
            // 归一化后显示三件套必须与原值一致：短语、黄灯阈值、遥测存在性。
            XCTAssertEqual(
                LineRowStyle.rolloutPhrase(for: canonical)?.text,
                LineRowStyle.rolloutPhrase(for: line(rolloutAge: raw))?.text,
                "raw=\(raw) 归一化后短语变了"
            )
            XCTAssertEqual(
                canonical.hasStaleRollout,
                line(rolloutAge: raw).hasStaleRollout,
                "raw=\(raw) 归一化后黄灯判定变了"
            )
        }
        XCTAssertNil(line(rolloutAge: nil).displayCanonicalized().rolloutAgeSeconds)
    }

    func testSameBucketJitterIsDisplayEquivalent() {
        let groupsA = SentinelAggregation.lineGroups(
            lines: [line(rolloutAge: 10)],
            registry: .empty
        )
        let groupsB = SentinelAggregation.lineGroups(
            lines: [line(rolloutAge: 15)],
            registry: .empty
        )
        XCTAssertNotEqual(groupsA, groupsB, "原始值不同，逐字段相等必须为假（前提自检）")
        XCTAssertTrue(groupsA.isDisplayEquivalent(to: groupsB), "同档抖动应判显示等价")

        let groupsCrossBucket = SentinelAggregation.lineGroups(
            lines: [line(rolloutAge: 65)],
            registry: .empty
        )
        XCTAssertFalse(
            groupsA.isDisplayEquivalent(to: groupsCrossBucket),
            "跨档（工作中 → 1 分钟没动静）必须判不等价"
        )

        let groupsStateChanged = SentinelAggregation.lineGroups(
            lines: [line(rolloutAge: 10, state: .waitingRelay)],
            registry: .empty
        )
        XCTAssertFalse(
            groupsA.isDisplayEquivalent(to: groupsStateChanged),
            "状态变化必须判不等价"
        )
    }

    func testStoreSkipsGroupPublishForSameBucketJitterButPublishesRealChanges() async {
        let suiteName = "fingerprint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SentinelStore(defaults: defaults, environment: [:])

        applyLines(store, [line(rolloutAge: 10)])
        XCTAssertEqual(store.lineGroups.activeRegistered.count + store.lineGroups.activeUnregistered.count, 1)

        // 同档抖动：lines 本身照常更新，但 lineGroups / boardWindow 不发布。
        let jitterChanges = await countStoreChanges(
            store,
            reading: { [weak store] in
                guard let store else { return }
                _ = store.lineGroups
                _ = store.boardWindow
            }
        ) {
            applyLines(store, [line(rolloutAge: 15)])
        }
        XCTAssertEqual(jitterChanges, 0, "同档抖动不许惊动线列表分区")
        XCTAssertEqual(store.lines.first?.rolloutAgeSeconds, 15, "raw lines 必须照常更新")

        // 跨档：必须发布。
        let bucketChanges = await countStoreChanges(
            store,
            reading: { [weak store] in
                guard let store else { return }
                _ = store.lineGroups
            }
        ) {
            applyLines(store, [line(rolloutAge: 65)])
        }
        XCTAssertEqual(bucketChanges, 1, "跨档（短语变了）必须让分区看到")
    }

    private func applyLines(_ store: SentinelStore, _ lines: [LineStatus]) {
        store.apply(
            lines: lines,
            aio: store.aio,
            otherCodexProcesses: store.otherCodexProcesses,
            lineRegistry: store.lineRegistry,
            inputStatus: store.inputStatus
        )
    }

    private func line(
        rolloutAge: Double?,
        state: LineState = .running
    ) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/fingerprint-alpha.status.json"),
            slug: "fingerprint-alpha",
            workdir: nil,
            branch: nil,
            state: state,
            restarts: 0,
            rolloutAgeSeconds: rolloutAge,
            updatedAt: nil,
            sourceModifiedAt: fixtureModifiedAt,
            relay: nil
        )
    }
}
