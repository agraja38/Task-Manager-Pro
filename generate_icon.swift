import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetURL = root.appendingPathComponent("TaskManagerPro.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, size) in specs {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.76, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.33, green: 0.56, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.11, green: 0.21, blue: 0.42, alpha: 1)
    ])!
    gradient.draw(in: NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.02, dy: size * 0.02), xRadius: size * 0.2, yRadius: size * 0.2), angle: -60)

    let panelRect = NSRect(x: size * 0.11, y: size * 0.13, width: size * 0.78, height: size * 0.74)
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: panelRect, xRadius: size * 0.11, yRadius: size * 0.11).fill()

    let barWidth = size * 0.12
    let barSpacing = size * 0.06
    let baseX = size * 0.23
    let baseline = size * 0.28
    let heights = [0.20, 0.34, 0.50]
    let barColors = [
        NSColor(calibratedRed: 0.37, green: 0.96, blue: 0.72, alpha: 1),
        NSColor(calibratedRed: 0.99, green: 0.74, blue: 0.31, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.40, blue: 0.40, alpha: 1)
    ]

    for index in 0..<3 {
        let barRect = NSRect(
            x: baseX + CGFloat(index) * (barWidth + barSpacing),
            y: baseline,
            width: barWidth,
            height: size * CGFloat(heights[index])
        )
        barColors[index].setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    let pulse = NSBezierPath()
    pulse.lineWidth = max(2, size * 0.04)
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    pulse.move(to: NSPoint(x: size * 0.18, y: size * 0.60))
    pulse.line(to: NSPoint(x: size * 0.34, y: size * 0.60))
    pulse.line(to: NSPoint(x: size * 0.42, y: size * 0.76))
    pulse.line(to: NSPoint(x: size * 0.50, y: size * 0.46))
    pulse.line(to: NSPoint(x: size * 0.58, y: size * 0.67))
    pulse.line(to: NSPoint(x: size * 0.68, y: size * 0.53))
    pulse.line(to: NSPoint(x: size * 0.82, y: size * 0.53))
    NSColor.white.withAlphaComponent(0.96).setStroke()
    pulse.stroke()

    let badgeRect = NSRect(x: size * 0.64, y: size * 0.62, width: size * 0.16, height: size * 0.16)
    NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 0.32).setFill()
    NSBezierPath(ovalIn: badgeRect.offsetBy(dx: size * 0.02, dy: -size * 0.02)).fill()
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(ovalIn: badgeRect).fill()

    let center = NSPoint(x: badgeRect.midX, y: badgeRect.midY)
    let hand = NSBezierPath()
    hand.lineWidth = max(1.5, size * 0.018)
    hand.move(to: center)
    hand.line(to: NSPoint(x: center.x, y: center.y + size * 0.038))
    hand.move(to: center)
    hand.line(to: NSPoint(x: center.x + size * 0.03, y: center.y - size * 0.01))
    NSColor(calibratedRed: 0.19, green: 0.46, blue: 0.96, alpha: 1).setStroke()
    hand.stroke()

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else { continue }

    try png.write(to: iconsetURL.appendingPathComponent(name))
}
