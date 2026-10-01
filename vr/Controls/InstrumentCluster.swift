//
//  InstrumentCluster.swift
//  vr
//
//  Digital and analog speed, gear, and RPM displays.
//

import Observation
import SwiftUI

/// What the cluster is showing.
///
/// Separate from the simulation, and deliberately lazy about updating: the
/// physics runs at 180 Hz and the renderer at 60 or 120, but a number a person
/// is reading only needs to change when it has something new to say. Every
/// value here is quantised and only written when it actually differs, so the
/// cluster redraws a handful of times a second instead of every frame.
///
/// Nothing here computes a speed or an engine speed of its own: every figure
/// arrives from `VehicleDynamics` and `Drivetrain` and is only rounded for
/// reading. The dials cannot disagree with the car.
@MainActor
@Observable
final class DriveInstruments {

    /// Whole units of the chosen scale, already converted.
    private(set) var speed: Int = 0
    private(set) var unit: SpeedUnit = .kilometresPerHour
    /// `R`, `N`, `1`, `2`, …
    private(set) var gear: String = "N"
    private(set) var mode: TransmissionMode = .automatic
    /// 0...1 of the redline, quantised.
    private(set) var revFraction: Double = 0
    private(set) var engineRPM: Int = 0
    private(set) var redlineRPM: Int = 7000
    /// This car's idle, so a parked car reads its own tickover rather than zero.
    private(set) var idleRPM: Int = 0
    /// Rounded dial limit in the currently selected speed unit…
    private(set) var speedScale: Int = 100
    /// …and how much of it sits between two numbered ticks.
    private(set) var speedStep: Int = 20
    /// The tachometer's full scale, always a whole number of thousands, and the
    /// gap between its numbered ticks.
    private(set) var tachScale: Int = 8000
    private(set) var tachStep: Int = 1000
    private(set) var isShifting = false
    /// Bumped whenever a requested shift was turned down, so the interface can
    /// flash once without having to know why it was asked.
    private(set) var refusalPulse: Int = 0

    /// How quickly the displayed speed follows the car, per second. Fast
    /// enough that the number answers the pedal, slow enough that it is not
    /// chasing the last digit of a physics step.
    private static let speedResponse: Float = 11
    /// How far the true speed has to be from the number on screen before the
    /// number moves. Without this the read-out flickers between two adjacent
    /// values whenever the car sits near a boundary.
    private static let speedDeadband: Float = 0.62
    /// The rev display is drawn in steps this size, so a sweeping needle does not
    /// rebuild the view on every frame.
    private static let revStep: Double = 0.01
    /// How much dial is left past the car's top speed, so the needle has
    /// somewhere to sit at full chat instead of pinning against the last tick.
    private static let speedHeadroom: Float = 1.15
    /// The same, past the rev limiter — this is the room the red zone lives in.
    private static let revHeadroom: Float = 1.12

    @ObservationIgnored private var filteredSpeed: Float = 0
    @ObservationIgnored private var lastRefusals = 0

    /// Takes one frame's readings.
    func update(renderedSpeed: Float,
                readout: DrivetrainReadout,
                maxRenderedSpeed: Float,
                unit: SpeedUnit,
                mode: TransmissionMode,
                deltaTime: Float) {

        let unitChanged = unit != self.unit
        if unitChanged { self.unit = unit }
        if mode != self.mode { self.mode = mode }

        let blend = min(max(Self.speedResponse * deltaTime, 0), 1)
        filteredSpeed += (renderedSpeed - filteredSpeed) * blend
        if renderedSpeed == 0, filteredSpeed < 0.004 { filteredSpeed = 0 }

        let display = SimulationScale.displaySpeed(renderedMetresPerSecond: filteredSpeed, unit: unit)
        // A changed unit has to land immediately; otherwise the deadband would
        // leave the old scale's number on screen until the car sped up.
        if unitChanged || abs(display - Float(speed)) >= Self.speedDeadband {
            let rounded = Int(max(display, 0).rounded())
            if rounded != speed { speed = rounded }
        }

        let label = readout.gear.label
        if label != gear { gear = label }
        if readout.isShifting != isShifting { isShifting = readout.isShifting }

        let revs = (Double(readout.revFraction) / Self.revStep).rounded() * Self.revStep
        if revs != revFraction { revFraction = revs }
        let rpm = Int((readout.engineRPM / 50).rounded()) * 50
        if rpm != engineRPM { engineRPM = rpm }
        let redline = Int(readout.redlineRPM.rounded())
        if redline != redlineRPM { redlineRPM = redline }
        let idle = Int((readout.idleRPM / 50).rounded()) * 50
        if idle != idleRPM { idleRPM = idle }

        // Both dials are sized from the car that is actually being driven: the
        // speedometer from its top speed in whichever unit is showing, the
        // tachometer from its own limiter. Changing car, or changing unit,
        // re-scales them.
        let maximum = SimulationScale.displaySpeed(renderedMetresPerSecond: maxRenderedSpeed,
                                                   unit: unit)
        let speedDial = Self.dialScale(atLeast: maximum * Self.speedHeadroom)
        if speedDial.scale != speedScale { speedScale = speedDial.scale }
        if speedDial.step != speedStep { speedStep = speedDial.step }

        let revDial = Self.tachometerScale(redlineRPM: redline, headroom: Self.revHeadroom)
        if revDial.scale != tachScale { tachScale = revDial.scale }
        if revDial.step != tachStep { tachStep = revDial.step }

        if readout.refusals != lastRefusals {
            lastRefusals = readout.refusals
            refusalPulse &+= 1
        }
    }

    /// Back to a parked car, without waiting for the filter to catch up.
    func clear() {
        filteredSpeed = 0
        if speed != 0 { speed = 0 }
        if gear != "N" { gear = "N" }
        if isShifting { isShifting = false }
        // A stopped engine is still running: the tachometer drops to this car's
        // tickover, which is where the next frame of simulation will put it too.
        if engineRPM != idleRPM { engineRPM = idleRPM }
        let idling = (Double(idleRPM) / Double(max(redlineRPM, 1)) / Self.revStep)
            .rounded() * Self.revStep
        if revFraction != idling { revFraction = idling }
    }

    // MARK: - Choosing a scale

    /// A round dial limit at or above `needed`, with the value that sits
    /// between two numbered ticks.
    ///
    /// Picked from steps a driver expects to read — 10s, 20s, 25s, 50s — rather
    /// than from whatever the car's top speed happens to convert to, so the
    /// printed numbers are always whole and evenly spaced. Every car in the
    /// garage gets its own answer, and so does each unit.
    static func dialScale(atLeast needed: Float) -> (scale: Int, step: Int) {
        let steps = [5, 10, 20, 25, 50, 100]
        let counts = [4, 5, 6]
        var best: (scale: Int, step: Int)?
        for step in steps {
            for count in counts {
                let scale = step * count
                guard Float(scale) >= needed else { continue }
                if best == nil || scale < best!.scale { best = (scale, step) }
            }
        }
        // Nothing on the ladder is big enough — only reachable if a car is ever
        // given a top speed far beyond anything in the garage.
        if let best { return best }
        let hundreds = max(Int((needed / 100).rounded(.up)), 1)
        return (hundreds * 100, max(hundreds / 6, 1) * 100)
    }

    /// The tachometer's scale, in whole thousands, and its label step.
    ///
    /// The headroom is deliberate: it is what leaves room between the car's
    /// real redline and the end of the dial for a red zone that starts exactly
    /// at the limiter. Past ten thousand the numbers stop fitting one to a
    /// thousand, so they go up in twos instead.
    static func tachometerScale(redlineRPM: Int, headroom: Float) -> (scale: Int, step: Int) {
        let needed = Float(max(redlineRPM, 500)) * headroom
        var thousands = max(Int((needed / 1000).rounded(.up)), 2)
        guard thousands >= 10 else { return (thousands * 1000, 1000) }
        if !thousands.isMultiple(of: 2) { thousands += 1 }
        return (thousands * 1000, 2000)
    }
}

/// Compact speed, gear, and RPM readout for the bottom of the drive screen.
struct DigitalInstrumentCluster: View {

    let instruments: DriveInstruments

    @State private var isFlashing = false

    private var chipColour: Color {
        if isFlashing { return Color(red: 1.0, green: 0.42, blue: 0.38) }
        return instruments.mode == .manual
            ? Color(red: 0.72, green: 0.88, blue: 1.0)
            : .white.opacity(0.92)
    }

    private var redlineTint: Color {
        switch instruments.revFraction {
        case ..<0.72: return Color(red: 0.36, green: 0.86, blue: 0.62)
        case ..<0.90: return Color(red: 1.0, green: 0.76, blue: 0.24)
        default:      return Color(red: 1.0, green: 0.36, blue: 0.33)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            gearChip
            // Monospaced so the number does not shuffle sideways as it
            // climbs, and drawn plainly: a rolling-digit transition spends the
            // whole of an acceleration run mid-animation, which reads as a
            // blur rather than as a speed.
            Text("\(instruments.speed)")
                .font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
            Text(instruments.unit.abbreviation)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
            if instruments.mode == .manual {
                Text("\(instruments.engineRPM)").font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(GaragePalette.neon).accessibilityLabel("\(instruments.engineRPM) RPM")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 12)
        // The rev bar is an overlay rather than another row so that it takes
        // the cluster's width instead of setting it. A shape in the stack is
        // greedy, and the cluster would stretch from one column of buttons to
        // the other rather than sitting neatly between them.
        .overlay(alignment: .bottom) { if instruments.mode == .manual { revBar } }
        .background(GaragePalette.midnight.opacity(0.90), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .onChange(of: instruments.refusalPulse) { _, _ in
            withAnimation(.easeOut(duration: 0.08)) { isFlashing = true }
            withAnimation(.easeIn(duration: 0.28).delay(0.08)) { isFlashing = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Manual tints the chip the same blue as the shift buttons, so which mode
    /// the car is in can be read from the cluster without counting whether the
    /// gears are changing on their own.
    private var gearChip: some View {
        Text(instruments.gear)
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(.black.opacity(0.82))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(chipColour)
            )
            .opacity(instruments.isShifting ? 0.55 : 1)
            .animation(.easeOut(duration: 0.1), value: instruments.isShifting)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
    }

    private var revBar: some View {
        Capsule()
            .fill(.white.opacity(0.14))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(redlineTint)
                    .scaleEffect(x: max(instruments.revFraction, 0.015), anchor: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .animation(.easeOut(duration: 0.09), value: instruments.revFraction)
    }

    private var accessibilityDescription: String {
        let unit = instruments.unit == .kilometresPerHour ? "kilometres per hour" : "miles per hour"
        let gear: String
        switch instruments.gear {
        case "R": gear = "reverse"
        case "N": gear = "neutral"
        default:  gear = "gear \(instruments.gear)"
        }
        let mode = instruments.mode == .manual ? "manual" : "automatic"
        return "\(instruments.speed) \(unit), \(instruments.engineRPM) RPM, \(gear), \(mode)"
    }
}

struct InstrumentCluster: View {
    let instruments: DriveInstruments
    let style: InstrumentStyle
    /// How much width the panel has been given. The dials are sized from it so
    /// a small iPhone gets smaller dials rather than clipped labels.
    var availableWidth: CGFloat = 360

    static func footprint(style: InstrumentStyle, width: CGFloat) -> CGSize {
        if style == .digital { return CGSize(width: min(width, 200), height: 54) }
        let metrics = ClusterMetrics(width: width)
        return CGSize(width: metrics.panelWidth, height: metrics.dial + metrics.verticalPadding * 2)
    }

    var body: some View {
        Group {
            if style == .analog {
                AnalogInstrumentCluster(instruments: instruments, availableWidth: availableWidth)
            } else {
                DigitalInstrumentCluster(instruments: instruments)
            }
        }
        // The panel sits over the driving controls, and must never take a touch
        // meant for the wheel or a pedal.
        .allowsHitTesting(false)
    }
}

// MARK: - Analogue panel

/// The colours the dials are drawn in. One cyan for road speed, one red for the
/// limiter, and white for everything that has to be read rather than noticed.
private enum DialPalette {
    static let accent = Color(red: 0.24, green: 0.81, blue: 0.93)
    static let warning = Color(red: 0.95, green: 0.25, blue: 0.22)
    static let manual = Color(red: 0.72, green: 0.90, blue: 1.0)
}

/// Every size in the panel, worked out once from the width it has to live in.
///
/// One place for all of it so that shrinking the dials on a small iPhone also
/// shrinks the type, the gear badge and the padding by the same amount — which
/// is what stops labels colliding instead of merely getting smaller.
private struct ClusterMetrics {

    /// Dial diameter, and the size everything else is a fraction of.
    let dial: CGFloat
    let badge: CGFloat
    let gearColumn: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    let cornerRadius: CGFloat
    let panelWidth: CGFloat

    init(width: CGFloat) {
        // Wide enough to read on the smallest iPhone, capped so that the panel
        // never grows into the lower half of the camera view on the largest.
        let panel = min(max(width, 210), 230)
        panelWidth = panel
        dial = min(max(panel * 0.29, 62), 106)
        badge = min(max(dial * 0.30, 22), 33)
        gearColumn = badge + 24
        verticalPadding = max(dial * 0.090, 6)
        horizontalPadding = max(dial * 0.06, 4)
        cornerRadius = dial * 0.24
    }
}

/// Two dials and the engaged gear on a slab of dark glass.
///
/// The speedometer follows `DriveInstruments.speed` and the tachometer follows
/// `DriveInstruments.engineRPM`, which are the simulation's own figures rounded
/// for reading — the needle, the tick it points at and the number in the middle
/// are all the same value, so they cannot drift apart.
private struct AnalogInstrumentCluster: View {

    let instruments: DriveInstruments
    let availableWidth: CGFloat

    private var metrics: ClusterMetrics { ClusterMetrics(width: availableWidth) }

    var body: some View {
        let metrics = self.metrics
        return HStack(spacing: 0) {
            SpeedometerDial(instruments: instruments, diameter: metrics.dial)
                .frame(maxWidth: .infinity)
            GearBadge(instruments: instruments, metrics: metrics)
                .frame(width: metrics.gearColumn)
            TachometerDial(instruments: instruments, diameter: metrics.dial)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, metrics.verticalPadding)
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(maxWidth: metrics.panelWidth)
        .background {
            // Charcoal rather than a blur: the camera frame behind it is being
            // recorded, and a material would cost a full-screen pass every
            // frame of the video for no more legibility than this.
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(white: 0.15).opacity(0.72),
                                            Color(white: 0.05).opacity(0.80)],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .overlay {
            // The hairline is what holds the panel's edge against a dark floor,
            // where the fill alone would have nothing to show against.
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.38), radius: 12, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let unit = instruments.unit == .kilometresPerHour ? "kilometres per hour" : "miles per hour"
        let gear: String
        switch instruments.gear {
        case "R": gear = "reverse"
        case "N": gear = "neutral"
        default:  gear = "gear \(instruments.gear)"
        }
        let mode = instruments.mode == .manual ? "manual" : "automatic"
        return "\(instruments.speed) \(unit), \(instruments.engineRPM) RPM, \(gear), \(mode)"
    }
}

/// How long a needle takes to reach a new reading. Short enough that the dial
/// answers the pedal rather than trailing it, long enough to smooth the step
/// between two quantised readings into a sweep.
private let needleResponse = Animation.easeOut(duration: 0.09)

/// Road speed, with the figure repeated in the middle so it can be read at a
/// glance without interpreting the needle.
private struct SpeedometerDial: View {

    let instruments: DriveInstruments
    let diameter: CGFloat

    private var fraction: Double {
        guard instruments.speedScale > 0 else { return 0 }
        return min(max(Double(instruments.speed) / Double(instruments.speedScale), 0), 1)
    }

    var body: some View {
        ZStack {
            DialFace(diameter: diameter,
                     scale: instruments.speedScale,
                     step: instruments.speedStep,
                     divisor: 1,
                     redlineFraction: nil,
                     accent: DialPalette.accent)
                .equatable()

            // The live half of the cyan accent: an arc that fills round the rim
            // as the car speeds up, on the same animation as the needle so the
            // two always agree.
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .rotation(.degrees(135))
                .stroke(DialPalette.accent,
                        style: StrokeStyle(lineWidth: diameter * 0.030, lineCap: .round))
                .padding(diameter * 0.045)

            // Started clear of the middle so it never crosses the number.
            NeedleShape(innerFraction: 0.36, tipFraction: 0.79,
                        baseWidth: 0.032, tipWidth: 0.016)
                .fill(DialPalette.accent)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .rotationEffect(.degrees(-135 + 270 * fraction))

            readout
        }
        .frame(width: diameter, height: diameter)
        .animation(needleResponse, value: fraction)
    }

    /// Sized to stay inside the ring of numbers: the dial is clear to about
    /// 0.27 of its diameter from the middle, and this has to fit in that.
    private var readout: some View {
        VStack(spacing: diameter * 0.005) {
            Text("\(instruments.speed)")
                .font(.system(size: diameter * 0.235, weight: .semibold, design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(instruments.unit.abbreviation)
                .font(.system(size: diameter * 0.080, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.60))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: diameter * 0.50)
        .offset(y: diameter * 0.035)
    }
}

/// Engine speed, with the red zone starting at this car's own limiter.
private struct TachometerDial: View {

    let instruments: DriveInstruments
    let diameter: CGFloat

    private var fraction: Double {
        guard instruments.tachScale > 0 else { return 0 }
        return min(max(Double(instruments.engineRPM) / Double(instruments.tachScale), 0), 1)
    }

    /// Where the red begins, as a share of the dial. `tachScale` is chosen with
    /// headroom past the redline precisely so this is never the very last tick.
    private var redlineFraction: Double {
        guard instruments.tachScale > 0 else { return 1 }
        return min(max(Double(instruments.redlineRPM) / Double(instruments.tachScale), 0), 1)
    }

    var body: some View {
        ZStack {
            DialFace(diameter: diameter,
                     scale: instruments.tachScale,
                     step: instruments.tachStep,
                     divisor: 1000,
                     redlineFraction: redlineFraction,
                     accent: nil)
                .equatable()

            // Kept inside the clear middle of the dial and above the pivot, so
            // it never runs into the numbers around the rim.
            Text("×1000 RPM")
                .font(.system(size: diameter * 0.066, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: diameter * 0.44)
                .offset(y: -diameter * 0.105)

            NeedleShape(innerFraction: -0.15, tipFraction: 0.79,
                        baseWidth: 0.038, tipWidth: 0.016)
                .fill(DialPalette.warning)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .rotationEffect(.degrees(-135 + 270 * fraction))

            Circle()
                .fill(.white)
                .frame(width: diameter * 0.062, height: diameter * 0.062)
        }
        .frame(width: diameter, height: diameter)
        .animation(needleResponse, value: fraction)
    }
}

/// The part of a dial that only changes when the car does.
///
/// Ticks, numbers and the coloured rim go into one `Canvas`; the needle is a
/// separate rotated shape on top. That split is what keeps a sweeping gauge
/// cheap — the face is drawn when the scale changes and left alone after that,
/// and the needle animates as a transform rather than as a redraw.
private struct DialFace: View, Equatable {

    let diameter: CGFloat
    /// Full-scale reading, in the dial's own units.
    let scale: Int
    /// How much sits between two numbered ticks.
    let step: Int
    /// What the printed numbers are divided by — 1000 on the tachometer.
    let divisor: Int
    /// Where the red zone starts, 0...1, or `nil` on a dial that has none.
    let redlineFraction: Double?
    /// Colour of the rim flourish at the bottom of the scale.
    let accent: Color?

    /// Five minor divisions to a numbered tick, which is what a driver expects
    /// to count without having to.
    private static let minorPerMajor = 5

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            // Ticks live in the outer band and the numbers just inside them,
            // which leaves the middle of the dial clear for the read-out. The
            // clear radius that falls out of this — a little over half the
            // diameter — is what the centre type is sized against.
            let side = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let rim = side * 0.470
            let tickOuter = side * 0.436
            let majorInner = side * 0.382
            let minorInner = side * 0.409
            let labelRadius = side * 0.320

            // The scale sweeps 270°, from lower left round to lower right.
            func point(_ fraction: Double, _ radius: CGFloat) -> CGPoint {
                let angle = CGFloat.pi * (0.75 + 1.5 * fraction)
                return CGPoint(x: centre.x + cos(angle) * radius,
                               y: centre.y + sin(angle) * radius)
            }

            // Arcs are drawn as short chords rather than with `addArc`, so the
            // direction is the same one the tick angles use and a fading colour
            // can be applied segment by segment.
            func strokeArc(from start: Double, to end: Double, width: CGFloat,
                           colour: (Double) -> Color) {
                let segments = max(Int((end - start) * 110), 2)
                for index in 0..<segments {
                    let a = start + (end - start) * Double(index) / Double(segments)
                    let b = start + (end - start) * Double(index + 1) / Double(segments)
                    var chord = Path()
                    chord.move(to: point(a, rim))
                    chord.addLine(to: point(b, rim))
                    context.stroke(chord, with: .color(colour((a + b) / 2)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            }

            if let accent {
                // A flourish, not a reading: it fades out over the first part of
                // the sweep and leaves the rest of the rim to the numbers.
                strokeArc(from: 0, to: 0.46, width: side * 0.030) { fraction in
                    accent.opacity(0.62 * (1 - fraction / 0.46))
                }
            }

            if let redlineFraction, redlineFraction < 1 {
                strokeArc(from: redlineFraction, to: 1, width: side * 0.032) { _ in
                    DialPalette.warning.opacity(0.92)
                }
            }

            let majors = max(scale / max(step, 1), 1)
            let divisions = majors * Self.minorPerMajor
            for tick in 0...divisions {
                let fraction = Double(tick) / Double(divisions)
                let isMajor = tick.isMultiple(of: Self.minorPerMajor)
                let isRed = redlineFraction.map { fraction >= $0 - 1e-6 } ?? false

                var mark = Path()
                mark.move(to: point(fraction, isMajor ? majorInner : minorInner))
                mark.addLine(to: point(fraction, tickOuter))
                context.stroke(
                    mark,
                    with: .color(isRed ? DialPalette.warning
                                       : .white.opacity(isMajor ? 0.95 : 0.48)),
                    style: StrokeStyle(lineWidth: side * (isMajor ? 0.022 : 0.011))
                )

                guard isMajor else { continue }
                // Numbers stay white even inside the red zone: a red number this
                // small on charcoal is the one thing on the dial that stops
                // being readable.
                let value = Int((Double(scale) * fraction / Double(max(divisor, 1))).rounded())
                context.draw(
                    context.resolve(
                        Text("\(value)")
                            .font(.system(size: side * 0.086, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                    ),
                    at: point(fraction, labelRadius)
                )
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// A tapered needle pointing straight up, for a caller to rotate.
///
/// `innerFraction` is where it starts: positive leaves the middle of the dial
/// clear for a number, negative carries the tail across the pivot the way a
/// counterweighted needle does.
private struct NeedleShape: Shape {

    var innerFraction: CGFloat
    var tipFraction: CGFloat
    /// Half-widths, as fractions of the dial's radius.
    var baseWidth: CGFloat
    var tipWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let tip = centre.y - radius * tipFraction
        let base = centre.y - radius * innerFraction
        let half = radius * baseWidth
        let point = radius * tipWidth

        var path = Path()
        path.move(to: CGPoint(x: centre.x - point, y: tip))
        path.addLine(to: CGPoint(x: centre.x + point, y: tip))
        path.addLine(to: CGPoint(x: centre.x + half, y: base))
        path.addLine(to: CGPoint(x: centre.x - half, y: base))
        path.closeSubpath()
        return path
    }
}

/// The engaged gear, between the dials.
///
/// Manual tints it the same blue as the shift buttons, so which mode the car is
/// in can be read from the panel; a refused shift flashes it red once, which is
/// the only reply the gearbox gives when it turns a request down.
private struct GearBadge: View {

    let instruments: DriveInstruments
    let metrics: ClusterMetrics

    @State private var isFlashing = false

    private var tint: Color {
        if isFlashing { return DialPalette.warning }
        return instruments.mode == .manual ? DialPalette.manual : .white
    }

    var body: some View {
        VStack(spacing: metrics.badge * 0.30) {
            rule
            Text(instruments.gear)
                .font(.system(size: metrics.badge * 0.62, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: metrics.badge, height: metrics.badge * 1.08)
                .background {
                    RoundedRectangle(cornerRadius: metrics.badge * 0.28, style: .continuous)
                        .fill(.black.opacity(0.40))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.badge * 0.28, style: .continuous)
                        .strokeBorder(tint.opacity(isFlashing ? 0.9 : 0.42), lineWidth: 1)
                }
                .opacity(instruments.isShifting ? 0.5 : 1)
                .animation(.easeOut(duration: 0.1), value: instruments.isShifting)
                .animation(.easeOut(duration: 0.12), value: isFlashing)
            rule
        }
        .onChange(of: instruments.refusalPulse) { _, _ in
            withAnimation(.easeOut(duration: 0.08)) { isFlashing = true }
            withAnimation(.easeIn(duration: 0.28).delay(0.08)) { isFlashing = false }
        }
    }

    private var rule: some View {
        Capsule()
            .fill(.white.opacity(0.22))
            .frame(width: metrics.badge * 0.66, height: 1.5)
    }
}
