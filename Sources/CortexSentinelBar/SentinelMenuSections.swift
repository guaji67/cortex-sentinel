import AppKit
import SwiftUI

/// 面板的分区视图。2026-08-24 从单个 1798 行的 SentinelMenuView body 拆出来：
/// 每个分区是独立 View struct，只读自己需要的 store 属性。@Observable 按
/// 「谁读了什么」决定失效范围——余额回来只重算余额分区，线列表分区在
/// Falcon 滑动时保持安静。**别把跨区的读取加回来**：任何一个分区读了
/// store.aio 这类高频面，它就会跟着那个面一起失效。
enum SentinelSectionChrome {
    static func sectionTitle(_ title: String, trailing: String?) -> some View {
        HStack(spacing: SentinelTheme.Spacing.md) {
            Text(title)
                .font(SentinelTheme.Fonts.section)
                .kerning(0.5)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            Spacer()
            if let trailing {
                Text(trailing)
                    .sentinelBadge(
                        foreground: SentinelTheme.Colors.secondaryForeground,
                        background: SentinelTheme.Colors.inset
                    )
            }
        }
    }

    static func compactDiagnosticRow(title: String, status: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.md) {
            Text(title)
                .font(SentinelTheme.Fonts.section)
                .kerning(0.5)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            Text(status)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func emptyState(_ text: String) -> some View {
        Text(text)
            .font(SentinelTheme.Fonts.subtitle)
            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sentinelRow()
    }

    static func collapsibleSection<Content: View>(
        title: String,
        count: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: SentinelTheme.Spacing.md) {
                    Image(systemName: "chevron.right")
                        .font(SentinelTheme.Fonts.axisLabel.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .frame(
                            width: SentinelTheme.Metrics.disclosureChevron,
                            height: SentinelTheme.Metrics.disclosureChevron
                        )
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)

                    Text(title)
                        .font(SentinelTheme.Fonts.section)
                        .kerning(0.5)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)

                    Spacer()

                    Text("\(count)")
                        .sentinelBadge(
                            foreground: SentinelTheme.Colors.secondaryForeground,
                            background: SentinelTheme.Colors.inset
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)，\(isExpanded.wrappedValue ? "已展开" : "已折叠")")

            if isExpanded.wrappedValue {
                content()
                    .padding(.top, SentinelTheme.Spacing.sm)
            }
        }
    }
}

/// 标题 + 副标题。读：paths（监视目录缺失）、lineGroups / boardWindow / localHost（计数）。
struct SentinelHeaderSection: View {
    var store: SentinelStore

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            Text("Cortex 哨兵")
                .font(SentinelTheme.Fonts.title)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            Text(subtitle)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if store.watchDirectoryMissing {
            return SentinelPaths.missingWatchDirectoryTitle
        }
        let localHost = store.localHost
        let origins = store.lineGroups.activeHostOriginCounts(localHost: localHost)
        return SentinelBoardCopy.headerSubtitle(
            localActiveCount: origins.local,
            recentCount: store.boardWindow.recentShown.count,
            offHostActiveCount: origins.remote + origins.unknown
        )
    }
}

/// 面板打包分区的挂载判据。分区 View 和生产路径父 body 都不在这里之外另写一套。
@MainActor
enum SentinelPackagingPresentation {
    static func activeSnapshot(from store: SentinelStore) -> PackagingProgressSnapshot? {
        guard let packaging = store.packagingProgress, packaging.isActive else {
            return nil
        }
        return packaging
    }
}

/// Cortex 打包进度：只在 running 时出现，failed/completed 残留不占地方。读：packagingProgress。
struct SentinelPackagingSection: View {
    var store: SentinelStore
    var bodyCounter: SentinelViewBodyCounter? = nil

    var body: some View {
        let _ = bodyCounter?.increment()
        if let packaging = SentinelPackagingPresentation.activeSnapshot(from: store) {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.sm) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(SentinelTheme.Colors.warning)
                    Text("Cortex 打包")
                        .font(SentinelTheme.Fonts.section)
                        .foregroundStyle(SentinelTheme.Colors.warning)
                    Spacer()
                    Text(packaging.etaText)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.warning)
                }

                Text(packaging.stepTitle)
                    .font(SentinelTheme.Fonts.rowTitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)

                if let detail = packaging.detailText {
                    Text(detail)
                        .font(SentinelTheme.Fonts.subtitle)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let updatedAt = packaging.updatedAt {
                    Text("更新于 \(SentinelTimeFormat.clockTime(updatedAt))")
                        .font(SentinelTheme.Fonts.rowTime)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                }
            }
            .sentinelRow(tone: .warning)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(packaging.accessibilityText)
            .accessibilityIdentifier("packaging-progress")
        }
    }
}

/// 通道两卡（Codex / Grok）。读：channelStatus、lineGroups（本机引擎计数）、localHost。
/// 2026-09-04 Falcon 令：ox-alpha 卡从面板撤掉，只留 Codex 和 Grok；
/// 磁盘摘要里的 claude-oxalpha 键继续解析，只是不再画卡。
struct SentinelChannelSection: View {
    var store: SentinelStore

    var body: some View {
        let presentation = ChannelSectionPresentation(
            grok: store.channelStatus.grok,
            codex: store.channelStatus.codex,
            liveCounts: store.lineGroups.localActiveEngineCounts(localHost: store.localHost)
        )
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            SentinelSectionChrome.sectionTitle("通道", trailing: updatedText)

            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                channelItem(presentation.codex)
                Spacer(minLength: SentinelTheme.Spacing.md)
                channelItem(presentation.grok)
            }

            ForEach(Array(presentation.problemLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(SentinelTheme.Fonts.balanceMeta)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var updatedText: String? {
        guard let generatedAt = store.channelStatus.generatedAt else {
            return nil
        }
        return SentinelTimeFormat.clockTime(generatedAt)
    }

    private func channelItem(_ item: ChannelItemPresentation) -> some View {
        HStack(alignment: .center, spacing: SentinelTheme.Spacing.xs) {
            Circle()
                .fill(item.verdict.status.color)
                .frame(
                    width: SentinelTheme.Metrics.balanceDot,
                    height: SentinelTheme.Metrics.balanceDot
                )

            Text(item.name)
                .font(SentinelTheme.Fonts.balanceName)
                .foregroundStyle(SentinelTheme.Colors.foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            Text(item.verdict.statusText)
                .font(SentinelTheme.Fonts.balanceAmount)
                .foregroundStyle(item.verdict.status.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            if let countText = item.countText {
                Text(countText)
                    .font(SentinelTheme.Fonts.balanceMeta)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .accessibilityIdentifier(item.accessibilityIdentifier)
        .accessibilityLabel(item.itemText)
    }
}

/// Input 服务。读：inputStatus。
struct SentinelServiceSection: View {
    var store: SentinelStore

    var body: some View {
        let probes = store.inputStatus.displayProbes()
        switch InputServiceSectionPresentation.resolve(probes: probes) {
        case let .compact(statusText):
            SentinelSectionChrome.compactDiagnosticRow(title: "Input 服务", status: statusText)
        case .expanded:
            expandedSection(probes: probes)
        }
    }

    private func expandedSection(probes: [InputStatusDisplayProbe]) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
            Text("Input 服务")
                .font(SentinelTheme.Fonts.section)
                .kerning(0.5)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(probes) { display in
                serviceModelBlock(display)
            }

            historyAxis

            if let updatedAt = store.inputStatus.generatedAt ?? store.inputStatus.readAt {
                Text("更新于 \(SentinelTimeFormat.clockTime(updatedAt))")
                    .font(SentinelTheme.Fonts.rowTime)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }
        }
        .padding(SentinelTheme.Spacing.lg)
        .background(SentinelTheme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel)
                .stroke(
                    store.inputStatus.allOK == false
                        ? SentinelTheme.Colors.warningBorder
                        : SentinelTheme.Colors.border,
                    lineWidth: SentinelTheme.Metrics.borderWidth
                )
        )
    }

    private func serviceModelBlock(_ display: InputStatusDisplayProbe) -> some View {
        // v3.2 第 1/8 点：圆点用统一 indicatorTone（含高延迟橙档，与状态栏一致），
        // 状态复述文字（在线/高延迟/失败）整个删掉，红黄绿颜色自解释。
        let tone = InputStatusPresentation.indicatorTone(for: display)
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.sm) {
                Text(display.probe.model)
                    .font(SentinelTheme.Fonts.serviceModel)
                    .foregroundStyle(SentinelTheme.Colors.foreground)

                Circle()
                    .fill(tone.color)
                    .frame(
                        width: SentinelTheme.Metrics.statusDot,
                        height: SentinelTheme.Metrics.statusDot
                    )

                Spacer()

                Text("可用率")
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                Text(uptimeText(display.probe.uptimePercentage))
                    .font(SentinelTheme.Fonts.serviceValue)
                    .foregroundStyle(
                        InputStatusPresentation.uptimeSeverity(display.probe.uptimePercentage).color
                    )
                Text("样本")
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                Text(display.probe.sampleCountText)
                    .font(SentinelTheme.Fonts.serviceValue)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }
            .help(latencyHelpText(display))

            historyStrip(display.probe.history)
        }
    }

    private func historyStrip(_ history: [InputStatusHistoryPoint]) -> some View {
        let padded = InputStatusPresentation.paddedHistory(history)
        return HStack(spacing: SentinelTheme.Metrics.historyBarGap) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, point in
                RoundedRectangle(
                    cornerRadius: SentinelTheme.Metrics.historyBarCornerRadius
                )
                .fill(InputStatusPresentation.historyTone(point).color)
                .frame(maxWidth: .infinity)
                .help(InputStatusPresentation.cellHelpText(point))
            }
        }
        .frame(height: SentinelTheme.Metrics.historyBarHeight)
    }

    private var historyAxis: some View {
        HStack {
            Text("-60m")
            Spacer()
            Text("-45m")
            Spacer()
            Text("-30m")
            Spacer()
            Text("-15m")
            Spacer()
            Text("现在")
        }
        .font(SentinelTheme.Fonts.axisLabel)
        .foregroundStyle(SentinelTheme.Colors.secondaryForeground.opacity(0.75))
    }

    private func uptimeText(_ value: Double?) -> String {
        value.map { String(format: "%.2f%%", $0) } ?? "--"
    }

    private func latencyHelpText(_ display: InputStatusDisplayProbe) -> String {
        var parts = ["\(display.probe.model)：\(display.state.displayName)"]
        if let latency = display.probe.latencyMilliseconds {
            parts.append("最近一次 \(latency) 毫秒")
        }
        if let uptime = display.probe.uptimePercentage {
            parts.append("可用率 \(String(format: "%.2f%%", uptime))")
        }
        return parts.joined(separator: " · ")
    }
}

/// 余额（官方额度 + 中转各账号）。读：aio、officialUsage、两个手动刷新标志。
struct SentinelBalancesSection: View {
    var store: SentinelStore

    var body: some View {
        switch BalanceSectionPresentation.resolve(
            official: store.officialUsage,
            aio: store.aio,
            glm: store.glmUsage
        ) {
        case let .compact(statusText):
            SentinelSectionChrome.compactDiagnosticRow(title: "余额", status: statusText)
        case .unread:
            unreadSection
        case .expanded:
            expandedSection
        }
    }

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            SentinelSectionChrome.sectionTitle(
                "余额",
                trailing: SentinelTopChannelPresentation(aio: store.aio).balanceCountText
            )

            glmUsageRows

            cursorUsageRow

            officialUsageRow

            switch store.aio.sourceState {
            case .unconfigured, .invalid:
                EmptyView()
            case .available:
                if relayBalanceProviders.isEmpty {
                    SentinelSectionChrome.emptyState("没有可显示的中转余额")
                } else {
                    VStack(spacing: SentinelTheme.Metrics.balanceRowSpacing) {
                        ForEach(relayBalanceProviders) { provider in
                            balanceRow(provider)
                        }
                    }
                }
            }
        }
    }

    /// 智谱 GLM Coding Plan 额度：每把 key 一行（5 小时窗 + 周窗两组剩余百分比），
    /// 排在 Cursor 前面。没识别到 key 就不占位。
    @ViewBuilder private var glmUsageRows: some View {
        if store.glmUsage.accounts.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: SentinelTheme.Metrics.balanceRowSpacing) {
                ForEach(store.glmUsage.accounts) { account in
                    glmUsageRow(account)
                }
            }
        }
    }

    private func glmUsageRow(_ account: GLMAccountUsage) -> some View {
        HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
            Circle()
                .fill(glmUsageStatusColor(account))
                .frame(
                    width: SentinelTheme.Metrics.balanceDot,
                    height: SentinelTheme.Metrics.balanceDot
                )
            Text(account.displayTitle)
                .font(SentinelTheme.Fonts.balanceName)
                .foregroundStyle(SentinelTheme.Colors.foreground)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: SentinelTheme.Spacing.xs)
            if let failureText = glmUsageFailureText(account) {
                // 查失败或没订阅额度就如实说一句，不摆「5h —」的空架子。
                Text(failureText)
                    .font(SentinelTheme.Fonts.balanceMeta)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            } else {
                HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                    cursorUsageSegment("5h", account.fiveHourWindow?.percentUsed)
                    cursorUsageDivider
                    cursorUsageSegment("周", account.weeklyWindow?.percentUsed)
                    if account.cashBalance != nil {
                        cursorUsageDivider
                        glmBalanceSegment(account)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }
        }
        .frame(height: 38)
        .contentShape(Rectangle())
        .help(glmUsageTooltip(account))
    }

    /// 无数字时的右侧文案：优先报错，其次「无订阅额度」。
    private func glmUsageFailureText(_ account: GLMAccountUsage) -> String? {
        if account.hasDisplayableNumber {
            return nil
        }
        if let errorMessage = account.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return "无订阅额度"
    }

    /// 现金余额段：走 /api/paas/v4 按量端点的链路（ClaudeZ）烧的就是这笔。
    /// 快见底变橙，烧穿变红。
    @ViewBuilder
    private func glmBalanceSegment(_ account: GLMAccountUsage) -> some View {
        if let cash = account.cashBalance {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("余")
                    .font(SentinelTheme.Fonts.balanceAmount)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .lineLimit(1)
                Text(String(format: "¥%.2f", cash))
                    .font(SentinelTheme.Fonts.balanceAmount)
                    .foregroundStyle(cash <= 0
                        ? SentinelTheme.Colors.danger
                        : cash < GLMUsageConstants.lowCashBalance
                            ? SentinelTheme.Colors.warning
                            : SentinelTheme.Colors.foreground)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .help(glmBalanceTooltip(account))
        }
    }

    private func glmBalanceTooltip(_ account: GLMAccountUsage) -> String {
        guard let cash = account.cashBalance else {
            return ""
        }
        var text = "现金余额 ¥\(String(format: "%.2f", cash))（按量计费）"
        if let spend = account.totalSpendAmount {
            text += " · 累计消费 ¥\(String(format: "%.2f", spend))"
        }
        return text
    }

    private func glmUsageStatusColor(_ account: GLMAccountUsage) -> Color {
        if account.stale {
            return SentinelTheme.Colors.warning
        }
        let hasLow = [account.fiveHourWindow?.percentUsed, account.weeklyWindow?.percentUsed]
            .compactMap { $0 }
            .contains { (100 - $0) <= 100 - AIOConstants.quotaWarningThreshold }
        if hasLow
            || account.cashBalance.map { $0 < GLMUsageConstants.lowCashBalance } == true {
            return SentinelTheme.Colors.warning
        }
        return account.hasDisplayableNumber
            ? SentinelTheme.Colors.success
            : SentinelTheme.Colors.secondaryForeground
    }

    private func glmUsageTooltip(_ account: GLMAccountUsage) -> String {
        var parts = ["GLM Coding Plan · \(account.displayTitle)"]
        if let level = account.level, !level.isEmpty {
            parts.append("档位 \(level)")
        }
        for (name, window) in [("5小时", account.fiveHourWindow), ("周", account.weeklyWindow)] {
            guard let window else {
                continue
            }
            var piece = "\(name) "
            if let used = window.usedPoints, let total = window.totalPoints, total > 0 {
                piece += "已用 \(Self.pointsText(used)) / \(Self.pointsText(total)) 积分"
            } else if let percent = window.percentUsed {
                piece += "已用 \(Int(percent.rounded()))%"
            }
            if let resetAt = window.resetAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M/d HH:mm"
                piece += "，\(formatter.string(from: resetAt)) 重置"
            }
            parts.append(piece)
        }
        if let checkedAt = account.checkedAt {
            parts.append("\(SentinelTimeFormat.clockTime(checkedAt)) 更新")
        }
        if account.stale {
            parts.append("已过期")
        }
        if let errorMessage = account.errorMessage {
            parts.append(errorMessage)
        }
        return parts.joined(separator: " · ")
    }

    /// 积分数字按官方口径缩写：2201 → 2,201；12000 → 1.2万。
    static func pointsText(_ value: Double) -> String {
        if value >= 10_000 {
            let wan = value / 10_000
            let text = wan.rounded() == wan ? String(Int(wan)) : String(format: "%.1f", wan)
            return "\(text)万"
        }
        let rounded = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return rounded
    }

    /// Cursor 订阅余额：三组（模式 / API / Bot）排成一行，只报剩余百分比。
    /// 本机没装或没登录 Cursor 时不占位。
    @ViewBuilder private var cursorUsageRow: some View {
        let snapshot = store.cursorUsage
        switch snapshot.sourceState {
        case .unconfigured:
            EmptyView()
        case .invalid:
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Circle()
                    .fill(SentinelTheme.Colors.secondaryForeground)
                    .frame(
                        width: SentinelTheme.Metrics.balanceDot,
                        height: SentinelTheme.Metrics.balanceDot
                    )
                Text("Cursor")
                    .font(SentinelTheme.Fonts.balanceName)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                    .lineLimit(1)
                Spacer(minLength: SentinelTheme.Spacing.xs)
                Text(snapshot.errorMessage ?? "暂不可用")
                    .font(SentinelTheme.Fonts.balanceMeta)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 38)
            .contentShape(Rectangle())
        case .available:
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Circle()
                    .fill(cursorUsageStatusColor(snapshot))
                    .frame(
                        width: SentinelTheme.Metrics.balanceDot,
                        height: SentinelTheme.Metrics.balanceDot
                    )
                Text("Cursor")
                    .font(SentinelTheme.Fonts.balanceName)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: SentinelTheme.Spacing.xs)
                // 三组余额：小灰标签 + 大数字，各组按剩余独立变色——
                // 哪组快用完一眼扫出来，而不是整行一个颜色糊在一起。
                HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                    cursorUsageSegment("Grok", snapshot.autoPercentUsed)
                    cursorUsageDivider
                    cursorUsageSegment("API", snapshot.apiPercentUsed)
                    cursorUsageDivider
                    cursorUsageSegment("Bot", snapshot.botPercentUsed)
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }
            .frame(height: 38)
            .contentShape(Rectangle())
            .help(cursorUsageTooltip(snapshot))
        }
    }

    private var cursorUsageDivider: some View {
        Circle()
            .fill(SentinelTheme.Colors.secondaryForeground.opacity(0.45))
            .frame(width: 2.5, height: 2.5)
    }

    private func cursorUsageSegment(
        _ label: String,
        _ percentUsed: Double?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(SentinelTheme.Fonts.balanceAmount)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .lineLimit(1)
            if let percentUsed {
                let remaining = min(100, max(0, 100 - percentUsed))
                Text(cursorUsageRemainingText(remaining))
                    .font(SentinelTheme.Fonts.balanceAmount)
                    .foregroundStyle(cursorUsageRemainingColor(remaining))
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(SentinelTheme.Fonts.balanceAmount)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .lineLimit(1)
            }
        }
    }

    private func cursorUsageRemainingText(_ remaining: Double) -> String {
        let rounded = remaining.rounded() == remaining
            ? String(Int(remaining))
            : String(format: "%.1f", remaining)
        return "\(rounded)%"
    }

    /// 剩得越少越红：0 附近红，低档黄，其余正常白。与中转余额同一套档位。
    private func cursorUsageRemainingColor(_ remaining: Double) -> Color {
        if remaining <= 0.05 {
            return SentinelTheme.Colors.danger
        }
        if remaining <= 100 - AIOConstants.quotaWarningThreshold {
            return SentinelTheme.Colors.warning
        }
        return SentinelTheme.Colors.foreground
    }

    private func cursorUsageStatusColor(_ snapshot: CursorUsageSnapshot) -> Color {
        if snapshot.stale {
            return SentinelTheme.Colors.warning
        }
        let hasLow = [snapshot.autoPercentUsed, snapshot.apiPercentUsed, snapshot.botPercentUsed]
            .compactMap { $0 }
            .contains { (100 - $0) <= 100 - AIOConstants.quotaWarningThreshold }
        return hasLow ? SentinelTheme.Colors.warning : SentinelTheme.Colors.success
    }

    private func cursorUsageTooltip(_ snapshot: CursorUsageSnapshot) -> String {
        var parts = ["Cursor 订阅 · 剩余百分比（Grok / API / Bot）"]
        if let resetDate = snapshot.botResetDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M/d HH:mm"
            parts.append("Bot \(formatter.string(from: resetDate)) 重置")
        }
        if let checkedAt = snapshot.checkedAt {
            parts.append("\(SentinelTimeFormat.clockTime(checkedAt)) 更新")
        }
        if snapshot.stale {
            parts.append("已过期")
        }
        if let errorMessage = snapshot.errorMessage {
            parts.append(errorMessage)
        }
        return parts.joined(separator: " · ")
    }

    private var unreadSection: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            Text(BalanceSectionPresentation.unreadTitle)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            Text(BalanceSectionPresentation.unreadDetail)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var relayBalanceProviders: [AIOProvider] {
        store.aio.providers.filter { !$0.isOfficialOAuthProvider }
    }

    private var officialUsageRow: some View {
        let presentation = officialUsagePresentation
        return HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
            Circle()
                .fill(officialUsageStatusColor)
                .frame(
                    width: SentinelTheme.Metrics.balanceDot,
                    height: SentinelTheme.Metrics.balanceDot
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(store.officialUsage.accountLabel)
                    .font(SentinelTheme.Fonts.balanceName)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                    .lineLimit(1)

                if let metadata = officialUsageMetadata {
                    Text(metadata)
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(
                            store.officialUsage.stale
                                ? SentinelTheme.Colors.warning
                                : SentinelTheme.Colors.secondaryForeground
                        )
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: SentinelTheme.Spacing.xs)

            Text(presentation.text)
                .font(SentinelTheme.Fonts.balanceAmount)
                .foregroundStyle(presentation.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
                .accessibilityIdentifier("official-quota-value")

            Button {
                store.refreshOfficialUsageManually()
            } label: {
                Group {
                    if store.isOfficialUsageRefreshing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .disabled(
                store.isOfficialUsageRefreshing
                    || store.isOfficialUsageRefreshCoolingDown
            )
            .help(store.isOfficialUsageRefreshing ? "正在刷新官方额度" : "刷新官方额度")
            .accessibilityLabel("刷新官方额度")
            .accessibilityIdentifier("official-quota-refresh-button")
        }
        .frame(height: 38)
        .contentShape(Rectangle())
        .help(officialUsageTooltip)
    }

    private var officialUsageMetadata: String? {
        OfficialUsagePresentation.metadata(
            planDisplayName: store.officialUsage.planDisplayName,
            checkedAt: store.officialUsage.checkedAt,
            stale: store.officialUsage.stale
        )
    }

    private var officialUsagePresentation: (text: String, color: Color) {
        if let remaining = store.officialUsage.weeklyRemainingPercentage {
            let percentage = remaining.rounded() == remaining
                ? String(Int(remaining))
                : String(format: "%.1f", remaining)
            let color = store.officialUsage.stale
                || remaining <= 100 - AIOConstants.quotaWarningThreshold
                ? SentinelTheme.Colors.warning
                : SentinelTheme.Colors.foreground
            return ("剩 \(percentage)%", color)
        }
        // 查询期间不改文案：有旧数字就继续显示旧数字（上面那个分支已经返回了），
        // 没有数字就一直是「等待查询」，不许中途闪成「查询中」。
        if store.officialUsage.errorMessage != nil {
            return ("暂不可用", SentinelTheme.Colors.warning)
        }
        return ("等待查询", SentinelTheme.Colors.secondaryForeground)
    }

    private var officialUsageStatusColor: Color {
        guard let remaining = store.officialUsage.weeklyRemainingPercentage else {
            return store.officialUsage.errorMessage == nil
                ? SentinelTheme.Colors.secondaryForeground
                : SentinelTheme.Colors.warning
        }
        if store.officialUsage.stale
            || remaining <= 100 - AIOConstants.quotaWarningThreshold {
            return SentinelTheme.Colors.warning
        }
        return SentinelTheme.Colors.success
    }

    private var officialUsageTooltip: String {
        var parts = ["GPT 官方 · Codex 登录号"]
        if let email = store.officialUsage.email, !email.isEmpty {
            parts.append(email)
        }
        if let resetAt = store.officialUsage.weeklyResetDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M/d HH:mm"
            parts.append("周额度 \(formatter.string(from: resetAt)) 重置")
        }
        if let errorMessage = store.officialUsage.errorMessage {
            parts.append(errorMessage)
        }
        return parts.joined(separator: " · ")
    }

    private func balanceRow(_ provider: AIOProvider) -> some View {
        let balance = usagePresentation(provider.usage)

        return HStack(alignment: .center, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(provider.statusSeverity.color)
                .frame(
                    width: SentinelTheme.Metrics.balanceDot,
                    height: SentinelTheme.Metrics.balanceDot
                )

            Text(provider.name)
                .font(SentinelTheme.Fonts.balanceName)
                .foregroundStyle(
                    provider.enabled
                        ? SentinelTheme.Colors.foreground
                        : SentinelTheme.Colors.secondaryForeground
                )
                .lineLimit(1)
                .layoutPriority(1)

            if let secondary = balanceSecondaryText(provider) {
                Text(secondary)
                    .font(SentinelTheme.Fonts.balanceMeta)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: SentinelTheme.Spacing.md)

            // 刷新余额时这里原来会冒一个转圈动画。Falcon 2026-08-24：
            // 「点了往下一滑，所有查询一转，整个下滑菜单就直接卡死」——
            // 查询期间原样显示上一次的数字，不做任何加载态提示。

            Text(balance.text)
                .font(SentinelTheme.Fonts.balanceAmount)
                .foregroundStyle(balance.color)
                .lineLimit(1)
                .accessibilityIdentifier("aio-balance-\(provider.id)")
        }
        .frame(height: SentinelTheme.Metrics.balanceRowHeight)
        .contentShape(Rectangle())
        .help(balanceTooltip(provider))
    }

    private func balanceSecondaryText(_ provider: AIOProvider) -> String? {
        if !provider.enabled {
            return "已停用"
        }
        return BalanceRowPresentation.secondaryText(
            expiresAt: provider.usage.usage?.expiresAt,
            note: provider.note,
            planName: provider.usage.usage?.planName
        )
    }

    private func balanceTooltip(_ provider: AIOProvider) -> String {
        var parts = ["AIO 本地网关 · provider \(provider.id)"]
        if !provider.note.isEmpty {
            parts.append(provider.note)
        }
        if let planName = provider.usage.usage?.planName, !planName.isEmpty {
            parts.append(planName)
        }
        if let expiresAt = provider.usage.usage?.expiresAt, !expiresAt.isEmpty {
            parts.append("到期 \(String(expiresAt.prefix(10)))")
        }
        parts.append("熔断：\(provider.circuitState.displayName)")
        if !provider.enabled {
            parts.append("已停用")
        }
        return parts.joined(separator: " · ")
    }

    private func usagePresentation(_ status: AIOUsageStatus) -> (
        text: String,
        color: Color
    ) {
        switch status {
        case .idle:
            return ("等待查询", SentinelTheme.Colors.secondaryForeground)
        case .loading:
            // 已经不再写入这个状态（见 SentinelStore.refreshUsageConcurrently）。
            // 留个兜底，但绝不再显示「查询中」。
            return ("等待查询", SentinelTheme.Colors.secondaryForeground)
        case .failed:
            return ("余额接口暂不可达", SentinelTheme.Colors.danger)
        case .timedOut:
            return ("查询超时", SentinelTheme.Colors.warning)
        case .invalid:
            return ("数据无效", SentinelTheme.Colors.danger)
        case let .success(usage):
            if let used = usage.weeklyUsedPercentage {
                let remaining = OfficialQuotaPresentation.remainingPercentage(fromUsed: used)
                let percentage = remaining.rounded() == remaining
                    ? String(Int(remaining))
                    : String(format: "%.1f", remaining)
                let color = used >= AIOConstants.quotaWarningThreshold
                    ? SentinelTheme.Colors.warning
                    : SentinelTheme.Colors.foreground
                return ("剩 \(percentage)%", color)
            }
            guard let remaining = usage.remaining else {
                return ("网关未返回额度", SentinelTheme.Colors.secondaryForeground)
            }
            let text: String
            if remaining <= 0 {
                text = "余额不足"
            } else if usage.unit == nil || usage.unit == "USD" {
                text = "$\(String(format: "%.2f", remaining))"
            } else {
                text = "\(usage.unit!) \(String(format: "%.2f", remaining))"
            }

            let color: Color
            if remaining <= 0 {
                color = SentinelTheme.Colors.danger
            } else if remaining < AIOConstants.lowBalanceThreshold {
                color = SentinelTheme.Colors.warning
            } else {
                color = SentinelTheme.Colors.foreground
            }
            return (text, color)
        }
    }
}

/// 有登记的派工 + 最近完成。读：lineGroups、boardWindow、relayAttribution、
/// localHost、paths、watchDirectoryMissing。**不读 aio**（归因走 relayAttribution 切片）。
struct SentinelDispatchSection: View {
    var store: SentinelStore
    /// 仅截图 smoke 用：预展开第一条最近完成；菜单栏常驻默认 false。
    var autoExpandFirstCompleted = false
    let onShowSettings: (LineStatus) -> Void
    @State private var expandedCompletedLines: Set<String> = []
    @State private var expandedLineNotes: Set<String> = []
    @State private var forceStartAllFeedback: String?

    var body: some View {
        let groups = store.lineGroups
        let localHost = store.localHost
        let attribution = store.relayAttribution
        let logsDirectory = store.paths.logsDirectory
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            title(groups: groups, logsDirectory: logsDirectory)

            if store.watchDirectoryMissing {
                missingWatchDirectoryEmptyState
            } else if groups.activeRegistered.isEmpty {
                SentinelSectionChrome.emptyState("当前没有活跃派工")
            } else {
                ForEach(groups.activeRegistered) { presentation in
                    RegisteredLineRow(
                        presentation: presentation,
                        hostOrigin: presentation.hostOrigin(localHost: localHost),
                        attribution: attribution.resolve(line: presentation.line),
                        logsDirectory: logsDirectory,
                        isNoteExpanded: expandedLineNotes.contains(presentation.line.id),
                        onToggleNote: { toggleNote(presentation.line.id) },
                        onShowSettings: onShowSettings
                    )
                    .equatable()
                }
            }

            if !store.boardWindow.recentShown.isEmpty {
                Text("最近完成")
                    .font(SentinelTheme.Fonts.section)
                    .kerning(0.5)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .padding(.top, SentinelTheme.Spacing.xs)

                ForEach(store.boardWindow.recentShown) { presentation in
                    CompletedLineRow(
                        presentation: presentation,
                        hostOrigin: presentation.hostOrigin(localHost: localHost),
                        attribution: attribution.resolve(line: presentation.line),
                        isExpanded: expandedCompletedLines.contains(presentation.line.id),
                        onToggleExpanded: { toggleCompleted(presentation.line.id) }
                    )
                    .equatable()
                }
            }
        }
        .onAppear {
            seedAutoExpandIfNeeded()
        }
        .modifier(
            AutoExpandSeedModifier(
                enabled: autoExpandFirstCompleted,
                store: store,
                seed: { seedAutoExpandIfNeeded() }
            )
        )
    }

    private func toggleNote(_ id: String) {
        if expandedLineNotes.contains(id) {
            expandedLineNotes.remove(id)
        } else {
            expandedLineNotes.insert(id)
        }
    }

    private func toggleCompleted(_ id: String) {
        if expandedCompletedLines.contains(id) {
            expandedCompletedLines.remove(id)
        } else {
            expandedCompletedLines.insert(id)
        }
    }

    private func seedAutoExpandIfNeeded() {
        guard autoExpandFirstCompleted,
              expandedCompletedLines.isEmpty,
              let first = store.boardWindow.recentShown.first
        else {
            return
        }
        expandedCompletedLines.insert(first.id)
    }

    private func title(groups: SentinelLineGroups, logsDirectory: URL) -> some View {
        let candidates = SentinelForceStartAction.candidates(in: groups.activePresentations)
        return VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xxs) {
            HStack(spacing: SentinelTheme.Spacing.md) {
                Text(SentinelBoardCopy.registeredSectionTitle)
                    .font(SentinelTheme.Fonts.section)
                    .kerning(0.5)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                Spacer()
                Button {
                    let result = SentinelForceStartAction.requestAll(
                        in: groups.activePresentations,
                        logsDirectory: logsDirectory
                    )
                    forceStartAllFeedback = result.feedbackText
                } label: {
                    Label("一键恢复 \(candidates.count)", systemImage: "play.fill")
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, compact: true))
                .disabled(candidates.isEmpty)
                .help("强制开始所有非终态且没有在运行的 Codex 线")
                .accessibilityLabel("一键恢复 \(candidates.count) 条线")
                .accessibilityIdentifier("force-start-all")

                Text("\(groups.activeRegistered.count)")
                    .sentinelBadge(
                        foreground: SentinelTheme.Colors.secondaryForeground,
                        background: SentinelTheme.Colors.inset
                    )
            }

            if let forceStartAllFeedback {
                Text(forceStartAllFeedback)
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(
                        forceStartAllFeedback.contains("失败")
                            ? SentinelTheme.Colors.warning
                            : SentinelTheme.Colors.success
                    )
                    .accessibilityIdentifier("force-start-all-feedback")
            }
        }
    }

    private var missingWatchDirectoryEmptyState: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            Text(SentinelPaths.missingWatchDirectoryTitle)
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            Text(SentinelPaths.missingWatchDirectoryBody)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            Text(SentinelPaths.missingWatchDirectoryHint)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sentinelRow()
    }
}

/// smoke 截图预展开用的种子触发器。只有 enabled（即 --smoke-expand）时才读
/// store.lines / boardWindow 当 onChange 依赖；生产路径 enabled=false，
/// 这个修饰器不给分区增加任何额外的失效来源。
private struct AutoExpandSeedModifier: ViewModifier {
    let enabled: Bool
    var store: SentinelStore
    let seed: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onChange(of: store.lines) {
                    seed()
                }
                .onChange(of: store.boardWindow.recentShown.first?.id) {
                    seed()
                }
        } else {
            content
        }
    }
}

/// 没登记的（自动识别）。读：lineGroups、boardWindow（recentUnregistered）、
/// otherCodexProcesses、relayAttribution、paths。
struct SentinelAutomaticSection: View {
    var store: SentinelStore
    let onShowSettings: (LineStatus) -> Void
    @State private var isExpanded = false
    @State private var expandedLineNotes: Set<String> = []

    var body: some View {
        let activeUnregistered = store.lineGroups.activeUnregistered
        let recentUnregistered = store.boardWindow.recentUnregistered
        let processes = store.otherCodexProcesses
        let attribution = store.relayAttribution
        let logsDirectory = store.paths.logsDirectory
        let count = activeUnregistered.count + recentUnregistered.count + processes.count
        SentinelSectionChrome.collapsibleSection(
            title: SentinelBoardCopy.unregisteredSectionTitle,
            count: count,
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                ForEach(activeUnregistered) { presentation in
                    AutomaticLineRow(
                        line: presentation.line,
                        attribution: attribution.resolve(line: presentation.line),
                        logsDirectory: logsDirectory,
                        isNoteExpanded: expandedLineNotes.contains(presentation.line.id),
                        onToggleNote: { toggleNote(presentation.line.id) },
                        onShowSettings: onShowSettings
                    )
                    .equatable()
                }

                ForEach(recentUnregistered) { presentation in
                    AutomaticCompletedLineRow(line: presentation.line)
                        .equatable()
                }

                ForEach(processes) { process in
                    AutomaticProcessRow(process: process)
                        .equatable()
                }

                if count == 0 {
                    SentinelSectionChrome.emptyState("当前没有自动识别线")
                }
            }
        }
    }

    private func toggleNote(_ id: String) {
        if expandedLineNotes.contains(id) {
            expandedLineNotes.remove(id)
        } else {
            expandedLineNotes.insert(id)
        }
    }
}

/// 历史。读：boardWindow、localHost。
struct SentinelHistorySection: View {
    var store: SentinelStore
    @State private var isExpanded = false
    @State private var expandedLineNotes: Set<String> = []

    var body: some View {
        let entries = store.boardWindow.historyShown
        let localHost = store.localHost
        SentinelSectionChrome.collapsibleSection(
            title: "历史",
            count: entries.count,
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                ForEach(entries) { presentation in
                    HistoryLineRow(
                        presentation: presentation,
                        hostOrigin: presentation.hostOrigin(localHost: localHost),
                        isNoteExpanded: expandedLineNotes.contains(presentation.line.id),
                        onToggleNote: { toggleNote(presentation.line.id) }
                    )
                    .equatable()
                }
                if let footerText = store.boardWindow.footerText {
                    Text(footerText)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(footerText)
                }
                if entries.isEmpty {
                    SentinelSectionChrome.emptyState("没有历史记录")
                }
            }
        }
    }

    private func toggleNote(_ id: String) {
        if expandedLineNotes.contains(id) {
            expandedLineNotes.remove(id)
        } else {
            expandedLineNotes.insert(id)
        }
    }
}

/// 后台任务（PR 健康快照折叠块 + 私有腿 launchctl 操作行 + 关闭确认弹层）。
/// 读：backgroundJobs、backgroundJobRows、backgroundJobsExpanded、
/// backgroundJobMessages、backgroundJobOperations。
struct SentinelBackgroundJobsPanelSection: View {
    var store: SentinelStore
    @State private var showsHealthy = false
    @State private var pendingConfirmation: BackgroundJob?

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            // PR 腿的健康快照折叠展示保留；私有腿的 launchctl 控制行另列在下方。
            BackgroundJobsSectionView(
                presentation: BackgroundJobsPresentation(snapshot: store.backgroundJobs),
                showsHealthy: $showsHealthy,
                isExpanded: store.backgroundJobsExpanded,
                onToggleExpanded: {
                    store.setBackgroundJobsExpanded(!store.backgroundJobsExpanded)
                }
            )
            // 操作行跟着整块一起收：收起时只留摘要那一行。
            if store.backgroundJobsExpanded, !store.backgroundJobRows.isEmpty {
                SentinelSectionChrome.sectionTitle("后台任务操作", trailing: "\(store.backgroundJobRows.count)")
                ForEach(store.backgroundJobRows) { row in
                    operationRow(row)
                }
            }
        }
        .confirmationDialog(
            "确认关闭后台任务？",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let job = pendingConfirmation {
                Button("关闭 \(job.displayName)", role: .destructive) {
                    store.disableBackgroundJob(job.label)
                    pendingConfirmation = nil
                }
            }
            Button("取消", role: .cancel) { pendingConfirmation = nil }
        } message: {
            if let job = pendingConfirmation {
                Text("这会停止并持久关闭 \(job.label)。")
            }
        }
    }

    private func operationRow(_ row: BackgroundJobRow) -> some View {
        let job = row.job
        let busy = store.backgroundJobOperations.contains(job.label)
        let statusText = row.isDisabled ? "已关闭" : job.statusText
        return HStack(alignment: .top, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(row.isDisabled ? SentinelTheme.Colors.secondaryForeground : statusColor(job.status))
                .frame(width: SentinelTheme.Metrics.statusDot, height: SentinelTheme.Metrics.statusDot)
                .padding(.top, SentinelTheme.Spacing.xs)
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.xs) {
                    Text(job.displayName).font(SentinelTheme.Fonts.rowTitle).foregroundStyle(SentinelTheme.Colors.foreground)
                    Text(statusText).sentinelBadge(
                        foreground: row.isDisabled ? SentinelTheme.Colors.secondaryForeground : statusColor(job.status),
                        background: row.isDisabled ? SentinelTheme.Colors.inset : statusColor(job.status).opacity(0.14)
                    )
                }
                Text(job.label).font(SentinelTheme.Fonts.metadata).foregroundStyle(SentinelTheme.Colors.secondaryForeground).lineLimit(1)
                if !job.reason.isEmpty && !row.isDisabled { Text(job.reason).font(SentinelTheme.Fonts.subtitle).foregroundStyle(SentinelTheme.Colors.secondaryForeground).fixedSize(horizontal: false, vertical: true) }
                if let message = store.backgroundJobMessages[job.label] { Text(message).font(SentinelTheme.Fonts.subtitle).foregroundStyle(SentinelTheme.Colors.warning).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                ProgressView().controlSize(.small).frame(width: 62, height: SentinelTheme.Metrics.lineControlHeight)
            } else {
                Button {
                    if row.isDisabled { store.enableBackgroundJob(job.label) }
                    else if BackgroundJobsConstants.criticalLabels.contains(job.label) { pendingConfirmation = job }
                    else { store.disableBackgroundJob(job.label) }
                } label: {
                    Label(row.isDisabled ? "开启" : "关闭", systemImage: row.isDisabled ? "play.circle" : "stop.circle")
                }
                .buttonStyle(SentinelLineControlButtonStyle(width: 62))
                .accessibilityLabel("\(row.isDisabled ? "开启" : "关闭") \(job.displayName)")
            }
        }
        .sentinelRow(tone: row.isDisabled ? .normal : rowTone(job.status))
        .accessibilityIdentifier("background-job-operation-\(job.label)")
    }

    private func statusColor(_ status: BackgroundJobStatus) -> Color {
        switch status {
        case .ok: return SentinelTheme.Colors.success
        case .stalled, .hung, .neverRan: return SentinelTheme.Colors.warning
        case .error: return SentinelTheme.Colors.danger
        case .unknown: return SentinelTheme.Colors.secondaryForeground
        }
    }

    private func rowTone(_ status: BackgroundJobStatus) -> SentinelRowTone {
        switch status {
        case .ok: return .success
        case .stalled, .hung, .neverRan: return .warning
        case .error: return .danger
        case .unknown: return .normal
        }
    }
}

/// 底部：AIO 路由摘要 + 打开日志 / 刷新 / 设置 / 退出。读：aio。
struct SentinelFooterSection: View {
    var store: SentinelStore

    var body: some View {
        let topChannel = SentinelTopChannelPresentation(aio: store.aio)
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
            Rectangle()
                .fill(SentinelTheme.Colors.border)
                .frame(height: SentinelTheme.Spacing.hairline)

            HStack(spacing: SentinelTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                    Text("AIO 路由")
                        .font(SentinelTheme.Fonts.section)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    Text(topChannel.routeSummary)
                        .font(SentinelTheme.Fonts.subtitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let routeModeBadge = topChannel.routeModeBadge {
                    Text(routeModeBadge)
                        .sentinelBadge(
                            foreground: SentinelTheme.Colors.info,
                            background: SentinelTheme.Colors.infoSoft
                        )
                }
            }

            HStack(spacing: SentinelTheme.Spacing.md) {
                Spacer(minLength: 0)

                Button {
                    store.openLogsDirectory()
                } label: {
                    Label("打开日志", systemImage: "folder")
                }
                .buttonStyle(
                    SentinelButtonStyle(
                        kind: .secondary,
                        compact: true
                    )
                )

                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(
                    SentinelButtonStyle(
                        kind: .secondary,
                        compact: true,
                        iconOnly: true
                    )
                )
                .help("刷新")
                .accessibilityLabel("刷新")

                Button {
                    store.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(
                    SentinelButtonStyle(
                        kind: .secondary,
                        compact: true,
                        iconOnly: true
                    )
                )
                .help("设置")
                .accessibilityLabel("设置")
                .accessibilityIdentifier("app-settings-button")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(
                    SentinelButtonStyle(
                        kind: .ghost,
                        compact: true,
                        iconOnly: true
                    )
                )
                .help("退出")
                .accessibilityLabel("退出")
            }
        }
    }
}
