import MetalKit
import SwiftUI

/// Background of ASCII glyphs on a fixed grid.
/// Glyphs never move: the "drift" is slowly changing brightness (3D noise over x, y and time),
/// and each glyph is randomly swapped for another from time to time.
/// Rendered with Metal (`AsciiFieldRenderer`) so it can run all day without loading the CPU.
struct AsciiFieldView: NSViewRepresentable {
    var cellSize: CGFloat = 14
    var fontSize: CGFloat = 11
    /// Opacity of the brightest glyphs; keeps the background subdued.
    var maxOpacity: Double = 0.3
    /// Stops the animation when nobody can see it (window covered, display asleep).
    var isPaused = false

    func makeCoordinator() -> AsciiFieldRenderer {
        AsciiFieldRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.attach(to: view)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.configuration = .init(cellSize: cellSize, fontSize: fontSize, maxOpacity: maxOpacity)
        let paused = isPaused || context.environment.accessibilityReduceMotion
        // While paused, MTKView draws only on demand (resize, display change); the last frame stays on screen.
        view.isPaused = paused
        view.enableSetNeedsDisplay = paused
        if paused { view.needsDisplay = true }
    }
}

#Preview {
    AsciiFieldView()
        .frame(width: 800, height: 500)
}
