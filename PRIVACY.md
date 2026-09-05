# Privacy Policy

Effective September 5, 2026.

Actualist is an independent, open-source iPhone client for Actual Budget. This
policy describes the data handling performed by Actualist itself.

## Data Actualist Handles

Actualist connects directly to the Actual Budget server address you provide. It
uses that connection to authenticate, download and synchronize your selected
budget, and send changes you make in the app.

Your budget data is stored in Actualist's private app container on your device
and on the Actual Budget server you choose. Sync tokens, unlocked budget
encryption keys, and any SimpleFIN device access URL you claim are stored in
the iOS Keychain. Your Actual server password is used to authenticate and is
not retained by Actualist.

To display widgets, Actualist also keeps a local snapshot in an App Group
container shared with its widget extension. This includes budget, category and
account names, balances, recent transaction summaries, attention counts, and
net-worth history. The sample-values privacy setting replaces names and amounts
before this snapshot is saved. The extension does not receive server credentials,
open the budget database, or contact your server. Financial widget views are
marked as sensitive for Apple's system-controlled redaction. The selected color
theme is also shared locally so widgets follow the app's appearance.

If your server uses OpenID, sign-in happens with the identity provider that
server is configured to use. Actualist receives a session token from the Actual
server and does not operate the identity provider.

If you import from Apple Wallet, Actualist uses Apple's on-device transaction
picker. You choose which transactions to add. Those records stay on this device
and on your Actual server after you save; the developer does not receive them.

If you use Bank Sync, downloads go through your Actual server when it hosts
SimpleFIN. If you paste a SimpleFIN setup token instead, Actualist claims a
device access URL over HTTPS and downloads from SimpleFIN on this device.
Background Bank Sync, when enabled, uses the server path only.

New-transaction alerts are local notifications generated on your device.
Actualist does not use a developer-operated push-notification service.

## Developer Collection

Actualist has no advertising, tracking, analytics SDK, or developer-operated
backend. The developer does not receive or collect your budget contents,
financial transactions, credentials, server address, or usage activity through
the app. Personal data handled by the app is not sold.

## Services You Choose

Your Actual Budget server is operated by you or by the hosting provider you
select. Its operator and privacy practices are outside Actualist's control.

If you install a beta through Apple TestFlight, Apple may collect beta usage,
crash, and diagnostic information under Apple's own privacy terms. If you
choose to report a bug or vulnerability through GitHub, the information you
submit is handled by GitHub and will be visible according to the reporting
method you select. Review attachments before submitting them and do not include
credentials or unredacted financial information.

## Device Backups

The imported budget directory, including pending sync changes and recovery
copies, is excluded from iPhone and iCloud device backups. The financial widget
snapshot is also excluded. Changes that have finished syncing can be restored
from your Actual server. Pending changes cannot be recovered from a device
backup if the device is lost or local data is removed.

## Retention and Deletion

Use **Settings → Connection & Sync → Disconnect & Erase Local Data** to remove
the imported budgets and saved authentication credentials from Actualist. This
also clears the selected budget and its widget snapshot. Removing the app
removes its private local files; use the in-app erase action before uninstalling
to explicitly clear credentials stored in Keychain.

Deleting local data does not delete information from your Actual Budget server
or revoke access at SimpleFIN or your identity provider. Manage those services
separately. Before erasing local data, let pending changes finish syncing if you
want to keep them.

## Changes and Contact

Material changes to this policy will be published in this repository with a new
effective date. For a privacy question, open a GitHub issue that contains no
sensitive information. For a security issue or a report containing sensitive
details, follow [SECURITY.md](SECURITY.md).
