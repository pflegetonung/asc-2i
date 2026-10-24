import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 340)
        .onAppear { launchAtLogin.refresh() }
    }
}

/// Мини-окно настроек; показывается только при повторном открытии уже запущенного приложения.
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
