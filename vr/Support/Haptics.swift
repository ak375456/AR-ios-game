//
//  Haptics.swift
//  vr
//
//  Thin wrapper so haptics stay deliberate and easy to audit.
//

import UIKit

/// Haptics are used only for things the user cannot otherwise feel:
/// placing the car, resetting it, building a course, the car hitting part of
/// it, picking up a road coin, and the result of a capture.
enum Haptics {

    /// A knock from the course, scaled by how hard it was: a barrier is a
    /// hard thud, a tyre a heavy bump, a cone a soft tap.
    static func impact(_ impact: CourseImpact) {
        switch impact {
        case .barrier(let strength):
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: CGFloat(0.45 + 0.55 * strength))
        case .tyre(let strength):
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: CGFloat(0.35 + 0.5 * strength))
        case .cone(let strength):
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: CGFloat(0.35 + 0.5 * strength))
        }
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func placement() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
