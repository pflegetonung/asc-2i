import AppKit
import Observation
import OSLog
import SwiftUI

/// Playback state of a single wallpaper window.
@Observable final class WallpaperPlayback {
    var isPaused = false
}

private struct WallpaperContent: View {
    let playback: WallpaperPlayback

    var body: some View {
        AsciiFieldView(isPaused: playback.isPaused)
            .ignoresSafeArea()
    }
}

/// Borderless desktop-level window: above the system wallpaper but below desktop icons and all regular windows.
/// Clicks pass through to Finder; the window shows on every Space and stays out of Mission Control / Cmd-Tab.
final class WallpaperWindow: NSWindow {
    let playback = WallpaperPlayback()
    let screenID: CGDirectDisplayID

    init(screen: NSScreen) {
        screenID = screen.displayID
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = NSColor(Theme.background)
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = NSHostingView(rootView: WallpaperContent(playback: playback))
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keeps one wallpaper window per display and rebuilds them when the display configuration changes.
/// Animation pauses when nobody can see it: displays are asleep or locked, the session is inactive,
/// or a display is fully covered by a window (a full-screen app).
final class WallpaperController {
    private var windows: [WallpaperWindow] = []
    private var screensAsleep = false
    private var sessionInactive = false
    private var screenLocked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var coverageTimer: Timer?

    func start() {
        rebuildWindows()

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.rebuildWindows() }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { _ in }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { _ in }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }

        // Desktop-level windows never get occlusionState changes, so coverage is checked manually
        // from the window list: on Space/app switches and every couple of seconds (window resizes).
        coverageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlayback() }
        }
        coverageTimer?.tolerance = 1
        updatePlayback()
    }

    /// Subscribes to a notification; playback state is recomputed after each one.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ update: @escaping (WallpaperController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.updatePlayback()
            }
        }
        observers.append((center, token))
    }

    private func rebuildWindows() {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))

        windows.removeAll { window in
            guard !ids.contains(window.screenID) else { return false }
            window.orderOut(nil)
            return true
        }
        for screen in screens {
            if let window = windows.first(where: { $0.screenID == screen.displayID }) {
                window.setFrame(screen.frame, display: true)
            } else {
                let window = WallpaperWindow(screen: screen)
                window.orderFront(nil)
                windows.append(window)
            }
        }
    }

    private func updatePlayback() {
        let idle = screensAsleep || sessionInactive || screenLocked
        let covered = idle ? [] : coveredDisplays()
        for window in windows {
            let paused = idle || covered.contains(window.screenID)
            if window.playback.isPaused != paused {
                Logger.wallpaper.debug("Display \(window.screenID): \(paused ? "paused" : "playing", privacy: .public)")
                window.playback.isPaused = paused
            }
        }
    }

    /// Displays fully covered by a single regular opaque window on the current Space.
    private func coveredDisplays() -> Set<CGDirectDisplayID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frames: [CGRect] = info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) >= 1,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        var covered = Set<CGDirectDisplayID>()
        for window in windows where frames.contains(where: { $0.contains(CGDisplayBounds(window.screenID)) }) {
            covered.insert(window.screenID)
        }
        return covered
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

private extension Logger {
    static let wallpaper = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AsciiWallpaper", category: "wallpaper")
}
