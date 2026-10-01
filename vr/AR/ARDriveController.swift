//
//  ARDriveController.swift
//  vr
//
//  Owns the ARKit session, the RealityKit scene and the per-frame update.
//

import ARKit
import Combine
import Foundation
import OSLog
import RealityKit
import UIKit
import simd

/// Where the user is in the place-the-car flow.
enum PlacementPhase: Equatable {
    case initializing, searching, readyToPlace, placed
}

/// What ARKit currently thinks of its own tracking.
enum TrackingStatus: Equatable {
    case initializing, normal, excessiveMotion, insufficientFeatures
    case relocalizing, interrupted
    case failed(String)

    /// Whether ARKit knows where it is well enough to keep driving.
    ///
    /// "Excessive motion" and "insufficient features" fire constantly while
    /// someone walks around a room holding a phone, and they do not mean the
    /// session has lost its place. Cutting the controls for those made the car
    /// stall every few seconds, so driving stops only for a real loss of
    /// tracking.
    var isUsable: Bool {
        switch self {
        case .normal, .excessiveMotion, .insufficientFeatures: return true
        case .initializing, .relocalizing, .interrupted, .failed: return false
        }
    }

    /// Tight enough to commit to a spot on the floor.
    var allowsPlacement: Bool { self == .normal || self == .insufficientFeatures }
}

/// Why the car cannot be put down where the player is aiming.
enum CarPlacementProblem: Equatable {
    /// On a different surface from the course that is already there.
    case awayFromCourse
    /// On top of, or too close to, a course prop.
    case onCourse
}

/// What the car just ran into, for haptics.
enum CourseImpact {
    case barrier(strength: Float)
    case cone(strength: Float)
    case tyre(strength: Float)
}

/// Bridges ARKit/RealityKit and the rest of the app.
///
/// The controller owns the one authoritative vehicle state. Nothing else moves
/// the car: the render loop advances the physics, reads an interpolated pose
/// out of it, and hands that pose to the rig and to the tyre effects.
///
/// The car and the course share one ARKit anchor, the *stage*. It is created
/// where the car is first put down and kept for as long as there is either a
/// car or a course standing on it, so moving the car never moves the course
/// and ARKit's refinements move both together.
@MainActor
final class ARDriveController: NSObject {

    // MARK: - Published state

    var onPlacementPhaseChange: ((PlacementPhase) -> Void)?
    var onTrackingStatusChange: ((TrackingStatus) -> Void)?
    var onSceneTooDarkChange: ((Bool) -> Void)?
    var onAssetError: ((String?) -> Void)?
    var onCarPlaced: (() -> Void)?
    var onPlacementLost: ((_ courseWasCleared: Bool) -> Void)?
    var onDriftingChange: ((Bool) -> Void)?
    var onCarPlacementProblemChange: ((CarPlacementProblem?) -> Void)?
    var onCourseImpact: ((CourseImpact) -> Void)?
    /// A road coin was picked up: its value, and whether it was a rare 5 or 10.
    var onRoadCoin: ((_ coins: Int, _ rare: Bool) -> Void)?
    /// Fired whenever course editing starts or stops, whoever stopped it —
    /// the player, a restart, or ARKit losing the anchor.
    var onCourseEditingChange: ((Bool) -> Void)?

    private(set) var placementPhase: PlacementPhase = .initializing {
        didSet {
            guard placementPhase != oldValue else { return }
            onPlacementPhaseChange?(placementPhase)
            refreshDrivingAvailability()
        }
    }

    private(set) var trackingStatus: TrackingStatus = .initializing {
        didSet {
            guard trackingStatus != oldValue else { return }
            onTrackingStatusChange?(trackingStatus)
            // Only a real loss of tracking drops a prop mid-drag; a moment of
            // "moving too fast" should not snatch it out of the player's hand.
            if !trackingStatus.isUsable { course.cancelAdjustment() }
            refreshDrivingAvailability()
        }
    }

    private(set) var isSceneTooDark = false {
        didSet {
            guard isSceneTooDark != oldValue else { return }
            onSceneTooDarkChange?(isSceneTooDark)
        }
    }

    /// Set while the reticle is over somewhere the car cannot go.
    private(set) var carPlacementProblem: CarPlacementProblem? {
        didSet {
            guard carPlacementProblem != oldValue else { return }
            onCarPlacementProblemChange?(carPlacementProblem)
        }
    }

    // MARK: - Collaborators

    /// Written by the control pad, read once per frame by the simulation.
    let input = DrivingInput()

    /// What the instrument cluster shows. Filled from the same vehicle state
    /// the car is drawn from, so the number on screen and the car under it can
    /// never disagree.
    let instruments = DriveInstruments()

    /// What the speedometer counts in. Read-out only: it is handed straight to
    /// the cluster and never reaches the simulation, which is why changing it
    /// cannot change how the car drives or which gear it is in.
    var speedUnit: SpeedUnit = .kilometresPerHour

    private(set) var arView: ARView?

    let car: CarDefinition
    private let paint: CarPaint

    /// The single authoritative vehicle state.
    private var vehicle: VehicleDynamics
    let challenges: ChallengeCoordinator
    private let progression: ProgressionModel
    private let launchParts: CarParts
    private var rig: CarRig?
    private let reticle = PlacementReticle()

    private let smoke = TireSmoke()
    private let skidMarks = SkidMarks()
    private let roadCoins = RoadCoins()
    var smokeStyle: SmokeStyle = .default {
        didSet { smoke.setStyle(smokeStyle) }
    }
    var effectsQuality: EffectsQuality = .full {
        didSet {
            skidMarks.isEnabled = effectsQuality.showsSkidMarks
            if !effectsQuality.showsSkidMarks { skidMarks.clear() }
            if !effectsQuality.showsSmoke { smoke.stopEmitting() }
        }
    }

    /// Hand-placed occluders, for iPhones that cannot map the room themselves.
    let occluders = ManualOccluders()
    let occlusionCapabilities = OcclusionCapabilities.current

    private(set) var isEditingOccluders = false
    private var isDraggingOccluder = false

    /// Cones, barriers and tyres the player lays out on the floor.
    let course = CourseBuilder()
    private(set) var isEditingCourse = false {
        didSet {
            guard isEditingCourse != oldValue else { return }
            onCourseEditingChange?(isEditingCourse)
        }
    }
    private var isDraggingProp = false
    private var isTwistingProp = false
    /// Detected floor is re-read a few times a second while editing, not
    /// every frame: the outlines grow slowly and each read copies them.
    private var surfaceCache: (time: Float, surfaces: DetectedSurfaces)?

    private var isRecording = false
    private var isTakingPhoto = false

    /// Whether the LiDAR room mesh is allowed to hide things. Off means the
    /// room is still scanned, just not drawn into the depth buffer.
    var usesRoomScanOcclusion = true {
        didSet {
            guard usesRoomScanOcclusion != oldValue else { return }
            arView?.setSceneMeshOcclusion(usesRoomScanOcclusion && occlusionCapabilities.hasSceneMesh)
        }
    }

    /// The anchor the car and the course stand on.
    private var stageAnchor: ARAnchor?
    private var stageEntity: AnchorEntity?
    private var isCarOnStage = false

    /// Built once and kept, so resuming never rebuilds the configuration and
    /// ARKit never re-reconstructs the room into a second set of mesh anchors.
    private var configuration: ARWorldTrackingConfiguration?

    private var updateSubscription: Cancellable?
    private var carLoadGeneration = 0
    private var isLoadingCar = false
    private var isForeground = true
    private var overlayPresented = false
    private var challengeUsable = false
    private var isRunning = false
    private var wantsSession = false
    private var hasStartedOnce = false
    private var elapsed: Float = 0
    private var framesSinceLightCheck = 0
    private var lastValidHit: SIMD3<Float>?
    private var wasDrifting = false
    private var lastImpactTime: Float = -1

    /// Smoothed body lean, for looks only.
    private var bodyRoll: Float = 0
    private var bodyPitch: Float = 0

    init(car: CarDefinition, paint: CarPaint, progression: ProgressionModel, parts: CarParts) {
        self.progression = progression
        self.launchParts = parts
        self.challenges = ChallengeCoordinator(progression: progression, carID: car.id)
        self.car = car
        self.paint = paint
        // Replaced with the rig's measured tuning once the model has loaded.
        self.vehicle = VehicleDynamics(
            tuning: VehicleTuning.make(carClass: car.carClass, length: car.length,
                                       wheelBase: car.length * 0.55,
                                       trackWidth: car.length * 0.44,
                                       wheelRadius: car.length * 0.115))
        super.init()
        roadCoins.onCollect = { [weak self] coins, rare in
            guard let self, self.progression.collectRoadCoins(coins, carID: self.car.id) else { return }
            self.onRoadCoin?(coins, rare)
        }
        roadCoins.onMiss = { [weak self] in
            guard let self else { return }
            self.progression.missedRoadCoin(carID: self.car.id)
        }
    }

    var isCarPlaced: Bool { isCarOnStage }

    /// The course can be built once there is a car to build it round.
    var canBuildCourse: Bool { isCarPlaced && PropFactory.shared.isReady }

    // MARK: - View lifecycle

    func makeARView() -> ARView {
        if let existing = arView { return existing }

        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        // Set once, from what this device can actually do.
        view.environment.sceneUnderstanding.options = []
        view.setSceneMeshOcclusion(usesRoomScanOcclusion && occlusionCapabilities.hasSceneMesh)

        view.session.delegateQueue = .main
        view.session.delegate = self
        view.scene.addAnchor(reticle.anchor)
        occluders.attach(to: view)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)

        // One finger moves things; two fingers turn them. Keeping the pan to a
        // single touch stops a twist from also dragging the prop around.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist(_:)))
        twist.delegate = self
        view.addGestureRecognizer(twist)

        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.update(deltaTime: Float(event.deltaTime))
        }

        arView = view
        loadCarIfNeeded()
        // The props are small; load them now so the course is ready the
        // moment anyone asks for it, and never mid-drive.
        Task { await PropFactory.shared.prepare() }

        // The session may have been requested before SwiftUI built the view.
        if wantsSession { startSession() }
        return view
    }

    /// Releases everything this controller put in the scene.
    func tearDown() {
        carLoadGeneration += 1; isLoadingCar = false
        smoke.detach()
        skidMarks.detach()
        setOccluderEditing(false)
        setCourseEditing(false)
        occluders.removeAll()
        removeCar()
        removeStage()
        updateSubscription?.cancel()
        updateSubscription = nil
        arView?.session.pause()
        arView?.session.delegate = nil
        arView = nil
        isRunning = false
        wantsSession = false
    }

    // MARK: - Session control

    func startSession() {
        wantsSession = true
        guard let arView, !isRunning, ARWorldTrackingConfiguration.isSupported else { return }

        let configuration = self.configuration ?? makeConfiguration()
        self.configuration = configuration

        // On a cold start throw everything away. When coming back from the
        // background, keep the existing anchors so ARKit can relocalise and the
        // car and its course stay where the user left them.
        let options: ARSession.RunOptions = hasStartedOnce ? [] : [.resetTracking, .removeExistingAnchors]
        arView.session.run(configuration, options: options)

        hasStartedOnce = true
        isRunning = true
        if placementPhase == .initializing { placementPhase = .searching }
        refreshDrivingAvailability()
    }

    /// The one place the session is described. Occlusion is part of it, so it
    /// is decided here, once, rather than switched on later by re-running the
    /// session — which is what duplicates reconstructed mesh anchors.
    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        configuration.isLightEstimationEnabled = true
        configuration.enableOcclusion(occlusionCapabilities)

        let mesh = occlusionCapabilities.hasSceneMesh
        let people = occlusionCapabilities.hasPeopleDepth
        AppLog.session.info("Occlusion — scene mesh: \(mesh, privacy: .public), people: \(people, privacy: .public)")
        return configuration
    }

    func pauseSession() {
        wantsSession = false
        guard isRunning else { return }
        isRunning = false
        haltCar()
        reticle.hide()
        course.cancelAdjustment()
        arView?.session.pause()
        refreshDrivingAvailability()
    }

    /// Driving is only allowed while the app is actually in front of the user;
    /// a notification banner or the app switcher stops the car immediately
    /// without tearing the session down.
    func setForeground(_ active: Bool) {
        guard isForeground != active else { return }
        isForeground = active
        if !active {
            haltCar()
            reticle.hide()
            course.cancelAdjustment()
        }
        refreshDrivingAvailability()
    }

    func setOverlayPresented(_ presented: Bool) {
        overlayPresented = presented
        refreshDrivingAvailability()
    }

    /// Full restart: used by the "try again" path after a session failure.
    func restartSession() {
        hasStartedOnce = false
        isRunning = false
        // A restart resets tracking and drops every anchor, so the boxes and
        // the course that were standing on those anchors go with it.
        setOccluderEditing(false)
        setCourseEditing(false)
        occluders.removeAll()
        removeCar()
        removeStage()
        trackingStatus = .initializing
        placementPhase = .initializing
        startSession()
    }

    /// Stops the car dead and clears anything mid-slide, so returning from the
    /// background never resumes into a physics jump.
    private func haltCar() {
        input.releaseAll()
        vehicle.halt()
        instruments.clear()
        smoke.stopEmitting()
        if let rig { rig.apply(vehicle.state, roll: 0, pitch: 0) }
        bodyRoll = 0
        bodyPitch = 0
        if wasDrifting { wasDrifting = false; onDriftingChange?(false) }
    }

    // MARK: - Asset loading

    private func loadCarIfNeeded() {
        guard rig == nil, !isLoadingCar else { return }
        isLoadingCar = true; carLoadGeneration += 1
        let generation = carLoadGeneration
        Task {
            defer { if generation == carLoadGeneration { isLoadingCar = false } }
            do {
                let loaded = try await CarRig.load(car: car, paint: paint)
                guard generation == carLoadGeneration, arView != nil else { return }
                rig = loaded
                // The physics now uses the geometry measured from the mesh.
                vehicle = VehicleDynamics(tuning: EffectiveTuning.resolve(base: loaded.tuning, carID: car.id, parts: launchParts))
                course.contacts.carHalfExtents = loaded.collisionHalfExtents
                course.contacts.carHeight = loaded.bodySize.y
                onAssetError?(nil)
                prewarmRendering(loaded)
            } catch {
                guard generation == carLoadGeneration else { return }
                AppLog.asset.error("Car model failed to load: \(error.localizedDescription, privacy: .public)")
                onAssetError?(error.localizedDescription)
            }
        }
    }

    // MARK: - Render warm-up

    private var warmAnchor: AnchorEntity?

    /// The first time RealityKit draws a model it compiles its shaders and uploads
    /// its textures, which used to freeze the camera for seconds at the moment the
    /// player tapped to place the car. Drawing the car once while they are still
    /// scanning moves that cost to a time nobody is waiting: it hangs a speck-sized
    /// copy in front of the camera, then takes it down again.
    private func prewarmRendering(_ rig: CarRig) {
        guard let arView, warmAnchor == nil, !isCarPlaced else { return }
        let anchor = AnchorEntity(.camera)
        rig.root.position = SIMD3(0, 0, -0.5)
        rig.root.scale = SIMD3(repeating: 0.001)
        anchor.addChild(rig.root)
        arView.scene.addAnchor(anchor)
        warmAnchor = anchor
        Task {
            for color in smokeStyle.activeColors { _ = await EffectTextures.smokePuff(color: color) }
            _ = await EffectTextures.skidFadeRamp()
            try? await Task.sleep(for: .seconds(1.5))
            endPrewarm()
        }
    }

    private func endPrewarm() {
        guard let anchor = warmAnchor else { return }
        warmAnchor = nil
        rig?.root.removeFromParent()
        rig?.root.scale = .one
        arView?.scene.removeAnchor(anchor)
    }

    func retryAssetLoad() { loadCarIfNeeded() }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let arView else { return }
        let point = gesture.location(in: arView)

        // While marking out the room a tap picks a box rather than placing the
        // car; tapping empty space clears the selection.
        if isEditingOccluders {
            occluders.select(occluders.box(near: point)?.id)
            return
        }

        if isEditingCourse {
            handleCourseTap(at: point)
            return
        }

        guard rig != nil, !isCarPlaced, trackingStatus.allowsPlacement else { return }
        // Prefer exactly what the user tapped; fall back to the reticle so a
        // tap slightly off the detected surface still does the obvious thing.
        guard let position = raycast(from: point) ?? lastValidHit else { return }
        if let problem = carProblem(at: position, heading: placementHeading(at: position)) {
            carPlacementProblem = problem
            Haptics.failure()
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        place(at: position)
        AppLog.asset.info("Placing the car took \(ProcessInfo.processInfo.systemUptime - started, format: .fixed(precision: 3)) s")
    }

    /// Drags a box or a prop across the floor, while editing.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let arView else { return }
        let point = gesture.location(in: arView)

        if isEditingOccluders {
            switch gesture.state {
            case .began:
                // Only a drag that starts on a box moves anything, so a stray
                // swipe across the room never teleports the selection.
                guard let box = occluders.box(near: point) else { return }
                occluders.select(box.id)
                isDraggingOccluder = true
            case .changed:
                guard isDraggingOccluder, let position = raycast(from: point) else { return }
                occluders.dragSelected(to: position)
            case .ended, .cancelled, .failed:
                guard isDraggingOccluder else { return }
                isDraggingOccluder = false
                occluders.endDrag()
            default:
                break
            }
            return
        }

        guard isEditingCourse else { return }
        switch gesture.state {
        case .began:
            // The recogniser fires after the finger has already moved a
            // little; the prop that matters is the one it came down on.
            let travel = gesture.translation(in: arView)
            let start = CGPoint(x: point.x - travel.x, y: point.y - travel.y)
            guard trackingStatus.allowsPlacement else { return }
            isDraggingProp = course.beginDrag(at: start, in: arView, floor: floorHit(from: start)?.world)
            if isDraggingProp { dragProp(to: point) }
        case .changed:
            guard isDraggingProp else { return }
            dragProp(to: point)
        case .ended:
            guard isDraggingProp else { return }
            isDraggingProp = false
            course.endAdjustment()
        case .cancelled, .failed:
            guard isDraggingProp else { return }
            isDraggingProp = false
            course.cancelAdjustment()
        default:
            break
        }
    }

    private func dragProp(to point: CGPoint) {
        let hit = floorHit(from: point)
        course.drag(to: hit?.world, onDetectedPlane: hit?.onDetectedPlane ?? false,
                    environment: courseEnvironment(fresh: false))
    }

    /// Turns the selected prop with two fingers.
    @objc private func handleTwist(_ gesture: UIRotationGestureRecognizer) {
        guard isEditingCourse else { return }
        switch gesture.state {
        case .began:
            guard !isDraggingProp, trackingStatus.allowsPlacement else { return }
            isTwistingProp = course.beginTwist()
        case .changed:
            guard isTwistingProp else { return }
            course.twist(by: Float(gesture.rotation), environment: courseEnvironment(fresh: false))
        case .ended:
            guard isTwistingProp else { return }
            isTwistingProp = false
            course.endAdjustment()
        case .cancelled, .failed:
            guard isTwistingProp else { return }
            isTwistingProp = false
            course.cancelAdjustment()
        default:
            break
        }
    }

    // MARK: - Occluders

    /// Enters or leaves the mode where the player marks out real furniture.
    ///
    /// Editing and driving are exclusive: the car is stopped and the controls
    /// are cut while boxes are being placed, so nobody is steering blind.
    func setOccluderEditing(_ editing: Bool) {
        guard isEditingOccluders != editing else { return }
        if editing {
            guard endChallenge() else { return }
            setCourseEditing(false)
        }
        isEditingOccluders = editing
        occluders.isEditing = editing
        isDraggingOccluder = false
        if editing {
            haltCar()
        } else {
            occluders.select(nil)
            reticle.hide()
        }
        refreshDrivingAvailability()
    }

    /// Stands a new box where the reticle is.
    @discardableResult
    func addOccluder() -> Bool {
        guard isEditingOccluders, let position = raycastFromScreenCentre() ?? lastValidHit else { return false }
        occluders.add(at: position, facing: placementHeading(at: position))
        return true
    }

    /// Scaffolding stays out of a recording: while one is running, no editing
    /// aid is drawn at all.
    func setCapturing(_ capturing: Bool) {
        isRecording = capturing
        occluders.isCapturing = capturing
        refreshCaptureVisibility()
    }

    /// Hides the editing aids and the reticle for the one frame a photo is
    /// rendered from, then brings them back.
    func setTakingPhoto(_ taking: Bool) {
        isTakingPhoto = taking
        occluders.isCapturing = taking || isRecording
        if taking { reticle.hide() }
        refreshCaptureVisibility()
    }

    private func refreshCaptureVisibility() {
        course.overlaysSuppressed = isRecording || isTakingPhoto
    }

    // MARK: - Course

    /// Enters or leaves course editing.
    ///
    /// Editing and driving are exclusive, like the occluder editor: the car is
    /// stopped and the controls are cut, so a finger moving a cone can never
    /// also be steering.
    func setCourseEditing(_ editing: Bool) {
        guard isEditingCourse != editing else { return }
        if editing {
            guard endChallenge() else { return }
            guard canBuildCourse, let stageEntity else { return }
            setOccluderEditing(false)
            course.attach(to: stageEntity)
            showCarStart()
            isEditingCourse = true
            haltCar()
            roadCoins.clear()
            course.setEditing(true)
        } else {
            isDraggingProp = false
            isTwistingProp = false
            isEditingCourse = false
            course.setEditing(false)
            surfaceCache = nil
        }
        refreshDrivingAvailability()
    }

    /// Removes every prop. With no car on the floor the anchor has nothing
    /// left to hold, so it goes too and the car can be put down anywhere.
    func clearCourse() {
        course.clear()
        if !isCarPlaced && course.isEmpty { removeStage() }
        carPlacementProblem = nil
    }

    func selectCourseTool(_ kind: PropKind?) {
        guard isEditingCourse else { return }
        course.setTool(kind)
    }

    func addSlalom() {
        guard isEditingCourse, let rig else { return }
        let start = vehicle.state
        course.addSlalom(carPosition: start.position, carHeading: start.heading,
                         carHalfExtents: rig.collisionHalfExtents, carLength: rig.bodySize.z,
                         environment: courseEnvironment(fresh: true))
    }

    func rotateSelectedProp(by step: Float) {
        course.rotateSelected(by: step, environment: courseEnvironment(fresh: true))
    }

    func duplicateSelectedProp() {
        course.duplicateSelected(environment: courseEnvironment(fresh: true))
    }

    private func handleCourseTap(at point: CGPoint) {
        guard let arView else { return }
        if let id = course.prop(at: point, in: arView) {
            course.select(id)
            Haptics.light()
            return
        }
        if course.status.tool != nil {
            if course.placeAtAim(environment: courseEnvironment(fresh: true)) == nil {
                Haptics.placement()
            } else {
                Haptics.failure()
            }
        } else if course.status.selected != nil {
            course.select(nil)
        }
    }

    /// What the course needs to judge a spot: the detected floor at the
    /// course's height and the car's footprint where it is and where it starts.
    private func courseEnvironment(fresh: Bool) -> CourseEnvironment {
        CourseEnvironment(surfaces: detectedSurfaces(fresh: fresh),
                          carFootprints: carFootprints(),
                          trackingAllowsPlacement: trackingStatus.allowsPlacement && isForeground && isRunning)
    }

    private func detectedSurfaces(fresh: Bool) -> DetectedSurfaces {
        if !fresh, let cache = surfaceCache, elapsed - cache.time < 0.25 { return cache.surfaces }
        guard let stageEntity, let frame = arView?.session.currentFrame else { return DetectedSurfaces() }
        let surfaces = DetectedSurfaces(anchors: frame.anchors,
                                        height: stageEntity.position(relativeTo: nil).y,
                                        tolerance: CourseSpec.sameSurfaceTolerance + 0.01)
        surfaceCache = (elapsed, surfaces)
        return surfaces
    }

    private func carFootprints() -> [Footprint2D] {
        guard isCarPlaced, let rig else { return [] }
        let half = rig.collisionHalfExtents
        let start = vehicle.placement
        return [.box(OrientedBox2D(centre: vehicle.state.position, halfExtents: half, angle: vehicle.state.heading)),
                .box(OrientedBox2D(centre: start.position, halfExtents: half, angle: start.heading))]
    }

    private func showCarStart() {
        guard let rig else { return }
        let start = vehicle.placement
        course.setCarStart(position: start.position, heading: start.heading, halfExtents: rig.collisionHalfExtents)
    }

    /// Whether the car could be put down at `position`, facing the world
    /// heading `heading`, without landing on the course.
    private func carProblem(at position: SIMD3<Float>, heading: Float) -> CarPlacementProblem? {
        guard let stageEntity, !course.isEmpty, let rig else { return nil }
        let local = stageEntity.convert(position: position, from: nil)
        guard abs(local.y) <= CourseSpec.sameSurfaceTolerance else { return .awayFromCourse }
        let footprint = Footprint2D.box(OrientedBox2D(centre: SIMD2(local.x, local.z),
                                                      halfExtents: rig.collisionHalfExtents,
                                                      angle: stageHeading(fromWorld: heading)))
        for prop in course.layout where footprint.overlaps(prop.footprint, margin: CourseSpec.carClearance) {
            return .onCourse
        }
        return nil
    }

    /// Converts a world yaw into the stage's own.
    private func stageHeading(fromWorld heading: Float) -> Float {
        guard let stageEntity else { return heading }
        let direction = stageEntity.convert(direction: SIMD3(sin(heading), 0, cos(heading)), from: nil)
        return atan2(direction.x, direction.z)
    }

    // MARK: - Placement

    private func place(at position: SIMD3<Float>) {
        guard let arView, let rig else { return }

        let stage: AnchorEntity
        var start = SIMD2<Float>.zero
        var heading = placementHeading(at: position)

        if let existing = stageEntity {
            // A course is already standing here: the car joins it rather than
            // taking the course with it to a new anchor.
            stage = existing
            let local = existing.convert(position: position, from: nil)
            start = SIMD2(local.x, local.z)
            heading = stageHeading(fromWorld: heading)
        } else {
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(position, 1)

            // A real ARAnchor (rather than a fixed world transform) lets ARKit
            // keep refining where the floor is as it learns more about the room.
            let anchor = ARAnchor(name: "car-ground", transform: transform)
            arView.session.add(anchor: anchor)

            let anchorEntity = AnchorEntity(anchor: anchor)
            arView.scene.addAnchor(anchorEntity)
            stageAnchor = anchor
            stageEntity = anchorEntity
            stage = anchorEntity
        }

        endPrewarm()
        stage.addChild(rig.root)
        isCarOnStage = true
        roadCoins.attach(to: stage)

        vehicle.place(at: start, heading: heading)
        rig.apply(vehicle.state, roll: 0, pitch: 0)
        instruments.clear()

        // A fresh start is a fresh run: anything knocked over stands back up.
        if !course.isEmpty {
            course.putPropsBack()
            showCarStart()
        }

        // Effects hang off the anchor, not the car, so their particles and
        // marks stay in the world as the car drives away from them.
        Task {
            await smoke.attach(to: stage, rig: rig)
            await skidMarks.attach(to: stage, rig: rig)
            skidMarks.isEnabled = effectsQuality.showsSkidMarks
        }

        reticle.hide()
        carPlacementProblem = nil
        placementPhase = .placed
        onCarPlaced?()
    }

    /// Which way a car placed at `position` should face.
    ///
    /// This follows where the phone is *looking*, projected onto the ground,
    /// rather than the line from the viewer's feet to the car. Placing a car
    /// means tilting the phone down at the floor a step or two away, and at
    /// that angle the horizontal distance between viewer and car is short and
    /// noisy — so the old feet-to-car version could point the car off at an
    /// angle, and pressing the accelerator then sent it sideways across the
    /// room instead of away from you.
    private func placementHeading(at position: SIMD3<Float>) -> Float {
        let direction = viewDirection(towards: position)
        guard simd_length(direction) > 1e-5 else { return 0 }
        // Heading 0 faces +Z, so the yaw pointing along (x, z) is atan2 of the
        // X component over the Z component.
        return atan2(direction.x, direction.z)
    }

    /// Where the phone is looking, flattened onto the floor, in world space.
    private func viewDirection(towards position: SIMD3<Float>? = nil) -> SIMD3<Float> {
        guard let arView else { return SIMD3(0, 0, 1) }
        let camera = arView.cameraTransform
        let matrix = camera.matrix

        // The camera looks down its own -Z.
        var direction = SIMD2(-matrix.columns.2.x, -matrix.columns.2.z)

        // Looking almost straight down flattens that to nothing; the camera's
        // up vector then points the way the top of the phone is facing, which
        // is the same thing the user means by "forward".
        if simd_length(direction) < 0.12 {
            direction = SIMD2(matrix.columns.1.x, matrix.columns.1.z)
        }
        // Last resort: away from where the viewer is standing.
        if simd_length(direction) < 0.12, let position {
            direction = SIMD2(position.x - camera.translation.x, position.z - camera.translation.z)
        }
        guard simd_length(direction) > 1e-5 else { return .zero }
        direction = simd_normalize(direction)
        return SIMD3(direction.x, 0, direction.y)
    }

    /// Returns the car to where it was placed, still on the same anchor, and
    /// puts any knocked cones and tyres back on their marks. The course
    /// itself is left exactly as it was laid out.
    func resetCar() {
        guard isCarPlaced else { return }
        challenges.reset(reason: "Back at the start. Banked progress is safe.")
        input.releaseAll()
        vehicle.reset()
        instruments.clear()
        bodyRoll = 0
        bodyPitch = 0
        smoke.stopEmitting()
        skidMarks.clear()
        roadCoins.clear()
        rig?.apply(vehicle.state, roll: 0, pitch: 0)
        course.putPropsBack()
    }

    /// Picks the car up so the user can place it somewhere else. The course
    /// stays where it is.
    func repositionCar() {
        _ = endChallenge()
        challenges.reset(reason: "Place again to begin a fresh attempt.")
        setCourseEditing(false)
        removeCar()
        placementPhase = .searching
    }

    private func removeCar() {
        input.releaseAll()
        vehicle.halt()
        if wasDrifting { wasDrifting = false; onDriftingChange?(false) }

        smoke.detach()
        skidMarks.detach()
        roadCoins.detach()

        rig?.root.removeFromParent()
        rig?.resetPose()
        isCarOnStage = false

        // An empty stage has nothing to hold in place; the next car gets a
        // fresh anchor wherever it is put down.
        if course.isEmpty { removeStage() }
    }

    /// Drops the shared anchor, and with it the course.
    private func removeStage() {
        challenges.stageLost()
        course.tearDown()
        if let stageAnchor { arView?.session.remove(anchor: stageAnchor) }
        if let stageEntity { arView?.scene.removeAnchor(stageEntity) }
        stageAnchor = nil
        stageEntity = nil
        surfaceCache = nil
    }

    private var challengePreparation: UUID?
    private var nextCourseCheck: Float = 0

    /// A single entry point for a continuous course run. Regular driving goals
    /// do not require this mode or a temporary course.
    func beginCourseRun() {
        guard challenges.mission == nil, let next = progression.nextCourse(carID: car.id) else { return }
        progression.activate(next)
        challenges.select(next)
        nextCourseCheck = 0
    }

    /// Never replaces a hand-built course until the whole layout fits detected floor.
    func prepareChallenge(compact: Bool, autoStart: Bool = false) {
        guard isCarPlaced, let stageEntity, let rig, let mission = challenges.mission,
              trackingStatus.allowsPlacement, !isEditingCourse, !isEditingOccluders,
              !challenges.isRestoringCourse, challengePreparation == nil else { return }
        let request = UUID()
        challengePreparation = request
        Task { [weak self, weak stageEntity] in
            await PropFactory.shared.prepare()
            guard let self else { return }
            defer { if self.challengePreparation == request { self.challengePreparation = nil } }
            guard self.challengePreparation == request, let stageEntity, self.stageEntity === stageEntity,
                  self.isCarPlaced, self.challenges.mission?.id == mission.id,
                  !self.challenges.isRestoringCourse, self.trackingStatus.allowsPlacement,
                  !self.isEditingCourse, !self.isEditingOccluders,
                  !autoStart || self.canAdvanceCourse else { return }
            let start = self.vehicle.placement
            let layout = ChallengeLayout.make(mission: mission, length: rig.bodySize.z,
                width: rig.bodySize.x, speed: self.vehicle.tuning.topSpeed, origin: start.position,
                heading: start.heading, compact: compact)
            let surfaces = self.detectedSurfaces(fresh: true)
            guard layout.fits({ point in
                surfaces.contains(stageEntity.convert(position: SIMD3(point.x, 0, point.y), to: nil))
            }) else { self.challenges.cannotFit(); return }
            self.resetCar()
            self.challenges.install(layout, stage: stageEntity, course: self.course)
            if autoStart { self.challenges.start() }
            self.refreshDrivingAvailability()
        }
    }

    func startChallenge() {
        resetCar(); challenges.start(); refreshDrivingAvailability()
    }

    @discardableResult func endChallenge() -> Bool {
        challengePreparation = nil
        let surfaces = detectedSurfaces(fresh: true)
        let stage = stageEntity
        return challenges.finish(stage: stage, course: course) { snapshot in
            guard let stage else { return snapshot.layout.isEmpty }
            return snapshot.layout.allSatisfy { prop in
                // Restore only on currently detected compatible floor.
                return prop.footprint.supportPoints.allSatisfy { p in
                    surfaces.contains(stage.convert(position: SIMD3(p.x, 0, p.y), to: nil))
                }
            }
        }
    }

    // MARK: - Per-frame update

    private func update(deltaTime: Float) {
        elapsed += deltaTime
        if let mission = challenges.mission, mission.mode == .daily,
           progression.selectedChallenge != mission.id, !challenges.isRestoringCourse {
            _ = endChallenge()
        }
        challenges.tick(deltaTime, usable: isForeground && isRunning && trackingStatus.isUsable && !overlayPresented)
        advanceCourseRun(deltaTime: deltaTime)
        refreshDrivingAvailability()
        updateReticle()
        updateCourseAim(deltaTime: deltaTime)

        guard isCarPlaced, let rig else { return }

        // The course is read before the step and written back after it: the
        // car sees where every loose prop is now, and each receives whatever
        // the car did to it for RealityKit to act on.
        course.prepareContacts()
        var contacts = course.contacts
        let evaluator = challenges
        let enabled = input.isEnabled
        let contactSource = course.contacts
        let manual = input.transmissionMode == .manual
        vehicle.advance(deltaTime: deltaTime, input: input, contacts: &contacts) { state, _, telemetry, dt in
            evaluator.consume(DriveSample(position: state.position, heading: state.heading,
                velocity: state.velocity, yawRate: state.yawRate, dt: dt, active: enabled,
                contact: contactSource.stepImpact, coneContact: contactSource.stepConeContact,
                braking: self.input.brake > 0 || self.input.handbrake > 0,
                handbrake: self.input.handbrake > 0, gear: telemetry.gear, manual: manual))
        }
        course.applyContactImpulses()
        course.updateDriving(deltaTime: deltaTime)
        reportImpacts()

        instruments.update(renderedSpeed: vehicle.state.speed,
                           readout: vehicle.drivetrainReadout,
                           maxRenderedSpeed: vehicle.tuning.topSpeed,
                           unit: speedUnit,
                           mode: input.transmissionMode,
                           deltaTime: deltaTime)
        let pose = vehicle.interpolatedState()
        updateLean(deltaTime: deltaTime, pose: pose)
        rig.apply(pose, roll: bodyRoll, pitch: bodyPitch)

        let patches = rig.rearContactPatchesInAnchorSpace(pose: pose)
        if effectsQuality.showsSmoke {
            smoke.update(patches: patches, telemetry: vehicle.telemetry,
                         speed: vehicle.state.speed, deltaTime: deltaTime)
        }
        if effectsQuality.showsSkidMarks {
            skidMarks.update(patches: patches, telemetry: vehicle.telemetry,
                             speed: vehicle.state.speed)
        }

        // Coins never compete with a course: none appear during a challenge,
        // and a car on its free test drive earns nothing.
        roadCoins.update(deltaTime: deltaTime,
                         car: OrientedBox2D(centre: pose.position, halfExtents: rig.collisionHalfExtents, angle: pose.heading),
                         speed: vehicle.state.speed,
                         running: input.isEnabled,
                         spawning: challenges.mission == nil && progression.canDrive(car.id),
                         isOpen: roadCoinSpotIsOpen)

        // Only published when it flips, so the interface is not rebuilt 60
        // times a second.
        let drifting = vehicle.telemetry.isDrifting
        if drifting != wasDrifting {
            wasDrifting = drifting
            onDriftingChange?(drifting)
        }
    }

    /// A coin may stand on detected floor at the course's height, clear of
    /// props, and where the camera can already see it.
    private func roadCoinSpotIsOpen(_ point: SIMD2<Float>) -> Bool {
        guard let stageEntity, let arView else { return false }
        let world = stageEntity.convert(position: SIMD3(point.x, 0, point.y), to: nil)
        guard detectedSurfaces(fresh: false).contains(world) else { return false }
        let spot = Footprint2D.circle(centre: point, radius: RoadCoins.Tuning.radius)
        guard !course.layout.contains(where: { $0.footprint.overlaps(spot, margin: 0.05) }) else { return false }
        let camera = arView.cameraTransform
        let forward = -camera.matrix.columns.2
        guard simd_dot(world - camera.translation, SIMD3(forward.x, forward.y, forward.z)) > 0.1,
              let screen = arView.project(world) else { return false }
        return arView.bounds.insetBy(dx: 32, dy: 64).contains(screen)
    }

    private var canAdvanceCourse: Bool {
        isCarPlaced && isForeground && isRunning && trackingStatus.allowsPlacement
            && !overlayPresented && !isEditingCourse && !isEditingOccluders
            && vehicle.state.speed < 0.03 && input.throttle == 0 && input.steering == 0
            && input.brake == 0 && input.handbrake == 0
    }

    private func advanceCourseRun(deltaTime: Float) {
        nextCourseCheck = max(0, nextCourseCheck-deltaTime)
        guard canAdvanceCourse, !challenges.isRestoringCourse, nextCourseCheck == 0 else { return }
        if challenges.phase == .finished, challenges.continuesAutomatically, challenges.completionTime >= 3 {
            if let next = progression.nextCourse(carID: car.id) {
                progression.activate(next)
                challenges.select(next)
                // The completed course is temporary; its original snapshot is
                // still owned by the coordinator until the whole run ends.
                course.replaceForChallenge([])
            } else { _ = endChallenge() }
        }
        if challenges.phase == .waiting, challenges.mission != nil {
            nextCourseCheck = 2
            prepareChallenge(compact: true, autoStart: true)
        } else if challenges.phase == .ready {
            challenges.start()
        }
    }

    /// Passes on the hardest thing hit this frame, no more than a few times a
    /// second, so a car scraping along a wall is not one long buzz.
    private func reportImpacts() {
        let impacts = course.contacts.takeImpacts()
        guard elapsed - lastImpactTime > 0.12 else { return }
        if impacts.barrier > 0.18 {
            lastImpactTime = elapsed
            onCourseImpact?(.barrier(strength: min(impacts.barrier / 1.6, 1)))
        } else if impacts.tyre > 0.12 {
            lastImpactTime = elapsed
            onCourseImpact?(.tyre(strength: min(impacts.tyre / 1.6, 1)))
        } else if impacts.cone > 0.12 {
            lastImpactTime = elapsed
            onCourseImpact?(.cone(strength: min(impacts.cone / 1.6, 1)))
        }
    }

    /// Body roll and pitch are cosmetic: they follow the forces the model has
    /// already computed rather than driving anything.
    private func updateLean(deltaTime: Float, pose: VehicleState) {
        let lateral = vehicle.state.lateralSpeed
        let topSpeed = max(vehicle.tuning.topSpeed, 0.01)
        let targetRoll = clamp(-vehicle.state.yawRate * 0.09 - lateral / topSpeed * 0.5, -1.4, 1.4)
            * DriveConfiguration.maxBodyRoll
        let targetPitch = -(input.throttle - input.brake) * DriveConfiguration.maxBodyPitch

        let blend = min(DriveConfiguration.bodyLeanSmoothing * deltaTime, 1)
        bodyRoll += (targetRoll - bodyRoll) * blend
        bodyPitch += (targetPitch - bodyPitch) * blend
    }

    private func updateReticle() {
        if isTakingPhoto {
            reticle.hide()
            return
        }

        // While editing it marks where the next box would stand, whether or
        // not the car is already down.
        if isEditingOccluders {
            guard isForeground, isRunning, trackingStatus.allowsPlacement,
                  let position = raycastFromScreenCentre() else {
                lastValidHit = nil
                reticle.hide()
                return
            }
            lastValidHit = position
            reticle.show(at: position, heading: placementHeading(at: position), pulse: elapsed)
            return
        }

        guard !isCarPlaced else { return }

        guard rig != nil, isForeground, isRunning, trackingStatus.allowsPlacement,
              let position = raycastFromScreenCentre() else {
            lastValidHit = nil
            reticle.hide()
            carPlacementProblem = nil
            if placementPhase == .readyToPlace { placementPhase = .searching }
            return
        }

        lastValidHit = position
        let heading = placementHeading(at: position)
        let problem = carProblem(at: position, heading: heading)
        carPlacementProblem = problem
        reticle.show(at: position, heading: heading, pulse: elapsed, valid: problem == nil)
        if placementPhase != .placed { placementPhase = .readyToPlace }
    }

    /// Keeps the placement preview under the middle of the screen while a
    /// course tool is picked.
    private func updateCourseAim(deltaTime: Float) {
        guard isEditingCourse else { return }
        guard course.status.tool != nil else {
            course.updateAim(nil, environment: courseEnvironment(fresh: false), deltaTime: deltaTime)
            return
        }
        var aim: CourseAim?
        if isForeground, isRunning, trackingStatus.allowsPlacement, let arView, arView.bounds.width > 0,
           let hit = floorHit(from: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)) {
            aim = CourseAim(world: hit.world, onDetectedPlane: hit.onDetectedPlane, viewDirection: viewDirection())
        }
        course.updateAim(aim, environment: courseEnvironment(fresh: false), deltaTime: deltaTime)
    }

    private func raycastFromScreenCentre() -> SIMD3<Float>? {
        guard let arView, arView.bounds.width > 0 else { return nil }
        return raycast(from: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY))
    }

    /// Horizontal-plane raycast that works on every ARKit device, LiDAR or not.
    private func raycast(from point: CGPoint) -> SIMD3<Float>? {
        floorHit(from: point)?.world
    }

    /// As `raycast`, and says whether the hit was on a detected plane's
    /// outline or only an estimate — the course accepts only the former.
    private func floorHit(from point: CGPoint) -> (world: SIMD3<Float>, onDetectedPlane: Bool)? {
        guard let arView else { return nil }
        // Real plane geometry first; estimated planes are the fallback while
        // ARKit is still building up its understanding of the floor.
        var onDetectedPlane = true
        var results = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal)
        if results.isEmpty {
            onDetectedPlane = false
            results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal)
        }
        guard let result = results.first else { return nil }
        let world = SIMD3(result.worldTransform.columns.3.x,
                          result.worldTransform.columns.3.y,
                          result.worldTransform.columns.3.z)
        return (world, onDetectedPlane)
    }

    // MARK: - Driving availability

    /// The controls only reach the simulation when the car exists, ARKit is
    /// tracking properly and the app is in front of the user.
    private func refreshDrivingAvailability() {
        let usable = isCarPlaced && trackingStatus.isUsable && isForeground && isRunning
            && !isEditingOccluders && !isEditingCourse && !overlayPresented && progression.canLaunch(car.id)
        // A course countdown is not a tracking interruption.
        if challengeUsable != usable {
            challengeUsable = usable
            if usable { challenges.resume() } else { challenges.pause() }
        }
        let allowed = usable && !challenges.holdsControls
        guard input.isEnabled != allowed else { return }
        input.isEnabled = allowed
        if !allowed { haltCar() }
    }
}

// MARK: - Gesture coordination

extension ARDriveController: UIGestureRecognizerDelegate {

    /// A drag and a twist are separate gestures (one finger, two fingers), but
    /// letting both be recognised means lifting one finger of a twist hands
    /// over to a drag cleanly instead of dropping the touch.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPanGestureRecognizer && other is UIRotationGestureRecognizer)
            || (gestureRecognizer is UIRotationGestureRecognizer && other is UIPanGestureRecognizer)
    }
}

// MARK: - ARSessionDelegate

extension ARDriveController: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        MainActor.assumeIsolated {
            switch state {
            case .normal:
                trackingStatus = .normal
            case .notAvailable:
                trackingStatus = .initializing
            case .limited(let reason):
                switch reason {
                case .excessiveMotion:      trackingStatus = .excessiveMotion
                case .insufficientFeatures: trackingStatus = .insufficientFeatures
                case .relocalizing:         trackingStatus = .relocalizing
                case .initializing:         trackingStatus = .initializing
                @unknown default:           trackingStatus = .initializing
                }
            }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { trackingStatus = .interrupted }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            // ARKit reports `.limited(.relocalizing)` next; treat the gap as
            // relocalising so the user sees a sensible message immediately.
            trackingStatus = .relocalizing
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let identifiers = Set(anchors.map(\.identifier))
        MainActor.assumeIsolated {
            // If ARKit gives up on the anchor the car and course stand on, they
            // have nowhere to stand: take them away and ask for a new spot
            // rather than leaving them floating in a stale position.
            guard let stageAnchor, identifiers.contains(stageAnchor.identifier) else { return }
            AppLog.session.error("Placement anchor was removed by ARKit")
            let hadCourse = !course.isEmpty
            setCourseEditing(false)
            removeCar()
            removeStage()
            placementPhase = .searching
            onPlacementLost?(hadCourse)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = (error as? ARError)?.localizedDescription ?? error.localizedDescription
        AppLog.session.error("AR session failed: \(message, privacy: .public)")
        MainActor.assumeIsolated { trackingStatus = .failed(message) }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let intensity = frame.lightEstimate?.ambientIntensity
        MainActor.assumeIsolated {
            framesSinceLightCheck += 1
            guard framesSinceLightCheck >= 15, let intensity else { return }
            framesSinceLightCheck = 0
            // Hysteresis, otherwise the warning flickers on and off as the
            // camera auto-exposes.
            if isSceneTooDark {
                if intensity > DriveConfiguration.brightSceneThreshold { isSceneTooDark = false }
            } else if intensity < DriveConfiguration.darkSceneThreshold {
                isSceneTooDark = true
            }
        }
    }
}

private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}
