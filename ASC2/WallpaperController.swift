import AppKit
import Observation
import OSLog
import SwiftUI

/// Состояние воспроизведения одного окна-обоев.
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

/// Окно без рамки на уровне рабочего стола: выше системных обоев, но ниже иконок и всех обычных окон.
/// Клики проходят насквозь в Finder, окно видно на всех Spaces и не участвует в Mission Control / Cmd-Tab.
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

/// Держит по одному окну-обоям на каждый экран и пересобирает их при изменении конфигурации мониторов.
/// Анимация встаёт на паузу, когда её никто не видит: экран спит или заблокирован, сессия неактивна,
/// либо дисплей целиком закрыт окном (полноэкранное приложение).
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

        // Окна на уровне рабочего стола не получают изменений occlusionState, поэтому перекрытие
        // проверяем сами по списку окон: на смене Space/приложения и раз в пару секунд (ресайз окон).
        coverageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlayback() }
        }
        coverageTimer?.tolerance = 1
        updatePlayback()
    }

    /// Подписка, после которой состояние воспроизведения пересчитывается.
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

    /// Дисплеи, которые целиком закрыты одним обычным непрозрачным окном текущего Space.
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
