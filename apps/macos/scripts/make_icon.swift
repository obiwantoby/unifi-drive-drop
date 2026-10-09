// Renders the DriveDrop app icon at every size macOS wants, into an .iconset, then
// iconutil turns that into AppIcon.icns.
//
// Drawn, not photographed: the geometry is defined once in a 1024 design space and every
// size is a vector-accurate downsample, so the mark stays sharp at 16 px in the menu bar.
//
//   swift scripts/make_icon.swift resources/AppIcon.iconset && iconutil -c icns resources/AppIcon.iconset -o resources/AppIcon.icns

import AppKit

let design: CGFloat = 1024

func draw(_ size: CGFloat) -> Data? {
    let s = size
    let k = s / design                       // design-space -> pixel scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext
    g.clear(CGRect(x: 0, y: 0, width: s, height: s))

    func px(_ v: CGFloat) -> CGFloat { v * k }

    // ---- tile: macOS big-sur squircle, ~22.37% corner radius --------------------------
    let inset = px(64)
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)
    g.saveGState()
    g.addPath(tilePath); g.clip()

    // Deep console blue -> cyan. Reads as "UniFi" without copying their logo.
    let cs = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.043, green: 0.302, blue: 0.784, alpha: 1),   // #0B4DC8
        CGColor(red: 0.000, green: 0.557, blue: 0.839, alpha: 1),   // #008ED6
        CGColor(red: 0.055, green: 0.761, blue: 0.725, alpha: 1),   // #0EC2B9
    ] as CFArray, locations: [0, 0.55, 1])!
    g.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY),
                         end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // Liquid-glass sheen: a soft diagonal highlight across the upper third.
    let sheen = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(sheen,
                         start: CGPoint(x: tile.minX, y: tile.maxY),
                         end: CGPoint(x: tile.midX, y: tile.midY - tile.height * 0.25),
                         options: [.drawsAfterEndLocation])
    g.restoreGState()

    // Hairline rim light, the thing that makes it look like glass rather than plastic.
    g.addPath(tilePath)
    g.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
    g.setLineWidth(max(1, px(6)))
    g.strokePath()

    // ---- mark: arrow into a tray ------------------------------------------------------
    // Kept deliberately chunky: at 16 px this is 16 device pixels total.
    g.setLineCap(.round)
    g.setLineJoin(.round)

    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let stroke = px(58)

    // Drop shadow so the mark lifts off the tile.
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -px(6)), blur: px(18),
                color: CGColor(red: 0, green: 0.1, blue: 0.25, alpha: 0.45))

    // shaft
    let shaftX = design / 2
    g.setStrokeColor(white)
    g.setLineWidth(stroke)
    g.beginPath()
    g.move(to: CGPoint(x: px(shaftX), y: px(660)))
    g.addLine(to: CGPoint(x: px(shaftX), y: px(362)))
    g.strokePath()

    // arrowhead
    g.beginPath()
    g.move(to: CGPoint(x: px(shaftX - 150), y: px(510)))
    g.addLine(to: CGPoint(x: px(shaftX), y: px(360)))
    g.addLine(to: CGPoint(x: px(shaftX + 150), y: px(510)))
    g.strokePath()

    // tray: an open bracket the arrow drops into
    let trayY: CGFloat = 236
    g.beginPath()
    g.move(to: CGPoint(x: px(286), y: px(trayY + 128)))
    g.addLine(to: CGPoint(x: px(286), y: px(trayY)))
    g.addLine(to: CGPoint(x: px(738), y: px(trayY)))
    g.addLine(to: CGPoint(x: px(738), y: px(trayY + 128)))
    g.strokePath()
    g.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    guard let data = draw(px) else { FileHandle.standardError.write(Data("failed \(name)\n".utf8)); exit(1) }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(sizes.count) pngs to \(outDir)")
