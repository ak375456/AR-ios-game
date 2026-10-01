import SwiftUI

/// Shared pit-garage palette. Cyan means navigation; yellow means the main action.
enum GaragePalette {
    static let midnight = Color(red: 0.055, green: 0.10, blue: 0.15)
    static let indigo = Color(red: 0.11, green: 0.20, blue: 0.27)
    static let deepIndigo = Color(red: 0.075, green: 0.14, blue: 0.20)
    static let neon = Color(red: 0.26, green: 0.80, blue: 0.88)
    static let glow = neon
    static let statStart = neon
    static let statEnd = neon
    static let amberTop = Color(red: 1, green: 0.78, blue: 0.16)
    static let amberBottom = Color(red: 0.76, green: 0.43, blue: 0.04)
    static let amberInk = midnight
    static let paper = Color(red: 0.96, green: 0.94, blue: 0.86)
    static let muted = Color(red: 0.64, green: 0.74, blue: 0.78)
    static let success = Color(red: 0.36, green: 0.76, blue: 0.43)
}

enum GameType {
    // The bundled font's PostScript name, not its filename. Supporting copy uses SF.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom("LilitaOne", size: size, relativeTo: style)
    }
}

struct GarageBackdrop: View {
    var body: some View { GaragePalette.midnight.ignoresSafeArea() }
}

/// Quiet architectural shapes: garage door seams, cyan wall and a painted pit bay.
struct GarageStudio: View {
    var body: some View {
        GeometryReader { p in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(GaragePalette.neon))
                for i in 1...4 {
                    let y = size.height * CGFloat(i) / 6
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.08)))
                }
                var floor = Path()
                floor.move(to: CGPoint(x: 0, y: size.height * 0.72))
                floor.addLine(to: CGPoint(x: size.width, y: size.height * 0.60))
                floor.addLine(to: CGPoint(x: size.width, y: size.height))
                floor.addLine(to: CGPoint(x: 0, y: size.height)); floor.closeSubpath()
                context.fill(floor, with: .color(GaragePalette.indigo))
                var bay = Path()
                bay.move(to: CGPoint(x: size.width * 0.13, y: size.height * 0.84))
                bay.addLine(to: CGPoint(x: size.width * 0.73, y: size.height * 0.71))
                bay.addLine(to: CGPoint(x: size.width * 0.9, y: size.height * 0.90))
                context.stroke(bay, with: .color(GaragePalette.paper.opacity(0.5)), lineWidth: 2)
            }
            Text("DRIVE / MOTOR CLUB").font(.system(size: 9, weight: .black)).tracking(2)
                .foregroundStyle(GaragePalette.midnight.opacity(0.55)).position(x: p.size.width / 2, y: 24)
        }.clipShape(RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false)
    }
}

struct GameButtonStyle: ButtonStyle {
    var color: Color = GaragePalette.indigo
    var ink: Color = GaragePalette.paper
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        content(configuration: configuration, enabled: enabled)
    }
    func content(configuration: Configuration, enabled: Bool) -> some View {
        configuration.label.font(GameType.display(compact ? 17 : 23, relativeTo: .headline))
            .foregroundStyle(ink).padding(.horizontal, compact ? 12 : 20)
            .frame(minHeight: compact ? 44 : 54)
            .background(color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14), lineWidth: 1.5))
            .compositingGroup()
            .shadow(color: .black.opacity(0.65), radius: 0, y: configuration.isPressed ? 1 : 4)
            .offset(y: configuration.isPressed ? 3 : 0).opacity(enabled ? 1 : 0.45)
    }
}
struct AmberActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        GameButtonStyle(color: GaragePalette.amberTop, ink: GaragePalette.midnight)
            .content(configuration: configuration, enabled: enabled)
    }
}
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
}
struct GameProgress: View {
    let value: Double
    var color: Color = GaragePalette.neon
    var body: some View {
        GeometryReader { p in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(GaragePalette.midnight)
                RoundedRectangle(cornerRadius: 3).fill(color)
                    .frame(width: max(0, (p.size.width - 4) * min(max(value, 0), 1))).padding(2)
            }
        }.frame(height: 10).accessibilityHidden(true)
    }
}
struct CoinLabel: View {
    let amount: Int
    var iconColor: Color = GaragePalette.amberTop
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.inset.filled").foregroundStyle(iconColor)
            Text(amount.formatted()).monospacedDigit()
        }.font(.system(.subheadline, weight: .heavy))
        .accessibilityLabel("\(amount) coins")
    }
}
struct GameSheetHeader: View {
    let title: String
    let close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(GameType.display(28))
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44) }
                .buttonStyle(GameButtonStyle(compact: true)).accessibilityLabel("Close")
        }.foregroundStyle(GaragePalette.paper).padding(20)
    }
}
