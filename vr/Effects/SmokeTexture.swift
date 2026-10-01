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

    /// A puff's density and self-shadowed brightness, shared by every tint.
    private typealias SmokeShape = (size: Int, density: [Float], light: [Float])

    private static var smoke: [SmokeColor: TextureResource] = [:]
    private static var smokeOrder: [SmokeColor] = []
    private static var smokeShape: SmokeShape?
    private static var skidFade: TextureResource?

    /// A billowing, self-shadowed puff with wispy, irregular edges, so particles
    /// read as volumes of smoke rather than soft discs.
    static func smokePuff(color: SmokeColor) async -> TextureResource? {
        if let cached = smoke[color] { return cached }
        let shape: SmokeShape
        if let smokeShape {
            shape = smokeShape
        } else {
            // Fractal noise is the expensive part; build it once, off the main thread.
            shape = await Task.detached(priority: .userInitiated) { EffectTextures.makeSmokeShape(size: 256) }.value
            smokeShape = shape
        }
        guard let image = tintSmoke(shape, color: color) else { return nil }
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
        smokeShape = nil
        skidFade = nil
    }

    // MARK: - Drawing

    /// Density: a domain-warped fractal billow inside a ragged, noisy silhouette
    /// that always reaches zero at the sprite border. Light: relief shading from
    /// one side, so each lump is bright where it faces the light and shaded
    /// behind, without darkening the dense core into a grey hole.
    nonisolated private static func makeSmokeShape(size: Int) -> SmokeShape {
        let count = size * size
        var density = [Float](repeating: 0, count: count)
        for y in 0..<size {
            for x in 0..<size {
                let px = (Float(x) + 0.5) / Float(size) * 2 - 1
                let py = (Float(y) + 0.5) / Float(size) * 2 - 1
                // Warp the domain so the billows curl instead of sitting on a grid.
                let warpX = fbm(px * 1.7 + 3.1, py * 1.7 + 7.7, octaves: 3) - 0.5
                let warpY = fbm(px * 1.7 + 11.3, py * 1.7 + 1.9, octaves: 3) - 0.5
                let qx = px + 0.45 * warpX
                let qy = py + 0.45 * warpY
                let radius = (qx * qx + qy * qy).squareRoot()
                let body = 1 - smoothstep(0.18, 0.98, radius)
                let billow = fbm(qx * 2.4 + 5.0, qy * 2.4 + 9.0, octaves: 5)
                var value = max(0, body * (0.25 + 1.4 * billow) - 0.24) / 0.76
                let border = max(0, 1 - (px * px + py * py))
                value *= border * border.squareRoot()
                density[y * size + x] = pow(min(value, 1), 1.12)
            }
        }
        var light = [Float](repeating: 1, count: count)
        let step = max(1, size / 64)
        for y in 0..<size {
            for x in 0..<size {
                // Compare with the density towards the light (up and slightly left).
                var towardLight: Float = 0
                for k in 1...3 {
                    let sx = x - k * step, sy = y - 2 * k * step
                    if sx >= 0 && sy >= 0 { towardLight += density[sy * size + sx] / 3 }
                }
                let lit = 0.96 + 1.3 * (density[y * size + x] - towardLight)
                light[y * size + x] = min(max(lit, 0.78), 1.1)
            }
        }
        return (size, density, light)
    }

    private static func tintSmoke(_ shape: SmokeShape, color: SmokeColor) -> CGImage? {
        let size = shape.size
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        // A little neutral smoke in every tint keeps vivid custom colors
        // translucent and textured instead of neon discs.
        let red = Float(color.red) * 0.8 + 200 * 0.2
        let green = Float(color.green) * 0.8 + 200 * 0.2
        let blue = Float(color.blue) * 0.8 + 200 * 0.2
        pixels.withUnsafeMutableBufferPointer { buffer in
            for i in 0..<(size * size) {
                let alpha = min(max(shape.density[i], 0), 1) * 0.66
                let light = shape.light[i]
                let index = i * 4
                // Premultiplied: clamp the lit color before scaling by alpha.
                buffer[index] = UInt8(min(red * light, 255) * alpha)
                buffer[index + 1] = UInt8(min(green * light, 255) * alpha)
                buffer[index + 2] = UInt8(min(blue * light, 255) * alpha)
                buffer[index + 3] = UInt8(alpha * 255)
            }
        }
        return makeImage(&pixels, width: size, height: size)
    }

    // MARK: - Noise

    nonisolated private static func hash(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65_535
    }

    /// Smooth value noise in 0...1.
    nonisolated private static func noise(_ x: Float, _ y: Float) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int(fx), iy = Int(fy)
        let tx = x - fx, ty = y - fy
        let u = tx * tx * (3 - 2 * tx), v = ty * ty * (3 - 2 * ty)
        let a = hash(ix, iy), b = hash(ix + 1, iy)
        let c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        let top = a + (b - a) * u
        let bottom = c + (d - c) * u
        return top + (bottom - top) * v
    }

    /// Fractal noise in 0...1. Each octave is rotated so no grid lines show.
    nonisolated private static func fbm(_ x: Float, _ y: Float, octaves: Int) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, total: Float = 0
        var px = x, py = y
        for _ in 0..<octaves {
            sum += amplitude * noise(px, py)
            total += amplitude
            let rx = 0.8 * px - 0.6 * py, ry = 0.6 * px + 0.8 * py
            px = rx * 2.03 + 17.1
            py = ry * 2.03 + 4.7
            amplitude *= 0.5
        }
        return sum / total
    }

    nonisolated private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
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
