# Contributing to Actualist

Actualist modifies real financial data. Keep changes focused, test the affected
local-first read or write path, and avoid including personal budget data in code,
fixtures, screenshots, logs, or issues.

For substantial changes, open an issue before investing in an implementation so
the behavior and safety boundaries can be agreed first. Bug fixes and focused
tests can be submitted directly as pull requests.

## Development

- Use Xcode 26 or later and target iOS 26+.
- Keep production reads and writes behind `LocalFirstActualStore` and the
  repository protocols.
- Add every new Swift file to `Actualist.xcodeproj/project.pbxproj`.
- Run `scripts/check.sh` and the relevant tests before submitting.
- Pin simulator destinations by UDID, not display name.

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the full development and
verification workflow.

## Licensing Contributions

Actualist is licensed under GNU GPL version 3 only, with the additional
[App Store and TestFlight Exception](APP_STORE_EXCEPTION.md). By submitting a
contribution, you agree to license it under those same terms and confirm that
you have the right to do so. Do not submit code copied from an incompatible
license or code you are not authorized to contribute.

The Actualist name and branding are governed separately by
[TRADEMARKS.md](TRADEMARKS.md).
