# Changelog

User-visible changes to FreeDisplay. Versions follow
[Semantic Versioning](https://semver.org/); a release takes its notes from
its section here.

## [Unreleased]

- **Brightness stays on the display you set it for** — with more than one
  external display, DDC brightness went to one default display rather than
  the one selected in the panel, all displays shared one brightness and
  warmth, and resetting one display cleared the others' dimming. Each display
  now has its own DDC connection, found in the I/O Registry, and its own
  saved values; a display FreeDisplay can't match is dimmed through gamma
  instead (#2).
- **The bit depth is labelled as the framebuffer's** — the "10-bit" in the
  panel, `status` and `list` is the depth macOS uses for the mode's
  framebuffer, not the bit depth on the cable or the panel's own (#2).

## [1.3.1] - 2026-11-26

- **In-app updates are ready for newer macOS** — macOS 27 deprecates
  `hdiutil attach`, which the updater mounts the downloaded DMG with; when
  it fails, the updater now mounts it with `diskutil image attach` instead.

## [1.3.0] - 2026-11-26

- **In-app updates** — FreeDisplay checks GitHub Releases once a day (or when
  you ask, from the bottom of the panel, where the check can also be turned
  off) and installs a new version with one click: it downloads the DMG with a
  progress bar and speed, checks its SHA-256 and that the app is signed by
  the same Developer ID team, replaces itself and reopens. A copy that can't
  replace itself opens the release page instead.
- **The panel shows the app's version**, next to the update controls.

## [1.2.1] - 2026-11-26

- **The menu bar panel opens in full again** — it no longer opens with its
  top cut off above the screen, and it stays under the menu bar icon when
  its height changes or the display it is on switches mode. 1.2.0 made this
  worse by reopening the panel after every display change; now NSPopover
  sizes the panel from its arrow and is only re-anchored in place (#1).

## [1.2.0] - 2026-11-26

- **Virtual-display HiDPI fallback (experimental)** — for a monitor macOS
  gives no HiDPI mode between 2× and native, the panel can create a virtual
  display with HiDPI modes and have the monitor mirror it, so 2048 × 1152 and
  the other presets work. It costs HDR and a little GPU time, lasts only
  while FreeDisplay runs, switches back after 15 seconds unless kept, and
  comes back on the next launch for a monitor it was kept on.
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
