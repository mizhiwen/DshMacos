#!/usr/bin/swift
import AppKit
import Foundation

guard CommandLine.arguments.count >= 4,
      let pixelSize = Int(CommandLine.arguments[3]),
      pixelSize > 0 else {
    fputs("usage: render-icon.swift <svg> <png> <size>\n", stderr)
    exit(1)
}

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pngURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: svgURL) else {
    fputs("无法加载图标 SVG：\(svgURL.path)\n", stderr)
    exit(1)
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("无法创建图标画布\n", stderr)
    exit(1)
}

rep.size = NSSize(width: pixelSize, height: pixelSize)
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("无法创建图标绘图上下文\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
let scale = CGFloat(pixelSize) / 1024
// Match Chrome / WeChat: 818pt squircle inset on a 1024 canvas.
let squircleRect = NSRect(
    x: 103 * scale,
    y: 103 * scale,
    width: 818 * scale,
    height: 818 * scale
)
let squircle = macOSIconSquircle(in: squircleRect, exponent: 5.18)

context.cgContext.setFillColor(NSColor.clear.cgColor)
context.cgContext.fill(canvas)

let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.26)
shadow.shadowOffset = NSSize(width: 0, height: -16 * scale)
shadow.shadowBlurRadius = 22 * scale
shadow.set()
NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
squircle.fill()

context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
squircle.addClip()
source.draw(
    in: canvas,
    from: .zero,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("无法编码图标 PNG\n", stderr)
    exit(1)
}

do {
    try png.write(to: pngURL)
} catch {
    fputs("无法写入图标 PNG：\(error.localizedDescription)\n", stderr)
    exit(1)
}

func macOSIconSquircle(in rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 240
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    for index in 0 ... steps {
        let theta = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let cosT = cos(theta)
        let sinT = sin(theta)
        let x = cx + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = cy + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
        let point = NSPoint(x: x, y: y)
        if index == 0 {
            path.move(to: point)
        } else {
            path.line(to: point)
        }
    }
    path.close()
    return path
}
