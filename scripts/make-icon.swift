#!/usr/bin/env swift
// Renders the app icon and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// The icon is the app itself: the floating prompt bar (a capsule with the blue send
// button) and a reply rising above it, on a blue field in the macOS rounded-square shape.
// Drawn with Core Graphics only; SF Symbols aren't allowed in app icons.
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024

/// Top-left based rectangle, converted to Core Graphics' bottom-left origin.
func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: canvas - y - height, width: width, height: height)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func draw(in context: CGContext) {
    // Body: the macOS icon grid's 824pt rounded square, centred, leaving room for the shadow.
    let body = box(100, 100, 824, 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    context.addPath(bodyPath)
    context.setFillColor(color(0x2A55E0))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    context.drawLinearGradient(gradient([color(0x4C8DFF), color(0x2B4BD8), color(0x1E2A94)]),
                               start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    // Soft light from the top left, as on glass.
    context.drawRadialGradient(gradient([color(0xFFFFFF, 0.30), color(0xFFFFFF, 0)]),
                               startCenter: CGPoint(x: body.minX + 220, y: body.maxY - 160), startRadius: 0,
                               endCenter: CGPoint(x: body.minX + 220, y: body.maxY - 160), endRadius: 620, options: [])

    // The reply: a frosted card above the bar.
    let card = box(232, 262, 560, 330)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 64, cornerHeight: 64, transform: nil)
    context.addPath(cardPath)
    context.setFillColor(color(0xFFFFFF, 0.20))
    context.fillPath()
    context.addPath(cardPath)
    context.setStrokeColor(color(0xFFFFFF, 0.42))
    context.setLineWidth(3)
    context.strokePath()
    for (index, width) in [CGFloat(380), 448, 260].enumerated() {
        let line = box(292, 336 + CGFloat(index) * 72, width, 30)
        context.addPath(CGPath(roundedRect: line, cornerWidth: 15, cornerHeight: 15, transform: nil))
        context.setFillColor(color(0xFFFFFF, index == 2 ? 0.55 : 0.78))
        context.fillPath()
    }

    // The prompt bar: a white glass capsule.
    let bar = box(182, 652, 660, 152)
    let barPath = CGPath(roundedRect: bar, cornerWidth: 76, cornerHeight: 76, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x0B1450, 0.45))
    context.addPath(barPath)
    context.setFillColor(color(0xFFFFFF, 0.96))
    context.fillPath()
    context.restoreGState()
    context.addPath(barPath)
    context.clip()
    context.drawLinearGradient(gradient([color(0xFFFFFF, 0), color(0xDCE6FF, 0.55)]),
                               start: CGPoint(x: bar.midX, y: bar.maxY), end: CGPoint(x: bar.midX, y: bar.minY), options: [])
    context.resetClip()
    context.addPath(bodyPath)
    context.clip()

    // Typed text and the caret.
    let text = box(252, 714, 230, 28)
    context.addPath(CGPath(roundedRect: text, cornerWidth: 14, cornerHeight: 14, transform: nil))
    context.setFillColor(color(0xB9C4E4))
    context.fillPath()
    context.setFillColor(color(0x2F6BFF))
    context.fill(box(500, 696, 8, 64))

    // The send button.
    let send = box(696, 670, 116, 116)
    context.saveGState()
    context.addEllipse(in: send)
    context.clip()
    context.drawLinearGradient(gradient([color(0x5A9BFF), color(0x1F55E6)]),
                               start: CGPoint(x: send.midX, y: send.maxY), end: CGPoint(x: send.midX, y: send.minY), options: [])
    context.restoreGState()
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(15)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let center = CGPoint(x: send.midX, y: send.midY)
    context.move(to: CGPoint(x: center.x, y: center.y - 30))
    context.addLine(to: CGPoint(x: center.x, y: center.y + 30))
    context.move(to: CGPoint(x: center.x - 26, y: center.y + 6))
    context.addLine(to: CGPoint(x: center.x, y: center.y + 32))
    context.addLine(to: CGPoint(x: center.x + 26, y: center.y + 6))
    context.strokePath()
    context.restoreGState()

    // A thin bright rim on the body.
    context.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, 0.22))
    context.setLineWidth(3)
    context.strokePath()
}

func png(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(in: context)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let output = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
