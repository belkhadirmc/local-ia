// Test pratique d'un agent OpenCode par l'API du serveur (14.B.1) — Node.js hôte, execFileSync (aucun shell : pas d'altération
// des guillemets ni de BOM). Session « 14B1-<agent>- » dans le projet ouvert, modèle de SESSION optionnel (aucun changement
// d'affectation), permissions répondues explicitement et journalisées, délai maximal puis interruption.
// Usage : node tests/agents/run-agent.mjs '{"agent":"assistant","prompt":"...","model":"qwen3.5:4b-q4_K_M","timeout":240,"allowEdit":["*"],"allowShell":[]}'
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const cfg = JSON.parse(process.argv[2]);
const dir = cfg.directory ?? '/data/workspace/t14-pyapp';
const timeout = (cfg.timeout ?? 240) * 1000;
const like = (pat, s) => new RegExp('^' + pat.split('*').map(x => x.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$', 's').test(s);
const container = execFileSync('docker', ['ps', '-qf', 'name=local-ai-opencode-1']).toString().trim();
function api(method, path, data) {
  const args = ['exec', container, 'opencode', 'api', '--server', 'http://127.0.0.1:4096', method, path];
  if (data !== undefined) args.push('-d', JSON.stringify(data));
  try { return JSON.parse(execFileSync('docker', args, { maxBuffer: 64 << 20 }).toString('utf8')); }
  catch (e) { return { error: String(e.stdout ?? e.message).slice(0, 400) }; }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

const body = { title: `14B1-${cfg.agent}-${Date.now() % 1e6}`, agent: cfg.agent, location: { directory: dir } };
if (cfg.model) body.model = { providerID: 'ollama', id: cfg.model };
const s = api('POST', '/api/session', body);
const sid = s?.data?.id;
if (!sid) { console.log(JSON.stringify({ agent: cfg.agent, error: 'session', detail: s })); process.exit(2); }
const t0 = Date.now();
const p = api('POST', `/api/session/${sid}/prompt`, { text: cfg.prompt });
if (!p?.data?.id) { console.log(JSON.stringify({ agent: cfg.agent, error: 'prompt', detail: p })); process.exit(2); }
const decisions = []; let timedOut = false; let lastBusySeen = Date.now();
while (true) {
  await sleep(2000);
  for (const q of api('GET', `/api/session/${sid}/permission`)?.data ?? []) {
    if (!q?.id) continue;
    const res = (q.resources ?? []).join(' ');
    let ok = false;
    if (q.action === 'edit') ok = (cfg.allowEdit ?? ['*']).some(x => like(x, res));
    else if (q.action === 'shell') ok = (cfg.allowShell ?? []).some(x => like(x, res));
    else if (q.action === 'subagent') ok = cfg.allowSubagent !== false;
    const decision = ok ? 'once' : 'reject';
    api('POST', `/api/session/${sid}/permission/${q.id}/reply`, { decision });
    decisions.push({ action: q.action, resource: res.slice(0, 200), decision });
  }
  const info = api('GET', `/api/session/${sid}`)?.data;
  const busy = info?.time?.busy && (!info.time.updated || info.time.busy >= info.time.updated - 5);
  const msgs = api('GET', `/api/session/${sid}/message`)?.data ?? [];
  const last = msgs[0];
  const finished = last && ((last.type === 'assistant' && last.time?.completed && last.finish !== 'tool-calls') || last.type === 'idle');
  if (finished && Date.now() - t0 > 4000) break;
  if (Date.now() - t0 > timeout) { api('POST', `/api/session/${sid}/interrupt`); timedOut = true; break; }
}
const seconds = Math.round((Date.now() - t0) / 1000);
const msgs = (api('GET', `/api/session/${sid}/message`)?.data ?? []).slice().reverse();
const tools = [], texts = [], errors = [], kinds = new Set();
for (const m of msgs) {
  if (m.type !== 'assistant') continue;
  if (m.error) errors.push(`${m.error.type}: ${m.error.message}`);
  for (const c of m.content ?? []) {
    kinds.add(c.type);
    if (c.type === 'text' && c.text) texts.push(c.text);
    else if (/tool/.test(c.type)) tools.push(`${c.tool ?? c.name ?? c.type}${c.state?.status ? ':' + c.state.status : ''}`);
  }
}
const r = { agent: cfg.agent, model: cfg.model ?? 'affectation', session: sid, seconds, timedOut, tools, permissions: decisions, errors,
  partTypes: [...kinds], answer: texts.join('\n').replace(/\s+/g, ' ').trim().slice(0, 1500) };
mkdirSync(join(root, 'runtime', 'tests', '14B1'), { recursive: true });
writeFileSync(join(root, 'runtime', 'tests', '14B1', `${cfg.agent}${cfg.tag ? '-' + cfg.tag : ''}.json`), JSON.stringify(r, null, 2));
console.log(JSON.stringify(r, null, 1));
