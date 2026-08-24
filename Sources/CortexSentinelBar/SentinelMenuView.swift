import AppKit
import SwiftUI

enum SentinelMenuInitialSection {
    case top
    case dispatch
}

/// 面板骨架。2026-08-24 架构改造：原来这里是一个 1798 行的 body，68 处直接读
/// store，任何一路刷新（哪怕只是某个账号余额回来了）都让整个面板重算一遍。
/// 现在它只搭 ScrollView 骨架和设置浮层；十个分区各自是独立 View（见
/// SentinelMenuSections.swift），各读各的数据。生产路径父 body 只读两个低频开关
/// （packagingActive / panelPresentationGeneration），不读线列表和余额。
struct SentinelMenuView: View {
    var store: SentinelStore
    var initialSection: SentinelMenuInitialSection = .top
    /// 仅截图 smoke 用：预展开第一条最近完成，便于给第 4 点留证；菜单栏常驻默认 false。
    var autoExpandFirstCompleted = false
    /// 离屏出图用：ImageRenderer 吃不下 ScrollView/LazyVStack，换成同等间距的 VStack。
    /// 菜单栏常驻默认 false，现场布局一条都不改。
    var rendersOffscreen = false
    @State private var settingsLine: LineStatus?

    var body: some View {
        // 生产路径仍不读线/余额等高频面。只读两个低频开关：
        // packagingActive 决定要不要把打包分区挂进树；
        // panelPresentationGeneration 在每次打开面板时强制父 body 按当前 store 重挂，
        // 避开「隐藏 NSPopover 的 NSHostingView 丢掉 Observation 更新」。
        let _ = store.panelPresentationGeneration
        let packagingActive = store.packagingActive
        ZStack {
            if rendersOffscreen {
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
                    sectionStack(packagingActive: packagingActive)
                }
                .padding(SentinelTheme.Spacing.panel)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
                            sectionStack(packagingActive: packagingActive)
                        }
                        .padding(SentinelTheme.Spacing.panel)
                    }
                    .modifier(
                        InitialSectionScrollModifier(
                            enabled: initialSection == .dispatch,
                            store: store,
                            proxy: proxy
                        )
                    )
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
    }

    @ViewBuilder
    private func sectionStack(packagingActive: Bool) -> some View {
        SentinelHeaderSection(store: store)
        if packagingActive {
            SentinelPackagingSection(store: store)
        }
        SentinelChannelSection(store: store)
        SentinelServiceSection(store: store)
        SentinelBalancesSection(store: store)
        SentinelDispatchSection(
            store: store,
            autoExpandFirstCompleted: autoExpandFirstCompleted,
            onShowSettings: { settingsLine = $0 }
        )
        .id(SentinelMenuInitialSection.dispatch)
        SentinelAutomaticSection(
            store: store,
            onShowSettings: { settingsLine = $0 }
        )
        SentinelHistorySection(store: store)
        // 后台任务垫在内容区最后：它平时只是一行摘要，出问题时展开才铺告警，不该抢派工的位置。
        SentinelBackgroundJobsPanelSection(store: store)
        SentinelFooterSection(store: store)
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
}

/// smoke 截图专用：把视口滚到派工区，并在 aio 快照落地后再滚一次对齐。
/// 只有 --smoke-lines 传了 initialSection == .dispatch 才会挂上 onChange，
/// 生产面板不因此订阅 store.aio。
private struct InitialSectionScrollModifier: ViewModifier {
    let enabled: Bool
    var store: SentinelStore
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        if enabled {
            content
                .onAppear {
                    proxy.scrollTo(SentinelMenuInitialSection.dispatch, anchor: .top)
                }
                .onChange(of: store.aio.readAt) {
                    proxy.scrollTo(SentinelMenuInitialSection.dispatch, anchor: .top)
                }
        } else {
            content
        }
    }
}
