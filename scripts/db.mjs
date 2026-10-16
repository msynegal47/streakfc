// Applies any streakfc-v*.sql that hasn't run yet against the live Supabase database.
// Connection string lives in ~/.streakfc-db on this computer only (never in the repo).
import fs from 'fs'; import os from 'os'; import path from 'path'; import { createRequire } from 'module';
const require = createRequire(path.join(os.homedir(), '.streakfc-tools', 'x.js'));
const { Client } = require('pg');
const dir = path.dirname(path.dirname(new URL(import.meta.url).pathname));
const url = (process.env.STREAKFC_DB || fs.readFileSync(path.join(os.homedir(), '.streakfc-db'), 'utf8')).trim();
const ver = n => n === 'streakfc-setup.sql' ? 1 : +(/streakfc-v(\d+)(?:-v(\d+))?\.sql$/.exec(n)?.[2] || /streakfc-v(\d+)/.exec(n)?.[1] || 0);
const files = fs.readdirSync(dir).filter(n => /^streakfc-(setup|v\d+(-v\d+)?)\.sql$/.test(n)).sort((a, b) => ver(a) - ver(b) || a.localeCompare(b));
const c = new Client({ connectionString: url, ssl: /localhost|\/var\//.test(url) ? false : { rejectUnauthorized: false } });
await c.connect();
const fresh = (await c.query(`select to_regclass('public.sfc_migrations') is null as fresh`)).rows[0].fresh;
await c.query(`create table if not exists public.sfc_migrations (name text primary key, applied_at timestamptz not null default now());
  alter table public.sfc_migrations enable row level security; revoke all on public.sfc_migrations from public, anon, authenticated;`);
// Everything up to v14 was already pasted in by hand before this script existed
if (fresh) for (const n of files.filter(n => ver(n) <= 14)) await c.query('insert into public.sfc_migrations(name) values ($1) on conflict do nothing', [n]);
const done = new Set((await c.query('select name from public.sfc_migrations')).rows.map(r => r.name));
const todo = files.filter(n => !done.has(n));
if (!todo.length) console.log('Database: up to date');
for (const n of todo) {
  process.stdout.write(`Database: applying ${n} ... `);
  try { await c.query('begin'); const r = await c.query(fs.readFileSync(path.join(dir, n), 'utf8')); await c.query('insert into public.sfc_migrations(name) values ($1)', [n]); await c.query('commit');
    const last = [].concat(r).pop(); console.log(last && last.rows && last.rows[0] ? JSON.stringify(last.rows[0]) : 'ok'); }
  catch (e) { await c.query('rollback'); console.log('FAILED'); console.error(e.message); process.exit(1); }
}
await c.query(`notify pgrst, 'reload schema'`); await c.end();
