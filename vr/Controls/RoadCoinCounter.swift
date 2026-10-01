//
//  RoadCoinCounter.swift
//  vr
//
//  The arcade-style tally of coins picked up this drive.
//

import SwiftUI

/// A coin and a running total. Each pickup bounces the coin, ticks the number
/// and floats a "+N" away; rare coins flash cyan.
struct RoadCoinCounter: View {
    let total: Int
    let pickup: RoadCoinPickup?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = false

    var body: some View {
        HStack(spacing: 7) {
            CoinGlyph(diameter: 26)
                .scaleEffect(bounce ? 1.28 : 1)
                .rotation3DEffect(.degrees(bounce && !reduceMotion ? 180 : 0), axis: (x: 0, y: 1, z: 0))
            Text(total.formatted())
                .font(GameType.display(24))
                .monospacedDigit()
                .foregroundStyle(GaragePalette.paper)
                .contentTransition(.numericText(value: Double(total)))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.leading, 9)
        .padding(.trailing, 14)
        .frame(height: 44)
        .background(GaragePalette.midnight.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(flashColor.opacity(bounce ? 0.95 : 0.3), lineWidth: 1.5))
        .shadow(color: flashColor.opacity(bounce ? 0.6 : 0), radius: 8)
        .overlay(alignment: .bottomTrailing) {
            if let pickup {
                FloatingGain(pickup: pickup, reduceMotion: reduceMotion)
                    .id(pickup.serial)
                    .offset(x: -8, y: 26)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: total)
        .onChange(of: pickup) { _, _ in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { bounce = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bounce = false }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(total) road coins this drive")
    }

    private var flashColor: Color { pickup?.rare == true ? GaragePalette.neon : GaragePalette.amberTop }
}

/// "+N" that rises and fades.
private struct FloatingGain: View {
    let pickup: RoadCoinPickup
    let reduceMotion: Bool
    @State private var risen = false

    var body: some View {
        Text("+\(pickup.coins)")
            .font(GameType.display(pickup.rare ? 22 : 18))
            .foregroundStyle(pickup.rare ? GaragePalette.neon : GaragePalette.amberTop)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .offset(y: risen && !reduceMotion ? 16 : 0)
            .opacity(risen ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { risen = true }
            }
    }
}

/// A small gold coin drawn in SwiftUI, matching the ones on the floor.
struct CoinGlyph: View {
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(GaragePalette.amberBottom)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.93, blue: 0.6), GaragePalette.amberTop, GaragePalette.amberBottom],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: diameter * 0.6))
                .padding(diameter * 0.07)
            Circle()
                .strokeBorder(GaragePalette.amberBottom.opacity(0.7), lineWidth: diameter * 0.07)
                .padding(diameter * 0.17)
            Image(systemName: "star.fill")
                .font(.system(size: diameter * 0.32, weight: .black))
                .foregroundStyle(GaragePalette.amberBottom)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}
