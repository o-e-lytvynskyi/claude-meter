import AppKit

/// Claude's spark, tinted by how much of the 5-hour limit is used: one colour
/// per tenth, green through yellow to red. From 70 % — where the warnings
/// start — a dot joins it, so the state reads by shape and not only by hue.
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    /// Nil step: nothing read yet — a template image in the menu bar's own colour.
    static func image(step: Int?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let colour = step.map(tint) ?? .black
            let badge = (step ?? 0) >= Warnings.firstStep
            spark(in: rect, colour: colour, cutout: badge)
            if badge { dot(in: rect, colour: colour) }
            return true
        }
        image.isTemplate = step == nil
        return image
    }

    /// 0…10 → green (0 %) … red (100 %). Picked by hand rather than spread
    /// evenly by hue: an even spread spends half the steps on greens nobody
    /// can tell apart at 16 px. The yellows are a little dark so they hold up
    /// on a light menu bar.
    private static let tints: [(CGFloat, CGFloat, CGFloat)] = [
        (0x2F, 0xBF, 0x4A), (0x62, 0xC2, 0x34), (0x92, 0xC4, 0x24), (0xB9, 0xBF, 0x16), (0xD6, 0xB2, 0x12),
        (0xEB, 0x9F, 0x14), (0xF2, 0x87, 0x18), (0xF2, 0x6C, 0x1D), (0xEC, 0x52, 0x24), (0xE2, 0x3A, 0x2C),
        (0xCC, 0x22, 0x3A),
    ]

    static func tint(_ step: Int) -> NSColor {
        let (r, g, b) = tints[min(max(step, 0), 10)]
        return NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    /// Twelve rays of two lengths from a common centre, round-capped.
    private static func spark(in rect: NSRect, colour: NSColor, cutout: Bool) {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let rays = 12
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = 1.9
        for i in 0..<rays {
            let angle = CGFloat(i) / CGFloat(rays) * 2 * .pi + .pi / 2
            let length: CGFloat = i % 2 == 0 ? 7.6 : 5.6
            path.move(to: NSPoint(x: centre.x + cos(angle) * 1.2, y: centre.y + sin(angle) * 1.2))
            path.line(to: NSPoint(x: centre.x + cos(angle) * length, y: centre.y + sin(angle) * length))
        }
        NSGraphicsContext.saveGraphicsState()
        if cutout {
            // Clear a ring around the dot so the two shapes don't merge.
            let clip = NSBezierPath(rect: rect)
            clip.appendOval(in: dotRect(in: rect).insetBy(dx: -1.4, dy: -1.4))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        colour.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func dotRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 6.5, y: rect.minY, width: 6.5, height: 6.5)
    }

    private static func dot(in rect: NSRect, colour: NSColor) {
        colour.setFill()
        NSBezierPath(ovalIn: dotRect(in: rect)).fill()
    }
}
