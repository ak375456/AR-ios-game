//
//  SmokeTexture.swift
//  vr
//
//  Procedural sprites for the tyre effects.
//

import CoreGraphics
import Foundation
import RealityKit
import UIKit

/// Builds the sprites the effects need, once, at runtime.
///
/// Drawing them rather than shipping images keeps the bundle small and keeps
/// the shapes tunable in one place next to the code that uses them.
@MainActor
enum EffectTextures {

    private static var smoke: [SmokeColor: TextureResource] = [:]
    private static var smokeOrder: [SmokeColor] = []
    private static var skidFade: TextureResource?

    /// A soft, irregular puff. Several overlapping blobs with feathered edges,
    /// so particles do not read as hard white circles.
    static func smokePuff(color: SmokeColor) async -> TextureResource? {
        if let cached = smoke[color] { return cached }
        guard let image = drawSmoke(size: 192, color: color) else { return nil }
        let texture = try? await TextureResource(image: image, options: .init(semantic: .color))
        if let texture {
            smoke[color] = texture
            smokeOrder.append(color)
            // Color picker drags can generate many shades. Active emitters own
            // their textures, so the lookup cache only needs a small window.
            if smokeOrder.count > 12 { smoke[smokeOrder.removeFirst()] = nil }
        }
        return texture
    }

    /// A left-to-right ramp used as an opacity map, so the oldest end of a
    /// skid mark fades out instead of ending abruptly.
    static func skidFadeRamp() async -> TextureResource? {
        if let skidFade { return skidFade }
        guard let image = drawSkidRamp(width: 128, height: 16) else { return nil }
        skidFade = try? await TextureResource(image: image, options: .init(semantic: .raw))
        return skidFade
    }

    static func purge() {
        smoke.removeAll()
        smokeOrder.removeAll()
        skidFade = nil
    }

    // MARK: - Drawing

    private static func drawSmoke(size: Int, color: SmokeColor) -> CGImage? {
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        let centre = Float(size) / 2

        // Four soft lobes at varying offsets give an irregular silhouette that
        // still fades to nothing at the sprite's edge.
        let lobes: [(x: Float, y: Float, radius: Float, weight: Float)] = [
            (0.00, 0.00, 0.40, 1.00),
            (0.16, -0.12, 0.28, 0.75),
            (-0.18, 0.10, 0.30, 0.70),
            (0.04, 0.20, 0.22, 0.55),
        ]

        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<size {
                for x in 0..<size {
                    let px = (Float(x) - centre) / centre
                    let py = (Float(y) - centre) / centre
                    let warpedX = px + 0.055 * sin(py * 9 + px * 3)
                    let warpedY = py + 0.045 * sin(px * 11 - py * 4)

                    var density: Float = 0
                    for lobe in lobes {
                        let dx = warpedX - lobe.x * 2
                        let dy = warpedY - lobe.y * 2
                        let distance = (dx * dx + dy * dy).squareRoot() / (lobe.radius * 2)
                        density += lobe.weight * max(0, 1 - distance * distance)
                    }
                    // Fade hard towards the sprite border so tiles never show.
                    let edge = max(0, 1 - (warpedX * warpedX + warpedY * warpedY))
                    let grain = 0.78 + 0.12 * sin(px * 16 + py * 9)
                        + 0.10 * sin(px * 27 - py * 19)
                    density = pow(min(density, 1), 1.35) * edge * edge * max(grain, 0)

                    let alpha = UInt8(min(max(density, 0), 1) * 140)
                    let index = y * bytesPerRow + x * 4
                    // A little neutral smoke in every tint keeps vivid custom
                    // colors translucent and textured instead of neon discs.
                    let shade = 0.90 + 0.10 * max(grain, 0)
                    buffer[index] = UInt8(min((Float(color.red) * 0.78 + 196 * 0.22) * shade * Float(alpha) / 255, 255))
                    buffer[index + 1] = UInt8(min((Float(color.green) * 0.78 + 196 * 0.22) * shade * Float(alpha) / 255, 255))
                    buffer[index + 2] = UInt8(min((Float(color.blue) * 0.78 + 196 * 0.22) * shade * Float(alpha) / 255, 255))
                    buffer[index + 3] = alpha
                }
            }
        }
        return makeImage(&pixels, width: size, height: size)
    }

    private static func drawSkidRamp(width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<height {
                // Soft edges across the width of the tyre.
                let v = Float(y) / Float(height - 1)
                let across = 1 - pow(abs(v * 2 - 1), 3)
                for x in 0..<width {
                    let u = Float(x) / Float(width - 1)
                    let along = pow(1 - u, 1.4)
                    let value = UInt8(min(max(across * along, 0), 1) * 255)
                    let index = y * bytesPerRow + x * 4
                    buffer[index] = value
                    buffer[index + 1] = value
                    buffer[index + 2] = value
                    buffer[index + 3] = 255
                }
            }
        }
        return makeImage(&pixels, width: width, height: height)
    }

    private static func makeImage(_ pixels: inout [UInt8], width: Int, height: Int) -> CGImage? {
        pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
    }
}
