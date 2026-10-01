//
//  SceneOcclusion.swift
//  vr
//
//  What this iPhone can do about hiding the car behind real things.
//

import ARKit
import Foundation
import RealityKit

/// The three ways the car can end up behind something real, and which of them
/// this particular iPhone can actually manage.
///
/// Each is a separate capability with a separate test, because they come from
/// different hardware:
///
/// - **Scene mesh** needs a LiDAR scanner. ARKit reconstructs the room as a
///   triangle mesh and RealityKit renders it depth-only, so anything real
///   hides anything virtual behind it, automatically and everywhere.
/// - **People** needs only a fast neural engine, so it works on every iPhone
///   this app runs on. ARKit segments people out of the camera image *with a
///   depth estimate*, so a hand or a leg in front of the car hides the car,
///   and behind it does not.
/// - **Manual occluders** need nothing at all and are the fallback: the player
///   marks out the real furniture by hand. See `ManualOccluders`.
///
/// Nothing here guesses from the device model — `ARWorldTrackingConfiguration`
/// is asked directly, so a device that gains or loses a capability is handled
/// by ARKit rather than by a lookup table that would go stale.
struct OcclusionCapabilities: Equatable {

    /// A LiDAR scanner reconstructing the room as geometry.
    let hasSceneMesh: Bool

    /// Person segmentation that also estimates how far away the person is.
    ///
    /// The depth-aware variant matters: plain `.personSegmentation` always
    /// draws people in front of the virtual content, which looks wrong the
    /// moment someone walks *behind* the car.
    let hasPeopleDepth: Bool

    static let current = OcclusionCapabilities(
        hasSceneMesh: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
        hasPeopleDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)
    )

    /// True when the room itself is understood without the player marking it.
    var understandsRoomAutomatically: Bool { hasSceneMesh }

    /// How the settings screen describes the scene mesh.
    var sceneMeshSummary: String {
        hasSceneMesh
            ? "Real walls and furniture hide the car automatically."
            : "Needs a LiDAR scanner — this iPhone doesn't have one."
    }

    /// How the settings screen describes people occlusion.
    var peopleSummary: String {
        hasPeopleDepth
            ? "People in front of the car hide it; behind it they don't."
            : "Not available on this iPhone."
    }
}

extension ARWorldTrackingConfiguration {

    /// Turns on every occlusion source this device has.
    ///
    /// Called once, while the configuration is being built, so the session is
    /// never re-run just to change occlusion: re-running a world-tracking
    /// configuration is what duplicates reconstructed mesh anchors and makes
    /// tracking hiccup.
    func enableOcclusion(_ capabilities: OcclusionCapabilities) {
        if capabilities.hasSceneMesh {
            sceneReconstruction = .mesh
        }
        if capabilities.hasPeopleDepth {
            frameSemantics.insert(.personSegmentationWithDepth)
        }
    }
}

extension ARView {

    /// Turns depth-only rendering of the reconstructed room on or off.
    ///
    /// Safe to call at any moment: this changes how RealityKit draws, never
    /// what the session is doing, so the room is not re-scanned and no mesh
    /// anchor is duplicated. That split is why the room-scan switch in
    /// settings costs nothing — the scanning stays on, only the drawing stops.
    ///
    /// People occlusion is not configured here at all: that one is driven
    /// entirely by the frame semantic, and RealityKit composites it for us.
    func setSceneMeshOcclusion(_ isEnabled: Bool) {
        if isEnabled {
            environment.sceneUnderstanding.options.insert(.occlusion)
        } else {
            environment.sceneUnderstanding.options.remove(.occlusion)
        }
    }
}
