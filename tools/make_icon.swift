#!/usr/bin/env swift
// Generates the 1024×1024 app-icon source.
// Usage:  swift tools/make_icon.swift <out.png>
//
// The icon is generated at install time into a temp dir and thrown away
// afterwards — nothing image-shaped is kept in the repo.

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-source.png"
let side: CGFloat = 1024

guard let ctx = CGContext(
    data: nil, width: Int(side), height: Int(side),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Cannot create CGContext") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

// ── Squircle background: warm near-black ──────────────────────────────────
let squircle = NSBezierPath(
    roundedRect: NSRect(x: 32, y: 32, width: side - 64, height: side - 64),
    xRadius: 220, yRadius: 220
)
squircle.addClip()

guard let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.17, green: 0.13, blue: 0.12, alpha: 1),
        CGColor(red: 0.07, green: 0.05, blue: 0.05, alpha: 1)
    ] as CFArray,
    locations: [0, 1]
) else { fatalError("gradient") }

ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: side / 2, y: side),
                       end:   CGPoint(x: side / 2, y: 0),
                       options: [])

// ── Gauge arc: green → red, three quarters of a turn ──────────────────────
let centre = CGPoint(x: side / 2, y: side / 2)
let stops: [(CGFloat, NSColor)] = [
    (0.0, NSColor(srgbRed: 0.18, green: 0.75, blue: 0.29, alpha: 1)),
    (0.5, NSColor(srgbRed: 0.92, green: 0.62, blue: 0.08, alpha: 1)),
    (1.0, NSColor(srgbRed: 0.89, green: 0.23, blue: 0.17, alpha: 1)),
]
func colour(at t: CGFloat) -> NSColor {
    let i = t < 0.5 ? 0 : 1
    let local = (t - stops[i].0) / (stops[i + 1].0 - stops[i].0)
    return stops[i].1.blended(withFraction: local, of: stops[i + 1].1) ?? stops[i].1
}
let segments = 120
let start: CGFloat = 225, sweep: CGFloat = 270
for s in 0..<segments {
    let t0 = CGFloat(s) / CGFloat(segments), t1 = CGFloat(s + 1) / CGFloat(segments)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: centre, radius: 360,
                  startAngle: start - sweep * t0, endAngle: start - sweep * t1 - 0.3, clockwise: true)
    arc.lineWidth = 56
    arc.lineCapStyle = s == 0 || s == segments - 1 ? .round : .butt
    colour(at: t0).setStroke()
    arc.stroke()
}

// ── Claude's spark in the middle ──────────────────────────────────────────
let spark = NSBezierPath()
spark.lineCapStyle = .round
spark.lineWidth = 50
for i in 0..<12 {
    let angle = CGFloat(i) / 12 * 2 * .pi + .pi / 2
    let length: CGFloat = i % 2 == 0 ? 230 : 170
    spark.move(to: CGPoint(x: centre.x + cos(angle) * 36, y: centre.y + sin(angle) * 36))
    spark.line(to: CGPoint(x: centre.x + cos(angle) * length, y: centre.y + sin(angle) * length))
}
NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setStroke()
spark.stroke()

NSGraphicsContext.restoreGraphicsState()

// ── Export ────────────────────────────────────────────────────────────────
guard
    let cgImage = ctx.makeImage(),
    let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
else { fatalError("PNG conversion failed") }

try! png.write(to: URL(fileURLWithPath: outPath))
print("   ✓ icon source → \(outPath)")
