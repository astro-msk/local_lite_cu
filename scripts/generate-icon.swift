#!/usr/bin/env swift
import AppKit
import Foundation

// Extend Lite CU's existing SwiftUI brand mark into a native macOS app icon.
// Run: swift scripts/generate-icon.swift [--preview /absolute/path/icon.png]
// The complete iconset is generated in a temporary directory and packed as ICNS.

enum IconError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = root.appendingPathComponent("Resources/AppIcon.icns")
let arguments = Array(CommandLine.arguments.dropFirst())
let preview: URL?
if arguments.isEmpty {
    preview = nil
} else if arguments.count == 2, arguments[0] == "--preview" {
    preview = URL(fileURLWithPath: arguments[1])
} else {
    throw IconError.message("Usage: swift scripts/generate-icon.swift [--preview /absolute/path/icon.png]")
}

let graphite = NSColor(srgbRed: 0.055, green: 0.065, blue: 0.065, alpha: 1)
let lime = NSColor(srgbRed: 0.80, green: 0.93, blue: 0.43, alpha: 1)
guard let baseSymbol = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "Lite CU"),
      let symbol = baseSymbol.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 512, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [graphite]))
      ) else {
    throw IconError.message("The cursorarrow.motionlines SF Symbol is unavailable.")
}

func iconPNG(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.message("Could not create a \(pixels)-pixel image.")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    // The transparent margin keeps the icon aligned with other macOS app tiles.
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    graphite.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    lime.setFill()
    tile.fill()
    let sheen = NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: NSColor.white.withAlphaComponent(0))
    sheen?.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.28).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    // Preserve the same symbol and weight as the app's sidebar logo, with
    // optical centering and generous spacing for small Dock representations.
    let available = NSSize(width: 536, height: 536)
    let fit = min(available.width / symbol.size.width, available.height / symbol.size.height)
    let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
    let rect = NSRect(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2 + 4, width: size.width, height: size.height)
    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

    context.flushGraphics()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.message("Could not encode a \(pixels)-pixel PNG.")
    }
    return data
}

let temporary = fileManager.temporaryDirectory.appendingPathComponent("litecu-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporary) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(points)x\(points)\(suffix).png"
        try iconPNG(pixels: pixels).write(to: iconset.appendingPathComponent(filename))
    }
}

try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", destination.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw IconError.message("iconutil failed with status \(process.terminationStatus).")
}
if let preview { try iconPNG(pixels: 1024).write(to: preview) }
print("Generated \(destination.path) with 16–1024 px representations.")
if let preview { print("Preview: \(preview.path)") }
