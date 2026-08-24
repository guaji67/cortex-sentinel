import SwiftUI

/// 派工线各种行的独立视图与配套小件。
///
/// 2026-08-24 从 SentinelMenuView 的方法堆里拆出来：行以值类型输入渲染，
/// 不直接摸 store——分区 view 负责把 LinePresentation / 本机身份 / 通道归因
/// 解析成值传进来。这样 SwiftUI 能按输入相等跳过没变的行，行也不会因为
/// 余额刷新（aio.readAt 每轮都变）跟着失效。
enum LineRowStyle {
    static func activeColor(_ line: LineStatus) -> Color {
        if line.state == .waitingRelay {
            return SentinelTheme.Colors.info
        }
        if line.state == .dead, line.note != nil {
            return SentinelTheme.Colors.success
        }
        if line.requiresAttention {
            return SentinelTheme.Colors.danger
        }
        if line.state.isRetrying || line.hasStaleRollout {
            return SentinelTheme.Colors.warning
        }
        if case .unknown = line.state {
            return SentinelTheme.Colors.warning
        }
        return SentinelTheme.Colors.success
    }

    static func activeSoftColor(_ line: LineStatus) -> Color {
        if line.state == .waitingRelay {
            return SentinelTheme.Colors.infoSoft
        }
        if line.state == .dead, line.note != nil {
            return SentinelTheme.Colors.successSoft
        }
        if line.requiresAttention {
            return SentinelTheme.Colors.dangerSoft
        }
        if line.state.isRetrying || line.hasStaleRollout {
            return SentinelTheme.Colors.warningSoft
        }
        if case .unknown = line.state {
            return SentinelTheme.Colors.warningSoft
        }
        return SentinelTheme.Colors.successSoft
    }

    static func rowTone(_ line: LineStatus) -> SentinelRowTone {
        if line.state == .dead, line.note != nil {
            return .success
        }
        if line.requiresAttention {
            return .danger
        }
        if line.state.isRetrying || line.hasStaleRollout {
            return .warning
        }
        if case .unknown = line.state {
            return .warning
        }
        return .primary
    }

    /// v3.2 第 2 点：把看不懂的「轮转 N 秒」（rollout 心跳距今秒数）改人话分档。
    /// <60s 工作中(灰)；60–600s N 分钟没动静(橙)；>600s 卡住守护重拉中(橙)。
    /// 「重拉 N 次」在 metadata 里保留（即他要的重试次数）。
    static func rolloutPhrase(for line: LineStatus) -> (text: String, color: Color)? {
        guard let seconds = line.rolloutAgeSeconds else {
            return nil
        }
        if seconds < 60 {
            return ("工作中", SentinelTheme.Colors.secondaryForeground)
        }
        if seconds <= 600 {
            let minutes = max(1, Int((seconds / 60).rounded(.down)))
            return ("\(minutes) 分钟没动静", SentinelTheme.Colors.warning)
        }
        return ("卡住，守护重拉中", SentinelTheme.Colors.warning)
    }

    static func metadata(_ line: LineStatus, attribution: RelayAttribution) -> String? {
        var parts: [String] = []
        // v3.2 第 3 点：目录名与 slug 同名时省略；分支 codex/<slug> 同理。slug 全卡最多出现一次。
        if let worktreeName = line.worktreeName, worktreeName != line.slug {
            parts.append(worktreeName)
        }
        if let branch = line.branch, branch != "codex/\(line.slug)" {
            parts.append(branch)
        }
        if let model = line.model {
            parts.append(model)
        }
        if line.reportsRestarts, line.restarts > 0 {
            parts.append("重拉 \(line.restarts) 次")
        }
        if line.reportsCodexChannelTelemetry, attribution.isReported {
            parts.append(attribution.text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func forceStartBadgeHelp(_ forceStart: LineForceStart?) -> String {
        var parts = ["本线已进入手动接管强制模式"]
        if let activatedBy = forceStart?.activatedBy, !activatedBy.isEmpty {
            parts.append("来源 \(activatedBy)")
        }
        if let activatedAt = forceStart?.activatedAt, !activatedAt.isEmpty {
            parts.append("生效 \(activatedAt)")
        }
        return parts.joined(separator: " · ")
    }
}

extension CodexLineRegistration {
    var sourceConversationText: String {
        var value = dispatcherZH.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("Claude 对话：") {
            value.removeFirst("Claude 对话：".count)
        }
        value = value.replacingOccurrences(of: "（Air）", with: "")
        if !value.hasSuffix("对话") {
            value += "对话"
        }
        return "来自：\(value)"
    }
}

struct EngineBadge: View {
    let engine: LineEngine

    var body: some View {
        Text(engine.displayName)
            .sentinelBadge(
                foreground: engine.isCursorGrok
                    ? SentinelTheme.Colors.info
                    : SentinelTheme.Colors.secondaryForeground,
                background: engine.isCursorGrok
                    ? SentinelTheme.Colors.infoSoft
                    : SentinelTheme.Colors.inset
            )
            .accessibilityLabel("引擎 \(engine.displayName)")
    }
}

struct HostBadge: View {
    let origin: LineHostOrigin

    var body: some View {
        Text(origin.badgeText)
            .lineLimit(1)
            .sentinelBadge(
                foreground: origin.isRemote
                    ? SentinelTheme.Colors.info
                    : origin.isUnknown
                        ? SentinelTheme.Colors.warning
                        : SentinelTheme.Colors.secondaryForeground,
                background: origin.isRemote
                    ? SentinelTheme.Colors.infoSoft
                    : origin.isUnknown
                        ? SentinelTheme.Colors.warningSoft
                        : SentinelTheme.Colors.inset
            )
            .accessibilityLabel("机器 \(origin.badgeText)")
    }
}

struct LineStateBadge: View {
    let line: LineStatus

    var body: some View {
        let presentation = LineDispositionPresentation(line: line)
        HStack(spacing: SentinelTheme.Spacing.xxs) {
            Image(systemName: presentation.symbolName)
                .imageScale(.small)
            Text(presentation.stateText)
        }
        .sentinelBadge(
            foreground: LineRowStyle.activeColor(line),
            background: LineRowStyle.activeSoftColor(line)
        )
    }
}

struct ForceStartBadge: View {
    let line: LineStatus

    var body: some View {
        if let text = SentinelForceStartAction.activeBadgeText(for: line) {
            Text(text)
                .sentinelBadge(
                    foreground: SentinelTheme.Colors.primary,
                    background: SentinelTheme.Colors.primarySoft
                )
                .help(LineRowStyle.forceStartBadgeHelp(line.forceStart))
                .accessibilityLabel("\(line.slug) \(text)")
                .accessibilityIdentifier("force-start-active-\(line.slug)")
        }
    }
}

struct LineDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: SentinelTheme.Spacing.sm) {
            Text(label)
                .font(SentinelTheme.Fonts.metadata)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(SentinelTheme.Fonts.metadata)
                .foregroundStyle(SentinelTheme.Colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct OfficialQuotaRowsView: View {
    let balance: RelayBalance?

    var body: some View {
        ForEach(
            Array(OfficialQuotaPresentation.rows(for: balance).enumerated()),
            id: \.offset
        ) { _, row in
            Text(row.text)
                .font(SentinelTheme.Fonts.metadata)
                .foregroundStyle(
                    row.isWarning
                        ? SentinelTheme.Colors.warning
                        : SentinelTheme.Colors.secondaryForeground
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RelayProbeDetailsView: View {
    let probe: LineRelayProbe

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            ForEach(
                Array(LineRelayProbePresentation.details(for: probe).enumerated()),
                id: \.offset
            ) { _, detail in
                LineDetailRow(label: detail.label, value: detail.value)
            }
        }
        .padding(.top, SentinelTheme.Spacing.xxs)
    }
}

/// 处置结论标记 + 展开的备注全文。展开状态由分区持有，行只拿到自己的布尔值。
struct LineNoteSectionView: View {
    let line: LineStatus
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        let presentation = LineDispositionPresentation(line: line)
        if let markerText = presentation.markerText, let note = presentation.note {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                Button(action: onToggle) {
                    HStack(spacing: SentinelTheme.Spacing.xs) {
                        Image(systemName: "checkmark.seal.fill")
                            .imageScale(.small)
                        Text(markerText)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.success)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(markerText)，\(isExpanded ? "已展开" : "已折叠")")

                if isExpanded {
                    Text(note)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("line-note-detail-\(line.slug)")
                }
            }
            .padding(.top, SentinelTheme.Spacing.xxs)
        }
    }
}

/// 「有登记的」活跃派工行。
struct RegisteredLineRow: View {
    let presentation: LinePresentation
    let hostOrigin: LineHostOrigin
    let attribution: RelayAttribution
    let logsDirectory: URL
    let isNoteExpanded: Bool
    let onToggleNote: () -> Void
    let onShowSettings: (LineStatus) -> Void

    var body: some View {
        let line = presentation.line
        let registration = presentation.registration
        HStack(alignment: .top, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(LineRowStyle.activeColor(line))
                .frame(
                    width: SentinelTheme.Metrics.statusDot,
                    height: SentinelTheme.Metrics.statusDot
                )
                .padding(.top, SentinelTheme.Spacing.xs)

            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.xs) {
                    Text(registration?.labelZH ?? line.slug)
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    EngineBadge(engine: presentation.engine)
                    HostBadge(origin: hostOrigin)
                }

                if let registration {
                    Text(registration.sourceConversationText)
                        .font(SentinelTheme.Fonts.subtitle)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                }

                Text(line.slug)
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)

                if let metadata = LineRowStyle.metadata(line, attribution: attribution) {
                    Text(metadata)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(2)
                }

                if let rollout = LineRowStyle.rolloutPhrase(for: line) {
                    Text(rollout.text)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(rollout.color)
                }

                if line.balance != nil {
                    OfficialQuotaRowsView(balance: line.balance)
                }

                if line.state == .waitingRelay, let relayProbe = line.relayProbe {
                    RelayProbeDetailsView(probe: relayProbe)
                }

                LineNoteSectionView(
                    line: line,
                    isExpanded: isNoteExpanded,
                    onToggle: onToggleNote
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xs) {
                LineStateBadge(line: line)
                ForceStartBadge(line: line)
                if let startedAt = line.startedAt {
                    Text(SentinelTimeFormat.shortTime(startedAt))
                        .font(SentinelTheme.Fonts.rowTime)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .help("启动时刻")
                }
                SentinelLineControls(
                    line: line,
                    engine: presentation.engine,
                    logsDirectory: logsDirectory,
                    onShowSettings: onShowSettings
                )
            }
        }
        .sentinelRow(tone: LineRowStyle.rowTone(line))
    }
}

/// 「最近完成」一行；v3.2 第 4 点：整行可点，展开显示来源对话 / 标识 /
/// 启动→完成 / 重拉次数 / 通道归因。
struct CompletedLineRow: View {
    let presentation: LinePresentation
    let hostOrigin: LineHostOrigin
    let attribution: RelayAttribution
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    var body: some View {
        let line = presentation.line
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.md) {
                Circle()
                    .fill(
                        line.state == .done
                            ? SentinelTheme.Colors.success
                            : SentinelTheme.Colors.secondaryForeground
                    )
                    .frame(
                        width: SentinelTheme.Metrics.statusDot,
                        height: SentinelTheme.Metrics.statusDot
                    )

                HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.xs) {
                    Text(presentation.registration?.labelZH ?? line.slug)
                        .font(SentinelTheme.Fonts.body)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    EngineBadge(engine: presentation.engine)
                    HostBadge(origin: hostOrigin)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xxs) {
                    if let outcome = LineTerminalOutcomePresentation.label(for: line.state) {
                        Text(outcome)
                            .font(SentinelTheme.Fonts.badge)
                            .foregroundStyle(
                                line.state == .done
                                    ? SentinelTheme.Colors.success
                                    : SentinelTheme.Colors.secondaryForeground
                            )
                    }
                    if let completedAt = line.sourceModifiedAt {
                        Text(SentinelTimeFormat.shortTime(completedAt))
                            .font(SentinelTheme.Fonts.rowTime)
                            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(SentinelTheme.Fonts.axisLabel.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }

            // COR-502 修改五：终态线落在「最近完成」这一档时，处置结论原先
            // 只在展开后的详情里，折叠着看不出「已经有人处理过」。
            // 这里补一行折叠态就能看见的标记，全文仍在展开的详情里。
            if let markerText = LineDispositionPresentation(line: line).markerText {
                HStack(spacing: SentinelTheme.Spacing.xs) {
                    Image(systemName: "checkmark.seal.fill")
                        .imageScale(.small)
                    Text(markerText)
                }
                .font(SentinelTheme.Fonts.metadata)
                .foregroundStyle(SentinelTheme.Colors.success)
                .padding(.leading, SentinelTheme.Metrics.statusDot + SentinelTheme.Spacing.md)
                .accessibilityIdentifier("completed-note-marker-\(line.slug)")
            }

            if isExpanded {
                detail
                    .padding(.leading, SentinelTheme.Metrics.statusDot + SentinelTheme.Spacing.md)
            }
        }
        .padding(.horizontal, SentinelTheme.Spacing.md)
        .padding(.vertical, SentinelTheme.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                onToggleExpanded()
            }
        }
        .accessibilityLabel(
            "\(presentation.registration?.labelZH ?? line.slug)，\(isExpanded ? "已展开" : "已折叠")"
        )
    }

    private var detail: some View {
        let line = presentation.line
        let started = line.startedAt.map { SentinelTimeFormat.shortTime($0) } ?? "未知"
        let finished = line.sourceModifiedAt.map { SentinelTimeFormat.shortTime($0) } ?? "未知"
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            if let registration = presentation.registration {
                LineDetailRow(label: "来源", value: registration.sourceConversationText)
            }
            LineDetailRow(label: "标识", value: line.slug)
            LineDetailRow(label: "运行", value: "\(started) → \(finished)")
            if line.reportsRestarts {
                LineDetailRow(label: "重拉", value: line.restarts > 0 ? "\(line.restarts) 次" : "无")
            }
            if line.reportsCodexChannelTelemetry, attribution.isReported {
                LineDetailRow(label: "通道", value: attribution.text)
            }
            if let note = line.note {
                LineDetailRow(label: "备注", value: note)
            }
        }
    }
}

/// 自动识别（未登记且活跃）的行。
struct AutomaticLineRow: View {
    let line: LineStatus
    let attribution: RelayAttribution
    let logsDirectory: URL
    let isNoteExpanded: Bool
    let onToggleNote: () -> Void
    let onShowSettings: (LineStatus) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(LineRowStyle.activeColor(line))
                .frame(
                    width: SentinelTheme.Metrics.statusDot,
                    height: SentinelTheme.Metrics.statusDot
                )
                .padding(.top, SentinelTheme.Spacing.xs)

            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.xs) {
                    Text(line.slug)
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                    EngineBadge(engine: line.engine)
                }
                Text("未登记，信息可能不准")
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(SentinelTheme.Colors.warning)
                if let metadata = LineRowStyle.metadata(line, attribution: attribution) {
                    Text(metadata)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(2)
                }

                if let rollout = LineRowStyle.rolloutPhrase(for: line) {
                    Text(rollout.text)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(rollout.color)
                }

                if line.balance != nil {
                    OfficialQuotaRowsView(balance: line.balance)
                }

                if line.state == .waitingRelay, let relayProbe = line.relayProbe {
                    RelayProbeDetailsView(probe: relayProbe)
                }

                LineNoteSectionView(
                    line: line,
                    isExpanded: isNoteExpanded,
                    onToggle: onToggleNote
                )
            }

            Spacer()

            VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xs) {
                LineStateBadge(line: line)
                ForceStartBadge(line: line)
                SentinelLineControls(
                    line: line,
                    logsDirectory: logsDirectory,
                    onShowSettings: onShowSettings
                )
            }
        }
        .sentinelRow(tone: LineRowStyle.rowTone(line))
    }
}

/// 自动识别里已经终态的行。
struct AutomaticCompletedLineRow: View {
    let line: LineStatus

    var body: some View {
        HStack(alignment: .center, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(
                    line.state == .done
                        ? SentinelTheme.Colors.success
                        : SentinelTheme.Colors.secondaryForeground
                )
                .frame(
                    width: SentinelTheme.Metrics.statusDot,
                    height: SentinelTheme.Metrics.statusDot
                )

            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.xs) {
                    Text(line.slug)
                        .font(SentinelTheme.Fonts.body)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .lineLimit(1)
                    EngineBadge(engine: line.engine)
                }
                Text("未登记，信息可能不准")
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }

            Spacer()

            Text(LineTerminalOutcomePresentation.label(for: line.state) ?? line.state.displayName)
                .font(SentinelTheme.Fonts.badge)
                .foregroundStyle(
                    line.state == .done
                        ? SentinelTheme.Colors.success
                        : SentinelTheme.Colors.secondaryForeground
                )
        }
        .sentinelRow(tone: .normal)
    }
}

/// 没有状态文件、只从进程表看见的 Codex 进程行。
struct AutomaticProcessRow: View {
    let process: OtherCodexProcess

    var body: some View {
        HStack(alignment: .top, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(SentinelTheme.Colors.info)
                .frame(
                    width: SentinelTheme.Metrics.statusDot,
                    height: SentinelTheme.Metrics.statusDot
                )
                .padding(.top, SentinelTheme.Spacing.xs)

            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                Text(
                    process.worktreeName == "目录未知"
                        ? "Codex 进程"
                        : process.worktreeName
                )
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)

                Text("未登记，信息可能不准")
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(SentinelTheme.Colors.warning)

                Text("进程 \(process.processID) · 已运行 \(process.elapsed)")
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }

            Spacer()
        }
        .sentinelRow(tone: .normal)
    }
}

/// 历史区的一行。
struct HistoryLineRow: View {
    let presentation: LinePresentation
    let hostOrigin: LineHostOrigin
    let isNoteExpanded: Bool
    let onToggleNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            HStack(alignment: .top, spacing: SentinelTheme.Spacing.md) {
                Circle()
                    .fill(SentinelTheme.Colors.secondaryForeground)
                    .frame(
                        width: SentinelTheme.Metrics.statusDot,
                        height: SentinelTheme.Metrics.statusDot
                    )
                    .padding(.top, SentinelTheme.Spacing.xs)

                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.xs) {
                        Text(presentation.registration?.labelZH ?? presentation.line.slug)
                            .font(SentinelTheme.Fonts.body)
                            .foregroundStyle(SentinelTheme.Colors.foreground)
                            .lineLimit(2)
                        EngineBadge(engine: presentation.engine)
                        HostBadge(origin: hostOrigin)
                    }

                    if let registration = presentation.registration {
                        Text(registration.sourceConversationText)
                            .font(SentinelTheme.Fonts.subtitle)
                            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    }

                    Text(presentation.line.slug)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xxs) {
                    Text(LineDispositionPresentation(line: presentation.line).stateText)
                        .font(SentinelTheme.Fonts.badge)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    if let modifiedAt = presentation.line.sourceModifiedAt {
                        Text(SentinelTimeFormat.shortTime(modifiedAt))
                            .font(SentinelTheme.Fonts.rowTime)
                            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    }
                }
            }

            LineNoteSectionView(
                line: presentation.line,
                isExpanded: isNoteExpanded,
                onToggle: onToggleNote
            )
        }
        .sentinelRow(tone: .normal)
    }
}
