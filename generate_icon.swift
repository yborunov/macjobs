import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 1024
let height = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create drawing context.\n", stderr)
    exit(1)
}

func setFill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) {
    ctx.setFillColor(red: r, green: g, blue: b, alpha: a)
}

let rect = CGRect(x: 0, y: 0, width: width, height: height)

let topColor = CGColor(red: 0.08, green: 0.36, blue: 0.86, alpha: 1.0)
let bottomColor = CGColor(red: 0.15, green: 0.64, blue: 0.95, alpha: 1.0)
let gradient = CGGradient(colorsSpace: colorSpace, colors: [topColor, bottomColor] as CFArray, locations: [0.0, 1.0])!

let cardRect = rect.insetBy(dx: 56, dy: 56)
let cardPath = CGPath(roundedRect: cardRect, cornerWidth: 220, cornerHeight: 220, transform: nil)
ctx.addPath(cardPath)
ctx.clip()
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 968), end: CGPoint(x: 512, y: 56), options: [])
ctx.resetClip()

setFill(1, 1, 1, 0.93)
let panel = CGRect(x: 206, y: 206, width: 612, height: 612)
ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 88, cornerHeight: 88, transform: nil))
ctx.fillPath()

setFill(0.03, 0.19, 0.54, 0.97)
let header = CGRect(x: 206, y: 638, width: 612, height: 180)
ctx.addPath(CGPath(roundedRect: header, cornerWidth: 88, cornerHeight: 88, transform: nil))
ctx.fillPath()

setFill(0.08, 0.35, 0.86)
for row in 0..<2 {
    for col in 0..<2 {
        let x = 302 + CGFloat(col) * 220
        let y = 318 + CGFloat(row) * 180
        let dot = CGRect(x: x, y: y, width: 112, height: 104)
        ctx.addPath(CGPath(roundedRect: dot, cornerWidth: 28, cornerHeight: 28, transform: nil))
        ctx.fillPath()
    }
}

setFill(1, 1, 1)
let bar = CGRect(x: 382, y: 704, width: 260, height: 40)
ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 20, cornerHeight: 20, transform: nil))
ctx.fillPath()

guard let image = ctx.makeImage() else {
    fputs("Failed to create image from context.\n", stderr)
    exit(1)
}

let outURL = URL(fileURLWithPath: "/Users/wannabe/GitUnsynced/my-tools/MacJobs/icon_1024.png")
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("Failed to create output destination.\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(dest, image, nil)
if !CGImageDestinationFinalize(dest) {
    fputs("Failed to write icon PNG.\n", stderr)
    exit(1)
}
