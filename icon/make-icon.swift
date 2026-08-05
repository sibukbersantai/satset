import AppKit
import CoreGraphics
import Foundation

// MARK: - Shapes

/// Apple-style squircle (superellipse), not a plain rounded rect.
func squirclePath(in r: CGRect, n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath()
    let a = r.width/2, b = r.height/2
    let cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i)/CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2/n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2/n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

/// Lightning bolt in a unit box, y measured downward.
func boltPath(in rect: CGRect) -> CGPath {
    let pts: [(CGFloat, CGFloat)] = [
        (0.600, 0.030),
        (0.180, 0.565),
        (0.450, 0.565),
        (0.395, 0.970),
        (0.820, 0.435),
        (0.550, 0.435),
    ]
    let p = CGMutablePath()
    for (i, pt) in pts.enumerated() {
        let x = rect.minX + pt.0 * rect.width
        let y = rect.minY + (1 - pt.1) * rect.height   // CG origin is bottom-left
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func ctx(_ px: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true)
    c.interpolationQuality = .high
    return c
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - App icon

func appIcon(_ px: Int) -> CGImage {
    let c = ctx(px)
    let s = CGFloat(px)
    // Apple's macOS grid: 824/1024 body, centred, with room for a soft shadow.
    let margin = s * 0.0977
    let body = CGRect(x: margin, y: margin, width: s - margin*2, height: s - margin*2)

    // Soft contact shadow
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -s*0.012), blur: s*0.045,
                color: NSColor.black.withAlphaComponent(0.28).cgColor)
    c.addPath(squirclePath(in: body))
    c.setFillColor(NSColor.black.cgColor)
    c.fillPath()
    c.restoreGState()

    // Gradient body
    c.saveGState()
    c.addPath(squirclePath(in: body))
    c.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.541, green: 0.169, blue: 0.886, alpha: 1),   // violet
        CGColor(srgbRed: 0.925, green: 0.145, blue: 0.478, alpha: 1),   // magenta
    ] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY),
                         end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Top sheen for depth
    let sheen = CGGradient(colorsSpace: cs, colors: [
        NSColor.white.withAlphaComponent(0.30).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                         end: CGPoint(x: body.midX, y: body.midY), options: [])
    c.restoreGState()

    // Inner hairline so the edge reads crisply on light backgrounds
    c.saveGState()
    c.addPath(squirclePath(in: body.insetBy(dx: s*0.004, dy: s*0.004)))
    c.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    c.setLineWidth(max(1, s*0.006))
    c.strokePath()
    c.restoreGState()

    // Bolt
    let boltBox = body.insetBy(dx: body.width*0.155, dy: body.height*0.115)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -s*0.006), blur: s*0.02,
                color: NSColor.black.withAlphaComponent(0.22).cgColor)
    // Composite fill+stroke first, then shadow the result -- shadowing each op separately
    // leaves a ghost line along the inside of the stroke.
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.addPath(boltPath(in: boltBox))
    c.setFillColor(NSColor.white.cgColor)
    c.setStrokeColor(NSColor.white.cgColor)
    // Stroking with round joins softens the polygon corners at small sizes.
    c.setLineJoin(.round)
    c.setLineWidth(s * 0.028)
    c.drawPath(using: .fillStroke)
    c.endTransparencyLayer()
    c.restoreGState()

    return c.makeImage()!
}

// MARK: - Menu bar icon (template: black + alpha only)

func menuBarIcon(w: Int, h: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true)
    let box = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)).insetBy(dx: CGFloat(w)*0.06, dy: CGFloat(h)*0.04)
    c.addPath(boltPath(in: box))
    c.setFillColor(NSColor.black.cgColor)
    c.setStrokeColor(NSColor.black.cgColor)
    c.setLineJoin(.round)
    c.setLineWidth(CGFloat(h) * 0.10)
    c.drawPath(using: .fillStroke)
    return c.makeImage()!
}

// MARK: - Emit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for px in [16, 32, 64, 128, 256, 512, 1024] {
    write(appIcon(px), to: out.appendingPathComponent("app-\(px).png"))
}
write(menuBarIcon(w: 16, h: 18), to: out.appendingPathComponent("menubar-1x.png"))
write(menuBarIcon(w: 32, h: 36), to: out.appendingPathComponent("menubar-2x.png"))
print("wrote icons to \(out.path)")
