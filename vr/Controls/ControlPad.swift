//
//  ControlPad.swift
//  vr
//
//  Multi-touch driving controls, placed wherever the player put them.
//

import Observation
import SwiftUI
import UIKit

/// What the controls currently look like. Separate from `DrivingInput` so the
/// simulation can read raw values every frame while SwiftUI only redraws the
/// small views that actually changed.
@MainActor
@Observable
final class ControlPadState {
    var steering: Float = 0
    var isThrottleDown = false
    var isBrakeDown = false
    var isHandbrakeDown = false
    /// Which half of the gear shift is under a finger, for the pressed look.
    var heldShift: ShiftDirection?
}

/// The touch surface.
///
/// Driving needs two thumbs at once, and SwiftUI's gesture arbitration is not
/// built for that: a second finger landing on another control can cancel the
/// first, which leaves the accelerator stuck off until the finger moves again.
/// UIKit multi-touch tracks each finger independently and never loses one.
///
/// The view covers the whole screen so controls can be placed anywhere, but
/// `hitTest` only claims touches that land on a control — everything else
/// falls through to the AR view underneath, so tap-to-place still works.
final class ControlPadTouchView: UIView {

    private let state: ControlPadState
    private let input: DrivingInput

    private var assignments: [ObjectIdentifier: ControlKind] = [:]
    private var shiftAssignments: [ObjectIdentifier: ShiftDirection] = [:]
    private var steeringValue: Float = 0

    var layout: ControlLayout = .standard { didSet { publish() } }
    var usesHaptics = true

    /// The gear shift exists only in Manual. In Automatic it is not drawn, and
    /// this view does not claim touches where it would have been, so the AR
    /// view underneath keeps them.
    var showsShifter = false { didSet { if !showsShifter { releaseShifts() } } }

    var isDrivingEnabled = false {
        // A finger already resting on the accelerator must start working the
        // moment driving becomes possible again, without being lifted first.
        didSet { publish() }
    }

    /// Slop around each control, so a near miss still counts.
    private static let slop: CGFloat = 12
    /// The wheel gets a bigger catch area than the buttons.
    private static let steeringSlop = UIEdgeInsets(top: -26, left: -44, bottom: -26, right: -44)

    init(state: ControlPadState, input: DrivingInput) {
        self.state = state
        self.input = input
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Hit testing

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        control(at: point) == nil ? nil : self
    }

    private func control(at point: CGPoint) -> ControlKind? {
        let frames = layout.frames(in: bounds.size)
        // Buttons win over the wheel, whose catch area is the most generous.
        for kind in [ControlKind.handbrake, .brake, .throttle] {
            guard let frame = frames[kind] else { continue }
            if frame.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) { return kind }
        }
        if showsShifter, let frame = frames[.shifter],
           frame.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) {
            return .shifter
        }
        if let frame = frames[.steering], frame.inset(by: Self.steeringSlop).contains(point) {
            return .steering
        }
        return nil
    }

    /// Which half of the shift a touch landed on. Split down the middle, so a
    /// finger that lands between the two buttons still gets the nearer one.
    private func shiftDirection(at point: CGPoint) -> ShiftDirection? {
        guard let frame = layout.frames(in: bounds.size)[.shifter] else { return nil }
        return point.y < frame.midY ? .up : .down
    }

    // MARK: - Touch tracking

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let kind = control(at: point) else { continue }
            assignments[ObjectIdentifier(touch)] = kind
            if kind == .steering { updateSteering(from: touch) }
            if kind == .handbrake, isDrivingEnabled, usesHaptics { Haptics.light() }
            // A gear is taken the moment the finger lands, and exactly once per
            // landing however long it stays down. Repeated taps therefore
            // always move the gearbox, and a resting thumb never does.
            if kind == .shifter, let direction = shiftDirection(at: point) {
                shiftAssignments[ObjectIdentifier(touch)] = direction
                if isDrivingEnabled {
                    switch direction {
                    case .up:   input.requestShiftUp()
                    case .down: input.requestShiftDown()
                    }
                    if usesHaptics { Haptics.light() }
                }
            }
        }
        publish()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where assignments[ObjectIdentifier(touch)] == .steering {
            updateSteering(from: touch)
        }
        publish()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            assignments.removeValue(forKey: ObjectIdentifier(touch))
            shiftAssignments.removeValue(forKey: ObjectIdentifier(touch))
        }
        if !assignments.values.contains(.steering) { steeringValue = 0 }
        publish()
    }

    private func releaseShifts() {
        shiftAssignments.removeAll()
        for (id, kind) in assignments where kind == .shifter { assignments.removeValue(forKey: id) }
        publish()
    }

    private func updateSteering(from touch: UITouch) {
        guard let frame = layout.frames(in: bounds.size)[.steering] else { return }
        let travel = ControlPadGeometry.steeringTravel(in: frame)
        guard travel > 0 else { return }
        let offset = touch.location(in: self).x - frame.midX
        steeringValue = Float(min(max(offset / travel, -1), 1))
    }

    private func publish() {
        let held = Set(assignments.values)
        let steering = held.contains(.steering) ? steeringValue : 0

        state.steering = steering
        state.isThrottleDown = held.contains(.throttle)
        state.isBrakeDown = held.contains(.brake)
        state.isHandbrakeDown = held.contains(.handbrake)
        state.heldShift = shiftAssignments.values.first

        guard isDrivingEnabled else {
            input.releaseAll()
            return
        }
        input.steering = steering
        input.throttle = held.contains(.throttle) ? 1 : 0
        input.brake = held.contains(.brake) ? 1 : 0
        input.handbrake = held.contains(.handbrake) ? 1 : 0
    }
}

/// Shared geometry so the drawing and the hit testing cannot disagree.
enum ControlPadGeometry {
    static func knobDiameter(in frame: CGRect) -> CGFloat { frame.height * 0.74 }
    static func steeringTravel(in frame: CGRect) -> CGFloat {
        (frame.width - knobDiameter(in: frame)) / 2 - 4
    }
}

/// Puts the touch surface into SwiftUI.
struct ControlPadTouchLayer: UIViewRepresentable {

    let state: ControlPadState
    let input: DrivingInput
    let layout: ControlLayout
    let isEnabled: Bool
    let usesHaptics: Bool
    let showsShifter: Bool

    func makeUIView(context: Context) -> ControlPadTouchView {
        let view = ControlPadTouchView(state: state, input: input)
        view.layout = layout
        view.isDrivingEnabled = isEnabled
        view.usesHaptics = usesHaptics
        view.showsShifter = showsShifter
        return view
    }

    func updateUIView(_ uiView: ControlPadTouchView, context: Context) {
        if uiView.layout != layout { uiView.layout = layout }
        uiView.isDrivingEnabled = isEnabled
        uiView.usesHaptics = usesHaptics
        if uiView.showsShifter != showsShifter { uiView.showsShifter = showsShifter }
    }
}
