# Repository Guidelines

Rules for changing this repository. `CLAUDE.md` is a symlink to this file.
[README.md](README.md) describes what the app does; all of its code is in
`Sources/FreeDisplay/`.

## Subagents
- Run subagents, workflow agents and delegated sessions on a cheap, practical
  model (Claude Opus 5.5 rather than Claude Fable 5.2, for example) unless the
  user asks for another.
- Name the model when spawning; left unset, an agent inherits the session's.

## Architecture
- One Swift package with one executable target. The same binary is the
  menu-bar app and the CLI: `main.swift` runs `CLIRunner` and exits whenever a
  command is given, before `NSApplication` starts, so a CLI command never
  creates UI.
- `SkyLightEngine.swift` is the only place that calls SkyLight. It loads the
  framework with `dlopen`/`dlsym` at run time and every symbol is optional: a
  missing one becomes an empty mode list or a failed switch, never a crash.
  Do not link the private framework or add a bridging header for it.
- `VirtualDisplayEngine.swift` is the only place that touches `CGVirtualDisplay`,
  the private CoreGraphics classes behind the HiDPI fallback. It reaches them
  through the Objective-C runtime with `@objc` protocols and checks every
  selector first: a missing class or selector makes the fallback unavailable,
  never a crash. Do not add a bridging header for them.
- A mode record is read from the 0xD4-byte buffer that
  `CGSGetDisplayModeDescriptionOfLength` fills. Its offsets are an observed
  layout, not a documented one; change them only with a dump from a real
  display, and say which macOS version it came from.
- `DisplayViewModel` (`@MainActor`) owns the app state. `MenuBarPopoverView`
  is shown both in the menu-bar popover and in the standalone window; it is
  one view, so change it once.
- `BrightnessController` owns DDC/CI (`IOAVService`, VCP 0x10, loaded with
  `dlsym`) and the gamma table.

## Behavior invariants
- Offer only modes macOS reports and marks safe (`DisplayModeItem.isSafe`).
  Never synthesize modes or write display overrides (EDID, files under
  `/Library/Displays`).
- The only virtual display FreeDisplay creates is the opt-in HiDPI fallback
  (`VirtualDisplayEngine`): offered only for an external display whose
  `fractionalHiDPIModes` is empty, started by the user, undone after 15
  seconds unless kept, torn down when its panel goes away or stops mirroring
  and when the app quits, and brought back on launch only for a panel the
  user kept it on that still has no fractional HiDPI mode. It exists only
  while the app runs.
- Presets derive from the panel's native size: native/1.25, native/(4/3) and
  native/1.6, each within 80 px and at the native aspect ratio (±0.04), plus
  native 1×. Never hard-code a resolution.
- A rate chosen from the refresh-rate menu goes through
  `selectMode(_:requireConfirmIfHzChanges: true)`: it applies `.forSession`
  and reverts after 10 seconds unless the user confirms it. Presets, the
  slider, the HiDPI switch and the mode list keep the current refresh rate
  when the target mode offers it and apply `.permanently`. A new control
  whose main job is changing the refresh rate uses the confirmed path.
- Brightness stays within 20–100 and warmth within 0–50. DDC/CI is used only
  while warmth is off, the gamma table otherwise, and `reset` restores the
  ColorSync settings.
- The bundle identifier `local.opensource.FreeDisplay`, the distributed
  notification `local.opensource.FreeDisplay.showPopover`, the UserDefaults
  keys `FreeDisplay.softwareBrightness`, `FreeDisplay.softwareWarmth` and
  `FreeDisplay.virtualHiDPIDisplays`, and the virtual display's vendor ID
  `0xF0D1` are installed state: renaming one breaks existing installs (the
  second-launch handoff, saved values, the login item, the panels the
  fallback was kept on).
- The app is `LSUIElement` with the `.accessory` activation policy, so it has
  no Dock icon; closing the window leaves it running in the menu bar.

## Language
- Every user-facing string, in the UI and in CLI output, goes through
  `L10n.tr(zh:en:)` with both languages. `--lang zh|en` overrides the system
  language; check both.
- `README.md` and `README.zh-CN.md` change together. A new CLI command or flag
  updates the help text in both languages and both READMEs.

## Swift
- Swift tools 5.9 and macOS 13: `Package.swift` and `LSMinimumSystemVersion`
  in `Info.plist` change together.
- No third-party dependencies; system frameworks only (AppKit, SwiftUI,
  CoreGraphics, IOKit, ServiceManagement).
- The release build has no warnings; keep it that way.

## Verification
There is no test target. CI (`.github/workflows/ci.yml`) runs on every push to
`master` and every pull request: a build with warnings as errors, a CLI smoke
test, the universal package and its bundle checks. Run what your change touches
and say what you could not run.
- Build: `swift build -c release -Xswiftc -warnings-as-errors`; packaging:
  `./build.sh --universal --no-install`.
- CLI: `.build/release/FreeDisplay status`, `list --hidpi`, and `help` with
  `--lang en` and with `--lang zh`.
- Mode switching needs a real external display. Note the starting mode with
  `status`, apply the change (for example `preset 125`), switch back with
  `set`, and check `status` after each step. Leave the display in the mode it
  started in.
- The virtual-display fallback needs a real external display too, and its
  test must run inside `NSApplication.run`: without the event loop, a process
  that has mirrored once stops seeing new displays. Note the mode, turn the
  fallback on, check that `status` shows the panel mirroring the virtual
  display, turn it off (and once let the 15-second countdown run out), and
  check that `status` is back to the starting mode with no extra display. A
  display with native fractional HiDPI never offers it; test it there through
  a harness that calls `DisplayViewModel.enableVirtualHiDPI()`.
- UI: `./build.sh` replaces `/Applications/FreeDisplay.app` and starts it;
  run it only when installing is what the user wants, then check the popover
  in both languages.

## Commits, PRs and releases
- Commits: short and imperative. PRs: summary, rationale, and how it was
  verified (which display, which macOS version).
- A user-visible change adds a bullet under `## [Unreleased]` in
  `CHANGELOG.md`; a release renames that heading to `## [X.Y.Z] - date`, and
  the release notes are taken from that section.
- A release bumps `CFBundleShortVersionString` and `CFBundleVersion` in
  `Info.plist`; the build number only rises. Pushing the tag `vX.Y.Z`, equal to
  `v` + `CFBundleShortVersionString`, runs `.github/workflows/release.yml`: it
  builds the universal app, and `scripts/release/macos_package.py` signs it
  with the Developer ID (hardened runtime, no entitlements), notarizes and
  staples the app and the DMG, verifies the mounted DMG, and the workflow
  publishes `FreeDisplay-X.Y.Z.dmg` with its SHA-256. Never reuse a tag.
  Running the workflow by hand rehearses all of it without publishing.
- Signing material never enters the repository. It lives in the Actions
  secrets `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` and
  `APPLE_NOTARY_PRIVATE_KEY` and the variables `MACOS_SIGNING_IDENTITY`,
  `APPLE_TEAM_ID`, `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_ISSUER_ID`. The
  Developer ID certificate expires on 2027-12-23: before the first release
  after that, replace the two certificate secrets and `MACOS_SIGNING_IDENTITY`.
- `docs/assets/` holds the README images. The English and Chinese demo GIFs
  change together, as whole files, each under 3 MB.
- Never commit build output (`.build/`, `dist/`), recordings or secrets.
