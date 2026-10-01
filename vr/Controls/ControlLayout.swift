//
//  ControlLayout.swift
//  vr
//
//  Where the driving controls sit, and the player's freedom to move them.
//

import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// One control's place on screen.
///
/// The anchor is a fraction of the usable screen rather than a point count, so
/// a layout set on one iPhone still makes sense on another.
struct ControlPlacement: Codable, Hashable {
    /// 0...1 across and down the safe area.
    var anchor: CGPoint
    /// 0.75...1.45 multiplier on the control's base size.
    var scale: CGFloat = 1
}

/// Which control is which.
enum ControlKind: String, CaseIterable, Codable, Identifiable {
    case steering, throttle, brake, handbrake, shifter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steering:  return "Steering"
        case .throttle:  return "Accelerator"
        case .brake:     return "Brake"
        case .handbrake: return "Handbrake"
        case .shifter:   return "Gear shift"
        }
    }

    /// For the segmented picker in the settings screen, where five full titles
    /// do not fit across a small iPhone. These are the words already printed on
    /// the controls themselves.
    var shortTitle: String {
        switch self {
        case .steering:  return "Wheel"
        case .throttle:  return "Go"
        case .brake:     return "Brake"
        case .handbrake: return "Hand"
        case .shifter:   return "Gears"
        }
    }

    /// True for controls that only exist in one transmission mode.
    var isManualOnly: Bool { self == .shifter }

    /// Base size before the player's scale is applied.
    ///
    /// The shifter is one control holding two buttons, stacked: upshift on top,
    /// downshift below, the way a sequential lever moves. Keeping them together
    /// means they move and size as a pair, and a thumb that lands between them
    /// still gets the one it was nearer. Its two halves come out at 58×62,
    /// comfortably past the 44-point minimum, and the pair is short enough to
    /// sit clear of the instrument panel on the smallest iPhone.
    var baseSize: CGSize {
        switch self {
        case .steering:  return CGSize(width: 150, height: 78)
        case .throttle:  return CGSize(width: 78, height: 78)
        case .brake:     return CGSize(width: 66, height: 66)
        case .handbrake: return CGSize(width: 56, height: 56)
        case .shifter:   return CGSize(width: 58, height: 132)
        }
    }
}

/// One half of the gear shift.
enum ShiftDirection {
    case up, down
}

/// The full arrangement.
struct ControlLayout: Codable, Hashable {

    var steering: ControlPlacement
    var throttle: ControlPlacement
    var brake: ControlPlacement
    var handbrake: ControlPlacement
    var shifter: ControlPlacement

    /// Wheel, brake and accelerator along the bottom edge, with the handbrake
    /// at the top left, under the pause button, where the left index finger
    /// reaches it while the left thumb steers, and the manual shifter on the right. This default is
    /// used only when no saved layout exists or the player explicitly resets it.
    ///
    /// The three bottom-row anchors are what set how much room the instrument
    /// panel has: `DriveScreen` parks it immediately above the highest of them.
    /// The gear shift then has to finish above the panel, which is what fixes
    /// its anchor — on the shortest supported iPhone that leaves about ten
    /// points between the two.
    static let standard = ControlLayout(
        steering: ControlPlacement(anchor: CGPoint(x: 0.25, y: 0.925)),
        throttle: ControlPlacement(anchor: CGPoint(x: 0.865, y: 0.925)),
        brake: ControlPlacement(anchor: CGPoint(x: 0.655, y: 0.925)),
        handbrake: ControlPlacement(anchor: CGPoint(x: 0.12, y: 0.17)),
        shifter: ControlPlacement(anchor: CGPoint(x: 0.905, y: 0.545))
    )

    /// Decoded by hand so that a layout stored before the gear shift existed
    /// still loads, rather than throwing and silently resetting everything the
    /// player had arranged.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ControlLayout.standard
        steering = try container.decodeIfPresent(ControlPlacement.self, forKey: .steering) ?? fallback.steering
        throttle = try container.decodeIfPresent(ControlPlacement.self, forKey: .throttle) ?? fallback.throttle
        brake = try container.decodeIfPresent(ControlPlacement.self, forKey: .brake) ?? fallback.brake
        handbrake = try container.decodeIfPresent(ControlPlacement.self, forKey: .handbrake) ?? fallback.handbrake
        shifter = try container.decodeIfPresent(ControlPlacement.self, forKey: .shifter) ?? fallback.shifter
    }

    init(steering: ControlPlacement, throttle: ControlPlacement, brake: ControlPlacement,
         handbrake: ControlPlacement, shifter: ControlPlacement) {
        self.steering = steering
        self.throttle = throttle
        self.brake = brake
        self.handbrake = handbrake
        self.shifter = shifter
    }

    subscript(kind: ControlKind) -> ControlPlacement {
        get {
            switch kind {
            case .steering:  return steering
            case .throttle:  return throttle
            case .brake:     return brake
            case .handbrake: return handbrake
            case .shifter:   return shifter
            }
        }
        set {
            switch kind {
            case .steering:  steering = newValue
            case .throttle:  throttle = newValue
            case .brake:     brake = newValue
            case .handbrake: handbrake = newValue
            case .shifter:   shifter = newValue
            }
        }
    }

    /// Turns the stored fractions into real rectangles for a given screen.
    func frame(for kind: ControlKind, in size: CGSize) -> CGRect {
        let placement = self[kind]
        let base = kind.baseSize
        let width = base.width * placement.scale
        let height = base.height * placement.scale
        // Keep every control fully on screen whatever the anchor says.
        let x = min(max(placement.anchor.x * size.width, width / 2), size.width - width / 2)
        let y = min(max(placement.anchor.y * size.height, height / 2), size.height - height / 2)
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    func frames(in size: CGSize) -> [ControlKind: CGRect] {
        Dictionary(uniqueKeysWithValues: ControlKind.allCases.map { ($0, frame(for: $0, in: size)) })
    }
}

/// How much effect work to do.
enum EffectsQuality: String, CaseIterable, Codable, Identifiable {
    case off, smokeOnly, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:       return "Off"
        case .smokeOnly: return "Smoke only"
        case .full:      return "Smoke + marks"
        }
    }

    var showsSmoke: Bool { self != .off }
    var showsSkidMarks: Bool { self == .full }
}

enum SmokeColorCount: Int, CaseIterable, Codable, Identifiable {
    case one = 1, two, three

    var id: Int { rawValue }
    var title: String { "\(rawValue) color\(rawValue == 1 ? "" : "s")" }
}

enum InstrumentStyle: String, CaseIterable, Codable, Identifiable {
    case digital, analog

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Stored as RGB bytes so the chosen colors survive launches exactly.
struct SmokeColor: Codable, Hashable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    var color: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255,
              blue: Double(blue) / 255)
    }

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: Color) {
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(UInt8((min(max(r, 0), 1) * 255).rounded()),
                  UInt8((min(max(g, 0), 1) * 255).rounded()),
                  UInt8((min(max(b, 0), 1) * 255).rounded()))
    }
}

struct SmokeStyle: Codable, Hashable {
    var colorCount: SmokeColorCount = .one
    var colors: [SmokeColor] = [
        SmokeColor(218, 222, 226),
        SmokeColor(154, 170, 182),
        SmokeColor(230, 233, 235),
    ]

    static let `default` = SmokeStyle()

    var activeColors: [SmokeColor] {
        (0..<colorCount.rawValue).map { index in
            index < colors.count ? colors[index] : Self.default.colors[index]
        }
    }

    /// Safe for any index: SwiftUI can still read a row's binding for one last
    /// frame after `colorCount` shrinks and that row is on its way out.
    func color(at index: Int) -> SmokeColor {
        let all = Self.default.colors
        guard (0..<all.count).contains(index) else { return all[0] }
        return index < colors.count ? colors[index] : all[index]
    }

    mutating func setColor(_ color: SmokeColor, at index: Int) {
        guard (0..<3).contains(index) else { return }
        while colors.count < 3 { colors.append(Self.default.colors[colors.count]) }
        colors[index] = color
    }

    static let presets: [(name: String, style: SmokeStyle)] = [
        ("Classic", SmokeStyle(colorCount: .one,
                               colors: [SmokeColor(218, 222, 226), SmokeColor(154, 170, 182), SmokeColor(230, 233, 235)])),
        ("Silver", SmokeStyle(colorCount: .one,
                              colors: [SmokeColor(160, 174, 184), SmokeColor(154, 170, 182), SmokeColor(230, 233, 235)])),
        ("Ice", SmokeStyle(colorCount: .two,
                           colors: [SmokeColor(143, 204, 223), SmokeColor(214, 227, 231), SmokeColor(185, 192, 219)])),
        ("Dusk", SmokeStyle(colorCount: .two,
                            colors: [SmokeColor(182, 161, 209), SmokeColor(227, 181, 166), SmokeColor(208, 219, 227)])),
        ("Aurora", SmokeStyle(colorCount: .three,
                              colors: [SmokeColor(156, 202, 194), SmokeColor(172, 186, 222), SmokeColor(210, 176, 211)])),
    ]
}

/// The player's settings, remembered between launches.
@MainActor
@Observable
final class ControlSettings {

    private enum Key {
        static let layout = "controls.layout"
        static let effects = "controls.effects"
        static let smokeStyle = "controls.smokeStyle"
        static let haptics = "controls.haptics"
        static let occluderTool = "occluders.tool"
        static let roomScan = "occluders.roomScan"
        static let transmission = "drive.transmission"
        static let speedUnit = "drive.speedUnit"
        static let instrumentStyle = "drive.instrumentStyle"
        static let handbrakeTopLeft = "controls.handbrakeTopLeft.v1"
    }

    var layout: ControlLayout {
        didSet { persist(layout, forKey: Key.layout) }
    }

    var effectsQuality: EffectsQuality {
        didSet { defaults.set(effectsQuality.rawValue, forKey: Key.effects) }
    }

    var smokeStyle: SmokeStyle {
        didSet { persist(smokeStyle, forKey: Key.smokeStyle) }
    }

    var usesHaptics: Bool {
        didSet { defaults.set(usesHaptics, forKey: Key.haptics) }
    }

    /// Who picks the forward gears. Kept here rather than on the car so that
    /// changing car does not quietly change how it is driven.
    var transmissionMode: TransmissionMode {
        didSet { defaults.set(transmissionMode.rawValue, forKey: Key.transmission) }
    }

    /// What the speedometer counts in. Read-out only — nothing in the
    /// simulation has ever heard of it, so changing it cannot change how the
    /// car drives or which gear it is in.
    var speedUnit: SpeedUnit {
        didSet { defaults.set(speedUnit.rawValue, forKey: Key.speedUnit) }
    }

    var instrumentStyle: InstrumentStyle {
        didSet { defaults.set(instrumentStyle.rawValue, forKey: Key.instrumentStyle) }
    }

    /// Whether the occluder button appears on the driving screen. The tool is
    /// entirely optional — the app works the same without it — so anyone who
    /// does not want it can put it away.
    var showsOccluderTool: Bool {
        didSet { defaults.set(showsOccluderTool, forKey: Key.occluderTool) }
    }

    /// Whether a LiDAR iPhone's room mesh may hide virtual things.
    ///
    /// A reconstructed floor sits a centimetre or two off the real one, which
    /// can swallow something lying flat on the ground — the skid marks are a
    /// millimetre thick. Anyone who sees that can turn the mesh off without
    /// losing people occlusion or their own occluder boxes.
    var usesRoomScanOcclusion: Bool {
        didSet { defaults.set(usesRoomScanOcclusion, forKey: Key.roomScan) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.layout),
           let stored = try? JSONDecoder().decode(ControlLayout.self, from: data) {
            var migrated = stored
            // One-time: bring the handbrake to its new top-left home for layouts saved before it moved.
            if !defaults.bool(forKey: Key.handbrakeTopLeft) {
                migrated.handbrake = ControlLayout.standard.handbrake
                defaults.set(true, forKey: Key.handbrakeTopLeft)
                if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: Key.layout) }
            }
            layout = migrated
        } else {
            defaults.set(true, forKey: Key.handbrakeTopLeft)
            layout = .standard
        }
        effectsQuality = EffectsQuality(rawValue: defaults.string(forKey: Key.effects) ?? "") ?? .full
        if let data = defaults.data(forKey: Key.smokeStyle),
           let stored = try? JSONDecoder().decode(SmokeStyle.self, from: data) {
            smokeStyle = stored
        } else {
            smokeStyle = .default
        }
        usesHaptics = defaults.object(forKey: Key.haptics) as? Bool ?? true
        showsOccluderTool = defaults.object(forKey: Key.occluderTool) as? Bool ?? true
        usesRoomScanOcclusion = defaults.object(forKey: Key.roomScan) as? Bool ?? true
        transmissionMode = TransmissionMode(rawValue: defaults.string(forKey: Key.transmission) ?? "") ?? .automatic
        speedUnit = SpeedUnit(rawValue: defaults.string(forKey: Key.speedUnit) ?? "") ?? .kilometresPerHour
        instrumentStyle = InstrumentStyle(rawValue: defaults.string(forKey: Key.instrumentStyle) ?? "") ?? .digital
    }

    func resetLayout() {
        layout = .standard
    }

    private func persist<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
