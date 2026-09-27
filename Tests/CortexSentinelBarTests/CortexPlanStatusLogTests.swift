import XCTest
@testable import CortexSentinelBar

/// 套餐状态取数记录（COR-9931 第 1 条）：每换一份状态（成功或失败）追加一行 JSON，
/// 落本 App 自己的日志目录、按行数轮转；只写套餐 id 与钥匙指纹，不写任何钥匙。
final class CortexPlanStatusLogTests: XCTestCase {
    /// 有冷却、有拦人理由的套餐样例（值都是假的）。
    private let payloadJSON: Data = """
    {
      "schema": 1,
      "generated_at": "2026-09-11T01:30:00Z",
      "free_window": {"active": false},
      "plans": [
        {
          "id": "plan-a",
          "label": "Sample 套餐",
          "key_sha12": "0123456789ab",
          "max_parallel": 5,
          "running": 2,
          "executors": [],
          "dispatchable": false,
          "skip_code": "weekly_exhausted",
          "skip_text_zh": "周额度用完",
          "cooldown_until": "2026-09-11T02:00:00Z",
          "usage_known": true
        }
      ],
      "errors": []
    }
    """.data(using: .utf8)!

    private func samplePayload() throws -> CortexPlanStatusPayload {
        try JSONDecoder().decode(CortexPlanStatusPayload.self, from: payloadJSON)
    }

    private func isoUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func parsed(_ line: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// 成功一次：本机时刻、取数时刻、各号读数都记下，指纹只写 key_sha12。
    func testSuccessLineRecordsFetchTimeAndPlanReadings() throws {
        let localNow = Date(timeIntervalSince1970: 1_760_000_123)
        let fetchedAt = localNow.addingTimeInterval(-9)
        let payload = try samplePayload()
        let line = CortexPlanStatusLog.line(
            at: localNow,
            state: CortexPlanStatusDisplayState(payload: payload, fetchedAt: fetchedAt, failureText: nil),
            outcome: .success(payload)
        )

        let object = try parsed(line)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertTrue(object["error"] is NSNull, "成功没有失败原因")
        // 本机时刻带时区偏移，解析回来还是同一个绝对时刻。
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let ts = try XCTUnwrap(object["ts"] as? String)
        let parsedTs = try XCTUnwrap(parser.date(from: ts))
        XCTAssertEqual(parsedTs.timeIntervalSince1970, localNow.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(object["fetched_at"] as? String, isoUTC(fetchedAt))

        let plans = try XCTUnwrap(object["plans"] as? [[String: Any]])
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0]["id"] as? String, "plan-a")
        XCTAssertEqual(plans[0]["key_sha12"] as? String, "0123456789ab")
        XCTAssertEqual(plans[0]["cooldown_until"] as? String, "2026-09-11T02:00:00Z")
        XCTAssertEqual(plans[0]["dispatchable"] as? Bool, false)
        XCTAssertEqual(plans[0]["skip_code"] as? String, "weekly_exhausted")
        // 除了指纹，任何地方都不写钥匙（本样例的假钥匙串不该出现）。
        XCTAssertFalse(line.contains("0123456789ab-key"))
    }

    /// 失败一次：记失败原因与沿用的上一份成功结果（取数时刻还是上次的）。
    func testFailureLineKeepsReasonAndCarriedPlans() throws {
        let localNow = Date(timeIntervalSince1970: 1_760_000_999)
        let fetchedAt = localNow.addingTimeInterval(-600)
        let payload = try samplePayload()
        let reason = "脚本清单缺一个文件"
        let line = CortexPlanStatusLog.line(
            at: localNow,
            state: CortexPlanStatusDisplayState(payload: payload, fetchedAt: fetchedAt, failureText: reason),
            outcome: .failure(reason: reason)
        )

        let object = try parsed(line)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, reason)
        // 取数时刻是上一次成功的时刻，不是这次失败的时刻。
        XCTAssertEqual(object["fetched_at"] as? String, isoUTC(fetchedAt))
        let plans = try XCTUnwrap(object["plans"] as? [[String: Any]])
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0]["id"] as? String, "plan-a")
    }

    /// 从没成功过也记一行：没有取数时刻、没有套餐。
    func testFailureWithoutAnySuccessStillLogsALine() throws {
        let line = CortexPlanStatusLog.line(
            at: Date(timeIntervalSince1970: 1_760_000_001),
            state: CortexPlanStatusDisplayState(payload: nil, fetchedAt: nil, failureText: "找不到 cortex 仓"),
            outcome: .failure(reason: "找不到 cortex 仓")
        )
        let object = try parsed(line)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue(object["fetched_at"] is NSNull)
        XCTAssertEqual((object["plans"] as? [Any])?.count, 0)
    }

    /// 按行数轮转：留最近 N 行，不无限长，每行都是能解析的 JSON。
    func testAppendRotatesByLineCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-status-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try samplePayload()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        for index in 0..<8 {
            CortexPlanStatusLog.append(
                at: now.addingTimeInterval(TimeInterval(index)),
                state: CortexPlanStatusDisplayState(payload: payload, fetchedAt: now, failureText: nil),
                outcome: .success(payload),
                url: url,
                maxLines: 5
            )
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5, "只留最近 5 行")
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let timestamps: [TimeInterval] = try lines.map { line in
            let stamp = try XCTUnwrap(try parsed(line)["ts"] as? String)
            return try XCTUnwrap(parser.date(from: stamp)).timeIntervalSince1970
        }
        // 留下的是最后 5 次写入（下标 3..7），最早 3 次被丢掉。
        XCTAssertEqual(
            timestamps,
            (3..<8).map { now.timeIntervalSince1970 + Double($0) }
        )
    }

    /// 落点在本 App 自己的日志目录：跟巡检痕迹同一个目录，不在被监视的 logs/。
    func testLogLivesInAppSupportDirectory() {
        let url = CortexPlanStatusLog.logURL(fileManager: .default)
        XCTAssertEqual(url.lastPathComponent, "plan-status.log")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "CortexSentinel")
    }
}
