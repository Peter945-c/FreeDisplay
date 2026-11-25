# Changelog

User-visible changes to FreeDisplay. Versions follow
[Semantic Versioning](https://semver.org/); a release takes its notes from
its section here.

## [Unreleased]

- **The panel stays on screen after a mode switch** — switching the
  resolution of the display the menu bar panel is on no longer leaves the
  panel partly off-screen; it re-anchors under the menu bar icon (#1).
- **Integer-only displays are explained** — when macOS offers no HiDPI mode
  between 2× and native for a display (only 1280 × 720 HiDPI on a
  2560 × 1440 panel, for example), the panel and `freedisplay status` say so
  instead of just showing no HiDPI presets.
- **`freedisplay list --all`** also lists the modes macOS marks unsafe, with
  their flags, to attach to bug reports.

## [1.1.0] - 2026-11-23

The first public release.

- **HiDPI presets** — about 125%, 133% and 160% in HiDPI plus native 100%,
  worked out from the panel's resolution, one click each.
- **Every safe mode macOS reports** — a UI-scale slider, a HiDPI switch, a
  refresh-rate menu and the full mode list, keeping the current refresh rate
  wherever the new mode offers it.
- **Refresh-rate safety net** — a rate chosen from the menu reverts after 10
  seconds unless you keep it.
- **Brightness and warmth** — 20–100% over DDC/CI or the gamma table, and a
  warm tint from 0 to 50%; both are remembered.
- **Command line** — `freedisplay status | list | preset | set | brightness |
  reset`.
- **Chinese and English**, following the macOS language or `--lang`.
- **Signed and notarized** — one universal DMG for Apple silicon and Intel,
  macOS 13 or later.
