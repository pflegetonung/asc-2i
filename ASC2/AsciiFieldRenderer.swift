import AppKit
import CoreText
import MetalKit
import SwiftUI

/// Draws the ASCII field with Metal: all per-cell math lives in the vertex shader (`AsciiFieldShader`)
/// and glyphs come from a pre-rendered atlas. The CPU does almost nothing per frame.
final class AsciiFieldRenderer: NSObject, MTKViewDelegate {
    struct Configuration: Equatable {
        var cellSize: CGFloat
        var fontSize: CGFloat
        var maxOpacity: Double
    }

    /// Layout matches `FieldUniforms` in the shader.
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
        var pattern: UInt32
        var rampCount: UInt32
        var tierRows: UInt32
        var padding: UInt32 = 0
    }

    /// Glyph sets by brightness: dim cells get "light" glyphs, bright cells get "dense" ones.
    /// Each tier is one atlas row.
    private static let tiers: [[String]] = [
        [".", "-", "`", "'"],
        ["-", "+", ":", "=", "~"],
        ["+", "x", "o", "*", "="],
        ["x", "o", "X", "O", "#", "%"],
    ]
    /// Glyphs for the image pattern. The atlas stores them as one extra row sorted by measured ink coverage,
    /// so brightness maps to a position on this "weight" ramp.
    private static let ramp: [String] = [
        ".", "`", "'", ",", "-", "_", ":", ";", "~", "^", "\"", "=", "+", "<", ">", "*", "!",
        "/", "\\", "|", "(", ")", "[", "]", "{", "}", "?", "i", "l", "v", "x", "z", "c", "o", "s",
        "e", "a", "X", "Z", "O", "0", "Q", "#", "%", "&", "8", "B", "@", "M", "W",
    ]
    /// Number of opacity steps for cells.
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
    /// Picture for the image pattern; nil draws clouds.
    var image: CGImage? {
        didSet { if image !== oldValue { brightness = nil } }
    }
    /// Per-cell brightness of `image` for the current grid size.
    private var brightness: MTLTexture?
    /// Bound in place of `brightness` with clouds, so the shader always has a texture.
    private var emptyBrightness: MTLTexture?
    private let start = Date()
    /// Color the glyphs ease toward; a change fades in over `colorTransition` seconds.
    var targetGlyphColor = Theme.glyph.srgbComponents
    private var glyphColor = Theme.glyph.srgbComponents
    private var lastFrameTime: CFTimeInterval?
    private static let colorTransition: CFTimeInterval = 3

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
        emptyBrightness = makeBrightnessTexture(device: device, bytes: [0], columns: 1, rows: 1)
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
        guard let atlas, let emptyBrightness else { return }

        let size = view.drawableSize
        let cellSize = CGFloat(cell)
        let columns = Int(size.width / cellSize) + 1
        let rows = Int(size.height / cellSize) + 1
        // Center the grid so the margins are equal; cell corners land exactly on pixels.
        let originX = ((size.width - CGFloat(columns - 1) * cellSize - cellSize) / 2).rounded()
        let originY = ((size.height - CGFloat(rows - 1) * cellSize - cellSize) / 2).rounded()

        if let image, brightness?.width != columns || brightness?.height != rows {
            brightness = makeBrightnessTexture(device: device,
                                               bytes: BrightnessMap.make(from: image, columns: columns, rows: rows),
                                               columns: columns, rows: rows)
        }
        let imageBrightness = image == nil ? nil : brightness

        // After a pause (or on the first frame) the elapsed time is long, so the color simply snaps.
        let now = CACurrentMediaTime()
        let elapsed = lastFrameTime.map { now - $0 } ?? .infinity
        lastFrameTime = now
        glyphColor += (targetGlyphColor - glyphColor) * Float(min(1, elapsed / Self.colorTransition))

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
            atlasColumns: UInt32(Self.atlasColumns),
            atlasRows: UInt32(Self.tiers.count + 1),
            pattern: imageBrightness == nil ? 0 : 1,
            rampCount: UInt32(Self.ramp.count),
            tierRows: UInt32(Self.tiers.count)
        )

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexTexture(imageBrightness ?? emptyBrightness, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: columns * rows)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static var atlasColumns: Int {
        max(tiers.map(\.count).max() ?? 1, ramp.count)
    }

    /// Coverage atlas (r8): one row per clouds tier, then the image ramp sorted from lightest to heaviest glyph.
    /// Each glyph is centered in its cell.
    private func makeAtlas(device: MTLDevice, cell: Int, scale: CGFloat) -> MTLTexture? {
        let font = NSFont.monospacedSystemFont(ofSize: configuration.fontSize * scale, weight: .regular)
        let ramp = Self.ramp
            .map { (glyph: $0, weight: inkCoverage(of: $0, font: font, cell: cell)) }
            .sorted { $0.weight < $1.weight }
            .map(\.glyph)
        let rows = Self.tiers + [ramp]

        let width = cell * Self.atlasColumns
        let height = cell * rows.count
        let pixels = render(width: width, height: height) { context in
            for (row, glyphs) in rows.enumerated() {
                for (column, glyph) in glyphs.enumerated() {
                    // CGContext's y axis points up, while atlas row 0 is the top one.
                    draw(glyph, font: font, in: context, cell: cell,
                         origin: CGPoint(x: column * cell, y: height - (row + 1) * cell))
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

    /// Total coverage of a glyph rendered alone in one cell: its visual "weight".
    private func inkCoverage(of glyph: String, font: NSFont, cell: Int) -> Int {
        render(width: cell, height: cell) { context in
            draw(glyph, font: font, in: context, cell: cell, origin: .zero)
        }
        .reduce(0) { $0 + Int($1) }
    }

    /// White-on-black grayscale bitmap, top row first.
    private func render(width: Int, height: Int, _ body: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.setShouldSmoothFonts(false)
            body(context)
        }
        return pixels
    }

    private func draw(_ glyph: String, font: NSFont, in context: CGContext, cell: Int, origin: CGPoint) {
        let string = NSAttributedString(string: glyph, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        context.textPosition = CGPoint(x: origin.x + (CGFloat(cell) - advance) / 2,
                                       y: origin.y + (CGFloat(cell) - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
    }

    private func makeBrightnessTexture(device: MTLDevice, bytes: [UInt8], columns: Int, rows: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: columns,
                                                                  height: rows, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, columns, rows), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: columns)
        return texture
    }
}

extension Color {
    var srgbComponents: SIMD4<Float> {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return SIMD4(Float(color.redComponent), Float(color.greenComponent),
                     Float(color.blueComponent), Float(color.alphaComponent))
    }
}
