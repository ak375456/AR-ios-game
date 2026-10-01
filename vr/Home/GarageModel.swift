//
//  GarageModel.swift
//  vr
//
//  What the player has chosen, remembered between launches.
//

import Foundation
import Observation

/// The selected car and its paint. Stored in user defaults so the garage opens
/// where the player left it.
@MainActor
@Observable
final class GarageModel {

    private enum Key {
        static let car = "garage.selectedCar"
        static let paint = "garage.selectedPaint"
    }

    var selectedCar: CarDefinition {
        didSet { defaults.set(selectedCar.id, forKey: Key.car) }
    }

    var selectedPaint: CarPaint {
        didSet { defaults.set(selectedPaint.id, forKey: Key.paint) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedCar = CarCatalog.car(id: defaults.string(forKey: Key.car) ?? "")
        selectedPaint = CarPaint.paint(id: defaults.string(forKey: Key.paint) ?? "")
    }

    var carIndex: Int {
        CarCatalog.all.firstIndex(of: selectedCar) ?? 0
    }

    func selectCar(offsetBy step: Int) {
        let cars = CarCatalog.all
        let index = (carIndex + step + cars.count) % cars.count
        selectedCar = cars[index]
    }
}
