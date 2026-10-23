import AppKit
import SwiftUI

/// Draws a polyline of samples as a smooth curve (Catmull-Rom converted to cubic Béziers) instead of straight
/// segments. The control points are kept inside the vertical range of the two points they join, so a spike
/// never makes the curve overshoot above the peak or dip below the baseline.
enum SmoothCurve {
    typealias Segment = (c1: CGPoint, c2: CGPoint, end: CGPoint)

    /// One cubic segment per gap between consecutive `points` (`points.count - 1` segments).
    static func segments(_ p: [CGPoint]) -> [Segment] {
        guard p.count > 1 else { return [] }
        return (0..<p.count - 1).map { i in
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let lo = min(p1.y, p2.y), hi = max(p1.y, p2.y)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(max(p1.y + (p2.y - p0.y) / 6, lo), hi))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(max(p2.y - (p3.y - p1.y) / 6, lo), hi))
            return (c1, c2, p2)
        }
    }

    /// Every `step`-th sample (always keeping the last): for dense data such as the 1024-sample waveform, where
    /// curving through every sample would cost more than it shows.
    static func decimated(_ p: [CGPoint], step: Int) -> [CGPoint] {
        guard step > 1, p.count > 2 else { return p }
        var out = Swift.stride(from: 0, to: p.count, by: step).map { p[$0] }
        if let last = p.last, out.last != last { out.append(last) }
        return out
    }
}

extension Path {
    /// Starts a new subpath at the first point and curves smoothly through the rest.
    mutating func addSmoothCurve(through points: [CGPoint]) {
        guard let first = points.first else { return }
        move(to: first)
        for s in SmoothCurve.segments(points) { addCurve(to: s.end, control1: s.c1, control2: s.c2) }
    }
}

extension NSBezierPath {
    /// Starts a new subpath at the first point and curves smoothly through the rest.
    func appendSmoothCurve(through points: [CGPoint]) {
        guard let first = points.first else { return }
        move(to: first)
        for s in SmoothCurve.segments(points) { curve(to: s.end, controlPoint1: s.c1, controlPoint2: s.c2) }
    }
}
