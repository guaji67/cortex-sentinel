import Foundation

enum RelayRecoveryConstants {
    /// 后台 Input 状态刷新为 2 分钟；冷却保持同一量级，避免重复探测。
    static let probeCooldown: TimeInterval = InputStatusConstants.backgroundRefreshInterval
}

extension InputStatusSnapshot {
    /// `all_ok` 只在本次读取仍新鲜时作为恢复侧信号；它不代表线路请求必然成功。
    func overallState(now: Date = Date()) -> InputProbeState {
        guard let readAt else {
            return .unknown
        }
        let age = now.timeIntervalSince(readAt)
        guard age >= 0 && age <= InputStatusConstants.staleInterval else {
            return .stale
        }
        guard let allOK else {
            return .unknown
        }
        return allOK ? .connected : .disconnected
    }
}

/// 「为什么这条线现在没动静」的结构性归因。
///
/// 维护者 2026-08-12：只开了 Input 系中转、且 Input 不通时，重试是注定失败的，
/// 「这太傻逼了」；但 Input 恢复仍然是绝对的续接信号，所以不是永远不试。
enum RelayExitPosture: Equatable, Sendable {
    /// 启用的出口全是 Input 系，且 Input 判为不通——结构上没有出口。
    case noExit
    /// Input 不通，但名单里还有非 Input 系出口（或名单读不到，保守当还有）。
    case alternativeExit
    /// Input 可用。
    case inputUsable
    /// Input 状态过期或暂无数据，拿不准——一律按老行为走。
    case undetermined

    var isNoExit: Bool {
        self == .noExit
    }

    /// `no_exit` 时给使用者看的兜底人话。守护自己上报了 `no_exit_reason` 时优先用它的，
    /// 这句只在旧版守护（状态文件里没有该字段）时兜底，两边措辞保持一个意思。
    static let noExitFallbackSummary =
        "只开了 Input 系出口，Input 挂着，已暂停无谓重试，等它恢复自动继续"

    static func resolve(aio: AIOSnapshot, inputState: InputProbeState) -> RelayExitPosture {
        switch inputState {
        case .connected:
            return .inputUsable
        case .disconnected:
            return aio.onlyInputExitsEnabled ? .noExit : .alternativeExit
        case .stale, .unknown:
            return .undetermined
        }
    }
}

struct RelayRecoveryProbeCoordinator {
    private(set) var lastRequestedAtBySlug: [String: Date] = [:]
    /// 最近一次判定的出口态势，供界面解释"为什么现在没动静"。
    private(set) var lastPosture: RelayExitPosture = .undetermined
    private var lastInputReadAtBySlug: [String: Date] = [:]

    @discardableResult
    mutating func requestEligibleProbes(
        lines: [LineStatus],
        aio: AIOSnapshot,
        inputStatus: InputStatusSnapshot,
        logsDirectory: URL,
        now: Date = Date()
    ) -> [String] {
        let state = inputStatus.overallState(now: now)
        lastPosture = RelayExitPosture.resolve(aio: aio, inputState: state)
        // 结构性无出口时明确记账再退出，而不是让它顺带落进下面那条 guard——
        // 界面要靠这个态势把停摆解释成"等 Input 恢复"，不能看着像卡死。
        // 注意这里只读名单、只做判断，绝不改动 AIO 里任何出口的启用开关。
        if lastPosture.isNoExit {
            return []
        }
        guard state == .connected, let inputReadAt = inputStatus.readAt else {
            return []
        }

        var requested: [String] = []
        for line in lines where line.state == .waitingRelay && line.isActive(now: now) {
            if let lastRequestedAt = lastRequestedAtBySlug[line.slug],
               now.timeIntervalSince(lastRequestedAt) < RelayRecoveryConstants.probeCooldown {
                continue
            }
            if let lastInputReadAt = lastInputReadAtBySlug[line.slug], inputReadAt <= lastInputReadAt {
                continue
            }
            do {
                try SentinelControlFile.requestProbe(
                    slug: line.slug,
                    logsDirectory: logsDirectory,
                    now: now
                )
                lastRequestedAtBySlug[line.slug] = now
                lastInputReadAtBySlug[line.slug] = inputReadAt
                requested.append(line.slug)
            } catch {
                // 写控制文件失败时不记冷却，下一次状态轮询仍可重试。
            }
        }

        lastRequestedAtBySlug = lastRequestedAtBySlug.filter {
            now.timeIntervalSince($0.value) < RelayRecoveryConstants.probeCooldown * 2
        }
        lastInputReadAtBySlug = lastInputReadAtBySlug.filter {
            lastRequestedAtBySlug[$0.key] != nil
        }
        return requested
    }
}
