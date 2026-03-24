import Foundation

final class ThermalTelemetryService {
    private let reader = SMCReader()

    func sample(currentThermalLevel: String) -> ThermalDetailsSnapshot {
        reader.sample(currentThermalLevel: currentThermalLevel)
    }

    func applyMinimumFanSpeeds(_ speedsByFanIndex: [Int: Int]) throws {
        try reader.setMinimumFanSpeeds(speedsByFanIndex)
    }
}
