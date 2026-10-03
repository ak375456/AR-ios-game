import SwiftUI
import UIKit

/// Main-actor parsing matches SceneKit's asset requirements. Thumbnails are
/// rendered on demand, cached as pixels, and the scene is released after each.
@MainActor final class CarThumbnailCache {
    static let shared = CarThumbnailCache()
    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    init() {
        memory.totalCostLimit = 16 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // v4: brand badges were removed from five models, so older thumbnails are stale.
        directory = caches.appendingPathComponent("CarThumbnails-v4")
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("CarThumbnails-v3"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func image(for car: CarDefinition) async -> UIImage? {
        let key = car.id as NSString
        if let image = memory.object(forKey: key) { return image }
        let url = directory.appendingPathComponent(car.id + ".png")
        if let image = UIImage(contentsOfFile: url.path) {
            memory.setObject(image, forKey: key, cost: 360 * 260 * 4); return image
        }
        await Task.yield()
        guard !Task.isCancelled else { return nil }
        if let image = memory.object(forKey: key) { return image }
        guard let image = CarPreviewView.Coordinator.thumbnail(car: car) else { return nil }
        memory.setObject(image, forKey: key, cost: 360 * 260 * 4)
        if let data = image.pngData() { try? data.write(to: url, options: .atomic) }
        return image
    }
}
struct CarThumbnail: View {
    let car: CarDefinition
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "car.side.fill").font(.largeTitle).accessibilityLabel("Preview unavailable") }
            else { ProgressView().tint(GaragePalette.midnight) }
        }.task(id: car.id) { image = await CarThumbnailCache.shared.image(for: car); failed = image == nil }
        .accessibilityHidden(true)
    }
}
