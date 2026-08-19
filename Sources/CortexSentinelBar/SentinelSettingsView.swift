import AppKit
import SwiftUI

struct SentinelSettingsView: View {
    @ObservedObject var store: SentinelStore
    @State private var historyText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
            loginItemRow
            historyRow
            notifyRow
            watchRow
        }
        .padding(SentinelTheme.Spacing.sheet)
        .frame(width: SentinelTheme.Metrics.settingsWindowWidth, alignment: .leading)
        .background(SentinelTheme.Colors.canvas)
        .tint(SentinelTheme.Colors.primary)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("app-settings-window")
        .onAppear {
            historyText = "\(store.historyRetainCount)"
        }
        .onChange(of: store.historyRetainCount) { _, newValue in
            historyText = "\(newValue)"
        }
        .onDisappear(perform: commitHistoryCount)
    }

    private var loginItemRow: some View {
        let presentation = store.loginItemSettingsPresentation
        return HStack(alignment: .center, spacing: SentinelTheme.Spacing.md) {
            Text(SentinelSettingsCopy.loginItemTitle)
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            Spacer(minLength: SentinelTheme.Spacing.sm)
            Toggle("", isOn: loginItemBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!presentation.isControlEnabled)
                .accessibilityLabel(SentinelSettingsCopy.loginItemTitle)
                .accessibilityIdentifier("settings-login-item-toggle")
            if let hint = presentation.trailingHint {
                Text(hint)
                    .font(SentinelTheme.Fonts.subtitle)
                    .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("settings-login-item-hint")
            }
        }
    }

    private var historyRow: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Text(SentinelSettingsCopy.historyTitle)
                    .font(SentinelTheme.Fonts.rowTitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                TextField("", text: $historyText)
                    .textFieldStyle(SentinelTextFieldStyle())
                    .frame(width: SentinelTheme.Metrics.settingsCountFieldWidth)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitHistoryCount)
                    .accessibilityLabel(SentinelSettingsCopy.historyTitle)
                    .accessibilityIdentifier("settings-history-retain-count")
                Text(SentinelSettingsCopy.historyUnit)
                    .font(SentinelTheme.Fonts.rowTitle)
                    .foregroundStyle(SentinelTheme.Colors.foreground)
                Spacer(minLength: 0)
            }
            Text(SentinelSettingsCopy.historyHint)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notifyRow: some View {
        HStack(alignment: .center, spacing: SentinelTheme.Spacing.md) {
            Text(SentinelSettingsCopy.notifyTitle)
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            Spacer(minLength: SentinelTheme.Spacing.sm)
            Toggle("", isOn: notifyBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(SentinelSettingsCopy.notifyTitle)
                .accessibilityIdentifier("settings-notify-toggle")
        }
    }

    private var watchRow: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.xs) {
            Text(SentinelSettingsCopy.watchTitle)
                .font(SentinelTheme.Fonts.rowTitle)
                .foregroundStyle(SentinelTheme.Colors.foreground)
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.sm) {
                Text(store.paths.logsDirectory.path)
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(
                        store.isWatchDirectoryLocked
                            ? SentinelTheme.Colors.secondaryForeground
                            : SentinelTheme.Colors.foreground
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(store.isWatchDirectoryLocked ? SentinelTheme.Metrics.disabledOpacity : 1)
                    .accessibilityIdentifier("settings-watch-directory")
                Button(SentinelSettingsCopy.watchChoose) {
                    store.chooseWatchDirectory()
                }
                .buttonStyle(
                    SentinelButtonStyle(
                        kind: .secondary,
                        compact: true
                    )
                )
                .disabled(store.isWatchDirectoryLocked)
                .accessibilityIdentifier("settings-watch-choose")
                if store.isWatchDirectoryLocked {
                    Text(SentinelSettingsCopy.watchLockedHint)
                        .font(SentinelTheme.Fonts.subtitle)
                        .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("settings-watch-lock-hint")
                }
            }
            Text(SentinelSettingsCopy.watchHint)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { store.loginItemSettingsPresentation.isOn },
            set: { store.setLoginItemEnabled($0) }
        )
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { store.notifyOnTaskComplete },
            set: { store.setNotifyOnTaskComplete($0) }
        )
    }

    private func commitHistoryCount() {
        let trimmed = historyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 1 else {
            historyText = "\(store.historyRetainCount)"
            return
        }
        store.setHistoryRetainCount(value)
    }
}

@MainActor
final class SentinelSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SentinelSettingsWindowController()

    private var window: NSWindow?

    func show(store: SentinelStore) {
        let hosting = NSHostingController(rootView: SentinelSettingsView(store: store))
        if let window {
            window.contentViewController = hosting
            present(window)
            return
        }
        let window = NSWindow(contentViewController: hosting)
        window.title = SentinelSettingsCopy.windowTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(
            NSSize(
                width: SentinelTheme.Metrics.settingsWindowWidth,
                height: 280
            )
        )
        self.window = window
        present(window)
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口复用，关掉不清引用。
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
