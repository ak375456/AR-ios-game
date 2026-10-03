import Foundation
import CoreGraphics

/// Finds clear screen space using the same safe-area coordinates as UIKit controls.
/// A small menu button remains reachable with custom layouts.
enum OverlayPlacement {
    static func find(in size: CGSize, avoiding obstacles: [CGRect], preferred: CGSize,
                     near anchor: CGPoint? = nil, fallback: CGSize? = CGSize(width: 44, height: 44)) -> CGRect? {
        let area = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        let expanded = obstacles.map { $0.insetBy(dx: -8, dy: -8) }
        for dimensions in [preferred] + (fallback.map { [$0] } ?? []) {
            guard dimensions.width <= area.width, dimensions.height <= area.height else { continue }
            let xs = stride(from: area.minX, through: area.maxX-dimensions.width, by: 8).sorted {
                abs($0+dimensions.width/2-(anchor?.x ?? size.width/2)) < abs($1+dimensions.width/2-(anchor?.x ?? size.width/2))
            }
            let ys = Array(stride(from: area.minY, through: area.maxY-dimensions.height, by: 8)).sorted {
                abs($0+dimensions.height/2-(anchor?.y ?? 0)) < abs($1+dimensions.height/2-(anchor?.y ?? 0))
            }
            for y in ys {
                for x in xs {
                    let frame = CGRect(origin: CGPoint(x:x,y:y), size:dimensions)
                    if expanded.allSatisfy({ !$0.intersects(frame) }) { return frame }
                }
            }
        }
        return nil
    }
}

/// Every overlay uses the actual control rectangles, including a moved handbrake
/// and manual shifter. Optional panels yield space before a control is obscured.
struct DriveOverlayLayout {
    var toolbar: CGRect?
    /// Reset car, beside the pause button. Icon-only when only 44 points fit.
    var reset: CGRect?
    var instruments: CGRect?
    var status: CGRect?
    var goal: CGRect?
    /// The road-coin counter, top right like an arcade score.
    var coins: CGRect?
    var compactInstruments = false

    init(size: CGSize, controls: [CGRect], focused: Bool, instrumentSize: CGSize?,
         instrumentY: CGFloat, showsStatus: Bool, showsGoal: Bool, statusHeight: CGFloat = 76,
         showsCoins: Bool = false, showsReset: Bool = false) {
        var occupied = controls
        toolbar = OverlayPlacement.find(in: size, avoiding: occupied,
            preferred: CGSize(width: 44, height: 44),
            near: CGPoint(x: 30, y: 30))
        if let toolbar { occupied.append(toolbar) }
        if showsCoins {
            coins = OverlayPlacement.find(in: size, avoiding: occupied,
                preferred: CGSize(width: 116, height: 44),
                near: CGPoint(x: size.width - 66, y: 30), fallback: nil)
            if let coins { occupied.append(coins) }
        }
        if showsReset, let toolbar {
            let width: CGFloat = 92
            reset = OverlayPlacement.find(in: size, avoiding: occupied,
                preferred: CGSize(width: width, height: 44),
                near: CGPoint(x: toolbar.maxX + 12 + width / 2, y: toolbar.midY))
            if let reset { occupied.append(reset) }
        }
        if showsStatus {
            status = OverlayPlacement.find(in: size, avoiding: occupied,
                preferred: CGSize(width: min(size.width-32, 280), height: statusHeight), near: CGPoint(x: size.width / 2, y: 112), fallback: nil)
            if let status { occupied.append(status) }
        }
        if let instrumentSize {
            instruments = OverlayPlacement.find(in: size, avoiding: occupied, preferred: instrumentSize,
                near: CGPoint(x: size.width/2, y: instrumentY), fallback: nil)
            if instruments == nil {
                compactInstruments = true
                instruments = OverlayPlacement.find(in: size, avoiding: occupied,
                    preferred: CGSize(width: min(size.width-32, 200), height: 54),
                    near: CGPoint(x: size.width/2, y: instrumentY), fallback: nil)
            }
            if let instruments { occupied.append(instruments) }
        }
        // Missions live in the garage; kept as an input for compatibility with
        // the standalone geometry audit. No mission rectangle is ever reserved.
        goal = nil
    }
}
