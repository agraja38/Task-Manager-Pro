import Foundation

final class ThermalTelemetryService {
    private let reader = SMCReader()

    func sample(currentThermalLevel: String) -> ThermalDetailsSnapshot {
        reader.sample(currentThermalLevel: currentThermalLevel)
    }
}
