import CoreGraphics
import Foundation

/// The shape of the wheel and which petal a point is on (`pomeloo/ui/wheel.py`). Coordinates have their
/// origin at the top-left of the wheel's square and y pointing down, like the view that draws it. Angles
/// are the mathematical kind: 0 to the right, counter-clockwise, as in the Windows app.
public enum WheelGeometry {
    private static let scale = 1.3
    public static let inner = 50.6 * scale
    public static let outer = 119.5 * scale
    /// Space left between two petals.
    public static let gap = 4.0 * scale
    /// Side of the square the wheel is drawn in.
    public static let size = Double(Int(2 * (outer + 10)))
    /// Room under the wheel for the hint pill.
    public static let hintHeight = 54.0

    public static var center: CGPoint { CGPoint(x: size / 2, y: size / 2) }

    /// Where petal `i` of `n` points. The first petal is at the top, or at the left when there are three.
    public static func angle(_ i: Int, of n: Int) -> Double {
        (n == 3 ? Double.pi : Double.pi / 2) - 2 * Double.pi * Double(i) / Double(n)
    }

    /// The petal under the point, or nil for the hole, the outside and the gaps between petals.
    public static func petal(atX x: Double, y: Double, count n: Int) -> Int? {
        let dx = x - size / 2
        let dy = y - size / 2
        let r = hypot(dx, dy)
        guard n > 0, r >= inner, r <= outer else { return nil }
        if n == 1 { return 0 }
        let a = atan2(-dy, dx)
        let step = 2 * Double.pi / Double(n)
        let turns = positiveRemainder(angle(0, of: n) - a, 2 * Double.pi)
        let i = Int((turns / step).rounded()) % n
        let off = abs(atan2(sin(a - angle(i, of: n)), cos(a - angle(i, of: n))))
        return off <= step / 2 - asin(gap / 2 / r) ? i : nil
    }

    /// The outline of petal `i` of `n` (n of at least 2) as a closed polygon, one point per degree of arc.
    public static func petalOutline(_ i: Int, of n: Int) -> [CGPoint] {
        let half = Double.pi / Double(n)
        let a = angle(i, of: n)
        let outerGap = asin(gap / 2 / outer)
        let innerGap = asin(gap / 2 / inner)
        var points = arc(radius: outer, from: a - half + outerGap, to: a + half - outerGap)
        points += arc(radius: inner, from: a + half - innerGap, to: a - half + innerGap)
        return points
    }

    /// A point on the circle of `radius` around the centre.
    public static func point(radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: size / 2 + cos(angle) * radius, y: size / 2 - sin(angle) * radius)
    }

    private static func arc(radius: Double, from start: Double, to end: Double) -> [CGPoint] {
        let steps = max(2, Int(abs(end - start) * 180 / Double.pi))
        return (0...steps).map { point(radius: radius, angle: start + (end - start) * Double($0) / Double(steps)) }
    }

    private static func positiveRemainder(_ value: Double, _ divisor: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: divisor)
        return r < 0 ? r + divisor : r
    }
}
