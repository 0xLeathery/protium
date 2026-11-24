// Draws Protium's app icon and writes it as PNG: protium is hydrogen-1, one proton with one
// electron around it. The artwork is this file; macos/make-release.sh runs it for every size an
// .icns holds.
//
//   swift make-icon.swift <size in pixels> <output.png>
//
// Copyright (C) 2026 Ethan Hurst. GPL-3.0-or-later, see LICENSE.protium.

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]), size >= 16 else {
    FileHandle.standardError.write("usage: make-icon.swift <size> <output.png>\n".data(using: .utf8)!)
    exit(64)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let s = CGFloat(size) / 1024        // the drawing is laid out on a 1024 point canvas
ctx.scaleBy(x: s, y: s)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r / 255, g / 255, b / 255, a])!
}
func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: stops)!
}

// the plate: macOS's rounded square, 824 points inside the 1024 canvas, deep blue to near black
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.35))
ctx.addPath(platePath)
ctx.setFillColor(rgb(12, 16, 40))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(38, 52, 128), rgb(16, 20, 58), rgb(8, 9, 26)], [0, 0.55, 1]),
                       start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// a soft light behind the nucleus
ctx.drawRadialGradient(gradient([rgb(255, 130, 70, 0.34), rgb(255, 130, 70, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 400, options: [])

// the electron's orbit: one tilted ellipse, brighter where the electron is
let tilt: CGFloat = -32 * .pi / 180
let orbit = CGRect(x: -300, y: -128, width: 600, height: 256)
ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: tilt)
ctx.setLineWidth(size < 64 ? 44 : 26)       // small sizes need a heavier line to stay visible
ctx.addEllipse(in: orbit)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(120, 200, 255, 0.30), rgb(170, 225, 255, 0.95)], [0, 1]),
                       start: CGPoint(x: -300, y: 0), end: CGPoint(x: 300, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// the proton: a warm sphere
let nucleus = CGRect(x: 512 - 104, y: 512 - 104, width: 208, height: 208)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: rgb(255, 120, 60, 0.75))
ctx.setFillColor(rgb(255, 120, 60))
ctx.fillEllipse(in: nucleus)
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: nucleus)
ctx.clip()
ctx.drawRadialGradient(gradient([rgb(255, 236, 190), rgb(255, 150, 70), rgb(214, 62, 44)], [0, 0.45, 1]),
                       startCenter: CGPoint(x: 478, y: 552), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 112, options: [])
ctx.restoreGState()

// the electron, on the bright end of the orbit
let ex = 512 + 300 * cos(tilt), ey = 512 + 300 * sin(tilt)
let er: CGFloat = size < 64 ? 58 : 44
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 36, color: rgb(130, 215, 255, 0.9))
ctx.setFillColor(rgb(150, 222, 255))
ctx.fillEllipse(in: CGRect(x: ex - er, y: ey - er, width: 2 * er, height: 2 * er))
ctx.restoreGState()
ctx.setFillColor(rgb(236, 250, 255))
ctx.fillEllipse(in: CGRect(x: ex - er * 0.55, y: ey - er * 0.35, width: er, height: er))
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
