//
//  DrivingInput.swift
//  vr
//
//  The bridge between the on-screen controls and the simulation.
//

import Foundation

/// Mutable control state shared by the control pad and the render loop.
///
/// This is deliberately *not* observable: the pad writes into it many times a
/// second while fingers are down, and the simulation samples it once per frame.
/// Routing that through SwiftUI's observation machinery would re-render the
/// interface on every touch move for no benefit.
final class DrivingInput {

    /// -1 (full left) ... +1 (full right).
    var steering: Float = 0
    /// 0 ... 1
    var throttle: Float = 0
    /// 0 ... 1 — brake while moving forward, reverse once stopped.
    var brake: Float = 0
    /// 0 ... 1 — scrubs grip off the rear so the car will slide.
    var handbrake: Float = 0

    /// Who picks the forward gears. Changed from the settings screen, read by
    /// the simulation every step, and deliberately not something that touches
    /// the car's velocity — switching mid-corner changes who is shifting and
    /// nothing else.
    var transmissionMode: TransmissionMode = .automatic

    /// Shift taps waiting to be taken by the simulation.
    ///
    /// Counted rather than sampled as a held state: the physics runs in fixed
    /// steps and the render loop can skip one, so a tap sampled as a flag can
    /// be missed or read twice. A counter drained once per advance moves the
    /// gearbox exactly once per tap, however hard the screen is being tapped.
    private(set) var pendingShiftUp = 0
    private(set) var pendingShiftDown = 0

    func requestShiftUp() { pendingShiftUp += 1 }
    func requestShiftDown() { pendingShiftDown += 1 }

    /// Hands the pending taps to the simulation and clears them.
    func takeShiftRequests() -> (up: Int, down: Int) {
        defer { pendingShiftUp = 0; pendingShiftDown = 0 }
        return (pendingShiftUp, pendingShiftDown)
    }

    /// False whenever driving is not allowed: before placement, while ARKit has
    /// lost its place, or while the app is not in front of the user.
    var isEnabled: Bool = false {
        didSet { if !isEnabled { releaseAll() } }
    }

    func releaseAll() {
        steering = 0
        throttle = 0
        brake = 0
        handbrake = 0
        pendingShiftUp = 0
        pendingShiftDown = 0
    }
}
