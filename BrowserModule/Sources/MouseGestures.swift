import Foundation
import AppKit
import WebKit

/// Browser mouse gestures implementation.
///
/// Behavior & Constraints:
/// - Right mouse button drag (right click down -> drag -> right click up).
/// - Gestures recognized:
///   * Left: Back (goBack)
///   * Right: Forward (goForward)
///   * Up: Page Top (scroll to top)
///   * Down: Page Bottom (scroll to bottom)
/// - Normal context menu preserved when right click is not a deliberate drag.
/// - Minimum distance threshold (e.g. 40pt) and strict dominant axis ratio (dx vs dy > 2.0 or dy vs dx > 2.0).
/// - No action on short or ambiguous drag; context menu is allowed to show normally.
/// - Text input safety: if gesture starts on an editable text input or selection, gesture is not triggered to preserve selection/input context menus.
/// - Tab safety: gestures only take effect on the active foreground tab.
/// - User toggle via BrowserPreferences / Settings.
public enum MouseGestureRecognizer {
    public static let minDragDistance: CGFloat = 40.0
    public static let dominanceRatio: CGFloat = 2.0
    public static let minShakeLegDistance: CGFloat = 30.0
    public static let minLDragLegDistance: CGFloat = 30.0

    public enum Direction: Equatable {
        case left    // Back
        case right   // Forward
        case up      // Page top
        case down    // Page bottom
        case shake   // Refresh
        case closeTab // Close current tab (down then left OR right)
    }

    public static func recognize(start: CGPoint, end: CGPoint) -> Direction? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let absX = abs(dx)
        let absY = abs(dy)
        let distance = hypot(dx, dy)

        guard distance >= minDragDistance else { return nil }

        if absX >= absY * dominanceRatio {
            // Horizontal dominance
            return dx < 0 ? .left : .right
        } else if absY >= absX * dominanceRatio {
            // Vertical dominance: note macOS view coordinates where Y is 0 at bottom or top depending on flipped
            // But we evaluate end.y - start.y: dy > 0 is up in unflipped or down in flipped.
            // In LinkMenuWebView (flipped = true in WKWebView): dy > 0 is downwards, dy < 0 is upwards.
            return dy < 0 ? .up : .down
        }

        return nil
    }

    /// Recognizes a horizontal shake gesture (left-right or right-left) across a sampled point trace.
    /// Requires meaningful movement in both opposite horizontal legs and horizontal dominance over vertical spread.
    public static func recognizeShake(points: [CGPoint]) -> Bool {
        guard points.count >= 3 else { return false }

        var minX = points[0].x
        var maxX = points[0].x
        var minY = points[0].y
        var maxY = points[0].y

        for pt in points {
            if pt.x < minX { minX = pt.x }
            if pt.x > maxX { maxX = pt.x }
            if pt.y < minY { minY = pt.y }
            if pt.y > maxY { maxY = pt.y }
        }

        let totalSpanX = maxX - minX
        let totalSpanY = maxY - minY

        // Dominance: horizontal movement must clearly dominate vertical jitter
        guard totalSpanX >= minShakeLegDistance else { return false }
        guard totalSpanX >= totalSpanY * dominanceRatio else { return false }

        // Trace incremental extrema / direction changes along the X axis
        var extremaX: [CGFloat] = [points[0].x]
        var currentDirection: Int = 0 // +1: moving right, -1: moving left

        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            if abs(dx) < 2.0 { continue } // Filter micro-jitter

            let dir = dx > 0 ? 1 : -1
            if currentDirection == 0 {
                currentDirection = dir
            } else if dir != currentDirection {
                // Direction reversal detected
                extremaX.append(points[i - 1].x)
                currentDirection = dir
            }
        }
        extremaX.append(points.last!.x)

        guard extremaX.count >= 3 else { return false }

        // Check for at least two consecutive opposite legs, each meeting minShakeLegDistance
        for i in 0..<(extremaX.count - 2) {
            let leg1 = extremaX[i + 1] - extremaX[i]
            let leg2 = extremaX[i + 2] - extremaX[i + 1]

            // Opposite directions: leg1 * leg2 < 0
            if (leg1 > 0 && leg2 < 0) || (leg1 < 0 && leg2 > 0) {
                if abs(leg1) >= minShakeLegDistance && abs(leg2) >= minShakeLegDistance {
                    return true
                }
            }
        }

        return false
    }

    /// Recognizes an L-shaped gesture: right-button down then downward leg followed by horizontal leg (left OR right).
    /// Requires both legs >= 30pt, dominant axes (first leg downward dy > 0, second leg horizontal dx != 0),
    /// rejects diagonal/jitter, and normalizes y-down coordinates.
    public static func recognizeLCloseTab(points: [CGPoint]) -> Bool {
        guard points.count >= 3 else { return false }

        // Find candidate corner points where the gesture transitions from downward to horizontal movement.
        // We evaluate segment 1 (start -> corner) and segment 2 (corner -> end).
        let start = points[0]
        let end = points.last!

        // Filter out consecutive duplicate points to avoid 0-length step artifacts
        var cleanPoints: [CGPoint] = [points[0]]
        for pt in points.dropFirst() {
            let last = cleanPoints.last!
            if hypot(pt.x - last.x, pt.y - last.y) >= 2.0 {
                cleanPoints.append(pt)
            }
        }
        guard cleanPoints.count >= 3 else { return false }

        let n = cleanPoints.count
        var bestCornerIndex: Int? = nil
        var maxCornerScore: CGFloat = -1.0

        for i in 1..<(n - 1) {
            let corner = cleanPoints[i]

            // Leg 1: start -> corner
            let dy1 = corner.y - start.y
            let dx1 = corner.x - start.x

            // Leg 2: corner -> end
            let dy2 = end.y - corner.y
            let dx2 = end.x - corner.x

            // First leg must be downward: dy1 >= minLDragLegDistance
            guard dy1 >= minLDragLegDistance else { continue }
            // First leg must be strictly vertical dominant: dy1 >= abs(dx1) * dominanceRatio
            guard dy1 >= abs(dx1) * dominanceRatio else { continue }

            // Second leg must be horizontal: abs(dx2) >= minLDragLegDistance
            guard abs(dx2) >= minLDragLegDistance else { continue }
            // Second leg must be strictly horizontal dominant: abs(dx2) >= abs(dy2) * dominanceRatio
            guard abs(dx2) >= abs(dy2) * dominanceRatio else { continue }

            // Verify monotonicity / reject diagonal/jitter within leg 1
            // In leg 1, y should generally increase, and horizontal spread should stay small
            var leg1Valid = true
            for j in 0...i {
                let pt = cleanPoints[j]
                // Spread away from the line between start and corner or excessive horizontal excursion
                let xDist = abs(pt.x - start.x)
                if xDist > abs(dx1) + 15.0 || (dy1 > 0 && xDist > dy1 / dominanceRatio) {
                    leg1Valid = false
                    break
                }
                // Reject upward jitter beyond a small threshold
                if pt.y < start.y - 10.0 || pt.y > corner.y + 10.0 {
                    leg1Valid = false
                    break
                }
            }
            guard leg1Valid else { continue }

            // Verify monotonicity / reject diagonal/jitter within leg 2
            // In leg 2, vertical spread should stay small relative to corner.y
            var leg2Valid = true
            for j in i..<n {
                let pt = cleanPoints[j]
                let yDist = abs(pt.y - corner.y)
                if yDist > abs(dy2) + 15.0 || (abs(dx2) > 0 && yDist > abs(dx2) / dominanceRatio) {
                    leg2Valid = false
                    break
                }
                // Reject horizontal overshoot/jitter in opposite direction
                if dx2 > 0 {
                    if pt.x < corner.x - 10.0 || pt.x > end.x + 10.0 {
                        leg2Valid = false
                        break
                    }
                } else {
                    if pt.x > corner.x + 10.0 || pt.x < end.x - 10.0 {
                        leg2Valid = false
                        break
                    }
                }
            }
            guard leg2Valid else { continue }

            // Score this corner by sum of leg distances
            let score = dy1 + abs(dx2)
            if score > maxCornerScore {
                maxCornerScore = score
                bestCornerIndex = i
            }
        }

        return bestCornerIndex != nil
    }

    /// Combined recognition prioritizing shake, then L-shaped closeTab, then simple directional drags.
    public static func recognizeGesture(points: [CGPoint]) -> Direction? {
        guard let start = points.first, let end = points.last else { return nil }
        if recognizeShake(points: points) {
            return .shake
        }
        if recognizeLCloseTab(points: points) {
            return .closeTab
        }
        return recognize(start: start, end: end)
    }
}
