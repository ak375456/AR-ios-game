//
//  CarPaint.swift
//  vr
//
//  Repainting a car by rewriting the hue of its base-colour map.
//

import CoreGraphics
import Foundation

/// A colour the player can paint a car.
///
/// Stored as HSV rather than RGB because repainting works in hue space: the
/// car's own shading, panel gaps and reflections are preserved and only the
/// colour of the paint itself moves.
struct CarPaint: Identifiable, Hashable {

    let id: String
    let name: String
    /// Degrees, 0...360.
    let hue: Float
    let saturation: Float
    let brightness: Float

    static let all: [CarPaint] = [
        CarPaint(id: "crimson", name: "Crimson", hue: 355, saturation: 0.80, brightness: 0.92),
        CarPaint(id: "ember",   name: "Ember",   hue: 22,  saturation: 0.88, brightness: 0.98),
        CarPaint(id: "lemon",   name: "Lemon",   hue: 48,  saturation: 0.92, brightness: 1.00),
        CarPaint(id: "lime",    name: "Lime",    hue: 96,  saturation: 0.72, brightness: 0.84),
        CarPaint(id: "mint",    name: "Mint",    hue: 162, saturation: 0.62, brightness: 0.82),
        CarPaint(id: "azure",   name: "Azure",   hue: 203, saturation: 0.78, brightness: 0.94),
        CarPaint(id: "indigo",  name: "Indigo",  hue: 254, saturation: 0.62, brightness: 0.82),
        CarPaint(id: "magenta", name: "Magenta", hue: 315, saturation: 0.70, brightness: 0.90),
        CarPaint(id: "pearl",   name: "Pearl",   hue: 30,  saturation: 0.04, brightness: 0.96),
        CarPaint(id: "carbon",  name: "Carbon",  hue: 220, saturation: 0.10, brightness: 0.22),
    ]

    static let factory = CarPaint(id: "factory", name: "Original finish", hue: 0, saturation: 0, brightness: 0)

    static let `default` = all[5]

    static func paint(id: String) -> CarPaint {
        if id == "factory" { return .factory }
        return all.first { $0.id == id } ?? `default`
    }
}

/// Rewrites the paint colour of a car's base-colour map.
///
/// Only pixels whose hue falls inside the car's paint window are touched, so
/// glass, tyres, lights and trim come through untouched. Saturation and
/// brightness are *shifted* rather than replaced, which keeps every highlight
/// and shadow that was baked into the original texture.
enum PaintRecolorer {

    static func recolour(
        _ image: CGImage,
        referenceHue: Float,
        tolerance: Float,
        referenceSaturation: Float,
        referenceBrightness: Float,
        to paint: CarPaint
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let saturationShift = paint.saturation - referenceSaturation
        let brightnessShift = paint.brightness - referenceBrightness

        // Window glass is often the same hue family as the body — a blue van
        // with blue-tinted windows — but it is always much paler. Requiring a
        // pixel to be within reach of the paint's own saturation keeps the
        // glass out of the repaint without needing to know which pixels are
        // windows.
        let minimumSaturation = max(0.22, referenceSaturation * 0.55)

        pixels.withUnsafeMutableBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                let alpha = Float(buffer[index + 3]) / 255
                guard alpha > 0 else { index += 4; continue }

                // The context is premultiplied, so undo it before working in HSV.
                let r = Float(buffer[index]) / 255 / alpha
                let g = Float(buffer[index + 1]) / 255 / alpha
                let b = Float(buffer[index + 2]) / 255 / alpha

                var (h, s, v) = rgbToHsv(r, g, b)
                if s >= minimumSaturation && v >= 0.12 && hueDistance(h, referenceHue) <= tolerance {
                    h = paint.hue
                    s = min(max(s + saturationShift, 0), 1)
                    v = min(max(v + brightnessShift, 0), 1)
                    let (nr, ng, nb) = hsvToRgb(h, s, v)
                    buffer[index] = channel(nr * alpha)
                    buffer[index + 1] = channel(ng * alpha)
                    buffer[index + 2] = channel(nb * alpha)
                }
                index += 4
            }
        }

        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            return context.makeImage()
        }
    }

    // MARK: - Colour maths

    private static func channel(_ value: Float) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }

    /// Shortest distance between two hues, in degrees.
    static func hueDistance(_ a: Float, _ b: Float) -> Float {
        let delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta)
    }

    static func rgbToHsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum

        var hue: Float = 0
        if delta > 0 {
            if maximum == r {
                hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == g {
                hue = 60 * ((b - r) / delta + 2)
            } else {
                hue = 60 * ((r - g) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }
        return (hue, maximum > 0 ? delta / maximum : 0, maximum)
    }

    static func hsvToRgb(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
        let c = v * s
        let hh = h.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c

        let rgb: (Float, Float, Float)
        switch Int(hh) {
        case 0:  rgb = (c, x, 0)
        case 1:  rgb = (x, c, 0)
        case 2:  rgb = (0, c, x)
        case 3:  rgb = (0, x, c)
        case 4:  rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }
}
