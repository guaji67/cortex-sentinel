import AppKit
import Foundation
import Observation

/// 面板数据源。2026-08-24 从 ObservableObject/@Published 迁到 @Observable：
/// 旧形态下任何一个 @Published 变化都会给唯一的整面板 view 发 objectWillChange，
/// 整个 1798 行的 body 重算一遍（Falcon 量到冷开 22 次、每 5 秒一次 324-389ms 主线程
/// hang）。Observation 按「哪个 view 读了哪个属性」决定失效范围，配合面板按分区拆开，
/// 余额回来只惊动余额那一块，线列表在他滑动时保持安静。
@Observable
@MainActor
final class SentinelStore {
    private(set) var lines: [LineStatus] = []
    private(set) var otherCodexProcesses: [OtherCodexProcess] = []
    private(set) var aio: AIOSnapshot = .unconfigured
    private(set) var lineRegistry: CodexLineRegistry = .empty
    /// 分组和使用者实际看板窗口随状态快照每轮计算一次；菜单 body 只读缓存。
    /// 旧口径（@Published 时代）这两个派生属性从不自己发 objectWillChange；
    /// Observation 下它们各自通知自己的读者，这正是分区隔离要的形态。
    private(set) var lineGroups: SentinelLineGroups = .empty
    private(set) var boardWindow: SentinelBoardWindow = .empty
    /// 线行通道归因用的 AIO 切片；只在路由/网关/命中/名单真变时更新，
    /// 让线列表分区不用跟着余额刷新（readAt 每轮都变）一起失效。
    private(set) var relayAttribution: RelayAttributionContext = .unconfigured
    private(set) var inputStatus: InputStatusSnapshot = .empty
    private(set) var officialUsage: OfficialUsageSnapshot = .empty
    /// Cursor 订阅余额（模式/API/Bot 三组一行显示）；跟随官方额度同一套刷新时机。
    private(set) var cursorUsage: CursorUsageSnapshot = .empty
    private(set) var channelStatus: ChannelStatusSnapshot = .missing
    private(set) var backgroundJobs: BackgroundJobsSnapshot = .missing
    /// Cortex 打包进度；没打包在跑时保持 nil，界面不占地方。
    private(set) var packagingProgress: PackagingProgressSnapshot?
    /// 只在 running / 非 running 之间翻转。面板父 body 靠它决定要不要挂载打包分区，
    /// 避免 LazyVStack 里 EmptyView 在隐藏 NSPopover 里丢掉从无到有的失效。
    private(set) var packagingActive = false
    /// 每次把面板打开加一。隐藏的 NSHostingView 不调度 Observation 更新
    /// （设置窗对照测试已踩过）；打开时父 body 必须重新求值，按当前 store 挂载分区。
    private(set) var panelPresentationGeneration: UInt = 0
    /// 状态栏三个面的合成快照。控制器只观察这一份，不再自己拼 Optional 读集。
    private(set) var statusBarRenderState = StatusBarRenderState()
    /// 私有腿的 launchctl 操作行；健康快照仍由 `backgroundJobs` 保留给 PR 展示模型。
    private(set) var backgroundJobRows: [BackgroundJobRow] = []
    private(set) var backgroundJobMessages: [String: String] = [:]
    private(set) var backgroundJobOperations: Set<String> = []
    /// 后台任务整块是否展开。默认收起，只留一行摘要；用户点开的选择要跨次打开面板记住。
    private(set) var backgroundJobsExpanded: Bool
    private(set) var unclaimedTerminals: [UnclaimedTerminalEntry] = []
    /// 只有他自己点刷新按钮时才为真。面板打开时的自动刷新**不点亮**它——
    /// Falcon 2026-08-24：他没点任何东西，界面就不该自己转给他看。
    private(set) var isOfficialUsageRefreshing = false
    /// 真正的并发闸，跟界面无关；不进 Observation，改它不惊动任何 view。
    @ObservationIgnored private var officialUsageFetchInFlight = false
    @ObservationIgnored private var cursorUsageFetchInFlight = false
    @ObservationIgnored private var lastCursorUsageAttemptAt: Date?
    private(set) var isOfficialUsageRefreshCoolingDown = false
    private(set) var loginItemPresentation: LoginItemPanelPresentation = .disabled
    private(set) var paths: SentinelPaths
    private(set) var watchDirectorySource: WatchDirectoryResolution.Source
    /// 本机身份缓存。原来面板 body 里每个 hostBadge 都现调 LocalHostIdentity.current()，
    /// 一次就是一趟 NSHost.localizedName → SCPreferences 读盘解析 XML（Time Profiler
    /// 抓到它躺在主线程 hang 窗口里）。现在开机算一次，之后每轮磁盘刷新在后台线程
    /// 复核，变了才发布。
    private(set) var localHost: LocalHostIdentity = .current()
    let settingsModel: SentinelSettingsModel
    @ObservationIgnored private(set) var historyRetainCount: Int

    var isWatchDirectoryLocked: Bool {
        watchDirectorySource.isLockedByEnvironment
    }

    var loginItemSettingsPresentation: LoginItemSettingsPresentation {
        LoginItemSettingsPresentation.make(
            signals: LaunchdSupervisionProbe.collectFromCurrentProcess().signals,
            wantsEnabled: SentinelSettings.loginItemEnabled(defaults: defaults)
        )
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let notifier: SentinelNotifier
    @ObservationIgnored private let loginItemRegistrar: any LoginItemRegistrar
    @ObservationIgnored private let lineRegistryCache: CodexLineRegistryCache
    @ObservationIgnored private let lineStatusCache: LineStatusFileCache
    @ObservationIgnored private let otherCodexProcessReader: @Sendable (Set<Int>) -> [OtherCodexProcess]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let aioUsageClient: AIOUsageClient
    @ObservationIgnored private let launchctlRunner: any LaunchctlRunning
    @ObservationIgnored private let disabledJobsStore: DisabledJobsStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let launchctlUID: Int32
    /// 滚动期间挂起后台刷新的上屏；见 ScrollPublishGate。用户手动操作不走它。
    @ObservationIgnored let scrollPublishGate = ScrollPublishGate()
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var aioTimer: Timer?
    @ObservationIgnored private var inputStatusTimer: Timer?
    @ObservationIgnored private var officialUsageTimer: Timer?
    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private var aioRefreshInFlight = false
    @ObservationIgnored private var aioRefreshIncludesUsage = false
    @ObservationIgnored private var inputStatusRefreshInFlight = false
    @ObservationIgnored private var lastAIORefreshAt: Date?
    @ObservationIgnored private var lastAIOUsageRefreshAt: Date?
    @ObservationIgnored private var lastDisabledAIOUsageRefreshAt: Date?
    @ObservationIgnored private var lastInputStatusRefreshAt: Date?
    @ObservationIgnored private var lastOfficialUsageAttemptAt: Date?
    @ObservationIgnored private var lastPanelOpenFullRefreshAt: Date?
    @ObservationIgnored private var hasStarted = false
    /// 磁盘读取慢时不排队；定时器或面板打开的下一轮直接跳过。
    @ObservationIgnored private var diskRefreshInFlight = false
    @ObservationIgnored private var isPanelPresented = false
    @ObservationIgnored private var pendingAIOUsageRefresh = false
    @ObservationIgnored private var relayRecoveryCoordinator = RelayRecoveryProbeCoordinator()
    @ObservationIgnored private(set) var statusDiskRefreshCountForTests = 0
    @ObservationIgnored private(set) var aioUsageRefreshCountForTests = 0
    @ObservationIgnored private(set) var inputStatusRefreshCountForTests = 0
    @ObservationIgnored private(set) var officialUsageRefreshCountForTests = 0
    @ObservationIgnored private(set) var lastStatusDiskReadWasOnMainThreadForTests = false
    @ObservationIgnored private(set) var scheduledStatusTimerInterval: TimeInterval = 0

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
        self.backgroundJobsExpanded = SentinelSettings.backgroundJobsExpanded(defaults: defaults)
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
        aioTimer = makeRepeatingTimer(interval: AIOConstants.aioRefreshInterval) { [weak self] in
            guard let self else {
                return
            }
            await self.refreshAIO(force: false, includeUsage: self.isPanelPresented)
        }
        inputStatusTimer = makeRepeatingTimer(interval: InputStatusConstants.refreshInterval) { [weak self] in
            await self?.refreshInputStatus(force: false)
        }
        officialUsageTimer = makeRepeatingTimer(
            interval: OfficialUsageConstants.automaticRefreshInterval
        ) { [weak self] in
            self?.refreshOfficialUsage(reason: .automatic)
            self?.refreshCursorUsage()
        }

        // v3.2 第 5 点：启动即清一次派工日志，之后每小时巡检一次。
        runLogCleanup()
        cleanupTimer = makeRepeatingTimer(interval: LogCleanupConstants.sweepInterval) { [weak self] in
            self?.runLogCleanup()
        }
    }

    func enableLoginItem() {
        setLoginItemEnabled(true)
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        // COR-2550：开机注册唯一由 LaunchAgent 安装器负责，app 侧只保留用户偏好。
        SentinelSettings.setLoginItemEnabled(enabled, defaults: defaults)
        loginItemPresentation = .systemManaged
        settingsModel.loginItem = loginItemSettingsPresentation
    }

    func setBackgroundJobsExpanded(_ value: Bool) {
        SentinelSettings.setBackgroundJobsExpanded(value, defaults: defaults)
        backgroundJobsExpanded = SentinelSettings.backgroundJobsExpanded(defaults: defaults)
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
        loginItemPresentation = details.signals.isLaunchdManaged ? .systemManaged : .disabled
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
        statusTimer = makeRepeatingTimer(interval: interval) { [weak self] in
            await self?.refreshStatuses()
        }
    }

    /// 加到 `.common` 而不是只进 default：菜单栏 tracking / NSPopover 打开时
    /// default mode 定时器会停，关面板的心跳和打开瞬间都会漏拍。
    private func makeRepeatingTimer(
        interval: TimeInterval,
        handler: @escaping @MainActor () async -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                await handler()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
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
        refreshCursorUsage()
    }

    func refreshStatuses() async {
        guard !diskRefreshInFlight else {
            return
        }
        diskRefreshInFlight = true
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
        let (snapshot, refreshedHost) = await withCheckedContinuation { continuation in
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
                // 本机身份复核也放后台线程：NSHost.localizedName 要读
                // SystemConfiguration 的 plist，不许在主线程做。
                continuation.resume(returning: (loaded, LocalHostIdentity.current()))
            }
        }
        diskRefreshInFlight = false
        lastStatusDiskReadWasOnMainThreadForTests = snapshot.readOnMainThread
        scrollPublishGate.publish(surface: .statuses) { [weak self] in
            self?.applyStatusSnapshot(snapshot, refreshedHost: refreshedHost)
        }
    }

    /// 一轮磁盘快照的上屏动作。跨面数据（aio / inputStatus）在**执行时**从 self 读，
    /// 不在闭包创建时捕获——滚动挂起可能让这段延后执行，捕获旧值会把别的面倒退回去。
    private func applyStatusSnapshot(
        _ snapshot: StatusDiskSnapshot,
        refreshedHost: LocalHostIdentity
    ) {
        if localHost != refreshedHost {
            localHost = refreshedHost
        }
        // 失败/完成的 progress.json 只是历史残留，界面不展示；不要把它
        // 发布成一次状态变化，避免每轮空转给菜单栏再发一条通知。
        let nextPackagingProgress = snapshot.packagingProgress?.isActive == true
            ? snapshot.packagingProgress
            : nil
        if packagingProgress != nextPackagingProgress {
            packagingProgress = nextPackagingProgress
        }
        let nextPackagingActive = nextPackagingProgress != nil
        if packagingActive != nextPackagingActive {
            packagingActive = nextPackagingActive
        }
        apply(
            lines: snapshot.lines,
            aio: aio,
            otherCodexProcesses: snapshot.otherCodexProcesses ?? otherCodexProcesses,
            lineRegistry: snapshot.registry,
            inputStatus: inputStatus,
            lineGroups: snapshot.lineGroups,
            boardWindow: snapshot.boardWindow
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
        syncStatusBarRenderState()
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
            // 面板一关，滚动挂起没有意义了；把攒着的上屏立即放行，
            // 下次打开时数据是新的。
            scrollPublishGate.flushNow()
            return
        }
        panelPresentationGeneration += 1
        // 打包进度走磁盘状态刷新，不能跟余额新鲜度闸绑在一起——闸一跳过，
        // 打开面板也看不到正在跑的打包。
        await refreshStatuses()
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
        // 状态文件刚在 setPanelPresented 刷过；这里只补余额和 Input。
        async let aio: Void = refreshAIO(
            force: true,
            includeUsage: true,
            bypassMinimumInterval: true
        )
        async let input: Void = refreshInputStatus(
            force: true,
            bypassMinimumInterval: true
        )
        await aio
        await input
        refreshOfficialUsage(reason: .panelOpen, bypassMinimumInterval: true)
        refreshCursorUsage(bypassMinimumInterval: true)
    }

    func refreshOfficialUsageManually() {
        refreshOfficialUsage(reason: .manual)
        refreshCursorUsage()
    }

    /// Cursor 余额跟着官方额度走同一套时机（启动 / 定时 / 开面板 / 手动点刷新），
    /// 不单独发按钮，失败也不打扰——上一轮的数字原样留着。
    private func refreshCursorUsage(bypassMinimumInterval: Bool = false) {
        let timestamp = self.now()
        guard !cursorUsageFetchInFlight else {
            return
        }
        if !bypassMinimumInterval, let lastCursorUsageAttemptAt {
            let minimumInterval: TimeInterval
            if isPanelPresented {
                minimumInterval = SentinelSettings.balanceRecheckInterval(defaults: defaults).rawValue
            } else {
                minimumInterval = CursorUsageConstants.automaticRefreshInterval
            }
            guard timestamp.timeIntervalSince(lastCursorUsageAttemptAt) >= minimumInterval else {
                return
            }
        }
        cursorUsageFetchInFlight = true
        lastCursorUsageAttemptAt = timestamp
        let client = CursorUsageClient()

        Task { @MainActor [weak self] in
            let result: Result<CursorUsageSnapshot, CursorUsageReaderError>
            do {
                result = .success(try await client.fetch())
            } catch let error as CursorUsageReaderError {
                result = .failure(error)
            } catch {
                result = .failure(.network)
            }

            guard let self else {
                return
            }
            self.cursorUsageFetchInFlight = false
            self.scrollPublishGate.publish(surface: .officialUsage) { [weak self] in
                guard let self else {
                    return
                }
                let snapshot: CursorUsageSnapshot
                switch result {
                case let .success(value):
                    snapshot = value
                case let .failure(error):
                    // 本机没装/没登录 Cursor 就保持空快照，界面不占位。
                    if self.cursorUsage.sourceState == .unconfigured
                        && !self.cursorUsage.hasDisplayableNumber {
                        return
                    }
                    snapshot = self.cursorUsage.preservingLastSuccess(
                        errorMessage: error.userMessage
                    )
                }
                if self.cursorUsage != snapshot {
                    self.cursorUsage = snapshot
                }
            }
        }
    }

    private func refreshOfficialUsage(
        reason: OfficialUsageRefreshReason,
        bypassMinimumInterval: Bool = false
    ) {
        let timestamp = self.now()
        if officialUsageFetchInFlight {
            return
        }
        if !bypassMinimumInterval {
            guard OfficialUsageRefreshPolicy.shouldStart(
                reason: reason,
                lastAttemptAt: lastOfficialUsageAttemptAt,
                isInFlight: officialUsageFetchInFlight,
                now: timestamp,
                panelOpenInterval: SentinelSettings.balanceRecheckInterval(defaults: defaults).rawValue
            ) else {
                return
            }
        }

        officialUsageRefreshCountForTests += 1
        officialUsageFetchInFlight = true
        if reason == .manual {
            isOfficialUsageRefreshing = true
        }
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
            self.officialUsageFetchInFlight = false
            if self.isOfficialUsageRefreshing {
                self.isOfficialUsageRefreshing = false
            }
            self.scrollPublishGate.publish(surface: .officialUsage) { [weak self] in
                guard let self else {
                    return
                }
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
        scrollPublishGate.publish(surface: .aio) { [weak self] in
            self?.applyAIOSnapshot(snapshot)
        }
        if pendingAIOUsageRefresh {
            pendingAIOUsageRefresh = false
            if isPanelPresented {
                await refreshAIO(force: true, includeUsage: true)
            }
        }
    }

    /// AIO 面的上屏动作；其余面在执行时从 self 读，理由同 applyStatusSnapshot。
    private func applyAIOSnapshot(_ snapshot: AIOSnapshot) {
        apply(
            lines: lines,
            aio: snapshot,
            otherCodexProcesses: otherCodexProcesses,
            lineRegistry: lineRegistry,
            inputStatus: inputStatus
        )
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
        // Falcon 2026-08-24 令：「查询中」这个中间态一律不许露面，查完直接换数字。
        //
        // 原来这里干两件事，两件都在他滚动的时候把面板搅得没法用：
        //   1. 先把每个账号的 usage 覆盖成 .loading 再 apply 一次。后果不只是文案闪
        //      一下——每行冒出一个转圈动画，文案从数字变成「查询中」宽度也变；更狠的是
        //      所有账号同时没有数字，BalanceSectionPresentation 会判成 .compact，
        //      **整个余额块从展开塌成一行**，结果回来又弹回展开。面板内容高度在他手指
        //      滑动的过程中一缩一涨，滚动位置被反复夹回去，手感就是「滑不动、卡死」。
        //   2. 每收到一个账号的结果就 apply 一次。N 个账号 = N+1 次整面板刷新，
        //      全挤在他刚点开往下滑的那两秒里。
        //
        // 现在：查询期间原样显示上一次的数字（不写 .loading），全部回来了由调用方
        // apply 一次。数字没变时 apply 内部的相等判断会让这一次刷新连通知都不发。
        var cached = cachedUsage
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
                // 只有这一行本来就没数字可显示时才立刻上屏——那种情况行上写着
                // 「等待查询」，早一点把数字填进去对他有用，而且不会有任何东西被
                // 替换掉。已经有数字的行一律攒到最后一次性换：他滚动时面板不该
                // 被连续 N 次整体刷新，那正是「滑一下卡一下」的来源。
                if cachedUsage[providerID]?.hasDisplayableBalanceNumber != true {
                    let incremental = base.replacingUsage(cached)
                    scrollPublishGate.publish(surface: .aio) { [weak self] in
                        self?.applyAIOSnapshot(incremental)
                    }
                }
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
        scrollPublishGate.publish(surface: .inputStatus) { [weak self] in
            guard let self else {
                return
            }
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
        inputStatus: InputStatusSnapshot,
        lineGroups suppliedLineGroups: SentinelLineGroups? = nil,
        boardWindow suppliedBoardWindow: SentinelBoardWindow? = nil
    ) {
        let lineInputsChanged = self.lines != lines || self.lineRegistry != lineRegistry
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
            let nextAttribution = RelayAttributionContext(aio: aio)
            if relayAttribution != nextAttribution {
                relayAttribution = nextAttribution
            }
        }
        if self.otherCodexProcesses != otherCodexProcesses {
            self.otherCodexProcesses = otherCodexProcesses
        }
        if self.lineRegistry != lineRegistry {
            self.lineRegistry = lineRegistry
        }
        if let suppliedLineGroups {
            // Observation 下派生快照的赋值只惊动读它的分区，不再需要
            // @Published 时代「换 Published 壳不发通知 + 借同值 lines 赋值
            // 触发 UI」那套黑招。
            //
            // 发布门用显示等价而不是逐字段相等：活跃线的 rolloutAgeSeconds
            // 每轮磁盘刷新必变，但同一显示档位内界面一个像素都不会变；
            // 逐字段比较会让线列表分区每 5 秒白白失效一次。raw 的 lines
            // 属性照常更新（上面），内部消费者（通知器、dump）拿到的仍是真值。
            applyDerivedLinePresentationsIfDisplayChanged(
                lineGroups: suppliedLineGroups,
                boardWindow: suppliedBoardWindow
            )
        } else if lineInputsChanged {
            let nextLineGroups = SentinelAggregation.lineGroups(
                lines: lines,
                registry: lineRegistry
            )
            applyDerivedLinePresentationsIfDisplayChanged(
                lineGroups: nextLineGroups,
                boardWindow: SentinelBoardWindow.snapshot(groups: nextLineGroups)
            )
        }
        if self.inputStatus != inputStatus {
            self.inputStatus = inputStatus
        }
        syncStatusBarRenderState()
        relayRecoveryCoordinator.requestEligibleProbes(
            lines: lines,
            aio: aio,
            inputStatus: inputStatus,
            logsDirectory: paths.logsDirectory
        )
    }

    private func applyDerivedLinePresentationsIfDisplayChanged(
        lineGroups nextLineGroups: SentinelLineGroups,
        boardWindow nextBoardWindow: SentinelBoardWindow?
    ) {
        if !lineGroups.isDisplayEquivalent(to: nextLineGroups) {
            lineGroups = nextLineGroups
        }
        if let nextBoardWindow,
           !boardWindow.isDisplayEquivalent(to: nextBoardWindow) {
            boardWindow = nextBoardWindow
        }
    }

    func setOfficialUsageIfChanged(_ snapshot: OfficialUsageSnapshot) {
        if officialUsage != snapshot {
            officialUsage = snapshot
        }
    }

    private func syncStatusBarRenderState() {
        let next = StatusBarRenderState(
            inputStatus: inputStatus,
            aio: aio,
            packagingProgress: packagingProgress
        )
        if statusBarRenderState != next {
            statusBarRenderState = next
        }
    }

    // 旧 emitStatusRefreshPublicationsForTests（把每个 @Published 原值重发一遍）
    // 已删：实测这台 macOS 26 的 Observation 运行时对同值赋值不发通知，
    // 它在新架构下是空操作；唯一的消费者（设置窗对照测试）已改用真实数据变化驱动。
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
