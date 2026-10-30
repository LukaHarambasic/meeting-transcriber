#!/usr/bin/env swift
// Generates still images of the menu bar icon for documentation.
// Usage: swift scripts/generate_menu_bar_icons.swift
// Output: docs/menu-bar-*.png

import AppKit

// MARK: - Drawing Constants (mirrored from MenuBarIcon.swift)

let barWidth: CGFloat = 2.2
let barSpacing: CGFloat = 3.6
let barCount = 5
let barHeights: [CGFloat] = [0.25, 0.50, 0.75, 0.45, 0.30]
let dotSize: CGFloat = 6.0
let dotMargin: CGFloat = 0.5
let dotGap: CGFloat = 1.0

// MARK: - Drawing Functions

func circle(at center: NSPoint, size: CGFloat) -> NSRect {
    NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
}

// Mirrors `MenuBarIcon.drawBars`.
func drawBars(in rect: NSRect) {
    let barsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * (barSpacing - barWidth)
    let left = (rect.width - barsWidth) / 2
    for i in 0 ..< barCount {
        let barH = rect.height * barHeights[i]
        let barRect = NSRect(
            x: left + CGFloat(i) * barSpacing,
            y: rect.height / 2 - barH / 2,
            width: barWidth,
            height: barH,
        )
        NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
}

// Mirrors `MenuBarIcon.drawRecordingDot`. The app clears the ring to
// transparent; here it is painted with the page background instead, so the
// image has no hole that a dark README theme would show through.
func drawRecordingDot(in rect: NSRect) {
    let center = NSPoint(x: rect.maxX - dotSize / 2 - dotMargin, y: rect.maxY - dotSize / 2 - dotMargin)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: circle(at: center, size: dotSize + 2 * dotGap)).fill()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: circle(at: center, size: dotSize)).fill()
}

// Mirrors `MenuBarIcon.drawErrorDot`: the icon's only coloured mark.
func drawErrorDot(in rect: NSRect) {
    let center = NSPoint(x: rect.maxX - dotSize / 2 - dotMargin, y: rect.minY + dotSize / 2 + dotMargin)
    NSColor.systemRed.setFill()
    NSBezierPath(ovalIn: circle(at: center, size: dotSize)).fill()
}

// MARK: - Rendering

let nativeSize: CGFloat = 18
let pixelSize = 100

func writePNG(name: String, draw: (NSRect) -> Void) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0,
    )! // swiftlint:disable:this force_unwrapping

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: CGFloat(pixelSize), height: CGFloat(pixelSize)).fill()

    // Draw at native 18pt, output at 100px.
    // swiftlint:disable:next legacy_objc_type
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixelSize) / nativeSize)
    transform.concat()
    NSColor.black.setFill()
    draw(NSRect(x: 0, y: 0, width: nativeSize, height: nativeSize))
    NSGraphicsContext.restoreGraphicsState()

    let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let url = scriptDir.deletingLastPathComponent().appendingPathComponent("docs/\(name)")
    try! rep.representation(using: .png, properties: [:])!.write(to: url) // swiftlint:disable:this force_try force_unwrapping
    print("  Generated: docs/\(name)")
}

// MARK: - Generate

print("Generating menu bar icon images...")

writePNG(name: "menu-bar-idle.png") { drawBars(in: $0) }

writePNG(name: "menu-bar-recording.png") { rect in
    drawBars(in: rect)
    drawRecordingDot(in: rect)
}

writePNG(name: "menu-bar-error.png") { rect in
    drawBars(in: rect)
    drawErrorDot(in: rect)
}

writePNG(name: "menu-bar-error-recording.png") { rect in
    drawBars(in: rect)
    drawRecordingDot(in: rect)
    drawErrorDot(in: rect)
}

print("Done!")
