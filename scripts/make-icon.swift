// Draws the app icon: a ruled notebook page with one line circled in red, and a record
// badge. Run: swift Scripts/make-icon.swift Resources/AppIcon-1024.png
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, alpha: a)
}

// Work top-left, y down, like a drawing.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// 1. The tile: Apple's grid puts an 824 pt squircle in the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x1B2340))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x34457E), rgb(0x1A2244)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
// soft light from the top left
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 260, y: 200), startRadius: 0, endCenter: CGPoint(x: 260, y: 200), endRadius: 620, options: [])

// 2. The page, a little tilted.
ctx.saveGState()
ctx.translateBy(x: 512, y: 520)
ctx.rotate(by: -5 * .pi / 180)
let page = CGRect(x: -250, y: -300, width: 500, height: 600)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: rgb(0x000000, 0.45))
ctx.addPath(CGPath(roundedRect: page, cornerWidth: 38, cornerHeight: 38, transform: nil))
ctx.setFillColor(rgb(0xFBF8F1))
ctx.fillPath()
ctx.restoreGState()
// binding strip
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: page, cornerWidth: 38, cornerHeight: 38, transform: nil))
ctx.clip()
ctx.setFillColor(rgb(0xE9E3D6))
ctx.fill(CGRect(x: page.minX, y: page.minY, width: 70, height: page.height))
ctx.restoreGState()
// rings
for i in 0..<5 {
    let y = page.minY + 80 + Double(i) * 110
    ctx.setFillColor(rgb(0x2A3358))
    ctx.fillEllipse(in: CGRect(x: page.minX + 22, y: y - 13, width: 26, height: 26))
}
// ruled lines of "text"
ctx.setLineCap(.round)
let lines: [(Double, Double)] = [(0.78, 150), (0.62, 225), (0.84, 300), (0.55, 375), (0.72, 450)]
for (frac, y) in lines {
    let x0 = page.minX + 110
    let w = (page.width - 150) * frac
    ctx.setStrokeColor(rgb(0x9AA3BC))
    ctx.setLineWidth(22)
    ctx.move(to: CGPoint(x: x0, y: page.minY + y))
    ctx.addLine(to: CGPoint(x: x0 + w, y: page.minY + y))
    ctx.strokePath()
}
// 3. The red circle around line three, drawn like a quick pen mark: one loop that overshoots.
let cx = page.minX + 110 + (page.width - 150) * 0.84 / 2, cy = page.minY + 300
ctx.setStrokeColor(rgb(0xFF3B30))
ctx.setLineWidth(20)
ctx.setLineJoin(.round)
let loop = CGMutablePath()
let rx = 205.0, ry = 62.0
let start = -0.35 * Double.pi
for step in 0...120 {
    let t = start + Double(step) / 120 * 2.12 * Double.pi
    let wobble = 1 + 0.06 * sin(3 * t)
    let p = CGPoint(x: cx + rx * wobble * cos(t), y: cy + ry * wobble * sin(t) - 10 * Double(step) / 120)
    if step == 0 { loop.move(to: p) } else { loop.addLine(to: p) }
}
ctx.saveGState()
ctx.rotate(by: 0)
ctx.addPath(loop)
ctx.strokePath()
ctx.restoreGState()
ctx.restoreGState()

// 4. The record badge, bottom right.
let badge = CGPoint(x: 742, y: 756)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x000000, 0.45))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: badge.x - 96, y: badge.y - 96, width: 192, height: 192))
ctx.restoreGState()
let red = CGGradient(colorsSpace: space, colors: [rgb(0xFF5A4E), rgb(0xE0261B)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: badge.x - 74, y: badge.y - 74, width: 148, height: 148))
ctx.clip()
ctx.drawLinearGradient(red, start: CGPoint(x: badge.x, y: badge.y - 74), end: CGPoint(x: badge.x, y: badge.y + 74), options: [])
ctx.restoreGState()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
