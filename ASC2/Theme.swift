import SwiftUI

enum Theme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let glyph = Color(white: 0.92)

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}
