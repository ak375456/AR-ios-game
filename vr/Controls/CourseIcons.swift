//
//  CourseIcons.swift
//  vr
//
//  Small drawings of the course props, for the editor's tray.
//

import SwiftUI

/// The props drawn the way they look in the room, rather than stood in for
/// by a generic symbol, so the tray says exactly what a tap will put down.
enum CourseIconPalette {
    static let orange = Color(red: 0.98, green: 0.46, blue: 0.12)
    static let red = Color(red: 0.86, green: 0.16, blue: 0.12)
    static let white = Color(red: 0.95, green: 0.95, blue: 0.93)
    static let rubber = Color(white: 0.14)
}

/// A road cone: black base, orange shell, white band.
struct ConeIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let baseTop = h * 0.84
            context.fill(Path(roundedRect: CGRect(x: w * 0.12, y: baseTop, width: w * 0.76, height: h * 0.12),
                              cornerRadius: h * 0.03), with: .color(CourseIconPalette.rubber))

            let apex = CGPoint(x: w * 0.5, y: h * 0.06)
            let left = CGPoint(x: w * 0.25, y: baseTop)
            let right = CGPoint(x: w * 0.75, y: baseTop)
            var shell = Path()
            shell.move(to: CGPoint(x: apex.x - w * 0.035, y: apex.y))
            shell.addLine(to: CGPoint(x: apex.x + w * 0.035, y: apex.y))
            shell.addLine(to: right)
            shell.addLine(to: left)
            shell.closeSubpath()
            context.fill(shell, with: .color(CourseIconPalette.orange))

            // The band, clipped to the shell so its edges follow the taper.
            context.clip(to: shell)
            context.fill(Path(CGRect(x: 0, y: h * 0.40, width: w, height: h * 0.16)),
                         with: .color(CourseIconPalette.white))
        }
        .accessibilityHidden(true)
    }
}

/// A race barrier end-on and from the side: red and white sections on a
/// rubber toe, with the Jersey slope at each end.
struct BarrierIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let bottom = h * 0.80, top = h * 0.30
            var outline = Path()
            outline.move(to: CGPoint(x: w * 0.04, y: bottom))
            outline.addLine(to: CGPoint(x: w * 0.10, y: h * 0.56))
            outline.addLine(to: CGPoint(x: w * 0.14, y: top))
            outline.addLine(to: CGPoint(x: w * 0.86, y: top))
            outline.addLine(to: CGPoint(x: w * 0.90, y: h * 0.56))
            outline.addLine(to: CGPoint(x: w * 0.96, y: bottom))
            outline.closeSubpath()
            context.fill(outline, with: .color(CourseIconPalette.red))

            var clipped = context
            clipped.clip(to: outline)
            let sections = 5
            for index in stride(from: 1, to: sections, by: 2) {
                let x = w * (0.04 + 0.92 * CGFloat(index) / CGFloat(sections))
                clipped.fill(Path(CGRect(x: x, y: 0, width: w * 0.92 / CGFloat(sections), height: h)),
                             with: .color(CourseIconPalette.white))
            }
            context.fill(Path(roundedRect: CGRect(x: w * 0.03, y: bottom, width: w * 0.94, height: h * 0.09),
                              cornerRadius: h * 0.02), with: .color(CourseIconPalette.rubber))
        }
        .accessibilityHidden(true)
    }
}

/// A tyre lying flat, seen from above and a little to the side: the tread
/// wall, the rubber face and the grey wheel with its nuts.
struct TyreIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let rx = w * 0.42, ry = h * 0.26
            let top = h * 0.40, wall = h * 0.20
            let centreX = w * 0.5

            // The tread wall: the face dropped by the tyre's depth, and the
            // band between, both under the face drawn next.
            let wallColour = GraphicsContext.Shading.color(Color(white: 0.07))
            context.fill(Path(ellipseIn: CGRect(x: centreX - rx, y: top + wall - ry, width: rx * 2, height: ry * 2)),
                         with: wallColour)
            context.fill(Path(CGRect(x: centreX - rx, y: top, width: rx * 2, height: wall)), with: wallColour)

            let face = Path(ellipseIn: CGRect(x: centreX - rx, y: top - ry, width: rx * 2, height: ry * 2))
            context.fill(face, with: .color(CourseIconPalette.rubber))
            context.stroke(face, with: .color(.white.opacity(0.22)), lineWidth: 0.8)

            let wheel = CGRect(x: centreX - rx * 0.52, y: top - ry * 0.52, width: rx * 1.04, height: ry * 1.04)
            context.fill(Path(ellipseIn: wheel), with: .color(Color(white: 0.30)))
            for index in 0..<5 {
                let angle = Double(index) / 5 * 2 * .pi - .pi / 2
                let nut = CGPoint(x: centreX + cos(angle) * rx * 0.22, y: top + sin(angle) * ry * 0.22)
                context.fill(Path(ellipseIn: CGRect(x: nut.x - 1.3, y: nut.y - 1.0, width: 2.6, height: 2.0)),
                             with: .color(Color(white: 0.85)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Three cones in a row with the line weaving through them.
struct SlalomIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var weave = Path()
            weave.move(to: CGPoint(x: w * 0.02, y: h * 0.62))
            weave.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.62),
                           control1: CGPoint(x: w * 0.14, y: h * 0.10), control2: CGPoint(x: w * 0.38, y: h * 0.10))
            weave.addCurve(to: CGPoint(x: w * 0.98, y: h * 0.62),
                           control1: CGPoint(x: w * 0.62, y: h * 1.10), control2: CGPoint(x: w * 0.86, y: h * 1.10))
            context.stroke(weave, with: .color(.white.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3, 3]))

            for x in [w * 0.26, w * 0.5, w * 0.74] {
                let base = h * 0.78, apex = h * 0.36, half = w * 0.075
                context.fill(Path(CGRect(x: x - half * 1.3, y: base, width: half * 2.6, height: h * 0.07)),
                             with: .color(CourseIconPalette.rubber))
                var shell = Path()
                shell.move(to: CGPoint(x: x, y: apex))
                shell.addLine(to: CGPoint(x: x + half, y: base))
                shell.addLine(to: CGPoint(x: x - half, y: base))
                shell.closeSubpath()
                context.fill(shell, with: .color(CourseIconPalette.orange))
            }
        }
        .accessibilityHidden(true)
    }
}
