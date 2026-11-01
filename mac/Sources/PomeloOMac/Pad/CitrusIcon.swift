import AppKit

/// PomeloO's orange slice, drawn with Core Graphics at any size (no image file needed). The same drawing
/// as the Windows app's progress citrus, with every segment filled.
enum CitrusIcon {
    private static let segments = 12

    /// Draws into a square of `side` points whose top-left is `origin`, in a flipped (y down) context.
    static func draw(in g: CGContext, origin: CGPoint, side: CGFloat) {
        let k = side / 176  // the Windows drawing is laid out for 176 px
        let c = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        let radius = side / 2 - 6 * k
        let fleshRadius = radius - 11 * k
        let hub = 7 * k

        func circle(_ radius: CGFloat, at center: CGPoint, _ color: NSColor) {
            g.setFillColor(color.cgColor)
            g.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }

        // rind: a glossy orange ring, then white pith, then the dark inside of the fruit
        g.saveGState()
        g.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
        g.clip()
        let focus = CGPoint(x: c.x - radius * 0.3, y: c.y - radius * 0.3)
        g.drawRadialGradient(gradient([.hex(0xFFB54A), .hex(0xE2620A)], [0, 1]), startCenter: focus, startRadius: 0,
                             endCenter: focus, endRadius: radius * 1.6, options: [.drawsAfterEndLocation])
        g.restoreGState()
        circle(radius - 7 * k, at: c, .hex(0xFFF1DB))
        circle(fleshRadius + k, at: c, .rgb(48, 40, 34))

        // twelve juicy segments from 12 o'clock, clockwise, with a little pith between them
        let step = 360.0 / Double(segments)
        let gap = 2.2
        let juice = gradient([.hex(0xFFE2A1), .hex(0xFFA62B), .hex(0xFF7B00)], [0, 0.45, 1])
        for i in 0..<segments {
            let a0 = 90 - Double(i + 1) * step + gap / 2
            let a1 = 90 - Double(i) * step - gap / 2
            g.saveGState()
            g.addPath(wedge(center: c, inner: hub, outer: fleshRadius, from: a0, to: a1))
            g.clip()
            g.drawRadialGradient(juice, startCenter: c, startRadius: 0, endCenter: c, endRadius: fleshRadius,
                                 options: [.drawsAfterEndLocation])
            g.restoreGState()
        }
        circle(hub, at: c, .hex(0xFFF1DB))
        // rind gloss
        g.setFillColor(NSColor.white.withAlphaComponent(40 / 255).cgColor)
        let gloss = CGPoint(x: c.x - radius * 0.45, y: c.y - radius * 0.62)
        g.fillEllipse(in: CGRect(x: gloss.x - radius * 0.18, y: gloss.y - radius * 0.07,
                                 width: radius * 0.36, height: radius * 0.14))
    }

    /// An annular sector between two radii and two angles (degrees, counter-clockwise from the right).
    private static func wedge(center c: CGPoint, inner: CGFloat, outer: CGFloat, from a0: Double, to a1: Double) -> CGPath {
        func point(_ radius: CGFloat, _ degrees: Double) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(x: c.x + radius * cos(radians), y: c.y - radius * sin(radians))
        }
        let path = CGMutablePath()
        let steps = max(2, Int(abs(a1 - a0) / 2))
        path.move(to: point(outer, a0))
        for s in 1...steps { path.addLine(to: point(outer, a0 + (a1 - a0) * Double(s) / Double(steps))) }
        for s in 0...steps { path.addLine(to: point(inner, a1 + (a0 - a1) * Double(s) / Double(steps))) }
        path.closeSubpath()
        return path
    }

    private static func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: colors.map(\.cgColor) as CFArray, locations: locations)!
    }
}
