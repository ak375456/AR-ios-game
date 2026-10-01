//
//  TireSmoke.swift
//  vr
//
//  Smoke off the rear tyres, driven by how hard they are actually sliding.
//

import Foundation
import RealityKit
import simd
import UIKit

/// Particle emitters at the rear contact patches.
///
/// The emitters are children of the *placement anchor*, not of the car, and
/// their particles are configured not to inherit the emitter's transform. A
/// puff therefore stays exactly where the tyre was when it was born: the car
/// drives away and leaves the smoke behind, instead of dragging a cloud along
/// with it.
///
/// Emission comes from `VehicleTelemetry` — the rear axle's real sideways slip
/// speed plus the longitudinal slip estimate — never from whether a button is
/// held. A gentle steering correction makes a wisp, a sustained slide makes a
/// trail, and a parked car makes nothing.
@MainActor
final class TireSmoke {

    /// Tuning, all in one place.
    private enum Tuning {
        /// Rear slip speed at which smoke starts and reaches full strength, m/s.
        static let slipStart: Float = 0.17
        static let slipFull: Float = 1.05
        /// Car speed over which sideways slip counts as a slide rather than a
        /// stationary scrub.
        static let movingSpeed: Float = 0.30
        /// Particles per second per wheel at full intensity.
        static let maxBirthRate: Float = 52
        /// Puff size at birth as a fraction of wheel radius. Puffs start tight
        /// at the tyre and billow out to several times this as they age.
        static let sizePerWheelRadius: Float = 0.6
        /// Real tyre smoke hangs in the air; a hard slide leaves a lingering cloud.
        static let lifeSpanRange: ClosedRange<Double> = 1.1...2.5
        /// Below this the emitter is switched off entirely.
        static let cutoff: Float = 0.02
    }

    private var emitters: [Entity] = []
    private var emitterWheels: [Int] = []
    private var retiredEmitters: [Entity] = []
    private var colorsPerWheel = 1
    private var isAttached = false
    private var wheelRadius: Float = 0.05
    private var smoothedIntensity: Float = 0
    private var style: SmokeStyle = .default
    private var anchor: Entity?
    private var rig: CarRig?
    private var generation = 0
    private var pendingStyleTask: Task<Void, Never>?

    func setStyle(_ newStyle: SmokeStyle) {
        guard style != newStyle else { return }
        style = newStyle
        generation += 1 // Invalidate any texture load already in flight.
        guard let anchor, let rig else { return }
        let revision = generation
        pendingStyleTask?.cancel()
        pendingStyleTask = Task { [weak self, weak anchor] in
            // The system picker sends many intermediate shades while dragging.
            // Only build the settled choice; existing smoke keeps flowing.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self, let anchor,
                  self.anchor === anchor else { return }
            await self.rebuild(to: anchor, rig: rig, revision: revision)
        }
    }

    // MARK: - Lifecycle

    /// Creates the emitters and parents them to the placement anchor.
    func attach(to anchor: Entity, rig: CarRig) async {
        detach()
        self.anchor = anchor
        self.rig = rig
        wheelRadius = rig.wheelRadius
        await rebuild(to: anchor, rig: rig, revision: generation)
    }

    private func rebuild(to anchor: Entity, rig: CarRig, revision: Int) async {
        let selected = style.activeColors
        var textures: [TextureResource?] = []
        for color in selected {
            textures.append(await EffectTextures.smokePuff(color: color))
            guard generation == revision else { return }
        }

        let layers = style.colorCount == .three ? 3 : 1
        var nextEmitters: [Entity] = []
        var nextWheels: [Int] = []
        for wheel in rig.rearContactPatches.indices {
            let colorIndices: [Int]
            switch style.colorCount {
            case .one: colorIndices = [0]
            case .two: colorIndices = [wheel % 2]
            case .three: colorIndices = [0, 1, 2]
            }
            for colorIndex in colorIndices {
                let entity = Entity()
                entity.components.set(makeEmitter(texture: textures[colorIndex]))
                anchor.addChild(entity)
                nextEmitters.append(entity)
                nextWheels.append(wheel)
            }
        }

        retire(emitters)
        emitters = nextEmitters
        emitterWheels = nextWheels
        colorsPerWheel = layers
        isAttached = true
    }

    /// Old particles finish their natural fade after a color change. Keeping
    /// retired emitters briefly also avoids recoloring particles in flight.
    private func retire(_ old: [Entity]) {
        guard !old.isEmpty else { return }
        for entity in old {
            guard var emitter = entity.components[ParticleEmitterComponent.self] else { continue }
            emitter.isEmitting = false
            entity.components.set(emitter)
        }
        retiredEmitters.append(contentsOf: old)
        while retiredEmitters.count > 12 {
            let oldest = retiredEmitters.removeFirst()
            oldest.components.remove(ParticleEmitterComponent.self)
            oldest.removeFromParent()
        }
        Task { [weak self] in
            // Longest life is 2.5 s plus variation; let every retired puff finish.
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard let self else { return }
            for entity in old {
                entity.components.remove(ParticleEmitterComponent.self)
                entity.removeFromParent()
                self.retiredEmitters.removeAll { $0 === entity }
            }
        }
    }

    /// Removes every emitter. Called when the car changes, placement is reset,
    /// or the screen goes away, so effects can never outlive their car.
    func detach() {
        generation += 1
        pendingStyleTask?.cancel()
        pendingStyleTask = nil
        for entity in emitters + retiredEmitters {
            entity.components.remove(ParticleEmitterComponent.self)
            entity.removeFromParent()
        }
        emitters.removeAll()
        emitterWheels.removeAll()
        retiredEmitters.removeAll()
        isAttached = false
        smoothedIntensity = 0
        anchor = nil
        rig = nil
    }

    /// Stops new puffs immediately; whatever is already in the air fades out
    /// on its own.
    func stopEmitting() {
        smoothedIntensity = 0
        for entity in emitters {
            guard var emitter = entity.components[ParticleEmitterComponent.self] else { continue }
            emitter.isEmitting = false
            entity.components.set(emitter)
        }
    }

    // MARK: - Per-frame

    /// - Parameters:
    ///   - patches: rear contact patches in the anchor's space.
    ///   - telemetry: what the tyres are doing this frame.
    ///   - speed: the car's speed, m/s.
    ///   - deltaTime: seconds since the last update.
    func update(patches: [SIMD3<Float>], telemetry: VehicleTelemetry,
                speed: Float, deltaTime: Float) {
        guard isAttached, !emitters.isEmpty else { return }

        // Sideways slip only counts as sliding if the car is going somewhere;
        // longitudinal slip is wheelspin and counts even from a standstill.
        let moving = min(speed / Tuning.movingSpeed, 1)
        let gripLoss = clamp((telemetry.rearGripUsage - 0.5) / 0.7, 0, 1)
        let lateral = telemetry.rearLateralSlipSpeed * moving * (0.4 + 0.6 * gripLoss)
        let longitudinal = telemetry.rearLongitudinalSlipSpeed
        let slip = (lateral * lateral + longitudinal * longitudinal).squareRoot()

        let raw = clamp((slip - Tuning.slipStart) / (Tuning.slipFull - Tuning.slipStart), 0, 1)
        // Smooth so density follows the slide rather than flickering with it.
        let response: Float = raw > smoothedIntensity ? 6.5 : 3.0
        let blend = 1 - exp(-response * min(max(deltaTime, 0), 0.05))
        smoothedIntensity += (raw - smoothedIntensity) * blend

        let intensity = smoothedIntensity
        let shouldEmit = intensity > Tuning.cutoff

        for (index, entity) in emitters.enumerated() {
            let wheelIndex = emitterWheels[index]
            if wheelIndex < patches.count {
                entity.position = patches[wheelIndex] + SIMD3(0, wheelRadius * 0.25, 0)
            }
            guard var emitter = entity.components[ParticleEmitterComponent.self] else { continue }

            emitter.isEmitting = shouldEmit && wheelIndex < patches.count
            emitter.mainEmitter.birthRate = Tuning.maxBirthRate * intensity / Float(colorsPerWheel)
            emitter.mainEmitter.size = wheelRadius * Tuning.sizePerWheelRadius * (0.7 + 0.6 * intensity)
            emitter.mainEmitter.sizeVariation = emitter.mainEmitter.size * 0.45
            emitter.mainEmitter.lifeSpan = Tuning.lifeSpanRange.lowerBound
                + Double(intensity) * (Tuning.lifeSpanRange.upperBound - Tuning.lifeSpanRange.lowerBound)
            // Harder slides throw the smoke out further.
            emitter.speed = 0.03 + 0.09 * intensity
            entity.components.set(emitter)
        }
    }

    // MARK: - Emitter setup

    private func makeEmitter(texture: TextureResource?) -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()

        emitter.emitterShape = .sphere
        // About a tyre's width, so the cloud comes off the whole tread.
        emitter.emitterShapeSize = SIMD3(repeating: wheelRadius * 0.35)
        emitter.birthLocation = .volume
        emitter.birthDirection = .local
        emitter.emissionDirection = SIMD3(0, 1, 0)
        emitter.speed = 0.035
        emitter.speedVariation = 0.03
        emitter.isEmitting = false
        emitter.simulationState = .play

        // The whole point: a puff belongs to the world, not to the car.
        emitter.particlesInheritTransform = false
        emitter.fieldSimulationSpace = .global

        var main = ParticleEmitterComponent.ParticleEmitter()
        main.birthRate = 0
        main.size = wheelRadius * Tuning.sizePerWheelRadius
        main.sizeVariation = main.size * 0.45
        main.lifeSpan = Tuning.lifeSpanRange.lowerBound
        main.lifeSpanVariation = 0.4
        // A wide cone rolls the smoke out low across the ground first; the
        // damping stops that push and the cloud then rises slowly.
        main.spreadingAngle = 0.85
        main.acceleration = SIMD3(0, 0.016, 0)
        main.dampingFactor = 2.2
        // Expands fast while it is fresh, then slows, as a real billow does.
        main.sizeMultiplierAtEndOfLifespan = 4.6
        main.sizeMultiplierAtEndOfLifespanPower = 0.5
        main.opacityCurve = .quickFadeInOut
        // Thick and bright off the tyre, thinning and cooling to a soft grey as
        // it spreads. Multiplies the sprite, so custom colors keep their hue.
        main.color = .evolving(start: .single(UIColor(white: 1, alpha: 1)),
                               end: .single(UIColor(red: 0.86, green: 0.88, blue: 0.9, alpha: 0.3)))
        // Varied rotation keeps repeated sprites from reading as copies; slow
        // turning reads as rolling smoke rather than spinning cards.
        main.angleVariation = .pi
        main.angularSpeed = 0.2
        main.angularSpeedVariation = 0.6
        main.noiseStrength = 0.09
        main.noiseScale = 1.3
        main.noiseAnimationSpeed = 0.25
        main.billboardMode = .billboard
        main.blendMode = .alpha
        main.sortOrder = .decreasingAge
        main.isLightingEnabled = false
        main.image = texture

        emitter.mainEmitter = main
        return emitter
    }
}

private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}
