import AppKit
import Darwin
import Foundation
import UserNotifications

@MainActor
final class SentinelStore: ObservableObject {
    @Published private(set) var lines: [LineStatus] = []
    @Published private(set) var otherCodexProcesses: [OtherCodexProcess] = []
    @Published private(set) var aio: AIOSnapshot = .unconfigured
    @Published private(set) var lineRegistry: CodexLineRegistry = .empty
    @Published private(set) var inputStatus: InputStatusSnapshot = .empty
    @Published private(set) var officialUsage: OfficialUsageSnapshot = .empty
    @Published private(set) var channelStatus: ChannelStatusSnapshot = .missing
    @Published private(set) var unclaimedTerminals: [UnclaimedTerminalEntry] = []
    @Published private(set) var backgroundJobs: [BackgroundJobRow] = []
    @Published private(set) var backgroundJobMessages: [String: String] = [:]
    @Published private(set) var backgroundJobOperations: Set<String> = []
    @Published private(set) var isOfficialUsageRefreshing = false
    @Published private(set) var isOfficialUsageRefreshCoolingDown = false

    let paths: SentinelPaths

    private let notifier = SentinelNotifier()
    private var statusTimer: Timer?
    private var aioTimer: Timer?
    private var inputStatusTimer: Timer?
    private var officialUsageTimer: Timer?
    private var cleanupTimer: Timer?
    private var aioRefreshInFlight = false
    private var inputStatusRefreshInFlight = false
    private var lastAIORefreshAt: Date?
    private var lastAIOUsageRefreshAt: Date?
    private var lastDisabledAIOUsageRefreshAt: Date?
    private var lastInputStatusRefreshAt: Date?
    private var lastOfficialUsageAttemptAt: Date?
    private var hasStarted = false
    private var isPanelPresented = false
    private var pendingAIOUsageRefresh = false
    private var relayRecoveryCoordinator = RelayRecoveryProbeCoordinator()
    private let launchctlRunner: any LaunchctlRunning
    private let disabledJobsStore: DisabledJobsStore
    private let fileManager: FileManager
    private let launchctlUID: Int32
    private var processActivity: NSObjectProtocol?

    init(
        paths: SentinelPaths = .discover(),
        launchctlRunner: any LaunchctlRunning = ProcessLaunchctlRunner(),
        fileManager: FileManager = .default,
        disabledJobsURL: URL? = nil,
        launchctlUID: Int32 = Int32(getuid())
    ) {
        self.paths = paths
        self.launchctlRunner = launchctlRunner
        self.fileManager = fileManager
        self.launchctlUID = launchctlUID
        self.disabledJobsStore = DisabledJobsStore(
            url: disabledJobsURL ?? paths.disabledJobsURL,
            fileManager: fileManager
        )
    }

    deinit {
        statusTimer?.invalidate()
        aioTimer?.invalidate()
        inputStatusTimer?.invalidate()
        officialUsageTimer?.invalidate()
        cleanupTimer?.invalidate()
    }

    var severity: SentinelSeverity {
        SentinelAggregation.severity(lines: lines, aio: aio)
    }

    var sortedLines: [LineStatus] {
        SentinelAggregation.sortedLines(lines)
    }

    var lineGroups: SentinelLineGroups {
        SentinelAggregation.lineGroups(lines: lines, registry: lineRegistry)
    }

    var statusBarBalances: [StatusBarBalanceItem] {
        aio.statusBarBalances
    }

    var statusBarTooltip: String {
        let probes = inputStatus.displayProbes()
        let serviceText = probes.map { display in
            let latency = display.probe.latencyMilliseconds.map { " · \($0) 毫秒" } ?? ""
            return "\(display.probe.model)：\(display.state.displayName)\(latency)"
        }
        .joined(separator: "\n")
        return serviceText.isEmpty ? "服务状态暂无数据" : serviceText
    }

    var watchDirectoryMissing: Bool {
        !paths.logsDirectoryExists
    }

    var statusBarAccessibilityLabel: String {
        let states = inputStatus.displayProbes().map {
            "\($0.probe.model)\($0.state.displayName)"
        }
        let balances = statusBarBalances.map {
            "\($0.providerName) 余额 \($0.text)"
        }
        return (states + balances).joined(separator: "，")
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        processActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "保持哨兵状态与后台任务面板及时刷新"
        )
        notifier.requestAuthorization()
        refreshAll()

        statusTimer = Timer.scheduledTimer(
            withTimeInterval: AIOConstants.statusRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatuses()
            }
        }
        aioTimer = Timer.scheduledTimer(
            withTimeInterval: AIOConstants.aioRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.refreshAIO(force: false, includeUsage: self.isPanelPresented)
            }
        }
        inputStatusTimer = Timer.scheduledTimer(
            withTimeInterval: InputStatusConstants.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInputStatus(force: false)
            }
        }
        officialUsageTimer = Timer.scheduledTimer(
            withTimeInterval: OfficialUsageConstants.automaticRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshOfficialUsage(reason: .automatic)
            }
        }

        // v3.2 第 5 点：启动即清一次派工日志，之后每小时巡检一次。
        runLogCleanup()
        cleanupTimer = Timer.scheduledTimer(
            withTimeInterval: LogCleanupConstants.sweepInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runLogCleanup()
            }
        }
    }

    private func runLogCleanup() {
        let logsDirectory = paths.logsDirectory
        Task.detached(priority: .utility) {
            LogCleaner.run(logsDirectory: logsDirectory, dryRun: false)
        }
    }

    func refreshAll() {
        let updatedLines = SentinelFileReader.readLines(in: paths.logsDirectory)
        apply(
            lines: updatedLines,
            aio: aio,
            otherCodexProcesses: readOtherCodexProcesses(excluding: updatedLines),
            lineRegistry: CodexLineRegistryReader.read(at: paths.lineRegistryURL),
            inputStatus: inputStatus
        )
        refreshAIO(force: true, includeUsage: false)
        refreshInputStatus(force: true)
        refreshOfficialUsage(reason: .startup)
        refreshChannelStatus()
        refreshUnclaimed(lines: updatedLines, registry: CodexLineRegistryReader.read(at: paths.lineRegistryURL))
        refreshBackgroundJobs()
    }

    func refreshStatuses() {
        let updatedLines = SentinelFileReader.readLines(in: paths.logsDirectory)
        apply(
            lines: updatedLines,
            aio: aio,
            otherCodexProcesses: readOtherCodexProcesses(excluding: updatedLines),
            lineRegistry: CodexLineRegistryReader.read(at: paths.lineRegistryURL),
            inputStatus: inputStatus
        )
        refreshChannelStatus()
        refreshUnclaimed(lines: updatedLines, registry: CodexLineRegistryReader.read(at: paths.lineRegistryURL))
        refreshBackgroundJobs()
    }

    private func refreshChannelStatus() {
        channelStatus = SentinelFileReader.readChannelStatus(at: paths.channelStatusURL)
    }

    private func refreshUnclaimed(lines: [LineStatus], registry: CodexLineRegistry) {
        let ack = SentinelFileReader.readTerminalAck(at: paths.lineTerminalAckURL)
        unclaimedTerminals = UnclaimedTerminalAggregation.entries(
            lines: lines,
            registry: registry,
            ack: ack
        )
    }

    func refreshRelays() {
        refreshAIO(force: true, includeUsage: true)
    }

    func setPanelPresented(_ presented: Bool) {
        guard isPanelPresented != presented else {
            return
        }
        isPanelPresented = presented
        guard presented else {
            return
        }
        refreshAIO(force: true, includeUsage: true)
        refreshInputStatus(force: true)
    }

    func refreshBackgroundJobs() {
        backgroundJobs = BackgroundJobsPresentation.merge(
            jobs: BackgroundJobsReader.read(
                at: paths.backgroundJobsHealthURL,
                fileManager: fileManager
            ),
            disabledLabels: disabledJobsStore.read()
        )
    }

    func disableBackgroundJob(_ label: String) {
        runBackgroundJobOperation(label) { [launchctlRunner, launchctlUID] in
            let bootout = await launchctlRunner.run(
                arguments: LaunchctlCommandBuilder.bootout(uid: launchctlUID, label: label)
            )
            guard bootout.succeeded else {
                throw BackgroundJobOperationFailure(
                    message: BackgroundJobOperationFailure.message(
                        action: "关闭",
                        result: bootout
                    )
                )
            }

            let disable = await launchctlRunner.run(
                arguments: LaunchctlCommandBuilder.disable(uid: launchctlUID, label: label)
            )
            guard disable.succeeded else {
                throw BackgroundJobOperationFailure(
                    message: BackgroundJobOperationFailure.message(
                        action: "写入关闭设置",
                        result: disable
                    )
                )
            }
        } onSuccess: { [weak self] in
            guard let self else { return }
            do {
                _ = try self.disabledJobsStore.adding(label)
                self.backgroundJobMessages[label] = nil
            } catch {
                self.backgroundJobMessages[label] = "已关闭，但本地记录写入失败：\(error.localizedDescription)"
            }
        }
    }

    func enableBackgroundJob(_ label: String) {
        let plistURL = paths.launchAgentURL(for: label)
        guard fileManager.fileExists(atPath: plistURL.path) else {
            backgroundJobMessages[label] = "配置文件已删除，无法从这里重新开启"
            refreshBackgroundJobs()
            return
        }

        runBackgroundJobOperation(label) { [launchctlRunner, launchctlUID] in
            let enable = await launchctlRunner.run(
                arguments: LaunchctlCommandBuilder.enable(uid: launchctlUID, label: label)
            )
            guard enable.succeeded else {
                throw BackgroundJobOperationFailure(
                    message: BackgroundJobOperationFailure.message(
                        action: "开启",
                        result: enable
                    )
                )
            }

            let bootstrap = await launchctlRunner.run(
                arguments: LaunchctlCommandBuilder.bootstrap(
                    uid: launchctlUID,
                    plistURL: plistURL
                )
            )
            guard bootstrap.succeeded else {
                throw BackgroundJobOperationFailure(
                    message: BackgroundJobOperationFailure.message(
                        action: "加载",
                        result: bootstrap
                    )
                )
            }
        } onSuccess: { [weak self] in
            guard let self else { return }
            do {
                _ = try self.disabledJobsStore.removing(label)
                self.backgroundJobMessages[label] = nil
            } catch {
                self.backgroundJobMessages[label] = "已开启，但本地记录更新失败：\(error.localizedDescription)"
            }
        }
    }

    private func runBackgroundJobOperation(
        _ label: String,
        operation: @escaping () async throws -> Void,
        onSuccess: @escaping () -> Void
    ) {
        guard !backgroundJobOperations.contains(label) else { return }
        backgroundJobOperations.insert(label)
        backgroundJobMessages[label] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await operation()
                onSuccess()
            } catch let failure as BackgroundJobOperationFailure {
                self.backgroundJobMessages[label] = failure.message
            } catch {
                self.backgroundJobMessages[label] = "操作失败：\(error.localizedDescription)"
            }
            self.backgroundJobOperations.remove(label)
            self.refreshBackgroundJobs()
        }
    }

    func refreshOfficialUsageManually() {
        refreshOfficialUsage(reason: .manual)
    }

    private func refreshOfficialUsage(reason: OfficialUsageRefreshReason) {
        let now = Date()
        guard OfficialUsageRefreshPolicy.shouldStart(
            reason: reason,
            lastAttemptAt: lastOfficialUsageAttemptAt,
            isInFlight: isOfficialUsageRefreshing,
            now: now
        ) else {
            return
        }

        isOfficialUsageRefreshing = true
        lastOfficialUsageAttemptAt = now
        if reason == .manual {
            beginOfficialUsageManualCooldown()
        }
        let client = OfficialUsageClient(authURL: paths.codexAuthURL)

        Task { @MainActor [weak self] in
            let result: Result<OfficialUsageSnapshot, OfficialUsageClientError>
            do {
                result = .success(try await client.fetch())
            } catch let error as OfficialUsageClientError {
                result = .failure(error)
            } catch {
                result = .failure(.network)
            }

            guard let self else {
                return
            }
            self.isOfficialUsageRefreshing = false
            switch result {
            case let .success(snapshot):
                self.officialUsage = snapshot
            case let .failure(error):
                self.officialUsage = self.officialUsage.preservingLastSuccess(
                    errorMessage: error.userMessage,
                    failedAt: Date()
                )
            }
        }
    }

    private func beginOfficialUsageManualCooldown() {
        isOfficialUsageRefreshCoolingDown = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(OfficialUsageConstants.manualRefreshThrottle * 1_000_000_000)
            )
            self?.isOfficialUsageRefreshCoolingDown = false
        }
    }

    private func refreshAIO(force: Bool, includeUsage: Bool) {
        let now = Date()
        if aioRefreshInFlight {
            pendingAIOUsageRefresh = pendingAIOUsageRefresh || includeUsage
            return
        }
        let relevantLastRefreshAt = includeUsage ? lastAIOUsageRefreshAt : lastAIORefreshAt
        if let relevantLastRefreshAt {
            let elapsed = now.timeIntervalSince(relevantLastRefreshAt)
            let minimumInterval = force
                ? AIOConstants.manualRefreshThrottle
                : AIOConstants.aioRefreshInterval
            if elapsed < minimumInterval {
                return
            }
        }

        aioRefreshInFlight = true
        lastAIORefreshAt = now
        if includeUsage {
            lastAIOUsageRefreshAt = now
        }
        let includeDisabledUsage = includeUsage
            && AIOUsageRefreshPolicy.shouldRefreshDisabledUsage(
                lastRefreshAt: lastDisabledAIOUsageRefreshAt,
                now: now
            )
        let databaseURL = paths.aioDatabaseURL
        let manifestURL = paths.aioManifestURL
        let configURL = paths.codexConfigURL
        let cachedUsage = Dictionary(
            uniqueKeysWithValues: aio.providers.map { ($0.id, $0.usage) }
        )

        Task { @MainActor [weak self] in
            let result = await Task.detached {
                let base = AIODataReader.read(
                    databaseURL: databaseURL,
                    manifestURL: manifestURL,
                    configURL: configURL
                )
                guard base.sourceState == .available else {
                    return (snapshot: base, attemptedDisabledUsage: false)
                }
                let cachedBase = base.replacingUsage(cachedUsage)
                guard includeUsage else {
                    return (snapshot: cachedBase, attemptedDisabledUsage: false)
                }
                let usageTargets = AIODataReader.readUsageTargets(databaseURL: databaseURL)
                let freshUsage = await AIOUsageClient().fetchAll(
                    targets: usageTargets,
                    includeDisabled: includeDisabledUsage
                )
                let mergedUsage = AIOUsageRefreshPolicy.merge(
                    cached: cachedUsage,
                    fresh: freshUsage,
                    providers: base.providers
                )
                let attemptedDisabledUsage = includeDisabledUsage
                    && base.providers.contains {
                        !$0.enabled && !$0.isOfficialOAuthProvider
                    }
                return (
                    snapshot: base.replacingUsage(mergedUsage),
                    attemptedDisabledUsage: attemptedDisabledUsage
                )
            }.value

            guard let self else {
                return
            }
            self.aioRefreshInFlight = false
            if result.attemptedDisabledUsage {
                self.lastDisabledAIOUsageRefreshAt = now
            }
            self.apply(
                lines: self.lines,
                aio: result.snapshot,
                otherCodexProcesses: self.otherCodexProcesses,
                lineRegistry: self.lineRegistry,
                inputStatus: self.inputStatus
            )
            if self.pendingAIOUsageRefresh {
                self.pendingAIOUsageRefresh = false
                self.refreshAIO(force: true, includeUsage: true)
            }
        }
    }

    private func refreshInputStatus(force: Bool) {
        let now = Date()
        if inputStatusRefreshInFlight {
            return
        }
        if let lastInputStatusRefreshAt {
            let elapsed = now.timeIntervalSince(lastInputStatusRefreshAt)
            let minimumInterval: TimeInterval
            if isPanelPresented {
                minimumInterval = InputStatusConstants.panelRefreshThreshold
            } else if force {
                minimumInterval = 0
            } else {
                minimumInterval = InputStatusRefreshPolicy.automaticInterval(
                    panelPresented: false
                )
            }
            if elapsed < minimumInterval {
                return
            }
        }

        inputStatusRefreshInFlight = true
        lastInputStatusRefreshAt = now
        let client = InputStatusClient(endpoint: paths.inputStatusURL)

        Task { @MainActor [weak self] in
            let result: Result<InputStatusSnapshot, InputStatusClientError>
            do {
                result = .success(try await client.fetch())
            } catch let error as InputStatusClientError {
                result = .failure(error)
            } catch {
                result = .failure(.network)
            }

            guard let self else {
                return
            }
            self.inputStatusRefreshInFlight = false
            let snapshot: InputStatusSnapshot
            switch result {
            case let .success(value):
                snapshot = value
            case let .failure(error):
                snapshot = self.inputStatus.preservingData(withError: error.userMessage)
            }
            self.apply(
                lines: self.lines,
                aio: self.aio,
                otherCodexProcesses: self.otherCodexProcesses,
                lineRegistry: self.lineRegistry,
                inputStatus: snapshot
            )
        }
    }

    func openLogsDirectory() {
        _ = NSWorkspace.shared.open(paths.logsDirectory)
    }

    private func apply(
        lines: [LineStatus],
        aio: AIOSnapshot,
        otherCodexProcesses: [OtherCodexProcess],
        lineRegistry: CodexLineRegistry,
        inputStatus: InputStatusSnapshot
    ) {
        notifier.observe(lines: lines, aio: aio, registry: lineRegistry)
        self.lines = lines
        self.aio = aio
        self.otherCodexProcesses = otherCodexProcesses
        self.lineRegistry = lineRegistry
        self.inputStatus = inputStatus
        relayRecoveryCoordinator.requestEligibleProbes(
            lines: lines,
            aio: aio,
            inputStatus: inputStatus,
            logsDirectory: paths.logsDirectory
        )
    }

    private func readOtherCodexProcesses(excluding lines: [LineStatus]) -> [OtherCodexProcess] {
        let managedProcessIDs = Set(lines.compactMap(\.processID))
        return OtherCodexProcessReader.read(excluding: managedProcessIDs)
    }
}

enum RelayAddFailureMessage {
    static func resolve(output: String, health: RelayHealth?) -> String {
        switch health?.httpClass?.lowercased() {
        case "auth":
            return "鉴权失败，请检查 API Key"
        case "timeout":
            return "连接超时，请检查 Base URL"
        case "5xx":
            return "中转暂时不可用"
        case "no_balance":
            return "余额不足，条目未启用"
        default:
            break
        }

        let lowered = output.lowercased()
        if lowered.contains("401") || lowered.contains("403") || lowered.contains("auth") {
            return "鉴权失败，请检查 API Key"
        }
        if lowered.contains("timeout") || lowered.contains("timed out") || output.contains("超时") {
            return "连接超时，请检查 Base URL"
        }
        if lowered.contains("502") || lowered.contains("503") || lowered.contains("5xx") {
            return "中转暂时不可用"
        }
        return "未通过连通测试，条目不会参与链路"
    }
}

@MainActor
private final class SentinelNotifier {
    private var priorStates: [String: LineState]?
    private var priorAIOCircuits: [Int64: Bool]?
    private var priorLowBalanceProviders: Set<Int64>?
    private var hasAIOBaseline = false

    func requestAuthorization() {
        guard !ProcessInfo.processInfo.arguments.contains(CortexSentinelBarMain.smokeWindowArgument),
              let center = notificationCenter
        else {
            return
        }
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func observe(lines: [LineStatus], aio: AIOSnapshot, registry: CodexLineRegistry) {
        let activeLines = lines.filter { $0.isActive(now: Date()) }
        let nextStates = Dictionary(uniqueKeysWithValues: activeLines.map { ($0.id, $0.state) })
        if let priorStates {
            for line in activeLines where line.state.isCritical && priorStates[line.id]?.isCritical != true {
                let label = registry.registration(for: line.slug)?.labelZH ?? line.slug
                send(
                    title: "派工线状态变化",
                    body: "\(label) 进入 \(line.state.displayName)"
                )
            }
        }

        let nextCircuits = Dictionary(
            uniqueKeysWithValues: aio.providers.map { ($0.id, $0.circuitState.isOpen) }
        )
        let nextLowBalance = Set(
            aio.providers.filter(\.isLowBalance).map(\.id)
        )
        if hasAIOBaseline, aio.sourceState == .available {
            for provider in aio.providers
            where provider.circuitState.isOpen && priorAIOCircuits?[provider.id] != true {
                send(
                    title: "AIO 熔断提醒",
                    body: "\(provider.name) 熔断已打开"
                )
            }
            for provider in aio.providers
            where provider.isLowBalance && priorLowBalanceProviders?.contains(provider.id) != true {
                send(
                    title: "AIO 余额提醒",
                    body: "\(provider.name) 余额低于 $\(String(format: "%.0f", AIOConstants.lowBalanceThreshold))"
                )
            }
        }

        priorStates = nextStates
        if aio.sourceState == .available {
            priorAIOCircuits = nextCircuits
            priorLowBalanceProviders = nextLowBalance
            hasAIOBaseline = true
        }
    }

    private func send(title: String, body: String) {
        guard let center = notificationCenter else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "cortex-sentinel-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil
        else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }
}
