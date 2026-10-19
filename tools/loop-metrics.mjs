// Per-round loop metrics: cost, time, agent errors, C verdicts, bugs by severity, real-check coverage, gate result.
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
const loop = process.argv[2];
const read = (p) => { const b = readFileSync(p); return (b[0] === 0xff && b[1] === 0xfe ? b.toString('utf16le') : b.toString('utf8')).replace(/^﻿/, ''); };
const json = (p) => { try { return existsSync(p) ? JSON.parse(read(p)) : null; } catch { return null; } };
const files = readdirSync(loop);
const seen = new Set();
for (const f of files) { const m = f.match(/^[abc]-round-(\d+)(-result)?\.json/); if (m) seen.add(Number(m[1])); }
const cost = (r, role) => { const o = { usd: 0, ms: 0, errors: 0 }; for (const f of files) { if (f.startsWith(`${role}-round-${r}-result.json`)) { const j = json(join(loop, f)); if (!j) continue; o.usd += Number(j.total_cost_usd) || 0; o.ms += Number(j.duration_ms) || 0; if (j.is_error) o.errors += 1; } } return o; };
const rows = [...seen].sort((a, b) => a - b).map((r) => {
  const a = cost(r, 'a'), b = cost(r, 'b'), c = cost(r, 'c'), cr = json(join(loop, `c-round-${r}.json`)), g = json(join(loop, 'gates', `gate-round-${r}.json`));
  const bugs = { critical: 0, high: 0, medium: 0, low: 0 }; for (const x of cr?.bugs ?? []) { const s = String(x.severity ?? '').toLowerCase(); if (s in bugs) bugs[s] += 1; }
  const real = cr ? (cr.realVerified ?? cr.browserVerified ?? null) : null;
  return { round: r, c: cr?.taskStatus ?? '', ...Object.fromEntries(Object.entries(bugs).map(([k, v]) => [`bugs_${k}`, v])), realVerified: real, usd: a.usd + b.usd + c.usd, hours: (a.ms + b.ms + c.ms) / 3.6e6, errors: a.errors + b.errors + c.errors, gate: g?.status ?? '' };
});
mkdirSync(join(loop, 'metrics'), { recursive: true });
writeFileSync(join(loop, 'metrics', 'rounds.json'), JSON.stringify(rows, null, 2));
const cols = Object.keys(rows[0] ?? { round: 0 });
writeFileSync(join(loop, 'metrics', 'rounds.csv'), [cols.join(','), ...rows.map((x) => cols.map((k) => (typeof x[k] === 'number' && !Number.isInteger(x[k]) ? x[k].toFixed(3) : String(x[k]))).join(','))].join('\n') + '\n');
const sum = (k, xs = rows) => xs.reduce((s, x) => s + (Number(x[k]) || 0), 0), last = rows.slice(-10), withC = rows.filter((x) => x.c);
writeFileSync(join(loop, 'metrics', 'summary.md'), [
  `# Loop metrics (${new Date().toISOString()})`, '',
  `- rounds: ${rows.length}; cost $${sum('usd').toFixed(2)} total, last 10 avg $${(sum('usd', last) / Math.max(1, last.length)).toFixed(2)}/round; agent time ${sum('hours').toFixed(1)} h`,
  `- C: PASS ${withC.filter((x) => x.c === 'PASS').length}, FAIL ${withC.filter((x) => x.c === 'FAIL').length}, BLOCKED ${withC.filter((x) => x.c === 'BLOCKED').length}; bugs c/h/m/l ${sum('bugs_critical')}/${sum('bugs_high')}/${sum('bugs_medium')}/${sum('bugs_low')}`,
  `- rounds without a real check: ${rows.filter((x) => x.realVerified === false).map((x) => x.round).join(', ') || 'none'}; agent errors ${sum('errors')}`,
  `- gates: ${rows.filter((x) => x.gate).map((x) => `${x.round}:${x.gate}`).join(', ') || 'none yet'}`,
  '', '| round | C | bugs c/h/m/l | real | $ | h | err | gate |', '|---|---|---|---|---|---|---|---|',
  ...rows.slice(-15).map((x) => `| ${x.round} | ${x.c || '-'} | ${x.bugs_critical}/${x.bugs_high}/${x.bugs_medium}/${x.bugs_low} | ${x.realVerified === null ? '-' : x.realVerified ? 'yes' : 'NO'} | ${x.usd.toFixed(2)} | ${x.hours.toFixed(2)} | ${x.errors} | ${x.gate || '-'} |`),
].join('\n') + '\n');
console.log(`metrics ${rows.length} rounds, $${sum('usd').toFixed(2)}`);
