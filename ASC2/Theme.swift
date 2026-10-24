import SwiftUI

enum Theme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let glyph = Color(white: 0.92)

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

/// Glyph color for the thermal mode: unchanged at nominal pressure, then a muted heat gradient
/// (yellowish, orange, red, maroon) driven by temperature from Moderate pressure upward.
enum ThermalPalette {
    private static let stops: [(red: Double, green: Double, blue: Double)] = [
        (0.92, 0.84, 0.58),  // yellowish
        (0.95, 0.63, 0.36),  // orange
        (0.90, 0.36, 0.30),  // red
        (0.72, 0.20, 0.27),  // maroon
    ]
    /// Temperatures (°C) mapped to the start and the end of the gradient.
    private static let coolTemperature = 65.0
    private static let hotTemperature = 100.0

    static func glyph(pressure: ThermalPressure, temperature: Double?) -> Color {
        guard pressure > .nominal else { return Theme.glyph }

        // Higher pressure never shows a cooler color than its own band, even if the sensor reads low.
        let floor = Double(pressure.rawValue - 1) / 3
        let heat: Double
        if let temperature {
            heat = (temperature - coolTemperature) / (hotTemperature - coolTemperature)
        } else {
            heat = floor + 0.15
        }
        return color(at: min(max(heat, floor), 1))
    }

    private static func color(at position: Double) -> Color {
        let scaled = position * Double(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let t = scaled - Double(index)
        let a = stops[index], b = stops[index + 1]
        return Color(red: a.red + (b.red - a.red) * t,
                     green: a.green + (b.green - a.green) * t,
                     blue: a.blue + (b.blue - a.blue) * t)
    }
}
