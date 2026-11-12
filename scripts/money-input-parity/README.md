# Money input parity harness

`generate.mjs` runs Actual's own amount-field code under vitest in the oracle
checkout and records what a person's typing produces. It writes
`money-input-contract.json` and `money-input-manifest.json` into
`ActualistTests/Fixtures/ActualCore26_11_0/MoneyInput/`.

What runs:

- `useFormat().fromEdit`, the parser behind the reconciliation balance, the
  schedule amount and the template amounts (`AmountInput` calls it on blur and
  Enter). It trims, strips letters and bidi marks, evaluates `+ - * / ^` and
  parentheses, then falls back to `currencyToAmount`, then rounds with
  `Math.round(amount * 10^decimalPlaces)`.
- `useFormat().forEdit`, the text Actual puts in a field for a stored amount.
  Each case also records `fromEdit` of that text.
- A mounted `AmountInput` with `autoDecimals`, as the Hold modal uses it: typed
  digits shift into cents, then the blur parses the field.

Each typed string runs under each of Actual's five number-format preferences
(`comma-dot`, `dot-comma`, `space-comma`, `apostrophe-dot`, `comma-dot-in`) and
both currency scales Actual has (2 decimals, and 0 for JPY). Actual has no
3-decimal currency. A result is `integer` (a safe integer), `none` (null),
`unsafe` (a number Actual would later refuse to display, with its text) or
`threw`. The manifest lists every case where Actual throws.

The generator writes a temporary test file inside the oracle checkout and
removes it afterwards, like the other harnesses. Run it against a scratch copy
of the pinned tag, not against a checkout you need to keep clean.

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/money-input-parity/generate.mjs
ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/money-input-parity/generate.mjs --check
node scripts/money-input-parity/verify.mjs
```

`--check` regenerates into a temporary directory and compares it with the
committed files. Without the oracle it exits 2. `verify.mjs` needs no oracle.
Any edit to `generate.mjs` changes its hash, so regenerate and re-run both.
