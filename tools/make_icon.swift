// Renders the 1024×1024 MacPulse app icon (full-bleed; macOS applies the squircle mask).
import AppKit
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(colors: [NSColor(red: 0.13, green: 0.16, blue: 0.32, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.12, alpha: 1)])!.draw(in: rect, angle: -90)
// Soft glow behind the glyph
NSGradient(colors: [NSColor(red: 0.35, green: 0.55, blue: 1, alpha: 0.55), .clear])!.draw(fromCenter: NSPoint(x: 512, y: 470), radius: 0, toCenter: NSPoint(x: 512, y: 470), radius: 460, options: [])
let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold).applying(.init(paletteColors: [.white]))
let glyph = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
glyph.draw(in: NSRect(x: 512 - glyph.size.width / 2, y: 512 - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
