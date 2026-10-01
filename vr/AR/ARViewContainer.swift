//
//  ARViewContainer.swift
//  vr
//
//  Hosts the RealityKit ARView inside SwiftUI.
//

import RealityKit
import SwiftUI

/// Thin bridge to `ARDriveController`, which owns the view and everything in it.
struct ARViewContainer: UIViewRepresentable {

    let controller: ARDriveController

    func makeUIView(context: Context) -> ARView {
        controller.makeARView()
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // All scene updates are driven by the render loop in ARDriveController.
    }
}
