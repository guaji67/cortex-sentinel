import XCTest
@testable import CortexSentinelBar

final class V31PolishTests: XCTestCase {
    // MARK: - 历史条格色映射（金标准 UsageMonitor classify：3000ms 边界）

    func testHistoryToneMapping() {
        XCTAssertEqual(
            InputStatusPresentation.historyTone(isOK: true, latencyMilliseconds: 1757),
            .ok
        )
        XCTAssertEqual(
            InputStatusPresentation.historyTone(isOK: true, latencyMilliseconds: 2999),
            .ok
        )
        XCTAssertEqual(
            InputStatusPresentation.historyTone(isOK: true, latencyMilliseconds: 3000),
            .slow
        )
        XCTAssertEqual(
            InputStatusPresentation.historyTone(isOK: true, latencyMilliseconds: nil),
            .missing
        )
        XCTAssertEqual(
            InputStatusPresentation.historyTone(isOK: false, latencyMilliseconds: 100),
            .fail
        )
        XCTAssertEqual(
            InputStatusPresentation.historyTone(isOK: nil, latencyMilliseconds: nil),
            .missing
        )
    }

    // MARK: - 可用率着色阈值（金标准 uptimeColor：95/80 边界）

    func testUptimeSeverityThresholds() {
        XCTAssertEqual(InputStatusPresentation.uptimeSeverity(99.9), .green)
        XCTAssertEqual(InputStatusPresentation.uptimeSeverity(95), .green)
        XCTAssertEqual(InputStatusPresentation.uptimeSeverity(94.99), .amber)
        XCTAssertEqual(InputStatusPresentation.uptimeSeverity(80), .amber)
        XCTAssertEqual(InputStatusPresentation.uptimeSeverity(79.99), .red)
        XCTAssertEqual(InputStatusPresentation.uptimeSeverity(nil), .gray)
    }

    // MARK: - 行状态文字（金标准 statusText：按最新一格判定）

    func testRowStatusText() {
        XCTAssertEqual(InputStatusPresentation.rowStatusText(.ok), "在线")
        XCTAssertEqual(InputStatusPresentation.rowStatusText(.slow), "高延迟")
        XCTAssertEqual(InputStatusPresentation.rowStatusText(.fail), "失败")
        XCTAssertEqual(InputStatusPresentation.rowStatusText(.missing), "缺少数据")
    }

    // MARK: - 格 tooltip（金标准 helpText）

    func testCellHelpText() {
        XCTAssertEqual(
            InputStatusPresentation.cellHelpText(
                InputStatusHistoryPoint(timestamp: 1, isOK: true, latencyMilliseconds: 1757)
            ),
            "正常 1757 ms"
        )
        XCTAssertEqual(
            InputStatusPresentation.cellHelpText(
                InputStatusHistoryPoint(timestamp: 1, isOK: true, latencyMilliseconds: 4200)
            ),
            "高延迟 4200 ms"
        )
        XCTAssertEqual(
            InputStatusPresentation.cellHelpText(
                InputStatusHistoryPoint(
                    timestamp: 1,
                    isOK: false,
                    latencyMilliseconds: nil,
                    error: "HTTP 502"
                )
            ),
            "失败：HTTP 502"
        )
        XCTAssertEqual(
            InputStatusPresentation.cellHelpText(
                InputStatusHistoryPoint(timestamp: 1, isOK: false, latencyMilliseconds: nil)
            ),
            "失败"
        )
        XCTAssertEqual(
            InputStatusPresentation.cellHelpText(.missing),
            "状态未知"
        )
    }

    // MARK: - 历史窗口补齐

    func testPaddedHistoryLeftPadsAndTruncates() {
        let short = [
            InputStatusHistoryPoint(timestamp: 1, isOK: true, latencyMilliseconds: 100),
        ]
        let padded = InputStatusPresentation.paddedHistory(short, windowSize: 4)
        XCTAssertEqual(padded.count, 4)
        XCTAssertEqual(padded[0], .missing)
        XCTAssertEqual(padded[3].timestamp, 1)

        let long = (0..<6).map {
            InputStatusHistoryPoint(timestamp: $0, isOK: true, latencyMilliseconds: 1)
        }
        let truncated = InputStatusPresentation.paddedHistory(long, windowSize: 4)
        XCTAssertEqual(truncated.count, 4)
        XCTAssertEqual(truncated.first?.timestamp, 2)
        XCTAssertEqual(truncated.last?.timestamp, 5)
    }

    // MARK: - 时间格式化

    func testShortTimeSameDayAndCrossDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 24, hour: 10, minute: 0)
        )!
        let sameDay = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 24, hour: 3, minute: 25)
        )!
        let crossDay = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 23, hour: 14, minute: 5)
        )!

        XCTAssertEqual(
            SentinelTimeFormat.shortTime(sameDay, now: now, calendar: calendar),
            "03:25"
        )
        XCTAssertEqual(
            SentinelTimeFormat.shortTime(crossDay, now: now, calendar: calendar),
            "7-23 14:05"
        )
    }

    // MARK: - 最近完成截断 8 条

    func testSplitRecentDisplayCapsAtEight() {
        let presentations = (0..<10).map { index in
            LinePresentation(
                line: LineStatus(
                    sourceFile: URL(fileURLWithPath: "/tmp/line-\(index).json"),
                    slug: "line-\(index)",
                    workdir: nil,
                    branch: nil,
                    state: .done,
                    restarts: 0,
                    rolloutAgeSeconds: nil,
                    updatedAt: nil,
                    sourceModifiedAt: nil,
                    relay: nil
                ),
                registration: nil
            )
        }
        let split = SentinelAggregation.splitRecentDisplay(presentations)
        XCTAssertEqual(split.shown.count, 8)
        XCTAssertEqual(split.overflow.count, 2)
        XCTAssertEqual(split.shown.first?.line.slug, "line-0")
        XCTAssertEqual(split.overflow.first?.line.slug, "line-8")

        let few = Array(presentations.prefix(3))
        let fewSplit = SentinelAggregation.splitRecentDisplay(few)
        XCTAssertEqual(fewSplit.shown.count, 3)
        XCTAssertTrue(fewSplit.overflow.isEmpty)
    }

    // MARK: - 余额行次要文本

    func testBalanceSecondaryTextPriority() {
        XCTAssertEqual(BalanceRowPresentation.shortExpiry("2026-10-19T00:00:00Z"), "26-10-19")
        XCTAssertEqual(BalanceRowPresentation.shortExpiry("2026/10/19"), "26-10-19")
        XCTAssertNil(BalanceRowPresentation.shortExpiry("按量"))

        XCTAssertEqual(BalanceRowPresentation.rateText(from: "按量 0.04 倍率, 最便宜"), "0.04x")
        XCTAssertEqual(BalanceRowPresentation.rateText(from: "按量 0.13 倍率"), "0.13x")
        XCTAssertNil(BalanceRowPresentation.rateText(from: "Pro号池"))

        XCTAssertEqual(
            BalanceRowPresentation.secondaryText(
                expiresAt: "2027-05-19",
                note: "按量 0.05 倍率",
                planName: "CodeX Lite 年度"
            ),
            "27-05-19"
        )
        XCTAssertEqual(
            BalanceRowPresentation.secondaryText(
                expiresAt: nil,
                note: "按量 0.05 倍率",
                planName: "CodeX Lite 年度"
            ),
            "0.05x"
        )
        XCTAssertEqual(
            BalanceRowPresentation.secondaryText(
                expiresAt: nil,
                note: "Pro号池",
                planName: "演示套餐"
            ),
            "演示套餐"
        )
        XCTAssertNil(
            BalanceRowPresentation.secondaryText(
                expiresAt: nil,
                note: nil,
                planName: nil
            )
        )
    }

    // MARK: - 状态接口 history / generated_at 解码

    func testDecodeSnapshotParsesHistoryAndGeneratedAt() throws {
        let json = """
        {
          "all_ok": false,
          "generated_at": 1784836535,
          "services": [
            {
              "model": "gpt-5.6-sol",
              "uptime_pct": 68.33,
              "last": {"ts": 1784836532, "ok": true, "latency_ms": 1757, "error": null},
              "history": [
                {"ts": 1784833017, "ok": false, "latency_ms": null, "error": "HTTP 502"},
                {"ts": 1784836532, "ok": true, "latency_ms": 1757, "error": null}
              ]
            }
          ]
        }
        """
        let readAt = Date(timeIntervalSince1970: 1_784_836_600)
        let snapshot = try XCTUnwrap(
            InputStatusClient.decodeSnapshot(Data(json.utf8), readAt: readAt)
        )
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 1_784_836_535))
        let probe = try XCTUnwrap(snapshot.probes.first)
        XCTAssertEqual(probe.history.count, 2)
        XCTAssertEqual(probe.history[0].isOK, false)
        XCTAssertEqual(probe.history[1].latencyMilliseconds, 1757)
        XCTAssertEqual(probe.sampleCountText, "2/60")
        XCTAssertEqual(
            InputStatusPresentation.historyTone(probe.history[0]),
            .fail
        )
    }
}
