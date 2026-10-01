import Foundation
import Observation
import RealityKit
import UIKit

/// Owns attempt-local telemetry and temporary visuals. Progression owns durable rewards.
@MainActor @Observable
final class ChallengeCoordinator {
    enum Phase: Equatable { case free, waiting, ready, countdown, driving, finished }
    private(set) var phase: Phase = .free
    private(set) var message = ""
    private(set) var countdown = 3
    private(set) var driftSeconds: Double = 0
    private(set) var orbitProgress: Double = 0
    private(set) var nextMarker = 1
    private(set) var mission: MissionDefinition?
    private(set) var layout: ChallengeLayout?
    private(set) var continuesAutomatically = false
    private(set) var isRestoringCourse = false
    private(set) var completionTime: Float = 0
    @ObservationIgnored private var evaluator = DrivingEvaluator()
    @ObservationIgnored private var clock: Float = 0
    @ObservationIgnored private var publication: Float = 0
    @ObservationIgnored private var previousStep = -1
    @ObservationIgnored private var pausedAt: TimeInterval?
    @ObservationIgnored private var temporaryRoot: Entity?
    @ObservationIgnored private var arrows: [Entity] = []
    @ObservationIgnored private var slalomArrows: [Entity] = []
    @ObservationIgnored private var snapshot: CourseSnapshot?
    let progression: ProgressionModel
    let carID: String

    init(progression: ProgressionModel, carID: String) {
        self.progression = progression; self.carID = carID
        if let id = progression.selectedChallenge, let m = progression.definition(id) {
            select(m, continues: !progression.progress(m).completed)
        }
    }
    var holdsControls: Bool { phase == .countdown || phase == .ready }
    var isScoring: Bool { phase == .driving }
    func select(_ m: MissionDefinition, continues: Bool = true) {
        temporaryRoot?.removeFromParent(); temporaryRoot = nil
        arrows.removeAll(); slalomArrows.removeAll()
        mission = m; phase = .waiting; layout = nil; evaluator.reset()
        continuesAutomatically = continues; isRestoringCourse = false; completionTime = 0
        message = "Scan clear floor around the car."
    }
    func install(_ layout: ChallengeLayout, stage: Entity, course: CourseBuilder) {
        guard let mission else { return }
        if snapshot == nil { snapshot = course.snapshot() }
        self.layout = layout
        course.attach(to:stage)
        let needsCones = mission.metric == .slalom || mission.metric == .slalomRuns || mission.steps.contains{$0.technique == .slalom}
        course.replaceForChallenge(needsCones ? layout.cones.map { PropLayout(kind:.cone,position:$0,yaw:0) } : [])
        evaluator = DrivingEvaluator(); evaluator.layout = layout; evaluator.assisted = mission.assisted
        evaluator.requiredParkHold = mission.metric == .parking ? mission.target : (mission.steps.first{$0.technique == .park}?.target ?? 2)
        buildVisuals(layout,stage:stage)
        phase = .ready; message = mission.objective; progression.resetAttempt(message:mission.objective)
    }
    func cannotFit() { phase = .waiting; message = "Scan a little more floor. Driving goals still count." }
    func start() {
        guard layout != nil else { return }
        evaluator.reset(); previousStep = -1; progression.resetAttempt(message:"Ready when you are.")
        clock = 0; countdown = 3; phase = .countdown; message = "Ready · 3"
    }
    func tick(_ dt: Float, usable: Bool) {
        if phase == .finished, usable { completionTime += min(max(dt,0),0.1) }
        guard phase == .countdown, usable else { return }
        clock += min(max(dt,0),0.1)
        let next = max(1,3-Int(clock))
        if countdown != next { countdown = next; message = "Ready · \(next)" }
        if clock >= 3 { phase = .driving; message = mission?.objective ?? "Go"; clock = 0 }
    }
    func pause() { if pausedAt == nil { pausedAt = ProcessInfo.processInfo.systemUptime }; progression.flush() }
    func resume() {
        guard let pause = pausedAt else { return }; pausedAt = nil
        if mission?.requiresCourse == true, ProcessInfo.processInfo.systemUptime - pause > 10, phase != .finished { reset(reason:"Ready to resume your course.") }
        else { evaluator.discontinuity() }
    }
    func reset(reason: String) {
        evaluator.reset(); progression.resetAttempt(message:reason); message = reason
        if layout != nil { phase = .ready }
        completionTime = 0
    }
    func stageLost() {
        temporaryRoot?.removeFromParent(); temporaryRoot = nil; arrows.removeAll(); layout = nil
        slalomArrows.removeAll(); evaluator = DrivingEvaluator(); phase = mission == nil ? .free : .waiting
        message = "The floor anchor was lost. Place again; your saved course needs a new floor."
        progression.resetAttempt(message:message)
    }
    func finish(stage: Entity?, course: CourseBuilder, canRestore: (CourseSnapshot) -> Bool) -> Bool {
        continuesAutomatically = false
        temporaryRoot?.removeFromParent(); temporaryRoot = nil; arrows.removeAll()
        slalomArrows.removeAll(); layout = nil; evaluator = DrivingEvaluator()
        if let snapshot, !snapshot.layout.isEmpty || stage != nil {
            guard let stage, canRestore(snapshot) else {
                isRestoringCourse = true
                phase = .waiting; message = "Scan your course's floor to restore it."; return false
            }
            course.attach(to:stage); course.restore(snapshot); self.snapshot = nil
        }
        self.snapshot = nil
        evaluator = DrivingEvaluator(); layout = nil; mission = nil; phase = .free; isRestoringCourse = false
        progression.stopChallenge(); message = "Free drive"
        return true
    }
    func consume(_ sample: DriveSample) {
        guard sample.active else { return }
        if let mission, phase == .driving, !mission.steps.isEmpty {
            let step = progression.currentStep(for:mission)
            if step != previousStep {
                evaluator.resetCourseProgress()
                evaluator.reverseGate = step < mission.steps.count && mission.steps[step].technique == .reverseGate
                previousStep = step
            }
        }
        let event = evaluator.consume(sample)
        progression.consume(event,carID:carID,dt:Double(sample.dt),scoredChallenge:isScoring ? mission?.id : nil)
        publication += sample.dt
        if publication >= 0.125 {
            publication = 0
            driftSeconds = evaluator.liveDriftTime; orbitProgress = event.orbitFraction
            nextMarker = (mission?.metric == .slalom ? evaluator.nextCone : evaluator.nextGate)+1
            if phase == .driving { message = evaluator.guidance }
            if let m = mission, phase == .driving, progression.finishedChallenge == m.id {
                phase = .finished; completionTime = 0
                message = continuesAutomatically ? "Complete · stop for the next course" : "Practice complete"
            }
            let step = mission.flatMap { m -> Technique? in
                let i = progression.currentStep(for: m)
                return i < m.steps.count ? m.steps[i].technique : nil
            }
            let weaving = step == .slalom || mission?.metric == .slalom || mission?.metric == .slalomRuns
            for (i,arrow) in arrows.enumerated() { arrow.isEnabled = !weaving && i == evaluator.nextGate % max(arrows.count,1) }
            for (i,arrow) in slalomArrows.enumerated() { arrow.isEnabled = weaving && i == evaluator.nextCone % max(slalomArrows.count,1) }
        }
    }
    private func buildVisuals(_ layout: ChallengeLayout, stage: Entity) {
        temporaryRoot?.removeFromParent(); arrows.removeAll(); slalomArrows.removeAll()
        let root = Entity(); stage.addChild(root); temporaryRoot = root
        let mint = UnlitMaterial(color:UIColor(red:0.56,green:1,blue:0.79,alpha:1))
        let amber = UnlitMaterial(color:UIColor(red:1,green:0.78,blue:0.25,alpha:1))
        let techniques = Set(mission?.steps.map(\.technique) ?? [])
        let needsGates = mission?.metric == .gates || mission?.metric == .gateLaps || !techniques.isDisjoint(with:[.gates,.reverseGate,.figureEight])
        let needsWeave = mission?.metric == .slalom || mission?.metric == .slalomRuns || techniques.contains(.slalom)
        for (i,gate) in (needsGates ? layout.gates : []).enumerated() {
            let yaw = atan2(gate.normal.x,gate.normal.y)
            let group = Entity(); group.position = SIMD3(gate.center.x,0.004,gate.center.y)
            group.orientation = simd_quatf(angle:yaw,axis:SIMD3(0,1,0))
            let line = ModelEntity(mesh:.generateBox(size:SIMD3(gate.halfWidth*2,0.003,0.012)),materials:[mint]); group.addChild(line)
            let arrow = ModelEntity(mesh:.groundChevron(width:0.12,length:0.14,thickness:0.025),materials:[amber]); arrow.position.z = 0.12
            group.addChild(arrow); arrows.append(arrow)
            let label = ModelEntity(mesh:.generateText("\(i+1)",extrusionDepth:0.001,font:.systemFont(ofSize:0.08,weight:.bold)),materials:[mint])
            label.orientation = simd_quatf(angle:-.pi/2,axis:SIMD3(1,0,0)); label.position = SIMD3(-0.025,0.003,-0.10)
            group.addChild(label); root.addChild(group)
        }
        for (i, gate) in (needsWeave ? layout.slalomGates : []).enumerated() {
            let marker = Entity()
            marker.position = SIMD3(gate.center.x, 0.008, gate.center.y)
            marker.orientation = simd_quatf(angle: atan2(gate.normal.x, gate.normal.y), axis: SIMD3(0,1,0))
            let arrow = ModelEntity(mesh: .groundChevron(width: 0.12, length: 0.15, thickness: 0.022), materials: [amber])
            marker.addChild(arrow)
            let number = ModelEntity(mesh: .generateText("\(i+1)", extrusionDepth: 0.001, font: .systemFont(ofSize: 0.055, weight: .bold)), materials: [amber])
            number.orientation = simd_quatf(angle: -.pi/2, axis: SIMD3(1,0,0)); number.position.z = -0.10
            marker.addChild(number); root.addChild(marker); slalomArrows.append(marker)
        }
        if [MissionMetric.parking,.parkingCount,.accelerationStops].contains(where: { $0 == mission?.metric }) || !techniques.isDisjoint(with:[.park,.accelerateStop]) {
        let park = ModelEntity(mesh:.groundFrame(halfExtents:layout.parking.halfSize,width:0.012),materials:[amber])
        park.position = SIMD3(layout.parking.center.x,0.003,layout.parking.center.y)
        park.orientation = simd_quatf(angle:layout.parking.heading,axis:SIMD3(0,1,0)); root.addChild(park)
        let direction = ModelEntity(mesh:.groundChevron(width:0.09,length:0.14,thickness:0.02),materials:[amber]); park.addChild(direction)
        }
        if mission?.metric == .donuts || techniques.contains(.donut) {
        let ring = ModelEntity(mesh:.groundRing(inner:layout.orbitRadius-0.005,outer:layout.orbitRadius+0.005,segments:80),materials:[mint])
        ring.position = SIMD3(layout.orbitCenter.x,0.002,layout.orbitCenter.y); root.addChild(ring)
        }
    }
}
