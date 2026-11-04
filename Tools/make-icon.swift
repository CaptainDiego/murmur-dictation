// Renders a simple app icon so Murmur shows something recognisable in the
// permission lists and Finder. Run via: swift Tools/make-icon.swift <out.icns>
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Murmur-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(size)
    let inset = side * 0.08
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.22

    let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.20, alpha: 1),
            NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1),
        ])
    gradient?.draw(in: background, angle: -90)

    // The 🫦 emoji, drawn with Apple Color Emoji and centred on the tile.
    let emoji = "\u{1FAE6}" as NSString
    let font = NSFont(name: "AppleColorEmoji", size: side * 0.56)
        ?? NSFont.systemFont(ofSize: side * 0.56)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let glyphSize = emoji.size(withAttributes: attributes)
    emoji.draw(
        at: NSPoint(x: (side - glyphSize.width) / 2, y: (side - glyphSize.height) / 2),
        withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (size, name) in [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
] {
    guard let data = render(size: size) else { continue }
    try? data.write(to: iconset.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(task.terminationStatus)
