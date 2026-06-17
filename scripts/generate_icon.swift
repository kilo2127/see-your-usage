#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let iconset = assets.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icns = assets.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct IconSize {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String {
        scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    }
}

let sizes = [
    IconSize(points: 16, scale: 1),
    IconSize(points: 16, scale: 2),
    IconSize(points: 32, scale: 1),
    IconSize(points: 32, scale: 2),
    IconSize(points: 128, scale: 1),
    IconSize(points: 128, scale: 2),
    IconSize(points: 256, scale: 1),
    IconSize(points: 256, scale: 2),
    IconSize(points: 512, scale: 1),
    IconSize(points: 512, scale: 2)
]

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon(size: Int) throws -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGraphicsContext.saveGraphicsState()

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    NSGraphicsContext.current?.cgContext.clear(canvas)

    let unit = CGFloat(size) / 1024
    let base = canvas.insetBy(dx: 76 * unit, dy: 76 * unit)
    let basePath = rounded(base, 214 * unit)

    NSGraphicsContext.current?.cgContext.setShadow(
        offset: CGSize(width: 0, height: -24 * unit),
        blur: 44 * unit,
        color: NSColor.black.withAlphaComponent(0.30).cgColor
    )
    let baseGradient = NSGradient(colors: [
        color(0x2a3034),
        color(0x111315)
    ])!
    baseGradient.draw(in: basePath, angle: -90)

    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    basePath.lineWidth = 4 * unit
    basePath.stroke()

    let gloss = rounded(base.insetBy(dx: 20 * unit, dy: 20 * unit), 192 * unit)
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.25),
        NSColor.white.withAlphaComponent(0.02)
    ])!.draw(in: gloss, angle: -90)

    let card = CGRect(x: 160 * unit, y: 228 * unit, width: 704 * unit, height: 568 * unit)
    let cardPath = rounded(card, 96 * unit)
    NSColor.white.withAlphaComponent(0.16).setFill()
    cardPath.fill()
    NSColor.white.withAlphaComponent(0.25).setStroke()
    cardPath.lineWidth = 2.5 * unit
    cardPath.stroke()

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 118 * unit, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92)
    ]
    NSString(string: "5h").draw(at: CGPoint(x: 230 * unit, y: 582 * unit), withAttributes: titleAttrs)
    NSString(string: "7d").draw(at: CGPoint(x: 230 * unit, y: 394 * unit), withAttributes: titleAttrs)

    func drawDots(y: CGFloat, lit: Int, accent: NSColor) {
        let count = 8
        let dot = 48 * unit
        let gap = 14 * unit
        let startX = 404 * unit
        for index in 0..<count {
            let rect = CGRect(
                x: startX + CGFloat(index) * (dot + gap),
                y: y,
                width: dot,
                height: dot
            )
            let path = NSBezierPath(ovalIn: rect)
            (index < lit ? accent : NSColor.white.withAlphaComponent(0.18)).setFill()
            path.fill()
        }
    }

    drawDots(y: 626 * unit, lit: 7, accent: color(0x34c759))
    drawDots(y: 438 * unit, lit: 5, accent: color(0xffcc00))

    let small = CGRect(x: 650 * unit, y: 244 * unit, width: 118 * unit, height: 118 * unit)
    let pulse = NSBezierPath(ovalIn: small)
    color(0xff3b30, alpha: 0.92).setFill()
    pulse.fill()
    NSColor.white.withAlphaComponent(0.38).setStroke()
    pulse.lineWidth = 3 * unit
    pulse.stroke()

    NSGraphicsContext.restoreGraphicsState()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    return data
}

for size in sizes {
    let data = try drawIcon(size: size.pixels)
    try data.write(to: iconset.appendingPathComponent(size.filename))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw NSError(domain: "Icon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print(icns.path)
