import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable private var launchAtLogin = LaunchAtLogin.shared
    @Bindable private var settings = AppSettings.shared
    private let thermal = ThermalMonitor.shared
    @State private var isChoosingImage = false
    @State private var imageError: String?

    private static let labelWidth: CGFloat = 52
    private static let labelIndent = labelWidth + 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                labeled("Pattern") {
                    Picker("Pattern", selection: $settings.pattern) {
                        ForEach(WallpaperPattern.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    note(patternDescription)
                    if settings.pattern == .image {
                        imageChooser
                    }
                }
                .padding(.leading, Self.labelIndent)

                labeled("Color") {
                    Picker("Color", selection: $settings.colorMode) {
                        ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .padding(.top, 6)
                VStack(alignment: .leading, spacing: 8) {
                    note(colorDescription)
                    if settings.colorMode == .thermal {
                        Text(thermalStatus)
                            .font(.callout.monospacedDigit())
                    }
                }
                .padding(.leading, Self.labelIndent)
            }

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin.isEnabled)
                .toggleStyle(.checkbox)

            if launchAtLogin.requiresApproval {
                HStack(spacing: 6) {
                    Text("Needs approval in Login Items.")
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") { launchAtLogin.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
            if let error = launchAtLogin.lastError {
                errorText(error)
            }

            Divider()

            HStack {
                Text("Open the app again to show this window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { launchAtLogin.refresh() }
        .fileImporter(isPresented: $isChoosingImage, allowedContentTypes: [.image]) { result in
            do {
                try settings.setImage(from: result.get())
                imageError = nil
            } catch {
                imageError = error.localizedDescription
            }
        }
    }

    private var imageChooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let image = settings.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Button(settings.image == nil ? "Choose Image…" : "Change Image…") { isChoosingImage = true }
                    .fixedSize()
            }
            if let imageError {
                errorText(imageError)
            }
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: Self.labelWidth, alignment: .trailing)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var patternDescription: String {
        switch settings.pattern {
        case .clouds:
            "Patches of brightness slowly drift across the grid."
        case .image where settings.image == nil:
            "Glyphs trace a picture's brightness. Until you choose one, clouds are shown."
        case .image:
            "Glyphs trace the picture's brightness. Nothing drifts; glyphs only swap for others of the same weight."
        }
    }

    private var colorDescription: String {
        switch settings.colorMode {
        case .still:
            "Glyphs keep a constant color."
        case .thermal:
            "Glyphs keep their color while the Mac is cool. From Moderate thermal pressure "
                + "they warm up with its temperature: yellow, orange, red, then maroon."
        }
    }

    private var thermalStatus: String {
        guard thermal.isPressureAvailable else { return "Thermal pressure is unavailable." }
        let temperature = thermal.temperature.map { "\(Int($0.rounded())) °C" } ?? "temperature unavailable"
        return "Pressure: \(thermal.pressure.displayName) · \(temperature)"
    }
}

/// Small settings window; shown only when the already running app is opened again.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "ASCII Wallpaper"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        guard let window else { return }
        LaunchAtLogin.shared.refresh()
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

#Preview {
    SettingsView()
}
