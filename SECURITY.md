# Security

Panefold can move and resize every window on your Mac, so this page explains what it can do and how to report a problem.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through [GitHub's vulnerability reporting](https://github.com/mralifakbar/panefold/security/advisories/new) with steps to reproduce. You'll get a reply within a week.

Only the latest release gets security fixes.

## What Panefold can do

- **Accessibility.** With your permission, Panefold reads window positions, sizes, roles and owning apps, and moves, resizes, raises, minimizes or closes windows. It reads window titles only while the window switcher is open, and for apps you made an "always float" rule for. It never reads window contents and never takes screenshots.
- **Keyboard.** Shortcuts are registered with macOS's hot key API, which reports only those combinations. Panefold has no keyboard event tap and doesn't ask for Input Monitoring. Keys are read directly only inside its own Settings window while you record a shortcut, and inside the window switcher and cheat sheet while they're open.
- **Mouse.** A passive monitor sees clicks, drags and pointer position to support ⌘-drag swapping, edge resizing, the grip and hover focus. It can't change or block events.
- **Apps.** Opening a setup launches its apps and hides others with the standard AppKit calls. Nothing is ever quit.

## What is stored

In Panefold's preferences (`~/Library/Preferences/dev.panefold.Panefold.plist`), readable only by your user account: settings, each screen's layouts, learned minimum sizes, setups (app identifiers, never documents or titles), always-float rules (an app and two words), and activity counts.

## Network

- The update check (once a day, can be turned off) requests `https://api.github.com/repos/mralifakbar/panefold/releases/latest`. It sends no identifier and installs nothing; it only shows a link.
- Nothing else. There is no telemetry.

## Builds

Release builds are made with `scripts/release.sh` from a tagged commit, signed with the maintainer's Developer ID certificate, with a SHA-256 checksum on the release page.
