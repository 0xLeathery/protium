// Draws Protium's app icon and writes it as PNG: a letter P whose bowl is an electron's orbit,
// with the proton at its centre (protium is hydrogen-1, one proton and one electron). The artwork is this file; macos/make-release.sh runs it for every size an
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

// the plate: macOS's rounded square, 824 points inside the 1024 canvas, white to a cool grey
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.30))
ctx.addPath(platePath)
ctx.setFillColor(rgb(240, 241, 246))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(255, 255, 255), rgb(228, 230, 240)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()
ctx.addPath(platePath)
ctx.setStrokeColor(rgb(20, 23, 43, 0.10))
ctx.setLineWidth(6)
ctx.strokePath()

// the P, in ink: a stem and a ring, heavier at small sizes so that it stays a letter
let ink = rgb(20, 23, 43)
let weight: CGFloat = size < 64 ? 96 : 76
let bowl = CGPoint(x: 556, y: 578)
let stem = CGRect(x: 356 - weight / 2, y: 254, width: weight, height: 500)
ctx.addPath(CGPath(roundedRect: stem, cornerWidth: weight / 2, cornerHeight: weight / 2, transform: nil))
ctx.setFillColor(ink)
ctx.fillPath()
ctx.setStrokeColor(ink)
ctx.setLineWidth(weight)
ctx.strokeEllipse(in: CGRect(x: bowl.x - 176, y: bowl.y - 176, width: 352, height: 352))

// the proton at the bowl's centre, the one warm thing on the plate
let pr: CGFloat = size < 64 ? 70 : 58
let proton = CGRect(x: bowl.x - pr, y: bowl.y - pr, width: 2 * pr, height: 2 * pr)
ctx.saveGState()
ctx.addEllipse(in: proton)
ctx.clip()
ctx.drawRadialGradient(gradient([rgb(255, 196, 143), rgb(226, 71, 42)], [0, 1]),
                       startCenter: CGPoint(x: bowl.x - pr * 0.3, y: bowl.y + pr * 0.4), startRadius: 0,
                       endCenter: bowl, endRadius: pr * 1.25, options: [.drawsAfterEndLocation])
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
