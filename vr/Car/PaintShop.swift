//
//  PaintShop.swift
//  vr
//
//  Produces and caches repainted base-colour maps.
//

import CoreGraphics
import Foundation
import ImageIO
import OSLog
import RealityKit
import UIKit

/// Builds a car's repainted texture once and keeps it.
///
/// Repainting walks every pixel of the base-colour map, which costs a few tens
/// of milliseconds, so the results are cached: switching back to a colour the
/// player has already seen is instant.
@MainActor
final class PaintShop {

    static let shared = PaintShop()

    private var originals: [String: CGImage] = [:]

    /// Only the current colour is kept per car. A repainted supercar map is a
    /// 1024 x 1024 image — holding every colour of every car would cost tens of
    /// megabytes for something that takes a few tens of milliseconds to rebuild.
    private var repainted: [String: (paint: String, image: CGImage)] = [:]
    private var textures: [String: (paint: String, texture: TextureResource)] = [:]

    /// The same repainted image wrapped as a `UIImage`, kept because SceneKit
    /// keys its uploaded textures on the object it is handed. Building a fresh
    /// wrapper each time looks free — it shares the pixels — but SceneKit sees
    /// a new object and uploads the whole map again, which is how browsing the
    /// garage grew by a few megabytes per car even for cars already shown.
    private var wrapped: [String: (paint: String, image: UIImage)] = [:]

    /// Car ids, least recently used first. Browsing all 28 cars would
    /// otherwise hold every base map and every repaint at once.
    private var recency: [String] = []
    private let carsToKeep = 6

    private init() {}

    /// The car's texture with `paint` applied, as a Core Graphics image.
    /// Used by the garage preview, and as the source for the AR texture.
    func image(for car: CarDefinition, paint: CarPaint) -> CGImage? {
        if let cached = repainted[car.id], cached.paint == paint.id { return cached.image }
        guard let original = original(for: car) else { return nil }

        guard let result = PaintRecolorer.recolour(
            original,
            referenceHue: car.paintHue,
            tolerance: car.paintHueTolerance,
            referenceSaturation: car.paintSaturation,
            referenceBrightness: car.paintBrightness,
            to: paint
        ) else {
            AppLog.asset.error("Repainting \(car.id, privacy: .public) failed; using the original texture")
            return original
        }

        repainted[car.id] = (paint.id, result)
        touch(car.id)
        return result
    }

    /// Moves a car to the most recent end and evicts the stalest ones.
    private func touch(_ carID: String) {
        recency.removeAll { $0 == carID }
        recency.append(carID)
        while recency.count > carsToKeep {
            let stale = recency.removeFirst()
            originals[stale] = nil
            repainted[stale] = nil
            wrapped[stale] = nil
            textures[stale] = nil
        }
    }

    /// The same image as a RealityKit texture, for the car in the room.
    func texture(for car: CarDefinition, paint: CarPaint) async -> TextureResource? {
        if let cached = textures[car.id], cached.paint == paint.id { return cached.texture }
        guard let image = image(for: car, paint: paint) else { return nil }
        do {
            let resource = try await TextureResource(image: image, options: .init(semantic: .color))
            textures[car.id] = (paint.id, resource)
            touch(car.id)
            return resource
        } catch {
            AppLog.asset.error("Texture creation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func uiImage(for car: CarDefinition, paint: CarPaint) -> UIImage? {
        if let cached = wrapped[car.id], cached.paint == paint.id {
            touch(car.id)
            return cached.image
        }
        guard let image = image(for: car, paint: paint) else { return nil }
        let result = UIImage(cgImage: image)
        wrapped[car.id] = (paint.id, result)
        return result
    }

    /// Drops everything rebuildable. Wired to the system memory warning.
    func purge() {
        repainted.removeAll()
        textures.removeAll()
        originals.removeAll()
        wrapped.removeAll()
        recency.removeAll()
    }

    /// The paint colour as a flat colour, for cars whose paint is a plain
    /// material rather than a map.
    ///
    /// A flat material has no shading to preserve, so the shift that a texture
    /// gets — keep the lighting, move the hue — collapses to simply becoming
    /// the chosen colour.
    func shiftedColour(for paint: CarPaint) -> UIColor {
        let (r, g, b) = PaintRecolorer.hsvToRgb(paint.hue, paint.saturation, paint.brightness)
        return UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    private func original(for car: CarDefinition) -> CGImage? {
        if let cached = originals[car.id] { return cached }
        guard let texture = car.paintTexture,
              let url = Bundle.main.url(forResource: texture.name, withExtension: texture.fileExtension),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            AppLog.asset.error("Missing base-colour map for \(car.id, privacy: .public)")
            return nil
        }
        originals[car.id] = image
        touch(car.id)
        return image
    }
}
