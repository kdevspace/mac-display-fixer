# Mac Display Fixer

A menu bar app for macOS that fixes how non-Apple displays render: proper
resolutions, HiDPI/scaled modes (including hidden GPU-scaled ones), high
refresh rates, rotation, DDC brightness/contrast and **virtual displays** —
a lightweight open-source alternative to [BetterDisplay](https://github.com/waydabber/BetterDisplay).

> The UI is currently in Russian. No entitlements, drivers or permissions
> are required — the app is a launch agent living in your menu bar.

## Features

| Feature | Implementation |
|---|---|
| Display & mode list (incl. hidden HiDPI variants) | CoreGraphics (`CGGetActiveDisplayList`, `CGDisplayCopyAllDisplayModes` + duplicate-low-res flag) |
| Monitor names | private CoreDisplay `CoreDisplay_DisplayCreateInfoDictionary` (`CGDisplayIOServicePort` is broken on macOS 26+) |
| Resolution / refresh rate switching | public CG API: `CGConfigureDisplayWithDisplayMode` (permanent) |
| **Hidden framebuffer modes** (e.g. `1920×1080 HiDPI @120Hz` applied directly to a physical monitor, no dummy needed) | full mode enumeration via private `CGSGetDisplayModeDescriptionOfLength` (D4 struct), applied by IOKit mode ID through `CGSConfigureDisplayMode` inside a configuration transaction |
| Rotation 0/90/180/270° | private MonitorPanel.framework (`MPDisplay.setOrientation:`, the binary lives in the dyld shared cache) — same as `displayplacer` |
| DDC/CI brightness (VCP 0x10) & contrast (VCP 0x12) for external monitors | `IOAVServiceRead/WriteI2C` (Apple Silicon), channel mapping via an IORegistry walk (as in MonitorControl/Crisp) |
| Built-in display brightness | private DisplayServices.framework `DisplayServicesSetBrightness` via dlsym (`IODisplayConnect` no longer exists on Apple Silicon) |
| **Virtual displays** (10 aspect presets: 16:9 … 32:9, 3:2, portrait, etc., mode ladder 720p→8K, always HiDPI) | private `CGVirtualDisplay`/`CGVirtualDisplayDescriptor`/`CGVirtualDisplaySettings` classes (ObjC target with a reverse-engineered header, same as BetterDummy/DeskPad) |
| Virtual display refresh rate selection (60…240 Hz) | forwarded to the display settings; note that Apple Silicon macOS currently clamps virtual displays to 60 Hz (the BetterDummy author hit the same wall) |
| **Mirroring a physical monitor onto a virtual display** | public `CGConfigureDisplayMirrorOfDisplay` (unmirror via `kCGNullDirectDisplay`) — mirrors even survive app relaunches because the serial number is preserved |
| Forced virtual display removal | private `CGSConfigureDisplayEnabled(false)` — after mirroring, the system holds internal retains on `CGVirtualDisplay`, so releasing the object alone is not enough |
| **Saved mode persistence & auto-restore** | the selected mode is stored per display UUID **by attributes** (not the volatile mode ID) and re-applied after sleep/reconnect only on an exact match in the current mode list |

## Why virtual displays?

The classic BetterDummy use case: a non-Apple monitor doesn't offer the
HiDPI/scaled modes you want.

1. Create a virtual display with the right aspect ratio (16:9, 21:9, 32:9 …).
2. On the physical monitor's card pick it in the “Mirror onto” row — the
   monitor joins the virtual display's mirror set and gets its mode list.
3. The resolution is now set on the virtual display's card; the picture is
   rendered in the selected mode and mirrored to the monitor.

Virtual displays persist in UserDefaults and are recreated on launch.

**Tip:** on many monitors you don't even need a dummy — check the physical
display's mode list for entries marked “скрытый” (hidden). Those are
GPU-scaled framebuffer modes (e.g. `1920×1080 (HiDPI → render 3840×2160)
· 120 Hz`) applied directly, keeping the monitor's native refresh rate.

## Build & run

```bash
swift build                # CLI/debug only
./build-app.sh             # release build + Mac Display Fixer.app + ad-hoc signing
open "build/Mac Display Fixer.app"
```

The app icon is generated from code: `swift tools/MakeIcon.swift &&
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`.

## CLI (also the smoke-test tool)

```bash
.build/debug/nbd --list                       # displays + all modes (incl. hidden CGS ones)
.build/debug/nbd --cgs <id>                   # raw dump of the private CGS mode list
.build/debug/nbd --probe                      # DDC brightness/contrast, built-in brightness
.build/debug/nbd --brightness <id> <0-100>
.build/debug/nbd --contrast  <id> <0-100>
.build/debug/nbd --mode <id> <W> <H> [hz] [hidpi] [--raw]   # [--raw] = don't remember it
.build/debug/nbd --restore <id>               # re-apply the saved mode if macOS reset it
.build/debug/nbd --rotate <id> <0|90|180|270>
.build/debug/nbd --mirror <id> <masterID>     # mirror a display onto another
.build/debug/nbd --unmirror <id>
.build/debug/nbd --vtest                      # virtual display end-to-end test
```

## Project layout

```
Sources/
  CGVirtualDisplayKit/     # ObjC target: private CGVirtualDisplay header (classes live in the CoreGraphics binary)
  nbd/
    main.swift             # entry: CLI when arguments are present, otherwise the GUI
    App.swift              # MenuBarExtra (SwiftUI) + display cards + virtual display management
    DisplayStore.swift     # UI state, CGDisplayReconfigurationCallback, wake handling
    DisplayManager.swift   # enumeration, modes, apply (public CG + CGS path), mirror, saved modes
    VirtualDisplayManager.swift  # virtual display lifecycle + persistence
    DDCService.swift       # DDC/CI over IOAVService + write coalescing
    InternalDisplay.swift  # built-in display brightness
    RotationService.swift  # rotation via MonitorPanel (MPDisplay)
    PrivateAPIs.swift      # @_silgen_name / dlsym declarations of private APIs
    CLI.swift              # CLI + self-tests
tools/MakeIcon.swift       # app icon generator (CoreGraphics)
```

## Known limitations

- DDC works on Apple Silicon only (the Intel `IOFBCopyI2CInterfaceForBus` path is not implemented).
- macOS clamps virtual displays to **60 Hz** on Apple Silicon (registered 120/144 Hz rates are silently turned into 60) — if you need 120/144 Hz + HiDPI, use the hidden CGS modes directly on the physical monitor instead.
- The maximum refresh rate of a physical monitor depends on its cable/input (e.g. the Samsung C32JG5x does 144 Hz only over DisplayPort, 120 Hz over HDMI).
- Rotation uses a private Apple API (MonitorPanel); the `MPDisplay` class is present in the dyld shared cache of all current macOS versions, but it is not a public contract.
- Some monitors don't answer DDC reads while writes still work — in that case sliders start from mid-range.
- The virtual display mode ladder has a 32-px step (1280×720 … 5120×2880 etc.), so the picker contains many non-standard intermediate sizes (same as BetterDummy).

## License

MIT — see [LICENSE](LICENSE). Portions of the display logic are based on
techniques from the open-source projects BetterDummy, MonitorControl,
Crisp, DeskPad and displayplacer (their licenses apply to their own code;
this project re-implements the techniques, see the source comments).

