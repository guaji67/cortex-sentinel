import Foundation
import SQLite3

enum AIODataReader {
    static func read(
        databaseURL: URL,
        manifestURL _: URL,
        configURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> AIOSnapshot {
        let routeMode = CodexConfigReader.readModelProvider(at: configURL, fileManager: fileManager)
            .map { $0.lowercased() == "aio" ? AIORouteMode.aggregate : .direct }
            ?? .direct
        let gatewayConfigured = CodexConfigReader.readAIOGatewayConfiguration(
            at: configURL,
            fileManager: fileManager
        ) != nil

        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return unavailableSnapshot(routeMode: routeMode)
        }

        for attempt in 0..<AIOConstants.databaseBusyRetryCount {
            do {
                let result = try readDatabase(
                    at: databaseURL
                )
                return AIOSnapshot(
                    sourceState: .available,
                    gatewayEnabled: gatewayConfigured,
                    routeMode: routeMode,
                    providers: result.providers,
                    lastHitProviderID: result.lastHitProviderID,
                    lastHitProviderName: result.lastHitProviderName,
                    readAt: now,
                    errorMessage: nil
                )
            } catch AIODataReaderError.busy where attempt + 1 < AIOConstants.databaseBusyRetryCount {
                Thread.sleep(forTimeInterval: AIOConstants.databaseBusyRetryDelay)
            } catch {
                return AIOSnapshot(
                    sourceState: .invalid,
                    gatewayEnabled: gatewayConfigured,
                    routeMode: routeMode,
                    providers: [],
                    lastHitProviderID: nil,
                    lastHitProviderName: nil,
                    readAt: now,
                    errorMessage: "AIO 数据读取失败"
                )
            }
        }

        return AIOSnapshot(
            sourceState: .invalid,
            gatewayEnabled: gatewayConfigured,
            routeMode: routeMode,
            providers: [],
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: now,
            errorMessage: "AIO 数据暂时忙"
        )
    }

    static func readUsageTargets(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) -> [AIOUsageTarget] {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return []
        }

        for attempt in 0..<AIOConstants.databaseBusyRetryCount {
            do {
                let connection = try AIOReadConnection(url: databaseURL)
                var targets: [AIOUsageTarget] = []
                try connection.query(Self.usageTargetQuery) { statement in
                    guard let baseURL = connection.text(statement, column: 1),
                          let apiKey = connection.text(statement, column: 2)
                    else {
                        return
                    }
                    targets.append(
                        AIOUsageTarget(
                            id: sqlite3_column_int64(statement, 0),
                            baseURL: baseURL,
                            apiKey: apiKey,
                            enabled: sqlite3_column_int(statement, 3) != 0
                        )
                    )
                }
                return targets
            } catch AIODataReaderError.busy where attempt + 1 < AIOConstants.databaseBusyRetryCount {
                Thread.sleep(forTimeInterval: AIOConstants.databaseBusyRetryDelay)
            } catch {
                return []
            }
        }
        return []
    }

    private static func unavailableSnapshot(routeMode: AIORouteMode) -> AIOSnapshot {
        AIOSnapshot(
            sourceState: .unconfigured,
            gatewayEnabled: false,
            routeMode: routeMode,
            providers: [],
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: nil,
            errorMessage: nil
        )
    }

    private static func readDatabase(at url: URL) throws -> AIOReadDatabaseResult {
        let connection = try AIOReadConnection(url: url)
        var providers: [AIOProvider] = []
        try connection.query(Self.providerQuery) { statement in
            let providerOrder = Int(sqlite3_column_int(statement, 4))
            let routeOrder = Int(sqlite3_column_int(statement, 6))
            providers.append(
                AIOProvider(
                    id: sqlite3_column_int64(statement, 0),
                    name: connection.text(statement, column: 1) ?? "未命名密钥",
                    baseURL: connection.text(statement, column: 2) ?? "",
                    enabled: sqlite3_column_int(statement, 3) != 0,
                    routeOrder: routeOrder,
                    providerOrder: providerOrder,
                    note: connection.text(statement, column: 5) ?? "",
                    circuitState: AIOCircuitState(
                        rawValue: connection.text(statement, column: 7)
                    ),
                    failureCount: Int(sqlite3_column_int(statement, 8)),
                    usage: .idle
                )
            )
        }

        var lastHit: AIOAttempt?
        do {
            try connection.query(Self.lastSuccessQuery) { statement in
                guard lastHit == nil,
                      let attemptsJSON = connection.text(statement, column: 0),
                      let data = attemptsJSON.data(using: .utf8),
                      let attempts = try? JSONDecoder().decode([AIOAttempt].self, from: data)
                else {
                    return
                }
                lastHit = attempts.last(where: \.isSuccess)
            }
        } catch {
            // 旧版本数据库可能暂时没有请求日志表，密钥池仍可展示。
        }

        let providerByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let lastHitProviderID = lastHit?.providerID
        let lastHitProviderName = lastHit.flatMap { attempt in
            let name = attempt.providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                return name
            }
            return attempt.providerID.flatMap { providerByID[$0]?.name }
        }

        return AIOReadDatabaseResult(
            providers: providers,
            lastHitProviderID: lastHitProviderID,
            lastHitProviderName: lastHitProviderName
        )
    }

    private static let providerQuery = """
        SELECT
            p.id,
            p.name,
            p.base_url,
            p.enabled,
            p.sort_order,
            p.note,
            COALESCE(r.sort_order, p.sort_order) AS route_order,
            COALESCE(cb.state, 'CLOSED') AS circuit_state,
            COALESCE(cb.failure_count, 0) AS failure_count
        FROM providers AS p
        LEFT JOIN default_route_providers AS r
            ON r.cli_key = p.cli_key AND r.provider_id = p.id
        LEFT JOIN provider_circuit_breakers AS cb
            ON cb.provider_id = p.id
        WHERE p.cli_key = 'codex'
        ORDER BY
            CASE WHEN r.sort_order IS NULL THEN 1 ELSE 0 END,
            r.sort_order,
            p.sort_order,
            p.id
        """

    private static let lastSuccessQuery = """
        SELECT attempts_json
        FROM request_logs
        WHERE cli_key = 'codex'
          AND status >= 200
          AND status < 300
        ORDER BY created_at_ms DESC, id DESC
        LIMIT 128
        """

    private static let usageTargetQuery = """
        SELECT id, base_url, api_key_plaintext, enabled
        FROM providers
        WHERE cli_key = 'codex'
          AND TRIM(base_url) <> ''
          AND TRIM(api_key_plaintext) <> ''
        ORDER BY id
        """
}

private struct AIOReadDatabaseResult {
    let providers: [AIOProvider]
    let lastHitProviderID: Int64?
    let lastHitProviderName: String?
}

private struct AIOAttempt: Decodable {
    let providerID: Int64?
    let providerName: String?
    let outcome: String?
    let status: Int?

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case providerName = "provider_name"
        case outcome
        case status
    }

    var isSuccess: Bool {
        if outcome?.lowercased() == "success" {
            return true
        }
        guard let status else {
            return false
        }
        return (200..<300).contains(status)
    }
}

private enum AIODataReaderError: Error {
    case busy
    case sqlite(Int32)
}

private final class AIOReadConnection {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var connection: OpaquePointer?
        let code = url.path.withCString { path in
            sqlite3_open_v2(
                path,
                &connection,
                SQLITE_OPEN_READONLY,
                nil
            )
        }
        guard code == SQLITE_OK, let connection else {
            if let connection {
                sqlite3_close_v2(connection)
            }
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                throw AIODataReaderError.busy
            }
            throw AIODataReaderError.sqlite(code)
        }
        handle = connection
        sqlite3_busy_timeout(connection, AIOConstants.databaseBusyTimeoutMilliseconds)
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func query(
        _ sql: String,
        rowHandler: (OpaquePointer) -> Void
    ) throws {
        guard let handle else {
            throw AIODataReaderError.sqlite(SQLITE_MISUSE)
        }

        var statement: OpaquePointer?
        let prepareCode = sql.withCString {
            sqlite3_prepare_v2(handle, $0, -1, &statement, nil)
        }
        guard prepareCode == SQLITE_OK, let statement else {
            if prepareCode == SQLITE_BUSY || prepareCode == SQLITE_LOCKED {
                throw AIODataReaderError.busy
            }
            throw AIODataReaderError.sqlite(prepareCode)
        }
        defer {
            sqlite3_finalize(statement)
        }

        while true {
            let stepCode = sqlite3_step(statement)
            switch stepCode {
            case SQLITE_ROW:
                rowHandler(statement)
            case SQLITE_DONE:
                return
            case SQLITE_BUSY, SQLITE_LOCKED:
                throw AIODataReaderError.busy
            default:
                throw AIODataReaderError.sqlite(stepCode)
            }
        }
    }

    func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else {
            return nil
        }
        return String(cString: value)
    }
}

enum CodexConfigReader {
    static func readModelProvider(
        at url: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        var inRootTable = true
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inRootTable = false
                continue
            }
            guard inRootTable else {
                continue
            }
            let uncommented = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = uncommented.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "model_provider"
            else {
                continue
            }
            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func readAIOGatewayConfiguration(
        at url: URL,
        fileManager: FileManager = .default
    ) -> AIOGatewayConfiguration? {
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        var inAIOSection = false
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inAIOSection = line == "[model_providers.aio]"
                continue
            }
            guard inAIOSection else {
                continue
            }
            let uncommented = line.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
            let parts = uncommented.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }

        guard let baseURL = values["base_url"], !baseURL.isEmpty,
              let bearerToken = values["experimental_bearer_token"], !bearerToken.isEmpty
        else {
            return nil
        }
        return AIOGatewayConfiguration(baseURL: baseURL, bearerToken: bearerToken)
    }
}

struct AIOGatewayConfiguration: Equatable, Sendable {
    let baseURL: String
    let bearerToken: String
}

struct AIOUsageTarget: Equatable, Sendable {
    let id: Int64
    let baseURL: String
    let apiKey: String
    let enabled: Bool
}

protocol AIOUsageRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: AIOUsageRequestLoading {}

struct AIOUsageClient: Sendable {
    private let requestLoader: any AIOUsageRequestLoading
    private let sleep: @Sendable (TimeInterval) async -> Void

    init(
        requestLoader: any AIOUsageRequestLoading = URLSession.shared,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.requestLoader = requestLoader
        self.sleep = sleep
    }

    func fetchAll(
        targets: [AIOUsageTarget],
        includeDisabled: Bool = false
    ) async -> [Int64: AIOUsageStatus] {
        await withTaskGroup(of: (Int64, AIOUsageStatus).self) { group in
            for target in targets where target.enabled || includeDisabled {
                group.addTask {
                    (target.id, await fetch(target: target))
                }
            }

            var results: [Int64: AIOUsageStatus] = [:]
            for await (providerID, status) in group {
                results[providerID] = status
            }
            return results
        }
    }

    /// 按传入顺序逐条刷，两条之间间隔 `interval`。第一条立刻开始，最后一条刷完不再多睡。
    func fetchSequential(
        targets: [AIOUsageTarget],
        interval: TimeInterval = AIOConstants.sequentialUsageInterval,
        onStart: (@Sendable (Int64) async -> Void)? = nil
    ) async -> [Int64: AIOUsageStatus] {
        var results: [Int64: AIOUsageStatus] = [:]
        for (index, target) in targets.enumerated() {
            if index > 0 {
                await sleep(interval)
            }
            await onStart?(target.id)
            results[target.id] = await fetch(target: target)
        }
        return results
    }

    func pause(_ interval: TimeInterval) async {
        await sleep(interval)
    }

    func fetch(target: AIOUsageTarget) async -> AIOUsageStatus {
        guard let url = Self.usageURL(baseURL: target.baseURL) else {
            return .failed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = AIOConstants.usageTimeout
        request.setValue("Bearer \(target.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await requestLoader.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                return .failed
            }
            guard let usage = Self.decodeUsage(data), usage.isValid else {
                return .invalid
            }
            return .success(usage)
        } catch let error as URLError where error.code == .timedOut {
            return .timedOut
        } catch {
            return .failed
        }
    }

    static func decodeUsage(_ data: Data) -> AIOUsage? {
        if let response = try? JSONDecoder().decode(AIOUsageResponse.self, from: data) {
            return AIOUsage(response: response)
        }
        if let response = try? JSONDecoder().decode(AIOOfficialUsageResponse.self, from: data) {
            return AIOUsage(official: response)
        }
        return nil
    }

    static func usageURL(baseURL: String) -> URL? {
        guard var components = URLComponents(
            string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        components.scheme?.isEmpty == false,
        components.host?.isEmpty == false
        else {
            return nil
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/v1" {
            path = ""
        } else if path.hasSuffix("/v1") {
            path.removeLast(3)
        }
        components.path = path + "/v1/usage"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
