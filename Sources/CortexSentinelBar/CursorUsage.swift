import Foundation
import SQLite3

/// Cursor 订阅余额。读本机 Cursor 的登录态（state.vscdb 里的 accessToken），
/// 再调官方 DashboardService 拿三组用量百分比（模式 / API / 总池）。
/// 布局上跟中转账号不同：三组排成一行，只显示剩余百分比数字。
struct CursorUsageSnapshot: Equatable, Sendable {
    enum SourceState: Equatable, Sendable {
        /// 本机没装 Cursor 或没登录过；余额区不占位。
        case unconfigured
        case available
        case invalid
    }

    let sourceState: SourceState
    /// 各分组「已用」百分比（0-100）；剩余 = 100 - 已用。
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
    let checkedAt: Date?
    let stale: Bool
    let errorMessage: String?

    static let empty = CursorUsageSnapshot(
        sourceState: .unconfigured,
        autoPercentUsed: nil,
        apiPercentUsed: nil,
        totalPercentUsed: nil,
        checkedAt: nil,
        stale: false,
        errorMessage: nil
    )

    var hasDisplayableNumber: Bool {
        autoPercentUsed != nil || apiPercentUsed != nil || totalPercentUsed != nil
    }

    func preservingLastSuccess(errorMessage: String) -> CursorUsageSnapshot {
        CursorUsageSnapshot(
            sourceState: sourceState == .unconfigured ? .invalid : sourceState,
            autoPercentUsed: autoPercentUsed,
            apiPercentUsed: apiPercentUsed,
            totalPercentUsed: totalPercentUsed,
            checkedAt: checkedAt,
            stale: true,
            errorMessage: errorMessage
        )
    }
}

enum CursorUsageReaderError: Error, Equatable {
    case cursorMissing
    case tokenMissing
    case unauthorized
    case timedOut
    case network
    case invalidResponse

    var userMessage: String {
        switch self {
        case .cursorMissing:
            return "本机未安装 Cursor"
        case .tokenMissing:
            return "未检测到 Cursor 登录"
        case .unauthorized:
            return "Cursor 登录已过期"
        case .timedOut:
            return "Cursor 查询超时"
        case .network:
            return "Cursor 接口暂不可达"
        case .invalidResponse:
            return "Cursor 额度格式已变化"
        }
    }
}

enum CursorUsageConstants {
    static let endpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    /// 官方刷新间隔跟 GPT 官方额度保持同一档（余额属于慢变量）。
    static let automaticRefreshInterval: TimeInterval = 10 * 60
    static let manualRefreshThrottle: TimeInterval = 5
    static let requestTimeout: TimeInterval = 15
    /// Cursor 的 state.vscdb 很大（上百万行 agentKv），查询期间给它更长的让路时间。
    static let databaseBusyTimeoutMilliseconds: Int32 = 500
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
}

/// 只读打开 Cursor 的 state.vscdb 取 accessToken。Cursor 运行中库会忙，
/// 读不到就当未登录处理，不重试拖慢余额刷新。
enum CursorAuthTokenReader {
    static func readToken(databaseURL: URL = CursorUsageConstants.databaseURL) throws -> String {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CursorUsageReaderError.cursorMissing
        }
        var handle: OpaquePointer?
        let code = databaseURL.path.withCString { path in
            sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        }
        guard code == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw CursorUsageReaderError.tokenMissing
        }
        defer {
            sqlite3_close_v2(handle)
        }
        sqlite3_busy_timeout(handle, CursorUsageConstants.databaseBusyTimeoutMilliseconds)

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard SQLITE_OK == sql.withCString({
            sqlite3_prepare_v2(handle, $0, -1, &statement, nil)
        }), let statement else {
            throw CursorUsageReaderError.tokenMissing
        }
        defer {
            sqlite3_finalize(statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, 0)
        else {
            throw CursorUsageReaderError.tokenMissing
        }
        let token = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw CursorUsageReaderError.tokenMissing
        }
        return token
    }
}

private struct CursorCurrentPeriodUsageResponse: Decodable {
    let planUsage: PlanUsage?

    struct PlanUsage: Decodable {
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    enum CodingKeys: String, CodingKey {
        case planUsage = "planUsage"
    }
}

protocol CursorUsageRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CursorUsageRequestLoading {}

struct CursorUsageClient: Sendable {
    private let databaseURL: URL
    private let endpoint: URL
    private let requestLoader: any CursorUsageRequestLoading
    private let tokenReader: @Sendable (URL) throws -> String

    init(
        databaseURL: URL = CursorUsageConstants.databaseURL,
        endpoint: URL = CursorUsageConstants.endpoint,
        requestLoader: any CursorUsageRequestLoading = URLSession.shared,
        tokenReader: @escaping @Sendable (URL) throws -> String = { try CursorAuthTokenReader.readToken(databaseURL: $0) }
    ) {
        self.databaseURL = databaseURL
        self.endpoint = endpoint
        self.requestLoader = requestLoader
        self.tokenReader = tokenReader
    }

    func fetch() async throws -> CursorUsageSnapshot {
        let token: String
        do {
            token = try tokenReader(databaseURL)
        } catch let error as CursorUsageReaderError {
            throw error
        } catch {
            throw CursorUsageReaderError.tokenMissing
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = CursorUsageConstants.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestLoader.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CursorUsageReaderError.timedOut
        } catch {
            throw CursorUsageReaderError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CursorUsageReaderError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CursorUsageReaderError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode),
              let payload = try? JSONDecoder().decode(
                  CursorCurrentPeriodUsageResponse.self,
                  from: data
              ),
              let usage = payload.planUsage
        else {
            throw CursorUsageReaderError.invalidResponse
        }
        return CursorUsageSnapshot(
            sourceState: .available,
            autoPercentUsed: usage.autoPercentUsed,
            apiPercentUsed: usage.apiPercentUsed,
            totalPercentUsed: usage.totalPercentUsed,
            checkedAt: Date(),
            stale: false,
            errorMessage: nil
        )
    }
}
