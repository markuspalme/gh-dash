// Draws the app icon and writes it as a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Background: the standard macOS icon shape (824pt rounded square on a 1024pt canvas).
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(platePath)
ctx.setFillColor(color(0.2, 0.17, 0.6))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [color(0.50, 0.42, 1.0), color(0.27, 0.22, 0.80), color(0.13, 0.11, 0.42)] as CFArray,
    locations: [0, 0.5, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Soft highlight from the top edge.
let highlight = CGGradient(
    colorsSpace: space,
    colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// Glyph: a pull request whose target node is a green "checks passed" badge.
let white = color(1, 1, 1)
let leftX: CGFloat = 372, rightX: CGFloat = 652
let topY: CGFloat = 700, bottomY: CGFloat = 324
let stroke: CGFloat = 46

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0, 0, 0.2, 0.3))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)

ctx.setStrokeColor(white)
ctx.setFillColor(white)
ctx.setLineWidth(stroke)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Source branch: two rings joined by a line.
let ring: CGFloat = 56
ctx.strokeEllipse(in: CGRect(x: leftX - ring, y: topY - ring, width: ring * 2, height: ring * 2))
ctx.strokeEllipse(in: CGRect(x: leftX - ring, y: bottomY - ring, width: ring * 2, height: ring * 2))
ctx.move(to: CGPoint(x: leftX, y: topY - ring))
ctx.addLine(to: CGPoint(x: leftX, y: bottomY + ring))
ctx.strokePath()

// Target branch: up from the badge, curving left into an arrowhead.
ctx.move(to: CGPoint(x: rightX, y: bottomY + 60))
ctx.addLine(to: CGPoint(x: rightX, y: topY - 90))
ctx.addArc(tangent1End: CGPoint(x: rightX, y: topY), tangent2End: CGPoint(x: rightX - 90, y: topY), radius: 90)
ctx.addLine(to: CGPoint(x: rightX - 96, y: topY))
ctx.strokePath()
ctx.move(to: CGPoint(x: rightX - 168, y: topY))
ctx.addLine(to: CGPoint(x: rightX - 88, y: topY + 62))
ctx.addLine(to: CGPoint(x: rightX - 88, y: topY - 62))
ctx.closePath()
ctx.setLineWidth(14)
ctx.drawPath(using: .fillStroke)

// Badge.
let badge: CGFloat = 104
let badgeRect = CGRect(x: rightX - badge, y: bottomY - badge, width: badge * 2, height: badge * 2)
ctx.fillEllipse(in: badgeRect)
ctx.endTransparencyLayer()
ctx.restoreGState()

ctx.saveGState()
let inner = badgeRect.insetBy(dx: 16, dy: 16)
ctx.addEllipse(in: inner)
ctx.clip()
let green = CGGradient(
    colorsSpace: space,
    colors: [color(0.30, 0.86, 0.45), color(0.13, 0.66, 0.31)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(green, start: CGPoint(x: inner.midX, y: inner.maxY), end: CGPoint(x: inner.midX, y: inner.minY), options: [])
ctx.restoreGState()

ctx.setStrokeColor(white)
ctx.setLineWidth(30)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: rightX - 44, y: bottomY + 2))
ctx.addLine(to: CGPoint(x: rightX - 12, y: bottomY - 32))
ctx.addLine(to: CGPoint(x: rightX + 46, y: bottomY + 36))
ctx.strokePath()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output.path)") }
