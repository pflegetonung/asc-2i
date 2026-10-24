# ASCII Wallpaper

Animated wallpaper for macOS: a field of ASCII characters where patches of brightness slowly drift and individual characters occasionally change.

## Features

- **Live wallpaper.** Each display gets a desktop-level window: above the system wallpaper, below desktop icons and all other windows. It shows on every Space and clicks pass through it. Displays are picked up as they are connected or disconnected.
- **No extra windows.** No Dock icon or menu bar; launching the app shows only the wallpaper.
- **Two patterns.**
  - **Clouds:** patches of brightness slowly drift across the grid.
  - **Image:** glyphs trace the brightness of a picture you choose. The picture fills the screen like a desktop picture, with edges sharpened and contrast auto-leveled so shapes read at one glyph per cell. Nothing drifts: glyphs only swap for others of nearly the same visual weight (about 50 glyphs, sorted by measured ink coverage), and it renders at 10 fps instead of 30. The picture is copied into the app's container.
- **Two color modes**, for either pattern.
  - **Static:** glyphs keep a constant color.
  - **Thermal:** glyphs keep their color while the Mac is cool. Once thermal pressure reaches **Moderate** (MacThrottle's `thermometer.medium`), they gradually warm up with the CPU/GPU temperature through muted yellow, orange, red and maroon. Higher pressure never shows a cooler color than its own band.
- **Settings on reopen.** Opening the app again (Finder, Launchpad, Spotlight) shows a small window with the pattern and color pickers, an image chooser, live pressure and temperature in thermal mode, a **Launch at login** checkbox and a **Quit** button.
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
| `AsciiFieldRenderer.swift` | Metal renderer, glyph atlas and weight-sorted glyph ramp |
| `AsciiFieldShader.swift` | Shader: brightness (noise or picture) and glyph choice for each cell |
| `SettingsView.swift` | Settings window |
| `LaunchAtLogin.swift` | `SMAppService` wrapper |
| `Theme.swift` | Colors, font and the thermal color palette |
| `AppSettings.swift` | Pattern, color mode and the chosen picture |
| `BrightnessMap.swift` | Picture to per-cell brightness: aspect fill, sharpening, auto-levels |
| `ThermalMonitor.swift` | Thermal pressure (pushed by the system) and temperature (polled every 3 s) in thermal mode |
| `ThermalSensors.swift` | Thermal pressure, SMC and HID temperature readers |

## How thermal mode reads the Mac's state

Ported from [MacThrottle](https://github.com/angristan/MacThrottle); works inside the App Sandbox, without admin rights or a helper:

- **Thermal pressure** comes from the `com.apple.system.thermalpressurelevel` Darwin notification (nominal, moderate, heavy, critical). It is finer than `ProcessInfo.thermalState`, which folds moderate and heavy into one state.
- **Temperature** is the hottest CPU/GPU core read from the SMC, falling back to PMU die sensors via IOHIDEventSystem.

## Debug launch arguments

Debug builds accept a few arguments for previews without touching the saved settings:

- `-colorMode thermal -debugThermalPressure <0-3> -debugTemperature <°C>`: preview the thermal palette.
- `-pattern image -debugPatternImage <path>`: preview a picture without choosing it.

## Credits

- [MacThrottle](https://github.com/angristan/MacThrottle) by Stanislas (MIT): thermal pressure and temperature readers.
- [Stats](https://github.com/exelban/stats) (MIT): SMC access and sensor keys used by MacThrottle.
