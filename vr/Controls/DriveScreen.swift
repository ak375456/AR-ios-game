import SwiftUI

/// Camera first. All floating chrome shares the controls' safe-area coordinates.
struct DriveScreen: View {
    @Bindable var model: ARExperienceModel
    let onExit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focused = false
    @State private var sheet: DriveSheet?
    @State private var afterSheet: (() -> Void)?

    init(model: ARExperienceModel, onExit: @escaping () -> Void) {
        self.model = model; self.onExit = onExit
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--drive-ui-preview") {
            _focused = State(initialValue: args.contains("--focus"))
            _sheet = State(initialValue: args.contains("--menu") ? (args.contains("--tools") ? .tools : args.contains("--all-missions") ? .allMissions : .missions) : nil)
        }
        #endif
    }

    var body: some View {
        ZStack {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--drive-ui-preview") {
                LinearGradient(colors: [Color(white: 0.48), Color(white: 0.25)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                Text("AR layout preview").font(.caption).foregroundStyle(.white.opacity(0.4)).allowsHitTesting(false)
            } else { ARViewContainer(controller: model.controller).ignoresSafeArea() }
            #else
            ARViewContainer(controller: model.controller).ignoresSafeArea()
            #endif
            if isDriving {
                DrivingControlsView(state: model.controlPad, input: model.controller.input,
                    layout: model.settings.layout, isEnabled: model.canDrive,
                    usesHaptics: model.settings.usesHaptics,
                    showsShifter: model.settings.transmissionMode == .manual)
            }
            GeometryReader { proxy in
                let placement = overlayLayout(in: proxy.size)
                if isEditing { editorHeader.frame(width: proxy.size.width).padding(.top, 8) }
                if !isEditing, let frame = placement.toolbar {
                    Group {
                        if !model.isCarPlaced {
                            GlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "Back to garage", diameter: 44, action: onExit)
                        } else if focused { focusButton }
                        else { toolsButton }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
                if let frame = placement.instruments {
                    InstrumentCluster(instruments: model.instruments,
                        style: placement.compactInstruments ? .digital : model.settings.instrumentStyle,
                        availableWidth: frame.width)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                if let frame = placement.coins {
                    RoadCoinCounter(total: model.roadCoins, pickup: model.lastRoadCoin)
                        .frame(width: frame.width, height: frame.height, alignment: .trailing)
                        .position(x: frame.midX, y: frame.midY)
                }
                if let frame = placement.status {
                    statusLine.frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }

                #if DEBUG && targetEnvironment(simulator)
                Color.clear.allowsHitTesting(false).onAppear {
                    if ProcessInfo.processInfo.arguments.contains("--drive-ui-preview") {
                        DrivingUIAudit.record(size: proxy.size, layout: placement, settings: model.settings, driving: isDriving, editing: isEditing)
                    }
                }
                #endif

            }
            if model.isEditingOccluders { OccluderEditorView(model: model) }
            if model.isEditingCourse { CourseEditorView(model: model) }
            problemCard
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: focused)
        .onChange(of: model.settings.speedUnit) { _, _ in model.syncSpeedUnit() }
        .onChange(of: model.settings.smokeStyle) { _, _ in model.syncSmokeStyle() }
        .onChange(of: model.settings.transmissionMode) { _, _ in model.syncTransmissionMode() }
        .onChange(of: sheet) { _, value in
            if value != nil { model.controller.setOverlayPresented(true) }
        }
        .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } }), onDismiss: {
            model.progression.refreshDriveMissions()
            model.controller.setOverlayPresented(false)
            let action = afterSheet; afterSheet = nil; action?()
        }) {
            pauseSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .onAppear { model.controller.setOverlayPresented(true) }
        }

    }

    /// Completed cards stay in `driveMissions` until Resume swaps them for new ones.
    private var hasCompletedMission: Bool {
        model.progression.driveMissions.contains { model.progression.progress($0).completed }
    }
    private var isEditing: Bool { model.isEditingCourse || model.isEditingOccluders }
    private var isDriving: Bool { model.isCarPlaced && !isEditing }
    private var showsStatus: Bool {
        model.guidance != nil || model.capture.isRecording || model.capture.status != .idle
            || model.challenges.phase == .countdown
    }

    private func overlayLayout(in size: CGSize) -> DriveOverlayLayout {
        let controls: [CGRect] = isDriving ? ControlKind.allCases.filter {
            !$0.isManualOnly || model.settings.transmissionMode == .manual
        }.map { kind in
            var frame = model.settings.layout.frame(for: kind, in: size)
            // GEAR is drawn above the touch rectangle, so reserve its ink too.
            if kind == .shifter { frame.origin.y -= 12; frame.size.height += 12 }
            // Include UIKit's expanded touch targets, not only the visible ink.
            return kind == .steering ? frame.insetBy(dx: -44, dy: -26) : frame.insetBy(dx: -12, dy: -12)
        } : []
        let instrumentSize = isDriving && !focused ? InstrumentCluster.footprint(
            style: model.settings.instrumentStyle, width: min(size.width-32, 230)) : nil
        let pedalTop = [ControlKind.steering, .brake, .throttle]
            .map { model.settings.layout.frame(for: $0, in: size).minY }.min() ?? size.height
        return DriveOverlayLayout(size: size, controls: controls, focused: focused,
            instrumentSize: instrumentSize, instrumentY: pedalTop-12-(instrumentSize?.height ?? 0)/2,
            showsStatus: showsStatus && !isEditing,
            showsGoal: false,
            statusHeight: model.capture.isRecording && (model.guidance != nil || model.challenges.phase == .countdown) ? 112 : 76,
            showsCoins: isDriving && !focused)
    }

    private var editorHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            if let guidance = model.guidance {
                GuidancePill(text: guidance, isWarning: model.isGuidanceAWarning)
                    .lineLimit(3).frame(maxWidth: .infinity)
            }
            if model.isEditingCourse {
                GlassCircleButton(systemImage: "camera.fill", accessibilityLabel: "Take a photo", diameter: 44,
                    isEnabled: !model.capture.isCapturingPhoto, action: model.capturePhoto)
                recordButton
            }
        }.padding(.horizontal, 16).dynamicTypeSize(...DynamicTypeSize.large)
    }
    private var toolsButton: some View {
        GlassCircleButton(systemImage: "pause.fill", accessibilityLabel: hasCompletedMission ? "Pause. A mission is complete" : "Pause and view missions",
            diameter: 44, isHighlighted: hasCompletedMission) { sheet = .missions }
    }
    private var focusButton: some View {
        GlassCircleButton(systemImage: focused ? "eye" : "eye.slash",
            accessibilityLabel: focused ? "Show driving interface" : "Hide driving interface",
            diameter: 44) { focused.toggle() }
    }
    private var recordButton: some View {
        GlassCircleButton(systemImage: model.capture.isRecording ? "stop.fill" : "record.circle",
            accessibilityLabel: model.capture.isRecording ? "Stop recording" : "Record video",
            diameter: 44, tint: .red, isEnabled: model.capture.isVideoRecordingAvailable,
            action: model.toggleRecording)
    }
    private var statusLine: some View {
        VStack(spacing: 4) {
            if model.isGuidanceAWarning, let guidance = model.guidance {
                GuidancePill(text: guidance, isWarning: true).lineLimit(2)
            } else if model.challenges.phase == .countdown {
                Text("READY  \(model.challenges.countdown)")
                    .font(.system(.title2, design: .rounded, weight: .black).monospacedDigit())
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
            } else if let guidance = model.guidance {
                GuidancePill(text: guidance, isWarning: model.isGuidanceAWarning).lineLimit(2)
            }
            if model.capture.isRecording {
                Button(action: model.toggleRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                        Text("\(Int(model.capture.recordingDuration))s").monospacedDigit()
                    }.font(.caption.bold()).padding(.horizontal, 14).frame(height: 44)
                        .background(.black.opacity(0.65), in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel("Stop recording")
            } else if !model.isGuidanceAWarning { CaptureToast(status: model.capture.status).lineLimit(2) }
        }.dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var pauseSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if sheet != .missions {
                    Button { sheet = .missions } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("Back to this drive's missions")
                }
                Text(sheet == .tools ? "Tools" : sheet == .allMissions ? "All missions" : "Missions")
                    .font(GameType.display(30)).frame(maxWidth: .infinity, alignment: .leading)
                if sheet == .missions {
                    Button { sheet = .tools } label: { Label("Tools", systemImage: "wrench.fill") }
                        .buttonStyle(GameButtonStyle(compact: true))
                }
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 12)
            if sheet == .tools {
                ScrollView { tools.padding(18) }
            } else if sheet == .allMissions {
                MissionsView(progression: model.progression, carID: model.car.id, onStart: { _ in })
            } else if model.progression.trialCarID == model.car.id {
                VStack(spacing: 10) {
                    Image(systemName: "flag.checkered").font(.system(size: 40)).foregroundStyle(GaragePalette.amberTop)
                    Text("Test drive").font(GameType.display(26))
                    Text("Fully upgraded, just for today. Slide it as hard as you like.")
                        .font(.subheadline).foregroundStyle(GaragePalette.muted).multilineTextAlignment(.center)
                }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        HStack {
                            Text("THIS DRIVE").font(.caption.weight(.black)).tracking(1)
                            Spacer()
                            let done = model.progression.driveMissions.filter { model.progression.progress($0).completed }.count
                            Label("\(done) / \(model.progression.driveMissions.count)", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.heavy)).foregroundStyle(GaragePalette.success)
                        }.foregroundStyle(GaragePalette.muted)
                        ForEach(model.progression.driveMissions) { mission in
                            PauseMissionCard(mission: mission, progress: model.progression.progress(mission))
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        }
                        Button { sheet = .allMissions } label: {
                            HStack {
                                Text("All missions")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.font(.subheadline.weight(.bold)).frame(minHeight: 44)
                        }.accessibilityLabel("View career, daily and car mastery missions")
                    }.padding(.horizontal, 18).padding(.bottom, 8)
                }
                .task(id: sheet) { await swapCompletedMissions() }
            }
            HStack(spacing: 12) {
                Button { performAfterSheet(onExit) } label: { Text("Garage").frame(maxWidth: .infinity) }
                    .buttonStyle(GameButtonStyle())
                Button(action: resume) { Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(AmberActionStyle())
            }.padding(18).background(GaragePalette.deepIndigo)
        }.buttonStyle(.plain).foregroundStyle(GaragePalette.paper).background(GaragePalette.midnight)
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("SET THE SCENE").font(.caption.weight(.heavy)).foregroundStyle(GaragePalette.muted)
            VStack(spacing: 2) {
                tool("Reset car", icon: "arrow.counterclockwise", enabled: model.isCarPlaced) { performAfterSheet(model.resetCar) }
                tool("Move car", icon: "move.3d", enabled: model.isCarPlaced) { performAfterSheet(model.repositionCar) }
                tool(model.course.count > 0 ? "Edit course" : "Build course", icon: "cone.fill", enabled: model.canBuildCourse) { performAfterSheet(model.startCourseEditing) }
                if model.settings.showsOccluderTool {
                    tool("Real objects", icon: "cube.transparent", enabled: !model.capture.isRecording) { performAfterSheet { model.setOccluderEditing(true) } }
                }
                tool("Clean view", icon: "eye.slash") { performAfterSheet { focused = true } }
            }
            Text("CAPTURE").font(.caption.weight(.heavy)).foregroundStyle(GaragePalette.muted)
            HStack(spacing: 12) {
                Button { performAfterSheet(model.capturePhoto) } label: { Label("Photo", systemImage: "camera.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(GameButtonStyle(compact: true)).disabled(model.capture.isCapturingPhoto)
                Button { performAfterSheet(model.toggleRecording) } label: { Label(model.capture.isRecording ? "Stop" : "Video", systemImage: "record.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(GameButtonStyle(compact: true)).disabled(!model.capture.isVideoRecordingAvailable)
            }

        }.foregroundStyle(GaragePalette.paper)
    }
    private func tool(_ title: String, icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(GaragePalette.neon).frame(width: 26)
                Text(title).font(.body.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(GaragePalette.muted)
            }.padding(.horizontal, 14).frame(minHeight: 50)
                .background(GaragePalette.indigo, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
    /// Opening the pause menu shows the finished card for a beat, then it fades
    /// into the next mission while the player watches.
    private func swapCompletedMissions() async {
        guard sheet == .missions, hasCompletedMission else { return }
        try? await Task.sleep(for: .seconds(1.4))
        guard !Task.isCancelled, sheet == .missions else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.0)) { model.progression.refreshDriveMissions() }
    }
    /// On the missions list, let finished cards fade out and their replacements
    /// fade in before the sheet closes; anywhere else just close.
    private func resume() {
        guard sheet == .missions, hasCompletedMission, !reduceMotion else { sheet = nil; return }
        withAnimation(.easeInOut(duration: 0.9)) { model.progression.refreshDriveMissions() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            sheet = nil
        }
    }
    private func performAfterSheet(_ action: @escaping () -> Void) {
        afterSheet = action
        sheet = nil
    }

    // MARK: - Recoverable problems

    @ViewBuilder
    private var problemCard: some View {
        if let assetError = model.assetError {
            ErrorCard(
                title: "Car unavailable",
                message: assetError,
                actionTitle: "Try again",
                action: model.retryAssetLoad
            )
        } else if model.hasFatalSessionError {
            ErrorCard(
                title: "AR stopped",
                message: "The augmented reality session ran into a problem. Restarting usually fixes it.",
                actionTitle: "Restart AR",
                action: model.restartSession
            )
        }
    }
}

private enum DriveSheet: String, Identifiable {
    case missions, allMissions, tools
    var id: String { rawValue }
}
