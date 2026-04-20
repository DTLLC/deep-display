import AppKit

enum DeepDisplayIcon {
    @MainActor
    static func makeAppIcon(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let background = NSBezierPath(roundedRect: bounds, xRadius: size * 0.22, yRadius: size * 0.22)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.26, alpha: 1),
            NSColor(calibratedRed: 0.09, green: 0.35, blue: 0.70, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.66, blue: 0.84, alpha: 1)
        ])?.draw(in: background, angle: 45)

        let glow = NSBezierPath(ovalIn: bounds.insetBy(dx: size * 0.12, dy: size * 0.12))
        NSColor.white.withAlphaComponent(0.08).setFill()
        glow.fill()

        let displayFrame = NSBezierPath(
            roundedRect: bounds.insetBy(dx: size * 0.14, dy: size * 0.18),
            xRadius: size * 0.08,
            yRadius: size * 0.08
        )
        NSColor.white.withAlphaComponent(0.92).setStroke()
        displayFrame.lineWidth = size * 0.03
        displayFrame.stroke()

        let innerBounds = bounds.insetBy(dx: size * 0.20, dy: size * 0.24)
        let innerDisplay = NSBezierPath(
            roundedRect: innerBounds,
            xRadius: size * 0.05,
            yRadius: size * 0.05
        )
        NSGradient(colors: [
            NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.20, alpha: 1),
            NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.35, alpha: 1)
        ])?.draw(in: innerDisplay, angle: -90)

        let splitX = innerBounds.midX
        let leftPanel = NSBezierPath(
            rect: NSRect(
                x: innerBounds.minX,
                y: innerBounds.minY,
                width: innerBounds.width * 0.52,
                height: innerBounds.height
            )
        )
        NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.98, alpha: 0.28).setFill()
        leftPanel.fill()

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: splitX, y: innerBounds.minY + size * 0.02))
        divider.line(to: NSPoint(x: splitX, y: innerBounds.maxY - size * 0.02))
        NSColor.white.withAlphaComponent(0.3).setStroke()
        divider.lineWidth = size * 0.012
        divider.stroke()

        let pixelBlock = NSBezierPath(
            roundedRect: NSRect(
                x: innerBounds.minX + size * 0.06,
                y: innerBounds.midY - size * 0.08,
                width: size * 0.18,
                height: size * 0.16
            ),
            xRadius: size * 0.03,
            yRadius: size * 0.03
        )
        NSColor.white.withAlphaComponent(0.95).setFill()
        pixelBlock.fill()

        let grid = NSBezierPath()
        for offset in stride(from: CGFloat(0), through: size * 0.18, by: size * 0.06) {
            grid.move(
                to: NSPoint(
                    x: innerBounds.minX + size * 0.06 + offset,
                    y: innerBounds.midY - size * 0.08
                )
            )
            grid.line(
                to: NSPoint(
                    x: innerBounds.minX + size * 0.06 + offset,
                    y: innerBounds.midY + size * 0.08
                )
            )
            grid.move(
                to: NSPoint(
                    x: innerBounds.minX + size * 0.06,
                    y: innerBounds.midY - size * 0.08 + offset
                )
            )
            grid.line(
                to: NSPoint(
                    x: innerBounds.minX + size * 0.24,
                    y: innerBounds.midY - size * 0.08 + offset
                )
            )
        }
        NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.52, alpha: 0.35).setStroke()
        grid.lineWidth = size * 0.004
        grid.stroke()

        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: splitX + size * 0.03, y: innerBounds.midY - size * 0.06))
        wave.curve(
            to: NSPoint(x: innerBounds.maxX - size * 0.04, y: innerBounds.midY + size * 0.07),
            controlPoint1: NSPoint(x: splitX + size * 0.10, y: innerBounds.midY + size * 0.13),
            controlPoint2: NSPoint(x: innerBounds.maxX - size * 0.15, y: innerBounds.midY - size * 0.12)
        )
        NSColor.white.withAlphaComponent(0.92).setStroke()
        wave.lineWidth = size * 0.026
        wave.lineCapStyle = .round
        wave.stroke()

        let stand = NSBezierPath(
            roundedRect: NSRect(
                x: size * 0.38,
                y: size * 0.08,
                width: size * 0.24,
                height: size * 0.05
            ),
            xRadius: size * 0.02,
            yRadius: size * 0.02
        )
        NSColor.white.withAlphaComponent(0.88).setFill()
        stand.fill()

        image.isTemplate = false
        return image
    }
}

