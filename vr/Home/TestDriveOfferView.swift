import SwiftUI

/// Shown once on a fresh install: a free, fully upgraded drive of the Drift Coupe.
struct TestDriveOfferView: View {
    let car: CarDefinition
    let onStart: () -> Void
    let onSkip: () -> Void
    @State private var previewStatus: CarPreviewStatus = .loading
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let slant = CGAffineTransform(a: 1, b: 0, c: -0.2, d: 1, tx: 0, ty: 0)
    private static let ink = Color(red: 0.03, green: 0.06, blue: 0.10)

    var body: some View {
        VStack(spacing: 0) {
            brand.padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("ONE-TIME TEST DRIVE").font(.footnote.weight(.heavy)).tracking(2.5).foregroundStyle(GaragePalette.neon)
                Text("MEET YOUR\n\(car.displayName.uppercased())")
                    .font(GameType.display(58, relativeTo: .largeTitle)).foregroundStyle(GaragePalette.paper)
                    .lineSpacing(-10).minimumScaleFactor(0.6).lineLimit(2)
                    .transformEffect(Self.slant)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 22)
            hero.frame(maxHeight: .infinity)
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "wrench.fill").font(.title2).foregroundStyle(GaragePalette.neon)
                    Rectangle().fill(GaragePalette.paper.opacity(0.35)).frame(width: 1, height: 34)
                    Text("FULLY UPGRADED").font(.headline.weight(.heavy)).tracking(3)
                }
                Rectangle().fill(GaragePalette.muted.opacity(0.35)).frame(height: 1).padding(.horizontal, 30)
                Text("Scan your floor. Place your car.\nMake your first drift.")
                    .font(.title3.weight(.medium)).foregroundStyle(GaragePalette.muted).multilineTextAlignment(.center)
            }.padding(.horizontal, 24)
            VStack(spacing: 4) {
                Button(action: onStart) {
                    HStack {
                        Text("LET'S DRIVE").font(GameType.display(30)).transformEffect(Self.slant)
                        Spacer().frame(width: 28)
                        Image(systemName: "arrow.right").font(.title2.weight(.bold))
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(AmberActionStyle())
                Button(action: onSkip) {
                    Text("Skip test drive").font(.body.weight(.medium)).underline().frame(maxWidth: .infinity, minHeight: 44)
                }.foregroundStyle(GaragePalette.paper.opacity(0.85))
                Text("One-time offer · Skipping dismisses this test drive.")
                    .font(.footnote).foregroundStyle(GaragePalette.muted.opacity(0.75)).multilineTextAlignment(.center)
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 10)
        }
        .foregroundStyle(GaragePalette.paper)
        .background(Self.ink.ignoresSafeArea())
        .buttonStyle(.plain)
        .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 14)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { appeared = true } }
    }

    private var brand: some View {
        VStack(spacing: 8) {
            Image(systemName: "flag.checkered").font(.system(size: 34, weight: .heavy)).foregroundStyle(GaragePalette.neon)
            Text("DRIVE / MOTOR CLUB").font(.footnote.weight(.heavy)).tracking(4)
        }.accessibilityElement(children: .combine)
    }

    /// Cyan slashes behind the car, a wet floor and the drift marks it just left.
    private var hero: some View {
        GeometryReader { p in
            let w = p.size.width, h = p.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.62)); path.addLine(to: CGPoint(x: w, y: h * 0.18))
                    path.addLine(to: CGPoint(x: w, y: h * 0.50)); path.addLine(to: CGPoint(x: w * 0.82, y: h * 0.44))
                    path.addLine(to: CGPoint(x: w, y: h * 0.62)); path.addLine(to: CGPoint(x: 0, y: h * 0.86))
                    path.closeSubpath()
                }.fill(GaragePalette.neon)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.40)); path.addLine(to: CGPoint(x: w * 0.30, y: h * 0.30))
                    path.addLine(to: CGPoint(x: 0, y: h * 0.50)); path.closeSubpath()
                }.fill(GaragePalette.neon.opacity(0.85))
                LinearGradient(colors: [.clear, Color(red: 0.07, green: 0.16, blue: 0.24)], startPoint: .top, endPoint: .bottom)
                    .frame(height: h * 0.55).frame(maxHeight: .infinity, alignment: .bottom)
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        Ellipse().stroke(GaragePalette.paper.opacity(0.28 - Double(i) * 0.07),
                                         style: StrokeStyle(lineWidth: 5 - CGFloat(i), lineCap: .round, dash: [2, 7]))
                            .frame(width: w * (0.9 + CGFloat(i) * 0.08), height: h * (0.34 + CGFloat(i) * 0.04))
                    }
                }.offset(x: w * 0.04, y: h * 0.30)
                CarPreviewView(car: car, paint: .factory) { previewStatus = $0 }
                    .padding(.horizontal, 6).accessibilityLabel(car.displayName)
                if previewStatus == .loading { ProgressView().tint(.white) }
            }
        }
        .clipped().frame(minHeight: 260)
    }
}
