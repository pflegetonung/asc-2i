import Foundation
import Observation

/// Tracks thermal pressure (pushed by the system) and CPU/GPU temperature (polled) while enabled.
@Observable final class ThermalMonitor {
    static let shared = ThermalMonitor()

    private static let temperatureInterval: TimeInterval = 3

    private(set) var pressure: ThermalPressure = .nominal
    /// Hottest CPU/GPU core in °C; nil when no sensor is readable.
    private(set) var temperature: Double?
    private(set) var isPressureAvailable = false

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    @ObservationIgnored private var pressureReader: ThermalPressureReader?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private lazy var smc = SMCTemperatureReader()
    @ObservationIgnored private lazy var hid = HIDTemperatureReader()

    private func start() {
        pressureReader = ThermalPressureReader { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }
        isPressureAvailable = pressureReader != nil
        timer = Timer.scheduledTimer(withTimeInterval: Self.temperatureInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer?.tolerance = 1
        update()
    }

    private func stop() {
        pressureReader = nil
        timer?.invalidate()
        timer = nil
        pressure = .nominal
        temperature = nil
    }

    private func update() {
        pressure = pressureReader?.read() ?? .nominal
        temperature = smc?.read() ?? hid?.read()
        #if DEBUG
        // Launch with e.g. `-debugThermalPressure 2 -debugTemperature 92` to preview the palette.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "debugThermalPressure") != nil {
            pressure = ThermalPressure(rawValue: defaults.integer(forKey: "debugThermalPressure")) ?? pressure
        }
        if defaults.object(forKey: "debugTemperature") != nil {
            temperature = defaults.double(forKey: "debugTemperature")
        }
        #endif
    }
}
