# Actualist

**A native, local-first iPhone and iPad client for [Actual Budget](https://actualbudget.org/).**

![Status: Beta](https://img.shields.io/badge/status-beta-E4A258)
![Platform: iOS 26+](https://img.shields.io/badge/iOS-26%2B-624183)
![UI: SwiftUI](https://img.shields.io/badge/UI-SwiftUI-1F6B64)
![License: GPL v3](https://img.shields.io/badge/license-GPLv3%20with%20App%20Store%20Exception-2F6FEB)

**Beta:** [Join TestFlight](https://testflight.apple.com/join/HDG6PcGX) ·
[actualist.app](https://actualist.app) ·
[Source](https://github.com/sporez/actualist)

Actualist connects directly to a normal Actual sync server, imports your budget
to a local SQLite database, and renders from that local copy. It is designed for
quick, repeated budget review on iPhone and iPad, with native SwiftUI navigation
and iOS Liquid Glass controls.

> [!CAUTION]
> **Actualist is beta software and can modify real financial data.** Before using
> it, export and verify
> [a backup of every budget you plan to test](https://actualbudget.org/docs/backup-restore/backup/).
> Do not rely on Actualist as the only copy of your data, and only test with a
> budget you are prepared to restore.

## App Preview

<p align="center">
  <img src="screenshots/IMG_3425.PNG" width="23%" alt="Actualist monthly budget screen">
  <img src="screenshots/IMG_3426.PNG" width="23%" alt="Actualist spending transaction feed">
  <img src="screenshots/IMG_3427.PNG" width="23%" alt="Actualist accounts screen">
  <img src="screenshots/IMG_3428.PNG" width="23%" alt="Actualist reports dashboard">
</p>

<p align="center"><sub>Budget · Spending · Accounts · Reports<br>Screenshots use randomized display values.</sub></p>

## Features

- Envelope and tracking budgets, category assignments, rollover, templates,
  notes, and overspending review. Move Money is available for envelope budgets.
- Searchable transaction feeds, with create, edit, delete, categorize,
  split, transfer, and eligible undo actions.
- Accounts with on-budget, off-budget, and closed balances, plus notes. Add
  and reconcile accounts. Manage groups when your Actual server supports them.
- iPad sidebar, category details, and up to five budget months side by side.
  Compact layouts can use Swipe Between Months for full-width transitions.
- History in the Budget ⋯ menu shows the last 25 changes on this device, with
  review and undo for the most recent eligible budget or transaction change.
- Reports for net worth, cash flow, spending, and budget comparisons.
- SimpleFIN Bank Sync and selected Apple Wallet imports, with review before save.
- Payee and rule management under Settings → Budget & Data.
- Widgets for balances, budget overview, recent activity, net worth, and quick
  actions. Configure them through Apple's **Edit Widget** controls.
- Shortcuts and Siri, themes, sample-value privacy, and background refresh.
- Offline changes that sync when your server is reachable, optional budget
  encryption, OpenID sign-in, and custom request headers.

Envelope budgets show **Assigned / Available** and **To Budget**. Tracking
budgets show **Budgeted / Balance** for expenses and **Budgeted / Received** for
income, with **Projected Savings** for current/future months and **Saved** or
**Overspent** for past months. Tracking expense balances reset monthly unless
rollover is enabled.

Add or edit templates from a category or Settings → Templates. Saving a template
changes its setup; **Apply Template** previews and assigns the money separately.
The preview switches between filling empty categories and overwriting existing
assignments, showing funding needed, resulting category balances, and any
shortfall before either action is confirmed.

## Requirements

- An iPhone or iPad running iOS/iPadOS 26 or later.
- A running [Actual Budget server](https://actualbudget.org/docs/install/) with at
  least one budget already uploaded for sync, unless you only open the bundled
  demo from onboarding.
- Network access from the device to that server. If the server is available only
  through a VPN, Tailscale, or another private network, connect the device to that
  network first.
- Your Actual server password, or OpenID if the server is configured for it.
- For an encrypted budget, the separate budget encryption password.

Public TestFlight builds correspond to `testflight/v<version>-b<build>` source
tags. Features described here reflect the current source.

## Connecting to Your Server

1. Enter your Actual server URL and sign in with its password or OpenID.
2. Choose a synced budget and enter its separate encryption password if needed.
3. Keep Actualist open until the initial import finishes.

Use HTTPS for remote servers. Trusted local HTTP connections are allowed but
unencrypted. If you use a VPN or Tailscale, connect the device first. If sign-in
fails, check that the server opens in Safari and that you are using the server
password rather than the budget encryption password.

Settings opens from the Budget gear button or the iPad sidebar. Proxy headers
can be configured during onboarding or under **Connection & Sync → Custom
Headers**, with separate Keychain-stored values for primary and fallback servers.
Header-only login is not supported; use password or OpenID.

## Data Safety

Keep Actual exports and compare important totals with the official client while
using the beta. Read recovery confirmations before reimporting or erasing data.

Local budgets and pending changes are excluded from device backups. **Unsynced
changes are lost if the app or local data is removed, or the device is lost.**
Before erasing or replacing a device, connect and confirm **Pending Sync: None**
in Settings. Synced changes can be restored from your Actual server.

**Background Bank Sync** is experimental and off by default under Settings →
Advanced. Enabling it automatically saves downloaded bank changes. Manual Bank
Sync lets you review changes before saving.

## Current Limitations

- Bank Sync can download SimpleFIN transactions from your Actual server or a
  device token. Other bank providers still arrive only after another Actual
  client or the server imports them.
- You can add and reconcile accounts. Renaming, closing, reopening, and
  deleting accounts are not yet supported.
- Imported split rules run but cannot be edited here. Formula actions, some date
  and recurrence options, and rules managed by schedules also remain read-only.
- Template definitions written in a category note stay view-only. Unsupported
  newer fields, schedule formulas or splits, and cleanup templates are not
  available for editing here, so their stored definition is not rewritten.

## Reporting Bugs

[Open an issue](https://github.com/sporez/actualist/issues/new) with your app/server
versions, device, and steps to reproduce. Attach **Settings → Support → Share
Diagnostic Report** when useful. Keep credentials and personal financial data
out of reports and screenshots.

If an action appears to damage data, stop repeating it and preserve your backup.
Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Privacy

Actualist has no advertising, tracking, analytics SDK, or developer-operated
backend. It connects to your chosen Actual Budget server and, if you configure a
SimpleFIN device token, directly to SimpleFIN.
See the full [Privacy Policy](PRIVACY.md) for its local storage, TestFlight, and
bug-reporting disclosures.

## Building From Source

You will need macOS, Xcode 26 or later, and an iOS 26 simulator or device.

```sh
git clone https://github.com/sporez/actualist.git
cd actualist
open Actualist.xcodeproj
```

Resolve Swift packages in Xcode, select the `Actualist` scheme, and run the app.

For the simulator helper, first copy `scripts/lib/destinations.example.sh` to
`scripts/lib/destinations.sh` and set `ACTUALIST_SIMULATOR_ID` to an installed
simulator ID from `xcrun simctl list devices available`. Then run:

```sh
scripts/run-ios-simulator.sh --boot
```

See the [development guide](docs/DEVELOPMENT.md) for demo budgets and test commands.

Actualist is an independent community project, not affiliated with or endorsed
by Actual Budget.

## License

Actualist source code is licensed under the
[GNU General Public License version 3 only](LICENSE), with a narrow
[App Store and TestFlight exception](APP_STORE_EXCEPTION.md). Modified versions
may be used and distributed, but a distributed derivative must provide its
corresponding source under GPLv3. The exception permits Apple distribution terms
without removing that source-code obligation.

The GPL does not grant permission to use the Actualist name or branding for a
modified distribution. See [TRADEMARKS.md](TRADEMARKS.md). Third-party software
and Actual Budget attribution are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Copyright © 2026 Neil DeLillo.
