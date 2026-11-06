# Contributing to Panefold

Thanks for helping. Bug reports, fixes, translations and small focused features are all welcome.

## Reporting a bug

Open an issue with:

- Your macOS version and Mac (Apple silicon or Intel), and your screens (sizes, which is the laptop).
- The layout and window count on that screen, and the apps involved.
- What you did, what you expected, and what happened.
- **Settings › About › Copy Report** with diagnostics: apps appear as letters and window titles are never included.
- For a crash, the report from `~/Library/Logs/DiagnosticReports/Panefold-*.ips`.

## Making a change

1. Fork the repository and create a branch.
2. Run every check (there is no hosted CI, so this is what a pull request should pass):

   ```sh
   ./scripts/ci.sh
   ```

3. Try the change with real windows: several apps, more windows than the screen holds, and a second display if it touches screens. Unit tests cover the layout engine and the tiling state, not Accessibility.
4. If the change adds interface text, run `python3 scripts/check-strings.py`. New strings show in English until translated.
5. Open a pull request that says what changed and how you tested it.

## Layout

```
Sources/PanefoldCore/     layout engine, tiles and stacks, navigation, shortcuts, settings, setups (no AppKit)
Sources/Panefold/         Accessibility, hot keys, window manager, overlays, SwiftUI interface
Tests/PanefoldCoreTests/  unit tests for PanefoldCore
Resources/                Info.plist and translations (*.lproj)
scripts/make-icon.swift   draws the app icon
scripts/extract-strings.py, check-strings.py   list interface strings, check translations
build.sh                  builds, signs and packages the .app
scripts/ci.sh, release.sh   local checks, and publishing a release
scripts/notarize.sh       notarizes and staples a Developer ID build
```

## Development switches

| Switch | Effect |
|---|---|
| `PANEFOLD_DEFAULTS_SUITE=<name>` | Keep settings and layouts in a separate preferences suite, so a test run doesn't touch yours. |
| `PANEFOLD_SNAPSHOT_DIR=<dir>` (debug builds) | Render the tour and Settings pages to PNG in that folder, then quit. Moves no windows. |
| `PANEFOLD_DARK=1` | With the snapshot switch, render in dark mode. |
| `PANEFOLD_SIGN_IDENTITY="…"` (build.sh) | Sign with that certificate instead of the first one found. |
| `tccutil reset Accessibility dev.panefold.Panefold` | Forget the Accessibility grant, to test the first run again. |

The README screenshots are made like this:

```sh
swift build
for dark in 0 1; do
  PANEFOLD_DEFAULTS_SUITE=dev.panefold.snapshot PANEFOLD_DARK=$dark PANEFOLD_SNAPSHOT_DIR=docs .build/debug/Panefold
done
```

## Guidelines

- Keep `PanefoldCore` free of AppKit and SwiftUI. Anything that can be unit tested belongs there, with a test.
- Never block on another app: Accessibility calls have short timeouts, and a frozen app must not freeze Panefold.
- Never store, log or send window titles or what's inside windows.
- Interface text is short, plain, and names the next step when something is wrong.
- Debug-only helpers go behind `#if DEBUG`.

## Translating

Copy `Resources/es.lproj/Localizable.strings` to `Resources/<language>.lproj/`, translate the right-hand side, and keep every `%@` and `%lld`. Use `%1$@`, `%2$@` to reorder them. Then run `python3 scripts/check-strings.py`.

## Releasing (maintainers)

1. Move the **Unreleased** notes in `CHANGELOG.md` under a new version heading.
2. Commit, then run `./scripts/release.sh 0.2.0` on your Mac. There is no hosted CI:
   the script checks everything first, then runs the tests, builds the universal app
   signed with the Developer ID, notarizes and staples it, pushes `main` and the
   `v0.2.0` tag, and publishes the GitHub release with the zip, its SHA-256 and the
   changelog section as notes.
3. Once per Mac: the Developer ID Application certificate in the keychain, notarization
   credentials saved with `xcrun notarytool store-credentials notary …` (see the top of
   `scripts/notarize.sh`), and `gh auth login`.

By contributing, you agree that your work is released under the [MIT License](LICENSE).
