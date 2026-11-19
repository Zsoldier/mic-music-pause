import AppKit

// Render at every icon size so Finder never needs to upscale a small bitmap.
func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
        xRadius: 185, yRadius: 185
    )
    guard let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.19, green: 0.36, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.49, green: 0.22, blue: 0.83, alpha: 1),
    ]) else {
        throw CocoaError(.coderInvalidValue)
    }
    gradient.draw(in: tile, angle: -45)

    NSColor.white.setFill()
    let beam = NSBezierPath()
    beam.move(to: NSPoint(x: 386, y: 644))
    beam.line(to: NSPoint(x: 708, y: 708))
    beam.line(to: NSPoint(x: 708, y: 620))
    beam.line(to: NSPoint(x: 386, y: 556))
    beam.close()
    beam.fill()
    NSBezierPath(roundedRect: NSRect(x: 346, y: 365, width: 44, height: 278),
                 xRadius: 20, yRadius: 20).fill()
    NSBezierPath(roundedRect: NSRect(x: 664, y: 423, width: 44, height: 278),
                 xRadius: 20, yRadius: 20).fill()
    NSBezierPath(ovalIn: NSRect(x: 232, y: 294, width: 158, height: 116)).fill()
    NSBezierPath(ovalIn: NSRect(x: 550, y: 352, width: 158, height: 116)).fill()

    NSColor(srgbRed: 0.10, green: 0.15, blue: 0.34, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 578, y: 162, width: 270, height: 270)).fill()
    NSColor(srgbRed: 0.42, green: 0.95, blue: 0.81, alpha: 1).setFill()
    for x in [CGFloat(653), CGFloat(731)] {
        NSBezierPath(roundedRect: NSRect(x: x, y: 228, width: 42, height: 138),
                     xRadius: 12, yRadius: 12).fill()
    }

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/generate-app-icon.swift <output.iconset>\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try renderIcon(pixels: size * scale).write(
            to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        )
    }
}
