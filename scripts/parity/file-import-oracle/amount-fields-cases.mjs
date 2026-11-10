// Cases for `parseAmountFields`: the modal's amount interpretation across split (outflow and
// inflow columns), in/out, flip and multiplier. Pure data: no expected output lives here.
//
// Input: { trans, splitMode, inOutMode, outValue, flipAmount, multiplierAmount }. `trans` holds
// the mapped row's `amount`, `outflow`, `inflow` and `inOut` values: strings, or the boolean true
// a saved mapping gets by naming the preview's `selected` flag. A key that is absent from the
// object is absent in Actual (undefined), which is not the empty string. A JSON null (only the
// legacy `amount: null` case) reads like an absent value everywhere here.
import { mulberry32 } from '../sync-merkle/cases.mjs';
import { between, chance, generatedAmount, named, pad, pick } from './case-kit.mjs';

export const AMOUNT_FIELDS_SEED = 20261109 + 12;
export const AMOUNT_FIELDS_GENERATED_COUNT = 600;

const settings = (overrides = {}) => ({
  splitMode: false, inOutMode: false, outValue: '', flipAmount: false, multiplierAmount: '', ...overrides,
});

const fieldsInput = (trans, overrides) => ({ trans, ...settings(overrides) });
const fields = (id, trans, overrides, description) => named(`parseAmountFields/${id}`, fieldsInput(trans, overrides), description);

function legacyCases() {
  const amount = (id, text, description) => fields(id, { amount: text }, {}, description);
  return [
    amount('plain', '12.50', 'a positive amount'),
    amount('negative', '-12.50', 'a negative amount'),
    amount('currency', '$1,234.56', 'currency symbol and grouping'),
    amount('parentheses', '(12.50)', 'parentheses'),
    amount('eu', '1.234,56', 'comma decimal'),
    amount('unreadable', 'abc', 'unreadable text becomes zero'),
    amount('empty', '', 'empty text becomes zero'),
    amount('null', null, 'a null amount becomes zero'),
    amount('zero', '0', 'zero'),
    amount('negative-zero', '-0.00', 'negative zero'),
    amount('past-max', '99999999999999', 'beyond the safe range: unreadable, zero'),
    amount('sub-cent', '0.005', 'a half cent'),
    amount('trailing-code', '12.50 USD', 'trailing currency code'),
  ];
}

function modeCases() {
  const split = { splitMode: true };
  const inOut = (outValue, extra) => ({ inOutMode: true, outValue, ...extra });
  return [
    fields('default/absent', {}, {}, 'no amount key: undefined reads as zero'),
    fields('default/ignores-split-columns', { outflow: '5', inflow: '6' }, {}, 'outflow and inflow are ignored outside split mode'),
    fields('default/ignores-inout', { amount: '5', inOut: 'Debit' }, {}, 'inOut is ignored outside in/out mode'),

    // Split mode: outflow first, then inflow.
    fields('split/outflow-only', { outflow: '12.50' }, split, 'a positive outflow becomes negative'),
    fields('split/inflow-only', { inflow: '12.50' }, split, 'an inflow stays positive'),
    fields('split/both-outflow-wins', { outflow: '3.00', inflow: '5.00' }, split, 'both filled: outflow wins and inflow is zero'),
    fields('split/zero-outflow-inflow-used', { outflow: '0', inflow: '5.00' }, split, 'a zero outflow is falsy, so inflow is read'),
    fields('split/empty-outflow-inflow-used', { outflow: '', inflow: '5.00' }, split, 'an empty outflow is read as zero, then inflow'),
    fields('split/unreadable-outflow-inflow-used', { outflow: 'abc', inflow: '5.00' }, split, 'an unreadable outflow reads as null, then inflow'),
    fields('split/negative-outflow', { outflow: '-12.50' }, split, 'a negative outflow is made negative by absolute value'),
    fields('split/negative-inflow', { inflow: '-5.00' }, split, 'a negative inflow is made positive by absolute value'),
    fields('split/parenthesised-outflow', { outflow: '(12.50)' }, split, 'parentheses on an outflow'),
    fields('split/both-absent', {}, split, 'neither column present'),
    fields('split/both-empty', { outflow: '', inflow: '' }, split, 'both columns empty'),
    fields('split/ignores-amount', { amount: '9.99', outflow: '', inflow: '' }, split, 'amount is not read in split mode'),
    fields('split/outflow-negative-zero', { outflow: '-0.00' }, split, 'a negative-zero outflow'),
    fields('split/currency-columns', { outflow: '$1,234.56', inflow: '' }, split, 'currency and grouping in the outflow column'),
    fields('split/past-max-outflow', { outflow: '99999999999999', inflow: '2.00' }, split, 'an out-of-range outflow reads as null, then inflow'),

    // In/out mode.
    fields('inout/equal-outvalue', { amount: '12.50', inOut: 'Debit' }, inOut('Debit'), 'inOut equals the out value: outflow'),
    fields('inout/different-outvalue', { amount: '12.50', inOut: 'Credit' }, inOut('Debit'), 'inOut differs: inflow'),
    fields('inout/negative-amount-out', { amount: '-12.50', inOut: 'Debit' }, inOut('Debit'), 'a negative amount flagged out stays negative'),
    fields('inout/negative-amount-in', { amount: '-12.50', inOut: 'Credit' }, inOut('Debit'), 'a negative amount flagged in becomes positive'),
    fields('inout/zero-amount', { amount: '0', inOut: 'Debit' }, inOut('Debit'), 'zero flagged out'),
    fields('inout/zero-amount-in', { amount: '0', inOut: 'Credit' }, inOut('Debit'), 'zero flagged in'),
    fields('inout/inout-absent-outvalue-empty', { amount: '5.00' }, inOut(''), 'an absent inOut is not the empty out value'),
    fields('inout/inout-empty-outvalue-empty', { amount: '5.00', inOut: '' }, inOut(''), 'an empty inOut equals an empty out value'),
    fields('inout/inout-padded', { amount: '5.00', inOut: ' Debit ' }, inOut('Debit'), 'padding on inOut: not equal'),
    fields('inout/outvalue-padded', { amount: '5.00', inOut: 'Debit' }, inOut(' Debit'), 'padding on the out value: not equal'),
    fields('inout/both-padded-equal', { amount: '5.00', inOut: ' Debit' }, inOut(' Debit'), 'identical padded values are equal'),
    fields('inout/case-different', { amount: '5.00', inOut: 'debit' }, inOut('Debit'), 'comparison is case sensitive'),
    fields('inout/unreadable-amount', { amount: 'abc', inOut: 'Debit' }, inOut('Debit'), 'an unreadable amount stays zero'),
    fields('inout/with-split-mode', { amount: '12.50', outflow: '1', inflow: '2', inOut: 'Debit' }, inOut('Debit', { splitMode: true }),
      'in/out wins over split: the amount column is read, and the split-shaped result is returned'),
    fields('inout/with-split-mode-in', { amount: '12.50', outflow: '1', inflow: '2', inOut: 'Credit' }, inOut('Debit', { splitMode: true }),
      'in/out with split mode, flagged in'),
    fields('inout/split-mode-no-amount', { outflow: '1', inflow: '2', inOut: 'Debit' }, inOut('Debit', { splitMode: true }), 'in/out with split mode and no amount column'),
    fields('inout/nonstring-inout', { amount: '5.00', inOut: true }, inOut('true'), 'a boolean inOut is never strictly equal to a string'),

    // Flip.
    fields('flip/positive', { amount: '12.50' }, { flipAmount: true }, 'a positive amount becomes negative'),
    fields('flip/negative', { amount: '-12.50' }, { flipAmount: true }, 'a negative amount becomes positive'),
    fields('flip/zero', { amount: '0' }, { flipAmount: true }, 'zero flips to negative zero outflow'),
    fields('flip/absent', {}, { flipAmount: true }, 'no amount, flipped'),
    fields('flip/split-outflow', { outflow: '12.50' }, { splitMode: true, flipAmount: true }, 'split outflow flipped to an inflow'),
    fields('flip/split-inflow', { inflow: '12.50' }, { splitMode: true, flipAmount: true }, 'split inflow flipped to an outflow'),
    fields('flip/inout-out', { amount: '12.50', inOut: 'Debit' }, { inOutMode: true, outValue: 'Debit', flipAmount: true }, 'in/out then flip, flagged out'),
    fields('flip/inout-in', { amount: '12.50', inOut: 'Credit' }, { inOutMode: true, outValue: 'Debit', flipAmount: true }, 'in/out then flip, flagged in'),

    // Multiplier.
    fields('multiplier/integer', { amount: '12.50' }, { multiplierAmount: '2' }, 'integer multiplier'),
    fields('multiplier/fraction', { amount: '-12.50' }, { multiplierAmount: '0.5' }, 'fractional multiplier on an outflow'),
    fields('multiplier/zero', { amount: '12.50' }, { multiplierAmount: '0' }, 'zero is falsy: the multiplier is 1'),
    fields('multiplier/zero-point-zero', { amount: '12.50' }, { multiplierAmount: '0.0000' }, '0.0000 parses to zero: the multiplier is 1'),
    fields('multiplier/empty', { amount: '12.50' }, { multiplierAmount: '' }, 'an empty multiplier is 1'),
    fields('multiplier/not-a-number', { amount: '12.50' }, { multiplierAmount: 'abc' }, 'unreadable text is 1'),
    fields('multiplier/trailing-point', { amount: '12.50' }, { multiplierAmount: '3.' }, 'a trailing point is allowed by the input rule'),
    fields('multiplier/four-places', { amount: '12.50' }, { multiplierAmount: '1.2345' }, 'four decimal places'),
    fields('multiplier/float-product', { amount: '3' }, { multiplierAmount: '1.1' }, 'a binary float product: 3.3000000000000003'),
    fields('multiplier/float-product-negative', { amount: '-0.07' }, { multiplierAmount: '100' }, 'a binary float product on a negative amount'),
    fields('multiplier/leading-zeros', { amount: '12.50' }, { multiplierAmount: '007' }, 'leading zeros'),
    fields('multiplier/padded', { amount: '12.50' }, { multiplierAmount: ' 2' }, 'parseFloat skips leading whitespace'),
    fields('multiplier/negative-text', { amount: '12.50' }, { multiplierAmount: '-2' }, 'a negative multiplier flips the sign'),
    fields('multiplier/exponent-text', { amount: '12.50' }, { multiplierAmount: '2e2' }, 'parseFloat reads an exponent'),
    fields('multiplier/trailing-text', { amount: '12.50' }, { multiplierAmount: '2x' }, 'parseFloat reads a prefix'),
    fields('multiplier/huge', { amount: '12.50' }, { multiplierAmount: '9'.repeat(400) }, 'a 400-digit multiplier is infinite'),
    fields('multiplier/huge-zero-side', { amount: '12.50' }, { splitMode: true, multiplierAmount: '9'.repeat(400) },
      'infinity times the zero side is NaN in the split result'),
    fields('multiplier/split', { outflow: '10', inflow: '' }, { splitMode: true, multiplierAmount: '1.5' }, 'multiplier in split mode'),
    fields('multiplier/inout-flip', { amount: '-10', inOut: 'x' }, { inOutMode: true, outValue: 'x', flipAmount: true, multiplierAmount: '0.25' }, 'in/out, flip and multiplier together'),

    // Values the CSV flow can hand over only through a saved mapping that names `selected`.
    fields('values/amount-true', { amount: true }, {}, 'the boolean `selected` read as an amount'),
    fields('values/outflow-true', { outflow: true }, { splitMode: true }, 'a boolean outflow'),
    fields('values/inflow-true', { inflow: true }, { splitMode: true }, 'a boolean inflow'),
    fields('values/amount-true-inout', { amount: true, inOut: 'x' }, { inOutMode: true, outValue: 'x', multiplierAmount: '3' }, 'a boolean amount in in/out mode with a multiplier'),
  ];
}

const OUT_VALUES = ['', 'Debit', 'debit', ' Debit', 'OUT', 'out', 'DR'];
const IN_OUT_VALUES = ['Debit', 'Credit', 'debit', ' Debit ', 'OUT', 'IN', 'out', '', 'DR', 'CR'];
const MULTIPLIERS = ['', '', '', '2', '0.5', '1.25', '3.', '0', '0.0000', '12', '0.0001', '1', '10.5', '100', '007', '1.1', '2.5000', '0.3'];

function generatedMultiplier(random) {
  if (chance(random, 0.7)) return pick(random, MULTIPLIERS);
  const whole = String(between(random, 0, 200));
  return chance(random, 0.6) ? `${whole}.${String(between(random, 0, 9999)).padStart(between(random, 1, 4), '0')}` : whole;
}

function generatedCases() {
  const random = mulberry32(AMOUNT_FIELDS_SEED);
  return Array.from({ length: AMOUNT_FIELDS_GENERATED_COUNT }, (_, index) => {
    const splitMode = chance(random, 0.45);
    const inOutMode = chance(random, 0.4);
    const flipAmount = chance(random, 0.35);
    const outValue = pick(random, OUT_VALUES);
    const trans = {};
    if (chance(random, 0.8)) trans.amount = generatedAmount(random);
    if (chance(random, 0.6)) trans.outflow = chance(random, 0.15) ? '' : generatedAmount(random);
    if (chance(random, 0.6)) trans.inflow = chance(random, 0.15) ? '' : generatedAmount(random);
    if (chance(random, 0.8)) trans.inOut = chance(random, 0.45) ? outValue : pick(random, IN_OUT_VALUES);
    return {
      id: `parseAmountFields/mode-gen-${pad(index, 3)}`,
      source: 'generated',
      description: 'seeded row values under random split, in/out, flip and multiplier settings',
      seed: AMOUNT_FIELDS_SEED,
      input: { trans, splitMode, inOutMode, outValue, flipAmount, multiplierAmount: generatedMultiplier(random) },
    };
  });
}

// The Phase 1 seeded amounts under the default settings, unchanged (same ids, seed and draws).
function legacyGeneratedCases() {
  const random = mulberry32(20261109 + 100);
  return Array.from({ length: 60 }, (_, index) => ({
    id: `parseAmountFields/gen-${pad(index, 3)}`,
    source: 'generated',
    description: 'seeded amount text',
    seed: 20261109,
    input: fieldsInput({ amount: generatedAmount(random) }),
  }));
}

export function parseAmountFieldsCases() {
  return [...legacyCases(), ...legacyGeneratedCases(), ...modeCases(), ...generatedCases()];
}
