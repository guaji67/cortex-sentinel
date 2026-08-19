import SwiftUI

private enum ProbeButtonState: Equatable {
    case idle
    case notified
    case failed(String)
}

struct SentinelLineControls: View {
    let line: LineStatus
    let engine: LineEngine
    let logsDirectory: URL
    let onShowSettings: (LineStatus) -> Void

    @State private var probeState: ProbeButtonState = .idle

    init(
        line: LineStatus,
        engine: LineEngine? = nil,
        logsDirectory: URL,
        onShowSettings: @escaping (LineStatus) -> Void
    ) {
        self.line = line
        self.engine = engine ?? line.engine
        self.logsDirectory = logsDirectory
        self.onShowSettings = onShowSettings
    }

    @ViewBuilder
    var body: some View {
        if !engine.isCursorGrok {
            HStack(spacing: SentinelTheme.Spacing.xs) {
                if line.state == .waitingRelay {
                    Button(action: requestProbe) {
                        probeButtonLabel
                    }
                    .buttonStyle(
                        SentinelLineControlButtonStyle(
                            width: SentinelTheme.Metrics.lineControlFeedbackWidth
                        )
                    )
                    .help(probeHelpText)
                    .accessibilityLabel(probeAccessibilityLabel)
                }

                Button {
                    onShowSettings(line)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(
                    SentinelLineControlButtonStyle(
                        width: SentinelTheme.Metrics.lineControlIconWidth
                    )
                )
                .help("本线设置")
                .accessibilityLabel("设置 \(line.slug)")
            }
        }
    }

    @ViewBuilder
    private var probeButtonLabel: some View {
        switch probeState {
        case .idle:
            Image(systemName: "play.fill")
        case .notified:
            Text("已通知")
        case .failed:
            Text("失败")
        }
    }

    private var probeHelpText: String {
        switch probeState {
        case .idle:
            return "立即重探并继续"
        case .notified:
            return "已通知守护立即重探"
        case let .failed(message):
            return message
        }
    }

    private var probeAccessibilityLabel: String {
        switch probeState {
        case .idle:
            return "立即继续 \(line.slug)"
        case .notified:
            return "已通知 \(line.slug)"
        case .failed:
            return "通知失败 \(line.slug)"
        }
    }

    private func requestProbe() {
        do {
            try SentinelControlFile.requestProbe(
                slug: line.slug,
                logsDirectory: logsDirectory
            )
            probeState = .notified
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                guard probeState == .notified else {
                    return
                }
                probeState = .idle
            }
        } catch {
            probeState = .failed("通知失败：\(error.localizedDescription)")
        }
    }
}

struct SentinelLineSettingsPanel: View {
    let line: LineStatus
    let logsDirectory: URL
    let onClose: () -> Void

    @State private var maxRestarts: Int
    @State private var escalateAfter: Int
    @State private var settingsMessage: String?
    @State private var settingsFailed = false

    init(line: LineStatus, logsDirectory: URL, onClose: @escaping () -> Void) {
        self.line = line
        self.logsDirectory = logsDirectory
        self.onClose = onClose
        _maxRestarts = State(initialValue: line.maxRestartsOverride ?? 6)
        _escalateAfter = State(initialValue: line.escalateAfterFailures ?? 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SentinelTheme.Spacing.section) {
            HStack(spacing: SentinelTheme.Spacing.md) {
                Text("本线设置")
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
                .accessibilityLabel("关闭本线设置")
            }

            Text(line.slug)
                .font(SentinelTheme.Fonts.metadata)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
                .lineLimit(1)
                .truncationMode(.middle)

            numberField("最多重试", value: $maxRestarts, range: "0-100")
            numberField("失败几次上报", value: $escalateAfter, range: "1-100")

            if let settingsMessage {
                Text(settingsMessage)
                    .font(SentinelTheme.Fonts.metadata)
                    .foregroundStyle(
                        settingsFailed
                            ? SentinelTheme.Colors.danger
                            : SentinelTheme.Colors.success
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("保存", action: saveSettings)
                .buttonStyle(SentinelButtonStyle(kind: .primary, compact: true))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(SentinelTheme.Spacing.sheet)
        .frame(width: SentinelTheme.Metrics.lineSettingsPopoverWidth)
        .background(SentinelTheme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: SentinelTheme.Radius.panel)
                .stroke(
                    SentinelTheme.Colors.border,
                    lineWidth: SentinelTheme.Metrics.borderWidth
                )
        )
        .accessibilityIdentifier("line-settings-panel-\(line.slug)")
        .onAppear(perform: loadSettings)
    }

    private func numberField(
        _ label: String,
        value: Binding<Int>,
        range: String
    ) -> some View {
        HStack(spacing: SentinelTheme.Spacing.md) {
            Text(label)
                .font(SentinelTheme.Fonts.subtitle)
                .foregroundStyle(SentinelTheme.Colors.secondaryForeground)
            Spacer(minLength: 0)
            TextField(range, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(SentinelTheme.Fonts.metadata)
                .frame(width: SentinelTheme.Metrics.lineSettingsFieldWidth)
                .accessibilityLabel(label)
        }
    }

    private func loadSettings() {
        let pending = try? SentinelControlFile.readSettings(
            slug: line.slug,
            logsDirectory: logsDirectory
        )
        maxRestarts = pending?.maxRestartsOverride ?? line.maxRestartsOverride ?? 6
        escalateAfter = pending?.escalateAfterFailures ?? line.escalateAfterFailures ?? 3
        settingsMessage = nil
        settingsFailed = false
    }

    private func saveSettings() {
        do {
            try SentinelControlFile.updateSettings(
                slug: line.slug,
                maxRestartsOverride: maxRestarts,
                escalateAfterFailures: escalateAfter,
                logsDirectory: logsDirectory
            )
            settingsMessage = "已保存"
            settingsFailed = false
        } catch {
            settingsMessage = error.localizedDescription
            settingsFailed = true
        }
    }
}
