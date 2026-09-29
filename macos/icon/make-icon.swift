// Draws the app icon: a spotlight beam landing on the current word of a
// script, in the prompter's own colors (public/style.css).
//
//   swift macos/icon/make-icon.swift out.png     # 1024x1024 PNG
//
// macos/icon/make-icns.sh turns that into Followspot.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let ctx = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size))  // draw top-down
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let fg = rgb(0xf5f5f5)
let read = rgb(0x6b6b6b)
let now = rgb(0xffd84d)

// Body on Apple's icon grid: 824 pt square, 100 pt margin, continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow, as macOS icons have.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x0b0b0c))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Background: near-black with a faint lift toward the top.
let bg = CGGradient(
  colorsSpace: nil, colors: [rgb(0x1c1c1f), rgb(0x050505)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// The word the beam lands on, and the script lines around it.
let lineH: CGFloat = 58
let gap: CGFloat = 44
let top: CGFloat = 470
let rows: [[(CGFloat, CGColor)]] = [
  [(170, read), (120, read), (210, read)],
  [(150, fg), (230, now), (130, fg)],
  [(200, fg), (140, fg), (150, fg)],
]
let wordGap: CGFloat = 34
var target = CGRect.zero
var bars: [(CGRect, CGColor)] = []
for (i, row) in rows.enumerated() {
  let width = row.map(\.0).reduce(0, +) + wordGap * CGFloat(row.count - 1)
  var x = 512 - width / 2
  let y = top + CGFloat(i) * (lineH + gap)
  for (w, color) in row {
    let rect = CGRect(x: x, y: y, width: w, height: lineH)
    bars.append((rect, color))
    if color === now { target = rect }
    x += w + wordGap
  }
}

// Beam: a cone from a lamp above the frame to the current word. Stacked
// faint cones, narrow to wide, give it a soft edge without a blur filter.
let lamp = CGPoint(x: target.midX - 40, y: 40)
let landing = target.midY
for i in 0..<10 {
  let spread = 20 + CGFloat(i) * 9
  let beam = CGMutablePath()
  beam.move(to: CGPoint(x: lamp.x - 6 - CGFloat(i), y: lamp.y))
  beam.addLine(to: CGPoint(x: lamp.x + 6 + CGFloat(i), y: lamp.y))
  beam.addLine(to: CGPoint(x: target.maxX + spread, y: landing))
  beam.addLine(to: CGPoint(x: target.minX - spread, y: landing))
  beam.closeSubpath()
  ctx.saveGState()
  ctx.addPath(beam)
  ctx.clip()
  let gradient = CGGradient(
    colorsSpace: nil, colors: [rgb(0xfff3c4, 0.004), rgb(0xffe27a, 0.045)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(gradient, start: lamp, end: CGPoint(x: target.midX, y: landing), options: [])
  ctx.restoreGState()
}

// Pool of light where the beam lands.
let pool = CGGradient(
  colorsSpace: nil, colors: [rgb(0xffd84d, 0.42), rgb(0xffd84d, 0)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.translateBy(x: target.midX, y: target.midY)
ctx.scaleBy(x: 1.9, y: 0.75)
ctx.drawRadialGradient(
  pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 190, options: [])
ctx.restoreGState()

// Words as rounded bars; the lit one glows.
for (rect, color) in bars {
  ctx.saveGState()
  if color === now { ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xffd84d, 0.9)) }
  ctx.addPath(CGPath(roundedRect: rect, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
  ctx.setFillColor(color)
  ctx.fillPath()
  ctx.restoreGState()
}

// Thin inner highlight on the edge, so it holds up on a dark Dock.
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(0xffffff, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(out.path)") }
print("Wrote \(out.path)")
