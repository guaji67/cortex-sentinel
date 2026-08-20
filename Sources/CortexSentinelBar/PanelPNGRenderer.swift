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
}

enum PanelPNGRenderError: Error {
    case emptyImage
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

        let suite = "com.falcon.cortex.sentinelbar.panel-png.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)

        let aioDB = root.appendingPathComponent("aio-coding-hub.db")
        let store = SentinelStore(
            defaults: defaults,
            environment: [
                "CORTEX_SENTINEL_WATCH_DIR": root.path,
                "CORTEX_DATA_ROOT": root.path,
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
    static func render(fixture: PanelPreviewFixture, to path: String) async throws {
        try await render(fixture: fixture, to: URL(fileURLWithPath: path))
    }

    @MainActor
    static func render(fixture: PanelPreviewFixture, to url: URL) async throws {
        _ = NSApplication.shared
        let session = try await PanelPreviewFactory.makeSession(fixture: fixture)
        defer { session.tearDown() }

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
        }
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

    private static func writeProblemBackgroundJobs(into root: URL, generatedAt: Date) throws {
        let longDetail = String(repeating: "长", count: 50)
        let jobs = """
        [
          {
            "label": "com.falcon.cortex.memory-monitor",
            "name": "内存与回收巡检",
            "interval_text": "每 10 分钟",
            "last_run_text": "14 分钟前",
            "status": "ok",
            "status_text": "正常",
            "plist_status": "unexpected_enum"
          },
          {
            "label": "com.falcon.cortex.web",
            "name": "界面常驻服务",
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
