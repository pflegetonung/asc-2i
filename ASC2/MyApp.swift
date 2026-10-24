import AppKit
import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Обычных окон у приложения нет: обои создаёт AppDelegate, настройки открываются при повторном запуске.
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let wallpaper = WallpaperController()
    private lazy var settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        wallpaper.start()
        LaunchAtLogin.shared.enableOnFirstLaunch()
    }

    /// Приходит, когда пользователь открывает уже запущенное приложение (Finder, Launchpad, Spotlight).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
