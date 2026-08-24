import AppKit

/// 状态栏那张图的输入快照。三个面合成一个非 Optional 值，
/// Observation 才能稳定追上 packagingProgress 从 nil 到 running 的跳变。
struct StatusBarRenderState: Equatable {
    var inputStatus: InputStatusSnapshot = .empty
    var aio: AIOSnapshot = .unconfigured
    var packagingProgress: PackagingProgressSnapshot?
}

enum SentinelStatusBarRenderer {
    static func image(
        probes: [InputStatusDisplayProbe],
        balances: [StatusBarBalanceItem],
        packaging: PackagingProgressSnapshot? = nil
    ) -> NSImage {
        let displayedProbes = Array(probes.prefix(InputStatusConstants.monitoredModels.count))
        let displayedBalances = normalizedBalances(balances)
        let segments = statusBarSegments(displayedBalances, packaging: packaging)
        let textWidth = segments.reduce(CGFloat.zero) { partial, segment in
            partial + textSize(segment.text).width
        }
        let dotWidth = SentinelTheme.StatusBar.dotDiameter
        let width = ceil(
            SentinelTheme.StatusBar.horizontalPadding
                + dotWidth
                + SentinelTheme.StatusBar.dotTextSpacing
                + textWidth
                + SentinelTheme.StatusBar.horizontalPadding
        )
        let size = NSSize(width: width, height: SentinelTheme.StatusBar.height)
        let image = NSImage(size: size, flipped: false) { bounds in
            drawProbes(displayedProbes, in: bounds)
            drawBalances(
                segments,
                startX: SentinelTheme.StatusBar.horizontalPadding
                    + dotWidth
                    + SentinelTheme.StatusBar.dotTextSpacing,
                in: bounds
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawProbes(
        _ probes: [InputStatusDisplayProbe],
        in bounds: NSRect
    ) {
        let dotDiameter = SentinelTheme.StatusBar.dotDiameter
        let dotSpacing = SentinelTheme.StatusBar.dotSpacing
        let count = InputStatusConstants.monitoredModels.count
        let stackHeight = CGFloat(count) * dotDiameter + CGFloat(count - 1) * dotSpacing
        let startY = floor((bounds.height - stackHeight) / 2)

        for index in 0..<count {
            let dotColor: NSColor
            if index < probes.count {
                dotColor = InputStatusPresentation.indicatorTone(for: probes[index]).appKitColor
            } else {
                dotColor = SentinelTheme.AppKitColors.statusBarMuted
            }
            dotColor.setFill()
            let rect = NSRect(
                x: SentinelTheme.StatusBar.horizontalPadding,
                y: startY + CGFloat(count - index - 1) * (dotDiameter + dotSpacing),
                width: dotDiameter,
                height: dotDiameter
            )
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    private static func drawBalances(
        _ segments: [BalanceSegment],
        startX: CGFloat,
        in bounds: NSRect
    ) {
        var x = startX
        let font = SentinelTheme.Fonts.statusBar
        let height = ceil(font.boundingRectForFont.height)
        let y = floor((bounds.height - height) / 2) + SentinelTheme.StatusBar.textVerticalOffset

        for segment in segments {
            let size = textSize(segment.text)
            (segment.text as NSString).draw(
                in: NSRect(x: x, y: y, width: ceil(size.width), height: height),
                withAttributes: [
                    .font: font,
                    .foregroundColor: segment.color,
                ]
            )
            x += size.width
        }
    }

    private static func normalizedBalances(
        _ balances: [StatusBarBalanceItem]
    ) -> [StatusBarBalanceItem] {
        var result = Array(balances.prefix(2))
        while result.count < 2 {
            result.append(
                StatusBarBalanceItem(
                    providerID: Int64.min + Int64(result.count),
                    providerName: "暂无密钥",
                    text: "--",
                    isLowBalance: false
                )
            )
        }
        return result
    }

    private static func statusBarSegments(
        _ balances: [StatusBarBalanceItem],
        packaging: PackagingProgressSnapshot?
    ) -> [BalanceSegment] {
        var segments: [BalanceSegment] = []
        if packaging?.isActive == true {
            segments.append(
                BalanceSegment(
                    text: "打包",
                    color: SentinelTheme.AppKitColors.warning
                )
            )
            segments.append(
                BalanceSegment(
                    text: "·",
                    color: SentinelTheme.AppKitColors.statusBarMuted
                )
            )
        }
        return segments + balanceSegments(balances)
    }

    private static func balanceSegments(
        _ balances: [StatusBarBalanceItem]
    ) -> [BalanceSegment] {
        var segments: [BalanceSegment] = []
        for (index, balance) in balances.enumerated() {
            if index > 0 {
                segments.append(
                    BalanceSegment(
                        text: "·",
                        color: SentinelTheme.AppKitColors.statusBarMuted
                    )
                )
            }
            segments.append(
                BalanceSegment(
                    text: balance.text,
                    color: balance.isLowBalance
                        ? SentinelTheme.AppKitColors.warning
                        : SentinelTheme.AppKitColors.statusBarText
                )
            )
        }
        return segments
    }

    private static func textSize(_ text: String) -> NSSize {
        (text as NSString).size(
            withAttributes: [.font: SentinelTheme.Fonts.statusBar]
        )
    }
}

private struct BalanceSegment {
    let text: String
    let color: NSColor
}
