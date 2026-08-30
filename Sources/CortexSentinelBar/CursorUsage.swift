import Foundation
import SQLite3

/// Cursor 订阅余额。读本机 Cursor 的登录态（state.vscdb 里的 access/refresh token），
/// 拉两组官方接口：
///   - GetCurrentPeriodUsage → 模式（auto）/ API 两组已用百分比
///   - GetSandUsageStatus    → Grok Bot 周额度的已用百分比（和总池无关，Falcon 2026-08-31 确认）
/// accessToken 会被服务端提前吊销（中转池轮换账号），遇到 401 用 refreshToken 换新再重试；
/// /oauth/token 的 refresh token 可重复使用，Cursor 自己也这么刷（同一个 token 同时存两列）。
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
    let botPercentUsed: Double?
    let botResetDate: Date?
    let checkedAt: Date?
    let stale: Bool
    let errorMessage: String?

    static let empty = CursorUsageSnapshot(
        sourceState: .unconfigured,
        autoPercentUsed: nil,
        apiPercentUsed: nil,
        botPercentUsed: nil,
        botResetDate: nil,
        checkedAt: nil,
        stale: false,
        errorMessage: nil
    )

    var hasDisplayableNumber: Bool {
        autoPercentUsed != nil || apiPercentUsed != nil || botPercentUsed != nil
    }

    func preservingLastSuccess(errorMessage: String) -> CursorUsageSnapshot {
        CursorUsageSnapshot(
            sourceState: sourceState == .unconfigured ? .invalid : sourceState,
            autoPercentUsed: autoPercentUsed,
            apiPercentUsed: apiPercentUsed,
            botPercentUsed: botPercentUsed,
            botResetDate: botResetDate,
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
    static let usageEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    static let sandUsageEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    )!
    static let oauthTokenEndpoint = URL(
        string: "https://api2.cursor.sh/oauth/token"
    )!
    /// Cursor 桌面端内置的 OAuth client id（workbench 里 Prod 档的 authClientId）。
    static let oauthClientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
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

struct CursorAuthTokens: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
}

/// 只读打开 Cursor 的 state.vscdb 取登录态。Cursor 运行中库会忙，
/// 读不到就当未登录处理，不重试拖慢余额刷新。
enum CursorAuthTokenReader {
    static func read(databaseURL: URL = CursorUsageConstants.databaseURL) throws -> CursorAuthTokens {
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
        let sql = """
            SELECT key, value FROM ItemTable
            WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/refreshToken')
            """
        guard SQLITE_OK == sql.withCString({
            sqlite3_prepare_v2(handle, $0, -1, &statement, nil)
        }), let statement else {
            throw CursorUsageReaderError.tokenMissing
        }
        defer {
            sqlite3_finalize(statement)
        }
        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = columnText(statement, 0), let value = columnText(statement, 1) else {
                continue
            }
            values[key] = value
        }
        let accessToken = (values["cursorAuth/accessToken"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw CursorUsageReaderError.tokenMissing
        }
        let refreshToken = (values["cursorAuth/refreshToken"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CursorAuthTokens(
            accessToken: accessToken,
            // 旧登录态可能只有 access 一列；那时无法自助续期，只能报过期。
            refreshToken: refreshToken.isEmpty ? accessToken : refreshToken
        )
    }

    private static func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else {
            return nil
        }
        return String(cString: value)
    }
}

private struct CursorCurrentPeriodUsageResponse: Decodable {
    let planUsage: PlanUsage?

    struct PlanUsage: Decodable {
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }
}

private struct CursorSandUsageResponse: Decodable {
    let usagePercent: Double?
    let nextResetTimestampUtc: String?
    let grokPlanLabel: String?

    /// "2026-09-06T16:02:29.110Z"
    var resetDate: Date? {
        guard let nextResetTimestampUtc else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: nextResetTimestampUtc) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: nextResetTimestampUtc)
    }
}

private struct CursorOAuthTokenResponse: Decodable {
    let accessToken: String?
    let shouldLogout: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case shouldLogout
    }
}

protocol CursorUsageRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CursorUsageRequestLoading {}

struct CursorUsageClient: Sendable {
    private let databaseURL: URL
    private let usageEndpoint: URL
    private let sandUsageEndpoint: URL
    private let oauthTokenEndpoint: URL
    private let oauthClientID: String
    private let requestLoader: any CursorUsageRequestLoading
    private let tokenReader: @Sendable (URL) throws -> CursorAuthTokens

    init(
        databaseURL: URL = CursorUsageConstants.databaseURL,
        usageEndpoint: URL = CursorUsageConstants.usageEndpoint,
        sandUsageEndpoint: URL = CursorUsageConstants.sandUsageEndpoint,
        oauthTokenEndpoint: URL = CursorUsageConstants.oauthTokenEndpoint,
        oauthClientID: String = CursorUsageConstants.oauthClientID,
        requestLoader: any CursorUsageRequestLoading = URLSession.shared,
        tokenReader: @escaping @Sendable (URL) throws -> CursorAuthTokens = {
            try CursorAuthTokenReader.read(databaseURL: $0)
        }
    ) {
        self.databaseURL = databaseURL
        self.usageEndpoint = usageEndpoint
        self.sandUsageEndpoint = sandUsageEndpoint
        self.oauthTokenEndpoint = oauthTokenEndpoint
        self.oauthClientID = oauthClientID
        self.requestLoader = requestLoader
        self.tokenReader = tokenReader
    }

    func fetch() async throws -> CursorUsageSnapshot {
        var tokens = try tokenReader(databaseURL)
        do {
            let snapshot = try await fetchUsage(tokens: tokens)
            return snapshot
        } catch let error as CursorUsageReaderError where error == .unauthorized {
            // accessToken 被服务端吊销（中转池轮换账号时会发生）：用 refreshToken
            // 换一张新的再试一次。refresh token 可重复使用，Cursor 自己也是这么刷的。
            tokens = try await refreshTokens(tokens)
            return try await fetchUsage(tokens: tokens)
        }
    }

    private func fetchUsage(tokens: CursorAuthTokens) async throws -> CursorUsageSnapshot {
        async let plan = fetchUsageJSON(endpoint: usageEndpoint, token: tokens.accessToken)
        async let sand = fetchUsageJSON(endpoint: sandUsageEndpoint, token: tokens.accessToken)
        let planPayload = try await decode(plan, as: CursorCurrentPeriodUsageResponse.self)
        let sandPayload = try await decode(sand, as: CursorSandUsageResponse.self)

        guard let usage = planPayload.planUsage, usage.autoPercentUsed != nil
            || usage.apiPercentUsed != nil || usage.totalPercentUsed != nil
        else {
            throw CursorUsageReaderError.invalidResponse
        }
        return CursorUsageSnapshot(
            sourceState: .available,
            autoPercentUsed: usage.autoPercentUsed,
            apiPercentUsed: usage.apiPercentUsed,
            botPercentUsed: sandPayload.usagePercent,
            botResetDate: sandPayload.resetDate,
            checkedAt: Date(),
            stale: false,
            errorMessage: nil
        )
    }

    private func refreshTokens(_ tokens: CursorAuthTokens) async throws -> CursorAuthTokens {
        var request = URLRequest(url: oauthTokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = CursorUsageConstants.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            """
            {"grant_type":"refresh_token","client_id":"\(oauthClientID)","refresh_token":"\(tokens.refreshToken)"}
            """.utf8
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestLoader.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CursorUsageReaderError.timedOut
        } catch {
            throw CursorUsageReaderError.network
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw CursorUsageReaderError.unauthorized
        }
        guard let payload = try? JSONDecoder().decode(CursorOAuthTokenResponse.self, from: data),
              let accessToken = payload.accessToken,
              !accessToken.isEmpty,
              payload.shouldLogout != true
        else {
            throw CursorUsageReaderError.unauthorized
        }
        return CursorAuthTokens(accessToken: accessToken, refreshToken: tokens.refreshToken)
    }

    private func fetchUsageJSON(endpoint: URL, token: String) async throws -> Data {
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
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CursorUsageReaderError.invalidResponse
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) async throws -> T {
        guard let payload = try? JSONDecoder().decode(T.self, from: data) else {
            throw CursorUsageReaderError.invalidResponse
        }
        return payload
    }
}
