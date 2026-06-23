import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Wattly app-icon master generator.
// Draws the brand LightningGlyph (prototype polygon, Glyphs.swift) in white on a
// rounded-rect #0066ff squircle, baked at 1024×1024 (macOS does NOT auto-mask).

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("ctx")
}
let W = CGFloat(size)

// --- squircle background -------------------------------------------------
let inset: CGFloat = 100                                  // macOS icon grid margin
let rect = CGRect(x: inset, y: inset, width: W - 2 * inset, height: W - 2 * inset)
let radius = rect.width * 0.2237                          // continuous-corner ratio
let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(rounded)
ctx.clip()
let colors = [CGColor(srgbRed: 0.149, green: 0.153, blue: 0.169, alpha: 1.0),  // #26272b top
              CGColor(srgbRed: 0.110, green: 0.114, blue: 0.125, alpha: 1.0)]  // #1c1d20 bottom
              as CFArray                                                        // around panelBg #212225
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: W), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// --- lightning glyph (white) --------------------------------------------
// 24×24 viewBox polygon, bbox centred at (12,12). CG y-up → negate y.
let pts: [(CGFloat, CGFloat)] = [(13, 2), (3, 14), (12, 14), (11, 22), (21, 10), (12, 10), (13, 2)]
let scale: CGFloat = 27.0                                 // bbox h20 → ~540px (~53% canvas)
func map(_ p: (CGFloat, CGFloat)) -> CGPoint {
    CGPoint(x: W / 2 + (p.0 - 12) * scale, y: W / 2 - (p.1 - 12) * scale)
}
let path = CGMutablePath()
for (i, p) in pts.enumerated() {
    let cg = map(p)
    if i == 0 { path.move(to: cg) } else { path.addLine(to: cg) }
}
path.closeSubpath()
ctx.addPath(path)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()

// --- write PNG -----------------------------------------------------------
guard let img = ctx.makeImage() else { fatalError("img") }
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fatalError("dest")
}
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
