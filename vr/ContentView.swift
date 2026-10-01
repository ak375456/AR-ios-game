import SwiftUI

private struct DriveLaunch: Identifiable {
    let id = UUID()
    let car: CarDefinition
    let paint: CarPaint
    let parts: CarParts
}

struct ContentView: View {
    @State private var progression = ProgressionModel()
    @State private var settings = ControlSettings()
    @State private var launch: DriveLaunch?
    @State private var showSummary = false
    @State private var showTestDrive = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let launch {
                DriveContainerView(car:launch.car,paint:launch.paint,settings:settings,
                                   progression:progression,parts:launch.parts) {
                    progression.endSession(); progression.endTrial(); self.launch = nil
                    showSummary = !progression.sessionRewards.isEmpty
                }.id(launch.id)
            } else {
                HomeView(progression:progression,settings:settings,onPlay:start)
            }
        }.preferredColorScheme(.dark)
            .animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:launch?.id)
            .sheet(isPresented:$showSummary) { SessionSummaryView(progression:progression) }
            .alert("Career update",isPresented:Binding(get:{progression.error != nil},set:{if !$0 {progression.clearError()}})) {
                Button("OK") { progression.clearError() }
            } message: { Text(progression.error ?? "") }
            .fullScreenCover(isPresented:$showTestDrive) {
                TestDriveOfferView(car:CarCatalog.car(id:ProgressionCatalog.trialCar),
                                   onStart:{ showTestDrive = false; startTrial() },
                                   onSkip:{ progression.introduce(); showTestDrive = false })
            }
            .task {
                progression.refreshDay()
                if progression.shouldOfferTestDrive { showTestDrive = true }
            }
            .onChange(of:scenePhase) { _, phase in
                if phase == .active { progression.refreshDay() } else { progression.flush() }
            }
    }
    private func startTrial() {
        let id = ProgressionCatalog.trialCar
        guard progression.isAvailable else { return }
        progression.beginTrial(carID:id)
        launch = DriveLaunch(car:CarCatalog.car(id:id),paint:.factory,parts:.maximum)
    }
    private func start(_ id: String) {
        guard progression.canDrive(id) else { return }
        progression.manualGearbox = settings.transmissionMode == .manual
        progression.select(id); progression.beginSession(carID:id)
        launch = DriveLaunch(car:CarCatalog.car(id:id),paint:progression.paint(id),parts:progression.parts(id))
    }
}
