#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Simulator-only fixtures render the shipping views without starting AR or
/// touching a player's save. Never present in a device or Release build.
struct DrivingUXPreview: View {
    @State private var model: ARExperienceModel
    init() {
        let args = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults(suiteName: "DriveAR.UIFixtures")!
        defaults.removePersistentDomain(forName: "DriveAR.UIFixtures")
        // Exercise the legacy decoder against actual persisted UIKit geometry.
        if args.contains("--legacy") {
            var saved = ControlLayout.standard
            saved.handbrake.anchor = CGPoint(x: 0.118, y: 0.34)
            defaults.set(try! JSONEncoder().encode(saved), forKey: "controls.layout")
            defaults.set("analog", forKey: "drive.instrumentStyle")
        }
        let settings = ControlSettings(defaults: defaults)
        if args.contains("--legacy") {
            precondition(settings.layout.handbrake.anchor.y == 0.34 && settings.instrumentStyle == .analog)
        }
        settings.usesHaptics = false
        if args.contains("--analog") { settings.instrumentStyle = .analog }
        if args.contains("--manual") { settings.transmissionMode = .manual }
        if args.contains("--moved") {
            settings.layout.handbrake = ControlPlacement(anchor: CGPoint(x: 0.12, y: 0.05), scale: 1.2)
            settings.layout.shifter = ControlPlacement(anchor: CGPoint(x: 0.80, y: 0.73), scale: 1.1)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UIFixture-\(UUID().uuidString)")
        let progression = ProgressionModel(directory: dir)
        progression.beginSession(carID: ProgressionCatalog.starter)
        // Reproduce the user's three completed starter missions.
        progression.consume(DrivingEvents(distance: 5, movingTime: 20, cleanTime: 20),
                            carID: ProgressionCatalog.starter, dt: 1, scoredChallenge: nil)
        if !args.contains("--completed") { progression.refreshDriveMissions() }
        if args.contains("--partial") {
            progression.consume(DrivingEvents(distance: 3, movingTime: 4, cleanTime: 24, brakeStops: 1), carID: ProgressionCatalog.starter, dt: 0.2, scoredChallenge: nil)
        }
        while let notification = progression.pendingNotification { progression.acknowledge(notification.id) }
        let model = ARExperienceModel(car: ProgressionCatalog.cars[0], paint: .factory,
            settings: settings, progression: progression, parts: CarParts())
        model.controller.onPlacementPhaseChange?(args.contains("--scanning") ? .searching : .placed)
        model.controller.onTrackingStatusChange?(args.contains("--recovery") ? .relocalizing : .normal)
        model.instruments.update(renderedSpeed: 0, readout: DrivetrainReadout(engineRPM: 900, redlineRPM: 7000, idleRPM: 900), maxRenderedSpeed: 0.9, unit: settings.speedUnit, mode: settings.transmissionMode, deltaTime: 1)
        if args.contains("--editor") { model.controller.onCourseEditingChange?(true) }
        _model = State(initialValue: model)
    }
    var body: some View {
        DriveScreen(model: model, onExit: {}).preferredColorScheme(.dark)
            .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--large-text") ? .accessibility2 : .large)
    }
}
struct GarageUXPreview: View {
    @State private var progression: ProgressionModel
    @State private var settings: ControlSettings
    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GarageFixture-\(UUID().uuidString)")
        var save = ProgressionSave()
        save.coins = ProcessInfo.processInfo.arguments.contains("--large-balance") ? 98765432 : 1280
        for m in MissionCatalog.career.prefix(3) { save.missions[m.id] = MissionProgress(value: m.target, completed: true) }
        let store = try! ProgressionStore(directory: dir); try! store.write(save)
        let progression = ProgressionModel(directory: dir)
        progression.refreshDay()
        _progression = State(initialValue: progression)
        let defaults = UserDefaults(suiteName: "DriveAR.GarageFixtures")!
        defaults.removePersistentDomain(forName: "DriveAR.GarageFixtures")
        _settings = State(initialValue: ControlSettings(defaults: defaults))
        precondition(UIFont(name: "LilitaOne", size: 24) != nil, "Bundled display font must render without fallback")
    }
    var body: some View {
        HomeView(progression: progression, settings: settings, onPlay: { _ in })
            .preferredColorScheme(.dark)
            .task { if ProcessInfo.processInfo.arguments.contains("--thumbnail-audit") { await auditThumbnails() } }
            .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--large-text") ? .accessibility2 : .large)
    }
    private func auditThumbnails() async {
        var images: [UIImage] = []
        for car in ProgressionCatalog.cars {
            guard let image = await CarThumbnailCache.shared.image(for: car) else { preconditionFailure("Missing thumbnail: \(car.id)") }
            images.append(image)
        }
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 1400)).image { context in
            UIColor(GaragePalette.paper).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1080, height: 1400))
            for (i, image) in images.enumerated() {
                let x = CGFloat(i % 4) * 270, y = CGFloat(i / 4) * 200
                image.draw(in: CGRect(x: x+15, y: y, width: 240, height: 173))
                let label = "\(i+1). \(ProgressionCatalog.cars[i].displayName)" as NSString
                label.draw(in: CGRect(x: x+12, y: y+174, width: 256, height: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: UIColor(GaragePalette.midnight)])
            }
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("all-cars.png")
        try? sheet.pngData()?.write(to: url, options: .atomic)
    }

}
#endif

#if DEBUG && targetEnvironment(simulator)
/// Records conservative rectangle coverage of the actual SwiftUI layout. It
/// counts every control/panel as opaque, including its transparent corners.
@MainActor enum DrivingUIAudit {
    static func record(size: CGSize, layout: DriveOverlayLayout, settings: ControlSettings, driving: Bool, editing: Bool) {
        let visible: [CGRect] = driving ? ControlKind.allCases.filter { !$0.isManualOnly || settings.transmissionMode == .manual }
            .map { settings.layout.frame(for: $0, in: size) } : []
        let panels = editing ? [] : [layout.toolbar, layout.status, layout.instruments].compactMap { $0 }
        precondition(layout.goal == nil, "Driving must never display mission panels")
        precondition(panels.allSatisfy { p in visible.allSatisfy { !$0.intersects(p) } }, "HUD must avoid controls")
        let area = (visible + panels).reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let clear = 1 - area / (size.width * size.height)
        if driving && !ProcessInfo.processInfo.arguments.contains("--moved") {
            precondition(clear >= 0.7, "Default driving HUD must leave 70% of safe area clear")
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DrivingUIAudit.json")
        var entries = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let key = ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " ")
        entries[key] = ["width": size.width, "height": size.height, "clearFraction": clear, "controlCount": visible.count, "missionPanel": false, "overlap": false, "font": UIFont(name: "LilitaOne", size: 24)?.fontName ?? "MISSING"]
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}
#endif
