// 生成 Cortex 哨兵 App 图标底图（1024x1024 PNG）。
// 用法：swift scripts/GenerateIcon.swift <输出.png>
// 母题与面板一致：AIO 暗色圆角方底 + 绿/橙/红三状态点 + 对应行条。
import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// 底：macOS 圆角方（约 80% 画布），AIO 暗色纵向渐变 + 弱描边
let plateRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let plate = NSBezierPath(roundedRect: plateRect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(
    starting: NSColor(srgbRed: 0x13 / 255, green: 0x1A / 255, blue: 0x26 / 255, alpha: 1),
    ending: NSColor(srgbRed: 0x0B / 255, green: 0x0F / 255, blue: 0x17 / 255, alpha: 1)
)
gradient?.draw(in: plate, angle: -90)
NSColor(white: 1, alpha: 0.08).setStroke()
plate.lineWidth = 6
plate.stroke()

// 三状态行：状态点 + 圆头行条（同面板行观感），从上到下 绿/橙/红
let dotDiameter: CGFloat = 130
let rowGap: CGFloat = 64
let barWidth: CGFloat = 330
let barHeight: CGFloat = 56
let dotBarGap: CGFloat = 56
let groupWidth = dotDiameter + dotBarGap + barWidth
let groupHeight = 3 * dotDiameter + 2 * rowGap
let originX = (canvas - groupWidth) / 2
let originY = (canvas - groupHeight) / 2

let rowColors = [
    NSColor(srgbRed: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255, alpha: 1),
    NSColor(srgbRed: 0xFB / 255, green: 0x92 / 255, blue: 0x3C / 255, alpha: 1),
    NSColor(srgbRed: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255, alpha: 1),
]

for (index, color) in rowColors.enumerated() {
    let rowY = originY + CGFloat(index) * (dotDiameter + rowGap)
    color.setFill()
    NSBezierPath(
        ovalIn: NSRect(x: originX, y: rowY, width: dotDiameter, height: dotDiameter)
    ).fill()

    color.withAlphaComponent(0.28).setFill()
    NSBezierPath(
        roundedRect: NSRect(
            x: originX + dotDiameter + dotBarGap,
            y: rowY + (dotDiameter - barHeight) / 2,
            width: barWidth,
            height: barHeight
        ),
        xRadius: barHeight / 2,
        yRadius: barHeight / 2
    ).fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("渲染失败\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("written \(outputPath)")
