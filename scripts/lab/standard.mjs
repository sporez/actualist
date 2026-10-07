// "standard" profile: an in-depth, deterministic household budget (envelope)
// meant to exercise every Actualist surface. Same seed + same anchor month =
// identical data (ids aside).
import * as api from '@harness/api';
import { addBatch, refDate, rng } from './profiles.mjs';

const pad = n => String(n).padStart(2, '0');
const ymd = (y, m, d) => `${y}-${pad(m)}-${pad(d)}`;

// [group, hidden?, [category, monthly budget (cents), opts]]
const GROUPS = [
  ['Housing', false, [['Mortgage', 215000], ['Utilities', 21000], ['Internet', 7000], ['Home Maintenance', 15000], ['Home Insurance', 14000], ['Lawn & Garden', 6000]]],
  ['Everyday', false, [['Groceries', 78000], ['Household Supplies', 12000], ['Dining Out', 25000], ['Coffee', 6000], ['Personal Care', 8000], ['Pharmacy', 5000], ['Pet Care', 9000]]],
  ['Transport', false, [['Fuel', 24000], ['Car Insurance', 16000], ['Car Maintenance', 10000], ['Parking & Tolls', 4000], ['Auto Loan Payment', 38000]]],
  ['Kids', false, [['Childcare', 80000], ['School & Activities', 12000], ['Kids Clothing', 7000], ['Allowance', 4000]]],
  ['Subscriptions', false, [['Streaming', 4500], ['Software', 3000], ['Phone', 11000], ['Gym', 5500]]],
  ['Giving', false, [['Charity', 10000], ['Gifts', 8000]]],
  ['Savings Goals', false, [['Emergency Fund', 20000], ['Vacation', 20000], ['New Roof', 15000], ['Holiday', 10000], ['Retirement Contributions', 40000]]],
  ['Irregular', false, [['Medical', 12000], ['Annual Fees', 4000], ['Taxes & Licenses', 6000], ['Clothing', 12000], ['Electronics', 10000], ['Storage Unit', 0, { hidden: true }]]],
  ['Archived', true, [['Old Hobby', 0]]],
];

// Variable spending: n = expected transactions a month, accts weights.
const VAR = {
  Groceries: { n: 7, min: 2800, max: 14500, payees: ['Greenleaf Market', 'Corner Grocer', 'Fresh Basket', 'Harvest Foods'], accts: ['visa', 'visa', 'joint', 'store'] },
  'Household Supplies': { n: 2, min: 1500, max: 6500, payees: ['Home Depot', 'Dollar Barn'], accts: ['visa', 'joint'] },
  'Dining Out': { n: 6, min: 1400, max: 8500, payees: ['Luna Cafe', 'Pizza Palace', 'Sunrise Diner', 'Noodle House', 'Taqueria Rio'], accts: ['visa', 'visa', 'cash', 'personal'] },
  Coffee: { n: 7, min: 450, max: 900, payees: ['Starbucks', 'Bean There'], accts: ['visa', 'cash', 'personal'], raw: { Starbucks: 'STARBUCKS #' } },
  'Personal Care': { n: 1, min: 1800, max: 7500, payees: ['Clip Joint Salon', 'Glow Spa'], accts: ['visa', 'personal'] },
  Pharmacy: { n: 1, min: 800, max: 4500, payees: ['CVS Pharmacy'], accts: ['visa', 'joint'] },
  'Pet Care': { n: 1.5, min: 2500, max: 9500, payees: ['Paws & Claws Vet', 'Pet Supply Co'], accts: ['visa'] },
  Fuel: { n: 4, min: 3200, max: 6800, payees: ['Shell', 'Chevron'], accts: ['visa', 'joint'], raw: { Shell: 'SHELL OIL ' } },
  'Car Maintenance': { n: 0.4, min: 6000, max: 45000, payees: ['QuickLube', 'Main St Auto'], accts: ['visa', 'joint'] },
  'Parking & Tolls': { n: 2, min: 400, max: 1800, payees: ['City Parking', 'Metro Toll'], accts: ['visa', 'cash'] },
  'School & Activities': { n: 1.5, min: 1500, max: 9500, payees: ['Lincoln Elementary', 'Youth Soccer League'], accts: ['joint', 'visa'] },
  'Kids Clothing': { n: 0.7, min: 2500, max: 9000, payees: ['Little Threads', 'Amazon'], accts: ['store', 'visa'], raw: { Amazon: 'AMZN MKTP US*' } },
  Allowance: { n: 2, min: 1000, max: 1000, payees: ['Cash to kids'], accts: ['cash'] },
  Charity: { n: 1, min: 2500, max: 7500, payees: ['Food Bank', 'Public Radio'], accts: ['joint'] },
  Gifts: { n: 0.8, min: 2000, max: 9000, payees: ['Gift Shoppe', 'Amazon'], accts: ['visa', 'store', 'personal'], raw: { Amazon: 'AMZN MKTP US*' } },
  Medical: { n: 0.6, min: 3000, max: 28000, payees: ['Valley Clinic', 'Smile Dental'], accts: ['joint', 'visa'] },
  Clothing: { n: 0.9, min: 3000, max: 14000, payees: ['Oak & Ash Goods', 'Threadbare'], accts: ['store', 'visa'] },
  Electronics: { n: 0.35, min: 4000, max: 80000, payees: ['Pixel Electronics', 'Amazon'], accts: ['visa'], raw: { Amazon: 'AMZN MKTP US*' } },
  'Home Maintenance': { n: 0.5, min: 4000, max: 40000, payees: ['Ace Hardware', 'Reliable Plumbing'], accts: ['joint', 'visa'] },
  'Lawn & Garden': { n: 1, min: 1500, max: 7000, payees: ['Green Thumb Nursery'], accts: ['visa'] },
};

// Fixed bills: [category, day, amount, payee, account, note?]
const FIXED = [
  ['Mortgage', 3, 215000, 'Springfield Mortgage', 'joint'],
  ['Utilities', 9, 0, 'City Power & Light', 'joint', 'range:14000:26000'],
  ['Utilities', 14, 0, 'Riverside Water', 'joint', 'range:3500:6500'],
  ['Internet', 11, 7000, 'FiberNet', 'joint'],
  ['Home Insurance', 18, 14000, 'Harbor Insurance', 'joint'],
  ['Car Insurance', 6, 16000, 'Drive Safe Insurance', 'joint'],
  ['Childcare', 4, 80000, 'Little Sprouts Daycare', 'joint'],
  ['Streaming', 12, 1599, 'StreamBox', 'visa'],
  ['Streaming', 21, 1199, 'Tunes Plus', 'visa'],
  ['Software', 7, 999, 'Cloud Notes', 'visa'],
  ['Phone', 10, 11000, 'Northwind Mobile', 'visa'],
  ['Gym', 2, 5500, 'Iron Works Gym', 'visa'],
];

// Payee rename rules on imported-style payee text: [imported contains, payee, category?]
const RULES = [
  ['STARBUCKS #', 'Starbucks', 'Coffee'],
  ['SHELL OIL ', 'Shell', 'Fuel'],
  ['AMZN MKTP US*', 'Amazon', null],
  ['SPRINGFIELD MTG', 'Springfield Mortgage', 'Mortgage'],
];

const NOTES = ['Birthday', 'Reimbursable', 'Split with partner', 'Check receipt', 'Monthly top-up', 'Back to school', 'Spring cleaning', 'Weekend trip'];

export async function buildStandard({ months }) {
  const rand = rng(20261001);
  const pick = a => a[Math.floor(rand() * a.length)];
  const between = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
  const now = refDate();
  const log = m => process.stdout.write(`LAB| ${m}\n`);

  // Month list (oldest first); the anchor month is partial when it is the current one.
  const mr = [];
  for (let i = months - 1; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const y = d.getFullYear(), m = d.getMonth() + 1;
    const last = new Date(y, m, 0).getDate();
    mr.push({ y, m, key: `${y}-${pad(m)}`, days: i === 0 ? Math.min(now.getDate(), last) : Math.min(last, 28), idx: months - 1 - i });
  }
  const clearedCutoff = new Date(now); clearedCutoff.setDate(clearedCutoff.getDate() - 4);
  const reconciledCutoff = new Date(now.getFullYear(), now.getMonth() - 3, 1);

  // ---- categories ----
  const cat = {};
  const hiddenGroupIds = [];
  for (const [group, hidden, cats] of GROUPS) {
    const gid = await api.createCategoryGroup({ name: group, hidden });
    if (hidden) hiddenGroupIds.push(gid);
    for (const [name, , opts] of cats) cat[name] = await api.createCategory({ name, group_id: gid, hidden: !!opts?.hidden });
  }
  const groups = await api.getCategoryGroups();
  const incomeGroup = groups.find(g => g.is_income);
  const incomeExisting = new Map((incomeGroup.categories ?? []).map(c => [c.name, c.id]));
  for (const name of ['Paycheck', 'Side Income', 'Interest']) {
    cat[name] = incomeExisting.get(name) ?? (await api.createCategory({ name, group_id: incomeGroup.id, is_income: true }));
  }

  // ---- accounts ----
  const acct = {};
  acct.joint = await api.createAccount({ name: 'Joint Checking' }, 650000);
  acct.personal = await api.createAccount({ name: 'Personal Checking' }, 120000);
  acct.savings = await api.createAccount({ name: 'Emergency Savings' }, 1800000);
  acct.hys = await api.createAccount({ name: 'High-Yield Savings' }, 900000);
  acct.visa = await api.createAccount({ name: 'Visa Rewards' }, -62000);
  acct.store = await api.createAccount({ name: 'Store Card' }, -18000);
  acct.cash = await api.createAccount({ name: 'Cash' }, 25000);
  acct.invest = await api.createAccount({ name: 'Brokerage', offbudget: true }, 4200000);
  acct.loan = await api.createAccount({ name: 'Auto Loan', offbudget: true }, -1450000);
  acct.old = await api.createAccount({ name: 'Old Checking' }, 0);

  const payeesAll = await api.getPayees();
  const xferPayee = id => payeesAll.find(p => p.transfer_acct === id).id;

  // ---- rules first, so imported-style payees are renamed as they arrive ----
  for (const [contains, payeeName, category] of RULES) {
    const payeeId = await api.createPayee({ name: payeeName });
    await api.createRule({
      stage: 'pre', conditionsOp: 'and',
      conditions: [{ field: 'imported_payee', op: 'contains', value: contains }],
      actions: [
        { op: 'set', field: 'payee', value: payeeId },
        ...(category ? [{ op: 'set', field: 'category', value: cat[category] }] : []),
      ],
    });
  }
  const nameRules = [['Luna Cafe', 'Dining Out'], ['Greenleaf Market', 'Groceries']];
  const allPayees = await api.getPayees();
  for (const [pn, c] of nameRules) {
    const id = allPayees.find(p => p.name === pn)?.id ?? (await api.createPayee({ name: pn }));
    await api.createRule({ stage: 'pre', conditionsOp: 'and', conditions: [{ field: 'payee', op: 'is', value: id }], actions: [{ op: 'set', field: 'category', value: cat[c] }] });
  }

  // ---- transactions ----
  const lastCardSpend = { visa: 0, store: 0 };
  for (const mo of mr) {
    const buckets = {};
    const add = (a, t) => (buckets[a] ??= []).push(t);
    const mkDate = d => ymd(mo.y, mo.m, Math.min(d, 28));
    const tail = (d, cleared = true) => {
      const dt = new Date(`${mkDate(d)}T12:00:00`);
      return {
        cleared: dt < clearedCutoff ? rand() > 0.015 : false,
        ...(dt < reconciledCutoff && cleared ? { reconciled: true, cleared: true } : {}),
      };
    };
    const inMonth = d => d <= mo.days;
    const spent = { visa: 0, store: 0 };
    const charge = () => {}; // card totals are summed from the buckets below
    const note = () => (rand() < 0.07 ? { notes: pick(NOTES) } : {});

    // income
    for (const d of [1, 15]) if (inMonth(d)) add('joint', { date: mkDate(d), amount: 450000, payee_name: 'Acme Payroll', category: cat.Paycheck, ...tail(d) });
    if (inMonth(5)) add('personal', { date: mkDate(5), amount: 90000, payee_name: 'Globex Payroll', category: cat.Paycheck, ...tail(5) });
    if (inMonth(20) && rand() < 0.5) add('personal', { date: mkDate(20), amount: between(15000, 60000), payee_name: 'Freelance Client', category: cat['Side Income'], ...tail(20) });
    if (inMonth(28)) add('hys', { date: mkDate(28), amount: between(2800, 3600), payee_name: 'Harbor Savings Bank', category: cat.Interest, ...tail(28) });
    if (inMonth(28)) add('savings', { date: mkDate(28), amount: between(300, 450), payee_name: 'Harbor Savings Bank', category: cat.Interest, ...tail(28) });

    // fixed bills
    for (const [c, d, amt, payee, a, spec] of FIXED) {
      if (!inMonth(d)) continue;
      let amount = amt;
      if (spec?.startsWith('range:')) { const [, lo, hi] = spec.split(':'); amount = between(+lo, +hi); }
      const t = { date: mkDate(d), amount: -amount, payee_name: payee, category: cat[c], ...tail(d) };
      if (c === 'Mortgage' && mo.idx % 5 === 0) { t.payee_name = 'SPRINGFIELD MTG PYMT'; t.imported_payee = 'SPRINGFIELD MTG PYMT'; }
      add(a, t); charge(a, -amount);
    }
    // variable spending
    for (const [c, v] of Object.entries(VAR)) {
      let count = Math.floor(v.n) + (rand() < v.n - Math.floor(v.n) ? 1 : 0);
      for (let i = 0; i < count; i++) {
        const d = between(1, 28);
        if (!inMonth(d)) continue;
        const a = pick(v.accts);
        const payee = pick(v.payees);
        const amount = between(v.min, v.max);
        const raw = v.raw?.[payee];
        const t = { date: mkDate(d), amount: -amount, payee_name: raw ? `${raw}${between(100, 9999)}` : payee, category: cat[c], ...tail(d), ...note() };
        if (raw) t.imported_payee = t.payee_name;
        add(a, t); charge(a, -amount);
      }
    }
    // refunds (occasional)
    if (inMonth(19) && rand() < 0.3) { const a = pick(['visa', 'store']); const amt = between(2000, 9000); add(a, { date: mkDate(19), amount: amt, payee_name: 'Amazon', category: cat.Electronics, notes: 'Refund', ...tail(19) }); }
    // seasonal big items
    if (mo.m === 6 || mo.m === 7) if (inMonth(22)) { add('visa', { date: mkDate(22), amount: -between(120000, 240000), payee_name: 'SkyWay Airlines', category: cat.Vacation, notes: 'Summer trip', ...tail(22) }); }
    if (mo.m === 12 && inMonth(12)) add('visa', { date: mkDate(12), amount: -between(40000, 70000), payee_name: 'Amazon', category: cat.Holiday, notes: 'Holiday gifts', ...tail(12) });
    if (mo.m === 4 && inMonth(15)) add('joint', { date: mkDate(15), amount: -between(150000, 260000), payee_name: 'State Tax Office', category: cat['Taxes & Licenses'], ...tail(15) });
    if (mo.m === 9 && inMonth(10)) add('joint', { date: mkDate(10), amount: -9500, payee_name: 'Visa Annual Fee', category: cat['Annual Fees'], ...tail(10) });
    // splits
    if (inMonth(16)) {
      const total = between(16000, 26000);
      const parts = [Math.round(total * 0.6), Math.round(total * 0.25)]; parts.push(total - parts[0] - parts[1]);
      add('visa', { date: mkDate(16), amount: -total, payee_name: 'Costco Wholesale', cleared: tail(16).cleared, ...(tail(16).reconciled ? { reconciled: true } : {}),
        subtransactions: [{ amount: -parts[0], category: cat.Groceries }, { amount: -parts[1], category: cat['Household Supplies'], notes: 'Bulk paper goods' }, { amount: -parts[2], category: cat.Clothing }] });
    }
    if (mo.idx % 3 === 1 && inMonth(24)) {
      const total = between(9000, 15000);
      add('store', { date: mkDate(24), amount: -total, payee_name: 'Target', cleared: tail(24).cleared, subtransactions: [{ amount: -Math.round(total / 2), category: cat['Kids Clothing'] }, { amount: -(total - Math.round(total / 2)), category: cat.Pharmacy }] });
    }
    // old closed account: history in the first two months, swept to zero
    if (mo.idx === 0 && inMonth(8)) add('old', { date: mkDate(8), amount: 210000, payee_name: 'Acme Payroll', category: cat.Paycheck, cleared: true, reconciled: true });
    if (mo.idx === 1 && inMonth(3)) add('old', { date: mkDate(3), amount: -38000, payee_name: 'City Power & Light', category: cat.Utilities, cleared: true, reconciled: true });

    for (const a of ['visa', 'store']) spent[a] = -(buckets[a] ?? []).reduce((n, t) => n + t.amount, 0);
    for (const [a, txns] of Object.entries(buckets)) await addBatch(acct[a], txns);

    // transfers (these go through the transfer machinery)
    const xfers = [];
    const X = (from, toKey, d, amount, extra = {}) => { if (inMonth(d)) xfers.push([from, { date: mkDate(d), amount: -amount, payee: xferPayee(acct[toKey]), ...tail(d), ...extra }]); };
    if (mo.idx > 0 && lastCardSpend.visa > 0 && lastCardSpend.store > 0) {
      X('joint', 'visa', 25, Math.round(lastCardSpend.visa), { notes: 'Card payment' });
      X('joint', 'store', 26, Math.round(lastCardSpend.store), { notes: 'Card payment' });
    }
    X('joint', 'savings', 27, 40000);
    X('joint', 'hys', 27, 50000);
    X('joint', 'personal', 7, 30000);
    X('joint', 'cash', 8, 45000, { notes: 'ATM' });
    X('hys', 'savings', 28, 10000);
    X('joint', 'loan', 13, 38000, { category: cat['Auto Loan Payment'] });
    X('joint', 'invest', 28, 40000, { category: cat['Retirement Contributions'] });
    if (mo.idx === 2 && inMonth(15)) xfers.push(['old', { date: mkDate(15), amount: -172000, payee: xferPayee(acct.joint), cleared: true, reconciled: true, notes: 'Close account' }]);
    for (const [from, t] of xfers) await addBatch(acct[from], [t], true);
    lastCardSpend.visa = spent.visa; lastCardSpend.store = spent.store;
    if (mo.idx % 6 === 5) log(`  ${mo.key}: transactions written`);
  }
  if (months >= 3) await api.closeAccount(acct.old);

  // ---- budget assignments ----
  const flat = GROUPS.flatMap(([, , cats]) => cats);
  await api.batchBudgetUpdates(async () => {
    for (const mo of mr) {
      for (const [name, base] of flat) {
        if (!base) continue;
        let amt = base;
        if (name === 'Dining Out' || name === 'Coffee') amt = Math.round(base * 0.7); // chronic overspend
        else if (name === 'Medical' || name === 'Home Maintenance') amt = Math.round(base * (0.5 + (mo.idx % 4) * 0.4));
        else if (name === 'Vacation' || name === 'Holiday') amt = base;
        else amt = Math.round((base * (1 + ((mo.idx * 7 + name.length) % 9 - 4) / 40)) / 100) * 100;
        await api.setBudgetAmount(mo.key, cat[name], amt);
      }
    }
  });
  // rollover/carryover on categories that should not forget overspending
  if (months >= 2) {
    await api.batchBudgetUpdates(async () => {
      for (const mo of mr.slice(1)) {
        for (const name of ['Groceries', 'Medical', 'Home Maintenance']) await api.setBudgetCarryover(mo.key, cat[name], true);
      }
    });
  }
  // hold for next month (envelope only)
  if (months >= 4) {
    const hm = mr[mr.length - 3];
    await api.holdBudgetForNextMonth(hm.key, 25000);
  }

  // ---- schedules ----
  const pid = async name => (await api.getPayees()).find(p => p.name === name)?.id ?? api.createPayee({ name });
  const nextMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1);
  const start = d => ymd(nextMonth.getFullYear(), nextMonth.getMonth() + 1, d);
  const monthly = (s, extra = {}) => ({ frequency: 'monthly', interval: 1, start: s, patterns: [], skipWeekend: false, weekendSolveMode: 'after', endMode: 'never', ...extra });
  const sched = [
    ['Mortgage', 'Springfield Mortgage', 'joint', -215000, 3, true],
    ['Internet', 'FiberNet', 'joint', -7000, 11, true],
    ['Phone', 'Northwind Mobile', 'visa', -11000, 10, false],
    ['Streaming', 'StreamBox', 'visa', -1599, 12, false],
    ['Car Insurance', 'Drive Safe Insurance', 'joint', -16000, 6, false],
  ];
  for (const [name, payee, a, amount, day, post] of sched) {
    await api.createSchedule({ name, posts_transaction: post, amount, amountOp: 'is', payee: await pid(payee), account: acct[a], date: monthly(start(day)) });
  }
  await api.createSchedule({ name: 'Savings Transfer', posts_transaction: true, amount: -40000, amountOp: 'is', payee: xferPayee(acct.savings), account: acct.joint, date: monthly(start(27)) });
  const endedStart = new Date(now.getFullYear(), now.getMonth() - 14, 5);
  const endedEnd = new Date(now.getFullYear(), now.getMonth() - 2, 5);
  await api.createSchedule({
    name: 'Old Gym Membership', posts_transaction: false, amount: -3500, amountOp: 'is', payee: await pid('Iron Works Gym'), account: acct.visa,
    date: monthly(ymd(endedStart.getFullYear(), endedStart.getMonth() + 1, 5), { endMode: 'on_date', endDate: ymd(endedEnd.getFullYear(), endedEnd.getMonth() + 1, 5) }),
  });

  // ---- goal templates (upstream #template syntax) ----
  const roofBy = new Date(now.getFullYear() + 2, 5, 1);
  const tmpl = {
    Groceries: '#template 780',
    Utilities: '#template 210 up to 300',
    Mortgage: '#template schedule Mortgage',
    Internet: '#template schedule Internet',
    Vacation: `#template 3600 by ${roofBy.getFullYear() - 1}-06 repeat every year`,
    'New Roof': `#template 15000 by ${roofBy.getFullYear()}-06`,
    'Emergency Fund': '#template 400',
    Holiday: '#template 150 by 2026-12 repeat every year',
    'Car Insurance': '#template schedule Car Insurance',
  };
  const notes = {
    Groceries: 'Weekly shop. Costco run mid-month.',
    Medical: 'Co-pays and dental.',
  };
  await api.batchBudgetUpdates(async () => {
    for (const [c, t] of Object.entries(tmpl)) await api.updateNote(cat[c], [notes[c], t].filter(Boolean).join('\n'));
    for (const [c, t] of Object.entries(notes)) if (!tmpl[c]) await api.updateNote(cat[c], t);
  });

  // ---- summary ----
  const accounts = await api.getAccounts();
  const cats = await api.getCategories();
  const { data: txCount } = await api.aqlQuery(api.q('transactions').filter({ is_child: false }).calculate({ $count: '*' }));
  const { data: allTx } = await api.aqlQuery(api.q('transactions').calculate({ $count: '*' }));
  const rules = await api.getRules();
  const schedules = await api.getSchedules();
  return `summary: ${accounts.length} accounts (${accounts.filter(a => a.closed).length} closed, ${accounts.filter(a => a.offbudget).length} off-budget), ${cats.length} categories, ${txCount} transactions (${allTx} rows incl. split children), ${schedules.length} schedules, ${rules.length} rules, ${months} months`;
}
