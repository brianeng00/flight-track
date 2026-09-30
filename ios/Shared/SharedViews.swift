import FlightCore
import SwiftUI

extension StatusTone {
    /// Flighty-style status colors.
    var color: Color {
        switch self {
        case .onTime: return Color(red: 0.25, green: 0.80, blue: 0.45)
        case .minorDelay: return Color(red: 1.00, green: 0.72, blue: 0.20)
        case .majorDelay, .canceled: return Color(red: 1.00, green: 0.33, blue: 0.30)
        case .diverted: return Color(red: 0.75, green: 0.45, blue: 1.00)
        case .unknown: return Color.secondary
        }
    }
}

struct StatusPill: View {
    var text: String
    var tone: StatusTone

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tone == .unknown ? Color.primary : Color.black)
            .background(tone.color, in: Capsule())
            .lineLimit(1)
    }
}

/// Great-circle route with the plane at `progress`. Used on the Live Activity and in the app.
/// Draws over an optional pre-rendered map image; the route points already match its projection.
struct RouteArcView: View {
    var route: [RoutePoint]
    var progress: Double
    var tint: Color
    var showPlane: Bool = true
    var mapImage: Image?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if let mapImage {
                    mapImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .opacity(0.9)
                }
                Canvas { ctx, canvasSize in
                    let pts = route.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
                    guard pts.count >= 2 else { return }
                    var full = Path()
                    full.addLines(pts)
                    ctx.stroke(full, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))

                    let here = RouteProjection.point(along: route, fraction: progress)
                    let splitIndex = flownIndex(for: progress)
                    var flown = Path()
                    flown.addLines(Array(pts[0...splitIndex]) + [CGPoint(x: here.point.x * canvasSize.width, y: here.point.y * canvasSize.height)])
                    ctx.stroke(flown, with: .color(tint), style: StrokeStyle(lineWidth: 3, lineCap: .round))

                    for (i, p) in [pts.first!, pts.last!].enumerated() {
                        let r: CGFloat = 3.5
                        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                        ctx.fill(dot, with: .color(i == 0 ? tint : .white))
                    }
                }
                if showPlane {
                    let here = RouteProjection.point(along: route, fraction: progress)
                    Image(systemName: "airplane")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .rotationEffect(.radians(here.angleRadians))
                        .position(x: here.point.x * size.width, y: here.point.y * size.height)
                }
            }
        }
    }

    /// Last route vertex at or before `fraction` of the path length.
    private func flownIndex(for fraction: Double) -> Int {
        guard route.count >= 2 else { return 0 }
        let lengths = zip(route, route.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        var remaining = min(max(fraction, 0), 1) * total
        for (i, len) in lengths.enumerated() {
            if remaining <= len { return i }
            remaining -= len
        }
        return route.count - 2
    }
}

/// Countdown that keeps ticking inside a widget with no updates. Never builds an inverted range.
struct CountdownText: View {
    var target: Date

    var body: some View {
        let now = Date()
        if target > now {
            Text(timerInterval: now...target, countsDown: true, showsHours: true)
                .monospacedDigit()
        } else {
            Text("now")
        }
    }
}

extension LiveActivityState {
    /// Time the relevant countdown points at (departure before takeoff, landing after).
    var countdownTarget: Date? {
        switch headline {
        case .departsIn(let d), .boardingSoon(let d), .landsIn(let d): return d
        default: return nil
        }
    }

    /// Self-updating progress window, when we know both ends.
    var flightWindow: ClosedRange<Date>? {
        guard let takeoff = takeoffAt, let landing = landingAt, landing > takeoff else { return nil }
        return takeoff...landing
    }
}
