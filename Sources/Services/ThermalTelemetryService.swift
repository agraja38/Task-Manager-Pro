import Foundation

final class ThermalTelemetryService {
    private let reader = SMCReader()

    func sample(currentThermalLevel: String) -> ThermalDetailsSnapshot {
        reader.sample(currentThermalLevel: currentThermalLevel)
    }

    func applyManualFanSpeeds(speedsByFanIndex: [Int: Int]) throws {
        try reader.setManualFanSpeeds(speedsByFanIndex)
    }

    func restoreAutomaticFanControl() throws {
        try reader.restoreAutomaticFanControl()
    }
}
