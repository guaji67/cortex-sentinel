import AppKit
import SwiftUI

final class SentinelViewBodyCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
final class SentinelSettingsModel: ObservableObject {
    @Published var loginItem: LoginItemSettingsPresentation
    @Published var historyRetainCount: Int
    @Published var notifyMasterEnabled: Bool
    @Published var notifyTaskCompleteEnabled: Bool
    @Published var notifyTaskProblemEnabled: Bool
    @Published var notifyChannelAlertEnabled: Bool
    @Published var notifyCadence: SentinelNotifyCadence
    @Published var panelOpenRefreshInterval: SentinelPanelOpenRefreshInterval
    @Published var panelClosedRefreshInterval: SentinelPanelClosedRefreshInterval
    @Published var balanceRecheckInterval: SentinelBalanceRecheckInterval
    @Published var watchPath: String
    @Published var isWatchLocked: Bool
    /// GLM 额度监控的生效 key 列表（自动识别 ∪ 手动添加 − 已删除），
    /// 由 store 在打开设置窗和增删后同步进来。
    @Published var glmEntries: [GLMKeyEntry] = []
    @Published var glmNewLabel: String = ""
    @Published var glmNewKey: String = ""
    /// Command Code 额度监控的生效 key 列表，同 GLM 一套结构。
    @Published var ccEntries: [CommandCodeKeyEntry] = []
    @Published var ccNewLabel: String = ""
    @Published var ccNewKey: String = ""
    /// 自更新：自动下载并安装（默认关，只提醒）。
    @Published var updateAutoInstall: Bool

    var applyLoginItem: ((Bool) -> Void)?
    var applyHistoryRetainCount: ((Int) -> Void)?
    var applyRefreshIntervals: (() -> Void)?
    var chooseWatchDirectory: (() -> Void)?
    var applyGLMKeys: (() -> Void)?
    var applyCommandCodeKeys: (() -> Void)?

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults,
        loginItem: LoginItemSettingsPresentation,
        historyRetainCount: Int,
        preferences: SentinelNotifyPreferences,
        watchPath: String,
        isWatchLocked: Bool
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.historyRetainCount = historyRetainCount
        self.notifyMasterEnabled = preferences.masterEnabled
        self.notifyTaskCompleteEnabled = preferences.taskCompleteEnabled
        self.notifyTaskProblemEnabled = preferences.taskProblemEnabled
        self.notifyChannelAlertEnabled = preferences.channelAlertEnabled
        self.notifyCadence = preferences.cadence
        self.panelOpenRefreshInterval = SentinelSettings.panelOpenRefreshInterval(defaults: defaults)
        self.panelClosedRefreshInterval = SentinelSettings.panelClosedRefreshInterval(defaults: defaults)
        self.balanceRecheckInterval = SentinelSettings.balanceRecheckInterval(defaults: defaults)
        self.watchPath = watchPath
        self.isWatchLocked = isWatchLocked
        self.updateAutoInstall = SentinelSettings.updateAutoInstall(defaults: defaults)
    }

    var preferences: SentinelNotifyPreferences {
        SentinelNotifyPreferences(
            masterEnabled: notifyMasterEnabled,
            taskCompleteEnabled: notifyTaskCompleteEnabled,
            taskProblemEnabled: notifyTaskProblemEnabled,
            channelAlertEnabled: notifyChannelAlertEnabled,
            cadence: notifyCadence
        )
    }

    /// 只给设置窗正文显示。存的 `watchPath` 一个字节都不改。
    var watchPathDisplay: String {
        (watchPath as NSString).abbreviatingWithTildeInPath
    }

    var loginItemBinding: Binding<Bool> {
        Binding(
            get: { self.loginItem.isOn },
            set: { self.setLoginItemEnabled($0) }
        )
    }

    var masterBinding: Binding<Bool> {
        Binding(
            get: { self.notifyMasterEnabled },
            set: { self.setNotifyMasterEnabled($0) }
        )
    }

    var taskCompleteBinding: Binding<Bool> {
        Binding(
            get: { self.notifyTaskCompleteEnabled },
            set: { self.setNotifyTaskCompleteEnabled($0) }
        )
    }

    var taskProblemBinding: Binding<Bool> {
        Binding(
            get: { self.notifyTaskProblemEnabled },
            set: { self.setNotifyTaskProblemEnabled($0) }
        )
    }

    var channelAlertBinding: Binding<Bool> {
        Binding(
            get: { self.notifyChannelAlertEnabled },
            set: { self.setNotifyChannelAlertEnabled($0) }
        )
    }

    var cadenceBinding: Binding<SentinelNotifyCadence> {
        Binding(
            get: { self.notifyCadence },
            set: { self.setNotifyCadence($0) }
        )
    }

    var panelOpenRefreshBinding: Binding<SentinelPanelOpenRefreshInterval> {
        Binding(
            get: { self.panelOpenRefreshInterval },
            set: { self.setPanelOpenRefreshInterval($0) }
        )
    }

    var panelClosedRefreshBinding: Binding<SentinelPanelClosedRefreshInterval> {
        Binding(
            get: { self.panelClosedRefreshInterval },
            set: { self.setPanelClosedRefreshInterval($0) }
        )
    }

    var balanceRecheckBinding: Binding<SentinelBalanceRecheckInterval> {
        Binding(
            get: { self.balanceRecheckInterval },
            set: { self.setBalanceRecheckInterval($0) }
        )
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        applyLoginItem?(enabled)
    }

    func setHistoryRetainCount(_ value: Int) {
        applyHistoryRetainCount?(value)
        historyRetainCount = max(1, value)
    }

    func setNotifyMasterEnabled(_ enabled: Bool) {
        SentinelSettings.setNotifyMasterEnabled(enabled, defaults: defaults)
        notifyMasterEnabled = enabled
    }

    func setNotifyTaskCompleteEnabled(_ enabled: Bool) {
        SentinelSettings.setNotifyCategoryEnabled(
            enabled,
            key: SentinelSettingsKey.notifyCategoryTaskComplete,
            defaults: defaults
        )
        notifyTaskCompleteEnabled = enabled
    }

    func setNotifyTaskProblemEnabled(_ enabled: Bool) {
        SentinelSettings.setNotifyCategoryEnabled(
            enabled,
            key: SentinelSettingsKey.notifyCategoryTaskProblem,
            defaults: defaults
        )
        notifyTaskProblemEnabled = enabled
    }

    func setNotifyChannelAlertEnabled(_ enabled: Bool) {
        SentinelSettings.setNotifyCategoryEnabled(
            enabled,
            key: SentinelSettingsKey.notifyCategoryChannelAlert,
            defaults: defaults
        )
        notifyChannelAlertEnabled = enabled
    }

    func setNotifyCadence(_ cadence: SentinelNotifyCadence) {
        SentinelSettings.setNotifyCadence(cadence, defaults: defaults)
        self.notifyCadence = cadence
    }

    func setPanelOpenRefreshInterval(_ interval: SentinelPanelOpenRefreshInterval) {
        SentinelSettings.setPanelOpenRefreshInterval(interval, defaults: defaults)
        panelOpenRefreshInterval = interval
        applyRefreshIntervals?()
    }

    func setPanelClosedRefreshInterval(_ interval: SentinelPanelClosedRefreshInterval) {
        SentinelSettings.setPanelClosedRefreshInterval(interval, defaults: defaults)
        panelClosedRefreshInterval = interval
        applyRefreshIntervals?()
    }

    func setBalanceRecheckInterval(_ interval: SentinelBalanceRecheckInterval) {
        SentinelSettings.setBalanceRecheckInterval(interval, defaults: defaults)
        balanceRecheckInterval = interval
        applyRefreshIntervals?()
    }

    var updateAutoInstallBinding: Binding<Bool> {
        Binding(
            get: { self.updateAutoInstall },
            set: { self.setUpdateAutoInstall($0) }
        )
    }

    func setUpdateAutoInstall(_ enabled: Bool) {
        SentinelSettings.setUpdateAutoInstall(enabled, defaults: defaults)
        updateAutoInstall = enabled
    }

    /// 把两个输入框里的内容录成一把新 key；key 太短或已存在就不动。
    func addGLMKeyFromFields() {
        addGLMKey(name: glmNewLabel, key: glmNewKey)
        glmNewLabel = ""
        glmNewKey = ""
    }

    /// 录入一把新 GLM key（名称可空）；key 太短或已存在就不动，也不发变更通知。
    func addGLMKey(name: String, key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.count >= GLMKeyConstants.minKeyLength else {
            return
        }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = SentinelSettings.addGLMUserKey(
            GLMKeyEntry(label: label.isEmpty ? "自定义" : label, key: trimmedKey, source: "user"),
            defaults: defaults
        )
        // 手动加回来的 key 同时从删除名单里捞回来。
        SentinelSettings.removeGLMRemovedKey(trimmedKey, defaults: defaults)
        guard added else {
            return
        }
        applyGLMKeys?()
    }

    /// 删一把 key：手加的直接删，自动识别的进删除名单防下次启动又认回来。
    func removeGLMKey(_ entry: GLMKeyEntry) {
        SentinelSettings.removeGLMUserKey(entry.key, defaults: defaults)
        SentinelSettings.addGLMRemovedKey(entry.key, defaults: defaults)
        applyGLMKeys?()
    }

    /// 把两个输入框里的内容录成一把新 Command Code key；key 太短或已存在就不动。
    func addCommandCodeKeyFromFields() {
        addCommandCodeKey(name: ccNewLabel, key: ccNewKey)
        ccNewLabel = ""
        ccNewKey = ""
    }

    /// 录入一把新 Command Code key（名称可空）；key 太短或已存在就不动，也不发变更通知。
    func addCommandCodeKey(name: String, key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.count >= CommandCodeUsageConstants.minKeyLength else {
            return
        }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = SentinelSettings.addCommandCodeUserKey(
            CommandCodeKeyEntry(label: label.isEmpty ? "账号" : label, key: trimmedKey),
            defaults: defaults
        )
        // 手动加回来的 key 同时从删除名单里捞回来。
        SentinelSettings.removeCommandCodeRemovedKey(trimmedKey, defaults: defaults)
        guard added else {
            return
        }
        applyCommandCodeKeys?()
    }

    /// 删一把 Command Code key：手加的直接删，自动识别的进删除名单。
    func removeCommandCodeKey(_ entry: CommandCodeKeyEntry) {
        SentinelSettings.removeCommandCodeUserKey(entry.key, defaults: defaults)
        SentinelSettings.addCommandCodeRemovedKey(entry.key, defaults: defaults)
        applyCommandCodeKeys?()
    }

    static func preview(
        fixture: SettingsPreviewFixture,
        defaults: UserDefaults = UserDefaults(suiteName: "com.falcon.cortex.sentinelbar.preview")
            ?? .standard
    ) -> SentinelSettingsModel {
        let preferences: SentinelNotifyPreferences
        switch fixture {
        case .default, .loginManaged, .watchLocked:
            preferences = .default
        case .masterOff:
            preferences = SentinelNotifyPreferences(
                masterEnabled: false,
                taskCompleteEnabled: true,
                taskProblemEnabled: true,
                channelAlertEnabled: true,
                cadence: .default
            )
        }

        let loginItem: LoginItemSettingsPresentation
        switch fixture {
        case .loginManaged:
            loginItem = LoginItemSettingsPresentation(
                isOn: true,
                isControlEnabled: false,
                trailingHint: SentinelSettingsCopy.loginItemManagedHint
            )
        default:
            loginItem = LoginItemSettingsPresentation(
                isOn: true,
                isControlEnabled: true,
                trailingHint: nil
            )
        }

        let model = SentinelSettingsModel(
            defaults: defaults,
            loginItem: loginItem,
            historyRetainCount: StatusFileRetention.defaultCap,
            preferences: preferences,
            watchPath: SentinelPaths.defaultWatchDirectory.path,
            isWatchLocked: fixture == .watchLocked
        )
        // 截图 smoke 用演示 key（假数据），让 GLM / Command Code 列表行在出图里有覆盖。
        model.glmEntries = [
            GLMKeyEntry(label: "pro", key: "demo0000000000000000000000000000.zf4X"),
        ]
        model.ccEntries = [
            CommandCodeKeyEntry(label: "账号1", key: "demo-cc-0000000000000000000000000001"),
        ]
        return model
    }
}

enum SettingsPreviewFixture: String {
    case `default`
    case masterOff = "master-off"
    case loginManaged = "login-managed"
    case watchLocked = "watch-locked"
}

enum SettingsDropdownID: Hashable {
    case cadence
    case panelOpen
    case panelClosed
    case balanceRecheck
}

struct SentinelSettingsView: View {
    @ObservedObject var model: SentinelSettingsModel
    var bodyCounter: SentinelViewBodyCounter?
    var rendersOffscreen = false
    var versionLine: String = SentinelAppVersion.displayLine()
    @State private var historyTextOverride: String?
    @State private var expandedMenu: SettingsDropdownID?

    /// 设置内容栈：真窗口包进 ScrollView 滚动，离屏出图直接取它（不套滚动）。
    var settingsContent: some View {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.panel) {
            settingsGroup(title: SentinelSettingsCopy.notifyGroupTitle) {
                notifyGroup
            }
            settingsGroup(title: SentinelSettingsCopy.glmGroupTitle) {
                glmKeyGroup
            }
            settingsGroup(title: SentinelSettingsCopy.commandCodeGroupTitle) {
                commandCodeKeyGroup
            }
            settingsGroup(title: SentinelSettingsCopy.refreshGroupTitle) {
                refreshGroup
            }
            settingsGroup(title: SentinelSettingsCopy.historyGroupTitle) {
                historyGroup
            }
            settingsGroup(title: SentinelSettingsCopy.startupGroupTitle) {
                startupGroup
            }
            versionFooter
            }
            .padding(SentinelTheme.Spacing.sheet)
            .frame(width: SentinelTheme.Metrics.settingsWindowWidth, alignment: .leading)
    }

    var body: some View {
        let _ = bodyCounter?.increment()
        ScrollView(.vertical) {
            settingsContent
        }
        .frame(width: SentinelTheme.Metrics.settingsWindowWidth)
        .background(SentinelTheme.Colors.canvas)
        .tint(SentinelTheme.Colors.primary)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("app-settings-window")
        .onChange(of: model.historyRetainCount) { _, _ in
            historyTextOverride = nil
        }
        .onDisappear(perform: commitHistoryCount)
    }

    private var notifyGroup: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
            labeledToggle(
                title: SentinelSettingsCopy.notifyMasterTitle,
                isOn: model.masterBinding,
                identifier: "settings-notify-toggle"
            )

            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
                labeledToggle(
                    title: SentinelSettingsCopy.notifyTaskCompleteTitle,
                    isOn: model.taskCompleteBinding,
                    identifier: "settings-notify-complete-toggle"
                )
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                    labeledToggle(
                        title: SentinelSettingsCopy.notifyTaskProblemTitle,
                        isOn: model.taskProblemBinding,
                        identifier: "settings-notify-problem-toggle"
                    )
                    hintText(SentinelSettingsCopy.notifyTaskProblemHint)
                        .padding(.leading, 4)
                }
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                    labeledToggle(
                        title: SentinelSettingsCopy.notifyChannelTitle,
                        isOn: model.channelAlertBinding,
                        identifier: "settings-notify-channel-toggle"
                    )
                    hintText(SentinelSettingsCopy.notifyChannelHint)
                        .padding(.leading, 4)
                }

                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                    HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                        Text(SentinelSettingsCopy.notifyCadenceTitle)
                            .font(SentinelTheme.Fonts.rowTitle)
                            .foregroundStyle(SentinelTheme.Colors.foreground)
                        Spacer(minLength: SentinelTheme.Spacing.sm)
                        settingsDropdown(
                            identifier: "settings-notify-cadence",
                            menu: .cadence,
                            title: model.notifyCadence.title,
                            options: SentinelNotifyCadence.allCases,
                            isSelected: { $0 == model.notifyCadence },
                            titleFor: { $0.title },
                            onSelect: { model.setNotifyCadence($0) }
                        )
                    }
                    hintText(SentinelSettingsCopy.notifyCadenceHint)
                }
            }
            .padding(.leading, SentinelTheme.Metrics.settingsCategoryIndent)
            .disabled(!model.notifyMasterEnabled)
            .opacity(model.notifyMasterEnabled ? 1 : 0.7)
        }
    }

    private var glmKeyGroup: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
            if model.glmEntries.isEmpty {
                hintText(SentinelSettingsCopy.glmEmptyHint)
            } else {
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                    ForEach(model.glmEntries, id: \.key) { entry in
                        HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                            Text(entry.label.isEmpty ? "GLM" : entry.label)
                                .font(SentinelTheme.Fonts.rowTitle)
                                .foregroundStyle(SentinelTheme.Colors.foreground)
                                .lineLimit(1)
                            Spacer(minLength: SentinelTheme.Spacing.sm)
                            Text(entry.maskedKeyText)
                                .font(SentinelTheme.Fonts.metadata)
                                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                                .lineLimit(1)
                            Button(SentinelSettingsCopy.glmDeleteButton) {
                                model.removeGLMKey(entry)
                            }
                            .buttonStyle(SentinelButtonStyle(kind: .secondary, compact: true))
                            .accessibilityIdentifier("settings-glm-delete-\(entry.label)")
                        }
                    }
                }
            }

            SettingsKeyInputRow(
                namePlaceholder: SentinelSettingsCopy.glmNameFieldPlaceholder,
                keyPlaceholder: SentinelSettingsCopy.glmKeyFieldPlaceholder,
                addButtonTitle: SentinelSettingsCopy.glmAddButton,
                identifierPrefix: "settings-glm",
                minKeyLength: GLMKeyConstants.minKeyLength,
                rendersOffscreen: rendersOffscreen
            ) { name, key in
                model.addGLMKey(name: name, key: key)
            }
            hintText(SentinelSettingsCopy.glmHint)
        }
    }

    /// Command Code key 管理：列表 + 增删，和 GLM 组同一套交互。
    private var commandCodeKeyGroup: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
            if model.ccEntries.isEmpty {
                hintText(SentinelSettingsCopy.commandCodeEmptyHint)
            } else {
                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
                    ForEach(model.ccEntries, id: \.key) { entry in
                        HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                            Text(entry.label.isEmpty ? "Command Code" : entry.label)
                                .font(SentinelTheme.Fonts.rowTitle)
                                .foregroundStyle(SentinelTheme.Colors.foreground)
                                .lineLimit(1)
                            Spacer(minLength: SentinelTheme.Spacing.sm)
                            Text(entry.maskedKeyText)
                                .font(SentinelTheme.Fonts.metadata)
                                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                                .lineLimit(1)
                            Button(SentinelSettingsCopy.commandCodeDeleteButton) {
                                model.removeCommandCodeKey(entry)
                            }
                            .buttonStyle(SentinelButtonStyle(kind: .secondary, compact: true))
                            .accessibilityIdentifier("settings-commandcode-delete-\(entry.label)")
                        }
                    }
                }
            }

            SettingsKeyInputRow(
                namePlaceholder: SentinelSettingsCopy.commandCodeNameFieldPlaceholder,
                keyPlaceholder: SentinelSettingsCopy.commandCodeKeyFieldPlaceholder,
                addButtonTitle: SentinelSettingsCopy.commandCodeAddButton,
                identifierPrefix: "settings-commandcode",
                minKeyLength: CommandCodeUsageConstants.minKeyLength,
                rendersOffscreen: rendersOffscreen
            ) { name, key in
                model.addCommandCodeKey(name: name, key: key)
            }
            hintText(SentinelSettingsCopy.commandCodeHint)
        }
    }

    private var refreshGroup: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
            labeledRefreshInterval(
                title: SentinelSettingsCopy.panelOpenRefreshTitle,
                hint: SentinelSettingsCopy.panelOpenRefreshHint,
                identifier: "settings-refresh-panel-open",
                menu: .panelOpen,
                selection: model.panelOpenRefreshInterval,
                options: SentinelPanelOpenRefreshInterval.allCases,
                onSelect: { model.setPanelOpenRefreshInterval($0) }
            )
            labeledRefreshInterval(
                title: SentinelSettingsCopy.panelClosedRefreshTitle,
                hint: SentinelSettingsCopy.panelClosedRefreshHint,
                identifier: "settings-refresh-panel-closed",
                menu: .panelClosed,
                selection: model.panelClosedRefreshInterval,
                options: SentinelPanelClosedRefreshInterval.allCases,
                onSelect: { model.setPanelClosedRefreshInterval($0) }
            )
            labeledRefreshInterval(
                title: SentinelSettingsCopy.balanceRecheckTitle,
                hint: SentinelSettingsCopy.balanceRecheckHint,
                identifier: "settings-refresh-balance-recheck",
                menu: .balanceRecheck,
                selection: model.balanceRecheckInterval,
                options: SentinelBalanceRecheckInterval.allCases,
                onSelect: { model.setBalanceRecheckInterval($0) }
            )
        }
    }

    private func labeledRefreshInterval<Value: SentinelRefreshIntervalOption>(
        title: String,
        hint: String,
        identifier: String,
        menu: SettingsDropdownID,
        selection: Value,
        options: [Value],
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Text(title)
                    .font(SentinelTheme.Fonts.rowTitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                Spacer(minLength: SentinelTheme.Spacing.sm)
                settingsDropdown(
                    identifier: identifier,
                    menu: menu,
                    title: selection.title,
                    options: options,
                    isSelected: { $0 == selection },
                    titleFor: { $0.title },
                    onSelect: onSelect
                )
            }
            hintText(hint)
        }
    }

    private var historyGroup: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Text(SentinelSettingsCopy.historyTitle)
                    .font(SentinelTheme.Fonts.rowTitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                ZStack {
                    Text(historyTextBinding.wrappedValue)
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, SentinelTheme.Spacing.section)
                        .allowsHitTesting(false)
                    if !rendersOffscreen {
                        TextField("", text: historyTextBinding)
                            .font(SentinelTheme.Fonts.rowTitle)
                            .foregroundStyle(Color.clear)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, SentinelTheme.Spacing.section)
                            .onSubmit(commitHistoryCount)
                    }
                }
                .frame(width: SentinelTheme.Metrics.settingsCountFieldWidth)
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
                .accessibilityLabel(SentinelSettingsCopy.historyTitle)
                .accessibilityIdentifier("settings-history-retain-count")
                Text(SentinelSettingsCopy.historyUnit)
                    .font(SentinelTheme.Fonts.rowTitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                Spacer(minLength: 0)
            }
            hintText(SentinelSettingsCopy.historyHint)
        }
    }

    private var startupGroup: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                labeledToggle(
                    title: SentinelSettingsCopy.loginItemTitle,
                    isOn: model.loginItemBinding,
                    identifier: "settings-login-item-toggle"
                )
                .disabled(!model.loginItem.isControlEnabled)
                if let hint = model.loginItem.trailingHint {
                    hintText(hint)
                        .accessibilityIdentifier("settings-login-item-hint")
                }
            }

            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                labeledToggle(
                    title: SentinelSettingsCopy.updateAutoInstallTitle,
                    isOn: model.updateAutoInstallBinding,
                    identifier: "settings-update-auto-install-toggle"
                )
                hintText(SentinelSettingsCopy.updateAutoInstallHint)
            }

            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                    Text(SentinelSettingsCopy.watchTitle)
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                    Spacer(minLength: SentinelTheme.Spacing.sm)
                    if !model.isWatchLocked {
                        Button(SentinelSettingsCopy.watchChoose) {
                            model.chooseWatchDirectory?()
                        }
                        .buttonStyle(
                            SentinelButtonStyle(
                                kind: .secondary,
                                compact: true
                            )
                        )
                        .accessibilityIdentifier("settings-watch-choose")
                    }
                }
                Text(model.watchPathDisplay)
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(
                        model.isWatchLocked
                            ? SentinelTheme.Colors.secondaryForeground
                            : SentinelTheme.Colors.foreground
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(model.isWatchLocked ? SentinelTheme.Metrics.disabledOpacity : 1)
                    .accessibilityIdentifier("settings-watch-directory")
                hintText(SentinelSettingsCopy.watchHint)
                if model.isWatchLocked {
                    hintText(SentinelSettingsCopy.watchLockedHint)
                        .accessibilityIdentifier("settings-watch-lock-hint")
                }
            }
        }
    }

    private func settingsDropdown<Value: Hashable>(
        identifier: String,
        menu: SettingsDropdownID,
        title: String,
        options: [Value],
        isSelected: @escaping (Value) -> Bool,
        titleFor: @escaping (Value) -> String,
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xs) {
            Button {
                if !rendersOffscreen {
                    expandedMenu = expandedMenu == menu ? nil : menu
                }
            } label: {
                HStack(spacing: SentinelTheme.Spacing.xs) {
                    Text(title)
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                }
                .padding(.horizontal, SentinelTheme.Spacing.md)
                .frame(minHeight: SentinelTheme.Metrics.smallControlHeight)
                .background(SentinelTheme.Colors.inset)
                .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.field))
                .overlay(
                    RoundedRectangle(cornerRadius: SentinelTheme.Radius.field)
                        .stroke(
                            SentinelTheme.Colors.border,
                            lineWidth: SentinelTheme.Metrics.borderWidth
                        )
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)

            if expandedMenu == menu {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button(titleFor(option)) {
                            onSelect(option)
                            expandedMenu = nil
                        }
                        .buttonStyle(.plain)
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .padding(.horizontal, SentinelTheme.Spacing.md)
                        .padding(.vertical, SentinelTheme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isSelected(option)
                                ? SentinelTheme.Colors.primarySoft
                                : Color.clear
                        )
                    }
                }
                .background(SentinelTheme.Colors.inset)
                .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.field))
                .overlay(
                    RoundedRectangle(cornerRadius: SentinelTheme.Radius.field)
                        .stroke(
                            SentinelTheme.Colors.border,
                            lineWidth: SentinelTheme.Metrics.borderWidth
                        )
                )
            }
        }
    }

    private func settingsGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.sm) {
            Text(title)
                .font(SentinelTheme.Fonts.section)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            VStack(alignment: .leading, spacing: SentinelTheme.Spacing.md) {
                content()
            }
            .padding(SentinelTheme.Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SentinelTheme.Colors.raised)
            .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel)
                    .stroke(
                        SentinelTheme.Colors.borderSoft,
                        lineWidth: SentinelTheme.Metrics.borderWidth
                    )
            )
        }
    }

    private func labeledToggle(
        title: String,
        isOn: Binding<Bool>,
        identifier: String,
        expandLabel: Bool = true
    ) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)
        }
        .toggleStyle(SentinelSwitchToggleStyle(expandLabel: expandLabel))
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private var versionFooter: some View {
        Text(versionLine)
            .font(SentinelTheme.Fonts.subtitle)
            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityIdentifier("settings-version-line")
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(SentinelTheme.Fonts.subtitle)
            .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var historyTextBinding: Binding<String> {
        Binding(
            get: { historyTextOverride ?? "\(model.historyRetainCount)" },
            set: { historyTextOverride = $0 }
        )
    }

    private func commitHistoryCount() {
        let trimmed = historyTextBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 1 else {
            historyTextOverride = nil
            return
        }
        model.setHistoryRetainCount(value)
        historyTextOverride = nil
    }
}

private struct StoreObservingProbeView: View {
    var store: SentinelStore
    var bodyCounter: SentinelViewBodyCounter

    var body: some View {
        let _ = bodyCounter.increment()
        Text("\(store.lines.count)")
            .accessibilityHidden(true)
    }
}

enum SettingsViewRedrawProbe {
    @MainActor
    static func storeObservingProbe(store: SentinelStore, counter: SentinelViewBodyCounter) -> some View {
        StoreObservingProbeView(store: store, bodyCounter: counter)
    }
}

/// 设置窗的素输入框。离屏渲染（截图 smoke）不吃 .plain TextField，
/// 用 Text 替身（限一行截断，长 key 不许把行高撑开）；真实窗口挂真输入框。
struct SettingsPlainTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?
    let identifier: String
    let rendersOffscreen: Bool
    var onSubmit: () -> Void = {}

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground.opacity(0.7))
                    .padding(.horizontal, SentinelTheme.Spacing.md)
                    .allowsHitTesting(false)
            } else {
                Text(text)
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, SentinelTheme.Spacing.md)
                    .allowsHitTesting(false)
            }
            if !rendersOffscreen {
                TextField("", text: $text)
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(Color.clear)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, SentinelTheme.Spacing.md)
                    .onSubmit(onSubmit)
            }
        }
        .frame(maxWidth: width, alignment: .leading)
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
        .accessibilityIdentifier(identifier)
    }
}

/// 设置窗的 key 输入行：名称 + key + 添加。草稿文本放在本地 @State，
/// 每次按键只重渲染这一行——之前草稿挂在模型的 @Published 上，一个键
/// 让整个设置窗重算一遍，字越多 Text 排版越贵，粘贴长 key 越打越卡。
struct SettingsKeyInputRow: View {
    let namePlaceholder: String
    let keyPlaceholder: String
    let addButtonTitle: String
    let identifierPrefix: String
    let minKeyLength: Int
    let rendersOffscreen: Bool
    let onAdd: (_ name: String, _ key: String) -> Void
    @State private var nameText = ""
    @State private var keyText = ""

    private var canAdd: Bool {
        keyText.trimmingCharacters(in: .whitespacesAndNewlines).count >= minKeyLength
    }

    var body: some View {
        HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
            SettingsPlainTextField(
                placeholder: namePlaceholder,
                text: $nameText,
                width: SentinelTheme.Metrics.settingsCountFieldWidth * 1.6,
                identifier: "\(identifierPrefix)-new-label",
                rendersOffscreen: rendersOffscreen,
                onSubmit: add
            )
            SettingsPlainTextField(
                placeholder: keyPlaceholder,
                text: $keyText,
                width: nil,
                identifier: "\(identifierPrefix)-new-key",
                rendersOffscreen: rendersOffscreen,
                onSubmit: add
            )
            Button(addButtonTitle, action: add)
                .buttonStyle(SentinelButtonStyle(kind: .primary, compact: true))
                .disabled(!canAdd)
                .accessibilityIdentifier("\(identifierPrefix)-add")
        }
    }

    private func add() {
        guard canAdd else {
            return
        }
        onAdd(nameText, keyText)
        nameText = ""
        keyText = ""
    }
}

@MainActor
final class SentinelSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SentinelSettingsWindowController()

    private var window: NSWindow?

    /// 默认高度：屏幕装得下就全显，装不下就给个带滚动的窗口。
    /// Falcon 2026-09-11 令：设置窗口不许比屏幕高，要能拉高矮、能滚动。
    static let defaultSettingsHeight: CGFloat = 920
    static let minSettingsHeight: CGFloat = 420

    func show(model: SentinelSettingsModel) {
        let hosting = NSHostingController(rootView: SentinelSettingsView(model: model))
        hosting.sizingOptions = []
        if let window {
            window.contentViewController = hosting
            present(window)
            return
        }
        let window = NSWindow(contentViewController: hosting)
        window.title = SentinelSettingsCopy.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let screenHeight = NSScreen.main?.visibleFrame.height ?? Self.defaultSettingsHeight
        let defaultHeight = min(Self.defaultSettingsHeight, screenHeight - 40)
        window.setContentSize(NSSize(width: SentinelTheme.Metrics.settingsWindowWidth, height: defaultHeight))
        window.contentMinSize = NSSize(width: SentinelTheme.Metrics.settingsWindowWidth, height: Self.minSettingsHeight)
        window.contentMaxSize = NSSize(width: SentinelTheme.Metrics.settingsWindowWidth, height: .greatestFiniteMagnitude)
        window.setFrameAutosaveName("SentinelSettingsWindow")
        self.window = window
        present(window)
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口复用，关掉不清引用。
    }

    private func clampToScreen(_ window: NSWindow) {
        // 保存的框架如果比当前屏幕还高，压回屏幕内。
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var frame = window.frame
        if frame.height > screen.height - 24 {
            frame.size.height = screen.height - 24
        }
        frame.origin.y = max(screen.minY, frame.origin.y)
        window.setFrame(frame, display: false)
    }

    private func present(_ window: NSWindow) {
        clampToScreen(window)
        window.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            window.makeFirstResponder(nil)
        }
    }
}

enum SettingsPNGRenderer {
    @MainActor
    static func render(fixture: SettingsPreviewFixture, to path: String) throws {
        try render(fixture: fixture, to: URL(fileURLWithPath: path))
    }

    @MainActor
    static func render(fixture: SettingsPreviewFixture, to url: URL) throws {
        _ = NSApplication.shared
        let model = SentinelSettingsModel.preview(fixture: fixture)
        let view = SentinelSettingsView(model: model, rendersOffscreen: true)
            .settingsContent
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: SentinelTheme.Metrics.settingsWindowWidth, height: nil)
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              !png.isEmpty
        else {
            throw SettingsPNGRenderError.emptyImage
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url)
    }
}

enum SettingsPNGRenderError: Error {
    case emptyImage
}
