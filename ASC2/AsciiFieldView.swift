import MetalKit
import SwiftUI

/// Фон из ASCII-символов на строгой сетке.
/// Символы не двигаются: «плавание» — это медленно меняющаяся яркость (3D-шум по x, y, времени),
/// а сами символы время от времени случайно заменяются на другие.
/// Рендер — Metal (`AsciiFieldRenderer`), чтобы фон мог крутиться весь день, не нагружая CPU.
struct AsciiFieldView: NSViewRepresentable {
    var cellSize: CGFloat = 14
    var fontSize: CGFloat = 11
    /// Максимальная непрозрачность самых ярких символов — держим фон приглушённым.
    var maxOpacity: Double = 0.3
    /// Останавливает анимацию, когда фон никто не видит (окно перекрыто, экран спит).
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
        // На паузе MTKView рисует только по запросу (ресайз, смена экрана), последний кадр остаётся на месте.
        view.isPaused = paused
        view.enableSetNeedsDisplay = paused
        if paused { view.needsDisplay = true }
    }
}

#Preview {
    AsciiFieldView()
        .frame(width: 800, height: 500)
}
