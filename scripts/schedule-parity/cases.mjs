// The schedule case plan: named and seeded cases in three families.
//
// Pure data. generate.mjs runs every case through Actual's own schedule code;
// verify.mjs rebuilds this plan without an oracle and compares it with the
// committed fixture. Amounts are integer minor units. Dates are ISO day strings.
//
// Families:
//   recurrence  getNextDate, getNextDateAfter, occurrence lists, upcoming dates
//   status      getStatus and getUpcomingDays
//   stateful    createSchedule, advanceSchedulesService, skipNextDate, setNextDate,
//               updateSchedule and post-transaction on a real in-memory budget

export const SEED = 20261011;
export const TIME_ZONE = 'America/New_York';
// Fixed clock for the stateful family unless a step names another. Local noon.
export const TODAY = '2026-10-11';
export const OCCURRENCE_COUNT = 6;
export const RECURRENCE_GENERATED_COUNT = 110;
export const STATE_GENERATED_COUNT = 24;

export function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let value = Math.imul(state ^ (state >>> 15), 1 | state);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

const pick = (rng, list) => list[Math.floor(rng() * list.length)];
const between = (rng, low, high) => low + Math.floor(rng() * (high - low + 1));

export function addDays(dayID, delta) {
  const [year, month, day] = dayID.split('-').map(Number);
  const date = new Date(Date.UTC(year, month - 1, day + delta));
  return date.toISOString().slice(0, 10);
}

function addMonthsClamped(dayID, delta) {
  const [year, month, day] = dayID.split('-').map(Number);
  const index = year * 12 + (month - 1) + delta;
  const targetYear = Math.floor(index / 12);
  const targetMonth = (index % 12) + 1;
  const last = new Date(Date.UTC(targetYear, targetMonth, 0)).getUTCDate();
  return `${targetYear}-${String(targetMonth).padStart(2, '0')}-${String(Math.min(day, last)).padStart(2, '0')}`;
}

const WEEKDAY_TYPES = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];

function config(frequency, start, extra = {}) {
  return { start, frequency, interval: 1, patterns: [], skipWeekend: false, weekendSolveMode: 'after', endMode: 'never', ...extra };
}

const dateCondition = (value, op = 'is') => ({ op, field: 'date', value });

// ---------------------------------------------------------------------------
// Family 1: recurrence

const START_POOL = [
  '2026-01-31', '2026-02-28', '2028-02-29', '2026-12-31', '2026-10-31', '2026-03-07',
  '2026-03-08', '2026-11-01', '2026-10-30', '2027-12-30', '2027-02-27', '2026-05-29',
];

// A weekend-skipping schedule gets one full week of consecutive from days, so every weekday (the Friday
// before a moved weekend in particular) is a from day for getNextDateAfter.
function defaultFroms(start, ending, skipWeekend = false) {
  const froms = [addDays(start, -5), start, addDays(start, 17), addDays(start, 61), addDays(start, 400)];
  if (skipWeekend) for (let offset = 18; offset <= 24; offset += 1) froms.push(addDays(start, offset));
  if (ending) froms.push(ending, addDays(ending, 12));
  return froms;
}

function recurrenceCase(id, description, value, froms, extra = {}) {
  const ending = value && typeof value === 'object' ? (value.endDate ?? null) : null;
  const start = value && typeof value === 'object' ? value.start : value;
  return {
    id,
    family: 'recurrence',
    source: extra.source ?? 'named',
    description,
    seed: extra.seed ?? null,
    oracleOnly: null,
    condition: dateCondition(value, extra.op),
    froms: froms ?? defaultFroms(start, ending, Boolean(value && typeof value === 'object' && value.skipWeekend)),
  };
}

function namedRecurrenceCases() {
  const plain = [
    ['plain-date-future', 'A single date later than the from dates', '2027-03-15', ['2026-10-11', '2027-03-15', '2027-03-16']],
    ['plain-date-past', 'A single date earlier than the from dates', '2020-02-29', ['2026-10-11']],
    ['plain-date-approx', 'isapprox with a plain date', '2026-10-20', ['2026-10-11', '2026-10-21'], 'isapprox'],
  ].map(([id, description, value, froms, op]) => recurrenceCase(id, description, value, froms, { op }));

  const recurring = [
    ['daily-interval-10', 'Daily every 10 days', config('daily', '2026-10-01', { interval: 10 })],
    ['weekly-interval-3', 'Weekly every 3 weeks', config('weekly', '2026-09-30', { interval: 3 })],
    ['weekly-skip-weekend-after', 'Weekly on a Saturday start, weekend moved after', config('weekly', '2026-10-10', { skipWeekend: true, weekendSolveMode: 'after' })],
    ['weekly-skip-weekend-before', 'Weekly on a Sunday start, weekend moved before', config('weekly', '2026-10-11', { skipWeekend: true, weekendSolveMode: 'before' })],
    ['monthly-no-patterns', 'Monthly with no patterns uses the start day', config('monthly', '2026-01-31')],
    ['monthly-last-day', 'Monthly on the last day', config('monthly', '2026-01-31', { patterns: [{ type: 'day', value: -1 }] })],
    ['monthly-day-31', 'Monthly on day 31 skips short months', config('monthly', '2026-01-31', { patterns: [{ type: 'day', value: 31 }] })],
    ['monthly-day-29-30', 'Monthly on days 29 and 30', config('monthly', '2026-01-29', { patterns: [{ type: 'day', value: 29 }, { type: 'day', value: 30 }] })],
    ['monthly-last-friday', 'Monthly on the last Friday', config('monthly', '2026-09-01', { patterns: [{ type: 'FR', value: -1 }] })],
    ['monthly-first-and-third-monday', 'Monthly on the first and third Monday', config('monthly', '2026-09-01', { patterns: [{ type: 'MO', value: 1 }, { type: 'MO', value: 3 }] })],
    ['monthly-day-and-weekday-mix', 'Monthly with a day pattern and a weekday pattern', config('monthly', '2026-09-01', { patterns: [{ type: 'day', value: 15 }, { type: 'WE', value: 2 }] })],
    ['monthly-interval-4-last-day-weekend-before', 'Every 4 months on the last day, weekend before', config('monthly', '2026-02-28', { interval: 4, patterns: [{ type: 'day', value: -1 }], skipWeekend: true, weekendSolveMode: 'before' })],
    ['monthly-after-3', 'Monthly ending after 3 occurrences', config('monthly', '2026-08-15', { endMode: 'after_n_occurrences', endOccurrences: 3 }), ['2026-07-01', '2026-08-15', '2026-09-16', '2026-11-20', '2027-06-01']],
    ['monthly-on-date-end', 'Monthly ending on a date', config('monthly', '2026-06-10', { endMode: 'on_date', endDate: '2026-09-10' }), ['2026-06-01', '2026-08-11', '2026-09-10', '2026-09-11', '2026-12-01']],
    ['monthly-two-patterns-after-5', 'Two day patterns ending after 5 occurrences', config('monthly', '2026-08-01', { patterns: [{ type: 'day', value: 5 }, { type: 'day', value: 20 }], endMode: 'after_n_occurrences', endOccurrences: 5 }), ['2026-08-01', '2026-09-21', '2026-10-06', '2026-10-21', '2027-01-01']],
    ['yearly-leap-day', 'Yearly from Feb 29 2028', config('yearly', '2028-02-29'), ['2028-02-28', '2028-03-01', '2029-02-28', '2032-02-29']],
    ['yearly-interval-4-leap', 'Every 4 years from Feb 29', config('yearly', '2024-02-29', { interval: 4 }), ['2026-01-01', '2028-02-29', '2028-03-01']],
    ['yearly-year-end-skip-weekend', 'Yearly on Dec 31, weekend after', config('yearly', '2022-12-31', { skipWeekend: true, weekendSolveMode: 'after' }), ['2026-12-30', '2026-12-31', '2027-01-01']],
    ['weekly-dst-spring', 'Weekly across the spring DST change', config('weekly', '2026-03-01'), ['2026-03-07', '2026-03-08', '2026-03-09']],
    ['daily-dst-fall', 'Daily across the fall DST change', config('daily', '2026-10-29'), ['2026-10-31', '2026-11-01', '2026-11-02']],
    ['monthly-dst-day-8', 'Monthly on day 8 at the spring DST change', config('monthly', '2026-01-08', { patterns: [{ type: 'day', value: 8 }] }), ['2026-03-07', '2026-03-08', '2026-03-09']],
    ['monthly-dst-first-sunday', 'Monthly first Sunday at the fall DST change', config('monthly', '2026-09-01', { patterns: [{ type: 'SU', value: 1 }] }), ['2026-10-31', '2026-11-01', '2026-11-02']],
    ['weekend-solve-crosses-month', 'Last day of month on a weekend, moved after into the next month', config('monthly', '2026-01-31', { patterns: [{ type: 'day', value: -1 }], skipWeekend: true, weekendSolveMode: 'after' }), ['2026-05-31', '2026-06-01', '2026-08-31', '2026-10-31']],
  ].map(([id, description, value, froms]) => recurrenceCase(id, description, value, froms));
  return [...plain, ...recurring];
}

function generatedRecurrence(seed, index) {
  const rng = mulberry32(seed);
  const frequency = pick(rng, ['daily', 'weekly', 'weekly', 'monthly', 'monthly', 'monthly', 'yearly']);
  const start = rng() < 0.5 ? pick(rng, START_POOL) : addDays('2026-01-01', between(rng, 0, 1100));
  const interval = pick(rng, [1, 1, 1, 2, 2, 3, 4, 6, 12]);
  const patterns = [];
  if (frequency === 'monthly' && rng() < 0.8) {
    const count = rng() < 0.7 ? 1 : between(rng, 2, 3);
    for (let i = 0; i < count; i += 1) {
      const kind = rng() < 0.55 ? 'day' : 'weekday';
      if (kind === 'day') {
        patterns.push({ type: 'day', value: pick(rng, [1, 5, 10, 15, 28, 29, 30, 31, -1, between(rng, 1, 31)]) });
      } else {
        patterns.push({ type: pick(rng, WEEKDAY_TYPES), value: pick(rng, [1, 2, 3, 4, -1]) });
      }
    }
  }
  const skipWeekend = rng() < 0.5;
  const endRoll = rng();
  const extra = { interval, patterns, skipWeekend, weekendSolveMode: pick(rng, ['before', 'after']) };
  let ending = null;
  if (endRoll < 0.25) {
    extra.endMode = 'after_n_occurrences';
    extra.endOccurrences = between(rng, 1, 12);
  } else if (endRoll < 0.5) {
    extra.endMode = 'on_date';
    extra.endDate = addMonthsClamped(start, between(rng, 1, 18));
    ending = extra.endDate;
  }
  const value = config(frequency, start, extra);
  const label = `${frequency}-${interval}${patterns.length ? '-p' + patterns.length : ''}${skipWeekend ? '-' + extra.weekendSolveMode : ''}${extra.endMode && extra.endMode !== 'never' ? '-' + extra.endMode : ''}`;
  return recurrenceCase(
    `gen-recur-${String(index).padStart(3, '0')}-${label}`,
    `Seeded ${frequency} recurrence`,
    value,
    defaultFroms(start, ending, skipWeekend),
    { source: 'generated', seed },
  );
}

// ---------------------------------------------------------------------------
// Family 2: status

const STATUS_TODAYS = ['2026-10-11', '2026-12-31', '2028-02-29', '2026-03-08'];
const UPCOMING_LENGTHS = ['7', '1', '14', 'oneMonth', 'currentMonth', '2-week', '3-day', '1-month', '12-month', '1-year', '0-day', '5-week'];

function statusCases() {
  const cases = [];
  const dense = [];
  for (let offset = -3; offset <= 35; offset += 1) dense.push(offset);
  const sparse = [-400, -100, -30, 60, 100, 200, 400];
  const flagged = [-30, -1, 0, 1, 7, 8, 60];
  for (const today of STATUS_TODAYS) {
    for (const upcomingLength of UPCOMING_LENGTHS) {
      const rows = [];
      for (const offset of [...sparse.filter(value => value < 0), ...dense, ...sparse.filter(value => value > 0)]) {
        rows.push({ nextDate: addDays(today, offset), completed: false, hasTrans: false });
      }
      for (const offset of flagged) {
        rows.push({ nextDate: addDays(today, offset), completed: false, hasTrans: true });
        rows.push({ nextDate: addDays(today, offset), completed: true, hasTrans: false });
        rows.push({ nextDate: addDays(today, offset), completed: true, hasTrans: true });
      }
      cases.push({
        id: `status-${today}-${upcomingLength}`,
        family: 'status',
        source: 'named',
        description: `getStatus on ${today} with upcoming length ${upcomingLength}`,
        seed: null,
        oracleOnly: null,
        today,
        upcomingLength,
        rows,
      });
    }
  }
  // getStatus called without an upcoming length uses the default of 7 days.
  cases.push({
    id: 'status-default-length',
    family: 'status',
    source: 'named',
    description: 'getStatus with the default upcoming length',
    seed: null,
    oracleOnly: null,
    today: '2026-10-11',
    upcomingLength: null,
    rows: [-1, 0, 1, 7, 8].map(offset => ({ nextDate: addDays('2026-10-11', offset), completed: false, hasTrans: false })),
  });
  return cases;
}

// ---------------------------------------------------------------------------
// Family 3: stateful

const CHECKING = { key: 'checking', name: 'Synthetic Checking', closed: false, offbudget: false };
const CLOSED = { key: 'closed', name: 'Synthetic Closed', closed: true, offbudget: false };
const PAYEE = { key: 'landlord', name: 'Synthetic Landlord' };

function schedule(key, createdOn, date, extra = {}) {
  return {
    key,
    name: extra.name ?? `Schedule ${key}`,
    createdOn,
    postsTransaction: extra.postsTransaction ?? false,
    customUpcomingLength: extra.customUpcomingLength ?? null,
    completed: extra.completed ?? false,
    accountKey: extra.accountKey ?? 'checking',
    payeeKey: extra.payeeKey === undefined ? 'landlord' : extra.payeeKey,
    amount: extra.amount ?? -10000,
    amountOp: extra.amountOp ?? 'is',
    date,
    dateOp: extra.dateOp ?? 'is',
  };
}

// A step production cannot run. Its case stays in the fixture and is replayed up to nothing:
// the whole case becomes oracle-only with this reason.
export function stepOracleOnlyReason(step) {
  if (step.op === 'advance' && step.syncSuccess === false) {
    return 'advanceSchedules has no sync-failure mode; Actual only records failed posts when sync did not succeed.';
  }
  if (step.op === 'setNextDate' && Boolean(step.advance) === Boolean(step.reset)) {
    return 'setNextDate without exactly one of advance or reset has no production entry point; skipNextDate (advance) and resetNextDate (reset) are its two callers.';
  }
  return null;
}

function stateCase(id, description, setup, steps, extra = {}) {
  const stepReason = steps.map(stepOracleOnlyReason).find(Boolean) ?? null;
  return {
    id,
    family: 'stateful',
    source: extra.source ?? 'named',
    description,
    seed: extra.seed ?? null,
    oracleOnly: extra.oracleOnly ?? stepReason,
    setup: {
      accounts: setup.accounts ?? [CHECKING],
      payees: setup.payees ?? [PAYEE],
      upcomingLength: setup.upcomingLength ?? null,
      schedules: setup.schedules,
      transactions: setup.transactions ?? [],
    },
    steps: steps.map(step => ({ today: TODAY, ...step })),
  };
}

const advance = (extra = {}) => ({ op: 'advance', syncSuccess: true, ...extra });

function namedStateCases() {
  const weekly2 = config('weekly', '2026-09-14', { interval: 2 });
  const monthly11 = config('monthly', '2026-08-11', { patterns: [{ type: 'day', value: 11 }] });
  return [
    stateCase('advance-posts-missed-weekly', 'Auto-post catches up every missed biweekly occurrence', {
      schedules: [schedule('s1', '2026-09-01', weekly2, { postsTransaction: true })],
    }, [advance()]),
    stateCase('advance-no-post-missed', 'A missed schedule that does not post is left alone', {
      schedules: [schedule('s1', '2026-09-01', weekly2, { postsTransaction: false })],
    }, [advance()]),
    stateCase('advance-due-today-posts-once', 'A schedule due today posts once and does not advance', {
      schedules: [schedule('s1', '2026-08-20', monthly11, { postsTransaction: true })],
    }, [advance(), advance()]),
    stateCase('advance-sync-failed', 'Auto-post does nothing when sync did not succeed', {
      schedules: [schedule('s1', '2026-09-01', weekly2, { postsTransaction: true })],
    }, [advance({ syncSuccess: false })]),
    stateCase('advance-paid-recurring-no-post', 'A paid manual recurring schedule moves to its next date', {
      schedules: [schedule('s1', '2026-09-01', weekly2, { postsTransaction: false })],
    }, [{ op: 'payNextDate', schedule: 's1', offsetDays: 0 }, advance()]),
    stateCase('advance-paid-then-catches-up', 'Auto-post continues past an already paid occurrence', {
      schedules: [schedule('s1', '2026-09-01', weekly2, { postsTransaction: true })],
    }, [{ op: 'payNextDate', schedule: 's1', offsetDays: 0 }, advance()]),
    stateCase('advance-one-time-paid-completes', 'A paid past one-time schedule completes', {
      schedules: [schedule('s1', '2026-09-01', '2026-09-20', { postsTransaction: false })],
    }, [{ op: 'payNextDate', schedule: 's1', offsetDays: 0 }, advance()]),
    stateCase('advance-one-time-paid-posts-on', 'A paid past one-time auto-post schedule completes', {
      schedules: [schedule('s1', '2026-09-01', '2026-09-20', { postsTransaction: true })],
    }, [{ op: 'payNextDate', schedule: 's1', offsetDays: 0 }, advance()]),
    stateCase('advance-one-time-due-posts', 'A one-time schedule due today posts', {
      schedules: [schedule('s1', '2026-10-01', '2026-10-11', { postsTransaction: true })],
    }, [advance()]),
    stateCase('advance-one-time-missed-posts', 'A missed one-time auto-post schedule posts once', {
      schedules: [schedule('s1', '2026-09-01', '2026-09-20', { postsTransaction: true })],
    }, [advance(), advance()]),
    stateCase('advance-ended-on-date', 'An ended recurring schedule keeps its last occurrence', {
      schedules: [schedule('s1', '2026-08-01', config('monthly', '2026-05-10', { endMode: 'on_date', endDate: '2026-07-10' }), { postsTransaction: true })],
    }, [advance(), advance()]),
    stateCase('advance-ended-paid-stays', 'A paid ended recurring schedule does not complete', {
      schedules: [schedule('s1', '2026-08-01', config('monthly', '2026-05-10', { endMode: 'on_date', endDate: '2026-07-10' }), { postsTransaction: false })],
    }, [{ op: 'payNextDate', schedule: 's1', offsetDays: 0 }, advance(), advance()]),
    stateCase('advance-after-n-reached', 'An after-3 schedule posts its three occurrences and stops', {
      schedules: [schedule('s1', '2026-08-20', config('weekly', '2026-08-24', { endMode: 'after_n_occurrences', endOccurrences: 3 }), { postsTransaction: true })],
    }, [advance(), advance()]),
    stateCase('advance-after-n-unposted', 'An after-3 schedule that does not post stays missed on its last occurrence', {
      schedules: [schedule('s1', '2026-08-20', config('weekly', '2026-08-24', { endMode: 'after_n_occurrences', endOccurrences: 3 }), { postsTransaction: false })],
    }, [advance(), { op: 'skip', schedule: 's1' }]),
    stateCase('advance-completed-untouched', 'A completed schedule is ignored', {
      schedules: [schedule('s1', '2026-09-01', weekly2, { postsTransaction: true, completed: true })],
    }, [advance()]),
    stateCase('advance-closed-account-skipped', 'A schedule on a closed account is ignored', {
      accounts: [CHECKING, CLOSED],
      schedules: [schedule('s1', '2026-09-01', weekly2, { postsTransaction: true, accountKey: 'closed' })],
    }, [advance()]),
    stateCase('advance-two-schedules', 'Two schedules on the same day post in turn', {
      schedules: [
        schedule('s1', '2026-10-01', '2026-10-11', { postsTransaction: true, amount: -5000 }),
        schedule('s2', '2026-10-01', monthly11, { postsTransaction: true, amount: -7000 }),
      ],
    }, [advance()]),
    stateCase('advance-approx-amount', 'An approximate amount posts the rounded average', {
      schedules: [schedule('s1', '2026-10-01', '2026-10-11', { postsTransaction: true, amount: { num1: -10001, num2: -20000 }, amountOp: 'isbetween' })],
    }, [advance()]),
    stateCase('advance-approx-amount-ordered', 'A between-amount stored low to high posts the rounded average', {
      schedules: [schedule('s1', '2026-10-01', '2026-10-11', { postsTransaction: true, amount: { num1: -20000, num2: -10001 }, amountOp: 'isbetween' })],
    }, [advance()]),
    stateCase('advance-no-payee', 'A schedule without a payee posts', {
      schedules: [schedule('s1', '2026-10-01', '2026-10-11', { postsTransaction: true, payeeKey: null })],
    }, [advance()]),
    stateCase('advance-dst-spring-weekly', 'Weekly auto-post across the spring DST change', {
      schedules: [schedule('s1', '2026-03-01', config('weekly', '2026-03-01'), { postsTransaction: true })],
    }, [{ ...advance(), today: '2026-03-09' }]),
    stateCase('advance-dst-fall-daily', 'Daily auto-post across the fall DST change', {
      schedules: [schedule('s1', '2026-10-28', config('daily', '2026-10-28'), { postsTransaction: true })],
    }, [{ ...advance(), today: '2026-11-02' }]),
    stateCase('advance-weekend-before-catchup', 'Auto-post with weekend moved before catches up', {
      schedules: [schedule('s1', '2026-08-30', config('monthly', '2026-08-31', { patterns: [{ type: 'day', value: -1 }], skipWeekend: true, weekendSolveMode: 'before' }), { postsTransaction: true })],
    }, [{ ...advance(), today: '2026-11-03' }]),
    stateCase('advance-early-payment-lookback', 'An approximate-date manual schedule paid one day early counts as paid', {
      schedules: [schedule('s1', '2026-09-01', monthly11, { postsTransaction: false, dateOp: 'isapprox' })],
    }, [{ op: 'payNextDate', schedule: 's1', offsetDays: -1 }, advance()]),
    stateCase('advance-exact-date-early-not-paid', 'An exact-date manual schedule is not paid by a transaction on the day before', {
      schedules: [schedule('s1', '2026-09-01', monthly11, { postsTransaction: false })],
    }, [{ op: 'payNextDate', schedule: 's1', offsetDays: -1 }, advance()]),
    stateCase('advance-post-yesterday-not-paid', 'An auto-post schedule is not paid by a transaction on the day before', {
      schedules: [schedule('s1', '2026-09-01', monthly11, { postsTransaction: true })],
    }, [{ op: 'payNextDate', schedule: 's1', offsetDays: -1 }, advance()]),
    stateCase('advance-custom-upcoming', 'A custom upcoming length changes the status and preview', {
      upcomingLength: '14',
      schedules: [
        schedule('s1', '2026-10-01', config('weekly', '2026-10-15'), { customUpcomingLength: '1-month' }),
        schedule('s2', '2026-10-01', config('weekly', '2026-10-15'), { customUpcomingLength: '1' }),
      ],
    }, [advance()]),
    stateCase('skip-weekly', 'Skip a weekly schedule', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-13'))],
    }, [{ op: 'skip', schedule: 's1' }, { op: 'skip', schedule: 's1' }]),
    stateCase('skip-monthly-last-day', 'Skip a last-day-of-month schedule', {
      schedules: [schedule('s1', '2026-01-01', config('monthly', '2026-01-31', { patterns: [{ type: 'day', value: -1 }] }))],
    }, [{ op: 'skip', schedule: 's1' }, { op: 'skip', schedule: 's1' }]),
    stateCase('skip-weekend-after', 'Skip with the weekend moved after', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-10', { skipWeekend: true, weekendSolveMode: 'after' }))],
    }, [{ op: 'skip', schedule: 's1' }, { op: 'skip', schedule: 's1' }]),
    stateCase('skip-weekend-before', 'Skip with the weekend moved before', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-10', { skipWeekend: true, weekendSolveMode: 'before' }))],
    }, [{ op: 'skip', schedule: 's1' }, { op: 'skip', schedule: 's1' }, { op: 'skip', schedule: 's1' }]),
    stateCase('skip-ended', 'Skipping an ended schedule changes nothing', {
      schedules: [schedule('s1', '2026-08-01', config('monthly', '2026-05-10', { endMode: 'on_date', endDate: '2026-07-10' }))],
    }, [{ op: 'skip', schedule: 's1' }]),
    stateCase('skip-after-n-last', 'Skipping the last occurrence of an after-n schedule', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-13', { endMode: 'after_n_occurrences', endOccurrences: 2 }))],
    }, [{ op: 'skip', schedule: 's1' }, { op: 'skip', schedule: 's1' }, { op: 'skip', schedule: 's1' }]),
    stateCase('skip-one-time', 'Skipping a one-time schedule changes nothing', {
      schedules: [schedule('s1', '2026-10-01', '2026-10-20')],
    }, [{ op: 'skip', schedule: 's1' }]),
    stateCase('set-next-date-after-edit', 'Editing the date condition resets the next date', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-13'))],
    }, [{ op: 'update', schedule: 's1', date: config('monthly', '2026-10-25', { patterns: [{ type: 'day', value: 25 }] }) }]),
    stateCase('set-next-date-edit-one-time', 'Editing a one-time date moves the next date', {
      schedules: [schedule('s1', '2026-10-01', '2026-10-20')],
    }, [{ op: 'update', schedule: 's1', date: '2026-11-05' }]),
    stateCase('set-next-date-reset-flag', 'resetNextDate recomputes from today', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-13'))],
    }, [{ op: 'skip', schedule: 's1' }, { op: 'update', schedule: 's1', resetNextDate: true }]),
    stateCase('set-next-date-amount-edit-no-reset', 'Editing only the amount keeps a skipped next date', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-13'))],
    }, [{ op: 'skip', schedule: 's1' }, { op: 'update', schedule: 's1', amount: -2500 }]),
    stateCase('set-next-date-direct-advance', 'setNextDate with advance moves to the next occurrence', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-13'))],
    }, [{ op: 'setNextDate', schedule: 's1', advance: true }, { op: 'setNextDate', schedule: 's1', advance: true }]),
    stateCase('set-next-date-plain', 'setNextDate without advance or reset recomputes the local next date from today', {
      schedules: [schedule('s1', '2026-09-01', config('weekly', '2026-09-14'))],
    }, [{ op: 'setNextDate', schedule: 's1' }]),
    stateCase('set-next-date-direct-reset', 'setNextDate with reset writes the base next date', {
      schedules: [schedule('s1', '2026-09-01', config('weekly', '2026-09-14'))],
    }, [{ op: 'setNextDate', schedule: 's1', reset: true }]),
    stateCase('post-transaction-next-date', 'Manual post uses the next date', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-13'))],
    }, [{ op: 'post', schedule: 's1', todayDate: false }]),
    stateCase('post-transaction-today', 'Manual post can use today', {
      schedules: [schedule('s1', '2026-10-01', config('weekly', '2026-10-13'))],
    }, [{ op: 'post', schedule: 's1', todayDate: true }, advance()]),
    stateCase('create-negative-offset-timezone', 'A schedule created at local noon in a zone behind UTC', {
      schedules: [schedule('s1', '2026-10-11', config('daily', '2026-10-01', { interval: 3 })), schedule('s2', '2026-10-11', config('weekly', '2026-10-11'))],
    }, [advance()]),
  ];
}

function generatedStateCase(seed, index) {
  const rng = mulberry32(seed);
  const count = between(rng, 1, 3);
  const schedules = [];
  // Skipping only targets recurring schedules; a one-time skip is the named case skip-one-time.
  const recurringKeys = [];
  for (let i = 0; i < count; i += 1) {
    const frequency = pick(rng, ['daily', 'weekly', 'weekly', 'monthly', 'monthly']);
    const createdOn = addDays(TODAY, -between(rng, 10, 100));
    const start = addDays(createdOn, between(rng, -3, 20));
    const extra = { interval: pick(rng, [1, 1, 2, 3]) };
    if (frequency === 'monthly' && rng() < 0.6) {
      extra.patterns = [{ type: 'day', value: pick(rng, [1, 10, 15, 29, 30, 31, -1]) }];
    }
    if (rng() < 0.5) {
      extra.skipWeekend = true;
      extra.weekendSolveMode = pick(rng, ['before', 'after']);
    }
    const endRoll = rng();
    if (endRoll < 0.2) {
      extra.endMode = 'after_n_occurrences';
      extra.endOccurrences = between(rng, 1, 5);
    } else if (endRoll < 0.35) {
      extra.endMode = 'on_date';
      extra.endDate = addDays(start, between(rng, 20, 90));
    }
    const date = rng() < 0.12 ? addDays(start, between(rng, 0, 60)) : config(frequency, start, extra);
    if (typeof date === 'object') recurringKeys.push(`s${i + 1}`);
    schedules.push(schedule(`s${i + 1}`, createdOn, date, {
      postsTransaction: rng() < 0.5,
      amount: -between(rng, 5, 200) * 100,
      customUpcomingLength: rng() < 0.15 ? pick(rng, ['1', '14', '2-week', 'oneMonth']) : null,
    }));
  }
  const steps = [];
  const stepCount = between(rng, 2, 4);
  let today = TODAY;
  for (let i = 0; i < stepCount; i += 1) {
    const target = `s${between(rng, 1, count)}`;
    const roll = rng();
    const recurringTarget = recurringKeys.length > 0 ? pick(rng, recurringKeys) : null;
    if (roll < 0.4 || (roll >= 0.8 && recurringTarget === null) || (roll >= 0.4 && roll < 0.6 && recurringTarget === null)) {
      steps.push({ today, ...advance() });
    } else if (roll < 0.6) {
      steps.push({ today, op: 'skip', schedule: recurringTarget });
    } else if (roll < 0.8) {
      steps.push({ today, op: 'payNextDate', schedule: target, offsetDays: pick(rng, [0, 0, -1, -2, 1]) });
    } else {
      const reset = rng() < 0.5;
      steps.push({ today, op: 'setNextDate', schedule: recurringTarget, advance: !reset, reset });
    }
    if (rng() < 0.4) today = addDays(today, between(rng, 1, 20));
  }
  return stateCase(
    `gen-state-${String(index).padStart(3, '0')}`,
    `Seeded stateful scenario with ${count} schedule(s)`,
    { schedules },
    steps,
    { source: 'generated', seed },
  );
}

// ---------------------------------------------------------------------------

export function buildPlan() {
  const master = mulberry32(SEED);
  const recurrence = [...namedRecurrenceCases()];
  for (let i = 0; i < RECURRENCE_GENERATED_COUNT; i += 1) {
    recurrence.push(generatedRecurrence(Math.floor(master() * 2 ** 31), i));
  }
  const stateful = [...namedStateCases()];
  for (let i = 0; i < STATE_GENERATED_COUNT; i += 1) {
    stateful.push(generatedStateCase(Math.floor(master() * 2 ** 31), i));
  }
  return {
    seed: SEED,
    timeZone: TIME_ZONE,
    today: TODAY,
    occurrenceCount: OCCURRENCE_COUNT,
    cases: [...recurrence, ...statusCases(), ...stateful],
  };
}

// Recorded fields with no production seam today. The replay compares the rest of the
// record and skips these; each one becomes a replay target once a seam exists.
export const ORACLE_ONLY_FIELDS = [
  {
    field: 'recurrence.queries[].occurrences.raw / adjusted',
    reason: 'Production exposes nextOccurrence(onOrAfter:) only; there is no occurrence-list API. A replay can chain nextOccurrence, but that loop would live in the test.',
  },
  {
    field: 'recurrence.queries[].upcoming',
    reason: 'schedule/get-upcoming-dates (editor preview of upcoming dates from today) has no production counterpart.',
  },
  {
    field: 'stateful steps[].after.preview',
    reason: 'computeSchedulePreviewTransactions (forecast rows in the account register) has no production counterpart.',
  },
];

// Cases the production path cannot replay without a new seam, with the reason.
export function oracleOnlyEntries(plan) {
  return plan.cases
    .filter(planCase => planCase.oracleOnly)
    .map(planCase => ({ id: planCase.id, reason: planCase.oracleOnly }));
}

// Sanity checks on recorded values that the plan itself can state without
// writing expected values by hand. A failure here means the harness is broken.
export function expectationFailures(record, planCase) {
  const failures = [];
  if (planCase.family === 'recurrence') {
    if (record.queries.length !== planCase.froms.length) failures.push('query count differs from froms');
    record.queries.forEach(query => {
      if (query.occurrences.raw.length > OCCURRENCE_COUNT) {
        failures.push(`${query.from}: too many occurrences`);
      }
    });
  } else if (planCase.family === 'status') {
    if (record.rows.length !== planCase.rows.length) failures.push('row count differs');
    for (const row of record.rows) {
      if (!['completed', 'paid', 'due', 'upcoming', 'missed', 'scheduled'].includes(row.status)) {
        failures.push(`unknown status ${row.status}`);
      }
    }
  } else if (planCase.family === 'stateful') {
    if (record.steps.length !== planCase.steps.length) failures.push('step count differs');
    if (record.before == null) failures.push('missing before snapshot');
  }
  return failures;
}
