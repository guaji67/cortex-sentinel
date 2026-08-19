import Foundation

struct RelayFileLocations {
    let pool: URL
    let health: URL
    let active: URL
    let switchLog: URL
}

struct SentinelPaths {
    let repositoryRoot: URL
    let poolDirectory: URL
    let aioDatabaseURL: URL
    let aioManifestURL: URL
    let codexConfigURL: URL
    let codexAuthURL: URL
    let inputStatusURL: URL
    let logsDirectory: URL

    /// 未设置监视目录环境变量时的默认日志目录。
    static var defaultWatchDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cortex-sentinel", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    var logsDirectoryExists: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: logsDirectory.path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// 监视目录不存在时给面板看的三行。不摊绝对路径，也不提 CORTEX_REPO_ROOT。
    static let missingWatchDirectoryTitle = "还没有可盯的线"
    static let missingWatchDirectoryBody =
        "哨兵盯一个目录，里面是派工工具写的状态文件。这个目录现在还不存在。"
    static let missingWatchDirectoryHint =
        "默认位置 ~/.cortex-sentinel/logs，把状态文件放进去就能看到。要换地方，在设置里点「选择」。"

    /// 监视目录不存在时给 --dump-state 看的诊断句。界面不共用这一句。
    var missingWatchDirectoryMessage: String {
        "监视目录不存在：\(logsDirectory.path)。可设置 CORTEX_SENTINEL_WATCH_DIR 指向日志目录，或设置 CORTEX_REPO_ROOT 指向仓库根（读取其中的 logs）。未设置时默认 \(Self.defaultWatchDirectory.path)。"
    }

    var lineRegistryURL: URL {
        logsDirectory.appendingPathComponent("codex-line-registry.json")
    }

    var channelStatusURL: URL {
        logsDirectory.appendingPathComponent("channel-status.json")
    }

    var lineTerminalAckURL: URL {
        logsDirectory.appendingPathComponent("line-terminal-ack.json")
    }

    var relayFiles: RelayFileLocations {
        RelayFileLocations(
            pool: poolDirectory.appendingPathComponent("pool.json"),
            health: poolDirectory.appendingPathComponent("health.json"),
            active: poolDirectory.appendingPathComponent("active.json"),
            switchLog: poolDirectory.appendingPathComponent("switch-log.jsonl")
        )
    }

    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory _: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        executableURL _: URL? = Bundle.main.executableURL,
        defaults: UserDefaults = SentinelSettings.resolvedDefaults()
    ) -> SentinelPaths {
        // 日志目录解析优先级：
        // 1. CORTEX_SENTINEL_WATCH_DIR  优先，直接就是日志目录（设置窗只读）
        // 2. CORTEX_REPO_ROOT           兼容旧装法，仍然解析成 <root>/logs（设置窗只读）
        // 3. UserDefaults               用户在设置窗选的目录
        // 4. ~/.cortex-sentinel/logs    都没给时的默认值
        let resolved = WatchDirectoryResolution.resolve(
            environment: environment,
            defaults: defaults
        )
        let repositoryRoot = resolved.repositoryRoot
        let logsDirectory = resolved.logsDirectory

        let poolDirectory: URL
        if let configured = environment["CORTEX_RELAY_POOL_DIR"], !configured.isEmpty {
            poolDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            poolDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cortex-air/codex-relay-pool", isDirectory: true)
        }

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let aioHome = homeDirectory.appendingPathComponent(".aio-coding-hub", isDirectory: true)
        let aioDatabaseURL = environment["CORTEX_AIO_DB_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? aioHome.appendingPathComponent("aio-coding-hub.db")
        let aioManifestURL = environment["CORTEX_AIO_CODEX_MANIFEST_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? aioHome
            .appendingPathComponent("cli-proxy", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("manifest.json")
        let codexConfigURL = environment["CORTEX_CODEX_CONFIG_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        let codexAuthURL = environment["CORTEX_CODEX_AUTH_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        let inputStatusURL = environment["CORTEX_INPUT_STATUS_URL"]
            .flatMap(URL.init(string:))
            ?? InputStatusConstants.defaultEndpoint

        return SentinelPaths(
            repositoryRoot: repositoryRoot,
            poolDirectory: poolDirectory,
            aioDatabaseURL: aioDatabaseURL,
            aioManifestURL: aioManifestURL,
            codexConfigURL: codexConfigURL,
            codexAuthURL: codexAuthURL,
            inputStatusURL: inputStatusURL,
            logsDirectory: logsDirectory
        )
    }
}

/// 按单个状态文件的 mtime + size 缓存解析结果。
/// 目录 mtime 不动也要能看见原地改写；所以这里不按目录级跳过。
final class LineStatusFileCache: @unchecked Sendable {
    fileprivate struct FileIdentity: Equatable {
        let modificationDate: Date
        let size: UInt64
    }

    private struct CachedFile {
        let identity: FileIdentity
        let line: LineStatus
    }

    private let lock = NSLock()
    private var files: [URL: CachedFile] = [:]
    private var parseCountStorage = 0

    var parseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parseCountStorage
    }

    func resetParseCount() {
        lock.lock()
        defer { lock.unlock() }
        parseCountStorage = 0
    }

    fileprivate func line(for url: URL, identity: FileIdentity) -> LineStatus? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = files[url], entry.identity == identity else {
            return nil
        }
        return entry.line
    }

    fileprivate func store(url: URL, identity: FileIdentity?, line: LineStatus) {
        lock.lock()
        defer { lock.unlock() }
        parseCountStorage += 1
        guard let identity else {
            return
        }
        files[url] = CachedFile(identity: identity, line: line)
    }

    fileprivate func retainOnly(_ urls: Set<URL>) {
        lock.lock()
        defer { lock.unlock() }
        files = files.filter { urls.contains($0.key) }
    }

    fileprivate func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        files.removeAll()
    }

    fileprivate static func fileIdentity(
        at url: URL,
        fileManager: FileManager
    ) -> FileIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return FileIdentity(modificationDate: modificationDate, size: size.uint64Value)
    }
}

enum SentinelFileReader {
    private static let statusPrefixes: [(prefix: String, engine: LineEngine)] = [
        ("codex-babysitter-", .codex),
        ("grok-", .cursorGrok),
    ]
    private static let statusSuffix = ".status.json"

    static func readChannelStatus(
        at url: URL,
        fileManager: FileManager = .default
    ) -> ChannelStatusSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        return parseChannelStatus(data: data)
    }

    static func parseChannelStatus(data: Data) -> ChannelStatusSnapshot {
        guard let payload = try? JSONDecoder().decode(ChannelStatusPayload.self, from: data) else {
            return .invalid
        }
        return ChannelStatusSnapshot(
            generatedAt: SentinelDateParser.parse(payload.generatedAt),
            grok: ChannelVerdict(payload: payload.channels?.grok),
            codex: ChannelVerdict(payload: payload.channels?.codex)
        )
    }

    static func readLines(
        in logsDirectory: URL,
        fileManager: FileManager = .default,
        cache: LineStatusFileCache? = nil
    ) -> [LineStatus] {
        let resolvedLogsDirectory = logsDirectory.resolvingSymlinksInPath()
        guard let urls = try? fileManager.contentsOfDirectory(
            at: resolvedLogsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            cache?.removeAll()
            return []
        }

        let statusEntries = urls.compactMap { url -> (url: URL, fallbackSlug: String, engine: LineEngine)? in
            guard let metadata = statusFileMetadata(for: url.lastPathComponent) else {
                return nil
            }
            return (url, metadata.fallbackSlug, metadata.engine)
        }
        .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }

        cache?.retainOnly(Set(statusEntries.map { $0.url.standardizedFileURL }))

        return statusEntries.map { entry in
            let url = entry.url
            let cacheKey = url.standardizedFileURL
            let identity = cache == nil
                ? nil
                : LineStatusFileCache.fileIdentity(at: cacheKey, fileManager: fileManager)
            if let identity, let cached = cache?.line(for: cacheKey, identity: identity) {
                return cached
            }
            let modifiedAt = identity?.modificationDate
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let data = (try? Data(contentsOf: url)) ?? Data()
            let line = parseLine(
                data: data,
                fallbackSlug: entry.fallbackSlug,
                fallbackEngine: entry.engine,
                sourceFile: url,
                sourceModifiedAt: modifiedAt
            )
            cache?.store(url: cacheKey, identity: identity, line: line)
            return line
        }
    }

    static func parseLine(
        data: Data,
        fallbackSlug: String,
        fallbackEngine: LineEngine = .codex,
        sourceFile: URL,
        sourceModifiedAt: Date? = nil
    ) -> LineStatus {
        do {
            let payload = try JSONDecoder().decode(BabysitterStatusPayload.self, from: data)
            guard let rawState = payload.state, !rawState.isEmpty else {
                throw SentinelReaderError.missingState
            }
            return LineStatus(
                sourceFile: sourceFile,
                slug: payload.slug?.isEmpty == false ? payload.slug! : fallbackSlug,
                engine: payload.engine.map(LineEngine.init(rawValue:)) ?? fallbackEngine,
                workdir: payload.workdir,
                branch: normalizedOptionalString(payload.branch),
                state: LineState(rawValue: rawState),
                restarts: payload.restarts ?? 0,
                reportsRestarts: payload.restarts != nil,
                rolloutAgeSeconds: payload.rolloutAgeSeconds,
                updatedAt: SentinelDateParser.parse(payload.updatedAt),
                sourceModifiedAt: sourceModifiedAt,
                startedAt: SentinelDateParser.parse(payload.startedAt),
                processID: payload.codexProcessID ?? payload.agentProcessID,
                model: normalizedOptionalString(payload.model),
                logBytes: payload.logBytes,
                exitCode: payload.exitCode,
                relay: payload.relay,
                relayProbe: payload.relayProbe,
                balance: payload.balance,
                note: normalizedOptionalString(payload.note),
                maxRestartsOverride: payload.maxRestartsOverride,
                escalateAfterFailures: payload.escalateAfterFailures,
                updatedAtRaw: normalizedOptionalString(payload.updatedAt)
            )
        } catch {
            return LineStatus(
                sourceFile: sourceFile,
                slug: fallbackSlug,
                engine: fallbackEngine,
                workdir: nil,
                branch: nil,
                state: .unknown("invalid"),
                restarts: 0,
                reportsRestarts: false,
                rolloutAgeSeconds: nil,
                updatedAt: nil,
                sourceModifiedAt: sourceModifiedAt,
                relay: nil
            )
        }
    }

    private static func statusFileMetadata(
        for fileName: String
    ) -> (fallbackSlug: String, engine: LineEngine)? {
        guard fileName.hasSuffix(statusSuffix),
              let match = statusPrefixes.first(where: { fileName.hasPrefix($0.prefix) })
        else {
            return nil
        }
        return (
            String(fileName.dropFirst(match.prefix.count).dropLast(statusSuffix.count)),
            match.engine
        )
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func readRelays(
        at locations: RelayFileLocations,
        fileManager: FileManager = .default
    ) -> RelaySnapshot {
        guard fileManager.fileExists(atPath: locations.pool.path) else {
            return .unconfigured
        }

        guard let poolData = try? Data(contentsOf: locations.pool),
              let pool = try? JSONDecoder().decode(RelayPoolPayload.self, from: poolData)
        else {
            return RelaySnapshot(
                sourceState: .invalid,
                entries: [],
                healthByID: [:],
                active: nil,
                latestSwitch: nil
            )
        }

        let health: [String: RelayHealth]
        if let data = try? Data(contentsOf: locations.health),
           let decoded = try? JSONDecoder().decode([String: RelayHealth].self, from: data) {
            health = decoded
        } else {
            health = [:]
        }

        let active: ActiveRelay?
        if let data = try? Data(contentsOf: locations.active) {
            active = try? JSONDecoder().decode(ActiveRelay.self, from: data)
        } else {
            active = nil
        }

        return RelaySnapshot(
            sourceState: .available,
            entries: pool.entries,
            healthByID: health,
            active: active,
            latestSwitch: readLatestSwitch(at: locations.switchLog)
        )
    }

    private static func readLatestSwitch(at url: URL) -> SwitchLogEntry? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let endOffset = (try? handle.seekToEnd()) ?? 0
        let startOffset = endOffset > 65_536 ? endOffset - 65_536 : 0
        try? handle.seek(toOffset: startOffset)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .reversed()

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(SwitchLogEntry.self, from: data)
            else {
                continue
            }
            return entry
        }
        return nil
    }
}

private struct ChannelStatusPayload: Decodable {
    let generatedAt: String?
    let channels: ChannelStatusChannelsPayload?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case channels
    }
}

private struct ChannelStatusChannelsPayload: Decodable {
    let grok: ChannelVerdictPayload?
    let codex: ChannelVerdictPayload?
}

struct ChannelVerdictPayload: Decodable {
    let status: String?
    let evidence: String?
    let running: Int?
}

private struct RelayPoolPayload: Decodable {
    let entries: [RelayEntry]
}

private struct BabysitterStatusPayload: Decodable {
    let engine: String?
    let slug: String?
    let state: String?
    let workdir: String?
    let branch: String?
    let restarts: Int?
    let rolloutAgeSeconds: Double?
    let updatedAt: String?
    let startedAt: String?
    let codexProcessID: Int?
    let agentProcessID: Int?
    let model: String?
    let logBytes: Int?
    let exitCode: Int?
    let relay: LineRelay?
    let relayProbe: LineRelayProbe?
    let balance: RelayBalance?
    let note: String?
    let maxRestartsOverride: Int?
    let escalateAfterFailures: Int?

    enum CodingKeys: String, CodingKey {
        case engine
        case slug
        case state
        case workdir
        case branch
        case restarts
        case rolloutAgeSeconds = "rollout_age_s"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case codexProcessID = "codex_pid"
        case agentProcessID = "agent_pid"
        case model
        case logBytes = "log_bytes"
        case exitCode = "exit_code"
        case relay
        case relayProbe = "relay_probe"
        case balance
        case note
        case maxRestartsOverride = "max_restarts_override"
        case escalateAfterFailures = "escalate_after_failures"
    }
}

private enum SentinelReaderError: Error {
    case missingState
}

enum SentinelDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

struct StatusDiskSnapshot {
    var lines: [LineStatus]
    var registry: CodexLineRegistry
    var channelStatus: ChannelStatusSnapshot
    var ack: TerminalAckLedger
    var otherCodexProcesses: [OtherCodexProcess]?
    var readOnMainThread: Bool
}

enum StatusDiskReader {
    static func load(
        logsDirectory: URL,
        registryURL: URL,
        channelStatusURL: URL,
        ackURL: URL,
        lineStatusCache: LineStatusFileCache,
        lineRegistryCache: CodexLineRegistryCache,
        includeOtherProcesses: Bool,
        otherCodexProcessReader: (Set<Int>) -> [OtherCodexProcess]
    ) -> StatusDiskSnapshot {
        let lines = SentinelFileReader.readLines(
            in: logsDirectory,
            cache: lineStatusCache
        )
        let registry = lineRegistryCache.read(at: registryURL)
        let channelStatus = SentinelFileReader.readChannelStatus(at: channelStatusURL)
        let ack = SentinelFileReader.readTerminalAck(at: ackURL)
        let processes: [OtherCodexProcess]?
        if includeOtherProcesses {
            processes = otherCodexProcessReader(Set(lines.compactMap(\.processID)))
        } else {
            processes = nil
        }
        return StatusDiskSnapshot(
            lines: lines,
            registry: registry,
            channelStatus: channelStatus,
            ack: ack,
            otherCodexProcesses: processes,
            readOnMainThread: Thread.isMainThread
        )
    }
}
