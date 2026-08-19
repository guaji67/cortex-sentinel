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
    @Published var watchPath: String
    @Published var isWatchLocked: Bool

    var applyLoginItem: ((Bool) -> Void)?
    var applyHistoryRetainCount: ((Int) -> Void)?
    var chooseWatchDirectory: (() -> Void)?

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
        self.watchPath = watchPath
        self.isWatchLocked = isWatchLocked
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

        return SentinelSettingsModel(
            defaults: defaults,
            loginItem: loginItem,
            historyRetainCount: StatusFileRetention.defaultCap,
            preferences: preferences,
            watchPath: "/Users/falcon/.cortex-sentinel/logs",
            isWatchLocked: fixture == .watchLocked
        )
    }
}

enum SettingsPreviewFixture: String {
    case `default`
    case masterOff = "master-off"
    case loginManaged = "login-managed"
    case watchLocked = "watch-locked"
}

struct SentinelSettingsView: View {
    @ObservedObject var model: SentinelSettingsModel
    var bodyCounter: SentinelViewBodyCounter?
    var rendersOffscreen = false
    var versionLine: String = SentinelAppVersion.displayLine()
    @State private var historyTextOverride: String?
    @State private var cadenceExpanded = false

    var body: some View {
        let _ = bodyCounter?.increment()
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.panel) {
            settingsGroup(title: SentinelSettingsCopy.notifyGroupTitle) {
                notifyGroup
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
                labeledToggle(
                    title: SentinelSettingsCopy.notifyChannelTitle,
                    isOn: model.channelAlertBinding,
                    identifier: "settings-notify-channel-toggle"
                )

                VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
                    HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                        Text(SentinelSettingsCopy.notifyCadenceTitle)
                            .font(SentinelTheme.Fonts.rowTitle)
                            .foregroundStyle(SentinelTheme.Colors.foreground)
                        Spacer(minLength: SentinelTheme.Spacing.sm)
                        cadenceControl
                    }
                    hintText(SentinelSettingsCopy.notifyCadenceHint)
                }
            }
            .padding(.leading, SentinelTheme.Metrics.settingsCategoryIndent)
            .disabled(!model.notifyMasterEnabled)
            .opacity(model.notifyMasterEnabled ? 1 : SentinelTheme.Metrics.disabledOpacity)
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
                HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                    Text(SentinelSettingsCopy.watchTitle)
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                    Spacer(minLength: SentinelTheme.Spacing.sm)
                    Button(SentinelSettingsCopy.watchChoose) {
                        model.chooseWatchDirectory?()
                    }
                    .buttonStyle(
                        SentinelButtonStyle(
                            kind: .secondary,
                            compact: true
                        )
                    )
                    .disabled(model.isWatchLocked)
                    .accessibilityIdentifier("settings-watch-choose")
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

    private var cadenceControl: some View {
        VStack(alignment: .trailing, spacing: SentinelTheme.Spacing.xs) {
            Button {
                if !rendersOffscreen {
                    cadenceExpanded.toggle()
                }
            } label: {
                HStack(spacing: SentinelTheme.Spacing.xs) {
                    Text(model.notifyCadence.title)
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
            .accessibilityIdentifier("settings-notify-cadence")

            if cadenceExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SentinelNotifyCadence.allCases, id: \.self) { cadence in
                        Button(cadence.title) {
                            model.setNotifyCadence(cadence)
                            cadenceExpanded = false
                        }
                        .buttonStyle(.plain)
                        .font(SentinelTheme.Fonts.rowTitle)
                        .foregroundStyle(SentinelTheme.Colors.foreground)
                        .padding(.horizontal, SentinelTheme.Spacing.md)
                        .padding(.vertical, SentinelTheme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            cadence == model.notifyCadence
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
    @ObservedObject var store: SentinelStore
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

@MainActor
final class SentinelSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SentinelSettingsWindowController()

    private var window: NSWindow?

    func show(model: SentinelSettingsModel) {
        let hosting = NSHostingController(rootView: SentinelSettingsView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        if let window {
            window.contentViewController = hosting
            sizeToFit(window, hosting: hosting)
            present(window)
            return
        }
        let window = NSWindow(contentViewController: hosting)
        window.title = SentinelSettingsCopy.windowTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        sizeToFit(window, hosting: hosting)
        self.window = window
        present(window)
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口复用，关掉不清引用。
    }

    private func sizeToFit(_ window: NSWindow, hosting: NSHostingController<SentinelSettingsView>) {
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.view.fittingSize
        if size.width < SentinelTheme.Metrics.settingsWindowWidth {
            size.width = SentinelTheme.Metrics.settingsWindowWidth
        }
        if size.height < 1 {
            size.height = hosting.view.intrinsicContentSize.height
        }
        window.setContentSize(
            NSSize(
                width: SentinelTheme.Metrics.settingsWindowWidth,
                height: max(size.height, 1)
            )
        )
    }

    private func present(_ window: NSWindow) {
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
            .frame(width: SentinelTheme.Metrics.settingsWindowWidth)
            .fixedSize(horizontal: true, vertical: true)
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
