import Foundation

/// Stable progression slots; generated asset metadata remains untouched.
enum ProgressionCatalog {
    static let ids = ["mini-hatch", "runabout", "rust-bucket", "vintage-saloon", "limousine",
        "family-van", "ambulance", "angular-truck", "work-pickup", "trail-jeep", "field-truck",
        "estate-4x-4", "beach-buggy", "banana-kart", "city-taxi", "sedan-sports", "patrol-car",
        "hot-hatch", "rotary-coupe", "eighties-wedge", "roadster", "grand-tourer", "pony-car",
        "track-coupe", "muscle-coupe", "eighties-icon", "supercar", "racer"]
    /// Shared dial on every price. 0.1088 makes all 27 cars plus every part at
    /// level 5 cost 47,035 coins, exactly 10,000 more than completing every
    /// mission pays (career 11,575 + chapter bonuses 5,500 + mastery 19,960).
    /// Contracts, dailies and road coins cover the rest.
    static let economyScale = 0.1088
    /// Relative knobs (1 = the original prices) before `economyScale`.
    static let carPriceScale = 2.5 * economyScale
    static let partPriceScale = 2.2 * economyScale
    static let transmissionPriceScale = 4.06 * economyScale
    /// Base prices scaled by `carPriceScale`, rounded to 5 coins. The starter stays free.
    static let prices = [0,1000,1200,1400,1600,1850,2100,2400,2700,2900,3000,3100,3200,3300,3400,3500,3600,3700,3800,3900,4000,4100,4200,4300,4400,4500,4600,4700]
        .map { $0 == 0 ? 0 : roundCoins(Double($0) * carPriceScale) }
    static let stars = [0,2,4,6,9,12,15,18,22,26,30,34,38,43,48,53,58,63,68,74,80,86,92,98,104,110,115,120]
    static let stockSpeeds: [Float] = [1,1.02,1.04,1.06,1.08,1.10,1.12,1.14,1.16,1.18,1.20,1.22,1.24,1.26,1.28,1.30,1.32,1.38,1.43,1.52,1.57,1.62,1.67,1.72,1.78,1.93,2.01,2.16]
    static let starter = ids[0]
    /// The car offered once, fully upgraded, as a free test drive.
    static let trialCar = "rotary-coupe"
    static var cars: [CarDefinition] { ids.compactMap { id in CarCatalog.all.first { $0.id == id } } }
    static func slot(_ id: String) -> Int? { ids.firstIndex(of: id) }
    static func roundCoins(_ value: Double) -> Int { max(5, Int((value / 5).rounded()) * 5) }
    static func upgradeCost(carID: String, part: UpgradePart, level: Int) -> Int {
        guard let slot = slot(carID), (1...4).contains(level) else { return 0 }
        return roundCoins(Double([25,50,90,150][level-1]) * part.priceFactor * part.priceRaise * (1 + 0.08 * Double(slot)))
    }
}

enum UpgradePart: String, Codable, CaseIterable, Identifiable {
    case engine, transmission, tires, steering, drift
    var id: String { rawValue }
    var title: String { switch self {
        case .engine: return "Engine"; case .transmission: return "Transmission"
        case .tires: return "Tires"; case .steering: return "Steering"; case .drift: return "Drift setup"
    } }
    var icon: String { switch self {
        case .engine: return "engine.combustion"; case .transmission: return "gearshape.2"
        case .tires: return "circle.circle"; case .steering: return "steeringwheel"; case .drift: return "point.topleft.down.to.point.bottomright.curvepath"
    } }
    var benefit: String { switch self {
        case .engine: return "Pull away more strongly and recover speed after a corner."
        case .transmission: return "Reach a higher speed with gearing matched to the engine."
        case .tires: return "Hold a cleaner line and use more braking traction."
        case .steering: return "Bring the wheels into a turn more responsively."
        case .drift: return "Initiate, hold and recover a slide more progressively."
    } }
    /// Price scale on top of `priceFactor`; transmission costs the most.
    var priceRaise: Double { self == .transmission ? ProgressionCatalog.transmissionPriceScale : ProgressionCatalog.partPriceScale }
    var priceFactor: Double { switch self { case .engine, .drift: return 1; case .transmission, .tires: return 0.9; case .steering: return 0.8 } }
}

struct CarParts: Codable, Equatable, Hashable {
    var levels: [String: Int] = [:]
    subscript(_ part: UpgradePart) -> Int {
        get { min(5, max(1, levels[part.rawValue] ?? 1)) }
        set { levels[part.rawValue] = min(5, max(1, newValue)) }
    }
    static var maximum: CarParts { var p = CarParts(); for part in UpgradePart.allCases { p[part] = 5 }; return p }
}

/// Always resolves from an unmodified measured reference, never a prior upgrade.
enum EffectiveTuning {
    static let curve: [Float] = [0, 0.22, 0.47, 0.73, 1]
    static func resolve(base: VehicleTuning, carID: String, parts: CarParts) -> VehicleTuning {
        guard let slot = ProgressionCatalog.slot(carID) else { return base }
        func blend(_ part: UpgradePart, _ low: Float, _ high: Float = 1) -> Float {
            low + (high-low) * curve[parts[part]-1]
        }
        var t = base
        let engineFloor: Float = 0.65 + 0.19 * Float(slot) / 27
        let engine = blend(.engine, engineFloor)
        let stock = ProgressionCatalog.stockSpeeds[slot]
        let gearedSpeed = stock + (base.topSpeed-stock) * curve[parts[.transmission]-1]
        // Matched road load: engine changes pull, while transmission changes the
        // speed envelope. Taller gears reduce low-gear force by up to 8%.
        let gearingTrade = 1 - 0.08 * curve[parts[.transmission]-1]
        t.engineForce = base.engineForce * engine * gearingTrade
        t.topSpeed = gearedSpeed
        t.dragCoefficient = max(t.engineForce - t.rollingResistance, 0.05) / (gearedSpeed * gearedSpeed)
        t.transmission.finalDrive = base.transmission.finalDrive * base.topSpeed / gearedSpeed
        t.transmission.peakDriveForce = base.transmission.peakDriveForce * engine * gearingTrade
        let grip = blend(.tires, 0.88)
        t.frontGrip = base.frontGrip * grip
        // Stock rear stays settled; drift parts progressively expose the class balance.
        let rearBalance = blend(.drift, 1.08, 1)
        t.rearGrip = base.rearGrip * grip * rearBalance
        t.frontCorneringStiffness = base.frontCorneringStiffness * grip
        t.rearCorneringStiffness = base.rearCorneringStiffness * grip * rearBalance
        t.brakeForce = base.brakeForce * blend(.tires, 0.94)
        t.steerRate = base.steerRate * blend(.steering, 0.82)
        t.maxSteerAngle = base.maxSteerAngle // Preserve the measured model's stable lock.
        t.handbrakeGripScale = base.handbrakeGripScale * blend(.drift, 1.35, 1)
        t.handbrakeForce = base.handbrakeForce * blend(.drift, 1, 1.25)
        t.handbrakeReleaseRate = base.handbrakeReleaseRate * blend(.drift, 0.75, 1)
        // Measured compact traces need more yaw damping at full power: without
        // it the reference rear breaks into a tiny oscillating circle.
        let maximumYaw: Float = CarCatalog.car(id:carID).carClass == .compact ? 2.5 : 1
        t.yawDamping = base.yawDamping * blend(.drift, 1.18, maximumYaw)
        return t
    }
    static func reference(for car: CarDefinition) -> VehicleTuning {
        VehicleTuning.make(carClass: car.carClass, length: car.length, wheelBase: car.length * 0.55,
                          trackWidth: car.length * 0.44, wheelRadius: car.length * 0.115)
    }
    static func estimate(car: CarDefinition, parts: CarParts) -> VehicleTuning {
        resolve(base: reference(for: car), carID: car.id, parts: parts)
    }
    static func ratings(_ t: VehicleTuning) -> [(String, Double)] {
        func rating(_ x: Float) -> Double { Double(min(100, max(0, x * 100))) }
        return [("Speed", rating(t.topSpeed/2.5)), ("Acceleration", rating(t.engineForce/t.mass/3.6)),
                ("Grip", rating((t.frontGrip+t.rearGrip)/2/1.25)), ("Agility", rating(t.steerRate/4.8)),
                ("Drift control", rating((1-t.handbrakeGripScale) * t.handbrakeReleaseRate/3.5))]
    }
}
