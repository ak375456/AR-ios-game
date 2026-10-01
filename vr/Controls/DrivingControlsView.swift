//
//  DrivingControlsView.swift
//  vr
//
//  Draws the driving controls wherever the layout puts them.
//

import SwiftUI

struct DrivingControlsView: View {

    let state: ControlPadState
    let input: DrivingInput
    let layout: ControlLayout
    let isEnabled: Bool
    let usesHaptics: Bool
    /// Only Manual has gears to choose, so only Manual gets the buttons.
    let showsShifter: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ControlPadTouchLayer(state: state, input: input, layout: layout,
                                     isEnabled: isEnabled, usesHaptics: usesHaptics,
                                     showsShifter: showsShifter)
                ControlPadVisuals(steering: state.steering,
                                  pressed: pressedSet,
                                  frames: layout.frames(in: proxy.size),
                                  isEnabled: isEnabled,
                                  showsShifter: showsShifter,
                                  heldShift: state.heldShift)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Driving controls")
    }

    private var pressedSet: Set<ControlKind> {
        var pressed: Set<ControlKind> = []
        if state.isThrottleDown { pressed.insert(.throttle) }
        if state.isBrakeDown { pressed.insert(.brake) }
        if state.isHandbrakeDown { pressed.insert(.handbrake) }
        return pressed
    }
}

/// Pure presentation — every touch is handled by `ControlPadTouchView`.
struct ControlPadVisuals: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let steering: Float
    let pressed: Set<ControlKind>
    let frames: [ControlKind: CGRect]
    var isEnabled: Bool = true
    var showsShifter: Bool = false
    var heldShift: ShiftDirection?
    /// Highlights one control while the player is arranging the layout.
    var highlighted: ControlKind?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let frame = frames[.steering] { steeringPad(in: frame) }
            if showsShifter, let frame = frames[.shifter] { shifter(in: frame) }
            pedal(.handbrake, symbol: "hand.raised.fill", title: "Hand", tint: GaragePalette.amberTop)
            pedal(.brake, symbol: "arrowtriangle.down.fill", title: "Brake", tint: .orange)
            pedal(.throttle, symbol: "arrowtriangle.up.fill", title: "Go", tint: GaragePalette.neon)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isEnabled)
    }

    private func steeringPad(in frame: CGRect) -> some View {
        let knob = ControlPadGeometry.knobDiameter(in: frame)
        return ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(GaragePalette.midnight.opacity(0.86))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(borderColour(.steering), lineWidth: 1.5))

            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.22)).frame(width: 2, height: frame.height * 0.18)

            Circle()
                .fill(.white.opacity(0.94))
                .overlay(
                    Image(systemName: "steeringwheel")
                        .font(.system(size: knob * 0.44, weight: .medium))
                        .foregroundStyle(.black.opacity(0.7))
                        .rotationEffect(.degrees(Double(steering) * 38))
                )
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                .frame(width: knob, height: knob)
                .offset(x: CGFloat(steering) * ControlPadGeometry.steeringTravel(in: frame))
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.8), value: steering)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
    }

    /// The sequential lever: up on top, down below, each half a full-width
    /// button so neither needs looking at.
    private func shifter(in frame: CGRect) -> some View {
        let gap: CGFloat = 8
        let buttonHeight = (frame.height - gap) / 2
        return VStack(spacing: gap) {
            shiftButton(.up, symbol: "plus", height: buttonHeight, width: frame.width)
            shiftButton(.down, symbol: "minus", height: buttonHeight, width: frame.width)
        }
        .frame(width: frame.width, height: frame.height)
        .overlay(alignment: .top) {
            Text("GEAR")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.5))
                .offset(y: -12)
        }
        .overlay {
            if highlighted == .shifter {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2.5)
            }
        }
        .position(x: frame.midX, y: frame.midY)
    }

    private func shiftButton(_ direction: ShiftDirection, symbol: String,
                             height: CGFloat, width: CGFloat) -> some View {
        let isDown = heldShift == direction
        let tint = Color(red: 0.42, green: 0.78, blue: 1.0)
        return Image(systemName: symbol)
            .font(.system(size: width * 0.34, weight: .bold))
            .foregroundStyle(isDown ? Color.white : tint)
            .frame(width: width, height: height)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(GaragePalette.midnight.opacity(0.86))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(tint.opacity(isDown ? 0.75 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(tint.opacity(isDown ? 0.9 : 0.45), lineWidth: 1.5))
            }
            .scaleEffect(isDown ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isDown)
            .accessibilityLabel(direction == .up ? "Shift up" : "Shift down")
    }

    @ViewBuilder
    private func pedal(_ kind: ControlKind, symbol: String, title: String, tint: Color) -> some View {
        if let frame = frames[kind] {
            let isDown = pressed.contains(kind)
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: frame.width * 0.28, weight: .semibold))
                Text(title)
                    .font(.system(size: max(frame.width * 0.145, 8), weight: .semibold))
                    
                    .kerning(0.4)
            }
            .foregroundStyle(isDown ? Color.white : tint)
            .frame(width: frame.width, height: frame.height)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(GaragePalette.midnight.opacity(0.86))
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(isDown ? 0.75 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                        highlighted == kind ? Color.white : tint.opacity(isDown ? 0.9 : 0.45),
                        lineWidth: highlighted == kind ? 2.5 : 1.5))
            }
            .scaleEffect(isDown ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isDown)
            .position(x: frame.midX, y: frame.midY)
        }
    }

    private func borderColour(_ kind: ControlKind) -> Color {
        highlighted == kind ? .white : .white.opacity(0.16)
    }
}
