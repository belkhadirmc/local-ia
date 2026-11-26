// Contrôles du relais Continue à travers la passerelle (14.B.1) — hôte, http://127.0.0.1:11435.
// 1 complétion FIM réelle (qwen2.5-coder:1.5b, 24 tokens), refus JSON/modèle, puis exclusion mutuelle : une génération longue
// lancée côté OpenCode (espace réseau OpenCode -> passerelle) pendant laquelle Continue doit recevoir 409.
import { execFile } from 'node:child_process';
const R = 'http://127.0.0.1:11435';
const out = [];
const chk = (ok, label) => out.push(`${ok ? 'PASS' : 'FAIL'} ${label}`);
async function post(path, body, raw) {
  const t = Date.now();
  const r = await fetch(R + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: raw ?? JSON.stringify(body) });
  return { code: r.status, text: await r.text(), ms: Date.now() - t };
}
const fim = { model: 'qwen2.5-coder:1.5b', prompt: 'def add(a, b):\n    ', suffix: '\n', stream: false, options: { num_predict: 24, temperature: 0 } };
let r = await post('/api/generate', fim);
chk(r.code === 200 && /return/.test(r.text), `complétion FIM réelle via passerelle (${r.ms} ms) : ${(JSON.parse(r.text).response ?? '').trim().slice(0, 40)}`);
r = await post('/api/generate', null, '{"model":"qwen2.5-coder:1.5b","model":"qwen3.5:4b-q4_K_M","prompt":"x"}');
chk(r.code === 400, `clé model dupliquée -> ${r.code}`);
r = await post('/api/generate', null, '{"model":"qwen2.5-coder:1.5b","prompt":"x",}');
chk(r.code === 400, `JSON invalide -> ${r.code}`);
r = await post('/api/generate', { model: 'qwen3.5:4b-q4_K_M', prompt: 'x' });
chk(r.code === 403, `autre modèle -> ${r.code}`);
r = await post('/api/generate', { prompt: '"model":"qwen2.5-coder:1.5b"' });
chk(r.code === 403, `modèle seulement dans une chaîne -> ${r.code}`);
// Exclusion mutuelle : génération longue du même modèle côté OpenCode, puis requête Continue pendant qu'elle tient le verrou.
const long = JSON.stringify({ model: 'qwen2.5-coder:1.5b', prompt: 'Écris une liste numérotée de 60 fruits.', stream: false, options: { num_predict: 160, temperature: 0 } });
const b64 = Buffer.from(long).toString('base64');
const bg = new Promise(res => execFile('docker', ['exec', 'local-ai-opencode-1', 'sh', '-c',
  `printf %s ${b64} | base64 -d > /tmp/long.json; wget -q -O /dev/null --header 'Content-Type: application/json' --post-file /tmp/long.json http://ollama:11434/api/generate; echo done`], () => res()));
await new Promise(res => setTimeout(res, 2500));
r = await post('/api/generate', fim);
chk(r.code === 409, `Continue pendant une inférence OpenCode -> ${r.code} (${r.text.slice(0, 80)})`);
await bg;
r = await post('/api/generate', fim);
chk(r.code === 200, `Continue après la fin de l'inférence OpenCode -> ${r.code}`);
console.log(out.join('\n'));
