import Foundation

enum InputStatusConstants {
    static let monitoredModels = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.5"]
    static let defaultEndpoint = URL(string: "https://status.input.im/api/status")!
    static let refreshInterval: TimeInterval = 60
    static let backgroundRefreshInterval: TimeInterval = 5 * 60
    static let requestTimeout: TimeInterval = 15
    static let staleInterval: TimeInterval = 10 * 60
    static let historyWindowSize = 60
    /// 金标准 UsageMonitor ServiceStatusCellKind.classify：高延迟阈值 3000ms。
    static let slowLatencyMilliseconds = 3000
}

enum InputStatusRefreshPolicy {
    static func automaticInterval(panelPresented: Bool) -> TimeInterval {
        panelPresented
            ? InputStatusConstants.refreshInterval
            : InputStatusConstants.backgroundRefreshInterval
    }
}

struct InputStatusHistoryPoint: Equatable, Sendable {
    let timestamp: Int?
    let isOK: Bool?
    let latencyMilliseconds: Int?
    let error: String?

    init(
        timestamp: Int?,
        isOK: Bool?,
        latencyMilliseconds: Int?,
        error: String? = nil
    ) {
        self.timestamp = timestamp
        self.isOK = isOK
        self.latencyMilliseconds = latencyMilliseconds
        self.error = error
    }

    static let missing = InputStatusHistoryPoint(
        timestamp: nil,
        isOK: nil,
        latencyMilliseconds: nil,
        error: nil
    )
}

enum InputHistoryTone: Equatable, Sendable {
    case ok
    case slow
    case fail
    case missing
}

enum InputStatusPresentation {
    /// 金标准 UsageMonitor ServiceStatusCellKind.classify 原样照搬：
    /// 缺样本或 ok 为空 → 灰；ok=false → 红；ok=true 但无延迟 → 灰；延迟 >=3000ms → 高延迟；否则绿。
    static func historyTone(
        isOK: Bool?,
        latencyMilliseconds: Int?
    ) -> InputHistoryTone {
        guard let isOK else {
            return .missing
        }
        guard isOK else {
            return .fail
        }
        guard let latency = latencyMilliseconds else {
            return .missing
        }
        return latency >= InputStatusConstants.slowLatencyMilliseconds ? .slow : .ok
    }

    static func historyTone(_ point: InputStatusHistoryPoint) -> InputHistoryTone {
        historyTone(
            isOK: point.isOK,
            latencyMilliseconds: point.latencyMilliseconds
        )
    }

    /// 状态栏圆点与面板行圆点共用的唯一口径（v3.2 第 1 点）：
    /// 过期/未知 → 灰(missing)；否则取最新一格 tone（含高延迟橙档 .slow）。
    /// 状态栏原先只按 InputProbeState(connected/disconnected/stale) 上色、丢了高延迟橙档，
    /// 导致面板显橙、状态栏仍绿。统一走这里后两处一致。
    static func indicatorTone(for display: InputStatusDisplayProbe) -> InputHistoryTone {
        switch display.state {
        case .stale, .unknown:
            return .missing
        case .connected, .disconnected:
            let latest = display.probe.history.last
                ?? InputStatusHistoryPoint(
                    timestamp: nil,
                    isOK: display.probe.isOK,
                    latencyMilliseconds: display.probe.latencyMilliseconds
                )
            return historyTone(latest)
        }
    }

    /// 金标准 UsageMonitor MenuBarView.uptimeColor：nil 灰、>=95 绿、>=80 橙、<80 红。
    static func uptimeSeverity(_ percentage: Double?) -> SentinelSeverity {
        guard let percentage else {
            return .gray
        }
        if percentage >= 95 {
            return .green
        }
        if percentage >= 80 {
            return .amber
        }
        return .red
    }

    /// 金标准 UsageMonitor ServiceStatusTimelineRow.statusText：按最新一格判定。
    static func rowStatusText(_ tone: InputHistoryTone) -> String {
        switch tone {
        case .ok:
            return "在线"
        case .slow:
            return "高延迟"
        case .fail:
            return "失败"
        case .missing:
            return "缺少数据"
        }
    }

    /// 金标准 UsageMonitor ServiceStatusDisplayCell.helpText。
    static func cellHelpText(_ point: InputStatusHistoryPoint) -> String {
        switch historyTone(point) {
        case .ok:
            return "正常 \(point.latencyMilliseconds.map { "\($0) ms" } ?? "")"
                .trimmingCharacters(in: .whitespaces)
        case .slow:
            return "高延迟 \(point.latencyMilliseconds.map { "\($0) ms" } ?? "")"
                .trimmingCharacters(in: .whitespaces)
        case .fail:
            if let error = point.error, !error.isEmpty {
                return "失败：\(error)"
            }
            return "失败"
        case .missing:
            return "状态未知"
        }
    }

    /// 左侧补灰对齐 60 格窗口（最右=最新）。
    static func paddedHistory(
        _ history: [InputStatusHistoryPoint],
        windowSize: Int = InputStatusConstants.historyWindowSize
    ) -> [InputStatusHistoryPoint] {
        if history.count >= windowSize {
            return Array(history.suffix(windowSize))
        }
        return Array(
            repeating: .missing,
            count: windowSize - history.count
        ) + history
    }
}

enum InputProbeState: Equatable, Sendable {
    case connected
    case disconnected
    case stale
    case unknown

    var displayName: String {
        switch self {
        case .connected:
            return "在线"
        case .disconnected:
            return "断开"
        case .stale:
            return "数据过期"
        case .unknown:
            return "暂无数据"
        }
    }
}

struct InputStatusProbe: Equatable, Identifiable, Sendable {
    let model: String
    let uptimePercentage: Double?
    let isOK: Bool?
    let latencyMilliseconds: Int?
    let history: [InputStatusHistoryPoint]

    init(
        model: String,
        uptimePercentage: Double?,
        isOK: Bool?,
        latencyMilliseconds: Int?,
        history: [InputStatusHistoryPoint] = []
    ) {
        self.model = model
        self.uptimePercentage = uptimePercentage
        self.isOK = isOK
        self.latencyMilliseconds = latencyMilliseconds
        self.history = history
    }

    var id: String {
        model
    }

    var sampleCountText: String {
        "\(min(history.count, InputStatusConstants.historyWindowSize))/\(InputStatusConstants.historyWindowSize)"
    }
}

struct InputStatusDisplayProbe: Equatable, Identifiable, Sendable {
    let probe: InputStatusProbe
    let state: InputProbeState

    var id: String {
        probe.id
    }
}

struct InputStatusSnapshot: Equatable, Sendable {
    let allOK: Bool?
    let probes: [InputStatusProbe]
    let readAt: Date?
    let generatedAt: Date?
    let errorMessage: String?

    init(
        allOK: Bool?,
        probes: [InputStatusProbe],
        readAt: Date?,
        generatedAt: Date? = nil,
        errorMessage: String?
    ) {
        self.allOK = allOK
        self.probes = probes
        self.readAt = readAt
        self.generatedAt = generatedAt
        self.errorMessage = errorMessage
    }

    static let empty = InputStatusSnapshot(
        allOK: nil,
        probes: [],
        readAt: nil,
        generatedAt: nil,
        errorMessage: nil
    )

    func state(for model: String, now: Date = Date()) -> InputProbeState {
        guard let readAt else {
            return .unknown
        }
        guard now.timeIntervalSince(readAt) <= InputStatusConstants.staleInterval else {
            return .stale
        }
        guard let isOK = probes.first(where: { $0.model == model })?.isOK else {
            return .unknown
        }
        return isOK ? .connected : .disconnected
    }

    func displayProbes(now: Date = Date()) -> [InputStatusDisplayProbe] {
        InputStatusConstants.monitoredModels.map { model in
            let probe = probes.first(where: { $0.model == model })
                ?? InputStatusProbe(
                    model: model,
                    uptimePercentage: nil,
                    isOK: nil,
                    latencyMilliseconds: nil
                )
            return InputStatusDisplayProbe(
                probe: probe,
                state: state(for: model, now: now)
            )
        }
    }

    func hasWarning(now: Date = Date()) -> Bool {
        displayProbes(now: now).contains { $0.state == .disconnected }
    }

    func preservingData(withError message: String) -> InputStatusSnapshot {
        InputStatusSnapshot(
            allOK: allOK,
            probes: probes,
            readAt: readAt,
            generatedAt: generatedAt,
            errorMessage: message
        )
    }
}

protocol InputStatusRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: InputStatusRequestLoading {}

enum InputStatusClientError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case decoding
    case network

    var userMessage: String {
        switch self {
        case .invalidResponse, .decoding:
            return "服务状态格式异常"
        case let .httpStatus(status):
            return "服务状态接口返回 HTTP \(status)"
        case .network:
            return "服务状态请求失败"
        }
    }
}

struct InputStatusClient: Sendable {
    private let endpoint: URL
    private let requestLoader: any InputStatusRequestLoading

    init(
        endpoint: URL = InputStatusConstants.defaultEndpoint,
        requestLoader: any InputStatusRequestLoading = URLSession.shared
    ) {
        self.endpoint = endpoint
        self.requestLoader = requestLoader
    }

    func fetch(now: Date = Date()) async throws -> InputStatusSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = InputStatusConstants.requestTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestLoader.data(for: request)
        } catch {
            throw InputStatusClientError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InputStatusClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw InputStatusClientError.httpStatus(httpResponse.statusCode)
        }
        guard let snapshot = Self.decodeSnapshot(data, readAt: now) else {
            throw InputStatusClientError.decoding
        }
        return snapshot
    }

    static func decodeSnapshot(_ data: Data, readAt: Date) -> InputStatusSnapshot? {
        guard let response = try? JSONDecoder().decode(InputStatusResponse.self, from: data) else {
            return nil
        }
        return InputStatusSnapshot(
            allOK: response.allOK,
            probes: response.services.map { service in
                InputStatusProbe(
                    model: service.model,
                    uptimePercentage: service.uptimePercentage,
                    isOK: service.last?.isOK,
                    latencyMilliseconds: service.last?.latencyMilliseconds,
                    history: (service.history ?? []).map { point in
                        InputStatusHistoryPoint(
                            timestamp: point.timestamp,
                            isOK: point.isOK,
                            latencyMilliseconds: point.latencyMilliseconds,
                            error: point.error
                        )
                    }
                )
            },
            readAt: readAt,
            generatedAt: response.generatedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            errorMessage: nil
        )
    }
}

private struct InputStatusResponse: Decodable {
    let allOK: Bool
    let generatedAt: Int?
    let services: [InputStatusService]

    enum CodingKeys: String, CodingKey {
        case allOK = "all_ok"
        case generatedAt = "generated_at"
        case services
    }
}

private struct InputStatusService: Decodable {
    let model: String
    let uptimePercentage: Double?
    let last: InputStatusLastProbe?
    let history: [InputStatusHistoryPointPayload]?

    enum CodingKeys: String, CodingKey {
        case model
        case uptimePercentage = "uptime_pct"
        case last
        case history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        uptimePercentage = try container.decodeFlexibleDoubleIfPresent(forKey: .uptimePercentage)
        last = try container.decodeIfPresent(InputStatusLastProbe.self, forKey: .last)
        history = try container.decodeIfPresent(
            [InputStatusHistoryPointPayload].self,
            forKey: .history
        )
    }
}

private struct InputStatusHistoryPointPayload: Decodable {
    let timestamp: Int?
    let isOK: Bool?
    let latencyMilliseconds: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case isOK = "ok"
        case latencyMilliseconds = "latency_ms"
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeFlexibleIntIfPresent(forKey: .timestamp)
        isOK = try container.decodeIfPresent(Bool.self, forKey: .isOK)
        latencyMilliseconds = try container.decodeFlexibleIntIfPresent(forKey: .latencyMilliseconds)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

private struct InputStatusLastProbe: Decodable {
    let isOK: Bool?
    let latencyMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case isOK = "ok"
        case latencyMilliseconds = "latency_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOK = try container.decodeIfPresent(Bool.self, forKey: .isOK)
        latencyMilliseconds = try container.decodeFlexibleIntIfPresent(forKey: .latencyMilliseconds)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), !(try decodeNil(forKey: key)) else {
            return nil
        }
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value)
        }
        return try decode(Double.self, forKey: key)
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), !(try decodeNil(forKey: key)) else {
            return nil
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decode(String.self, forKey: key),
           let value = Double(value) {
            return Int(value)
        }
        return try decode(Int.self, forKey: key)
    }
}
