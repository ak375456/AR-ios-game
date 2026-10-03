import Foundation
import simd

extension ProgressionChecks {
    static func additionalChecks() {
        let zone = ParkingZone(center:.zero,heading:0,halfSize:SIMD2(0.2,0.3),tolerance:20 * .pi/180)
        var layout = ChallengeLayout.make(mission:MissionCatalog.career[9],length:0.36,width:0.16,speed:1,origin:.zero,heading:0,compact:true)
        layout.parking = zone
        func feed(_ evaluator: inout DrivingEvaluator, _ position: SIMD2<Float>, velocity: SIMD2<Float> = .zero,
                  heading: Float = 0, contact: Float = 0, dt: Float = 1/180) -> DrivingEvents {
            evaluator.consume(DriveSample(position:position,heading:heading,velocity:velocity,yawRate:0,dt:dt,active:true,contact:contact))
        }
        var park = DrivingEvaluator(); park.layout = layout; park.requiredParkHold = 1
        var parks = 0
        for i in 0...360 {
            let p = SIMD2<Float>(0,-0.8+Float(i)/450)
            parks += feed(&park,p,velocity:SIMD2(0,0.4)).parks
        }
        for _ in 0..<360 { parks += feed(&park,.zero).parks }
        check("parking approach and hold pays once",parks == 1)
        for i in 0..<360 {
            let p = SIMD2<Float>(0,i.isMultiple(of:2) ? 0.01 : 0)
            parks += feed(&park,p).parks
        }
        check("parking repeated threshold cannot farm",parks == 1)
        var speedPark = DrivingEvaluator(); speedPark.layout = layout
        var movingParks = 0
        for _ in 0..<600 { movingParks += feed(&speedPark,.zero,velocity:SIMD2(0,0.2)).parks }
        check("moving car never parks",movingParks == 0)

        var detector = DrivingEvaluator(); var points: Double = 0, banked = 0
        // Synthetic curved translation with a stable body slip, followed by a crash.
        for i in 0..<720 {
            let a = Float(i)/180, v = SIMD2<Float>(cos(a),-sin(a))*0.7
            let e = detector.consume(DriveSample(position:SIMD2(sin(a),cos(a))*0.7,heading:atan2(v.x,v.y)-0.4,velocity:v,yawRate:1,dt:1/180,active:true,contact:i == 500 ? 0.5 : 0))
            points += e.driftPoints; banked += e.drifts
        }
        check("major contact drops unbanked chain",points == 0 && banked == 0)
        var wall = DrivingEvaluator(); var falseProgress: Double = 0
        for i in 0..<1000 {
            let e = wall.consume(DriveSample(position:.zero,heading:Float(i)*0.01,velocity:SIMD2(0.5,0.5),yawRate:1,dt:1/180,active:true,contact:0.4))
            falseProgress += e.distance+e.movingTime+e.driftPoints+Double(e.donuts)
        }
        check("wall pushing cannot earn progress",falseProgress == 0)
        var noise = DrivingEvaluator(); var jitterPoints: Double = 0
        for i in 0..<900 {
            let a = Float(i)/180, velocity = SIMD2<Float>(cos(a),-sin(a))*0.7
            let slip: Float = i.isMultiple(of:2) ? 0.4 : -0.4
            let e = noise.consume(DriveSample(position:SIMD2(sin(a),cos(a))*0.7,heading:atan2(velocity.x,velocity.y)-slip,velocity:velocity,yawRate:1,dt:1/180,active:true))
            jitterPoints += e.driftPoints+Double(e.driftLinks)
        }
        check("alternating slip jitter cannot link",jitterPoints == 0)
        var jump = DrivingEvaluator(); jump.layout = layout
        _ = feed(&jump,.zero,velocity:SIMD2(0,0.7))
        let teleport = feed(&jump,SIMD2(10,10),velocity:SIMD2(0,0.7))
        check("teleport earns nothing",teleport.distance == 0 && teleport.donuts == 0 && teleport.gates == 0)
        jump.discontinuity()
        let resumed = feed(&jump,SIMD2(20,20),velocity:SIMD2(0,0.7))
        check("resume never integrates time gap",resumed.distance == 0)

        var attempt = MissionAttempt(), progress = MissionProgress()
        let m = MissionCatalog.career[2]
        attempt.advance(m,event:DrivingEvents(movingTime:0.01,cleanTime:100),progress:&progress)
        check("clean mission excludes pre-activation time",progress.value == 0.01)
        attempt.advance(m,event:DrivingEvents(collided:true),progress:&progress)
        check("contact resets clean attempt",progress.value == 0)
        var saved = ProgressionSave(); saved.missions["career.fake"] = MissionProgress(value:100,completed:true)
        check("unknown IDs cannot grant stars",saved.stars == 0)

        // Test every control-like rectangle against the pure placement solver,
        // including shifter space and a deliberately crowded small screen.
        for width in [320.0,375.0,430.0] {
            let screen = CGSize(width:width,height:640)
            let obstacles = [CGRect(x:0,y:0,width:width,height:58),CGRect(x:0,y:180,width:180,height:112),CGRect(x:width-100,y:300,width:90,height:170),CGRect(x:0,y:530,width:width,height:110)]
            let frame = OverlayPlacement.find(in:screen,avoiding:obstacles,preferred:CGSize(width:200,height:120))
            check("HUD avoids moved controls width \(width)",frame != nil && obstacles.allSatisfy{!$0.intersects(frame!)})
        }
        check("HUD never overlays a fully occupied screen",OverlayPlacement.find(in:CGSize(width:320,height:640),avoiding:[CGRect(x:0,y:0,width:320,height:640)],preferred:CGSize(width:200,height:120)) == nil)
        for width in [320.0, 375.0, 393.0, 430.0] {
            for height in [548.0, 724.0, 810.0] {
                let size = CGSize(width: width, height: height)
                for moved in [false, true] {
                    let controls = [CGRect(x: 8, y: height-86, width: 150, height: 78),
                                    CGRect(x: width-170, y: height-100, width: 66, height: 66),
                                    CGRect(x: width-90, y: height-92, width: 78, height: 78),
                                    CGRect(x: 16, y: moved ? 14 : height*0.34, width: 70, height: 70),
                                    CGRect(x: width-74, y: moved ? height-230 : height*0.46, width: 66, height: 148)]
                    for focused in [false, true] {
                        let layout = DriveOverlayLayout(size: size, controls: controls, focused: focused,
                            instrumentSize: CGSize(width: min(width-32, 360), height: 124),
                            instrumentY: height-174, showsStatus: true, showsGoal: true, statusHeight: 112)
                        let panels = [layout.toolbar, layout.instruments, layout.status, layout.goal].compactMap { $0 }
                        check("all chrome avoids moved/manual controls \(width)x\(height) \(moved) \(focused)", panels.allSatisfy { panel in
                            CGRect(origin: .zero, size: size).contains(panel) && controls.allSatisfy { !$0.intersects(panel) }
                        })
                        check("overlay panels never overlap each other", panels.enumerated().allSatisfy { i, panel in
                            panels.enumerated().allSatisfy { j, other in i == j || !panel.intersects(other) }
                        })
                        check("show interface button stays available", layout.toolbar != nil)
                        check("focus mode hides the goal panel", !focused || layout.goal == nil)
                    }
                }
            }
        }
        let figureEight = MissionDefinition(id:"fixture.figure-eight",title:"Figure eight",objective:"Geometry fixture",mode:.career,metric:.sequence,target:1,scope:.sequence,reward:0,steps:[.init(.figureEight)])
        let eight = ChallengeLayout.make(mission:figureEight,length:0.36,width:0.16,speed:1,origin:.zero,heading:0,compact:true)
        check("figure eight has eight directed gates",eight.gates.count == 8)
        check("floor check includes extreme corners",!eight.fits { $0.x < eight.boundsMax.x-0.001 })
    }

    /// App Store unlocks: All Cars is granted into ownership and a refund removes only
    /// those cars; Double Coins doubles credits, not goal counts; Max Upgrades is an overlay.
    static func paidUnlockChecks() throws {
        let dir = directory("paid"); defer { try? FileManager.default.removeItem(at:dir) }
        var seed = ProgressionSave(); seed.coins = 5000
        for m in MissionCatalog.career.prefix(2) { seed.missions[m.id] = MissionProgress(value:m.target,completed:true) }
        try ProgressionStore(directory:dir).write(seed)
        let m = ProgressionModel(directory:dir)
        check("coin purchase before All Cars",m.buyCar("runabout"))
        m.grantAllCars()
        check("All Cars owns every car",m.ownsEveryCar && m.canDrive("racer"))
        check("All Cars survives relaunch",ProgressionModel(directory:dir).ownsEveryCar)
        check("All Cars keeps coin-bought receipt separate",!m.save.transactions.contains("iap.car.runabout"))
        m.revokeAllCars()
        check("refund removes only granted cars",m.save.owned.intersection(ProgressionCatalog.ids) == ["mini-hatch","runabout"])
        m.setPaidUnlocks(doubleCoins:false,maxUpgrades:true)
        check("Max Upgrades overlays every car",m.parts("mini-hatch") == .maximum && m.parts("racer") == .maximum)
        check("Max Upgrades leaves bought levels untouched",(m.save.parts["mini-hatch"] ?? CarParts()) == CarParts())
        m.setPaidUnlocks(doubleCoins:false,maxUpgrades:false)
        check("Max Upgrades refund restores bought levels",m.parts("mini-hatch") == CarParts())

        let doubleDir = directory("double"); defer { try? FileManager.default.removeItem(at:doubleDir) }
        let d = ProgressionModel(directory:doubleDir)
        d.setPaidUnlocks(doubleCoins:true,maxUpgrades:false)
        d.refreshDay()
        check("Double Coins doubles the daily bonus",d.save.ledger.contains { $0.id.hasPrefix("login.") && $0.coins == 20 })
        d.beginSession(carID:"mini-hatch")
        d.consume(DrivingEvents(distance:5),carID:"mini-hatch",dt:0.1,scoredChallenge:nil)
        let first = MissionCatalog.career[0]
        check("Double Coins doubles mission rewards",d.save.ledger.first { $0.id == "reward.\(first.id)" }?.coins == 2 * first.reward)
        check("shown reward matches credit",d.reward(first) == 2 * first.reward)
        let beforeRoad = d.save.coins
        d.collectRoadCoins(5,carID:"mini-hatch")
        check("Double Coins doubles road coins",d.save.coins - beforeRoad == 10)
        let pickups = MissionCatalog.career.first { $0.metric == .coinPickups }!
        check("coin goals still count one pickup",d.progress(pickups).value == 1 || d.progress(pickups).completed)
    }
}
