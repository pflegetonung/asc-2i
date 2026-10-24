import Foundation
import ImageIO
import Observation

/// What drives each cell's brightness.
enum WallpaperPattern: String, CaseIterable, Identifiable {
    /// Drifting noise clouds.
    case clouds
    /// A still picture chosen by the user.
    case image

    var id: Self { self }

    var title: String {
        switch self {
        case .clouds: "Clouds"
        case .image: "Image"
        }
    }
}

/// How glyphs are colored.
enum ColorMode: String, CaseIterable, Identifiable {
    /// Constant glyph color.
    case still
    /// Glyphs warm up with the Mac's temperature once thermal pressure reaches Moderate.
    case thermal

    var id: Self { self }

    var title: String {
        switch self {
        case .still: "Static"
        case .thermal: "Thermal"
        }
    }
}

@Observable final class AppSettings {
    static let shared = AppSettings()

    private static let patternKey = "pattern"
    private static let colorModeKey = "colorMode"
    /// The chosen picture is copied into the app's container, so it survives the original being moved.
    private static let imageDirectory = URL.applicationSupportDirectory
    private static let imageName = "pattern-image"
    /// Plenty for a grid of ~14 pt cells, and keeps decoding cheap.
    nonisolated private static let imageMaxPixelSize = 2048

    var pattern: WallpaperPattern {
        didSet { UserDefaults.standard.set(pattern.rawValue, forKey: Self.patternKey) }
    }

    var colorMode: ColorMode {
        didSet {
            UserDefaults.standard.set(colorMode.rawValue, forKey: Self.colorModeKey)
            ThermalMonitor.shared.isEnabled = colorMode == .thermal
        }
    }

    /// Picture for the image pattern; nil until one is chosen (the wallpaper shows clouds meanwhile).
    private(set) var image: CGImage?

    private init() {
        let defaults = UserDefaults.standard
        pattern = defaults.string(forKey: Self.patternKey).flatMap(WallpaperPattern.init) ?? .clouds
        colorMode = defaults.string(forKey: Self.colorModeKey).flatMap(ColorMode.init) ?? .still
        image = Self.storedImageURL().flatMap(Self.loadImage)
        #if DEBUG
        // Launch with e.g. `-pattern image -debugPatternImage <path>` to preview a picture without choosing it.
        if let path = defaults.string(forKey: "debugPatternImage") {
            image = Self.loadImage(at: URL(fileURLWithPath: path))
        }
        #endif
        ThermalMonitor.shared.isEnabled = colorMode == .thermal
    }

    /// Copies the picture at `url` into the container and switches to the image pattern.
    func setImage(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let loaded = Self.loadImage(at: url) else { throw ImageError.unreadable }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.imageDirectory, withIntermediateDirectories: true)
        if let previous = Self.storedImageURL() {
            try fileManager.removeItem(at: previous)
        }
        let destination = Self.imageDirectory
            .appendingPathComponent(Self.imageName)
            .appendingPathExtension(url.pathExtension)
        // Write the bytes rather than copy the item: a chosen symlink would otherwise be copied as a dangling link.
        try Data(contentsOf: url).write(to: destination)

        image = loaded
        pattern = .image
    }

    private static func storedImageURL() -> URL? {
        let files = try? FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)
        return files?.first { $0.deletingPathExtension().lastPathComponent == imageName }
    }

    /// Decodes a downscaled copy with the EXIF orientation applied.
    nonisolated private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imageMaxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    enum ImageError: LocalizedError {
        case unreadable

        var errorDescription: String? { "This file can't be read as an image." }
    }
}
