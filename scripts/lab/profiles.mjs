// Deterministic budget generators for the lab tool. Pure data + calls on the
// upstream @actual-app/api client; no credentials here.
import * as api from '@harness/api';

// mulberry32: small seeded PRNG so every run builds the same data.
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pad = n => String(n).padStart(2, '0');
const ymd = (y, m, d) => `${y}-${pad(m)}-${pad(d)}`;
export const today = () => {
  const n = new Date();
  return ymd(n.getFullYear(), n.getMonth() + 1, n.getDate());
};

// Oldest-first list of {y, m, key, days} for the last `count` months, the
// current month being partial (days up to today).
let anchorMonth = null; // 'YYYY-MM' override; null means the current month
export function setAnchor(a) { anchorMonth = a; }

// The reference "today": the real today for the current month, else the last
// day of the anchor month, so reruns with --anchor are identical.
export function refDate() {
  const real = new Date();
  if (!anchorMonth) return real;
  const [y, m] = anchorMonth.split('-').map(Number);
  if (y === real.getFullYear() && m === real.getMonth() + 1) return real;
  return new Date(y, m, 0, 12);
}

export function monthRange(count) {
  const now = refDate();
  const out = [];
  for (let i = count - 1; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const y = d.getFullYear(), m = d.getMonth() + 1;
    const full = new Date(y, m, 0).getDate();
    out.push({ y, m, key: `${y}-${pad(m)}`, days: i === 0 ? Math.min(now.getDate(), full) : Math.min(full, 28) });
  }
  return out;
}

export const GROUPS = [
  ['Bills', [['Rent', 150000], ['Utilities', 18000], ['Phone', 6500], ['Insurance', 12000]]],
  ['Food', [['Groceries', 55000], ['Dining Out', 20000]]],
  ['Fun & Lifestyle', [['Entertainment', 8000], ['Shopping', 15000], ['Subscriptions', 4500]]],
  ['Savings Goals', [['Emergency Fund', 30000], ['Vacation', 15000]]],
];

export const PAYEES = {
  Rent: ['Maple Property Management'],
  Utilities: ['City Power & Light', 'Riverside Water'],
  Phone: ['Northwind Mobile'],
  Insurance: ['Harbor Insurance'],
  Groceries: ['Greenleaf Market', 'Corner Grocer', 'Fresh Basket'],
  'Dining Out': ['Luna Cafe', 'Pizza Palace', 'Sunrise Diner', 'Noodle House'],
  Entertainment: ['Cinema 9', 'Bowl-a-Rama'],
  Shopping: ['Oak & Ash Goods', 'Pixel Electronics'],
  Subscriptions: ['StreamBox', 'Cloud Notes'],
};

export async function setupStructure() {
  const catIds = {};
  for (const [group, cats] of GROUPS) {
    const gid = await api.createCategoryGroup({ name: group });
    for (const [name] of cats) catIds[name] = await api.createCategory({ name, group_id: gid });
  }
  const groups = await api.getCategoryGroups();
  const income = groups.find(g => g.is_income);
  const incomeCats = new Map((income?.categories ?? []).map(c => [c.name, c.id]));
  for (const name of ['Salary', 'Interest']) {
    catIds[name] = incomeCats.get(name) ?? (await api.createCategory({ name, group_id: income.id }));
  }
  return catIds;
}

export async function setupAccounts() {
  const acct = {};
  acct.checking = await api.createAccount({ name: 'Checking' }, 500000);
  acct.savings = await api.createAccount({ name: 'Savings' }, 1200000);
  acct.card = await api.createAccount({ name: 'Credit Card' }, -45000);
  acct.retirement = await api.createAccount({ name: 'Retirement Fund', offbudget: true }, 8500000);
  return acct;
}

export async function transferPayee(accountId) {
  const payees = await api.getPayees();
  const p = payees.find(x => x.transfer_acct === accountId);
  if (!p) throw new Error('transfer payee not found');
  return p.id;
}

export async function budgetMonths(months, catIds, scale = 1) {
  await api.batchBudgetUpdates(async () => {
    for (const mo of months) {
      for (const [, cats] of GROUPS) {
        for (const [name, amount] of cats) {
          await api.setBudgetAmount(mo.key, catIds[name], Math.round((amount * scale) / 100) * 100);
        }
      }
    }
  });
}

export async function addBatch(accountId, txns, runTransfers = false) {
  if (txns.length === 0) return;
  // Transfer counterparts are created by reading the just-inserted rows back,
  // which does not work inside upstream's deferred batch; write those directly.
  const write = async () => {
    for (let i = 0; i < txns.length; i += 300) {
      await api.addTransactions(accountId, txns.slice(i, i + 300), { runTransfers });
    }
  };
  if (runTransfers) await write();
  else await api.batchBudgetUpdates(write);
}

// A tester-friendly month: pay, rent, bills, groceries, dining, card spending,
// card payment + savings transfer, one split. Cleared unless within 5 days.
async function standardMonth(mo, ctx, rand) {
  const { acct, catIds } = ctx;
  const cutoff = refDate(); cutoff.setDate(cutoff.getDate() - 5);
  const cleared = d => new Date(`${d}T12:00:00`) < cutoff;
  const inMonth = d => d <= mo.days;
  const pick = a => a[Math.floor(rand() * a.length)];
  const on = (d, amount, payee, cat, extra = {}) => ({
    date: ymd(mo.y, mo.m, d), amount, payee_name: payee, category: catIds[cat],
    cleared: cleared(ymd(mo.y, mo.m, d)), ...extra,
  });
  const checking = [], card = [], savings = [];
  if (inMonth(1)) checking.push(on(1, 240000, 'Acme Payroll', 'Salary'));
  if (inMonth(15)) checking.push(on(15, 240000, 'Acme Payroll', 'Salary'));
  if (inMonth(3)) checking.push(on(3, -150000, PAYEES.Rent[0], 'Rent'));
  if (inMonth(8)) checking.push(on(8, -(15000 + Math.floor(rand() * 6000)), pick(PAYEES.Utilities), 'Utilities'));
  if (inMonth(10)) checking.push(on(10, -6500, PAYEES.Phone[0], 'Phone'));
  if (inMonth(12)) checking.push(on(12, -12000, PAYEES.Insurance[0], 'Insurance'));
  if (inMonth(28)) savings.push(on(28, 1200, 'Harbor Savings Bank', 'Interest'));
  for (let i = 0; i < 6; i++) {
    const d = 2 + i * 4;
    if (inMonth(d)) (i % 2 ? checking : card).push(on(d, -(4000 + Math.floor(rand() * 9000)), pick(PAYEES.Groceries), 'Groceries'));
  }
  for (let i = 0; i < 4; i++) {
    const d = 5 + i * 6;
    if (inMonth(d)) card.push(on(d, -(1200 + Math.floor(rand() * 5000)), pick(PAYEES['Dining Out']), 'Dining Out'));
  }
  if (inMonth(9)) card.push(on(9, -1599, PAYEES.Subscriptions[0], 'Subscriptions'));
  if (inMonth(11)) card.push(on(11, -(2500 + Math.floor(rand() * 3000)), pick(PAYEES.Entertainment), 'Entertainment'));
  if (inMonth(20)) card.push(on(20, -(5000 + Math.floor(rand() * 9000)), pick(PAYEES.Shopping), 'Shopping'));
  if (inMonth(16)) {
    const d = 16;
    card.push({
      date: ymd(mo.y, mo.m, d), amount: -14850, payee_name: 'Costco Wholesale', cleared: cleared(ymd(mo.y, mo.m, d)),
      subtransactions: [
        { amount: -9850, category: catIds.Groceries, notes: 'Pantry restock' },
        { amount: -5000, category: catIds.Shopping, notes: 'Household' },
      ],
    });
  }
  await addBatch(acct.checking, checking);
  await addBatch(acct.card, card);
  await addBatch(acct.savings, savings);
  const toCard = await transferPayee(acct.card);
  const toSavings = await transferPayee(acct.savings);
  const xfers = [];
  if (inMonth(25)) xfers.push([acct.checking, { date: ymd(mo.y, mo.m, 25), amount: -60000, payee: toCard, cleared: cleared(ymd(mo.y, mo.m, 25)), notes: 'Card payment' }]);
  if (inMonth(26)) xfers.push([acct.checking, { date: ymd(mo.y, mo.m, 26), amount: -30000, payee: toSavings, cleared: cleared(ymd(mo.y, mo.m, 26)), notes: 'Monthly savings' }]);
  for (const [a, t] of xfers) await addBatch(a, [t], true);
}

async function addRuleAndSchedule(ctx) {
  const { acct, catIds } = ctx;
  const payees = await api.getPayees();
  const luna = payees.find(p => p.name === 'Luna Cafe');
  await api.createRule({
    stage: 'pre', conditionsOp: 'and',
    conditions: [{ field: 'payee', op: 'is', value: luna.id }],
    actions: [{ op: 'set', field: 'category', value: catIds['Dining Out'] }],
  });
  const rent = payees.find(p => p.name === PAYEES.Rent[0]);
  const next = refDate(); next.setMonth(next.getMonth() + 1, 3);
  await api.createSchedule({
    name: 'Rent', posts_transaction: false, amount: -150000, amountOp: 'is',
    payee: rent.id, account: acct.checking,
    date: { frequency: 'monthly', interval: 1, start: ymd(next.getFullYear(), next.getMonth() + 1, 3), patterns: [], skipWeekend: false, weekendSolveMode: 'after', endMode: 'never' },
  });
}

export async function buildBasic({ tracking = false, months = 3 }) {
  if (tracking) await api.internal.send('preferences/save', { id: 'budgetType', value: 'tracking' });
  const catIds = await setupStructure();
  const acct = await setupAccounts();
  const ctx = { acct, catIds };
  const mr = monthRange(months);
  const rand = rng(tracking ? 20260927 : 20260926);
  await budgetMonths(mr, catIds);
  for (const mo of mr) await standardMonth(mo, ctx, rand);
  await addRuleAndSchedule(ctx);
}

export async function buildPair(which) {
  const catIds = {};
  const gid = await api.createCategoryGroup({ name: 'Essentials' });
  for (const n of ['Rent', 'Groceries', 'Fun']) catIds[n] = await api.createCategory({ name: n, group_id: gid });
  const checking = await api.createAccount({ name: `${which} Checking` }, which === 'A' ? 300000 : 750000);
  const rand = rng(which === 'A' ? 11 : 22);
  const mo = monthRange(1)[0];
  const txns = [];
  for (let d = 1; d <= Math.min(mo.days, 8); d++) {
    txns.push({ date: ymd(mo.y, mo.m, d), amount: -(1500 + Math.floor(rand() * 4000)), payee_name: `${which} Store ${d % 3}`, category: catIds[d % 2 ? 'Groceries' : 'Fun'], cleared: true });
  }
  await addBatch(checking, txns);
}

// Multi-year history. Mostly plain transactions, with an occasional split and
// transfer so the data keeps the full shape.
export async function buildLarge({ months, perMonth }) {
  const catIds = await setupStructure();
  const acct = await setupAccounts();
  const mr = monthRange(months);
  const rand = rng(424242);
  await budgetMonths(mr, catIds);
  const spend = Object.keys(catIds).filter(n => n !== 'Salary' && n !== 'Interest');
  const accounts = [acct.checking, acct.card, acct.savings];
  const payeePool = Object.values(PAYEES).flat();
  const toSavings = await transferPayee(acct.savings);
  const pick = a => a[Math.floor(rand() * a.length)];
  for (const mo of mr) {
    const byAccount = new Map(accounts.map(a => [a, []]));
    const xfers = [];
    for (let i = 0; i < perMonth; i++) {
      const date = ymd(mo.y, mo.m, 1 + Math.floor(rand() * mo.days));
      const a = pick(accounts);
      const r = rand();
      const t = { date, cleared: rand() < 0.9 };
      if (r < 0.02) {
        t.amount = -(8000 + Math.floor(rand() * 8000));
        t.payee_name = 'Costco Wholesale';
        const half = Math.floor(t.amount / 2);
        t.subtransactions = [
          { amount: half, category: catIds.Groceries },
          { amount: t.amount - half, category: catIds.Shopping },
        ];
      } else if (r < 0.04 && a === acct.checking) {
        xfers.push({ date, amount: -(5000 + Math.floor(rand() * 20000)), payee: toSavings, cleared: true });
        continue;
      } else if (r < 0.08) {
        t.amount = 150000 + Math.floor(rand() * 60000);
        t.payee_name = 'Acme Payroll';
        t.category = catIds.Salary;
      } else {
        t.amount = -(300 + Math.floor(rand() * 15000));
        const cat = pick(spend);
        t.category = catIds[cat];
        t.payee_name = pick(PAYEES[cat] ?? payeePool);
      }
      byAccount.get(a).push(t);
    }
    for (const [a, txns] of byAccount) await addBatch(a, txns);
    await addBatch(acct.checking, xfers, true);
    process.stdout.write(`LAB| ${mo.key} done\n`);
  }
}
