//
//  DriveContainerView.swift
//  vr
//
//  Owns the AR experience for as long as the player is driving.
//

import SwiftUI

/// Wraps the AR screen with its permission and device checks, and tears the
/// session down when the player goes back to the garage.
struct DriveContainerView: View {

    let onExit: () -> Void

    @State private var model: ARExperienceModel
    @Environment(\.scenePhase) private var scenePhase

    init(car: CarDefinition, paint: CarPaint, settings: ControlSettings, progression: ProgressionModel, parts: CarParts,
         onExit: @escaping () -> Void) {
        self.onExit = onExit
        _model = State(initialValue: ARExperienceModel(car: car, paint: paint, settings: settings, progression: progression, parts: parts))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .task {
            await model.prepare()
            model.handleScenePhase(.active)
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
            // Permissions can change while the app is away.
            if phase == .active && model.availability != .ready {
                Task { await model.prepare() }
            }
        }
        .onDisappear { model.shutDown() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.availability {
        case .checking:
            ProgressView()
                .controlSize(.large)
                .tint(.white)

        case .unsupported:
            BlockerView(
                symbol: "arkit",
                title: "AR isn't available here",
                message: "This iPhone doesn't support the world tracking the game needs. Drive AR requires iOS 18 or later and ARKit world tracking.",
                actionTitle: "Back to the garage",
                action: onExit
            )

        case .cameraDenied:
            BlockerView(
                symbol: "video.slash",
                title: "Camera access is off",
                message: "The car is placed in the room in front of you, so the game needs the camera to see it. You can turn it back on in Settings.",
                actionTitle: "Open Settings",
                action: model.openSettings,
                secondaryTitle: "Back to the garage",
                secondaryAction: onExit
            )

        case .ready:
            DriveScreen(model: model, onExit: onExit)
        }
    }
}
