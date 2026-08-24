import Foundation
import Observation
@testable import CortexSentinelBar

/// @Observable 迁移后的「面板刷新次数」计数器。
///
/// 旧口径：`store.objectWillChange.sink { count += 1 }`——每写一个 @Published 记一次。
/// 新口径：withObservationTracking 盯一组读集，willSet 触发时**同步**重挂再计数，
/// 同一轮 apply 里的连续多笔写各计一次，语义与旧口径逐笔对齐。
///
/// 注意读集里**不含 lineGroups / boardWindow**：@Published 时代这两个派生快照
/// 用 `Published(initialValue:)` 换壳、从不发 objectWillChange（Falcon 冷开 22 次
/// 的拆帐里也没有它们）。想数它们的另建读集（见分区隔离测试）。
@MainActor
final class StoreChangeCounter {
    private(set) var count = 0
    private var active = true
    private let read: () -> Void

    init(reading read: @escaping () -> Void) {
        self.read = read
        arm()
    }

    func stop() {
        active = false
    }

    private func arm() {
        guard active else {
            return
        }
        withObservationTracking { [read] in
            read()
        } onChange: { [weak self] in
            // store 是 @MainActor，一切写都发生在主线程；onChange 在写入方
            // 线程同步触发，这里可以安全地假定主 actor。
            MainActor.assumeIsolated {
                guard let self, self.active else {
                    return
                }
                self.count += 1
                self.arm()
            }
        }
    }
}

@MainActor
enum StoreSurfaces {
    /// 与旧 objectWillChange 口径等价的面板刷新读集（原 @Published 的展示面，
    /// 不含 lineGroups / boardWindow，理由见 StoreChangeCounter 注释）。
    static func legacyPanelRead(_ store: SentinelStore) -> () -> Void {
        { [weak store] in
            guard let store else {
                return
            }
            _ = store.lines
            _ = store.aio
            _ = store.otherCodexProcesses
            _ = store.lineRegistry
            _ = store.inputStatus
            _ = store.officialUsage
            _ = store.channelStatus
            _ = store.backgroundJobs
            _ = store.packagingProgress
            _ = store.backgroundJobRows
            _ = store.backgroundJobMessages
            _ = store.backgroundJobOperations
            _ = store.backgroundJobsExpanded
            _ = store.unclaimedTerminals
            _ = store.isOfficialUsageRefreshing
            _ = store.isOfficialUsageRefreshCoolingDown
            _ = store.loginItemPresentation
            _ = store.paths
            _ = store.watchDirectorySource
        }
    }
}

/// 旧 `countPublications(store) { ... }` 的直接替身。
@MainActor
func countStoreChanges(
    _ store: SentinelStore,
    reading read: (() -> Void)? = nil,
    during body: () async -> Void
) async -> Int {
    let counter = StoreChangeCounter(
        reading: read ?? StoreSurfaces.legacyPanelRead(store)
    )
    await body()
    counter.stop()
    return counter.count
}

/// 记录某个值面每次发布的取值序列（连续相同值去重）。
///
/// Observation 的 onChange 在 willSet 触发，读到的是**旧值**；每笔写的旧值 =
/// 上一笔写的新值，所以「逐笔旧值 + 结束时的现值」就是完整的取值序列，
/// 与旧 `$aio.sink` 收到的序列信息等价。
@MainActor
final class ValueSequenceRecorder<Value> {
    private(set) var recorded: [Value] = []
    private var active = true
    private let read: () -> Value
    private let isDuplicate: (Value, Value) -> Bool

    init(
        reading read: @escaping () -> Value,
        dedupBy isDuplicate: @escaping (Value, Value) -> Bool
    ) {
        self.read = read
        self.isDuplicate = isDuplicate
        record(read())
        arm()
    }

    /// 收尾：把当前现值补进序列再返回。
    func finish() -> [Value] {
        active = false
        record(read())
        return recorded
    }

    private func record(_ value: Value) {
        if let last = recorded.last, isDuplicate(last, value) {
            return
        }
        recorded.append(value)
    }

    private func arm() {
        guard active else {
            return
        }
        withObservationTracking { [read] in
            _ = read()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active else {
                    return
                }
                self.record(self.read())
                self.arm()
            }
        }
    }
}
