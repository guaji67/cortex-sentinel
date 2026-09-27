import Foundation

// MARK: - 套餐状态取数记录（COR-9931 第 1 条）

/// 每换一份套餐状态（成功或失败）追加一行 JSON，排查「面板上那个冷却是几点取的数」。
/// 落在本 App 自己的日志目录（Application Support 下，跟巡检痕迹同一个目录，
/// 不在被监视、会被清理的 `logs/` 里），按行数轮转不无限长。
/// 一个判定一个读方：这里只记录 cortex 脚本给的读数与本 App 的取数结果，
/// 不写任何钥匙，指纹只写 `key_sha12`。
enum CortexPlanStatusLog {
    static let fileName = "plan-status.log"

    /// 留最近这么多行，超出的从头丢（按大小轮转的行数口径）。
    static let maxLines = 500

    static func logURL(fileManager: FileManager = .default) -> URL {
        LogCleaner.sentinelSupportDirectory(fileManager: fileManager)
            .appendingPathComponent(fileName)
    }

    /// 一行记录（纯函数，测试断它）。
    /// `state` 是这次 apply 之后面板上留着的状态（失败时是沿用的上一份成功结果），
    /// `outcome` 是这次取数的成败。ts 是本机时刻（带本机时区偏移，写明换算用），
    /// fetched_at 是取数时刻（UTC，跟 payload 里的 generated_at 同一口径）。
    static func line(
        at localNow: Date,
        state: CortexPlanStatusDisplayState?,
        outcome: CortexPlanStatusOutcome
    ) -> String {
        let succeeded: Bool
        let errorText: Any
        switch outcome {
        case .success:
            succeeded = true
            errorText = NSNull()
        case let .failure(reason):
            succeeded = false
            errorText = reason
        }
        let planRows: [[String: Any]] = (state?.payload?.plans ?? []).map { plan in
            [
                "id": plan.id,
                "key_sha12": plan.keySHA12,
                "cooldown_until": plan.cooldownUntilText ?? NSNull(),
                "dispatchable": plan.dispatchable.map(NSNumber.init(value:)) ?? NSNull(),
                "skip_code": plan.skipCode ?? NSNull(),
            ]
        }
        let payload: [String: Any] = [
            "ts": timestampText(localNow, timeZone: nil),
            "fetched_at": state?.fetchedAt.map { timestampText($0, timeZone: utcTimeZone) } ?? NSNull(),
            "ok": succeeded,
            "error": errorText,
            "plans": planRows,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\"ts\":\"unencodable\"}"
        }
        return text
    }

    /// 追加一行；超出行数上限从头丢（复用巡检痕迹的行轮转）。
    @discardableResult
    static func append(
        at localNow: Date,
        state: CortexPlanStatusDisplayState?,
        outcome: CortexPlanStatusOutcome,
        fileManager: FileManager = .default,
        url: URL? = nil,
        maxLines: Int = CortexPlanStatusLog.maxLines
    ) -> URL {
        let target = url ?? logURL(fileManager: fileManager)
        LogCleaner.appendInspectLine(
            line(at: localNow, state: state, outcome: outcome),
            to: target,
            maxLines: maxLines,
            fileManager: fileManager
        )
        return target
    }

    private static let utcTimeZone = TimeZone(identifier: "UTC")

    private static func timestampText(_ date: Date, timeZone: TimeZone?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone ?? .current
        return formatter.string(from: date)
    }
}
