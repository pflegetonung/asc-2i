// Thermal pressure and temperature readers, ported from MacThrottle
// (https://github.com/angristan/MacThrottle, MIT License, Copyright (c) 2025 Stanislas).
// The SMC approach and sensor keys originally come from Stats (https://github.com/exelban/stats, MIT License).

import Foundation
import IOKit
import notify

/// System thermal pressure, matching the levels MacThrottle shows as thermometer icons.
enum ThermalPressure: Int, Comparable {
    case nominal   // thermometer.low
    case moderate  // thermometer.medium
    case heavy     // thermometer.high
    case critical  // thermometer.sun.fill

    var displayName: String {
        switch self {
        case .nominal: "Nominal"
        case .moderate: "Moderate"
        case .heavy: "Heavy"
        case .critical: "Critical"
        }
    }

    static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Thermal pressure

/// Reads the 5-level thermal pressure from the `com.apple.system.thermalpressurelevel` Darwin notification
/// (finer than `ProcessInfo.thermalState`, which folds moderate and heavy into `fair`).
final class ThermalPressureReader {
    private static let name = "com.apple.system.thermalpressurelevel"
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    /// Starts watching; `onChange` is called on the main queue whenever the level changes.
    init?(onChange: @escaping () -> Void) {
        let status = notify_register_dispatch(Self.name, &token, .main) { _ in
            onChange()
        }
        guard status == NOTIFY_STATUS_OK else { return nil }
    }

    deinit {
        notify_cancel(token)
    }

    func read() -> ThermalPressure? {
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return nil }
        switch state {
        case 0: return .nominal
        case 1: return .moderate
        case 2: return .heavy
        default: return .critical  // trapping and sleeping
        }
    }
}

// MARK: - SMC temperature

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// Must match the AppleSMC user client's struct layout exactly.
private struct SMCKeyData {
    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Reads the hottest CPU/GPU core temperature straight from the System Management Controller.
final class SMCTemperatureReader {
    private static let keyProbeRetryInterval: TimeInterval = 60

    // CPU/GPU core temperature keys by chip generation (from Stats).
    private static let keys: [String] = {
        let m1 = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                  "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        // M1/M2 Pro/Max/Ultra use TC## keys for CPU cores.
        let proMax = ["TC10", "TC11", "TC12", "TC13", "TC20", "TC21", "TC22", "TC23",
                      "TC30", "TC31", "TC32", "TC33", "TC40", "TC41", "TC42", "TC43",
                      "TC50", "TC51", "TC52", "TC53",
                      "Tg04", "Tg05", "Tg0C", "Tg0D", "Tg0K", "Tg0L", "Tg0S", "Tg0T"]
        let m2 = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
                  "Tg0f", "Tg0j"]
        let m3 = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                  "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
                  "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        let m4 = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
                  "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        var seen = Set<String>()
        return (m1 + proMax + m2 + m3 + m4).filter { seen.insert($0).inserted }
    }()

    private var connection: io_connect_t = 0
    /// Keys that returned a value on this Mac; probed once, re-probed if they stop working.
    private var validKeys: [String]?
    private var lastKeyProbe: Date?

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Maximum temperature across CPU/GPU cores, in °C.
    func read() -> Double? {
        if let validKeys, !validKeys.isEmpty {
            if let value = maxTemperature(of: validKeys).value { return value }
            self.validKeys = nil
        }
        if let validKeys, validKeys.isEmpty, let lastKeyProbe,
           Date().timeIntervalSince(lastKeyProbe) < Self.keyProbeRetryInterval {
            return nil
        }
        let probe = maxTemperature(of: Self.keys)
        validKeys = probe.keys
        lastKeyProbe = Date()
        return probe.value
    }

    private func maxTemperature(of keys: [String]) -> (value: Double?, keys: [String]) {
        var maximum: Double?
        var found: [String] = []
        for key in keys {
            guard let value = readTemperature(key: key) else { continue }
            found.append(key)
            maximum = max(maximum ?? value, value)
        }
        return (maximum, found)
    }

    private func readTemperature(key: String) -> Double? {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        input.data8 = 9  // kSMCReadKeyInfo
        guard call(&input, &output) == kIOReturnSuccess, output.keyInfo.dataSize == 4 else { return nil }

        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5  // kSMCReadBytes
        guard call(&input, &output) == kIOReturnSuccess else { return nil }

        // "flt" (little-endian Float32) on Apple Silicon.
        let bits = UInt32(output.bytes.0) | UInt32(output.bytes.1) << 8
            | UInt32(output.bytes.2) << 16 | UInt32(output.bytes.3) << 24
        let value = Double(Float(bitPattern: bits))
        return value > 20 && value < 150 ? value : nil
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outputSize)
    }
}

// MARK: - HID temperature (fallback)

/// Fallback when the SMC is unavailable: PMU die temperatures via the private IOHIDEventSystem API.
final class HIDTemperatureReader {
    private typealias ClientRef = OpaquePointer
    private typealias ServiceRef = OpaquePointer
    private typealias EventRef = OpaquePointer

    private typealias CreateFunc = @convention(c) (CFAllocator?) -> ClientRef?
    private typealias SetMatchingFunc = @convention(c) (ClientRef, CFDictionary?) -> Void
    private typealias CopyServicesFunc = @convention(c) (ClientRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFunc = @convention(c) (ServiceRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFunc = @convention(c) (ServiceRef, Int64, Int32, Int64) -> EventRef?
    private typealias GetFloatValueFunc = @convention(c) (EventRef, UInt32) -> Double
    private typealias ReleaseFunc = @convention(c) (OpaquePointer) -> Void

    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField: UInt32 = 0xf0000

    private let copyServices: CopyServicesFunc
    private let copyProperty: CopyPropertyFunc
    private let copyEvent: CopyEventFunc
    private let getFloatValue: GetFloatValueFunc
    private let release: ReleaseFunc
    private let client: ClientRef

    init?() {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateFunc.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFunc.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFunc.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFunc.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFunc.self),
              let getFloatValue = symbol("IOHIDEventGetFloatValue", as: GetFloatValueFunc.self),
              let release = symbol("CFRelease", as: ReleaseFunc.self),
              let client = create(kCFAllocatorDefault)
        else { return nil }

        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        setMatching(client, matching as CFDictionary)
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue
        self.release = release
        self.client = client
    }

    deinit {
        release(client)
    }

    /// Maximum PMU die temperature, in °C.
    func read() -> Double? {
        guard let services = copyServices(client)?.takeRetainedValue() else { return nil }
        var maximum: Double?
        for index in 0..<CFArrayGetCount(services) {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(services, index), to: ServiceRef.self)
            let product = copyProperty(service, kIOHIDProductKey as CFString)?.takeRetainedValue() as? String ?? ""
            // Calibration sensors aren't real die temperatures.
            guard !(product.hasPrefix("PMU") && product.hasSuffix(" tcal")),
                  let event = copyEvent(service, Self.temperatureEventType, 0, 0) else { continue }
            let value = getFloatValue(event, Self.temperatureLevelField)
            release(event)
            if value > 0 && value < 150 { maximum = max(maximum ?? value, value) }
        }
        return maximum
    }
}
