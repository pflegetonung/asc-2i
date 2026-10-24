import AppKit
import CoreText
import MetalKit
import SwiftUI

/// Рисует ASCII-поле через Metal: вся математика клеток живёт в вершинном шейдере (`AsciiFieldShader`),
/// а символы берутся из заранее отрисованного атласа. CPU на кадр почти ничего не делает.
final class AsciiFieldRenderer: NSObject, MTKViewDelegate {
    struct Configuration: Equatable {
        var cellSize: CGFloat
        var fontSize: CGFloat
        var maxOpacity: Double
    }

    /// Раскладка совпадает с `FieldUniforms` в шейдере.
    private struct Uniforms {
        var viewSize: SIMD2<Float>
        var origin: SIMD2<Float>
        var cellSize: Float
        var time: Float
        var maxOpacity: Float
        var opacityLevels: Float
        var glyphColor: SIMD4<Float>
        var tierCounts: SIMD4<UInt32>
        var columns: UInt32
        var rows: UInt32
        var atlasColumns: UInt32
        var atlasRows: UInt32
    }

    /// Наборы символов по яркости: тусклые клетки — «лёгкие» знаки, яркие — «плотные».
    /// Каждый ярус — отдельная строка атласа.
    private static let tiers: [[String]] = [
        [".", "-", "`", "'"],
        ["-", "+", ":", "=", "~"],
        ["+", "x", "o", "*", "="],
        ["x", "o", "X", "O", "#", "%"],
    ]
    /// Сколько ступеней прозрачности у клеток.
    private static let opacityLevels = 24

    var configuration = Configuration(cellSize: 14, fontSize: 11, maxOpacity: 0.3) {
        didSet {
            if configuration.cellSize != oldValue.cellSize || configuration.fontSize != oldValue.fontSize {
                atlas = nil
            }
        }
    }

    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var atlas: MTLTexture?
    private var atlasCellSize = 0
    private let start = Date()
    private let glyphColor = Theme.glyph.srgbComponents

    func attach(to view: MTKView) {
        guard let device = view.device else { return }
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30
        let background = Theme.background.srgbComponents
        view.clearColor = MTLClearColor(red: Double(background.x), green: Double(background.y),
                                        blue: Double(background.z), alpha: 1)

        queue = device.makeCommandQueue()
        guard let library = try? device.makeLibrary(source: AsciiFieldShader.source, options: nil) else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cellVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cellFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = view.colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device = view.device, let queue, let pipeline, view.bounds.width > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable
        else { return }

        let scale = view.drawableSize.width / view.bounds.width
        let cell = max(1, Int((configuration.cellSize * scale).rounded()))
        if atlas == nil || atlasCellSize != cell {
            atlas = makeAtlas(device: device, cell: cell, scale: scale)
            atlasCellSize = cell
        }
        guard let atlas else { return }

        let size = view.drawableSize
        let cellSize = CGFloat(cell)
        let columns = Int(size.width / cellSize) + 1
        let rows = Int(size.height / cellSize) + 1
        // Центрируем сетку, чтобы поля по краям были одинаковыми; углы клеток — ровно по пикселям.
        let originX = ((size.width - CGFloat(columns - 1) * cellSize - cellSize) / 2).rounded()
        let originY = ((size.height - CGFloat(rows - 1) * cellSize - cellSize) / 2).rounded()

        var counts = SIMD4<UInt32>(repeating: 1)
        for (index, tier) in Self.tiers.enumerated() { counts[index] = UInt32(tier.count) }

        var uniforms = Uniforms(
            viewSize: SIMD2(Float(size.width), Float(size.height)),
            origin: SIMD2(Float(originX), Float(originY)),
            cellSize: Float(cellSize),
            time: Float(Date().timeIntervalSince(start)),
            maxOpacity: Float(configuration.maxOpacity),
            opacityLevels: Float(Self.opacityLevels),
            glyphColor: glyphColor,
            tierCounts: counts,
            columns: UInt32(columns),
            rows: UInt32(rows),
            atlasColumns: UInt32(Self.tiers.map(\.count).max() ?? 1),
            atlasRows: UInt32(Self.tiers.count)
        )

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: columns * rows)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Атлас покрытия (r8): ярус — строка, символ — столбец, каждый символ по центру своей клетки.
    private func makeAtlas(device: MTLDevice, cell: Int, scale: CGFloat) -> MTLTexture? {
        let atlasColumns = Self.tiers.map(\.count).max() ?? 1
        let width = cell * atlasColumns
        let height = cell * Self.tiers.count
        var pixels = [UInt8](repeating: 0, count: width * height)

        let font = NSFont.monospacedSystemFont(ofSize: configuration.fontSize * scale, weight: .regular)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.setShouldSmoothFonts(false)
            for (row, tier) in Self.tiers.enumerated() {
                for (column, glyph) in tier.enumerated() {
                    let string = NSAttributedString(string: glyph, attributes: [
                        .font: font,
                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                    ])
                    let line = CTLineCreateWithAttributedString(string)
                    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                    let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                    // У CGContext ось y смотрит вверх, а строка 0 атласа — верхняя.
                    let cellX = CGFloat(column * cell)
                    let cellY = CGFloat(height - (row + 1) * cell)
                    context.textPosition = CGPoint(x: cellX + (CGFloat(cell) - advance) / 2,
                                                   y: cellY + (CGFloat(cell) - ascent - descent) / 2 + descent)
                    CTLineDraw(line, context)
                }
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: width)
        return texture
    }
}

private extension Color {
    var srgbComponents: SIMD4<Float> {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return SIMD4(Float(color.redComponent), Float(color.greenComponent),
                     Float(color.blueComponent), Float(color.alphaComponent))
    }
}
