import AppKit
import SwiftUI

/// 机器分级候选流（Falcon 09-18 令）：机器胶囊 tab 动态生成（含「全部」）；
/// 全部态每台只亮一个首选执行者；点某台展开该台全部执行者胶囊。
struct RouteMachinePickerView: View {
    let card: CortexRoutePreviewDisplay.RouteCard

    @State private var selection: String?

    private var groups: [CortexRoutePreviewDisplay.RouteCard.MachineGroup] {
        card.machineGroups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if groups.count <= 1 {
                chipsFlow(card.chips)
            } else {
                machineTabs
                if let selected = selection, let group = groups.first(where: { $0.machine == selected }) {
                    chipsFlow(group.chips)
                } else {
                    overviewRows
                }
            }
        }
    }

    /// 机器 tab：全部 + 各机器（动态）。
    private var machineTabs: some View {
        HStack(spacing: 4) {
            tabChip("全部", selected: selection == nil) {
                selection = nil
            }
            ForEach(groups, id: \.machine) { group in
                tabChip("\(group.machine) · \(group.chips.count)", selected: selection == group.machine) {
                    selection = selection == group.machine ? nil : group.machine
                }
            }
        }
    }

    /// 机器 tab 用小一号的 badge 字体：层级压过执行者胶囊（balanceName 13），
    /// 机器分组是筛选器不是同级候选（Falcon 09-18 令：主次要分明）。
    private func tabChip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(SentinelTheme.Fonts.badge)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(selected ? SentinelTheme.Colors.primary : SentinelTheme.Colors.secondaryForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? SentinelTheme.Colors.primary.opacity(0.2) : SentinelTheme.Colors.inset))
                .overlay(Capsule().stroke(selected ? SentinelTheme.Colors.primary.opacity(0.6) : SentinelTheme.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 全部态：每台机器一行，只亮首选（第一个非暂停的，否则第一个）。
    private var overviewRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groups, id: \.machine) { group in
                HStack(spacing: 5) {
                    Text(group.machine)
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .frame(width: 44, alignment: .leading)
                    let primary = group.chips.first(where: { !$0.paused }) ?? group.chips.first
                    if let chip = primary {
                        // 概览行机器名已在本行行首，chip 文本里重复的机器括号剥掉。
                        let suffix = " (\(group.machine))"
                        let shown = chip.paused
                            ? "\(chip.text)（暂停）"
                            : (chip.text.hasSuffix(suffix) ? String(chip.text.dropLast(suffix.count)) : chip.text)
                        Text(shown)
                            .font(SentinelTheme.Fonts.balanceName)
                            .lineLimit(1)
                            .foregroundStyle(chip.paused ? SentinelTheme.Colors.secondaryForeground : SentinelTheme.Colors.foreground)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(chip.paused ? SentinelTheme.Colors.inset : SentinelTheme.Colors.success.opacity(0.12)))
                            .overlay(Capsule().stroke(chip.paused ? SentinelTheme.Colors.borderSoft : SentinelTheme.Colors.success.opacity(0.3), lineWidth: 1))
                    }
                    if group.chips.count > 1 {
                        Text("+\(group.chips.count - 1)")
                            .font(SentinelTheme.Fonts.metadata)
                            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chipsFlow(_ chips: [CortexRoutePreviewDisplay.RouteChip]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Text(chip.paused ? "\(chip.text)（暂停）" : chip.text)
                    .font(SentinelTheme.Fonts.balanceName)
                    .lineLimit(1)
                    .foregroundStyle(chip.paused ? SentinelTheme.Colors.secondaryForeground : SentinelTheme.Colors.foreground)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(chip.paused ? SentinelTheme.Colors.inset : SentinelTheme.Colors.success.opacity(0.12)))
                    .overlay(Capsule().stroke(chip.paused ? SentinelTheme.Colors.borderSoft : SentinelTheme.Colors.success.opacity(0.3), lineWidth: 1))
            }
        }
    }
}

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

/// 时间横条：数字看额度，横条看时间——长度是当前窗口的剩余时间占比，
/// 剩得越少越黄。时间看个大概就够，精确重置时间在悬停详情里。
struct UsageTimeBar: View {
    let fraction: Double

    private var clamped: Double {
        min(1, max(0, fraction))
    }

    // 时间轴正向：起步绿，快到重置点黄，压线红。
    private var fillColor: Color {
        if clamped >= 0.85 {
            return SentinelTheme.Colors.danger
        }
        if clamped >= 0.6 {
            return SentinelTheme.Colors.warning
        }
        return SentinelTheme.Colors.success
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // 灰色底轨：满格在哪一目了然。fill 传已流逝占比。
                Capsule()
                    .fill(SentinelTheme.Colors.secondaryForeground.opacity(0.22))
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(2, proxy.size.width * clamped))
            }
        }
        .frame(height: SentinelTheme.Metrics.timeBarHeight)
        .accessibilityHidden(true)
    }
}

/// 离屏渲染验收用：置真时详情卡常显，不用真鼠标悬停就能出图检查布局。
private struct HoverCardPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

/// 离屏渲染选行用：给了值（行名子串）就只常显命中那一行的卡，其他行不出，
/// 一张图验一张卡。只在出图 CLI 里注入，生产不传。
private struct HoverCardPreviewRowKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var hoverCardPreview: Bool {
        get { self[HoverCardPreviewKey.self] }
        set { self[HoverCardPreviewKey.self] = newValue }
    }

    var hoverCardPreviewRow: String? {
        get { self[HoverCardPreviewRowKey.self] }
        set { self[HoverCardPreviewRowKey.self] = newValue }
    }
}

/// 可在余额区拖拽排序的账号行模型（GLM / Command Code）。
/// Cursor / AIO / 官方不实现，不参与排序与状态点判定。
protocol ProviderAccount {
    var key: String { get }
}

extension CommandCodeAccountUsage: ProviderAccount {}

extension GLMAccountUsage: ProviderAccount {}

/// 详情卡一行：左标签、中数值、右备注（重置/刷新时间）。
struct BalanceHoverLine {
    let label: String
    let value: String
    var note: String?
    var noteColor: Color?
}

/// 详情卡内容：标题区（名字 + 来源/身份）、明细行、页脚（更新时间/异常）。
struct BalanceHoverContent {
    let title: String
    var subtitle: String?
    var lines: [BalanceHoverLine]
    var footer: String?
    var alert: String?
    var alertColor: Color?
}

/// 悬停 0.5 秒弹出的详情卡。
/// 不用系统 tooltip：弹层里系统悬浮提示经常不出，且样式没法设计。
/// Falcon 2026-09-11 令：不许密密麻麻一团字，标签/数值/时间分列，重点靠颜色。
struct BalanceHoverDetail: View {
    let content: BalanceHoverContent

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(SentinelTheme.Fonts.rowTitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(1)
                }
            }
            if !content.lines.isEmpty {
                Rectangle()
                    .fill(SentinelTheme.Colors.borderSoft)
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(content.lines, id: \.label) { line in
                        HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.sm) {
                            Text(line.label)
                                .font(SentinelTheme.Fonts.balanceMeta)
                                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                                .frame(width: 76, alignment: .leading)
                            Text(line.value)
                                .font(SentinelTheme.Fonts.subtitle)
                                .foregroundStyle(SentinelTheme.Colors.foreground)
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(1)
                            Spacer(minLength: SentinelTheme.Spacing.sm)
                            if let note = line.note {
                                Text(note)
                                    .font(SentinelTheme.Fonts.metadata)
                                    .foregroundStyle(line.noteColor ?? SentinelTheme.Colors.secondaryForeground)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            if content.footer != nil || content.alert != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let footer = content.footer {
                        Text(footer)
                            .font(SentinelTheme.Fonts.metadata)
                            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    }
                    if let alert = content.alert {
                        Text(alert)
                            .font(SentinelTheme.Fonts.balanceMeta)
                            .foregroundStyle(content.alertColor ?? SentinelTheme.Colors.danger)
                    }
                }
            }
        }
        .padding(SentinelTheme.Spacing.md)
        .frame(width: 312, alignment: .leading)
        .background(SentinelTheme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel)
                .stroke(SentinelTheme.Colors.border, lineWidth: SentinelTheme.Metrics.borderWidth)
        )
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .accessibilityIdentifier("balance-hover-detail")
    }
}

/// 有详情卡在显示的余额区分支集合：行级 zIndex 只在分支内兄弟间排序，
/// 跨分支（GLM 卡盖 Cursor 行等）要靠这个把 zIndex 提到余额区顶层。
private struct BalanceCardBranchKey: PreferenceKey {
    static var defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

/// 悬停 0.5 秒后显示详情卡，移开即消失；显示期间该行置顶避免被相邻行盖住。
struct HoverDetailCard: ViewModifier {
    let makeContent: () -> BalanceHoverContent
    var isSuppressed: () -> Bool = { false }
    /// 本行所属余额区分支（"cc" / "glm"），卡显示时上报给顶层排 z 序。
    var branchID: String = ""
    /// 选行出图用：本行是否命中 --preview-hover-row。选行模式下没传的行不出卡。
    var previewRowMatch: Bool = false
    @Environment(\.hoverCardPreview) private var preview
    @Environment(\.hoverCardPreviewRow) private var previewRowSelection
    @State private var pending = false
    @State private var visible = false

    /// 鼠标压在状态点上或正在拖拽时，卡片一律不出现，别挡拖拽的道。
    /// 选行模式（--preview-hover-row）下只开命中那一行，其他分区行没传匹配也不开。
    private var showsCard: Bool {
        if previewRowSelection != nil {
            return previewRowMatch && !isSuppressed()
        }
        return (visible || preview) && !isSuppressed()
    }

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    pending = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if pending {
                            visible = true
                        }
                    }
                } else {
                    pending = false
                    visible = false
                }
            }
            .overlay(alignment: .trailing) {
                if showsCard {
                    BalanceHoverDetail(content: makeContent())
                        // 卡片挂右侧：左边整列状态点是拖拽热区，任何时候不许被卡片盖住。
                        .offset(x: -10, y: -30)
                        // 淡入淡出要短；不许拦截鼠标事件，否则卡片弹出来正好
                        // 压住鼠标位置，onHover 立刻 false，卡片忽隐忽现。
                        .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                        .allowsHitTesting(false)
                }
            }
            .zIndex(showsCard ? 99 : 0)
            .preference(key: BalanceCardBranchKey.self, value: showsCard ? [branchID] : [])
    }
}

/// 余额行名字：点一下就地变输入框，回车或点任意空白处提交、Esc 取消。
/// Falcon 2026-09-11 令：改名不要编辑按钮，直接点名字。空名字等于不改。
struct EditableBalanceRowName: View {
    let text: String
    var accessibilityIdentifier: String = "editable-balance-name"
    var onCommit: (String) -> Void
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(SentinelTheme.Fonts.balanceName)
                .foregroundStyle(SentinelTheme.Colors.foreground)
                .frame(maxWidth: 160)
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand {
                    isEditing = false
                }
                .onChange(of: isFocused) { focused in
                    // 点到编辑框以外（空白处/别的行）就算提交，光标不许一直闪。
                    if !focused, isEditing {
                        commit()
                    }
                }
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            Text(text)
                .font(SentinelTheme.Fonts.balanceName)
                .foregroundStyle(SentinelTheme.Colors.foreground)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture {
                    draft = text
                    isEditing = true
                    Task { @MainActor in
                        isFocused = true
                    }
                }
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private func commit() {
        isEditing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != text else {
            return
        }
        onCommit(trimmed)
    }
}

/// 标题 + 副标题 + 右上角更新入口。读：paths（监视目录缺失）、lineGroups /
/// boardWindow / localHost（计数）、availableUpdate / preparedUpdate /
/// isUpdateDownloading / isUpdateInstalling / updateInstallMessage（更新）。
/// Falcon 2026-09-11 令：更新按钮放右上角，放底部用户八辈子看不到。
struct SentinelHeaderSection: View {
    var store: SentinelStore

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Text("Cortex 哨兵")
                    .font(SentinelTheme.Fonts.title)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                Spacer(minLength: SentinelTheme.Spacing.sm)
                updateEntry
            }
            Text(subtitle)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            if let message = store.updateInstallMessage {
                Text(message)
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("update-message")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 右上角更新入口，按更新流程的状态换脸：
    /// 有新版本→立即更新；下载中→下载中；就绪→重启更新；安装中→转圈。
    @ViewBuilder private var updateEntry: some View {
        if store.isUpdateInstalling {
            HStack(spacing: SentinelTheme.Spacing.xs) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("更新中")
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityIdentifier("update-entry-installing")
        } else if let update = store.availableUpdate {
            if store.preparedUpdate?.version == update.version {
                Button("重启更新") {
                    store.performUpdateNow()
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, compact: true))
                .help("新版本 \(update.version) 已就绪，点击换装并重启哨兵")
                .accessibilityIdentifier("update-restart-button")
            } else if store.isUpdateDownloading {
                Text("更新下载中")
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("update-entry-downloading")
            } else {
                Button("立即更新") {
                    store.performUpdateNow()
                }
                .buttonStyle(SentinelButtonStyle(kind: .primary, compact: true))
                .help("下载并安装新版本 \(update.version)")
                .accessibilityIdentifier("update-install-button")
            }
        }
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

/// 面板打包分区的活跃快照判据：只有过了四道活线闸的 running 才算数。
/// 状态栏「打包」段和测试对照都用它；三态分区本体读 packagingReading。
@MainActor
enum SentinelPackagingPresentation {
    static func activeSnapshot(from store: SentinelStore) -> PackagingProgressSnapshot? {
        guard let packaging = store.packagingProgress, packaging.isActive else {
            return nil
        }
        return packaging
    }
}

/// 打包三态分区的视觉档位（COR-7600 返工）。running 与 error 必须一眼可分：
/// 曾同为橙框橙图标，「在打包」和「出错了」扫一眼混掉，病根从文案挪到了颜色。
enum SentinelPackagingSectionMood: Equatable {
    case running
    case idle
    case error

    var iconName: String {
        switch self {
        case .running: return "shippingbox.fill"
        case .idle: return "shippingbox"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tone: SentinelRowTone {
        switch self {
        case .running: return .warning
        case .idle: return .normal
        case .error: return .danger
        }
    }

    var accent: Color {
        switch self {
        case .running: return SentinelTheme.Colors.warning
        case .idle: return SentinelTheme.Colors.secondaryForeground
        case .error: return SentinelTheme.Colors.danger
        }
    }
}

/// 打包三态的上屏文案。一律人话：读屏的人没看过我们代码，
/// 不许出现 JSON / 数据根 / 稳定落点 / 登记文件这类内部词。
/// 读侧 reason（与主仓遥测逐字一致的那套）只进 --dump-state 等诊断口，不上屏。
enum SentinelPackagingCopy {
    static let sectionTitle = "Cortex 打包"
    static let runningBusy = "打包中"
    static let idleLine = "当前没有在跑的炉"
    static let errorLine = "读不到打包状态"
    static let errorHint = "下一炉起来会自己恢复"
}

/// Cortex 打包进度：三态分区（COR-7600）。running 显示哪一炉/第几步/几点
/// 起算/预计几点出包；idle 显示「当前没有在跑的炉」（可带上一炉时间）；
/// error 用红色警示档单独显示「读不到打包状态」，与 running 橙框一眼可分。
/// 读：packagingReading。
struct SentinelPackagingSection: View {
    var store: SentinelStore
    var bodyCounter: SentinelViewBodyCounter? = nil

    var body: some View {
        let _ = bodyCounter?.increment()
        switch store.packagingReading {
        case .running(let packaging):
            runningBlock(packaging)
        case .idle(_, let lastRun):
            idleBlock(lastRun: lastRun)
        case .error:
            errorBlock()
        case nil:
            EmptyView()
        }
    }

    private func runningBlock(_ packaging: PackagingProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.sm) {
                Image(systemName: SentinelPackagingSectionMood.running.iconName)
                    .foregroundStyle(SentinelPackagingSectionMood.running.accent)
                Text(SentinelPackagingCopy.sectionTitle)
                    .font(SentinelTheme.Fonts.section)
                    .foregroundStyle(SentinelPackagingSectionMood.running.accent)
                Spacer()
                Text(packaging.etaDisplayText)
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelPackagingSectionMood.running.accent)
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

            // 哪一炉（版本）· 第几步 · 几点起算。缺哪段就少哪段。
            let metaParts = [
                packaging.furnaceText,
                packaging.stepProgressText,
                packaging.startedAt.map { "\(SentinelTimeFormat.clockTime($0)) 起算" },
            ].compactMap { $0 }
            if !metaParts.isEmpty {
                Text(metaParts.joined(separator: " · "))
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }

            if let updatedAt = packaging.updatedAt {
                Text("更新于 \(SentinelTimeFormat.clockTime(updatedAt))")
                    .font(SentinelTheme.Fonts.rowTime)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }
        }
        .sentinelRow(tone: SentinelPackagingSectionMood.running.tone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(packaging.accessibilityText)
        .accessibilityIdentifier("packaging-progress")
    }

    private func idleBlock(lastRun: PackagingProgressSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.sm) {
                Image(systemName: SentinelPackagingSectionMood.idle.iconName)
                    .foregroundStyle(SentinelPackagingSectionMood.idle.accent)
                Text(SentinelPackagingCopy.sectionTitle)
                    .font(SentinelTheme.Fonts.section)
                    .foregroundStyle(SentinelPackagingSectionMood.idle.accent)
                Spacer()
            }
            Text(SentinelPackagingCopy.idleLine)
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            if let lastRunAt = lastRun?.updatedAt {
                Text("上一炉 \(SentinelTimeFormat.clockTime(lastRunAt))")
                    .font(SentinelTheme.Fonts.rowTime)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }
        }
        .sentinelRow(tone: SentinelPackagingSectionMood.idle.tone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(idleAccessibilityText(lastRun: lastRun))
        .accessibilityIdentifier("packaging-idle")
    }

    private func errorBlock() -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.sm) {
                Image(systemName: SentinelPackagingSectionMood.error.iconName)
                    .foregroundStyle(SentinelPackagingSectionMood.error.accent)
                Text(SentinelPackagingCopy.sectionTitle)
                    .font(SentinelTheme.Fonts.section)
                    .foregroundStyle(SentinelPackagingSectionMood.error.accent)
                Spacer()
            }
            Text(SentinelPackagingCopy.errorLine)
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelPackagingSectionMood.error.accent)
            Text(SentinelPackagingCopy.errorHint)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
        }
        .sentinelRow(tone: SentinelPackagingSectionMood.error.tone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SentinelPackagingCopy.sectionTitle)，\(SentinelPackagingCopy.errorLine)，\(SentinelPackagingCopy.errorHint)")
        .accessibilityIdentifier("packaging-error")
    }

    private func idleAccessibilityText(lastRun: PackagingProgressSnapshot?) -> String {
        var parts = [SentinelPackagingCopy.sectionTitle, SentinelPackagingCopy.idleLine]
        if let lastRunAt = lastRun?.updatedAt {
            parts.append("上一炉 \(SentinelTimeFormat.clockTime(lastRunAt))")
        }
        return parts.joined(separator: "，")
    }
}

/// 通道三卡（Codex / CodeBuddy / Grok）。读：channelStatus、lineGroups（本机引擎计数）、localHost。
/// 2026-09-14 Falcon 令：ox-alpha 卡下架，Codex 与 Grok 之间补 CodeBuddy 一档；
/// 磁盘摘要里的 claude-oxalpha 键继续解析，只是不再画卡。
struct SentinelChannelSection: View {
    var store: SentinelStore

    var body: some View {
        let presentation = ChannelSectionPresentation(
            grok: store.channelStatus.grok,
            codex: store.channelStatus.codex,
            codebuddy: store.channelStatus.codebuddy,
            liveCounts: store.lineGroups.localActiveEngineCounts(localHost: store.localHost)
        )
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            SentinelSectionChrome.sectionTitle("通道", trailing: updatedText)

            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                channelItem(presentation.codex)
                Spacer(minLength: SentinelTheme.Spacing.md)
                channelItem(presentation.codebuddy)
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

/// 余额（官方额度 + 中转各账号）。读：aio、officialUsage、glmUsage、commandCodeUsage、
/// commandCodeKeyCount、手动刷新标志。没配 Command Code key 时给引导行，点了回调上层弹填写面板。
struct SentinelBalancesSection: View {
    var store: SentinelStore
    /// 引导行点击回调；上层（SentinelMenuView）用它弹 key 填写浮层。
    var onAddCommandCodeKey: () -> Void = {}
    /// 拖拽中的行 key 与拖动起始下标；同一时刻只有一行在拖。
    @State private var draggingKey: String?
    @State private var dragBaseIndex: Int?
    /// 鼠标正压在哪个状态点上；压着的时候该行详情卡不出现。
    @State private var suppressCardKey: String?
    /// 拖拽预览：过程只动这两份本地状态（弹簧动画换位），松手一次性落库。
    @State private var dragPreviewOrder: [String]?
    @State private var dragTargetIndex: Int?
    @State private var dragLastCommittedDy: CGFloat = 0
    /// 点空白处时把焦点挪过来，正在编辑的行名随之失焦提交。
    @FocusState private var renameSinkFocused: Bool
    /// 出图选行参数（行名子串），只在渲染 CLI 里注入。
    @Environment(\.hoverCardPreviewRow) private var hoverCardPreviewRow

    var body: some View {
        switch BalanceSectionPresentation.resolve(
            official: store.officialUsage,
            aio: store.aio,
            glm: store.glmUsage,
            commandCodeShowsEntry: true
        ) {
        case let .compact(statusText):
            SentinelSectionChrome.compactDiagnosticRow(title: "余额", status: statusText)
        case .unread:
            unreadSection
        case .expanded:
            expandedSection
        }
    }

    /// 有卡在显示的分支；分支容器据此顶到余额区所有行之上（行级 zIndex 跨不过分支）。
    @State private var branchesWithHoverCard: Set<String> = []

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            SentinelSectionChrome.sectionTitle(
                "余额",
                trailing: SentinelTopChannelPresentation(aio: store.aio).balanceCountText
            )

            commandCodeEntryRows
                .zIndex(branchesWithHoverCard.contains("cc") ? 1 : 0)

            glmUsageRows
                .zIndex(branchesWithHoverCard.contains("glm") ? 1 : 0)

            codeBuddyUsageRow
                .zIndex(branchesWithHoverCard.contains("codebuddy") ? 1 : 0)

            cursorUsageRow

            officialUsageRow

            gateRuntimeStatusRow

            // 机器总览在派工预案上面（Falcon 09-18 令整体对调）。
            telemetrySummarySection

            routePreviewSection

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
        .onPreferenceChange(BalanceCardBranchKey.self) { branchesWithHoverCard = $0 }
        .background {
            // 焦点垃圾桶：点空白处把焦点从正在编辑的行名上挪走，触发失焦提交。
            TextField("", text: .constant(""))
                .frame(width: 1, height: 1)
                .opacity(0)
                .focused($renameSinkFocused)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            renameSinkFocused = true
        }
    }

    /// 行首状态点：颜色即额度状态（providerDotSignal）。按住上下拖给同组排序，
    /// 仅 GLM / Command Code 行有手势；拖动中点放大提示。Falcon 2026-09-11 令。
    /// 拖拽过程只更新本地预览顺序（弹簧动画换位 + 死区防手抖），松手才落库。
    private func providerDot(
        color: Color,
        namespace: String,
        key: String,
        index: Int,
        keys: [String]
    ) -> some View {
        let pitch = SentinelTheme.Metrics.usageRowHeight + SentinelTheme.Metrics.balanceRowSpacing
        return Circle()
            .fill(color)
            .frame(
                width: SentinelTheme.Metrics.balanceDot,
                height: SentinelTheme.Metrics.balanceDot
            )
            .scaleEffect(draggingKey == key ? 1.5 : 1)
            .animation(.easeOut(duration: 0.12), value: draggingKey)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { hovering in
                suppressCardKey = hovering ? key : (suppressCardKey == key ? nil : suppressCardKey)
            }
            .gesture(
                // 零阈值：按住那一刻就进拖拽模式（点放大、卡 suppressed），
                // 不等鼠标位移，跟手。Falcon 2026-09-11 令。
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if draggingKey == nil {
                            draggingKey = key
                            dragBaseIndex = index
                            dragTargetIndex = index
                            dragLastCommittedDy = 0
                        }
                        guard draggingKey == key, let base = dragBaseIndex else { return }
                        let candidate = base + Int((value.translation.height / pitch).rounded())
                        guard candidate != dragTargetIndex,
                              candidate >= 0, candidate < keys.count,
                              abs(value.translation.height - dragLastCommittedDy) >= pitch * 0.3
                        else { return }
                        let next = ProviderOrdering.moved(keys: keys, key: key, toIndex: candidate)
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            dragTargetIndex = candidate
                            dragPreviewOrder = next
                            dragLastCommittedDy = value.translation.height
                        }
                    }
                    .onEnded { _ in
                        defer {
                            draggingKey = nil
                            dragBaseIndex = nil
                            dragTargetIndex = nil
                            dragLastCommittedDy = 0
                        }
                        guard draggingKey == key, let preview = dragPreviewOrder else { return }
                        store.setProviderOrder(namespace: namespace, keys: preview)
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            dragPreviewOrder = nil
                        }
                    }
            )
    }

    /// 行序：拖拽中有预览用预览，没有用落库顺序。
    private func orderedRows<T: ProviderAccount>(_ accounts: [T], namespace: String) -> [T] {
        store.orderedProviders(accounts, namespace: namespace, previewOrder: dragPreviewOrder)
    }

    /// Command Code 额度：一把 key 一行（5h / 周 / 月），排在 GLM 前面。
    /// 一把 key 都没有时给「点击填写 API Key」引导行，点了就地弹填写面板。
    @ViewBuilder private var commandCodeEntryRows: some View {
        if store.commandCodeKeyCount == 0 && store.commandCodeUsage.accounts.isEmpty {
            commandCodeGuideRow
        } else {
            VStack(spacing: SentinelTheme.Metrics.balanceRowSpacing) {
                let ordered = orderedRows(
                    store.commandCodeUsage.accounts,
                    namespace: ProviderRenameNamespace.commandCode
                )
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, account in
                    commandCodeRow(account, index: index, keys: ordered.map(\.key))
                        .zIndex(draggingKey == account.key ? 10 : 0)
                }
                if store.commandCodeUsage.accounts.isEmpty {
                    commandCodeWaitingRow
                }
            }
        }
    }

    private var commandCodeGuideRow: some View {
        Button(action: onAddCommandCodeKey) {
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Circle()
                    .fill(SentinelTheme.Colors.secondaryForeground)
                    .frame(
                        width: SentinelTheme.Metrics.balanceDot,
                        height: SentinelTheme.Metrics.balanceDot
                    )
                Text("Command Code")
                    .font(SentinelTheme.Fonts.balanceName)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: SentinelTheme.Spacing.xs)
                HStack(alignment: .center, spacing: 4) {
                    Text("点击填写 API Key")
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(SentinelTheme.Colors.info)
                    Image(systemName: "square.and.pencil")
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(SentinelTheme.Colors.info)
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("填写 Command Code API Key，监控 5 小时 / 周 / 月额度")
        .accessibilityIdentifier("commandcode-add-key-guide")
    }

    private var commandCodeWaitingRow: some View {
        HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
            Circle()
                .fill(SentinelTheme.Colors.secondaryForeground)
                .frame(
                    width: SentinelTheme.Metrics.balanceDot,
                    height: SentinelTheme.Metrics.balanceDot
                )
            Text("Command Code")
                .font(SentinelTheme.Fonts.balanceName)
                .foregroundStyle(SentinelTheme.Colors.foreground)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: SentinelTheme.Spacing.xs)
            Text(BalanceSectionPresentation.queryingStatusText)
                .font(SentinelTheme.Fonts.balanceMeta)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .frame(height: 38)
        .contentShape(Rectangle())
    }

    private func commandCodeRow(
        _ account: CommandCodeAccountUsage,
        index: Int,
        keys: [String]
    ) -> some View {
        let displayName = store.providerDisplayName(
            namespace: ProviderRenameNamespace.commandCode,
            id: account.key,
            fallback: account.displayTitle
        )
        let fiveHourRemaining = account.fiveHourWindow?.remainingPercentage
        let weeklyRemaining = account.weeklyWindow?.remainingPercentage
        let monthly = account.monthlyRemainingCredits
        let now = Date()
        let fiveHourBar = Self.timeElapsedFraction(
            resetAt: account.fiveHourWindow?.resetAt,
            windowLength: 5 * 3600,
            now: now
        )
        let weeklyBar = Self.timeElapsedFraction(
            resetAt: account.weeklyWindow?.resetAt,
            windowLength: 7 * 24 * 3600,
            now: now
        )
        let monthlyBar = account.monthlyRemainingCredits != nil
            ? Self.periodElapsedFraction(end: account.periodEnd, start: account.periodStart, now: now)
            : nil
        return HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
            providerDot(
                color: commandCodeStatusColor(account),
                namespace: ProviderRenameNamespace.commandCode,
                key: account.key,
                index: index,
                keys: keys
            )
            EditableBalanceRowName(
                text: displayName,
                accessibilityIdentifier: "commandcode-name-\(account.maskedKeyText)"
            ) { newName in
                store.renameProvider(
                    namespace: ProviderRenameNamespace.commandCode,
                    id: account.key,
                    name: newName
                )
            }
            .layoutPriority(1)
            Spacer(minLength: SentinelTheme.Spacing.xs)
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                if let failureText = commandCodeFailureText(account) {
                    Text(failureText)
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    HStack(alignment: .top, spacing: SentinelTheme.Metrics.usageSegmentGap) {
                        if let fiveHourRemaining {
                            quotaSegmentWithBar(
                                label: "5h",
                                valueText: cursorUsageRemainingText(fiveHourRemaining),
                                valueColor: cursorUsageRemainingColor(fiveHourRemaining),
                                columnWidth: SentinelTheme.Metrics.usageColWidth1,
                                barFraction: fiveHourBar
                            )
                        }
                        if let weeklyRemaining {
                            quotaSegmentWithBar(
                                label: "周",
                                valueText: cursorUsageRemainingText(weeklyRemaining),
                                valueColor: cursorUsageRemainingColor(weeklyRemaining),
                                columnWidth: SentinelTheme.Metrics.usageColWidth2,
                                barFraction: weeklyBar
                            )
                        }
                        if let monthly {
                            quotaSegmentWithBar(
                                label: "月余",
                                valueText: String(format: "$%.2f", monthly),
                                valueColor: monthly <= 0
                                    ? SentinelTheme.Colors.danger
                                    : monthly < CommandCodeUsageConstants.lowMonthlyCredits
                                        ? SentinelTheme.Colors.warning
                                        : SentinelTheme.Colors.foreground,
                                columnWidth: SentinelTheme.Metrics.usageColWidth3,
                                barFraction: monthlyBar
                            )
                        }
                    }
                }
            }
            .frame(
                width: SentinelTheme.Metrics.usageBlockWidth,
                alignment: .leading
            )
        }
        .frame(height: SentinelTheme.Metrics.usageRowHeight)
        .contentShape(Rectangle())
        .modifier(HoverDetailCard(
            makeContent: { self.commandCodeDetailContent(account) },
            isSuppressed: { self.suppressCardKey == account.key || self.draggingKey != nil },
            branchID: "cc",
            previewRowMatch: self.rowMatchesPreviewSelection(displayName)
        ))
    }

    /// 无任何可显示数字时的右侧文案：优先报错；接口通了但什么都没有显示未知。
    private func commandCodeFailureText(_ account: CommandCodeAccountUsage) -> String? {
        if account.hasDisplayableNumber {
            return nil
        }
        if let errorMessage = account.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return "未知"
    }

    /// 带倒计时横额度的段：上面 label + 数值，下面自己的时间横条。
    /// 横条长度统一固定，段内左对齐——数字变化不会左右抖。
    private func quotaSegmentWithBar(
        label: String,
        valueText: String,
        valueColor: Color,
        columnWidth: CGFloat,
        barFraction: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(label)
                    .font(SentinelTheme.Fonts.balanceAmount)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                Text(valueText)
                    .font(SentinelTheme.Fonts.balanceAmount)
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            if let barFraction {
                UsageTimeBar(fraction: barFraction)
                    .frame(width: columnWidth - SentinelTheme.Metrics.usageBarInset)
            }
        }
        .frame(width: columnWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(valueText)")
    }

    private func commandCodeStatusColor(_ account: CommandCodeAccountUsage) -> Color {
        Self.providerDotSignal(
            fiveHourRemaining: account.fiveHourWindow?.remainingPercentage,
            weeklyRemaining: account.weeklyWindow?.remainingPercentage,
            balanceAmount: account.monthlyRemainingCredits,
            stale: account.stale,
            hasDisplayableNumber: account.hasDisplayableNumber
        )
    }

    /// 状态点判定（Falcon 2026-09-11 定，只管 GLM + Command Code，Cursor/AIO 不参与）：
    /// 先看 5 小时窗剩余：≤20% 黄、≤1% 红；
    /// 周窗兜底：剩余 ≤10% 无论 5h 多少都黄、≤1% 红；
    /// 余额类（现金/月余取最大算）<10 黄、<1 红；
    /// 各维度取最严重一档；stale 至少黄；没数据灰。
    static func providerDotSignal(
        fiveHourRemaining: Double?,
        weeklyRemaining: Double?,
        balanceAmount: Double?,
        stale: Bool,
        hasDisplayableNumber: Bool
    ) -> Color {
        guard hasDisplayableNumber else {
            return SentinelTheme.Colors.secondaryForeground
        }
        var severity = 0
        if let remaining = fiveHourRemaining {
            if remaining <= 1 {
                severity = max(severity, 2)
            } else if remaining <= 20 {
                severity = max(severity, 1)
            }
        }
        if let remaining = weeklyRemaining {
            if remaining <= 1 {
                severity = max(severity, 2)
            } else if remaining <= 10 {
                severity = max(severity, 1)
            }
        }
        if let amount = balanceAmount {
            if amount < 1 {
                severity = max(severity, 2)
            } else if amount < 10 {
                severity = max(severity, 1)
            }
        }
        if severity >= 2 {
            return SentinelTheme.Colors.danger
        }
        if severity >= 1 || stale {
            return SentinelTheme.Colors.warning
        }
        return SentinelTheme.Colors.success
    }

    private func commandCodeDetailContent(_ account: CommandCodeAccountUsage) -> BalanceHoverContent {
        let now = Date()
        var lines: [BalanceHoverLine] = []
        for (name, window, windowLength) in [
            ("5 小时窗", account.fiveHourWindow, 5 * 3600.0),
            ("周窗", account.weeklyWindow, 7 * 24 * 3600.0),
        ] {
            guard let window else { continue }
            var value = ""
            if let used = window.used, let cap = window.cap, cap > 0 {
                value = "已用 \(Self.windowAmountText(used)) / \(Self.windowAmountText(cap))"
            } else if let remaining = window.remainingPercentage {
                value = "剩余 \(Int(remaining.rounded()))%"
            }
            lines.append(BalanceHoverLine(
                label: name,
                value: value,
                note: window.resetAt.map { "\(Self.shortTime($0)) 重置" },
                noteColor: Self.resetNoteColor(
                    Self.timeElapsedFraction(resetAt: window.resetAt, windowLength: windowLength, now: now)
                )
            ))
        }
        if let monthly = account.monthlyRemainingCredits {
            lines.append(BalanceHoverLine(
                label: "月余",
                value: String(format: "$%.2f", monthly),
                note: account.periodEnd.map { "\(Self.shortTime($0)) 刷新" },
                noteColor: nil
            ))
        }
        var subtitle = "Command Code 订阅"
        if let identity = account.accountIdentity, !identity.isEmpty {
            subtitle += " · \(identity)"
        }
        var alert: String?
        var alertColor: Color?
        if let errorMessage = account.errorMessage {
            alert = errorMessage
            alertColor = SentinelTheme.Colors.danger
        } else if account.stale {
            alert = "数据已过期"
            alertColor = SentinelTheme.Colors.warning
        }
        return BalanceHoverContent(
            title: store.providerDisplayName(
                namespace: ProviderRenameNamespace.commandCode,
                id: account.key,
                fallback: account.displayTitle
            ),
            subtitle: subtitle,
            lines: lines,
            footer: account.checkedAt.map { "\(SentinelTimeFormat.clockTime($0)) 更新" },
            alert: alert,
            alertColor: alertColor
        )
    }

    /// 重置时间备注：越接近重置越醒目（快到变黄、压线变红），平时灰。
    static func resetNoteColor(_ elapsed: Double?) -> Color? {
        guard let elapsed else { return nil }
        if elapsed >= 0.85 {
            return SentinelTheme.Colors.danger
        }
        if elapsed >= 0.6 {
            return SentinelTheme.Colors.warning
        }
        return nil
    }

    /// 窗口用量的整数就去掉小数点，小数留一位：1.334076828 → 1.3，14.0 → 14。
    private static func windowAmountText(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    /// 派工路由状态行：哨兵每轮确保路由最新，这里亮结果（套餐详情卡同区域）。
    /// 整句由显示层纯函数给（含「派工路由：」前缀），state 为 ok 用普通色，
    /// 其余态用面板现有提醒色。还没跑过任何一轮不占位。
    @ViewBuilder private var gateRuntimeStatusRow: some View {
        if let row = CortexGateRuntimeStatusDisplay.rowLine(store.gateRuntimeStatus, now: Date()) {
            Text(row.text)
                .font(SentinelTheme.Fonts.balanceMeta)
                .foregroundStyle(row.isWarning
                    ? SentinelTheme.Colors.warning
                    : SentinelTheme.Colors.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(row.text)
        }
    }

    /// 派工路由预案：图形卡片版（Falcon 09-18 令可视化）。
    /// 两张小卡（前端 / 高难）+ 一张候选胶囊卡（一般票），窗态做成胶囊徽标。
    @ViewBuilder private var routePreviewSection: some View {
        let payload = store.routePreview?.payload
        let cards = CortexRoutePreviewDisplay.cards(payload)
        if cards.isEmpty {
            if let failure = store.routePreview?.failureText, !failure.isEmpty {
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                    Text("派工预案：这次没读到（\(failure)）")
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    if failure.contains("找不到 cortex 仓") {
                        repoMissingHintRow
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                    Text("派工预案")
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                    Spacer(minLength: 0)
                    windowBadge(active: payload?.freeWindow?.active ?? false,
                                clock: "")
                }
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    routeCardView(card)
                }
            }
        }
    }

    /// 窗态胶囊徽标：免费窗中（绿） / 窗外（灰）。
    private func windowBadge(active: Bool, clock: String) -> some View {
        Text(active ? "ZCode 免费窗" : "窗外")
            .font(SentinelTheme.Fonts.balanceName)
            .foregroundStyle(active ? SentinelTheme.Colors.success : SentinelTheme.Colors.secondaryForeground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    (active ? SentinelTheme.Colors.success : SentinelTheme.Colors.secondaryForeground).opacity(0.16)
                )
            )
    }

    /// 预案小卡：单出口画绿点 + 目标；候选卡画胶囊 chips（paused 灰）。
    private func routeCardView(_ card: CortexRoutePreviewDisplay.RouteCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title)
                .font(SentinelTheme.Fonts.balanceName)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            if card.chips.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(SentinelTheme.Colors.success)
                        .frame(width: 7, height: 7)
                    Text(card.target)
                        .font(SentinelTheme.Fonts.balanceName)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .lineLimit(1)
                }
            } else if !card.chips.isEmpty {
                machineGroupFlow(card)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SentinelTheme.Colors.raised)
        .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.field))
        .overlay(
            RoundedRectangle(cornerRadius: SentinelTheme.Radius.field)
                .stroke(SentinelTheme.Colors.borderSoft, lineWidth: 1)
        )
    }

    /// 机器分级候选：机器胶囊 tab（动态，含「全部」），选中哪台就展开哪台的执行者；
    /// 「全部」态每台只亮一个首选（第一个可用的）执行者，不铺满。
    private func machineGroupFlow(_ card: CortexRoutePreviewDisplay.RouteCard) -> some View {
        RouteMachinePickerView(card: card)
    }

    /// 三机总览：图形卡（CPU / 内存 / swap 迷你条，槽位点阵，压力色点）。
    @ViewBuilder private var telemetrySummarySection: some View {
        let payload = store.telemetrySummary?.payload
        let machines = CortexTelemetrySummaryDisplay.mergedMachines(
            kvPayload: payload,
            lanMachines: store.lanMachines
        )
        if !machines.isEmpty {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                    Text("机器总览")
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                    Spacer(minLength: 0)
                    // 徽标数「正在执行的任务」不数人：一个执行者可同时背多条
                    // （Falcon 09-18 令）。旧脚本没 tasks_total 就不显示，别拿
                    // working 个数冒充任务数。
                    if let tasks = payload?.multica?.tasksTotal {
                        Text("Multica 在跑 \(tasks)")
                            .font(SentinelTheme.Fonts.balanceName)
                            .foregroundStyle(SentinelTheme.Colors.info)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(SentinelTheme.Colors.info.opacity(0.16)))
                            .contentShape(Rectangle())
                            .modifier(HoverDetailCard(
                                makeContent: { self.multicaHoverContent(payload) },
                                branchID: "multica"
                            ))
                    }
                }
                ForEach(Array(machines.enumerated()), id: \.offset) { _, machine in
                    machineCard(machine, tasksByMachine: payload?.multica?.tasksByMachine ?? [:],
                                tasksByAgent: payload?.multica?.tasksByAgent ?? [])
                }
            }
        } else if let state = store.telemetrySummary {
            let rows = CortexTelemetrySummaryDisplay.rows(state, now: Date())
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                }
                if let failure = state.failureText, failure.contains("找不到 cortex 仓") {
                    repoMissingHintRow
                }
            }
        }
    }

    /// Multica 徽标悬停：在飞任务拆到每个执行者——「名字 + 在飞任务数」
    /// （Falcon 09-18 令：要能看出这几条都压在谁身上）。
    /// 弹层里系统 tooltip 不可靠，走自绘 HoverDetailCard（仓规同余额区）。
    private func multicaHoverContent(_ payload: CortexTelemetrySummaryPayload?) -> BalanceHoverContent {
        let tasks = payload?.multica?.tasksTotal ?? 0
        let rows = payload?.multica?.tasksByAgent ?? []
        guard !rows.isEmpty else {
            return BalanceHoverContent(
                title: "Multica 在跑 \(tasks)",
                subtitle: "Multica 工作区",
                lines: [],
                footer: "Multica 没返回执行者拆账"
            )
        }
        return BalanceHoverContent(
            title: "Multica 在跑 \(tasks)",
            subtitle: "Multica 工作区 · 每行一名执行者名下的在飞任务",
            lines: rows.map { row in
                BalanceHoverLine(label: row.name.isEmpty ? "（未署名执行者）" : row.name,
                                 value: "\(row.tasks) 条",
                                 note: nil, noteColor: nil)
            }
        )
    }

    /// 认不到 cortex 仓时的安静指引（新装机器常见）：一句话 + 去设置，不弹窗不闪红。
    private var repoMissingHintRow: some View {
        HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
            Text("本机没认到 Cortex 仓库——去设置里把「盯这个文件夹」指到仓库的 logs 目录。")
                .font(SentinelTheme.Fonts.balanceMeta)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            Button("去设置") {
                store.openSettings()
            }
            .buttonStyle(SentinelButtonStyle(kind: .secondary, compact: true))
            .accessibilityIdentifier("repo-missing-open-settings")
        }
    }

    /// 单台机器图形卡。行1 认机器（名/CPU/内存/swap），行2 派工（槽位 + 在跑 +
    /// 压力灯收行尾）——压力灯放行2 是 Falcon 09-18 令的「右下角」，行1 满宽时
    /// 点会被裁半边（生产实锤），行2 尾永远有地方站。
    private func machineCard(
        _ machine: CortexTelemetrySummaryPayload.Machine,
        tasksByMachine: [String: Int],
        tasksByAgent: [CortexTelemetrySummaryPayload.Multica.AgentTasks]
    ) -> some View {
        let machineToken = machineName(machine).lowercased()
        let multicaTasks = tasksByMachine[machineToken] ?? 0
        let machineAgents = tasksByAgent.filter { ($0.machine ?? "") == machineToken }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(machineName(machine))
                    .font(SentinelTheme.Fonts.balanceName)
                // 名字是行里唯一没定宽的文本：不给 fixedSize，空间一紧就被
                // 压成一字一行竖排（0.1.46 生产实锤）。
                .fixedSize()
                .foregroundStyle(SentinelTheme.Colors.foreground)
                miniGauge(value: machine.cpuPct, label: "CPU")
                miniGauge(value: machine.memUsedPct ?? machine.memFreePct.map { 100 - $0 },
                          label: machine.memUsedPct != nil ? "内存" : "内存余")
                if let swap = machine.swap {
                    Text(swapText(swap))
                        .font(SentinelTheme.Fonts.balanceName)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                slotDots(machine.devSlots)
                runningBadge(machine.linesByModel, multicaTasks: multicaTasks)
                Spacer(minLength: 0)
                pressureDot(machine.pressureLevel)
            }
            // 悬停目标锚整行（余额区同模式）：锚在「在跑」小徽标上时，312pt 宽的
            // 拆账卡向左展出去会越过面板左缘整列被裁（0148 出图实锤）。
            .contentShape(Rectangle())
            .modifier(HoverDetailCard(
                makeContent: { self.runningHoverContent(machine.linesByModel, multicaTasks: multicaTasks, machineAgents: machineAgents) },
                branchID: "running"
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(SentinelTheme.Colors.raised)
        .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.field))
        .overlay(
            RoundedRectangle(cornerRadius: SentinelTheme.Radius.field)
                .stroke(SentinelTheme.Colors.border, lineWidth: 1)
        )
    }

    private func machineName(_ machine: CortexTelemetrySummaryPayload.Machine) -> String {
        guard let raw = machine.machine?.lowercased() else { return "?" }
        if raw.contains("mini") { return "mini2" }
        if raw.contains("m1max") || raw.contains("book-pro") { return "M1Max" }
        return "Pro"
    }

    /// 迷你胶囊进度条 + 标签。值缺画灰空条。
    private func miniGauge(value: Double?, label: String) -> some View {
        let fraction = value.map { min(max($0 / 100, 0), 1) } ?? 0
        let color = value.map { $0 < 60 ? SentinelTheme.Colors.success : ($0 < 85 ? SentinelTheme.Colors.warning : SentinelTheme.Colors.danger) }
            ?? SentinelTheme.Colors.inset
        return HStack(spacing: 4) {
            Text(label)
                .font(SentinelTheme.Fonts.balanceName)
                .fixedSize()
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SentinelTheme.Colors.inset)
                    Capsule().fill(color).frame(width: geo.size.width * fraction)
                }
            }
            .frame(width: 46, height: 6)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(SentinelTheme.Fonts.balanceName)
                .fixedSize()
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
        }
    }

    /// swap 短文本「1000M/2G」：慢变量不画条（Falcon 09-18 令视觉精简）。
    private func swapText(_ swap: CortexTelemetrySummaryPayload.Swap) -> String {
        func compact(_ raw: String?) -> String? {
            guard var text = raw else { return nil }
            if text.hasSuffix("M") {
                guard let mega = Double(text.dropLast()) else { return text }
                text = mega >= 1024 ? String(format: "%.0fG", mega / 1024) : String(format: "%.0fM", mega)
            } else if text.hasSuffix("G") {
                text = String(format: "%.0fG", Double(text.dropLast()) ?? 0)
            }
            return text
        }
        guard let used = compact(swap.used) else { return "swap –" }
        let total = compact(swap.total).map { "/\($0)" } ?? ""
        return "swap \(used)\(total)"
    }


    private func parseGigabytes(_ text: String?) -> Double? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("G") {
            return Double(trimmed.dropLast())
        }
        if trimmed.hasSuffix("M") {
            return Double(trimmed.dropLast()).map { $0 / 1024 }
        }
        return nil
    }

    /// 槽位点阵：实心 = 占用，空心 = 空闲。
    private func slotDots(_ slots: CortexTelemetrySummaryPayload.DevSlots?) -> some View {
        HStack(spacing: 3) {
            Text("槽")
                .font(SentinelTheme.Fonts.balanceName)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            if let cap = slots?.cap {
                let used = slots?.used ?? 0
                ForEach(0..<max(cap, 1), id: \.self) { index in
                    Circle()
                        .fill(index < used ? SentinelTheme.Colors.primary : SentinelTheme.Colors.inset)
                        .overlay(Circle().stroke(SentinelTheme.Colors.borderSoft, lineWidth: 1))
                        .frame(width: 7, height: 7)
                }
                Text("\(slots?.used ?? 0)/\(cap)")
                    .font(SentinelTheme.Fonts.balanceName)
                    .fixedSize()
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }
        }
    }

    /// 「在跑 N」数 Multica 派到本机的**在飞任务数**——三张卡加起来必须等于
    /// 顶部「Multica 在跑」徽标（Falcon 09-18 令：数任务不数人，要能对上账）。
    /// 本机 CLI 直派线是另一套口径（界面上的「N 次运行」是累计历史，跟在跑
    /// 无关），有活另给灰字「+N 本地」，不掺进这个数。
    private func runningBadge(_ localLines: [String: Int]?, multicaTasks: Int) -> some View {
        let localTotal = (localLines ?? [:]).values.reduce(0, +)
        return HStack(spacing: 5) {
            Text("在跑 \(multicaTasks)")
                .font(SentinelTheme.Fonts.balanceName)
                .fixedSize()
                .foregroundStyle(multicaTasks == 0 ? SentinelTheme.Colors.secondaryForeground : SentinelTheme.Colors.primary)
            if localTotal > 0 {
                Text("+\(localTotal) 本地")
                    .font(SentinelTheme.Fonts.balanceMeta)
                    .fixedSize()
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }
        }
    }

    private func runningHoverContent(
        _ localLines: [String: Int]?,
        multicaTasks: Int,
        machineAgents: [CortexTelemetrySummaryPayload.Multica.AgentTasks]
    ) -> BalanceHoverContent {
        let localTotal = (localLines ?? [:]).values.reduce(0, +)
        var lines: [BalanceHoverLine] = []
        if let localLines, !localLines.isEmpty {
            let breakdown = localLines
                .sorted { $0.value > $1.value }
                .map { key, count in count > 1 ? "\(CortexTelemetrySummaryDisplay.shortModel(key))×\(count)" : CortexTelemetrySummaryDisplay.shortModel(key) }
                .joined(separator: "、")
            lines.append(BalanceHoverLine(
                label: "本地 CLI 线",
                value: "\(localTotal)",
                note: breakdown,
                noteColor: nil
            ))
        } else {
            lines.append(BalanceHoverLine(label: "本地 CLI 线", value: "0", note: nil, noteColor: nil))
        }
        lines.append(BalanceHoverLine(
            label: "Multica 派本机",
            value: "\(multicaTasks)",
            note: nil,
            noteColor: nil
        ))
        for agent in machineAgents {
            lines.append(BalanceHoverLine(
                label: agent.name.isEmpty ? "（未署名执行者）" : agent.name,
                value: "\(agent.tasks) 条",
                note: nil,
                noteColor: nil
            ))
        }
        return BalanceHoverContent(
            title: "Multica 派本机 \(multicaTasks)",
            subtitle: "本地 CLI 线另计；每行是一名执行者名下的在飞任务",
            lines: lines
        )
    }

    /// 压力灯：正常只留一个绿点（Falcon 09-18 令），异常才出字；缺数据灰点。
    private func pressureDot(_ level: Int?) -> some View {
        let color = level.map { $0 == 1 ? SentinelTheme.Colors.success : ($0 == 2 ? SentinelTheme.Colors.warning : SentinelTheme.Colors.danger) }
            ?? SentinelTheme.Colors.inset
        return HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            if level == 2 || level == 4 {
                Text(level == 4 ? "压力危急" : "压力警告")
                    .font(SentinelTheme.Fonts.balanceName)
                    .fixedSize()
                    .foregroundStyle(level == 4 ? SentinelTheme.Colors.danger : SentinelTheme.Colors.warning)
            }
        }
    }

    /// 智谱 GLM Coding Plan 额度：每把 key 一行（5 小时窗 + 周窗两组剩余百分比），
    /// 排在 Cursor 前面。没识别到 key 就不占位。
    /// 同账号附加钥匙并进套餐行：先过可见行再排序，拖拽 keys 跟着对齐。
    @ViewBuilder private var glmUsageRows: some View {
        if store.glmUsage.accounts.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: SentinelTheme.Metrics.balanceRowSpacing) {
                let visible = CortexPlanStatusDisplay.visibleAccounts(
                    store.glmUsage.accounts,
                    payload: store.glmPlanStatus?.payload
                )
                let ordered = orderedRows(
                    visible,
                    namespace: ProviderRenameNamespace.glm
                )
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, account in
                    glmUsageRow(account, index: index, keys: ordered.map(\.key))
                        .zIndex(draggingKey == account.key ? 10 : 0)
                }
            }
        }
    }

    private func glmUsageRow(
        _ account: GLMAccountUsage,
        index: Int,
        keys: [String]
    ) -> some View {
        // 认成派工套餐的行：名字用套餐 label（用户改名仍优先）、第三列换在跑/冷却。
        // 数据过时（超过复用窗没读到新的）时身份照用，数值不显。
        let planState = store.glmPlanStatus
        let plan = CortexPlanStatusDisplay.plan(forAccountKey: account.key, in: planState?.payload)
        let planFreshness = CortexPlanStatusDisplay.freshness(planState, now: Date())
        let displayName = store.providerDisplayName(
            namespace: ProviderRenameNamespace.glm,
            id: account.key,
            fallback: CortexPlanStatusDisplay.rowTitleFallback(plan: plan, account: account)
        )
        let hasFiveHour = account.fiveHourWindow?.percentUsed != nil
        let hasWeekly = account.weeklyWindow?.percentUsed != nil
        let now = Date()
        let fiveHourBar = Self.timeElapsedFraction(
            resetAt: account.fiveHourWindow?.resetAt,
            windowLength: 5 * 3600,
            now: now
        )
        let weeklyBar = Self.timeElapsedFraction(
            resetAt: account.weeklyWindow?.resetAt,
            windowLength: 7 * 24 * 3600,
            now: now
        )
        let mainLine = HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
            providerDot(
                color: glmUsageStatusColor(account),
                namespace: ProviderRenameNamespace.glm,
                key: account.key,
                index: index,
                keys: keys
            )
            EditableBalanceRowName(
                text: displayName,
                accessibilityIdentifier: "glm-name-\(account.maskedKeyText)"
            ) { newName in
                store.renameProvider(
                    namespace: ProviderRenameNamespace.glm,
                    id: account.key,
                    name: newName
                )
            }
            .layoutPriority(1)
            Spacer(minLength: SentinelTheme.Spacing.xs)
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                if let failureText = glmUsageFailureText(account) {
                    Text(failureText)
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    HStack(alignment: .top, spacing: SentinelTheme.Metrics.usageSegmentGap) {
                        if hasFiveHour, let fiveHour = account.fiveHourWindow {
                            quotaSegmentWithBar(
                                label: "5h",
                                // 剩余口径（像电量）：remainingPercentage 就是剩的，不许再反转。
                                valueText: fiveHour.remainingPercentage.map(cursorUsageRemainingText) ?? "—",
                                valueColor: fiveHour.remainingPercentage.map(cursorUsageRemainingColor)
                                    ?? SentinelTheme.Colors.secondaryForeground,
                                columnWidth: SentinelTheme.Metrics.usageColWidth1,
                                barFraction: fiveHourBar
                            )
                        }
                        if hasWeekly, let weekly = account.weeklyWindow {
                            quotaSegmentWithBar(
                                label: "周",
                                valueText: weekly.remainingPercentage.map(cursorUsageRemainingText) ?? "—",
                                valueColor: weekly.remainingPercentage.map(cursorUsageRemainingColor)
                                    ?? SentinelTheme.Colors.secondaryForeground,
                                columnWidth: SentinelTheme.Metrics.usageColWidth2,
                                barFraction: weeklyBar
                            )
                        }
                        if let plan {
                            // 套餐行的第三列：在跑/冷却，不画横条（横条一律是时间
                            // 流逝，这列不是时间），也不加 .help（会和详情卡双弹）。
                            // 数据过时后数值不可信，固定「在跑 —」不显示冷却。
                            let columnText = planFreshness == .stale
                                ? CortexPlanStatusDisplay.staleThirdColumnText
                                : CortexPlanStatusDisplay.thirdColumnText(plan: plan, now: now)
                            Text(columnText)
                                .font(SentinelTheme.Fonts.balanceAmount)
                                .foregroundStyle(SentinelTheme.Colors.foreground)
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(width: SentinelTheme.Metrics.usageColWidth2, alignment: .leading)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(columnText)
                        } else if account.cashBalance != nil {
                            glmBalanceSegment(account)
                        }
                    }
                }
            }
            .frame(
                width: SentinelTheme.Metrics.usageBlockWidth,
                alignment: .leading
            )
        }
        // 套餐行在主行下带一排档案四格 meta 行；非套餐行没有这排，形状照旧。
        return VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
            mainLine
            glmPlanNotesLine(plan)
        }
        .frame(height: SentinelTheme.Metrics.usageRowHeight)
        .contentShape(Rectangle())
        .modifier(HoverDetailCard(
            makeContent: { self.glmDetailContent(account) },
            isSuppressed: { self.suppressCardKey == account.key || self.draggingKey != nil },
            branchID: "glm",
            previewRowMatch: self.rowMatchesPreviewSelection(displayName)
        ))
    }

    /// 套餐行下的档案四格 meta 行（COR-8595 T5）：到期 / 刷新 / 归属 / 看板隐藏。
    /// 文本原样、没登记写「未登记」，规则在 CortexPlanStatusDisplay.planNoteCells；
    /// 字号颜色照失败备注那行（balanceMeta + 次级色），不新开整块。
    @ViewBuilder
    private func glmPlanNotesLine(_ plan: CortexPlanStatusPlan?) -> some View {
        if let plan {
            let cells = CortexPlanStatusDisplay.planNoteCells(plan: plan)
            HStack(alignment: .firstTextBaseline, spacing: SentinelTheme.Spacing.md) {
                ForEach(cells.indices, id: \.self) { index in
                    Text(cells[index])
                        .font(SentinelTheme.Fonts.balanceMeta)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cells.joined(separator: "，"))
        }
    }

    /// 出图选行：给的是行名（用户改名后的最终名）子串，命中才出卡。
    private func rowMatchesPreviewSelection(_ displayName: String) -> Bool {
        guard let selection = hoverCardPreviewRow else {
            return false
        }
        return displayName.localizedCaseInsensitiveContains(selection)
    }

    /// 无任何可显示数字时的右侧文案：优先报错；接口通了但两头都空显示未知。
    private func glmUsageFailureText(_ account: GLMAccountUsage) -> String? {
        if account.hasDisplayableNumber {
            return nil
        }
        if let errorMessage = account.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return "未知"
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
        // 套餐行只看订阅窗口和冷却，现金不参与（套餐派工不花现金）；其余行照旧。
        // 数据过时后冷却判不了，只看订阅窗口。任一附加钥匙有状况 → 至少黄。
        let planState = store.glmPlanStatus
        if let plan = CortexPlanStatusDisplay.plan(forAccountKey: account.key, in: planState?.payload) {
            return CortexPlanStatusDisplay.dotColor(
                plan: plan,
                account: account,
                additionalAccounts: CortexPlanStatusDisplay.additionalAccounts(
                    for: plan,
                    in: store.glmUsage.accounts
                ),
                planState: planState,
                now: Date()
            )
        }
        return Self.glmDotSignal(
            fiveHourRemaining: account.fiveHourWindow?.remainingPercentage,
            weeklyRemaining: account.weeklyWindow?.remainingPercentage,
            cashBalance: account.cashBalance,
            stale: account.stale,
            hasDisplayableNumber: account.hasDisplayableNumber
        )
    }

    /// GLM 状态点分场景（Falcon 2026-09-11 定）：
    /// 有订阅（5h / 周窗任一存在）就只看订阅窗口，现金余额不参与——
    /// 有订阅人家优先烧订阅，余额没人管。没订阅只剩余额的（Lite / 按量）
    /// 才按余额判定。CC 的月余本身就是订阅量，不走这条。
    static func glmDotSignal(
        fiveHourRemaining: Double?,
        weeklyRemaining: Double?,
        cashBalance: Double?,
        stale: Bool,
        hasDisplayableNumber: Bool
    ) -> Color {
        let hasSubscription = fiveHourRemaining != nil || weeklyRemaining != nil
        return providerDotSignal(
            fiveHourRemaining: fiveHourRemaining,
            weeklyRemaining: weeklyRemaining,
            balanceAmount: hasSubscription ? nil : cashBalance,
            stale: stale,
            hasDisplayableNumber: hasDisplayableNumber
        )
    }

    private func glmDetailContent(_ account: GLMAccountUsage) -> BalanceHoverContent {
        let now = Date()
        let planState = store.glmPlanStatus
        let plan = CortexPlanStatusDisplay.plan(forAccountKey: account.key, in: planState?.payload)
        var lines: [BalanceHoverLine] = []
        for (name, window, windowLength) in [
            ("5 小时窗", account.fiveHourWindow, 5 * 3600.0),
            ("周窗", account.weeklyWindow, 7 * 24 * 3600.0),
        ] {
            guard let window else { continue }
            var value = ""
            if let used = window.usedPoints, let total = window.totalPoints, total > 0 {
                // 不带「积分」字样：卡宽 296 里带着它重置时间必截（量宽实锤），CC 卡口径一致。
                value = "已用 \(Self.pointsText(used)) / \(Self.pointsText(total))"
            } else if let percent = window.percentUsed {
                value = "已用 \(Int(percent.rounded()))%"
            }
            lines.append(BalanceHoverLine(
                label: name,
                value: value,
                note: window.resetAt.map { "\(Self.shortTime($0)) 重置" },
                noteColor: Self.resetNoteColor(
                    Self.timeElapsedFraction(resetAt: window.resetAt, windowLength: windowLength, now: now)
                )
            ))
        }
        // 套餐行追加派工状态；不是套餐的行一个字不变。
        // 数据过时后只留在跑/现金/派工状态三行，执行者、派工、免费时段不显示。
        if let plan {
            // 现金主钥匙行没有时用附加钥匙行的数（同账号现金是同一份）。
            let cash = CortexPlanStatusDisplay.planCashBalance(
                plan: plan,
                primary: account,
                accounts: store.glmUsage.accounts
            )
            if CortexPlanStatusDisplay.freshness(planState, now: now) == .stale,
               let failureText = planState?.failureText {
                lines.append(contentsOf: CortexPlanStatusDisplay.staleDetailLines(
                    plan: plan,
                    failureText: failureText,
                    cashBalance: cash
                ))
            } else {
                lines.append(contentsOf: CortexPlanStatusDisplay.detailLines(
                    plan: plan,
                    payload: planState?.payload,
                    failureText: planState?.failureText,
                    fetchedAt: planState?.fetchedAt,
                    cashBalance: cash
                ))
            }
            // 同账号附加钥匙：正常时只在这里报一句「同账号，额度共用」，
            // 行上不重复显示；出错或读数对不上在这里说出来。
            lines.append(contentsOf: CortexPlanStatusDisplay.additionalKeyLines(
                plan: plan,
                primary: account,
                accounts: store.glmUsage.accounts
            ) { additional in
                store.providerDisplayName(
                    namespace: ProviderRenameNamespace.glm,
                    id: additional.key,
                    fallback: additional.displayTitle
                )
            })
        }
        var subtitle = "GLM Coding Plan"
        if let level = account.level, !level.isEmpty {
            subtitle += " · 档位 \(level)"
        }
        var alert: String?
        var alertColor: Color?
        if let errorMessage = account.errorMessage {
            alert = errorMessage
            alertColor = SentinelTheme.Colors.danger
        } else if account.stale {
            alert = "数据已过期"
            alertColor = SentinelTheme.Colors.warning
        }
        return BalanceHoverContent(
            title: store.providerDisplayName(
                namespace: ProviderRenameNamespace.glm,
                id: account.key,
                fallback: CortexPlanStatusDisplay.rowTitleFallback(plan: plan, account: account)
            ),
            subtitle: subtitle,
            lines: lines,
            footer: account.checkedAt.map { "\(SentinelTimeFormat.clockTime($0)) 更新" },
            alert: alert,
            alertColor: alertColor
        )
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

    /// 时间轴：窗口内已流逝占比，正向走（重置时 0 起步，越接近 resetAt 越满）。
    /// 5 小时窗按 5h 折算，周窗按 7 天。过了 resetAt 就是满格（该重置了）。
    /// Falcon 2026-09-11 定：数字报剩余，横条报流逝，方向别再搞反。
    static func timeElapsedFraction(
        resetAt: Date?,
        windowLength: TimeInterval,
        now: Date
    ) -> Double? {
        guard let resetAt else {
            return nil
        }
        let remaining = resetAt.timeIntervalSince(now)
        return min(1, max(0, 1 - remaining / windowLength))
    }

    /// 账期时间轴：已流逝占比；起点缺失按 30 天账期折算。
    static func periodElapsedFraction(
        end: Date?,
        start: Date?,
        now: Date
    ) -> Double? {
        guard let end else {
            return nil
        }
        let length: TimeInterval
        if let start, end > start {
            length = end.timeIntervalSince(start)
        } else {
            length = 30 * 24 * 3600
        }
        let remaining = end.timeIntervalSince(now)
        return min(1, max(0, 1 - remaining / length))
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
                // 三组余额并入等宽网格（跟 GLM / CC 同列对齐）；
                // Cursor 没有时间窗，不放横条。Falcon 2026-09-11 定。
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xxs) {
                    HStack(alignment: .top, spacing: SentinelTheme.Metrics.usageSegmentGap) {
                        cursorGridSegment("Grok", snapshot.autoPercentUsed)
                        cursorGridSegment("API", snapshot.apiPercentUsed)
                        cursorGridSegment("Bot", snapshot.botPercentUsed)
                    }
                }
                .frame(
                    width: SentinelTheme.Metrics.usageBlockWidth,
                    alignment: .leading
                )
                .layoutPriority(2)
            }
            .frame(height: SentinelTheme.Metrics.usageRowHeight)
            .contentShape(Rectangle())
            .help(cursorUsageTooltip(snapshot))
        }
    }

    /// Cursor 行的网格段：剩余百分比换算跟老段一致，交给等宽网格渲染（无条）。
    private func cursorGridSegment(
        _ label: String,
        _ percentUsed: Double?
    ) -> some View {
        let remaining = percentUsed.map { min(100, max(0, 100 - $0)) }
        return quotaSegmentWithBar(
            label: label,
            valueText: remaining.map(cursorUsageRemainingText) ?? "—",
            valueColor: remaining.map(cursorUsageRemainingColor)
                ?? SentinelTheme.Colors.secondaryForeground,
            columnWidth: SentinelTheme.Metrics.usageColWidth1,
            barFraction: nil
        )
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

    /// CodeBuddy 积分余额：三个号并排一行（等宽网格，无横条——积分没有时间窗）。
    /// 一把 key 都没有时整行不占位；封禁的号在抓取层就被剔除；
    /// 可用的号超过三个时只取前三个进格子，其余进悬停。
    @ViewBuilder private var codeBuddyUsageRow: some View {
        let snapshot = store.codeBuddyCredit
        if snapshot.accounts.isEmpty {
            EmptyView()
        } else {
            let grid = CodeBuddyCreditConstants.gridSplit(snapshot.accounts)
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Circle()
                    .fill(codeBuddyStatusColor(visible: grid.visible))
                    .frame(
                        width: SentinelTheme.Metrics.balanceDot,
                        height: SentinelTheme.Metrics.balanceDot
                    )
                Text("CodeBuddy")
                    .font(SentinelTheme.Fonts.balanceName)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: SentinelTheme.Spacing.xs)
                HStack(alignment: .top, spacing: SentinelTheme.Metrics.usageSegmentGap) {
                    ForEach(grid.visible) { account in
                        codeBuddyGridSegment(account)
                    }
                }
                .frame(
                    width: SentinelTheme.Metrics.usageBlockWidth,
                    alignment: .leading
                )
                .layoutPriority(2)
            }
            .frame(height: SentinelTheme.Metrics.usageRowHeight)
            .contentShape(Rectangle())
            .modifier(HoverDetailCard(
                makeContent: { self.codeBuddyDetailContent(snapshot) },
                branchID: "codebuddy",
                previewRowMatch: self.rowMatchesPreviewSelection("CodeBuddy")
            ))
        }
    }

    /// 格子：短名 + 剩余积分（向下取整）。颜色只看剩余积分档位。
    private func codeBuddyGridSegment(_ account: CodeBuddyAccountCredit) -> some View {
        let color = account.credits.map(Self.codeBuddyCreditColor)
            ?? SentinelTheme.Colors.secondaryForeground
        return quotaSegmentWithBar(
            label: account.label,
            valueText: CodeBuddyCreditConstants.creditsText(account.credits),
            valueColor: color,
            columnWidth: SentinelTheme.Metrics.usageColWidth1,
            barFraction: nil
        )
    }

    /// 行左状态点取三格里最坏的那档；有账号数据过期至少黄，全没数字给灰。
    private func codeBuddyStatusColor(visible: [CodeBuddyAccountCredit]) -> Color {
        if visible.contains(where: \.stale) {
            return SentinelTheme.Colors.warning
        }
        let levels = visible.compactMap { account in
            account.credits.map(CodeBuddyCreditConstants.creditLevel)
        }
        guard let worst = CodeBuddyCreditConstants.worstLevel(levels) else {
            return SentinelTheme.Colors.secondaryForeground
        }
        return Self.codeBuddyLevelColor(worst)
    }

    private static func codeBuddyLevelColor(_ level: CodeBuddyCreditLevel) -> Color {
        switch level {
        case .normal:
            return SentinelTheme.Colors.success
        case .low:
            return SentinelTheme.Colors.warning
        case .critical:
            return SentinelTheme.Colors.danger
        }
    }

    private static func codeBuddyCreditColor(_ credits: Double) -> Color {
        codeBuddyLevelColor(CodeBuddyCreditConstants.creditLevel(credits))
    }

    /// 悬停：每个号三行（余额+人民币 / key+到期 / 今日+累计）；
    /// 号数超过格子容量的也全在这里列出；抓取失败的把失败原因写在余额备注里。
    private func codeBuddyDetailContent(_ snapshot: CodeBuddyCreditSnapshot) -> BalanceHoverContent {
        var lines: [BalanceHoverLine] = []
        var usedNames: Set<String> = []
        for account in snapshot.accounts {
            // 悬停行按 label 去重渲染，重名账号追加 key 尾巴保证唯一。
            var name = account.label
            if usedNames.contains(name) {
                name = "\(name)·\(account.key.suffix(4))"
            }
            usedNames.insert(name)
            if let credits = account.credits {
                lines.append(BalanceHoverLine(
                    label: name,
                    value: CodeBuddyCreditConstants.creditsText(credits),
                    note: CodeBuddyCreditConstants.cnyText(credits: credits, payBase1000: snapshot.payBase1000),
                    noteColor: nil
                ))
            } else {
                lines.append(BalanceHoverLine(
                    label: name,
                    value: "—",
                    note: account.errorMessage,
                    noteColor: SentinelTheme.Colors.danger
                ))
            }
            lines.append(BalanceHoverLine(
                label: "\(name) key",
                value: account.maskedKeyText,
                note: account.expiryText,
                noteColor: nil
            ))
            lines.append(BalanceHoverLine(
                label: "\(name) 用量",
                value: "今日 \(CodeBuddyCreditConstants.creditsText(account.todayUsed))",
                note: codeBuddyTotalsNote(account),
                noteColor: nil
            ))
        }
        var alert: String?
        var alertColor: Color?
        if snapshot.accounts.contains(where: \.stale) {
            alert = "数据已过期"
            alertColor = SentinelTheme.Colors.warning
        }
        return BalanceHoverContent(
            title: "CodeBuddy 积分余额",
            subtitle: snapshot.payBase1000.map {
                String(format: "按站点现价 1000 积分 = %g 元", $0)
            },
            lines: lines,
            footer: snapshot.checkedAt.map { "\(SentinelTimeFormat.clockTime($0)) 更新" },
            alert: alert,
            alertColor: alertColor
        )
    }

    private func codeBuddyTotalsNote(_ account: CodeBuddyAccountCredit) -> String? {
        var parts: [String] = []
        if let used = account.totalUsed {
            parts.append("累 \(CodeBuddyCreditConstants.creditsText(used))")
        }
        if let recharged = account.totalRecharged {
            parts.append("充 \(CodeBuddyCreditConstants.creditsText(recharged))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
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
            Button(SentinelPaths.missingWatchDirectoryButton) {
                store.chooseWatchDirectory()
            }
            .buttonStyle(SentinelButtonStyle(kind: .primary, compact: true))
            .accessibilityIdentifier("watch-missing-choose-button")
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
            Button { store.openWorkbench() } label: {
                Label("打开开发工作台", systemImage: "square.grid.3x3")
            }
            .buttonStyle(SentinelButtonStyle(kind: .secondary, compact: true))
            .disabled(store.workbench == nil)
            if let error = store.workbenchError {
                Text(error).font(SentinelTheme.Fonts.subtitle).foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            }
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

/// Command Code 首次接入引导：余额区引导行点开，就地填 key，不绕设置窗。
/// 字段直接绑设置模型的 cc 输入框；保存走 addCommandCodeKeyFromFields，
/// 由 applyCommandCodeKeys 回调 store 立刻重查一轮。
struct SentinelCommandCodeKeyPanel: View {
    @ObservedObject var model: SentinelSettingsModel
    let onClose: () -> Void

    private var canSave: Bool {
        model.ccNewKey.trimmingCharacters(in: .whitespacesAndNewlines).count
            >= CommandCodeUsageConstants.minKeyLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
            HStack(spacing: SentinelTheme.Spacing.md) {
                Text("接入 Command Code")
                    .font(SentinelTheme.Fonts.rowTitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(
                    SentinelLineControlButtonStyle(
                        width: SentinelTheme.Metrics.lineControlIconWidth
                    )
                )
                .help("关闭")
                .accessibilityLabel("关闭")
            }

            Text("粘贴 API Key，哨兵只查账务接口，不消耗 credits。用过官方 CLI 的话会自动识别登录态，无需手动填。")
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                TextField(SentinelSettingsCopy.commandCodeNameFieldPlaceholder, text: $model.ccNewLabel)
                    .textFieldStyle(.plain)
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                    .padding(.horizontal, SentinelTheme.Spacing.md)
                    .frame(width: 110)
                    .frame(minHeight: SentinelTheme.Metrics.controlHeight)
                    .background(SentinelTheme.Colors.inset)
                    .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.field))
                    .overlay(
                        RoundedRectangle(cornerRadius: SentinelTheme.Radius.field)
                            .stroke(
                                SentinelTheme.Colors.border,
                                lineWidth: SentinelTheme.Metrics.borderWidth
                            )
                    )
                    .accessibilityIdentifier("commandcode-panel-new-label")

                TextField(SentinelSettingsCopy.commandCodeKeyFieldPlaceholder, text: $model.ccNewKey)
                    .textFieldStyle(.plain)
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                    .padding(.horizontal, SentinelTheme.Spacing.md)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: SentinelTheme.Metrics.controlHeight)
                    .background(SentinelTheme.Colors.inset)
                    .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.field))
                    .overlay(
                        RoundedRectangle(cornerRadius: SentinelTheme.Radius.field)
                            .stroke(
                                SentinelTheme.Colors.border,
                                lineWidth: SentinelTheme.Metrics.borderWidth
                            )
                    )
                    .onSubmit(save)
                    .accessibilityIdentifier("commandcode-panel-new-key")
            }

            HStack(spacing: SentinelTheme.Spacing.md) {
                if !canSave {
                    Text("key 至少 \(CommandCodeUsageConstants.minKeyLength) 位")
                        .font(SentinelTheme.Fonts.metadata)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                }
                Spacer()
                Button("保存并开始监控", action: save)
                    .buttonStyle(SentinelButtonStyle(kind: .primary, compact: true))
                    .disabled(!canSave)
                    .accessibilityIdentifier("commandcode-panel-save")
            }
        }
        .padding(SentinelTheme.Spacing.sheet)
        .frame(width: 360)
        .background(SentinelTheme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel)
                .stroke(
                    SentinelTheme.Colors.border,
                    lineWidth: SentinelTheme.Metrics.borderWidth
                )
        )
        .accessibilityIdentifier("commandcode-key-panel")
    }

    private func save() {
        guard canSave else {
            return
        }
        model.addCommandCodeKeyFromFields()
        onClose()
    }
}
