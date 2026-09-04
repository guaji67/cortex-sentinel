import AppKit
import Foundation
import SwiftUI

enum PanelPreviewFixture: String, CaseIterable {
    case idle
    case busy
    case unclaimed
    case channelDown = "channel-down"
    case bgjobsProblems = "bgjobs-problems"
    case fourOutcomes = "four-outcomes"
    case balanceUnread = "balance-unread"
    case routeUnread = "route-unread"
    case splitCounts = "split-counts"
    case channelNoRecord = "channel-no-record"
    case channelUnreadable = "channel-unreadable"
    case channelUnrecognized = "channel-unrecognized"
    case channelUndetermined = "channel-undetermined"
    case offHostActive = "off-host-active"
    case packaging
    case packagingDeadPID = "packaging-dead-pid"
    case packagingPIDReuse = "packaging-pid-reuse"
    case packagingStale = "packaging-stale"
}

enum PanelPNGRenderError: Error {
    case emptyImage
}

enum PackagingPreviewMode {
    case live
    case deadPID
    case pidReuse
    case stale
}

/// 给 `--render-panel-png` 用的离屏会话：临时监视目录 + 不扫本机进程表。
@MainActor
final class PanelPreviewSession {
    let store: SentinelStore
    let root: URL
    private let defaultsSuite: String
    private let defaults: UserDefaults

    fileprivate init(
        store: SentinelStore,
        root: URL,
        defaultsSuite: String,
        defaults: UserDefaults
    ) {
        self.store = store
        self.root = root
        self.defaultsSuite = defaultsSuite
        self.defaults = defaults
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

enum PanelPreviewFactory {
    @MainActor
    static func makeSession(fixture: PanelPreviewFixture) async throws -> PanelPreviewSession {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "sentinel-panel-png-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try PanelPreviewLayout.write(fixture: fixture, into: root)
        let packRoot = root.appendingPathComponent("pack-progress", isDirectory: true)
        try fileManager.createDirectory(at: packRoot, withIntermediateDirectories: true)
        switch fixture {
        case .packaging:
            try PanelPreviewLayout.writePackagingProgress(into: packRoot, mode: .live)
        case .packagingDeadPID:
            try PanelPreviewLayout.writePackagingProgress(into: packRoot, mode: .deadPID)
        case .packagingPIDReuse:
            try PanelPreviewLayout.writePackagingProgress(into: packRoot, mode: .pidReuse)
        case .packagingStale:
            try PanelPreviewLayout.writePackagingProgress(into: packRoot, mode: .stale)
        default:
            break
        }

        let suite = "com.falcon.cortex.sentinelbar.panel-png.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)

        let aioDB = root.appendingPathComponent("aio-coding-hub.db")
        let store = SentinelStore(
            defaults: defaults,
            environment: [
                "CORTEX_SENTINEL_WATCH_DIR": root.path,
                "CORTEX_DATA_ROOT": root.path,
                "CORTEX_PACK_PROGRESS_DIR": packRoot.path,
                "CORTEX_AIO_DB_PATH": aioDB.path,
                "CORTEX_CODEX_CONFIG_PATH": root.appendingPathComponent("config.toml").path,
                "CORTEX_CODEX_AUTH_PATH": root.appendingPathComponent("auth.json").path,
            ],
            otherCodexProcessReader: { _ in [] }
        )
        await store.refreshStatuses()
        await store.refreshAIO(force: true, includeUsage: false)
        return PanelPreviewSession(
            store: store,
            root: root,
            defaultsSuite: suite,
            defaults: defaults
        )
    }
}

enum PanelPNGRenderer {
    @MainActor
    static func render(
        fixture: PanelPreviewFixture,
        to path: String,
        demoBalances: Bool = false
    ) async throws {
        try await render(fixture: fixture, to: URL(fileURLWithPath: path), demoBalances: demoBalances)
    }

    @MainActor
    static func render(
        fixture: PanelPreviewFixture,
        to url: URL,
        demoBalances: Bool = false
    ) async throws {
        _ = NSApplication.shared
        let session = try await PanelPreviewFactory.makeSession(fixture: fixture)
        defer { session.tearDown() }
        if demoBalances {
            DemoBalancesPreview.inject(into: session.store)
        }

        let view = SentinelMenuView(store: session.store, rendersOffscreen: true)
            .frame(width: SentinelTheme.Metrics.menuWidth)
            .fixedSize(horizontal: true, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(
            width: SentinelTheme.Metrics.menuWidth,
            height: nil
        )
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              !png.isEmpty
        else {
            throw PanelPNGRenderError.emptyImage
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url)
    }
}

/// README/截图用的演示余额：一套中性假数据（官方 / Cursor / GLM 三行 /
/// AIO 三家中转），只进离屏渲染，不碰任何真实账号。
/// GLM 三行刻意摆出三种探测形态：订阅+余额都有、只有余额、只有订阅。
@MainActor
enum DemoBalancesPreview {
    static func inject(into store: SentinelStore) {
        let checked = Date()

        let official = OfficialUsageSnapshot(
            planType: "plus",
            email: nil,
            weeklyWindow: OfficialUsageWindow(
                usedPercentage: 39,
                limitWindowSeconds: 604_800,
                resetAt: checked.addingTimeInterval(3600 * 72).timeIntervalSince1970,
                resetAfterSeconds: nil
            ),
            fiveHourWindow: OfficialUsageWindow(
                usedPercentage: 12,
                limitWindowSeconds: 5 * 3600,
                resetAt: checked.addingTimeInterval(3600 * 2.5).timeIntervalSince1970,
                resetAfterSeconds: nil
            ),
            checkedAt: checked,
            stale: false,
            errorMessage: nil,
            refreshFailedAt: nil
        )

        let cursor = CursorUsageSnapshot(
            sourceState: .available,
            autoPercentUsed: 18,
            apiPercentUsed: 35,
            botPercentUsed: 10,
            botResetDate: checked.addingTimeInterval(3600 * 40),
            checkedAt: checked,
            stale: false,
            errorMessage: nil
        )

        func glmWindow(total: Double, used: Double, resetIn: TimeInterval) -> GLMUsageWindow {
            GLMUsageWindow(
                totalPoints: total,
                usedPoints: used,
                percentUsed: used / total * 100,
                resetAt: checked.addingTimeInterval(resetIn)
            )
        }

        let glm = GLMUsageSnapshot(
            accounts: [
                GLMAccountUsage(
                    key: "demo-key-pro",
                    label: "pro",
                    level: "pro",
                    fiveHourWindow: glmWindow(total: 12000, used: 2400, resetIn: 3600 * 2),
                    weeklyWindow: glmWindow(total: 60000, used: 3000, resetIn: 3600 * 96),
                    cashBalance: 86.4,
                    totalSpendAmount: 113.6,
                    checkedAt: checked,
                    stale: false,
                    errorMessage: nil
                ),
                GLMAccountUsage(
                    key: "demo-key-lite",
                    label: "lite",
                    level: "lite",
                    fiveHourWindow: nil,
                    weeklyWindow: nil,
                    cashBalance: 12,
                    totalSpendAmount: 38,
                    checkedAt: checked,
                    stale: false,
                    errorMessage: nil
                ),
                GLMAccountUsage(
                    key: "demo-key-trial",
                    label: "体验卡",
                    level: nil,
                    fiveHourWindow: glmWindow(total: 12000, used: 5400, resetIn: 3600 * 1.5),
                    weeklyWindow: glmWindow(total: 60000, used: 42000, resetIn: 3600 * 80),
                    cashBalance: nil,
                    totalSpendAmount: nil,
                    checkedAt: checked,
                    stale: false,
                    errorMessage: nil
                ),
            ],
            checkedAt: checked
        )

        func aioProvider(
            id: Int64,
            name: String,
            remaining: Double?,
            weeklyUsed: Double?
        ) -> AIOProvider {
            let usage = AIOUsage(
                remaining: remaining,
                unit: remaining == nil ? nil : "USD",
                planName: nil,
                expiresAt: nil,
                weeklyUsedPercentage: weeklyUsed,
                weeklyResetAt: checked.addingTimeInterval(3600 * 60),
                email: nil,
                isValid: true
            )
            return AIOProvider(
                id: id,
                name: name,
                baseURL: "https://relay-\(id).example.invalid",
                enabled: true,
                routeOrder: Int(id),
                providerOrder: Int(id),
                note: "",
                circuitState: .closed,
                failureCount: 0,
                usage: .success(usage)
            )
        }

        let aio = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [
                aioProvider(id: 1, name: "中转一号", remaining: 42.5, weeklyUsed: nil),
                aioProvider(id: 2, name: "中转二号", remaining: 6.2, weeklyUsed: nil),
                aioProvider(id: 3, name: "中转三号", remaining: nil, weeklyUsed: 86),
            ],
            lastHitProviderID: 1,
            lastHitProviderName: "中转一号",
            readAt: checked,
            errorMessage: nil
        )

        store.injectPreviewData(
            official: official,
            cursor: cursor,
            glm: glm,
            aio: aio,
            inputStatus: demoInputStatus(checked: checked)
        )
    }

    /// Input 探针演示历史：三个模型 60 格，绝大多数绿，零星橙/红。
    private static func demoInputStatus(checked: Date) -> InputStatusSnapshot {
        let models = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.5"]
        var probes: [InputStatusProbe] = []
        for (index, model) in models.enumerated() {
            var history: [InputStatusHistoryPoint] = []
            for step in 0..<60 {
                // 伪随机但稳定：同一格每次出同一张图。
                let seed = (index * 60 + step) * 2654435761 % 100
                let latency = 180 + (index * 37 + step * 13) % 900
                if step >= 57 {
                    // 最右侧三格保持全绿：演示图最新状态不该看着像挂了。
                    history.append(
                        InputStatusHistoryPoint(
                            timestamp: Int(checked.timeIntervalSince1970) - (60 - step) * 60,
                            isOK: true,
                            latencyMilliseconds: latency
                        )
                    )
                } else if seed < 92 {
                    history.append(
                        InputStatusHistoryPoint(
                            timestamp: Int(checked.timeIntervalSince1970) - (60 - step) * 60,
                            isOK: true,
                            latencyMilliseconds: latency
                        )
                    )
                } else if seed < 97 {
                    history.append(
                        InputStatusHistoryPoint(
                            timestamp: Int(checked.timeIntervalSince1970) - (60 - step) * 60,
                            isOK: true,
                            latencyMilliseconds: 3400 + step * 7
                        )
                    )
                } else {
                    history.append(
                        InputStatusHistoryPoint(
                            timestamp: Int(checked.timeIntervalSince1970) - (60 - step) * 60,
                            isOK: false,
                            latencyMilliseconds: nil,
                            error: "upstream timeout"
                        )
                    )
                }
            }
            probes.append(
                InputStatusProbe(
                    model: model,
                    uptimePercentage: 99.2 - Double(index) * 1.4,
                    isOK: true,
                    latencyMilliseconds: 240 + index * 110,
                    history: history
                )
            )
        }
        return InputStatusSnapshot(
            allOK: true,
            probes: probes,
            readAt: checked,
            generatedAt: checked,
            errorMessage: nil
        )
    }
}

private enum PanelPreviewLayout {
    private struct LineSpec {
        let slug: String
        let labelZH: String
        let dispatcherZH: String
        let engine: PreviewEngine
        let state: String
        let model: String?
        let exitCode: Int?
    }

    private enum PreviewEngine: Equatable {
        case codex
        case grok

        var registryValue: String {
            switch self {
            case .codex:
                return "codex"
            case .grok:
                return "cursor-grok"
            }
        }

        func statusFileName(slug: String) -> String {
            switch self {
            case .codex:
                return "codex-babysitter-\(slug).status.json"
            case .grok:
                return "grok-\(slug).status.json"
            }
        }
    }

    static func write(fixture: PanelPreviewFixture, into root: URL) throws {
        let now = Date()
        let host = localHostName()
        switch fixture {
        case .idle:
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0),
                codex: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .busy:
            let lines = busyLines()
            try writeRegistry(lines, host: host, registeredAt: now, into: root)
            try writeStatusFiles(lines, now: now, into: root)
            let grokCount = lines.filter { $0.engine == .grok }.count
            let codexCount = lines.filter { $0.engine == .codex }.count
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "\(grokCount) 条在跑", running: grokCount),
                codex: ChannelJSON(status: "alive", evidence: "\(codexCount) 条在跑", running: codexCount)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .unclaimed:
            let lines = unclaimedLines()
            try writeRegistry(lines, host: host, registeredAt: now, into: root)
            try writeStatusFiles(lines, now: now, into: root)
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0),
                codex: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .channelDown:
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "degraded", evidence: "账单未付，进程秒退", running: nil),
                codex: ChannelJSON(status: "unknown", evidence: "无数据", running: nil)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .bgjobsProblems:
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0),
                codex: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0)
            )
            try writeProblemBackgroundJobs(into: root, generatedAt: now)
        case .fourOutcomes:
            let lines = fourOutcomeLines()
            try writeRegistry(lines, host: host, registeredAt: now, into: root)
            try writeStatusFiles(lines, now: now, into: root)
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0),
                codex: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .balanceUnread:
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0),
                codex: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
            try writeUnreadableAIODatabase(into: root)
        case .routeUnread:
            let lines = routeUnreadLines()
            try writeRegistry(lines, host: host, registeredAt: now, into: root)
            try writeStatusFiles(lines, now: now, into: root)
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "1 条在跑", running: 1),
                codex: ChannelJSON(status: "alive", evidence: "1 条在跑", running: 1)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .splitCounts:
            let unregistered = LineSpec(
                slug: "local-unregistered",
                labelZH: "本机未登记",
                dispatcherZH: "",
                engine: .grok,
                state: "running",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            )
            let remoteRegistered = LineSpec(
                slug: "remote-registered",
                labelZH: "外机已登记",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "running",
                model: "gpt-5.4",
                exitCode: nil
            )
            try writeRegistry(
                [remoteRegistered],
                host: "Other Mac",
                registeredAt: now,
                into: root
            )
            try writeStatusFiles([unregistered, remoteRegistered], now: now, into: root)
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "1 条在跑", running: 1),
                codex: ChannelJSON(status: "alive", evidence: "1 条在跑", running: 1)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .channelNoRecord:
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .channelUnreadable:
            try Data("this-is-not-channel-status".utf8).write(
                to: root.appendingPathComponent("channel-status.json")
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .channelUnrecognized:
            try writeRawChannel(
                into: root,
                json: """
                {
                  "generated_at": "\(isoString(now))",
                  "channels": {
                    "grok": {"status": "weird-value", "evidence": "x"},
                    "codex": {}
                  }
                }
                """
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .channelUndetermined:
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "unknown", evidence: "无数据", running: nil),
                codex: ChannelJSON(status: "unknown", evidence: "无数据", running: nil)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .offHostActive:
            let remote = LineSpec(
                slug: "remote-registered",
                labelZH: "外机已登记",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "running",
                model: "gpt-5.4",
                exitCode: nil
            )
            let unknown = LineSpec(
                slug: "unknown-host",
                labelZH: "机器未知",
                dispatcherZH: "主控窗口派工",
                engine: .grok,
                state: "running",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            )
            try writeMixedHostRegistry(
                remote: remote,
                unknown: unknown,
                registeredAt: now,
                into: root
            )
            try writeStatusFiles([remote, unknown], now: now, into: root)
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "1 条在跑", running: 1),
                codex: ChannelJSON(status: "alive", evidence: "1 条在跑", running: 1)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        case .packaging, .packagingDeadPID, .packagingPIDReuse, .packagingStale:
            try writeChannel(
                into: root,
                generatedAt: now,
                grok: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0),
                codex: ChannelJSON(status: "alive", evidence: "最近一次派工正常终态 done", running: 0)
            )
            try writeHealthyBackgroundJobs(into: root, generatedAt: now)
        }
    }

    static func writePackagingProgress(into root: URL, mode: PackagingPreviewMode) throws {
        let run = root.appendingPathComponent("preview-run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let processStartedAt = PackagingProgressActivity.processStartedAt(pid)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payloadPID: Int
        let payloadStartedAt: String
        let payloadUpdatedAt: Date
        switch mode {
        case .live:
            payloadPID = pid
            payloadStartedAt = processStartedAt
            payloadUpdatedAt = Date()
        case .deadPID:
            payloadPID = 2_147_483_647
            payloadStartedAt = "dead-fixture-process"
            payloadUpdatedAt = Date()
        case .pidReuse:
            payloadPID = pid
            payloadStartedAt = "old-fixture-process"
            payloadUpdatedAt = Date()
        case .stale:
            payloadPID = pid
            payloadStartedAt = processStartedAt
            payloadUpdatedAt = Date().addingTimeInterval(-31 * 60)
        }
        try Data(
            """
            {"schema":"cortex.packaging-progress.v1","run_id":"preview-run","status":"running",
             "pid":\(payloadPID),"process_started_at":"\(payloadStartedAt)",
             "current_step_id":"build","current_detail":"Electron 打包","updated_at":"\(formatter.string(from: payloadUpdatedAt))",
             "eta_label":"大约还要 12 分钟",
             "steps":[{"id":"build","title":"构建 App 与 zip","status":"running"}]}
            """.utf8
        ).write(to: run.appendingPathComponent("progress.json"))
    }

    private static func writeRawChannel(into root: URL, json: String) throws {
        try Data(json.utf8).write(to: root.appendingPathComponent("channel-status.json"))
    }

    private static func busyLines() -> [LineSpec] {
        [
            LineSpec(
                slug: "wake-panel",
                labelZH: "叫醒面板",
                dispatcherZH: "主控窗口派工",
                engine: .grok,
                state: "running",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            ),
            LineSpec(
                slug: "balance-refresh",
                labelZH: "打开面板刷余额",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "running",
                model: "gpt-5.4",
                exitCode: nil
            ),
            LineSpec(
                slug: "settings-feel",
                labelZH: "设置窗手感",
                dispatcherZH: "Claude 对话：哨兵设置",
                engine: .grok,
                state: "running",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            ),
            LineSpec(
                slug: "channel-watch",
                labelZH: "通道巡检",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "running",
                model: "gpt-5.4",
                exitCode: nil
            ),
            LineSpec(
                slug: "log-cleanup",
                labelZH: "日志清理",
                dispatcherZH: "Claude 对话：哨兵维护",
                engine: .grok,
                state: "running",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            ),
            LineSpec(
                slug: "registry-decode",
                labelZH: "登记表容错",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "running",
                model: "gpt-5.4",
                exitCode: nil
            ),
            LineSpec(
                slug: "dmg-version",
                labelZH: "出包写版本",
                dispatcherZH: "Claude 对话：出包",
                engine: .grok,
                state: "running",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            ),
            LineSpec(
                slug: "panel-scroll",
                labelZH: "面板滚动压测",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "running",
                model: "gpt-5.4",
                exitCode: nil
            ),
            LineSpec(
                slug: "notify-coalesce",
                labelZH: "通知合并",
                dispatcherZH: "Claude 对话：哨兵通知",
                engine: .grok,
                state: "running",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            ),
            LineSpec(
                slug: "idle-skip-ps",
                labelZH: "空闲不扫进程",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "running",
                model: "gpt-5.4",
                exitCode: nil
            ),
        ]
    }

    private static func unclaimedLines() -> [LineSpec] {
        [
            LineSpec(
                slug: "morning-brief",
                labelZH: "早报摘要",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "done",
                model: "gpt-5.4",
                exitCode: 0
            ),
            LineSpec(
                slug: "link-curate",
                labelZH: "链接整理",
                dispatcherZH: "Claude 对话：内容",
                engine: .grok,
                state: "done",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: 0
            ),
            LineSpec(
                slug: "stalled-probe",
                labelZH: "卡住的探针",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "killed",
                model: "gpt-5.4",
                exitCode: 1
            ),
        ]
    }

    private static func fourOutcomeLines() -> [LineSpec] {
        [
            LineSpec(
                slug: "morning-brief",
                labelZH: "早报摘要",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "done",
                model: "gpt-5.4",
                exitCode: 0
            ),
            LineSpec(
                slug: "quota-ask",
                labelZH: "额度告急",
                dispatcherZH: "主控窗口派工",
                engine: .grok,
                state: "help",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            ),
            LineSpec(
                slug: "stalled-writer",
                labelZH: "卡住的写稿",
                dispatcherZH: "Claude 对话：内容",
                engine: .codex,
                state: "dead",
                model: "gpt-5.4",
                exitCode: 1
            ),
            LineSpec(
                slug: "stopped-probe",
                labelZH: "被停的探针",
                dispatcherZH: "主控窗口派工",
                engine: .grok,
                state: "killed",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: 1
            ),
        ]
    }

    private static func routeUnreadLines() -> [LineSpec] {
        [
            LineSpec(
                slug: "wake-panel",
                labelZH: "叫醒面板",
                dispatcherZH: "主控窗口派工",
                engine: .grok,
                state: "running",
                model: "cursor-grok-4.6-xhigh-fast",
                exitCode: nil
            ),
            LineSpec(
                slug: "balance-refresh",
                labelZH: "打开面板刷余额",
                dispatcherZH: "主控窗口派工",
                engine: .codex,
                state: "running",
                model: "gpt-5.4",
                exitCode: nil
            ),
        ]
    }

    private static func writeUnreadableAIODatabase(into root: URL) throws {
        try Data("this-is-not-a-sqlite-database".utf8).write(
            to: root.appendingPathComponent("aio-coding-hub.db")
        )
    }

    private static func writeRegistry(
        _ lines: [LineSpec],
        host: String,
        registeredAt: Date,
        into root: URL
    ) throws {
        let timestamp = Int(registeredAt.timeIntervalSince1970)
        let entries = lines.map { line in
            """
              {
                "slug": "\(line.slug)",
                "engine": "\(line.engine.registryValue)",
                "label_zh": "\(line.labelZH)",
                "dispatcher_zh": "\(line.dispatcherZH)",
                "registered_at": \(timestamp),
                "host": "\(host)"
              }
            """
        }
        .joined(separator: ",\n")
        let json = "[\n\(entries)\n]\n"
        try Data(json.utf8).write(to: root.appendingPathComponent("codex-line-registry.json"))
    }

    private static func writeMixedHostRegistry(
        remote: LineSpec,
        unknown: LineSpec,
        registeredAt: Date,
        into root: URL
    ) throws {
        let timestamp = Int(registeredAt.timeIntervalSince1970)
        let json = """
        [
          {
            "slug": "\(remote.slug)",
            "engine": "\(remote.engine.registryValue)",
            "label_zh": "\(remote.labelZH)",
            "dispatcher_zh": "\(remote.dispatcherZH)",
            "registered_at": \(timestamp),
            "host": "COR-1704-Remote-Host"
          },
          {
            "slug": "\(unknown.slug)",
            "engine": "\(unknown.engine.registryValue)",
            "label_zh": "\(unknown.labelZH)",
            "dispatcher_zh": "\(unknown.dispatcherZH)",
            "registered_at": \(timestamp)
          }
        ]
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("codex-line-registry.json"))
    }

    private static func writeStatusFiles(
        _ lines: [LineSpec],
        now: Date,
        into root: URL
    ) throws {
        let stamp = isoString(now)
        for (index, line) in lines.enumerated() {
            let started = isoString(now.addingTimeInterval(TimeInterval(-180 - index * 45)))
            var fields = [
                "\"slug\": \"\(line.slug)\"",
                "\"engine\": \"\(line.engine.registryValue)\"",
                "\"state\": \"\(line.state)\"",
                "\"workdir\": \"/tmp/\(line.slug)\"",
                "\"branch\": \"codex/\(line.slug)\"",
                "\"updated_at\": \"\(stamp)\"",
                "\"started_at\": \"\(started)\"",
            ]
            if let model = line.model {
                fields.append("\"model\": \"\(model)\"")
            }
            if let exitCode = line.exitCode {
                fields.append("\"exit_code\": \(exitCode)")
            }
            if line.engine == .codex {
                fields.append("\"codex_pid\": \(42000 + index)")
                fields.append("\"restarts\": 0")
            } else {
                fields.append("\"agent_pid\": \(52000 + index)")
            }
            let json = "{\n  \(fields.joined(separator: ",\n  "))\n}\n"
            try Data(json.utf8).write(
                to: root.appendingPathComponent(line.engine.statusFileName(slug: line.slug))
            )
        }
    }

    private struct ChannelJSON {
        let status: String
        let evidence: String
        let running: Int?
    }

    private static func writeChannel(
        into root: URL,
        generatedAt: Date,
        grok: ChannelJSON,
        codex: ChannelJSON
    ) throws {
        let json = """
        {
          "generated_at": "\(isoString(generatedAt))",
          "channels": {
            "grok": \(channelObject(grok)),
            "codex": \(channelObject(codex))
          }
        }
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("channel-status.json"))
    }

    private static func writeHealthyBackgroundJobs(into root: URL, generatedAt: Date) throws {
        let jobs = """
        [
          {
            "label": "com.falcon.cortex.web",
            "name": "界面常驻服务",
            "interval_text": "常驻",
            "last_run_text": "正在运行",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "loaded"
          },
          {
            "label": "com.falcon.cortex.web-guard",
            "name": "界面守护",
            "interval_text": "每 150 秒",
            "last_run_text": "不到 1 分钟前",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "loaded"
          },
          {
            "label": "com.falcon.cortex.memory-monitor",
            "name": "内存与回收巡检",
            "interval_text": "每 10 分钟",
            "last_run_text": "不到 1 分钟前",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "loaded"
          },
          {
            "label": "com.falcon.cortex.mini-mirror-sync",
            "name": "数据镜像同步",
            "interval_text": "每 30 分钟",
            "last_run_text": "12 分钟前",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "loaded"
          },
          {
            "label": "com.cortex.sentinelbar",
            "name": "Cortex 哨兵",
            "interval_text": "常驻",
            "last_run_text": "正在运行",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "loaded"
          }
        ]
        """
        try writeBackgroundJobs(into: root, generatedAt: generatedAt, jobsJSON: jobs)
    }

    /// COR-1862 口径：红行必须是 launchd 实际状态真坏的 job；plist 异常只做
    /// 绿行备注（含超长细节截断），不再当问题。
    private static func writeProblemBackgroundJobs(into root: URL, generatedAt: Date) throws {
        let longDetail = String(repeating: "长", count: 50)
        let jobs = """
        [
          {
            "label": "com.falcon.cortex.web",
            "name": "界面常驻服务",
            "interval_text": "常驻",
            "last_run_text": "查不到上次运行",
            "status": "error",
            "status_text": "出错",
            "reason": "常驻进程不在了，上次退出码 78",
            "plist_status": "loaded"
          },
          {
            "label": "com.falcon.cortex.memory-monitor",
            "name": "内存与回收巡检",
            "interval_text": "每 10 分钟",
            "last_run_text": "14 分钟前",
            "status": "stalled",
            "status_text": "出错",
            "reason": "本轮 312 秒，已超过 10 分钟间隔的一半",
            "plist_status": "loaded"
          },
          {
            "label": "com.falcon.cortex.web-guard",
            "name": "界面守护",
            "interval_text": "每 150 秒",
            "last_run_text": "不到 1 分钟前",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "loaded"
          },
          {
            "label": "com.falcon.cortex.mini-mirror-sync",
            "name": "数据镜像同步",
            "interval_text": "每 30 分钟",
            "last_run_text": "12 分钟前",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "unexpected_enum"
          },
          {
            "label": "com.cortex.sentinelbar",
            "name": "Cortex 哨兵",
            "interval_text": "常驻",
            "last_run_text": "正在运行",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "unreadable",
            "plist_error_detail": "\(longDetail)"
          }
        ]
        """
        try writeBackgroundJobs(into: root, generatedAt: generatedAt, jobsJSON: jobs)
    }

    private static func writeBackgroundJobs(
        into root: URL,
        generatedAt: Date,
        jobsJSON: String
    ) throws {
        let json = """
        {
          "schema": "cortex.background-jobs-health.v1",
          "generated_at": "\(isoString(generatedAt))",
          "jobs": \(jobsJSON)
        }
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("background-jobs-health.json"))
    }

    private static func channelObject(_ channel: ChannelJSON) -> String {
        if let running = channel.running {
            return "{\"status\": \"\(channel.status)\", \"evidence\": \"\(channel.evidence)\", \"running\": \(running)}"
        }
        return "{\"status\": \"\(channel.status)\", \"evidence\": \"\(channel.evidence)\"}"
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func localHostName() -> String {
        Host.current().localizedName
            ?? Host.current().name
            ?? ProcessInfo.processInfo.hostName
    }
}
