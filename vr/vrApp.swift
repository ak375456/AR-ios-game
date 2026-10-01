//
//  vrApp.swift
//  vr
//
//  Created by aftab fazal qayum on 27/09/2026.
//

import SwiftUI
import UIKit

@main
struct vrApp: App {
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--drive-ui-preview") {
                    DrivingUXPreview()
                } else if ProcessInfo.processInfo.arguments.contains("--garage-ui-preview") { GarageUXPreview() }
                else { ContentView() }
                #else
                ContentView()
                #endif
            }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    // Repainted textures are large and cheap to rebuild.
                    PaintShop.shared.purge()
                }
        }
    }
}
