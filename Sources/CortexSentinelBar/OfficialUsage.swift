import Foundation

struct CodexOAuthCredentials: Equatable, Sendable {
    let accessToken: String
    let accountID: String?
}

enum CodexAuthReaderError: Error, Equatable {
    case missing
    case invalid
}

enum CodexAuthReader {
    static func read(at url: URL) throws -> CodexOAuthCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexAuthReaderError.missing
        }
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = payload["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexAuthReaderError.invalid
        }
        let accountID = (tokens["account_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexOAuthCredentials(
            accessToken: accessToken,
            accountID: accountID?.isEmpty == false ? accountID : nil
        )
    }
}

struct OfficialUsageWindow: Decodable, Equatable, Sendable {
    let usedPercentage: Double?
    let limitWindowSeconds: Double?
    let resetAt: Double?
    let resetAfterSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
        case resetAfterSeconds = "reset_after_seconds"
    }

    var remainingPercentage: Double? {
        usedPercentage.map { min(100, max(0, 100 - $0)) }
    }

    func resetDate(relativeTo checkedAt: Date) -> Date? {
        if let resetAt {
            return Date(timeIntervalSince1970: resetAt)
        }
        return resetAfterSeconds.map { checkedAt.addingTimeInterval($0) }
    }
}

private struct OfficialUsageResponse: Decodable {
    let planType: String?
    let email: String?
    let rateLimit: OfficialUsageRateLimit

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case email
        case rateLimit = "rate_limit"
    }
}

private struct OfficialUsageRateLimit: Decodable {
    let primaryWindow: OfficialUsageWindow?
    let secondaryWindow: OfficialUsageWindow?
    let weeklyWindow: OfficialUsageWindow?
    let fiveHourWindow: OfficialUsageWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
        case weeklyWindow = "weekly_window"
        case fiveHourWindow = "five_hour_window"
    }

    private var inferredWindows: [OfficialUsageWindow] {
        [primaryWindow, secondaryWindow].compactMap { $0 }
    }

    var resolvedWeeklyWindow: OfficialUsageWindow? {
        weeklyWindow ?? inferredWindows.first {
            ($0.limitWindowSeconds ?? 0) >= 6 * 24 * 60 * 60
        }
    }

    var resolvedFiveHourWindow: OfficialUsageWindow? {
        if let fiveHourWindow {
            return fiveHourWindow
        }
        return inferredWindows.first {
            guard let seconds = $0.limitWindowSeconds else {
                return false
            }
            return seconds >= 4 * 60 * 60 && seconds < 6 * 24 * 60 * 60
        }
    }
}

struct OfficialUsageSnapshot: Equatable, Sendable {
    let planType: String?
    let email: String?
    let weeklyWindow: OfficialUsageWindow?
    let fiveHourWindow: OfficialUsageWindow?
    let checkedAt: Date?
    let stale: Bool
    let errorMessage: String?
    let refreshFailedAt: Date?

    static let empty = OfficialUsageSnapshot(
        planType: nil,
        email: nil,
        weeklyWindow: nil,
        fiveHourWindow: nil,
        checkedAt: nil,
        stale: false,
        errorMessage: nil,
        refreshFailedAt: nil
    )

    var weeklyRemainingPercentage: Double? {
        weeklyWindow?.remainingPercentage
    }

    var weeklyResetDate: Date? {
        guard let checkedAt else {
            return nil
        }
        return weeklyWindow?.resetDate(relativeTo: checkedAt)
    }

    var planDisplayName: String? {
        guard let planType = planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !planType.isEmpty
        else {
            return nil
        }
        let uppercased = planType.uppercased()
        return uppercased.hasPrefix("GPT ") ? uppercased : "GPT \(uppercased)"
    }

    var accountLabel: String {
        guard let email,
              let localPart = email.split(separator: "@", maxSplits: 1).first,
              !localPart.isEmpty
        else {
            return "Codex 登录号"
        }
        return "Codex 登录号：\(localPart)"
    }

    func preservingLastSuccess(errorMessage: String, failedAt: Date) -> OfficialUsageSnapshot {
        OfficialUsageSnapshot(
            planType: planType,
            email: email,
            weeklyWindow: weeklyWindow,
            fiveHourWindow: fiveHourWindow,
            checkedAt: checkedAt,
            stale: true,
            errorMessage: errorMessage,
            refreshFailedAt: failedAt
        )
    }
}

protocol OfficialUsageRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OfficialUsageRequestLoading {}

enum OfficialUsageClientError: Error, Equatable {
    case authMissing
    case authInvalid
    case unauthorized
    case timedOut
    case network
    case invalidResponse

    var userMessage: String {
        switch self {
        case .authMissing:
            return "未检测到 Codex 登录"
        case .authInvalid:
            return "Codex 登录态无效"
        case .unauthorized:
            return "Codex 登录已过期"
        case .timedOut:
            return "GPT 官方查询超时"
        case .network:
            return "GPT 官方接口暂不可达"
        case .invalidResponse:
            return "GPT 官方额度格式已变化"
        }
    }
}

struct OfficialUsageClient: Sendable {
    private let authURL: URL
    private let endpoint: URL
    private let requestLoader: any OfficialUsageRequestLoading
    private let now: @Sendable () -> Date

    init(
        authURL: URL,
        endpoint: URL = OfficialUsageConstants.endpoint,
        requestLoader: any OfficialUsageRequestLoading = URLSession.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authURL = authURL
        self.endpoint = endpoint
        self.requestLoader = requestLoader
        self.now = now
    }

    func fetch() async throws -> OfficialUsageSnapshot {
        let credentials: CodexOAuthCredentials
        do {
            credentials = try CodexAuthReader.read(at: authURL)
        } catch CodexAuthReaderError.missing {
            throw OfficialUsageClientError.authMissing
        } catch {
            throw OfficialUsageClientError.authInvalid
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = OfficialUsageConstants.requestTimeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue("CortexSentinel/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestLoader.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OfficialUsageClientError.timedOut
        } catch {
            throw OfficialUsageClientError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OfficialUsageClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw OfficialUsageClientError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode),
              let payload = try? JSONDecoder().decode(OfficialUsageResponse.self, from: data)
        else {
            throw OfficialUsageClientError.invalidResponse
        }

        let checkedAt = now()
        let weeklyWindow = payload.rateLimit.resolvedWeeklyWindow
        guard weeklyWindow?.usedPercentage != nil else {
            throw OfficialUsageClientError.invalidResponse
        }
        return OfficialUsageSnapshot(
            planType: payload.planType,
            email: payload.email,
            weeklyWindow: weeklyWindow,
            fiveHourWindow: payload.rateLimit.resolvedFiveHourWindow,
            checkedAt: checkedAt,
            stale: false,
            errorMessage: nil,
            refreshFailedAt: nil
        )
    }
}

enum OfficialUsageRefreshReason {
    case startup
    case automatic
    case manual
}

enum OfficialUsagePresentation {
    static func metadata(
        planDisplayName: String?,
        checkedAt: Date?,
        stale: Bool
    ) -> String? {
        var parts: [String] = []
        if let planDisplayName {
            parts.append(planDisplayName)
        }
        if let checkedAt {
            parts.append("\(SentinelTimeFormat.clockTime(checkedAt)) 更新")
        }
        if stale {
            parts.append("已过期")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum OfficialUsageRefreshPolicy {
    static func shouldStart(
        reason: OfficialUsageRefreshReason,
        lastAttemptAt: Date?,
        isInFlight: Bool,
        now: Date
    ) -> Bool {
        guard !isInFlight else {
            return false
        }
        guard let lastAttemptAt else {
            return true
        }
        let minimumInterval: TimeInterval = reason == .automatic
            ? OfficialUsageConstants.automaticRefreshInterval
            : OfficialUsageConstants.manualRefreshThrottle
        return now.timeIntervalSince(lastAttemptAt) >= minimumInterval
    }
}

enum OfficialUsageConstants {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let automaticRefreshInterval: TimeInterval = 10 * 60
    static let manualRefreshThrottle: TimeInterval = 5
    static let requestTimeout: TimeInterval = 15
}
