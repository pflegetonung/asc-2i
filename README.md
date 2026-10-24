# ASCII Wallpaper

Animated wallpaper for macOS: a field of ASCII characters where patches of brightness slowly drift and individual characters occasionally change.

## Features

- **Live wallpaper.** Each display gets a desktop-level window: above the system wallpaper, below desktop icons and all other windows. It shows on every Space and clicks pass through it. Displays are picked up as they are connected or disconnected.
- **No extra windows.** No Dock icon or menu bar; launching the app shows only the wallpaper.
- **Settings on reopen.** Opening the app again (Finder, Launchpad, Spotlight) shows a small window with a **Launch at login** checkbox and a **Quit** button.
- **Launch at login.** Uses `SMAppService` and is turned on at first launch.
- **Low resource use.** Rendered with Metal (~4–5% CPU at 30 fps). Animation pauses (0% CPU) while displays are asleep or locked, the session is inactive, or a display is fully covered by a window (for example, an app in full screen).
- Respects the system **Reduce Motion** setting by stopping the animation.

## Requirements

- macOS 14+
- Xcode 26+ (no Metal Toolchain needed: the shader is compiled at launch)

## Build and install

```bash
xcodebuild -project ASC2.xcodeproj -scheme ASC2 -configuration Release -derivedDataPath build
```

Copy `build/Build/Products/Release/ASCII Wallpaper.app` to `/Applications` so the login item points at the installed copy.

## Release DMG

```bash
scripts/build-dmg.sh
```

Builds a universal (Apple Silicon + Intel) Release app and packs it into `build/ASCII-Wallpaper-<version>.dmg`: a Finder window with the app and an Applications link to drag it onto. The first run asks to let Terminal control Finder (used to lay out the window).

Signing depends on the keychain:

- **Developer ID Application** certificate present: the app and DMG are signed with it. Set `NOTARY_PROFILE` to a `notarytool` keychain profile to also notarize and staple the DMG:

  ```bash
  xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>
  NOTARY_PROFILE=<profile> scripts/build-dmg.sh
  ```

- **Apple Development** only: the DMG works, but Gatekeeper blocks the app on other Macs. Users have to open it once via **System Settings › Privacy & Security › Open Anyway**.

## Project layout

| File | Purpose |
| --- | --- |
| `MyApp.swift` | Entry point and `AppDelegate`: starts the wallpaper, shows settings on reopen |
| `WallpaperController.swift` | One wallpaper window per display, pause logic |
| `AsciiFieldView.swift` | SwiftUI wrapper around `MTKView` |
| `AsciiFieldRenderer.swift` | Metal renderer and glyph atlas |
| `AsciiFieldShader.swift` | Shader: noise, brightness and glyph choice for each cell |
| `SettingsView.swift` | Settings window |
| `LaunchAtLogin.swift` | `SMAppService` wrapper |
| `Theme.swift` | Colors and font |
