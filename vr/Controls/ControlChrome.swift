//
//  ControlChrome.swift
//  vr
//
//  Shared look for the controls that float over the camera feed.
//

import SwiftUI

/// A small translucent circular button, sized for a fingertip.
struct GlassCircleButton: View {

    let systemImage: String
    var accessibilityLabel: String
    var diameter: CGFloat = 40
    var tint: Color = .white
    var isEnabled: Bool = true
    /// Gold fill that asks for attention, e.g. a finished mission is waiting.
    var isHighlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.42, weight: isHighlighted ? .bold : .medium))
                .foregroundStyle(isHighlighted ? GaragePalette.amberInk : tint)
                .frame(width: diameter, height: diameter)
                .background(isHighlighted
                    ? AnyShapeStyle(LinearGradient(colors: [GaragePalette.amberTop, GaragePalette.amberBottom], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(GaragePalette.midnight.opacity(0.88)), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                    isHighlighted ? GaragePalette.amberTop : GaragePalette.paper.opacity(0.3), lineWidth: 1.5))
                .shadow(color: isHighlighted ? GaragePalette.amberTop.opacity(0.7) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The same glass chrome with a short word beside the icon, for an action whose
/// symbol alone would be ambiguous. Drops to icon-only when its slot is narrow.
struct GlassLabelButton: View {

    let title: String
    let systemImage: String
    var accessibilityLabel: String
    var height: CGFloat = 44
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage).font(.system(size: 16, weight: .bold))
                    Text(title).font(.subheadline.weight(.bold)).lineLimit(1)
                }.padding(.horizontal, 12)
                Image(systemName: systemImage).font(.system(size: height * 0.42, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(GaragePalette.midnight.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(GaragePalette.paper.opacity(0.3), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The floating status line above the scene.
struct GuidancePill: View {

    let text: String
    let isWarning: Bool

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(GaragePalette.midnight.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(
                    isWarning ? Color.orange.opacity(0.65) : Color.white.opacity(0.16),
                    lineWidth: isWarning ? 1 : 0.5
                )
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Feedback for a photo or video that is being saved.
struct CaptureToast: View {

    let status: SceneCapture.Status

    var body: some View {
        if let content {
            Label {
                Text(content.text)
            } icon: {
                if content.isBusy {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: content.symbol)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(GaragePalette.midnight.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
    }

    private var content: (text: String, symbol: String, isBusy: Bool)? {
        switch status {
        case .idle:                 return nil
        case .busy(let message):    return (message, "clock", true)
        case .success(let message): return (message, "checkmark.circle.fill", false)
        case .failure(let message): return (message, "exclamationmark.triangle.fill", false)
        }
    }
}

/// Red dot and running time, so it is never unclear that recording is live.
struct RecordingIndicator: View {

    let duration: TimeInterval
    @State private var isBlinking = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(isBlinking ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isBlinking)
            Text(Self.format(duration))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(GaragePalette.midnight.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { isBlinking = true }
        .accessibilityLabel("Recording, \(Int(duration)) seconds")
    }

    private static func format(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
