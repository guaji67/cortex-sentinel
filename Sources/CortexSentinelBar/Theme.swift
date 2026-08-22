import AppKit
import SwiftUI

enum SentinelTheme {
    enum AppKitColors {
        static let canvas = NSColor(hue: 222, saturation: 35, lightness: 7)
        static let panel = NSColor(hue: 222, saturation: 25, lightness: 10)
        static let raised = NSColor(hue: 220, saturation: 18, lightness: 13)
        static let inset = NSColor(hue: 222, saturation: 30, lightness: 8)
        static let foreground = NSColor(hue: 220, saturation: 15, lightness: 90)
        static let secondaryForeground = NSColor(hue: 220, saturation: 10, lightness: 60)
        static let primary = NSColor(hue: 217, saturation: 91, lightness: 60)
        static let success = NSColor(hex: 0x34D399)
        static let warning = NSColor(hex: 0xFB923C)
        static let danger = NSColor(hex: 0xF87171)
        static let info = NSColor(hex: 0x0EA5E9)

        static let statusBarText = NSColor.labelColor
        static let statusBarMuted = NSColor.secondaryLabelColor
    }

    enum Colors {
        static let canvas = Color(nsColor: AppKitColors.canvas)
        static let panel = Color(nsColor: AppKitColors.panel)
        static let raised = Color(nsColor: AppKitColors.raised)
        static let inset = Color(nsColor: AppKitColors.inset)
        static let foreground = Color(nsColor: AppKitColors.foreground)
        static let secondaryForeground = Color(nsColor: AppKitColors.secondaryForeground)
        static let primary = Color(nsColor: AppKitColors.primary)
        static let success = Color(nsColor: AppKitColors.success)
        static let warning = Color(nsColor: AppKitColors.warning)
        static let danger = Color(nsColor: AppKitColors.danger)
        static let info = Color(nsColor: AppKitColors.info)

        static let border = foreground.opacity(0.12)
        static let borderSoft = foreground.opacity(0.07)
        static let primarySoft = primary.opacity(0.15)
        static let primaryBorder = primary.opacity(0.38)
        static let successSoft = success.opacity(0.14)
        static let successBorder = success.opacity(0.34)
        static let warningSoft = warning.opacity(0.15)
        static let warningBorder = warning.opacity(0.42)
        static let dangerSoft = danger.opacity(0.14)
        static let dangerBorder = danger.opacity(0.42)
        static let infoSoft = info.opacity(0.14)
        static let onPrimary = Color.white
        static let shadow = Color.black.opacity(0.30)

        static let background = canvas
        static let card = panel
        static let ink = foreground
        static let inkSoft = secondaryForeground
        static let muted = secondaryForeground
        static let line = border
        static let lineSoft = borderSoft
        static let accent = primary
        static let accentDeep = success
        static let accentSoft = primarySoft
        static let amber = warning
        static let amberDeep = warning
        static let amberSoft = warningSoft
        static let onAccent = onPrimary
    }

    enum Spacing {
        static let hairline: CGFloat = 1
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let row: CGFloat = 8
        static let lg: CGFloat = 10
        static let section: CGFloat = 12
        static let panel: CGFloat = 14
        static let sheet: CGFloat = 16
    }

    enum Radius {
        static let control: CGFloat = 6
        static let field: CGFloat = 6
        static let row: CGFloat = 8
        static let panel: CGFloat = 8
    }

    enum Metrics {
        static let compactMenuWidth: CGFloat = 380
        static let menuWidth: CGFloat = compactMenuWidth
        static let menuHeight: CGFloat = 620
        static let historyBarHeight: CGFloat = 12
        static let historyBarGap: CGFloat = 1
        static let historyBarCornerRadius: CGFloat = 1
        static let balanceRowHeight: CGFloat = 26
        static let balanceRowSpacing: CGFloat = 2
        static let balanceDot: CGFloat = 8
        static let disclosureChevron: CGFloat = 12
        static let sheetWidth: CGFloat = 380
        static let settingsWindowWidth: CGFloat = 460
        static let settingsCountFieldWidth: CGFloat = 60
        static let settingsCategoryIndent: CGFloat = 20
        static let statusDot: CGFloat = 7
        static let headerDot: CGFloat = 10
        static let iconButton: CGFloat = 28
        static let lineControlHeight: CGFloat = 22
        static let lineControlIconWidth: CGFloat = 24
        static let lineControlFeedbackWidth: CGFloat = 48
        static let lineSettingsPopoverWidth: CGFloat = 232
        static let lineSettingsFieldWidth: CGFloat = 64
        static let smallControlHeight: CGFloat = 28
        static let controlHeight: CGFloat = 32
        static let stateColumnWidth: CGFloat = 88
        static let balanceColumnWidth: CGFloat = 96
        static let relayColumnWidth: CGFloat = 108
        static let relayActionWidth: CGFloat = 82
        static let toastMaxWidth: CGFloat = 170
        static let borderWidth: CGFloat = 1
        static let pressedScale: CGFloat = 0.98
        static let disabledOpacity: CGFloat = 0.45
    }

    enum StatusBar {
        static let height: CGFloat = 18
        static let horizontalPadding: CGFloat = 2
        static let dotDiameter: CGFloat = 4
        static let dotSpacing: CGFloat = 2
        static let dotTextSpacing: CGFloat = 5
        static let balanceSeparatorSpacing: CGFloat = 1
        static let textVerticalOffset: CGFloat = -1
    }

    enum Fonts {
        static let title = Font.system(size: 17, weight: .semibold)
        static let section = Font.system(size: 11, weight: .semibold)
        static let rowTitle = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 12.5)
        static let action = Font.system(size: 12, weight: .semibold)
        static let subtitle = Font.system(size: 11.5)
        static let metadata = Font.system(size: 10.5, design: .monospaced)
        static let badge = Font.system(size: 10.5, weight: .semibold)
        static let balance = Font.system(size: 14, weight: .semibold, design: .monospaced)
        static let serviceModel = Font.system(size: 12, weight: .semibold, design: .monospaced)
        static let serviceValue = Font.system(size: 11.5, weight: .semibold, design: .monospaced)
        static let axisLabel = Font.system(size: 9, design: .monospaced)
        static let balanceName = Font.system(size: 13, weight: .medium)
        static let balanceMeta = Font.system(size: 11)
        static let balanceAmount = Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let rowTime = Font.system(size: 10.5, design: .monospaced)

        static let statusBar = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }
}

enum SentinelButtonKind {
    case primary
    case secondary
    case ghost
    case danger
}

struct SentinelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let kind: SentinelButtonKind
    var compact = false
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SentinelTheme.Fonts.action)
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 0 : SentinelTheme.Spacing.lg)
            .frame(width: iconOnly ? SentinelTheme.Metrics.iconButton : nil)
            .frame(
                minHeight: compact
                    ? SentinelTheme.Metrics.smallControlHeight
                    : SentinelTheme.Metrics.controlHeight
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(border, lineWidth: SentinelTheme.Metrics.borderWidth)
            )
            .scaleEffect(configuration.isPressed ? SentinelTheme.Metrics.pressedScale : 1)
            .opacity(isEnabled ? 1 : SentinelTheme.Metrics.disabledOpacity)
    }

    private var cornerRadius: CGFloat {
        iconOnly ? SentinelTheme.Metrics.iconButton / 2 : SentinelTheme.Radius.control
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return SentinelTheme.Colors.onPrimary
        case .secondary:
            return SentinelTheme.Colors.foreground
        case .ghost:
            return SentinelTheme.Colors.secondaryForeground
        case .danger:
            return SentinelTheme.Colors.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            return SentinelTheme.Colors.primary
        case .secondary:
            return SentinelTheme.Colors.raised
        case .ghost, .danger:
            return .clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary:
            return SentinelTheme.Colors.primary
        case .secondary:
            return SentinelTheme.Colors.border
        case .ghost:
            return .clear
        case .danger:
            return SentinelTheme.Colors.dangerSoft
        }
    }
}

struct SentinelSwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    var expandLabel = true

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: SentinelTheme.Spacing.md) {
                configuration.label
                    .frame(maxWidth: expandLabel ? .infinity : nil, alignment: .leading)
                switchTrack(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : SentinelTheme.Metrics.disabledOpacity)
    }

    private func switchTrack(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? SentinelTheme.Colors.primary : SentinelTheme.Colors.raised)
            .overlay(
                Capsule()
                    .stroke(SentinelTheme.Colors.border, lineWidth: SentinelTheme.Metrics.borderWidth)
            )
            .frame(width: 36, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(SentinelTheme.Colors.onPrimary)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
    }
}

struct SentinelTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(SentinelTheme.Fonts.rowTitle)
            .foregroundStyle(SentinelTheme.Colors.foreground)
            .padding(.horizontal, SentinelTheme.Spacing.section)
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
    }
}

struct SentinelLineControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SentinelTheme.Fonts.badge)
            .foregroundStyle(SentinelTheme.Colors.foreground)
            .frame(width: width, height: SentinelTheme.Metrics.lineControlHeight)
            .background(SentinelTheme.Colors.raised)
            .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: SentinelTheme.Radius.control)
                    .stroke(
                        SentinelTheme.Colors.border,
                        lineWidth: SentinelTheme.Metrics.borderWidth
                    )
            )
            .scaleEffect(configuration.isPressed ? SentinelTheme.Metrics.pressedScale : 1)
            .opacity(isEnabled ? 1 : SentinelTheme.Metrics.disabledOpacity)
    }
}

struct SentinelRowModifier: ViewModifier {
    let tone: SentinelRowTone

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, SentinelTheme.Spacing.lg)
            .padding(.vertical, SentinelTheme.Spacing.row)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: SentinelTheme.Radius.row))
            .overlay(
                RoundedRectangle(cornerRadius: SentinelTheme.Radius.row)
                    .stroke(
                        border,
                        lineWidth: SentinelTheme.Metrics.borderWidth
                    )
            )
    }

    private var background: Color {
        switch tone {
        case .normal:
            return SentinelTheme.Colors.raised
        case .primary:
            return SentinelTheme.Colors.primarySoft
        case .success:
            return SentinelTheme.Colors.successSoft
        case .warning:
            return SentinelTheme.Colors.warningSoft
        case .danger:
            return SentinelTheme.Colors.dangerSoft
        }
    }

    private var border: Color {
        switch tone {
        case .normal:
            return SentinelTheme.Colors.borderSoft
        case .primary:
            return SentinelTheme.Colors.primaryBorder
        case .success:
            return SentinelTheme.Colors.successBorder
        case .warning:
            return SentinelTheme.Colors.warningBorder
        case .danger:
            return SentinelTheme.Colors.dangerBorder
        }
    }
}

enum SentinelRowTone: Equatable {
    case normal
    case primary
    case success
    case warning
    case danger
}

struct SentinelBadgeModifier: ViewModifier {
    let foreground: Color
    let background: Color

    func body(content: Content) -> some View {
        content
            .font(SentinelTheme.Fonts.badge)
            .foregroundStyle(foreground)
            .padding(.horizontal, SentinelTheme.Spacing.sm)
            .padding(.vertical, SentinelTheme.Spacing.xxs)
            .background(background)
            .clipShape(Capsule())
    }
}

extension View {
    func sentinelRow(tone: SentinelRowTone = .normal) -> some View {
        modifier(SentinelRowModifier(tone: tone))
    }

    func sentinelBadge(foreground: Color, background: Color) -> some View {
        modifier(SentinelBadgeModifier(foreground: foreground, background: background))
    }
}

extension ChannelHealth {
    var color: Color {
        switch self {
        case .alive:
            return SentinelTheme.Colors.success
        case .degraded:
            return SentinelTheme.Colors.warning
        case .unknown:
            return SentinelTheme.Colors.secondaryForeground
        }
    }
}

extension SentinelSeverity {
    var color: Color {
        switch self {
        case .green:
            return SentinelTheme.Colors.success
        case .amber:
            return SentinelTheme.Colors.warning
        case .red:
            return SentinelTheme.Colors.danger
        case .gray:
            return SentinelTheme.Colors.secondaryForeground
        }
    }

    var softColor: Color {
        switch self {
        case .green:
            return SentinelTheme.Colors.successSoft
        case .amber:
            return SentinelTheme.Colors.warningSoft
        case .red:
            return SentinelTheme.Colors.dangerSoft
        case .gray:
            return SentinelTheme.Colors.inset
        }
    }
}

extension InputHistoryTone {
    var color: Color {
        switch self {
        case .ok:
            return SentinelTheme.Colors.success
        case .slow:
            return SentinelTheme.Colors.warning
        case .fail:
            return SentinelTheme.Colors.danger
        case .missing:
            return SentinelTheme.Colors.secondaryForeground.opacity(0.25)
        }
    }

    /// 状态栏圆点用（AppKit）：与面板 SwiftUI 色义一致，高延迟=橙。
    var appKitColor: NSColor {
        switch self {
        case .ok:
            return SentinelTheme.AppKitColors.success
        case .slow:
            return SentinelTheme.AppKitColors.warning
        case .fail:
            return SentinelTheme.AppKitColors.danger
        case .missing:
            return SentinelTheme.AppKitColors.statusBarMuted
        }
    }
}

extension InputProbeState {
    var color: Color {
        switch self {
        case .connected:
            return SentinelTheme.Colors.success
        case .disconnected:
            return SentinelTheme.Colors.danger
        case .stale, .unknown:
            return SentinelTheme.Colors.secondaryForeground
        }
    }

    var softColor: Color {
        switch self {
        case .connected:
            return SentinelTheme.Colors.successSoft
        case .disconnected:
            return SentinelTheme.Colors.dangerSoft
        case .stale, .unknown:
            return SentinelTheme.Colors.inset
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    convenience init(
        hue: CGFloat,
        saturation: CGFloat,
        lightness: CGFloat,
        alpha: CGFloat = 1
    ) {
        let normalizedHue = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 360
        let normalizedSaturation = saturation / 100
        let normalizedLightness = lightness / 100

        guard normalizedSaturation > 0 else {
            self.init(
                srgbRed: normalizedLightness,
                green: normalizedLightness,
                blue: normalizedLightness,
                alpha: alpha
            )
            return
        }

        let upper = normalizedLightness < 0.5
            ? normalizedLightness * (1 + normalizedSaturation)
            : normalizedLightness + normalizedSaturation - normalizedLightness * normalizedSaturation
        let lower = 2 * normalizedLightness - upper

        func component(_ offset: CGFloat) -> CGFloat {
            var value = normalizedHue + offset
            if value < 0 {
                value += 1
            } else if value > 1 {
                value -= 1
            }
            if value < 1 / 6 {
                return lower + (upper - lower) * 6 * value
            }
            if value < 1 / 2 {
                return upper
            }
            if value < 2 / 3 {
                return lower + (upper - lower) * (2 / 3 - value) * 6
            }
            return lower
        }

        self.init(
            srgbRed: component(1 / 3),
            green: component(0),
            blue: component(-1 / 3),
            alpha: alpha
        )
    }
}
