import AppKit
import Foundation

/// 滚动期间挂起后台刷新的上屏，滚完再合并放行。
///
/// Falcon 2026-08-24 的原始诉求：「前端在刷新的时候我想上下滑，它就会卡。
/// 数据在后台更新是它的事，我的手指在滑是我的事，这两件事不该互相打架。」
/// 拆分区 + Observation 已把单次刷新的重算范围缩到分区级；这道闸解决剩下
/// 一类打架——刷新改变内容高度（新线出现、余额块从收起变展开）会让 ScrollView
/// 在他手指滑动途中夹一下滚动位置。手在滑就先攒着，手停 220ms 内合并上屏。
///
/// 只有**后台刷新**的上屏走这道闸；用户手动操作（点按钮、展开分区）永远直通，
/// 因为那是他自己要的即时反馈，而且滚动和点击本来就不会同时发生。
@MainActor
final class ScrollPublishGate {
    /// 四个独立刷新面。同一面在挂起期间后到的覆盖先到的（latest-wins）；
    /// 各面的上屏闭包只写自己的面、跨面数据在执行时从 store 现读，
    /// 所以放行顺序不会把别的面倒退回旧值。
    enum Surface: CaseIterable {
        case statuses
        case aio
        case inputStatus
        case officialUsage
    }

    /// 最后一个滚轮事件之后多久算「滚完」。触控板惯性阶段仍持续产生
    /// scrollWheel 事件，会自然把窗口续下去——正是「滚完再上屏」要的行为。
    nonisolated static let quiescenceInterval: TimeInterval = 0.22

    private(set) var isScrolling = false
    private var pending: [Surface: () -> Void] = [:]
    private var monitor: Any?
    private var quiesceGeneration = 0
    /// 测试观察口：挂起期间攒了几面。
    var pendingSurfaceCountForTests: Int {
        pending.count
    }

    func publish(surface: Surface, _ apply: @escaping () -> Void) {
        if isScrolling {
            pending[surface] = apply
        } else {
            apply()
        }
    }

    /// 每收到一个滚轮事件调一次；把「滚完」判定点往后推一个静默窗。
    func noteScrollActivity() {
        isScrolling = true
        quiesceGeneration += 1
        let generation = quiesceGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.quiescenceInterval * 1_000_000_000)
            )
            guard let self, self.quiesceGeneration == generation else {
                return
            }
            self.flushNow()
        }
    }

    /// 立即结束挂起并按固定面序放行。面板关闭时也会调，不让数据攒过夜。
    func flushNow() {
        isScrolling = false
        quiesceGeneration += 1
        guard !pending.isEmpty else {
            return
        }
        let applies = pending
        pending = [:]
        for surface in Surface.allCases {
            applies[surface]?()
        }
    }

    /// 装在真 UI 进程里（状态栏控制器 start 时）。本地监视器只看得到发给
    /// 本 app 窗口的事件，也就是面板开着且指针在面板上的滚动——别处的滚动
    /// 根本进不来。单元测试不装监视器，用 noteScrollActivity / flushNow 直接驱动。
    func installLocalScrollWheelMonitor() {
        guard monitor == nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.noteScrollActivity()
            }
            return event
        }
    }
}
