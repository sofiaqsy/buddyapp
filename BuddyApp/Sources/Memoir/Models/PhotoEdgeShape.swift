import SwiftUI

enum PhotoEdgeShape: String, CaseIterable, Equatable, Codable {
    case none
    case tornBottom
    case tornTop
    case tornRight
    case tornLeft
    case diagonalTR   // keeps top-right
    case diagonalBL   // keeps bottom-left (inverse)

    var label: String {
        switch self {
        case .none:        return "Normal"
        case .tornBottom:  return "Abajo"
        case .tornTop:     return "Arriba"
        case .tornRight:   return "Derecha"
        case .tornLeft:    return "Izquierda"
        case .diagonalTR:  return "Diag ↗"
        case .diagonalBL:  return "Diag ↙"
        }
    }

    var icon: String {
        switch self {
        case .none:        return "rectangle"
        case .tornBottom:  return "rectangle.bottomthird.inset.filled"
        case .tornTop:     return "rectangle.topthird.inset.filled"
        case .tornRight:   return "rectangle.righthalf.inset.filled"
        case .tornLeft:    return "rectangle.lefthalf.inset.filled"
        case .diagonalTR:  return "triangle"
        case .diagonalBL:  return "triangle.fill"
        }
    }
}

// MARK: - Helpers

/// Generates a torn edge path along one axis.
/// `anchors` are normalised (0–1). `amplitude` controls how deep each spike goes.
private func tornPoints(anchors: [CGFloat], spread: CGFloat, flip: Bool) -> [CGFloat] {
    // spread: how much each point deviates from the base line
    var pts: [CGFloat] = []
    for (i, a) in anchors.enumerated() {
        let jitter = spread * (i % 2 == 0 ? 1 : -1)
        pts.append(a + jitter * (flip ? -1 : 1))
    }
    return pts
}

// MARK: - Torn Bottom
// Natural tear: stays roughly at ~78% height with organic variation

struct TornBottomShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // Each pair = (x_normalised, y_normalised). x evenly spaced, y hand-tuned for realism.
        let pts: [(CGFloat, CGFloat)] = [
            (0.00, 0.79), (0.05, 0.76), (0.10, 0.82), (0.15, 0.74),
            (0.21, 0.80), (0.27, 0.72), (0.32, 0.78), (0.38, 0.71),
            (0.43, 0.77), (0.48, 0.83), (0.53, 0.74), (0.58, 0.80),
            (0.63, 0.70), (0.68, 0.76), (0.73, 0.82), (0.78, 0.73),
            (0.83, 0.79), (0.88, 0.69), (0.93, 0.76), (1.00, 0.80)
        ]

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: pts.last!.1 * h))

        for i in stride(from: pts.count - 2, through: 0, by: -1) {
            let curr = pts[i], next = pts[i + 1]
            // Horizontal jitter (like DiagonalTR) — gentle S-curves instead of sharp teeth
            let cpx = (curr.0 + next.0) / 2 * w + (i % 2 == 0 ? 7 : -7)
            let cpy = (curr.1 + next.1) / 2 * h
            p.addQuadCurve(to: CGPoint(x: curr.0 * w, y: curr.1 * h),
                           control: CGPoint(x: cpx, y: cpy))
        }

        p.addLine(to: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Torn Top

struct TornTopShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let pts: [(CGFloat, CGFloat)] = [
            (0.00, 0.21), (0.05, 0.25), (0.11, 0.18), (0.17, 0.28),
            (0.23, 0.19), (0.29, 0.27), (0.35, 0.17), (0.41, 0.24),
            (0.47, 0.16), (0.53, 0.23), (0.58, 0.18), (0.64, 0.26),
            (0.70, 0.17), (0.76, 0.24), (0.82, 0.19), (0.88, 0.27),
            (0.93, 0.20), (1.00, 0.22)
        ]

        var p = Path()
        p.move(to: CGPoint(x: 0, y: pts[0].1 * h))

        for i in 1..<pts.count {
            let prev = pts[i - 1], curr = pts[i]
            // Horizontal jitter (same style as DiagonalTR) — removes steep spikes
            let cpx = (prev.0 + curr.0) / 2 * w + (i % 2 == 0 ? 7 : -7)
            let cpy = (prev.1 + curr.1) / 2 * h
            p.addQuadCurve(to: CGPoint(x: curr.0 * w, y: curr.1 * h),
                           control: CGPoint(x: cpx, y: cpy))
        }

        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}

// MARK: - Torn Right

struct TornRightShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let pts: [(CGFloat, CGFloat)] = [
            (0.79, 0.00), (0.83, 0.06), (0.76, 0.12), (0.82, 0.18),
            (0.74, 0.24), (0.80, 0.31), (0.73, 0.38), (0.79, 0.45),
            (0.71, 0.52), (0.77, 0.59), (0.82, 0.65), (0.75, 0.72),
            (0.81, 0.78), (0.74, 0.85), (0.79, 0.91), (0.76, 1.00)
        ]

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: pts[0].0 * w, y: 0))

        for i in 1..<pts.count {
            let prev = pts[i - 1], curr = pts[i]
            let cpy = (prev.1 + curr.1) / 2 * h
            let cpx = max(prev.0, curr.0) * w + 4
            p.addQuadCurve(to: CGPoint(x: curr.0 * w, y: curr.1 * h),
                           control: CGPoint(x: cpx, y: cpy))
        }

        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}

// MARK: - Torn Left

struct TornLeftShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let pts: [(CGFloat, CGFloat)] = [
            (0.21, 0.00), (0.17, 0.07), (0.24, 0.14), (0.18, 0.21),
            (0.26, 0.28), (0.19, 0.35), (0.25, 0.42), (0.17, 0.50),
            (0.23, 0.57), (0.28, 0.63), (0.20, 0.70), (0.26, 0.77),
            (0.19, 0.84), (0.24, 0.91), (0.21, 1.00)
        ]

        var p = Path()
        p.move(to: CGPoint(x: pts[0].0 * w, y: 0))

        for i in 1..<pts.count {
            let prev = pts[i - 1], curr = pts[i]
            let cpy = (prev.1 + curr.1) / 2 * h
            let cpx = min(prev.0, curr.0) * w - 4
            p.addQuadCurve(to: CGPoint(x: curr.0 * w, y: curr.1 * h),
                           control: CGPoint(x: cpx, y: cpy))
        }

        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Diagonal TR (keeps top-right triangle area)
// Tear runs from ~top-right → bottom-left with organic edge

struct DiagonalTRShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // Points define the torn edge from top (right side) to bottom (left side)
        let pts: [(CGFloat, CGFloat)] = [
            (1.00, 0.05),
            (0.91, 0.14), (0.97, 0.22), (0.88, 0.30),
            (0.79, 0.38), (0.85, 0.46), (0.76, 0.53),
            (0.67, 0.61), (0.73, 0.68), (0.62, 0.76),
            (0.53, 0.83), (0.59, 0.90), (0.48, 0.97),
            (0.40, 1.00)
        ]

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: pts[0].0 * w, y: pts[0].1 * h))

        for i in 1..<pts.count {
            let prev = pts[i - 1], curr = pts[i]
            let cpx = (prev.0 + curr.0) / 2 * w + (i % 2 == 0 ? 8 : -8)
            let cpy = (prev.1 + curr.1) / 2 * h
            p.addQuadCurve(to: CGPoint(x: curr.0 * w, y: curr.1 * h),
                           control: CGPoint(x: cpx, y: cpy))
        }

        p.addLine(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Diagonal BL (keeps bottom-left — inverse of TR)

struct DiagonalBLShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let pts: [(CGFloat, CGFloat)] = [
            (0.00, 0.95),
            (0.09, 0.86), (0.03, 0.78), (0.12, 0.70),
            (0.21, 0.62), (0.15, 0.54), (0.24, 0.47),
            (0.33, 0.39), (0.27, 0.32), (0.38, 0.24),
            (0.47, 0.17), (0.41, 0.10), (0.52, 0.03),
            (0.60, 0.00)
        ]

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: pts.last!.0 * w, y: 0))

        for i in stride(from: pts.count - 2, through: 0, by: -1) {
            let next = pts[i + 1], curr = pts[i]
            let cpx = (next.0 + curr.0) / 2 * w + (i % 2 == 0 ? -8 : 8)
            let cpy = (next.1 + curr.1) / 2 * h
            p.addQuadCurve(to: CGPoint(x: curr.0 * w, y: curr.1 * h),
                           control: CGPoint(x: cpx, y: cpy))
        }

        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}
