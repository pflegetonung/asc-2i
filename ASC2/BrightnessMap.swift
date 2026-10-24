import CoreGraphics

/// Turns a picture into one brightness value per grid cell for the image pattern.
enum BrightnessMap {
    /// Supersampling per cell side; cells are box-averaged from it, avoiding aliasing on big downscales.
    private static let supersampling = 4
    /// How strongly edges are boosted, so shapes still read at one glyph per cell.
    private static let sharpening: Float = 0.8
    /// Darkest and brightest share of cells clipped by auto-levels.
    private static let clipFraction: Float = 0.02

    /// Row-major `columns × rows` bytes, top row first; the picture fills the grid like a desktop picture.
    static func make(from image: CGImage, columns: Int, rows: Int) -> [UInt8] {
        let samples = downsample(image, columns: columns, rows: rows)
        let sharpened = sharpen(samples, columns: columns, rows: rows)
        return autoLevels(sharpened).map { UInt8(($0 * 255).rounded()) }
    }

    /// Luminance averaged over each cell, in [0, 1].
    private static func downsample(_ image: CGImage, columns: Int, rows: Int) -> [Float] {
        let width = columns * supersampling
        let height = rows * supersampling
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .high
            // Aspect fill: scale to cover the grid and crop the overflow evenly.
            let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: CGRect(x: (CGFloat(width) - drawn.width) / 2,
                                           y: (CGFloat(height) - drawn.height) / 2,
                                           width: drawn.width, height: drawn.height))
        }

        var cells = [Float](repeating: 0, count: columns * rows)
        let norm = 1 / Float(supersampling * supersampling * 255)
        for y in 0..<height {
            for x in 0..<width {
                cells[(y / supersampling) * columns + x / supersampling] += Float(pixels[y * width + x]) * norm
            }
        }
        return cells
    }

    /// Unsharp mask against a 3×3 box blur.
    private static func sharpen(_ values: [Float], columns: Int, rows: Int) -> [Float] {
        var result = values
        for row in 0..<rows {
            for column in 0..<columns {
                var sum: Float = 0
                var count: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let y = row + dy, x = column + dx
                        guard y >= 0, y < rows, x >= 0, x < columns else { continue }
                        sum += values[y * columns + x]
                        count += 1
                    }
                }
                let value = values[row * columns + column]
                result[row * columns + column] = value + sharpening * (value - sum / count)
            }
        }
        return result
    }

    /// Stretches the 2nd–98th percentile to the full [0, 1] range.
    private static func autoLevels(_ values: [Float]) -> [Float] {
        let sorted = values.sorted()
        let low = sorted[Int(Float(sorted.count - 1) * clipFraction)]
        let high = sorted[Int(Float(sorted.count - 1) * (1 - clipFraction))]
        guard high - low > 0.01 else { return values.map { min(max($0, 0), 1) } }
        return values.map { min(max(($0 - low) / (high - low), 0), 1) }
    }
}
