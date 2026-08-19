import Foundation
import UserNotifications

enum SentinelNotifyCategory: String, Equatable, CaseIterable {
    case taskComplete
    case taskProblem
    case channelAlert
}

struct SentinelNotificationDraft: Equatable {
    var title: String
    var body: String
    var category: SentinelNotifyCategory
}

enum SentinelNotificationCopy {
    static let taskProblemTitle = "派工线状态变化"
    static let taskCompleteTitle = "任务结束"
    static let circuitTitle = "AIO 熔断提醒"
    static let lowBalanceTitle = "AIO 余额提醒"

    static func taskProblemBody(label: String, stateName: String) -> String {
        "\(label) 进入 \(stateName)"
    }

    static func taskCompleteBody(label: String, stateName: String) -> String {
        "\(label) \(stateName)"
    }

    static func circuitBody(name: String) -> String {
        "\(name) 熔断已打开"
    }

    static func lowBalanceBody(name: String) -> String {
        "\(name) 余额低于 $\(String(format: "%.0f", AIOConstants.lowBalanceThreshold))"
    }

    static func mergedTaskCompleteBody(count: Int) -> String {
        "\(count) 条线干完了"
    }

    static func mergedTaskProblemBody(count: Int) -> String {
        "\(count) 条线出问题了"
    }

    static func mergedChannelBody(count: Int) -> String {
        "\(count) 条通道熔断或余额不够"
    }
}

/// 固定窗口攒通知。窗口从这一批第一条算起，到期发出，不往后滑。
final class SentinelNotificationCoalescer {
    private var priorStates: [String: LineState]?
    private var priorAIOCircuits: [Int64: Bool]?
    private var priorLowBalanceProviders: Set<Int64>?
    private var hasAIOBaseline = false
    private var buffers: [SentinelNotifyCategory: PendingBatch] = [:]

    private struct PendingBatch {
        var windowStart: Date
        var items: [SentinelNotificationDraft]
    }

    func observe(
        lines: [LineStatus],
        aio: AIOSnapshot,
        registry: CodexLineRegistry,
        preferences: SentinelNotifyPreferences,
        now: Date = Date()
    ) -> [SentinelNotificationDraft] {
        let events = detectEvents(
            lines: lines,
            aio: aio,
            registry: registry,
            now: now
        )
        remember(lines: lines, aio: aio)

        guard preferences.masterEnabled else {
            buffers.removeAll()
            return []
        }

        let allowed = events.filter { preferences.allows($0.category) }
        var deliveries: [SentinelNotificationDraft] = []

        if let window = preferences.cadence.windowLength {
            for event in allowed {
                enqueue(event, now: now)
            }
            deliveries.append(contentsOf: flushExpired(window: window, now: now, preferences: preferences))
        } else {
            deliveries.append(contentsOf: allowed)
        }

        return deliveries
    }

    private func detectEvents(
        lines: [LineStatus],
        aio: AIOSnapshot,
        registry: CodexLineRegistry,
        now: Date
    ) -> [SentinelNotificationDraft] {
        var events: [SentinelNotificationDraft] = []

        if let priorStates {
            for line in SentinelNotificationPlanner.newlyCriticalLines(
                priorStates: priorStates,
                lines: lines,
                now: now
            ) {
                let label = registry.registration(for: line.slug)?.labelZH ?? line.slug
                events.append(
                    SentinelNotificationDraft(
                        title: SentinelNotificationCopy.taskProblemTitle,
                        body: SentinelNotificationCopy.taskProblemBody(
                            label: label,
                            stateName: line.state.displayName
                        ),
                        category: .taskProblem
                    )
                )
            }
            for line in SentinelNotificationPlanner.completedLines(priorStates: priorStates, lines: lines) {
                let label = registry.registration(for: line.slug)?.labelZH ?? line.slug
                events.append(
                    SentinelNotificationDraft(
                        title: SentinelNotificationCopy.taskCompleteTitle,
                        body: SentinelNotificationCopy.taskCompleteBody(
                            label: label,
                            stateName: line.state.displayName
                        ),
                        category: .taskComplete
                    )
                )
            }
        }

        if hasAIOBaseline, aio.sourceState == .available {
            for provider in SentinelNotificationPlanner.newlyOpenedCircuits(
                prior: priorAIOCircuits,
                providers: aio.providers
            ) {
                events.append(
                    SentinelNotificationDraft(
                        title: SentinelNotificationCopy.circuitTitle,
                        body: SentinelNotificationCopy.circuitBody(name: provider.name),
                        category: .channelAlert
                    )
                )
            }
            for provider in SentinelNotificationPlanner.newlyLowBalanceProviders(
                prior: priorLowBalanceProviders,
                providers: aio.providers
            ) {
                events.append(
                    SentinelNotificationDraft(
                        title: SentinelNotificationCopy.lowBalanceTitle,
                        body: SentinelNotificationCopy.lowBalanceBody(name: provider.name),
                        category: .channelAlert
                    )
                )
            }
        }

        return events
    }

    private func remember(lines: [LineStatus], aio: AIOSnapshot) {
        priorStates = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.state) })
        if aio.sourceState == .available {
            priorAIOCircuits = Dictionary(
                uniqueKeysWithValues: aio.providers.map { ($0.id, $0.circuitState.isOpen) }
            )
            priorLowBalanceProviders = Set(aio.providers.filter(\.isLowBalance).map(\.id))
            hasAIOBaseline = true
        }
    }

    private func enqueue(_ event: SentinelNotificationDraft, now: Date) {
        if var batch = buffers[event.category] {
            batch.items.append(event)
            buffers[event.category] = batch
        } else {
            buffers[event.category] = PendingBatch(windowStart: now, items: [event])
        }
    }

    private func flushExpired(
        window: TimeInterval,
        now: Date,
        preferences: SentinelNotifyPreferences
    ) -> [SentinelNotificationDraft] {
        var deliveries: [SentinelNotificationDraft] = []
        for category in SentinelNotifyCategory.allCases {
            guard let batch = buffers[category] else {
                continue
            }
            guard now.timeIntervalSince(batch.windowStart) >= window else {
                continue
            }
            buffers[category] = nil
            guard preferences.allows(category), !batch.items.isEmpty else {
                continue
            }
            deliveries.append(Self.merge(batch.items, category: category))
        }
        return deliveries
    }

    static func merge(
        _ items: [SentinelNotificationDraft],
        category: SentinelNotifyCategory
    ) -> SentinelNotificationDraft {
        if items.count == 1 {
            return items[0]
        }
        switch category {
        case .taskComplete:
            return SentinelNotificationDraft(
                title: SentinelNotificationCopy.taskCompleteTitle,
                body: SentinelNotificationCopy.mergedTaskCompleteBody(count: items.count),
                category: .taskComplete
            )
        case .taskProblem:
            return SentinelNotificationDraft(
                title: SentinelNotificationCopy.taskProblemTitle,
                body: SentinelNotificationCopy.mergedTaskProblemBody(count: items.count),
                category: .taskProblem
            )
        case .channelAlert:
            let titles = Set(items.map(\.title))
            let title: String
            if titles.count == 1, let only = titles.first {
                title = only
            } else if titles.contains(SentinelNotificationCopy.circuitTitle) {
                title = SentinelNotificationCopy.circuitTitle
            } else {
                title = SentinelNotificationCopy.lowBalanceTitle
            }
            return SentinelNotificationDraft(
                title: title,
                body: SentinelNotificationCopy.mergedChannelBody(count: items.count),
                category: .channelAlert
            )
        }
    }
}

@MainActor
final class SentinelNotifier {
    private let coalescer = SentinelNotificationCoalescer()
    var sendHandler: ((SentinelNotificationDraft) -> Void)?

    func requestAuthorization() {
        guard !ProcessInfo.processInfo.arguments.contains(CortexSentinelBarMain.smokeWindowArgument),
              !ProcessInfo.processInfo.arguments.contains(CortexSentinelBarMain.smokeSettingsArgument),
              !ProcessInfo.processInfo.arguments.contains(CortexSentinelBarMain.renderSettingsPNGArgument),
              !ProcessInfo.processInfo.arguments.contains(CortexSentinelBarMain.renderPanelPNGArgument),
              let center = notificationCenter
        else {
            return
        }
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func observe(
        lines: [LineStatus],
        aio: AIOSnapshot,
        registry: CodexLineRegistry,
        preferences: SentinelNotifyPreferences,
        now: Date = Date()
    ) {
        let deliveries = coalescer.observe(
            lines: lines,
            aio: aio,
            registry: registry,
            preferences: preferences,
            now: now
        )
        for draft in deliveries {
            send(draft)
        }
    }

    private func send(_ draft: SentinelNotificationDraft) {
        if let sendHandler {
            sendHandler(draft)
            return
        }
        guard let center = notificationCenter else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = draft.title
        content.body = draft.body
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
