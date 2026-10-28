# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1.0] — 2026-10-28

### Added

- **User interface localizations**: English, German, Spanish and Simplified
  Chinese (Russian was the original language and remains the base).
  - The app follows your system language automatically; macOS per-app
    language settings (System Settings → Mac Display Fixer → Language) also
    work.
  - All menu bar UI strings are localized: display cards, badges
    (Main/Built-in/Mirrored/Virtual), mode and rotation pickers, mirroring
    rows and notices, virtual display section and tips, error messages,
    mode labels (including the “HiDPI → render WxH”, Hz and “hidden” parts),
  - `Localization/<lang>.lproj/Localizable.strings` tables with 35 keys per
    language; `build-app.sh` packs them into the app bundle
    (`CFBundleLocalizations`).
- `nbd --l10n` CLI diagnostic: prints the effective language and samples
  from every bundled localization table.
- This CHANGELOG.

### Changed

- App version bumped to 1.1.0 (bundle version 2).

## [1.0.0] — 2026-10-28

Initial release.

### Core

- Display list with all usable modes, including HiDPI variants hidden by
  default and the **hidden GPU-scaled framebuffer modes** (private CGS mode
  list; applied by IOKit mode ID through `CGSConfigureDisplayMode`) — e.g.
  `1920×1080 HiDPI (render 3840×2160) @120Hz` directly on a physical monitor.
- Resolution / refresh rate switching via the public CG API.
- Rotation 0/90/180/270° for any display via MonitorPanel (`MPDisplay`).
- DDC/CI brightness & contrast for external monitors over `IOAVService`
  (Apple Silicon), with IORegistry-based channel mapping and write coalescing.
- Built-in display brightness via the DisplayServices private framework.
- **Virtual displays**: 10 aspect presets (16:9 … 32:9, 3:2, portrait),
  720p→8K mode ladder with HiDPI, refresh rate selection, persistence across
  relaunches, mirroring of physical monitors onto them
  (`CGConfigureDisplayMirrorOfDisplay`), forced removal via
  `CGSConfigureDisplayEnabled(false)`.
- **Saved mode persistence & auto-restore**: the selected mode is stored per
  display UUID by attributes and re-applied after sleep/reconnect.
- CLI (`--list`, `--cgs`, `--probe`, `--brightness`, `--contrast`, `--mode`,
  `--restore`, `--rotate`, `--mirror`, `--unmirror`, `--vtest`) for scripting
  and smoke tests.
- Generated app icon (display + green checkmark, `tools/MakeIcon.swift`).
