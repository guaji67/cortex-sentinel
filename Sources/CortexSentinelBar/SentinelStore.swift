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
    @Published private(set) var backgroundJobs: BackgroundJobsSnapshot = .missing
    /// Cortex 打包进度；没打包在跑时保持 nil，界面不占地方。
    @Published private(set) var packagingProgress: PackagingProgressSnapshot?
    /// 私有腿的 launchctl 操作行；健康快照仍由 `backgroundJobs` 保留给 PR 展示模型。
    @Published private(set) var backgroundJobRows: [BackgroundJobRow] = []
    @Published private(set) var backgroundJobMessages: [String: String] = [:]
    @Published private(set) var backgroundJobOperations: Set<String> = []
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
    private let lineStatusCache: LineStatusFileCache
    private let otherCodexProcessReader: @Sendable (Set<Int>) -> [OtherCodexProcess]
    private let now: @Sendable () -> Date
    private let aioUsageClient: AIOUsageClient
    private let launchctlRunner: any LaunchctlRunning
    private let disabledJobsStore: DisabledJobsStore
    private let fileManager: FileManager
    private let launchctlUID: Int32
    private var statusTimer: Timer?
    private var aioTimer: Timer?
    private var inputStatusTimer: Timer?
    private var officialUsageTimer: Timer?
    private var cleanupTimer: Timer?
    private var aioRefreshInFlight = false
    private var aioRefreshIncludesUsage = false
    private var inputStatusRefreshInFlight = false
    private var lastAIORefreshAt: Date?
    private var lastAIOUsageRefreshAt: Date?
    private var lastDisabledAIOUsageRefreshAt: Date?
    private var lastInputStatusRefreshAt: Date?
    private var lastOfficialUsageAttemptAt: Date?
    private var lastPanelOpenFullRefreshAt: Date?
    private var hasStarted = false
    private var isPanelPresented = false
    private var pendingAIOUsageRefresh = false
    private var relayRecoveryCoordinator = RelayRecoveryProbeCoordinator()
    private(set) var statusDiskRefreshCountForTests = 0
    private(set) var aioUsageRefreshCountForTests = 0
    private(set) var inputStatusRefreshCountForTests = 0
    private(set) var officialUsageRefreshCountForTests = 0
    private(set) var lastStatusDiskReadWasOnMainThreadForTests = false
    private(set) var scheduledStatusTimerInterval: TimeInterval = 0

    init(
        paths: SentinelPaths? = nil,
        loginItemRegistrar: any LoginItemRegistrar = SMAppServiceLoginItemRegistrar(),
        defaults: UserDefaults = SentinelSettings.resolvedDefaults(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        lineRegistryCache: CodexLineRegistryCache = CodexLineRegistryCache(),
        lineStatusCache: LineStatusFileCache = LineStatusFileCache(),
        otherCodexProcessReader: @escaping @Sendable (Set<Int>) -> [OtherCodexProcess] = {
            OtherCodexProcessReader.read(excluding: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        aioUsageClient: AIOUsageClient = AIOUsageClient(),
        notificationSendHandler: ((SentinelNotificationDraft) -> Void)? = nil,
        launchctlRunner: any LaunchctlRunning = ProcessLaunchctlRunner(),
        fileManager: FileManager = .default,
        disabledJobsURL: URL? = nil,
        launchctlUID: Int32 = Int32(getuid())
    ) {
        self.defaults = defaults
        self.environment = environment
        self.otherCodexProcessReader = otherCodexProcessReader
        self.now = now
        self.aioUsageClient = aioUsageClient
        self.launchctlRunner = launchctlRunner
        self.fileManager = fileManager
        self.launchctlUID = launchctlUID
        let resolvedPaths = paths ?? SentinelPaths.discover(
            environment: environment,
            defaults: defaults
        )
        self.paths = resolvedPaths
        self.disabledJobsStore = DisabledJobsStore(
            url: disabledJobsURL ?? resolvedPaths.disabledJobsURL,
            fileManager: fileManager
        )
        let watchSource = WatchDirectoryResolution.resolve(
            environment: environment,
            defaults: defaults
        ).source
        self.watchDirectorySource = watchSource
        self.historyRetainCount = SentinelSettings.historyRetainCount(defaults: defaults)
        self.loginItemRegistrar = loginItemRegistrar
        self.notifier = SentinelNotifier()
        self.notifier.sendHandler = notificationSendHandler
        self.lineRegistryCache = lineRegistryCache
        self.lineStatusCache = lineStatusCache
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
        settingsModel.applyRefreshIntervals = { [weak self] in
            self?.rescheduleStatusTimer()
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
        var sections: [String] = []
        if packagingProgress?.isActive == true, let packagingProgress {
            sections.append(packagingProgress.accessibilityText)
        }
        let probes = inputStatus.displayProbes()
        let serviceText = probes.map { display in
            let latency = display.probe.latencyMilliseconds.map { " · \($0) 毫秒" } ?? ""
            return "\(display.probe.model)：\(display.state.displayName)\(latency)"
        }
        .joined(separator: "\n")
        if !serviceText.isEmpty {
            sections.append(serviceText)
        }
        return sections.isEmpty ? "服务状态暂无数据" : sections.joined(separator: "\n")
    }

    var watchDirectoryMissing: Bool {
        !paths.logsDirectoryExists
    }

    var statusBarAccessibilityLabel: String {
        let packaging = packagingProgress?.isActive == true
            ? [packagingProgress!.accessibilityText]
            : []
        let states = inputStatus.displayProbes().map {
            "\($0.probe.model)\($0.state.displayName)"
        }
        let balances = statusBarBalances.map {
            "\($0.providerName) 余额 \($0.text)"
        }
        return (packaging + states + balances).joined(separator: "，")
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        reconcileLoginItem()
        notifier.requestAuthorization()
        Task { @MainActor [weak self] in
            await self?.refreshAll()
        }

        scheduleStatusTimer()
        aioTimer = Timer.scheduledTimer(
            withTimeInterval: AIOConstants.aioRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.refreshAIO(force: false, includeUsage: self.isPanelPresented)
            }
        }
        inputStatusTimer = Timer.scheduledTimer(
            withTimeInterval: InputStatusConstants.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshInputStatus(force: false)
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
        Task { await self.refreshAll() }
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

    func statusPollInterval() -> TimeInterval {
        isPanelPresented
            ? SentinelSettings.panelOpenRefreshInterval(defaults: defaults).rawValue
            : SentinelSettings.panelClosedRefreshInterval(defaults: defaults).rawValue
    }

    private func rescheduleStatusTimer() {
        scheduleStatusTimer()
    }

    private func scheduleStatusTimer() {
        guard hasStarted else {
            return
        }
        statusTimer?.invalidate()
        let interval = statusPollInterval()
        scheduledStatusTimerInterval = interval
        statusTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshStatuses()
            }
        }
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

    func refreshAll() async {
        await refreshStatuses()
        await refreshAIO(force: true, includeUsage: false)
        await refreshInputStatus(force: true)
        refreshOfficialUsage(reason: .startup)
    }

    func refreshStatuses() async {
        statusDiskRefreshCountForTests += 1
        let logsDirectory = paths.logsDirectory
        let registryURL = paths.lineRegistryURL
        let channelStatusURL = paths.channelStatusURL
        let ackURL = paths.lineTerminalAckURL
        let packagingProgressRoot = paths.packagingProgressRoot
        let lineStatusCache = lineStatusCache
        let lineRegistryCache = lineRegistryCache
        let includeOtherProcesses = isPanelPresented
        let reader = otherCodexProcessReader
        let env = environment
        let snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = StatusDiskReader.load(
                    logsDirectory: logsDirectory,
                    registryURL: registryURL,
                    channelStatusURL: channelStatusURL,
                    ackURL: ackURL,
                    packagingProgressRoot: packagingProgressRoot,
                    lineStatusCache: lineStatusCache,
                    lineRegistryCache: lineRegistryCache,
                    includeOtherProcesses: includeOtherProcesses,
                    otherCodexProcessReader: reader,
                    environment: env
                )
                continuation.resume(returning: loaded)
            }
        }
        lastStatusDiskReadWasOnMainThreadForTests = snapshot.readOnMainThread
        // 失败/完成的 progress.json 只是历史残留，界面不展示；不要把它
        // 发布成一次状态变化，避免每轮空转给菜单栏再发一条通知。
        let nextPackagingProgress = snapshot.packagingProgress?.isActive == true
            ? snapshot.packagingProgress
            : nil
        if packagingProgress != nextPackagingProgress {
            packagingProgress = nextPackagingProgress
        }
        apply(
            lines: snapshot.lines,
            aio: aio,
            otherCodexProcesses: snapshot.otherCodexProcesses ?? otherCodexProcesses,
            lineRegistry: snapshot.registry,
            inputStatus: inputStatus
        )
        if channelStatus != snapshot.channelStatus {
            channelStatus = snapshot.channelStatus
        }
        if backgroundJobs != snapshot.backgroundJobs {
            backgroundJobs = snapshot.backgroundJobs
        }
        let nextBackgroundJobRows = BackgroundJobsPresentation.merge(
            jobs: snapshot.backgroundJobs.jobs,
            disabledLabels: disabledJobsStore.read()
        )
        if backgroundJobRows != nextBackgroundJobRows {
            backgroundJobRows = nextBackgroundJobRows
        }
        refreshUnclaimed(lines: snapshot.lines, registry: snapshot.registry, ack: snapshot.ack)
    }

    private func refreshUnclaimed(
        lines: [LineStatus],
        registry: CodexLineRegistry,
        ack: TerminalAckLedger
    ) {
        let next = UnclaimedTerminalAggregation.entries(
            lines: lines,
            registry: registry,
            ack: ack
        )
        if unclaimedTerminals != next {
            unclaimedTerminals = next
        }
    }

    func refreshBackgroundJobs() {
        let snapshot = BackgroundJobsReader.read(at: paths.backgroundJobsHealthURL, fileManager: fileManager)
        backgroundJobs = snapshot
        backgroundJobRows = BackgroundJobsPresentation.merge(
            jobs: snapshot.jobs,
            disabledLabels: disabledJobsStore.read()
        )
    }

    func disableBackgroundJob(_ label: String) {
        runBackgroundJobOperation(label) { [launchctlRunner, launchctlUID] in
            let bootout = await launchctlRunner.run(arguments: LaunchctlCommandBuilder.bootout(uid: launchctlUID, label: label))
            guard bootout.succeeded else { throw BackgroundJobOperationFailure(message: BackgroundJobOperationFailure.message(action: "关闭", result: bootout)) }
            let disable = await launchctlRunner.run(arguments: LaunchctlCommandBuilder.disable(uid: launchctlUID, label: label))
            guard disable.succeeded else { throw BackgroundJobOperationFailure(message: BackgroundJobOperationFailure.message(action: "写入关闭设置", result: disable)) }
        } onSuccess: { [weak self] in
            guard let self else { return }
            do { _ = try self.disabledJobsStore.adding(label); self.backgroundJobMessages[label] = nil }
            catch { self.backgroundJobMessages[label] = "已关闭，但本地记录写入失败：\(error.localizedDescription)" }
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
            let enable = await launchctlRunner.run(arguments: LaunchctlCommandBuilder.enable(uid: launchctlUID, label: label))
            guard enable.succeeded else { throw BackgroundJobOperationFailure(message: BackgroundJobOperationFailure.message(action: "开启", result: enable)) }
            let bootstrap = await launchctlRunner.run(arguments: LaunchctlCommandBuilder.bootstrap(uid: launchctlUID, plistURL: plistURL))
            guard bootstrap.succeeded else { throw BackgroundJobOperationFailure(message: BackgroundJobOperationFailure.message(action: "加载", result: bootstrap)) }
        } onSuccess: { [weak self] in
            guard let self else { return }
            do { _ = try self.disabledJobsStore.removing(label); self.backgroundJobMessages[label] = nil }
            catch { self.backgroundJobMessages[label] = "已开启，但本地记录更新失败：\(error.localizedDescription)" }
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
            do { try await operation(); onSuccess() }
            catch let failure as BackgroundJobOperationFailure { self.backgroundJobMessages[label] = failure.message }
            catch { self.backgroundJobMessages[label] = "操作失败：\(error.localizedDescription)" }
            self.backgroundJobOperations.remove(label)
            self.refreshBackgroundJobs()
        }
    }

    func refreshRelays() {
        Task { await refreshAIO(force: true, includeUsage: true) }
    }

    func setPanelPresented(_ presented: Bool) async {
        guard isPanelPresented != presented else {
            return
        }
        isPanelPresented = presented
        rescheduleStatusTimer()
        guard presented else {
            return
        }
        await refreshOnPanelOpenIfNeeded()
    }

    private func refreshOnPanelOpenIfNeeded() async {
        let timestamp = now()
        let interval = SentinelSettings.balanceRecheckInterval(defaults: defaults).rawValue
        guard PanelBalanceRefreshPolicy.shouldRefresh(
            lastRefreshAt: lastPanelOpenFullRefreshAt,
            now: timestamp,
            interval: interval
        ) else {
            return
        }
        lastPanelOpenFullRefreshAt = timestamp
        await refreshStatuses()
        await refreshAIO(force: true, includeUsage: true, bypassMinimumInterval: true)
        await refreshInputStatus(force: true, bypassMinimumInterval: true)
        refreshOfficialUsage(reason: .panelOpen, bypassMinimumInterval: true)
    }

    func refreshOfficialUsageManually() {
        refreshOfficialUsage(reason: .manual)
    }

    private func refreshOfficialUsage(
        reason: OfficialUsageRefreshReason,
        bypassMinimumInterval: Bool = false
    ) {
        let timestamp = self.now()
        if isOfficialUsageRefreshing {
            return
        }
        if !bypassMinimumInterval {
            guard OfficialUsageRefreshPolicy.shouldStart(
                reason: reason,
                lastAttemptAt: lastOfficialUsageAttemptAt,
                isInFlight: isOfficialUsageRefreshing,
                now: timestamp,
                panelOpenInterval: SentinelSettings.balanceRecheckInterval(defaults: defaults).rawValue
            ) else {
                return
            }
        }

        officialUsageRefreshCountForTests += 1
        isOfficialUsageRefreshing = true
        lastOfficialUsageAttemptAt = timestamp
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

    func refreshAIO(
        force: Bool,
        includeUsage: Bool,
        bypassMinimumInterval: Bool = false
    ) async {
        let timestamp = self.now()
        if aioRefreshInFlight {
            if includeUsage && !aioRefreshIncludesUsage {
                pendingAIOUsageRefresh = true
            }
            return
        }
        let relevantLastRefreshAt = includeUsage ? lastAIOUsageRefreshAt : lastAIORefreshAt
        if !bypassMinimumInterval, let relevantLastRefreshAt {
            let elapsed = timestamp.timeIntervalSince(relevantLastRefreshAt)
            let minimumInterval = force
                ? AIOConstants.manualRefreshThrottle
                : AIOConstants.aioRefreshInterval
            if elapsed < minimumInterval {
                return
            }
        }

        aioRefreshInFlight = true
        aioRefreshIncludesUsage = includeUsage
        lastAIORefreshAt = timestamp
        if includeUsage {
            lastAIOUsageRefreshAt = timestamp
            aioUsageRefreshCountForTests += 1
        }
        let includeDisabledUsage = includeUsage
            && AIOUsageRefreshPolicy.shouldRefreshDisabledUsage(
                lastRefreshAt: lastDisabledAIOUsageRefreshAt,
                now: timestamp
            )
        let databaseURL = paths.aioDatabaseURL
        let manifestURL = paths.aioManifestURL
        let configURL = paths.codexConfigURL
        let cachedUsage = Dictionary(
            uniqueKeysWithValues: aio.providers.map { ($0.id, $0.usage) }
        )
        let usageClient = aioUsageClient

        let base = await Task.detached {
            AIODataReader.read(
                databaseURL: databaseURL,
                manifestURL: manifestURL,
                configURL: configURL
            )
        }.value

        let attemptedDisabledUsage: Bool
        let snapshot: AIOSnapshot
        if base.sourceState != .available {
            snapshot = base
            attemptedDisabledUsage = false
        } else if !includeUsage {
            snapshot = base.replacingUsage(cachedUsage)
            attemptedDisabledUsage = false
        } else {
            let usageTargets = await Task.detached {
                AIODataReader.readUsageTargets(databaseURL: databaseURL)
            }.value
            attemptedDisabledUsage = includeDisabledUsage
                && base.providers.contains {
                    !$0.enabled && !$0.isOfficialOAuthProvider
                }
            snapshot = await refreshUsageConcurrently(
                base: base,
                cachedUsage: cachedUsage,
                targets: usageTargets,
                includeDisabled: includeDisabledUsage,
                client: usageClient
            )
        }

        aioRefreshInFlight = false
        aioRefreshIncludesUsage = false
        if attemptedDisabledUsage {
            lastDisabledAIOUsageRefreshAt = timestamp
        }
        apply(
            lines: lines,
            aio: snapshot,
            otherCodexProcesses: otherCodexProcesses,
            lineRegistry: lineRegistry,
            inputStatus: inputStatus
        )
        if pendingAIOUsageRefresh {
            pendingAIOUsageRefresh = false
            if isPanelPresented {
                await refreshAIO(force: true, includeUsage: true)
            }
        }
    }

    private func refreshUsageConcurrently(
        base: AIOSnapshot,
        cachedUsage: [Int64: AIOUsageStatus],
        targets: [AIOUsageTarget],
        includeDisabled: Bool,
        client: AIOUsageClient
    ) async -> AIOSnapshot {
        let ordered = PanelBalanceRefreshPolicy.sequentialTargets(
            providers: base.providers,
            targets: targets,
            includeDisabled: includeDisabled
        )
        var cached = cachedUsage
        var loading = cached
        for target in ordered {
            loading[target.id] = .loading
        }
        apply(
            lines: lines,
            aio: base.replacingUsage(loading),
            otherCodexProcesses: otherCodexProcesses,
            lineRegistry: lineRegistry,
            inputStatus: inputStatus
        )

        await withTaskGroup(of: (Int64, AIOUsageStatus).self) { group in
            for target in ordered {
                group.addTask {
                    (target.id, await client.fetch(target: target))
                }
            }
            for await (providerID, status) in group {
                cached = AIOUsageRefreshPolicy.merge(
                    cached: cached,
                    fresh: [providerID: status],
                    providers: base.providers
                )
                apply(
                    lines: lines,
                    aio: base.replacingUsage(cached),
                    otherCodexProcesses: otherCodexProcesses,
                    lineRegistry: lineRegistry,
                    inputStatus: inputStatus
                )
            }
        }
        return base.replacingUsage(cached)
    }

    private func refreshInputStatus(force: Bool, bypassMinimumInterval: Bool = false) async {
        let timestamp = self.now()
        if inputStatusRefreshInFlight {
            return
        }
        if !bypassMinimumInterval, let lastInputStatusRefreshAt {
            let elapsed = timestamp.timeIntervalSince(lastInputStatusRefreshAt)
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
        lastInputStatusRefreshAt = timestamp
        inputStatusRefreshCountForTests += 1
        let client = InputStatusClient(endpoint: paths.inputStatusURL)

        let result: Result<InputStatusSnapshot, InputStatusClientError>
        do {
            result = .success(try await client.fetch())
        } catch let error as InputStatusClientError {
            result = .failure(error)
        } catch {
            result = .failure(.network)
        }

        inputStatusRefreshInFlight = false
        let snapshot: InputStatusSnapshot
        switch result {
        case let .success(value):
            snapshot = value
        case let .failure(error):
            snapshot = inputStatus.preservingData(withError: error.userMessage)
        }
        apply(
            lines: lines,
            aio: aio,
            otherCodexProcesses: otherCodexProcesses,
            lineRegistry: lineRegistry,
            inputStatus: snapshot
        )
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
        backgroundJobs = backgroundJobs
        backgroundJobRows = backgroundJobRows
        packagingProgress = packagingProgress
        unclaimedTerminals = unclaimedTerminals
        officialUsage = officialUsage
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
