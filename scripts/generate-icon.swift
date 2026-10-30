import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/generate-icon.swift OUTPUT_DIRECTORY")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Could not create icon") }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        NSAffineTransform(transform: AffineTransform(scale: factor)).concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1, alpha: 1),
            ending: NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.88, alpha: 1))!
        gradient.draw(in: tile, angle: -90)
        let symbol = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 450, weight: .semibold))!
        let rect = NSRect(x: 235, y: 290, width: 554, height: 444)
        let tinted = NSImage(size: symbol.size, flipped: false) { imageRect in
            symbol.draw(in: imageRect)
            NSColor.white.setFill()
            imageRect.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let destination = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
        try data.write(to: destination)
    }
}
