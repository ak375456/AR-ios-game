import Foundation
import simd

@main struct ProgressionDrivingAudit {
    static func main() throws {
        setbuf(stdout,nil)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        for id in ["mini-hatch"] {
            let geometry = try MeasuredCarGeometry(car:CarCatalog.car(id:id),resources:resources)
            print("measured wheelbase=\(geometry.base.wheelBase) width=\(geometry.width)")
            for build in [CarParts(),CarParts.maximum] {
                let car = CarCatalog.car(id:id), tuning = EffectiveTuning.resolve(base:geometry.base,carID:id,parts:build)
                var best: (Float,Float,Float,Float,Float,Float) = (0,0,0,0,0,0)
                for steer in stride(from:Float(0.25),through:1,by:0.05) {
                    for hand in stride(from:Float(0),through:1,by:0.1) {
                        let input = DrivingInput(); input.isEnabled = true; input.throttle = 1
                        var vehicle = VehicleDynamics(tuning:tuning)
                        for _ in 0..<720 { vehicle.advance(deltaTime:1/180,input:input) }
                        input.steering = steer; input.handbrake = hand
                        var qualified: Float = 0, maxHold: Float = 0, hold: Float = 0, angleMean: Float = 0, speedMean: Float = 0, radiusMean: Float = 0
                        for i in 0..<1800 {
                            input.handbrake = Float(i % 90) < hand*90 ? 1 : 0
                            vehicle.advance(deltaTime:1/180,input:input)
                            let state = vehicle.state
                            let angle = abs(atan2(state.lateralSpeed,state.forwardSpeed))*180 / .pi
                            let good = state.speed >= 0.40 && state.forwardSpeed > 0.12 && angle >= 12 && angle <= 55 && abs(state.yawRate) > 0.12
                            hold = good ? hold+1/180 : 0; maxHold = max(maxHold,hold)
                            if i >= 720 && good { qualified += 1/180; angleMean += angle/180; speedMean += state.speed/180; radiusMean += (state.speed/max(abs(state.yawRate),0.01))/180 }
                        }
                        if qualified > best.0 { best = (qualified,steer,hand,angleMean/max(qualified,0.001),speedMean/max(qualified,0.001),radiusMean/max(qualified,0.001)) }
                    }
                }
                var mostDonuts = 0, mostPerfect = 0
                var orbitInputs: (Float,Float) = (0,0)
                for steer in stride(from:Float(0.15),through:1,by:0.05) {
                    for hand in stride(from:Float(0),through:1,by:0.1) {
                        let input = DrivingInput(); input.isEnabled = true; input.throttle = 1
                        var v = VehicleDynamics(tuning:tuning)
                        for _ in 0..<720 { v.advance(deltaTime:1/180,input:input) }
                        input.steering = steer
                        for i in 0..<1800 { input.handbrake = Float(i%90) < hand*90 ? 1 : 0; v.advance(deltaTime:1/180,input:input) }
                        guard abs(v.state.yawRate) > 0.1 else { continue }
                        let center = v.state.position + SIMD2(v.state.velocity.y,-v.state.velocity.x)/v.state.yawRate
                        var layout = ChallengeLayout.make(mission:MissionDefinition(id:"test.orbit",title:"Orbit physics",objective:"Detector fixture",mode:.career,metric:.donuts,target:1,scope:.cumulative,reward:0,assisted:true),length:car.length,width:geometry.width,speed:tuning.topSpeed,origin:.zero,heading:0,compact:true)
                        layout.orbitCenter = center

                        var detector = DrivingEvaluator(); detector.layout = layout; detector.assisted = build[.engine] == 1
                        var donuts = 0, perfect = 0
                        for i in 0..<3600 {
                            input.handbrake = Float(i%90) < hand*90 ? 1 : 0
                            v.advance(deltaTime:1/180,input:input)
                            let state = v.state
                            let e = detector.consume(DriveSample(position:state.position,heading:state.heading,velocity:state.velocity,yawRate:state.yawRate,dt:1/180,active:true))
                            donuts += e.donuts; perfect += e.perfectDonuts
                        }
                        if donuts > mostDonuts || (donuts == mostDonuts && perfect > mostPerfect) { mostDonuts = donuts; mostPerfect = perfect; orbitInputs = (steer,hand) }
                    }
                }
                print("Measured actual orbit: standard=\(mostDonuts), perfect=\(mostPerfect), steer=\(orbitInputs.0), handbrake duty=\(orbitInputs.1)")
                if mostDonuts == 0 { fatalError("No real orbit trace satisfies the mission") }
                print("\(id) \(build[.engine] == 1 ? "stock" : "max") best: seconds=\(best.0) steer=\(best.1) handbrake=\(best.2) angle=\(best.3) speed=\(best.4) radius=\(best.5) length=\(car.length)")
            }
        }
    }
}
