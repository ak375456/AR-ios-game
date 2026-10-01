//
//  ARExperienceModel.swift
//  vr
//
//  The state the interface reads, and the intents it sends back.
//

import ARKit
import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Single source of truth for the screen: device/permission availability, the
/// AR flow, and the wording shown to the user.
///
/// It owns the AR controller and the capture service but contains no ARKit or
/// rendering logic itself — that lives in `ARDriveController` and `CarRig`.
@MainActor
@Observable
final class ARExperienceModel {

    /// Whether the experience can run at all on this device, right now.
    enum Availability: Equatable {
        case checking
        case unsupported
        case cameraDenied
        case ready
    }

    private(set) var availability: Availability = .checking
    private(set) var placementPhase: PlacementPhase = .initializing
    private(set) var trackingStatus: TrackingStatus = .initializing
    private(set) var isSceneTooDark = false
    private(set) var assetError: String?
    /// Set when ARKit drops the car's anchor, so the user is told why it vanished.
    private(set) var placementLostNotice = false
    /// …and whether a course went with it.
    private(set) var placementLostCourse = false
    private(set) var isDrifting = false
    /// Set while the reticle is over somewhere the car cannot go.
    private(set) var carPlacementProblem: CarPlacementProblem?

    // MARK: - Road coins

    /// Coins picked up off the floor during this drive, for the HUD counter.
    private(set) var roadCoins = 0
    /// The latest pickup, so the counter can float its "+N".
    private(set) var lastRoadCoin: RoadCoinPickup?
    @ObservationIgnored private let coinSound = CoinSound()

    // MARK: - Course

    private(set) var isEditingCourse = false
    /// The props being loaded the first time Build Course is opened.
    private(set) var isPreparingCourse = false
    private(set) var course = CourseStatus()
    /// A short message about something that has just happened — a slalom
    /// added, or not fitting. Clears itself.
    private(set) var courseNotice: CourseNotice?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    // MARK: - Occlusion

    /// How many boxes the player has marked out.
    private(set) var occluderCount = 0
    /// The selected box's measurements, or `nil` when nothing is selected.
    /// Mirrored here so the editor's sliders follow selections made by tapping
    /// the scene as well as ones made in the panel.
    private(set) var selectedOccluder: [OccluderDimension: Float]?
    private(set) var isEditingOccluders = false

    /// What this iPhone can hide the car behind on its own.
    var occlusionCapabilities: OcclusionCapabilities { controller.occlusionCapabilities }

    /// Speed, gear and revs, for the cluster.
    var instruments: DriveInstruments { controller.instruments }

    @ObservationIgnored let controller: ARDriveController
    let capture = SceneCapture()
    /// What the control pad looks like. Kept here so the pad survives the
    /// interface being rebuilt.
    let controlPad = ControlPadState()

    let car: CarDefinition
    /// Layout, effects quality and haptics, shared with the garage.
    let settings: ControlSettings
    let progression: ProgressionModel
    var challenges: ChallengeCoordinator { controller.challenges }

    init(car: CarDefinition, paint: CarPaint, settings: ControlSettings, progression: ProgressionModel, parts: CarParts) {
        self.car = car
        self.settings = settings
        self.progression = progression
        self.controller = ARDriveController(car: car, paint: paint, progression: progression, parts: parts)
        controller.effectsQuality = settings.effectsQuality
        controller.smokeStyle = settings.smokeStyle
        controller.usesRoomScanOcclusion = settings.usesRoomScanOcclusion
        controller.speedUnit = settings.speedUnit
        controller.input.transmissionMode = settings.transmissionMode
        controller.onPlacementPhaseChange = { [weak self] phase in
            self?.placementPhase = phase
            if phase == .placed {
                self?.placementLostNotice = false
                self?.placementLostCourse = false
            }
        }
        controller.onTrackingStatusChange = { [weak self] status in
            self?.trackingStatus = status
        }
        controller.onSceneTooDarkChange = { [weak self] isDark in
            self?.isSceneTooDark = isDark
        }
        controller.onAssetError = { [weak self] message in
            self?.assetError = message
        }
        controller.onCarPlaced = { [weak self] in
            if self?.settings.usesHaptics ?? true { Haptics.placement() }
        }
        controller.onDriftingChange = { [weak self] drifting in
            self?.isDrifting = drifting
        }
        controller.onPlacementLost = { [weak self] courseWasCleared in
            self?.placementLostNotice = true
            self?.placementLostCourse = courseWasCleared
        }
        controller.onCarPlacementProblemChange = { [weak self] problem in
            self?.carPlacementProblem = problem
        }
        controller.onRoadCoin = { [weak self] coins, rare in
            guard let self else { return }
            roadCoins += coins
            lastRoadCoin = RoadCoinPickup(serial: (lastRoadCoin?.serial ?? 0) + 1, coins: coins, rare: rare)
            coinSound.play(rare: rare)
            guard settings.usesHaptics else { return }
            if rare { Haptics.success() } else { Haptics.light() }
        }
        controller.onCourseImpact = { [weak self] impact in
            guard self?.settings.usesHaptics ?? false else { return }
            Haptics.impact(impact)
        }
        controller.occluders.onChange = { [weak self] in
            self?.readOccluders()
        }
        controller.onCourseEditingChange = { [weak self] editing in
            self?.isEditingCourse = editing
        }
        controller.course.onStatusChange = { [weak self] status in
            self?.course = status
        }
        controller.course.onNotice = { [weak self] notice in
            self?.show(notice)
        }
        // Outlines are scaffolding; they never belong in a recording.
        capture.onRecordingChange = { [weak self] isRecording in
            self?.controller.setCapturing(isRecording)
        }
    }

    // MARK: - Availability

    /// Checks AR support and camera access, prompting for the camera the first
    /// time. Called once when the view appears.
    func prepare() async {
        guard progression.canLaunch(car.id) else { availability = .unsupported; return }
        guard ARWorldTrackingConfiguration.isSupported else {
            availability = .unsupported
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            availability = .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            availability = granted ? .ready : .cameraDenied
        default:
            availability = .cameraDenied
        }
    }

    // MARK: - Lifecycle

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            controller.setForeground(true)
            if availability == .ready { controller.startSession() }
        case .inactive:
            // A banner or the app switcher: stop the car, keep the session.
            controller.setForeground(false)
        case .background:
            progression.flush()
            controller.setForeground(false)
            capture.stopRecording()
            controller.pauseSession()
        @unknown default:
            controller.setForeground(false)
        }
    }

    // MARK: - Intents

    var isCarPlaced: Bool { placementPhase == .placed }

    var canDrive: Bool {
        isCarPlaced && trackingStatus.isUsable && assetError == nil && !isEditingOccluders && !isEditingCourse && !challenges.holdsControls
    }

    /// Build Course needs a car to build round. It is not offered while
    /// recording, because the editing aids would end up in the video.
    var canBuildCourse: Bool {
        isCarPlaced && assetError == nil && !capture.isRecording && !isPreparingCourse
    }

    /// Pushes changed settings through to the scene.
    ///
    /// The unit and the transmission mode are pushed the moment they change
    /// rather than waiting for the settings sheet to be dismissed, so switching
    /// either one is visible behind the sheet.
    func syncSettings() {
        controller.effectsQuality = settings.effectsQuality
        controller.smokeStyle = settings.smokeStyle
        controller.usesRoomScanOcclusion = settings.usesRoomScanOcclusion
        syncSpeedUnit()
        syncTransmissionMode()
    }

    func syncSpeedUnit() {
        controller.speedUnit = settings.speedUnit
    }

    func syncSmokeStyle() {
        controller.smokeStyle = settings.smokeStyle
    }

    /// Changing who does the shifting does not touch the car: the gearbox keeps
    /// the gear it is in and the vehicle keeps its velocity.
    func syncTransmissionMode() {
        controller.input.transmissionMode = settings.transmissionMode
        progression.manualGearbox = settings.transmissionMode == .manual
    }

    func resetCar() {
        controller.resetCar()
        if settings.usesHaptics { Haptics.light() }
    }

    func repositionCar() {
        placementLostNotice = false
        controller.repositionCar()
        if settings.usesHaptics { Haptics.light() }
    }

    func restartSession() {
        controller.restartSession()
    }

    func retryAssetLoad() {
        assetError = nil
        controller.retryAssetLoad()
    }

    /// A photo never shows the editing aids or the reticle: they are hidden,
    /// given a couple of frames to leave the screen, and brought back once the
    /// frame has been captured.
    func capturePhoto() {
        guard let arView = controller.arView, !capture.isCapturingPhoto else { return }
        controller.setTakingPhoto(true)
        let carInShot = controller.isCarPlaced
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            capture.capturePhoto(from: arView, onRendered: { [weak self] in
                self?.controller.setTakingPhoto(false)
            }, onCaptured: { [weak self] in
                guard let self, carInShot else { return }
                progression.recordPhoto(carID: car.id)
            })
        }
    }

    /// Recording shows the game, not the workshop: starting one while the
    /// course is being built finishes building first.
    func toggleRecording() {
        if !capture.isRecording && isEditingCourse {
            finishCourseEditing()
        }
        capture.toggleRecording()
    }

    // MARK: - Occluder intents

    func setOccluderEditing(_ editing: Bool) {
        guard editing != isEditingOccluders else { return }
        controller.setOccluderEditing(editing)
        isEditingOccluders = controller.isEditingOccluders
        readOccluders()
        if settings.usesHaptics { Haptics.light() }
    }

    func addOccluder() {
        guard controller.addOccluder() else { return }
        if settings.usesHaptics { Haptics.placement() }
    }

    func deleteOccluder() {
        controller.occluders.deleteSelected()
        if settings.usesHaptics { Haptics.light() }
    }

    func clearOccluders() {
        controller.occluders.removeAll()
        if settings.usesHaptics { Haptics.light() }
    }

    func setOccluder(_ value: Float, for dimension: OccluderDimension) {
        controller.occluders.setValue(value, for: dimension)
    }

    private func readOccluders() {
        occluderCount = controller.occluders.boxes.count
        if let box = controller.occluders.selected {
            selectedOccluder = Dictionary(uniqueKeysWithValues:
                OccluderDimension.allCases.map { ($0, box.value(for: $0)) })
        } else {
            selectedOccluder = nil
        }
    }

    // MARK: - Course intents

    /// Opens the course editor. The props load at the start of the session,
    /// so this is normally instant; the first time it may wait a moment.
    func startCourseEditing() {
        guard !isEditingCourse, canBuildCourse else { return }
        isPreparingCourse = true
        Task {
            await PropFactory.shared.prepare()
            isPreparingCourse = false
            guard canBuildCourse else { return }
            controller.setCourseEditing(true)
            // Opening the course editor closes the occluder editor.
            isEditingOccluders = controller.isEditingOccluders
            if isEditingCourse, settings.usesHaptics { Haptics.light() }
        }
    }

    /// Back to driving, with every prop where it was left.
    func finishCourseEditing() {
        guard isEditingCourse else { return }
        controller.setCourseEditing(false)
        dismissNotice()
        if settings.usesHaptics { Haptics.light() }
    }

    /// Picks a prop to place; picking the same one again puts it down.
    func selectCourseTool(_ kind: PropKind) {
        controller.selectCourseTool(course.tool == kind ? nil : kind)
        if settings.usesHaptics { Haptics.selection() }
    }

    func addSlalom() {
        controller.addSlalom()
    }

    /// Fifteen degrees at a time. Clockwise as seen from above is a turn
    /// towards negative yaw.
    func rotateSelectedProp(clockwise: Bool) {
        controller.rotateSelectedProp(by: (clockwise ? -15 : 15) * .pi / 180)
        if settings.usesHaptics { Haptics.selection() }
    }

    func duplicateSelectedProp() {
        controller.duplicateSelectedProp()
        if settings.usesHaptics { Haptics.light() }
    }

    func deleteSelectedProp() {
        controller.course.deleteSelected()
        if settings.usesHaptics { Haptics.light() }
    }

    func deselectProp() {
        controller.course.select(nil)
    }

    func undoCourse() {
        controller.course.undo()
        if settings.usesHaptics { Haptics.light() }
    }

    func clearCourse() {
        controller.clearCourse()
        if settings.usesHaptics { Haptics.light() }
    }

    private func show(_ notice: CourseNotice) {
        courseNotice = notice
        if notice.isWarning, settings.usesHaptics { Haptics.failure() }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(notice.isWarning ? 3.5 : 2.5))
            guard !Task.isCancelled else { return }
            self?.courseNotice = nil
        }
    }

    private func dismissNotice() {
        noticeTask?.cancel()
        courseNotice = nil
    }

    /// Stops everything before the screen goes away.
    func shutDown() {
        progression.endSession()
        setOccluderEditing(false)
        finishCourseEditing()
        noticeTask?.cancel()
        capture.stopRecording()
        controller.setForeground(false)
        controller.pauseSession()
        // Release every emitter, mark and entity this run created.
        controller.tearDown()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Wording

    /// The one line of guidance shown at the top of the screen, or `nil` when
    /// the user is simply driving and does not need to be told anything.
    var guidance: String? {
        if assetError != nil { return nil }
        if isEditingOccluders {
            return occluderCount == 0
                ? "Aim at a real object and tap Add."
                : "Drag a box to move it, or tap one to select it."
        }

        switch trackingStatus {
        case .failed:
            return "AR stopped unexpectedly."
        case .interrupted:
            return "AR is paused — come back to the app to keep driving."
        case .relocalizing:
            return isEditingCourse
                ? "Finding your space again — move slowly. Your course is safe."
                : "Finding your space again — move slowly."
        case .excessiveMotion:
            return "Move your iPhone more slowly"
        case .insufficientFeatures:
            if isEditingCourse, let courseGuidance { return courseGuidance }
            return "Aim at a textured part of the floor"
        case .initializing:
            return "Starting AR…"
        case .normal:
            if isEditingCourse, let courseGuidance { return courseGuidance }
            if isSceneTooDark {
                return "More light will help tracking"
            }
            switch placementPhase {
            case .initializing, .searching:
                if placementLostNotice {
                    return placementLostCourse
                        ? "Lost track of that spot, and the course with it — place the car again."
                        : "Lost track of that spot — tap a surface to place the car again."
                }
                return course.count > 0
                    ? "Aim at the floor by your course to put the car back."
                    : "Move slowly to find the floor"
            case .readyToPlace:
                switch carPlacementProblem {
                case .onCourse:       return "Too close to your course — aim at clear floor."
                case .awayFromCourse: return "Put the car on the same floor as your course, or clear it."
                case nil:
                    return placementLostNotice
                        ? "Tap to place the car again."
                        : "Tap to place your car"
                }
            case .placed:
                return nil
            }
        }
    }

    /// What to say while the course is being built: news first, then what is
    /// wrong with the spot, then what the next tap will do.
    private var courseGuidance: String? {
        if let courseNotice { return courseNotice.text }
        if let problem = course.problem { return problem.message }
        if course.isAdjusting { return "Let go to leave it here." }
        if let tool = course.tool {
            return "Aim at the floor, then tap to place a \(tool.title.lowercased())."
        }
        if course.selected != nil { return "Drag to move · twist two fingers to turn." }
        return course.count == 0
            ? "Pick a cone, barrier or tyre, or add a slalom."
            : "Tap a prop to select it, or pick one to add."
    }

    /// True when the guidance line is a problem rather than a prompt.
    var isGuidanceAWarning: Bool {
        switch trackingStatus {
        case .normal:
            if isEditingCourse { return course.problem != nil || courseNotice?.isWarning == true }
            if carPlacementProblem != nil && !isCarPlaced { return true }
            return isSceneTooDark
        case .initializing:
            return false
        case .insufficientFeatures where isEditingCourse:
            return course.problem != nil || courseNotice?.isWarning == true
        default:
            return true
        }
    }

    /// Shown when the AR session has failed outright and needs a restart.
    var hasFatalSessionError: Bool {
        if case .failed = trackingStatus { return true }
        return false
    }
}

/// One road-coin pickup, numbered so repeated equal values still animate.
struct RoadCoinPickup: Equatable {
    let serial: Int
    let coins: Int
    let rare: Bool
}
