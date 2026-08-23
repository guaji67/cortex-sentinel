import AppKit
import SwiftUI

enum SentinelMenuInitialSection {
    case top
    case dispatch
}

struct SentinelMenuView: View {
    @ObservedObject var store: SentinelStore
    var initialSection: SentinelMenuInitialSection = .top
    /// 仅截图 smoke 用：预展开第一条最近完成，便于给第 4 点留证；菜单栏常驻默认 false。
    var autoExpandFirstCompleted = false
    /// 离屏出图用：ImageRenderer 吃不下 ScrollView/LazyVStack，换成同等间距的 VStack。
    /// 菜单栏常驻默认 false，现场布局一条都不改。
    var rendersOffscreen = false
    @State private var showsAutomaticLines = false
    @State private var showsBackgroundJobs = false
    @State private var showsHistory = false
    @State private var expandedCompletedLines: Set<String> = []
    @State private var expandedLineNotes: Set<String> = []
    @State private var settingsLine: LineStatus?
    @State private var pendingBackgroundJobConfirmation: BackgroundJob?

    var body: some View {
        ZStack {
            if rendersOffscreen {
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
                    sectionStack
                }
                .padding(SentinelTheme.Spacing.panel)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
                            sectionStack
                        }
                        .padding(SentinelTheme.Spacing.panel)
                    }
                    .onAppear {
                        scrollToInitialSection(using: proxy)
                        seedAutoExpandIfNeeded()
                    }
                    .onChange(of: store.aio.readAt) {
                        scrollToInitialSection(using: proxy)
                        seedAutoExpandIfNeeded()
                    }
                    .onChange(of: store.lines) {
                        seedAutoExpandIfNeeded()
                    }
                    .disabled(settingsLine != nil)
                }
            }

            if let settingsLine {
                settingsOverlay(for: settingsLine)
            }
        }
        .background(SentinelTheme.Colors.canvas)
        .frame(
            width: SentinelTheme.Metrics.menuWidth,
            height: rendersOffscreen ? nil : SentinelTheme.Metrics.menuHeight
        )
        .tint(SentinelTheme.Colors.primary)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "确认关闭后台任务？",
            isPresented: Binding(
                get: { pendingBackgroundJobConfirmation != nil },
                set: { if !$0 { pendingBackgroundJobConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let job = pendingBackgroundJobConfirmation {
                Button("关闭 \(job.displayName)", role: .destructive) {
                    store.disableBackgroundJob(job.label)
                    pendingBackgroundJobConfirmation = nil
                }
            }
            Button("取消", role: .cancel) { pendingBackgroundJobConfirmation = nil }
        } message: {
            if let job = pendingBackgroundJobConfirmation {
                Text("这会停止并持久关闭 \(job.label)。")
            }
        }
    }

    @ViewBuilder
    private var sectionStack: some View {
        header
        packagingSection
        channelSection
        backgroundJobsSection
        serviceSection
        balancesSection
        dispatchSection
            .id(SentinelMenuInitialSection.dispatch)
        automaticSection
        historySection
        footer
    }

    private func settingsOverlay(for line: LineStatus) -> some View {
        ZStack {
            SentinelTheme.Colors.canvas.opacity(0.82)
                .contentShape(Rectangle())
                .onTapGesture {
                    settingsLine = nil
                }

            SentinelLineSettingsPanel(
                line: line,
                logsDirectory: store.paths.logsDirectory,
                onClose: { settingsLine = nil }
            )
        }
        .accessibilityIdentifier("line-settings-overlay")
        .onExitCommand {
            settingsLine = nil
        }
    }

    private func scrollToInitialSection(using proxy: ScrollViewProxy) {
        guard initialSection == .dispatch else {
            return
        }
        proxy.scrollTo(SentinelMenuInitialSection.dispatch, anchor: .top)
    }

    private func seedAutoExpandIfNeeded() {
        guard autoExpandFirstCompleted,
              expandedCompletedLines.isEmpty,
              let first = boardWindow.recentShown.first
        else {
            return
        }
        expandedCompletedLines.insert(first.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            Text("Cortex 哨兵")
                .font(SentinelTheme.Fonts.title)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            Text(headerSubtitle)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerSubtitle: String {
        if store.watchDirectoryMissing {
            return SentinelPaths.missingWatchDirectoryTitle
        }
        return SentinelBoardCopy.headerSubtitle(
            localActiveCount: localActiveLineCount,
            recentCount: recentRegisteredCount,
            offHostActiveCount: offHostActiveLineCount
        )
    }

    /// Cortex 打包进度：只在 running 时出现，failed/completed 残留不占地方。
    @ViewBuilder
    private var packagingSection: some View {
        if let packaging = store.packagingProgress, packaging.isActive {
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

    private var channelSection: some View {
        let presentation = ChannelSectionPresentation(
            grok: store.channelStatus.grok,
            codex: store.channelStatus.codex,
            claudeOxAlpha: store.channelStatus.claudeOxAlpha,
            liveCounts: store.lineGroups.localActiveEngineCounts(localHost: localHost)
        )
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            sectionTitle("通道", trailing: channelUpdatedText)

            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                channelItem(presentation.codex)
                Spacer(minLength: SentinelTheme.Spacing.md)
                channelItem(presentation.grok)
                Spacer(minLength: SentinelTheme.Spacing.md)
                channelItem(presentation.claudeOxAlpha)
            }

            ForEach(Array(presentation.problemLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(SentinelTheme.Fonts.balanceMeta)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    private var backgroundJobsSection: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            // PR 腿的健康快照折叠展示保留；私有腿的 launchctl 控制行另列在下方。
            BackgroundJobsSectionView(
                snapshot: store.backgroundJobs,
                showsHealthy: $showsBackgroundJobs
            )
            if !store.backgroundJobRows.isEmpty {
                sectionTitle("后台任务操作", trailing: "\(store.backgroundJobRows.count)")
                ForEach(store.backgroundJobRows) { row in
                    backgroundJobOperationRow(row)
                }
            }
        }
    }

    private func backgroundJobOperationRow(_ row: BackgroundJobRow) -> some View {
        let job = row.job
        let busy = store.backgroundJobOperations.contains(job.label)
        let statusText = row.isDisabled ? "已关闭" : job.statusText
        return HStack(alignment: .top, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(row.isDisabled ? SentinelTheme.Colors.secondaryForeground : backgroundJobStatusColor(job.status))
                .frame(width: SentinelTheme.Metrics.statusDot, height: SentinelTheme.Metrics.statusDot)
                .padding(.top, SentinelTheme.Spacing.xs)
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.xs) {
                    Text(job.displayName).font(SentinelTheme.Fonts.rowTitle).foregroundStyle(SentinelTheme.Colors.foreground)
                    Text(statusText).sentinelBadge(
                        foreground: row.isDisabled ? SentinelTheme.Colors.secondaryForeground : backgroundJobStatusColor(job.status),
                        background: row.isDisabled ? SentinelTheme.Colors.inset : backgroundJobStatusColor(job.status).opacity(0.14)
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
                    else if BackgroundJobsConstants.criticalLabels.contains(job.label) { pendingBackgroundJobConfirmation = job }
                    else { store.disableBackgroundJob(job.label) }
                } label: {
                    Label(row.isDisabled ? "开启" : "关闭", systemImage: row.isDisabled ? "play.circle" : "stop.circle")
                }
                .buttonStyle(SentinelLineControlButtonStyle(width: 62))
                .accessibilityLabel("\(row.isDisabled ? "开启" : "关闭") \(job.displayName)")
            }
        }
        .sentinelRow(tone: row.isDisabled ? .normal : backgroundJobRowTone(job.status))
        .accessibilityIdentifier("background-job-operation-\(job.label)")
    }

    private func backgroundJobStatusColor(_ status: BackgroundJobStatus) -> Color {
        switch status {
        case .ok: return SentinelTheme.Colors.success
        case .stalled, .hung, .neverRan: return SentinelTheme.Colors.warning
        case .error: return SentinelTheme.Colors.danger
        case .unknown: return SentinelTheme.Colors.secondaryForeground
        }
    }

    private func backgroundJobRowTone(_ status: BackgroundJobStatus) -> SentinelRowTone {
        switch status {
        case .ok: return .success
        case .stalled, .hung, .neverRan: return .warning
        case .error: return .danger
        case .unknown: return .normal
        }
    }

    private var channelUpdatedText: String? {
        guard let generatedAt = store.channelStatus.generatedAt else {
            return nil
        }
        return SentinelTimeFormat.clockTime(generatedAt)
    }

    @ViewBuilder
    private var serviceSection: some View {
        let probes = store.inputStatus.displayProbes()
        switch InputServiceSectionPresentation.resolve(probes: probes) {
        case let .compact(statusText):
            compactDiagnosticRow(title: "Input 服务", status: statusText)
        case .expanded:
            expandedServiceSection(probes: probes)
        }
    }

    private func expandedServiceSection(probes: [InputStatusDisplayProbe]) -> some View {
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

    @ViewBuilder
    private var balancesSection: some View {
        switch BalanceSectionPresentation.resolve(
            official: store.officialUsage,
            aio: store.aio
        ) {
        case let .compact(statusText):
            compactDiagnosticRow(title: "余额", status: statusText)
        case .unread:
            unreadBalanceSection
        case .expanded:
            expandedBalancesSection
        }
    }

    private var expandedBalancesSection: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            sectionTitle("余额", trailing: balanceCountText)

            officialUsageRow

            switch store.aio.sourceState {
            case .unconfigured, .invalid:
                EmptyView()
            case .available:
                if relayBalanceProviders.isEmpty {
                    emptyState("没有可显示的中转余额")
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
        if store.isOfficialUsageRefreshing {
            return ("查询中", SentinelTheme.Colors.secondaryForeground)
        }
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
                .fill(providerStatusColor(provider))
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

            if case .loading = provider.usage {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("正在刷新余额")
            }

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

    private var dispatchSection: some View {
        let groups = store.lineGroups
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            sectionTitle(SentinelBoardCopy.registeredSectionTitle, trailing: "\(groups.activeRegistered.count)")

            if store.watchDirectoryMissing {
                missingWatchDirectoryEmptyState
            } else if groups.activeRegistered.isEmpty {
                emptyState("当前没有活跃派工")
            } else {
                ForEach(groups.activeRegistered) { presentation in
                    registeredLineRow(presentation)
                }
            }

            if !boardWindow.recentShown.isEmpty {
                Text("最近完成")
                    .font(SentinelTheme.Fonts.section)
                    .kerning(0.5)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .padding(.top, SentinelTheme.Spacing.xs)

                ForEach(boardWindow.recentShown) { presentation in
                    completedLineRow(presentation)
                }
            }
        }
    }

    private func registeredLineRow(_ presentation: LinePresentation) -> some View {
        let line = presentation.line
        let registration = presentation.registration
        return HStack(alignment: .top, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(lineActiveColor(line))
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
                    engineBadge(presentation.engine)
                    hostBadge(presentation.hostOrigin(localHost: localHost))
                }

                if let registration {
                    Text(registration.sourceConversationText)
                        .font(SentinelTheme.Fonts.subtitle)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                }

                Text(line.slug)
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)

                if let metadata = lineMetadata(line) {
                    Text(metadata)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(2)
                }

                if let rollout = rolloutPhrase(for: line) {
                    Text(rollout.text)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(rollout.color)
                }

                if line.balance != nil {
                    officialQuotaRows(line.balance)
                }

                if line.state == .waitingRelay, let relayProbe = line.relayProbe {
                    relayProbeDetails(relayProbe)
                }

                lineNoteSection(line)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xs) {
                lineStateBadge(line)
                if let startedAt = line.startedAt {
                    Text(SentinelTimeFormat.shortTime(startedAt))
                        .font(SentinelTheme.Fonts.rowTime)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .help("启动时刻")
                }
                SentinelLineControls(
                    line: line,
                    engine: presentation.engine,
                    logsDirectory: store.paths.logsDirectory,
                    onShowSettings: { settingsLine = $0 }
                )
            }
        }
        .sentinelRow(tone: lineRowTone(line))
    }

    private func completedLineRow(_ presentation: LinePresentation) -> some View {
        // v3.2 第 4 点：整行可点，展开显示来源对话 / 标识 / 启动→完成 / 重拉次数 / 通道归因。
        let line = presentation.line
        let isExpanded = expandedCompletedLines.contains(line.id)
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
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
                    engineBadge(presentation.engine)
                    hostBadge(presentation.hostOrigin(localHost: localHost))
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
            if let markerText = completedDispositionMarker(for: line) {
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
                completedLineDetail(presentation)
                    .padding(.leading, SentinelTheme.Metrics.statusDot + SentinelTheme.Spacing.md)
            }
        }
        .padding(.horizontal, SentinelTheme.Spacing.md)
        .padding(.vertical, SentinelTheme.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded {
                    expandedCompletedLines.remove(line.id)
                } else {
                    expandedCompletedLines.insert(line.id)
                }
            }
        }
        .accessibilityLabel(
            "\(presentation.registration?.labelZH ?? line.slug)，\(isExpanded ? "已展开" : "已折叠")"
        )
    }

    /// 只有真写了处置结论的终态线才给折叠态标记；没写的一个字都不加，
    /// 免得「已经有人处理过」的绿标记贴到其实还没人管的线上。
    private func completedDispositionMarker(for line: LineStatus) -> String? {
        LineDispositionPresentation(line: line).markerText
    }

    private func completedLineDetail(_ presentation: LinePresentation) -> some View {
        let line = presentation.line
        let attribution = RelayAttribution.resolve(line: line, aio: store.aio)
        let started = line.startedAt.map { SentinelTimeFormat.shortTime($0) } ?? "未知"
        let finished = line.sourceModifiedAt.map { SentinelTimeFormat.shortTime($0) } ?? "未知"
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            if let registration = presentation.registration {
                detailRow("来源", registration.sourceConversationText)
            }
            detailRow("标识", line.slug)
            detailRow("运行", "\(started) → \(finished)")
            if line.reportsRestarts {
                detailRow("重拉", line.restarts > 0 ? "\(line.restarts) 次" : "无")
            }
            if line.reportsCodexChannelTelemetry, attribution.isReported {
                detailRow("通道", attribution.text)
            }
            if let note = line.note {
                detailRow("备注", note)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
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

    private var automaticSection: some View {
        let count = store.lineGroups.activeUnregistered.count
            + recentUnregisteredLines.count
            + store.otherCodexProcesses.count
        return collapsibleSection(
            title: SentinelBoardCopy.unregisteredSectionTitle,
            count: count,
            isExpanded: $showsAutomaticLines
        ) {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                ForEach(store.lineGroups.activeUnregistered) { presentation in
                    automaticLineRow(presentation.line)
                }

                ForEach(recentUnregisteredLines) { presentation in
                    automaticCompletedLineRow(presentation.line)
                }

                ForEach(store.otherCodexProcesses) { process in
                    automaticProcessRow(process)
                }

                if count == 0 {
                    emptyState("当前没有自动识别线")
                }
            }
        }
    }

    private func collapsibleSection<Content: View>(
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

    private func automaticLineRow(_ line: LineStatus) -> some View {
        HStack(alignment: .top, spacing: SentinelTheme.Spacing.md) {
            Circle()
                .fill(lineActiveColor(line))
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
                    engineBadge(line.engine)
                }
                Text("未登记，信息可能不准")
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(SentinelTheme.Colors.warning)
                if let metadata = lineMetadata(line) {
                    Text(metadata)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(2)
                }

                if let rollout = rolloutPhrase(for: line) {
                    Text(rollout.text)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(rollout.color)
                }

                if line.balance != nil {
                    officialQuotaRows(line.balance)
                }

                if line.state == .waitingRelay, let relayProbe = line.relayProbe {
                    relayProbeDetails(relayProbe)
                }

                lineNoteSection(line)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xs) {
                lineStateBadge(line)
                SentinelLineControls(
                    line: line,
                    logsDirectory: store.paths.logsDirectory,
                    onShowSettings: { settingsLine = $0 }
                )
            }
        }
        .sentinelRow(tone: lineRowTone(line))
    }

    private func automaticCompletedLineRow(_ line: LineStatus) -> some View {
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
                    engineBadge(line.engine)
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

    private func automaticProcessRow(_ process: OtherCodexProcess) -> some View {
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

    private var historySection: some View {
        let entries = boardWindow.historyShown
        return collapsibleSection(
            title: "历史",
            count: entries.count,
            isExpanded: $showsHistory
        ) {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                ForEach(entries) { presentation in
                    historyLineRow(presentation)
                }
                if let footerText = boardWindow.footerText {
                    Text(footerText)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(footerText)
                }
                if entries.isEmpty {
                    emptyState("没有历史记录")
                }
            }
        }
    }

    private func historyLineRow(_ presentation: LinePresentation) -> some View {
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
                        engineBadge(presentation.engine)
                        hostBadge(presentation.hostOrigin(localHost: localHost))
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

            lineNoteSection(presentation.line)
        }
        .sentinelRow(tone: .normal)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
            sectionDivider

            HStack(spacing: SentinelTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                    Text("AIO 路由")
                        .font(SentinelTheme.Fonts.section)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    Text(routeSummary)
                        .font(SentinelTheme.Fonts.subtitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let routeModeBadge {
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

    private var sectionDivider: some View {
        Rectangle()
            .fill(SentinelTheme.Colors.border)
            .frame(height: SentinelTheme.Spacing.hairline)
    }

    private func sectionTitle(_ title: String, trailing: String?) -> some View {
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

    private func compactDiagnosticRow(title: String, status: String) -> some View {
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

    private var unreadBalanceSection: some View {
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

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(SentinelTheme.Fonts.subtitle)
            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sentinelRow()
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

    private var localHost: LocalHostIdentity {
        .current()
    }

    private var localActiveLineCount: Int {
        store.lineGroups.localActivePresentations(localHost: localHost).count
    }

    private var offHostActiveLineCount: Int {
        let origins = store.lineGroups.activeHostOriginCounts(localHost: localHost)
        return origins.remote + origins.unknown
    }

    private var boardWindow: SentinelBoardWindow {
        SentinelBoardWindow.snapshot(groups: store.lineGroups)
    }

    private var recentRegisteredCount: Int {
        boardWindow.recentShown.count
    }

    private var recentUnregisteredLines: [LinePresentation] {
        SentinelBoardWindow.newestFirst(
            store.lineGroups.recentlyCompleted.filter { $0.registration == nil }
        )
    }

    private var balanceCountText: String {
        SentinelTopChannelPresentation(aio: store.aio).balanceCountText
    }

    private var routeSummary: String {
        SentinelTopChannelPresentation(aio: store.aio).routeSummary
    }

    private var routeModeBadge: String? {
        SentinelTopChannelPresentation(aio: store.aio).routeModeBadge
    }

    private func usagePresentation(_ status: AIOUsageStatus) -> (
        text: String,
        color: Color
    ) {
        switch status {
        case .idle:
            return ("等待查询", SentinelTheme.Colors.secondaryForeground)
        case .loading:
            return ("查询中", SentinelTheme.Colors.secondaryForeground)
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

    private func providerStatusColor(_ provider: AIOProvider) -> Color {
        provider.statusSeverity.color
    }

    private func lineMetadata(_ line: LineStatus) -> String? {
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
        let attribution = RelayAttribution.resolve(line: line, aio: store.aio)
        if line.reportsCodexChannelTelemetry, attribution.isReported {
            parts.append(attribution.text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func relayProbeDetails(_ probe: LineRelayProbe) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            ForEach(
                Array(LineRelayProbePresentation.details(for: probe).enumerated()),
                id: \.offset
            ) { _, detail in
                detailRow(detail.label, detail.value)
            }
        }
        .padding(.top, SentinelTheme.Spacing.xxs)
    }

    private func officialQuotaRows(_ balance: RelayBalance?) -> some View {
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

    private func lineStateBadge(_ line: LineStatus) -> some View {
        let presentation = LineDispositionPresentation(line: line)
        return HStack(spacing: SentinelTheme.Spacing.xxs) {
            Image(systemName: presentation.symbolName)
                .imageScale(.small)
            Text(presentation.stateText)
        }
        .sentinelBadge(
            foreground: lineActiveColor(line),
            background: lineActiveSoftColor(line)
        )
    }

    private func engineBadge(_ engine: LineEngine) -> some View {
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

    private func hostBadge(_ origin: LineHostOrigin) -> some View {
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

    @ViewBuilder
    private func lineNoteSection(_ line: LineStatus) -> some View {
        let presentation = LineDispositionPresentation(line: line)
        if let markerText = presentation.markerText, let note = presentation.note {
            let isExpanded = expandedLineNotes.contains(line.id)
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                Button {
                    if isExpanded {
                        expandedLineNotes.remove(line.id)
                    } else {
                        expandedLineNotes.insert(line.id)
                    }
                } label: {
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

    /// v3.2 第 2 点：把看不懂的「轮转 N 秒」（rollout 心跳距今秒数）改人话分档。
    /// <60s 工作中(灰)；60–600s N 分钟没动静(橙)；>600s 卡住守护重拉中(橙)。
    /// 「重拉 N 次」在 lineMetadata 里保留（即他要的重试次数）。
    private func rolloutPhrase(for line: LineStatus) -> (text: String, color: Color)? {
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

    private func lineActiveColor(_ line: LineStatus) -> Color {
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

    private func lineActiveSoftColor(_ line: LineStatus) -> Color {
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

    private func lineRowTone(_ line: LineStatus) -> SentinelRowTone {
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
}

private extension CodexLineRegistration {
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
