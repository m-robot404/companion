import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let background = NSBezierPath(roundedRect: rect.insetBy(dx: 18, dy: 18), xRadius: 224, yRadius: 224)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.29, green: 0.20, blue: 0.52, alpha: 1),
    NSColor(calibratedRed: 0.48, green: 0.31, blue: 0.78, alpha: 1)
])!
gradient.draw(in: background, angle: -35)

let white = NSColor(calibratedWhite: 1, alpha: 0.94)
let soft = NSColor(calibratedWhite: 1, alpha: 0.68)
let segments: [(NSRect, CGFloat, NSColor)] = [
    (NSRect(x: 270, y: 690, width: 490, height: 112), 56, white),
    (NSRect(x: 270, y: 450, width: 112, height: 352), 56, white),
    (NSRect(x: 270, y: 210, width: 490, height: 112), 56, white),
    (NSRect(x: 648, y: 450, width: 112, height: 112), 56, soft)
]
for (frame, radius, color) in segments {
    color.setFill()
    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render Companion icon")
}
try png.write(to: URL(fileURLWithPath: output))
