// One fixed Apply Templates scenario, envelope or tracking. Every amount here
// is chosen so a skip, a blocked category or a lost cent shows in Savings,
// which takes the remainder.
import * as api from '@harness/api';
import { monthRange, refDate } from './profiles.mjs';

const monthKey = offset => {
  const d = refDate();
  const shifted = new Date(d.getFullYear(), d.getMonth() + offset, 1);
  return `${shifted.getFullYear()}-${String(shifted.getMonth() + 1).padStart(2, '0')}`;
};

export async function buildTemplates({ tracking = false, notes = false }) {
  if (tracking) await api.internal.send('preferences/save', { id: 'budgetType', value: 'tracking' });
  const month = monthRange(1)[0];
  const cat = {};
  const goals = ['Car Fund', 'Old Laptop', 'Savings', ...(notes ? ['Vet', 'Holiday', 'Gym'] : [])];
  const groups = [['Bills', ['Rent', 'Utilities']], ['Food', ['Groceries', 'Dining']], ['Goals', goals]];
  for (const [group, names] of groups) {
    const groupID = await api.createCategoryGroup({ name: group });
    for (const name of names) cat[name] = await api.createCategory({ name, group_id: groupID });
  }
  const income = (await api.getCategoryGroups()).find(g => g.is_income);
  const salary = income.categories.find(c => c.name === 'Salary')
    ?? { id: await api.createCategory({ name: 'Salary', group_id: income.id }) };
  cat.Salary = salary.id;

  const checking = await api.createAccount({ name: 'Checking' }, 0);
  await api.addTransactions(checking, [
    { date: `${month.key}-01`, amount: 600000, payee_name: 'Acme Payroll', category: cat.Salary, cleared: true },
    { date: `${month.key}-01`, amount: -12000, payee_name: 'Greenleaf Market', category: cat.Groceries, cleared: true },
  ]);

  await api.batchBudgetUpdates(async () => {
    await api.setBudgetAmount(month.key, cat.Groceries, 35000);
    await api.setBudgetAmount(month.key, cat.Dining, 18000);
    await api.setBudgetAmount(month.key, cat['Old Laptop'], 4000);
  });
  if (notes) {
    const lines = {
      Rent: '#template 1200',
      Utilities: '#template-1 150',
      Groceries: '#template-1 400',
      Dining: '#template-1 100',
      'Car Fund': `#template-2 600 by ${monthKey(3)}`,
      'Old Laptop': `#template-2 300 by ${monthKey(-2)}`,
      Vet: `#template-1 50 repeat every 2 months starting ${month.key}-01`,
      Holiday: `#template-2 900 by ${monthKey(8)} spend from ${monthKey(6)}`,
      Gym: '#template-1 40',
      Savings: '#template remainder',
    };
    for (const [name, note] of Object.entries(lines)) await api.updateNote(cat[name], note);
    await api.internal.send('budget/store-note-templates');
    // Changed after Actual stored it, so this one really is out of date.
    await api.updateNote(cat.Gym, '#template-1 60');
    return `month ${month.key}: note templates on ${Object.keys(lines).length} categories`;
  }
  // Stored the way Actual's template editor does (source "ui"), so the note
  // staleness check does not apply.
  const template = fields => [{ directive: 'template', priority: 1, ...fields }];
  const templates = {
    Rent: template({ type: 'simple', monthly: 1200, limit: null, priority: 0 }),
    Utilities: template({ type: 'simple', monthly: 150, limit: null }),
    Groceries: template({ type: 'simple', monthly: 400, limit: null }),
    Dining: template({ type: 'simple', monthly: 100, limit: null }),
    'Car Fund': template({ type: 'by', amount: 600, month: monthKey(3), priority: 2 }),
    'Old Laptop': template({ type: 'by', amount: 300, month: monthKey(-2), priority: 2 }),
    Savings: template({ type: 'remainder', priority: null, weight: 1, limit: null }),
    ...(tracking ? { Salary: template({ type: 'simple', monthly: 6000, limit: null }) } : {}),
  };
  await api.internal.send('budget/set-category-automations', {
    categoriesWithTemplates: Object.entries(templates).map(([name, entries]) => ({ id: cat[name], templates: entries })),
    source: 'ui',
  });
  return `month ${month.key}: templates on ${Object.keys(templates).length} categories`;
}
