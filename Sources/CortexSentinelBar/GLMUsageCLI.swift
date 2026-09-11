import CryptoKit
import Foundation

/// `--glm-usage-json` 命令行：把本机认到的 GLM 钥匙查一轮额度，出一个固定形状的
/// JSON 给程序吃（cortex 派工按 key_sha12 对行，每把钥匙一行）。
/// 这是给程序判阈值用的接口，不是面板显示：percent_used 是已用口径、
/// 直接取 GLMUsageWindow.percentUsed，别按面板的剩余口径改。
/// 输出里只有钥匙指纹（sha256 十六进制小写前 12 位，与 cortex 派工侧同算法），没有钥匙原文。
enum GLMUsageCLI {
    /// 没有钥匙退出码 2（区别于通用失败的 1），有钥匙查完退出码 0；
    /// 单把钥匙查挂不影响退出码（错误落进那一行的 error 字段）。
    static func exitCode(entryCount: Int) -> Int32 {
        entryCount > 0 ? 0 : 2
    }

    /// 钥匙字符串 UTF-8 字节的 sha256 十六进制小写前 12 位。
    static func keySHA12(_ key: String) -> String {
        String(
            SHA256.hash(data: Data(key.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
                .prefix(12)
        )
    }

    /// 固定形状的读数 JSON，键排序固定。行序跟钥匙清单一致，
    /// source / label 来自钥匙行，其余数字来自查回来的账号行。
    static func renderJSON(
        entries: [GLMKeyEntry],
        accounts: [GLMAccountUsage],
        checkedAt: Date
    ) -> Data {
        let usageByKey = Dictionary(
            accounts.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let accountRows: [[String: Any]] = entries.map { entry in
            let account = usageByKey[entry.key]
            return [
                "key_sha12": keySHA12(entry.key),
                "source": optionalJSONString(entry.source),
                "label": entry.label,
                "level": optionalJSONString(account?.level),
                "five_hour": windowJSON(account?.fiveHourWindow),
                "weekly": windowJSON(account?.weeklyWindow),
                "cash_balance": optionalJSONNumber(account?.cashBalance),
                "error": optionalJSONString(account?.errorMessage),
            ] as [String: Any]
        }
        let payload: [String: Any] = [
            "schema": 1,
            "checked_at": timestampText(checkedAt),
            "accounts": accountRows,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else {
            return Data()
        }
        return data
    }

    /// 真正跑：认钥匙 → 没有钥匙直接出空表退出 2；有就查一轮 → 出 JSON 退出 0。
    static func run() async -> Never {
        let entries = GLMKeyStore.resolvedEntries(
            environment: ProcessInfo.processInfo.environment,
            defaults: SentinelSettings.resolvedDefaults()
        )
        guard !entries.isEmpty else {
            write(renderJSON(entries: [], accounts: [], checkedAt: Date()))
            exit(exitCode(entryCount: 0))
        }
        let accounts = await GLMUsageClient().fetchAll(entries: entries)
        write(renderJSON(entries: entries, accounts: accounts, checkedAt: Date()))
        exit(exitCode(entryCount: entries.count))
    }

    private static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func windowJSON(_ window: GLMUsageWindow?) -> Any {
        guard let window else {
            return NSNull()
        }
        return [
            "percent_used": optionalJSONNumber(window.percentUsed),
            "used": optionalJSONNumber(window.usedPoints),
            "total": optionalJSONNumber(window.totalPoints),
            "reset_at_ms": window.resetAt.map { resetAt in
                NSNumber(value: Int64((resetAt.timeIntervalSince1970 * 1000).rounded()))
            } ?? NSNull(),
        ] as [String: Any]
    }

    private static func optionalJSONString(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func optionalJSONNumber(_ value: Double?) -> Any {
        value.map { NSNumber(value: $0) } ?? NSNull()
    }

    private static func timestampText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
