// Draws the app icon: swift icon.swift <out.png> <size> [full|fg]
// Default is the Mac-style inset rounded tile; "full" fills the whole square (web),
// "fg" is only the battery on transparent (Android adaptive icon foreground).
import AppKit

let args = CommandLine.arguments
let out = args[1], size = CGFloat(Double(args[2])!), mode = args.count > 3 ? args[3] : ""
let full = mode == "full"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let s = size / 1024

let tile = full ? NSRect(x: 0, y: 0, width: size, height: size)
                : NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: full ? 0 : 185 * s, yRadius: full ? 0 : 185 * s)
if mode != "fg" {
  NSGradient(starting: NSColor(red: 0.10, green: 0.16, blue: 0.19, alpha: 1),
           ending: NSColor(red: 0.06, green: 0.08, blue: 0.09, alpha: 1))!.draw(in: tilePath, angle: -90)
}

// battery body, cap and a 70% charge
let white = NSColor(red: 0.91, green: 0.94, blue: 0.92, alpha: 1)
let green = NSColor(red: 0.18, green: 0.81, blue: 0.55, alpha: 1)
let body = NSRect(x: 352 * s, y: 250 * s, width: 320 * s, height: 500 * s)
let outline = NSBezierPath(roundedRect: body, xRadius: 56 * s, yRadius: 56 * s)
outline.lineWidth = 34 * s
white.setStroke()
outline.stroke()
white.setFill()
NSBezierPath(roundedRect: NSRect(x: 452 * s, y: 760 * s, width: 120 * s, height: 50 * s),
             xRadius: 16 * s, yRadius: 16 * s).fill()
green.setFill()
let inner = body.insetBy(dx: 44 * s, dy: 44 * s)
NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * 0.7),
             xRadius: 22 * s, yRadius: 22 * s).fill()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
