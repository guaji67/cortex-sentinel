import AppKit
import Foundation

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
    @Published private(set) var isOfficialUsageRefreshing = false
    @Published private(set) var isOfficialUsageRefreshCoolingDown = false
    @Published private(set) var loginItemPresentation: LoginItemPanelPresentation = .disabled
    @Published private(set) var paths: SentinelPaths
    @Published private(set) var watchDirectorySource: WatchDirectoryResolution.Source
    let settingsModel: SentinelSettingsModel
    private(set) var historyRetainCount: Int

    var isWatchDirectoryLocked: Bool {
        watchDirectorySource.isLockedByEnvironment
    }

    var loginItemSettingsPresentation: LoginItemSettingsPresentation {
        LoginItemSettingsPresentation.make(
            signals: LaunchdSupervisionProbe.collectFromCurrentProcess().signals,
            wantsEnabled: SentinelSettings.loginItemEnabled(defaults: defaults)
        )
    }

    private let defaults: UserDefaults
    private let environment: [String: String]
    private let notifier: SentinelNotifier
    private let loginItemRegistrar: any LoginItemRegistrar
    private let lineRegistryCache: CodexLineRegistryCache
    private let otherCodexProcessReader: (Set<Int>) -> [OtherCodexProcess]
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

    init(
        paths: SentinelPaths? = nil,
        loginItemRegistrar: any LoginItemRegistrar = SMAppServiceLoginItemRegistrar(),
        defaults: UserDefaults = SentinelSettings.resolvedDefaults(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        lineRegistryCache: CodexLineRegistryCache = CodexLineRegistryCache(),
        otherCodexProcessReader: @escaping (Set<Int>) -> [OtherCodexProcess] = {
            OtherCodexProcessReader.read(excluding: $0)
        }
    ) {
        self.defaults = defaults
        self.environment = environment
        self.otherCodexProcessReader = otherCodexProcessReader
        let resolvedPaths = paths ?? SentinelPaths.discover(
            environment: environment,
            defaults: defaults
        )
        self.paths = resolvedPaths
        let watchSource = WatchDirectoryResolution.resolve(
            environment: environment,
            defaults: defaults
        ).source
        self.watchDirectorySource = watchSource
        self.historyRetainCount = SentinelSettings.historyRetainCount(defaults: defaults)
        self.loginItemRegistrar = loginItemRegistrar
        self.notifier = SentinelNotifier()
        self.lineRegistryCache = lineRegistryCache
        let settingsModel = SentinelSettingsModel(
            defaults: defaults,
            loginItem: LoginItemSettingsPresentation.make(
                signals: LaunchdSupervisionProbe.collectFromCurrentProcess().signals,
                wantsEnabled: SentinelSettings.loginItemEnabled(defaults: defaults)
            ),
            historyRetainCount: self.historyRetainCount,
            preferences: SentinelNotifyPreferences.load(defaults: defaults),
            watchPath: resolvedPaths.logsDirectory.path,
            isWatchLocked: watchSource.isLockedByEnvironment
        )
        self.settingsModel = settingsModel
        settingsModel.applyLoginItem = { [weak self] enabled in
            self?.setLoginItemEnabled(enabled)
        }
        settingsModel.applyHistoryRetainCount = { [weak self] value in
            self?.setHistoryRetainCount(value)
        }
        settingsModel.chooseWatchDirectory = { [weak self] in
            self?.chooseWatchDirectory()
        }
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
        reconcileLoginItem()
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

    func enableLoginItem() {
        setLoginItemEnabled(true)
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        let signals = LaunchdSupervisionProbe.collectFromCurrentProcess().signals
        if signals.isLaunchdManaged {
            loginItemPresentation = .systemManaged
            settingsModel.loginItem = loginItemSettingsPresentation
            return
        }
        SentinelSettings.setLoginItemEnabled(enabled, defaults: defaults)
        let plan = LoginItemReconciler.plan(
            signals: signals,
            status: loginItemRegistrar.status,
            wantsEnabled: enabled
        )
        guard LoginItemRuntime.shouldReconcileOnLaunch() else {
            loginItemPresentation = plan.presentation
            settingsModel.loginItem = loginItemSettingsPresentation
            return
        }
        loginItemPresentation = LoginItemReconciler.apply(
            plan: plan,
            registrar: loginItemRegistrar
        )
        settingsModel.loginItem = loginItemSettingsPresentation
    }

    func setHistoryRetainCount(_ value: Int) {
        SentinelSettings.setHistoryRetainCount(value, defaults: defaults)
        historyRetainCount = SentinelSettings.historyRetainCount(defaults: defaults)
        settingsModel.historyRetainCount = historyRetainCount
        runLogCleanup()
    }

    func setNotifyOnTaskComplete(_ enabled: Bool) {
        settingsModel.setNotifyMasterEnabled(enabled)
    }

    func setWatchDirectory(_ url: URL) {
        guard !isWatchDirectoryLocked else {
            return
        }
        SentinelSettings.setWatchDirectory(url, defaults: defaults)
        applyResolvedPaths()
        settingsModel.watchPath = paths.logsDirectory.path
        settingsModel.isWatchLocked = isWatchDirectoryLocked
        refreshAll()
        runLogCleanup()
    }

    func chooseWatchDirectory() {
        guard !isWatchDirectoryLocked else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = SentinelSettingsCopy.watchChoose
        panel.directoryURL = paths.logsDirectory
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        setWatchDirectory(url)
    }

    func openSettings() {
        settingsModel.loginItem = loginItemSettingsPresentation
        settingsModel.watchPath = paths.logsDirectory.path
        settingsModel.isWatchLocked = isWatchDirectoryLocked
        SentinelSettingsWindowController.shared.show(model: settingsModel)
    }

    private func applyResolvedPaths() {
        let resolved = WatchDirectoryResolution.resolve(
            environment: environment,
            defaults: defaults
        )
        paths = SentinelPaths.discover(environment: environment, defaults: defaults)
        watchDirectorySource = resolved.source
    }

    private func reconcileLoginItem() {
        let details = LaunchdSupervisionProbe.collectFromCurrentProcess()
        let plan = LoginItemReconciler.plan(
            signals: details.signals,
            status: loginItemRegistrar.status,
            wantsEnabled: SentinelSettings.loginItemEnabled(defaults: defaults)
        )
        guard LoginItemRuntime.shouldReconcileOnLaunch() else {
            loginItemPresentation = plan.presentation
            return
        }
        loginItemPresentation = LoginItemReconciler.apply(
            plan: plan,
            registrar: loginItemRegistrar
        )
    }

    private func runLogCleanup() {
        let logsDirectory = paths.logsDirectory
        let registryURL = paths.lineRegistryURL
        let registryCache = lineRegistryCache
        let cap = historyRetainCount
        Task.detached(priority: .utility) {
            let registry = registryCache.read(at: registryURL)
            // 先按条数清状态文件，再跑体积清理：刚失去 status 的派工日志
            // 若已静默超时，同一轮就能被 LogCleaner 当成孤儿收掉。
            StatusFileCleaner.run(
                logsDirectory: logsDirectory,
                registry: registry,
                dryRun: false,
                cap: cap
            )
            LogCleaner.run(logsDirectory: logsDirectory, dryRun: false)
        }
    }

    func refreshAll() {
        let updatedLines = SentinelFileReader.readLines(in: paths.logsDirectory)
        let registry = lineRegistryCache.read(at: paths.lineRegistryURL)
        apply(
            lines: updatedLines,
            aio: aio,
            otherCodexProcesses: readOtherCodexProcesses(excluding: updatedLines),
            lineRegistry: registry,
            inputStatus: inputStatus
        )
        refreshAIO(force: true, includeUsage: false)
        refreshInputStatus(force: true)
        refreshOfficialUsage(reason: .startup)
        refreshChannelStatus()
        refreshUnclaimed(lines: updatedLines, registry: registry)
    }

    func refreshStatuses() {
        let updatedLines = SentinelFileReader.readLines(in: paths.logsDirectory)
        let registry = lineRegistryCache.read(at: paths.lineRegistryURL)
        apply(
            lines: updatedLines,
            aio: aio,
            otherCodexProcesses: readOtherCodexProcesses(excluding: updatedLines),
            lineRegistry: registry,
            inputStatus: inputStatus
        )
        refreshChannelStatus()
        refreshUnclaimed(lines: updatedLines, registry: registry)
    }

    private func refreshChannelStatus() {
        let next = SentinelFileReader.readChannelStatus(at: paths.channelStatusURL)
        if channelStatus != next {
            channelStatus = next
        }
    }

    private func refreshUnclaimed(lines: [LineStatus], registry: CodexLineRegistry) {
        let ack = SentinelFileReader.readTerminalAck(at: paths.lineTerminalAckURL)
        let next = UnclaimedTerminalAggregation.entries(
            lines: lines,
            registry: registry,
            ack: ack
        )
        if unclaimedTerminals != next {
            unclaimedTerminals = next
        }
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
                self.setOfficialUsageIfChanged(snapshot)
            case let .failure(error):
                self.setOfficialUsageIfChanged(
                    self.officialUsage.preservingLastSuccess(
                        errorMessage: error.userMessage,
                        failedAt: Date()
                    )
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
            let minimumInterval = force
                ? AIOConstants.manualRefreshThrottle
                : InputStatusRefreshPolicy.automaticInterval(
                    panelPresented: isPanelPresented
                )
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

    func apply(
        lines: [LineStatus],
        aio: AIOSnapshot,
        otherCodexProcesses: [OtherCodexProcess],
        lineRegistry: CodexLineRegistry,
        inputStatus: InputStatusSnapshot
    ) {
        notifier.observe(
            lines: lines,
            aio: aio,
            registry: lineRegistry,
            preferences: settingsModel.preferences
        )
        if self.lines != lines {
            self.lines = lines
        }
        if self.aio != aio {
            self.aio = aio
        }
        if self.otherCodexProcesses != otherCodexProcesses {
            self.otherCodexProcesses = otherCodexProcesses
        }
        if self.lineRegistry != lineRegistry {
            self.lineRegistry = lineRegistry
        }
        if self.inputStatus != inputStatus {
            self.inputStatus = inputStatus
        }
        relayRecoveryCoordinator.requestEligibleProbes(
            lines: lines,
            aio: aio,
            inputStatus: inputStatus,
            logsDirectory: paths.logsDirectory
        )
    }

    func setOfficialUsageIfChanged(_ snapshot: OfficialUsageSnapshot) {
        if officialUsage != snapshot {
            officialUsage = snapshot
        }
    }

    func emitStatusRefreshPublicationsForTests() {
        lines = lines
        aio = aio
        otherCodexProcesses = otherCodexProcesses
        lineRegistry = lineRegistry
        inputStatus = inputStatus
        channelStatus = channelStatus
        unclaimedTerminals = unclaimedTerminals
        officialUsage = officialUsage
    }

    private func readOtherCodexProcesses(excluding lines: [LineStatus]) -> [OtherCodexProcess] {
        let managedProcessIDs = Set(lines.compactMap(\.processID))
        return otherCodexProcessReader(managedProcessIDs)
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
