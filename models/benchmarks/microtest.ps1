#Requires -Version 5.1
# Microtest de vitesse local-ai (12.B.1) : 1 requete d'amorce (num_predict 1) puis N mesures, prompt 6.B.1 "speed",
# temperature 0, seed 42, 128 tokens maximum, reflexion desactivee pour qwen3.5 (comme OpenCode). Aucun telechargement.
# Resultats : runtime/bench/microtests.jsonl (non versionne). Usage :
#   .\models\benchmarks\microtest.ps1 -Label base -Model qwen3.5:4b-q4_K_M [-NumThread 8] [-NumBatch 512] [-Ctx 4096] [-Runs 2]
param(
    [Parameter(Mandatory)][string]$Label,
    [string]$Model = 'qwen3.5:4b-q4_K_M',
    [int]$Ctx = 4096,
    [int]$NumThread = 0,
    [int]$NumBatch = 0,
    [int]$Runs = 2,
    [int]$Predict = 128,
    [int]$Filler = 0,
    [switch]$Unload
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Out = Join-Path $Root 'runtime\bench'; New-Item -ItemType Directory -Force $Out | Out-Null
$PostSh = @'
sed '1s/^\xEF\xBB\xBF//' > /tmp/localai-req.json
len=$(wc -c < /tmp/localai-req.json)
exec 3<>/dev/tcp/127.0.0.1/11434 || { echo '{"error":"connect"}'; exit 1; }
{ printf 'POST %s HTTP/1.0\r\nHost: ollama\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n' "$1" "$len"; cat /tmp/localai-req.json; } >&3
timeout "$2" cat <&3 | tr -d '\r' | awk 'b{print} /^$/{b=1}'
'@ -replace "`r", ''
$C = (docker compose -f (Join-Path $Root 'compose.yaml') --profile ollama ps -q --status running ollama 2>$null | Select-Object -First 1)
if (-not $C) { throw 'Ollama non demarre.' }
$PostSh | docker exec -i $C /bin/sh -c "sed '1s/^\xEF\xBB\xBF//' > /tmp/localai-post.sh" | Out-Null

function Get-Mem {
    $m = @{}; foreach ($l in ((wsl -d docker-desktop -- cat /proc/meminfo) -replace "`0", '')) { if ($l -match '^(\w+):\s+(\d+)') { $m[$Matches[1]] = [double]$Matches[2] / 1MB } }
    $os = Get-CimInstance Win32_OperatingSystem
    [ordered]@{ wsl_used_gib = [math]::Round($m.MemTotal - $m.MemAvailable, 2); wsl_total_gib = [math]::Round($m.MemTotal, 2)
        swap_used_gib = [math]::Round($m.SwapTotal - $m.SwapFree, 2); win_avail_gib = [math]::Round($os.FreePhysicalMemory / 1MB, 2) }
}
function Invoke-Gen([string]$Prompt, [int]$N) {
    $opt = [ordered]@{ num_ctx = $Ctx; num_predict = $N; temperature = 0.0; seed = 42 }
    if ($NumThread -gt 0) { $opt.num_thread = $NumThread }
    if ($NumBatch -gt 0) { $opt.num_batch = $NumBatch }
    $b = [ordered]@{ model = $Model; prompt = $Prompt; stream = $false; keep_alive = '5m'; options = $opt }
    if ($Model -like 'qwen3.5*') { $b.think = $false }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $raw = ($b | ConvertTo-Json -Compress) | docker exec -i $C /bin/bash /tmp/localai-post.sh /api/generate 600
    $sw.Stop(); $r = ($raw -join '') | ConvertFrom-Json
    if ($r.PSObject.Properties.Name -contains 'error') { throw "Ollama : $($r.error)" }
    [ordered]@{ wall_s = [math]::Round($sw.Elapsed.TotalSeconds, 2); load_s = [math]::Round($r.load_duration / 1e9, 2)
        prompt_tokens = $r.prompt_eval_count; prompt_tps = [math]::Round($r.prompt_eval_count / ($r.prompt_eval_duration / 1e9), 2)
        ttft_s = [math]::Round(($r.load_duration + $r.prompt_eval_duration) / 1e9, 2)
        out_tokens = $r.eval_count; out_tps = [math]::Round($r.eval_count / ($r.eval_duration / 1e9), 2) }
}
$warm = Invoke-Gen 'Request id: 00000000. Say OK.' 1
$res = @()
for ($i = 1; $i -le $Runs; $i++) {
    $ctxText = if ($Filler -gt 0) { ((1..$Filler | ForEach-Object { "Section $_ : the service validates each request, records an audit entry, checks the cache, then forwards the payload to the worker queue with a retry budget." }) -join ' ') + ' ' } else { '' }
    $p = "Request id: $([guid]::NewGuid().ToString('N').Substring(0,8)). $ctxText`Explain in about 150 words how a hash table handles collisions."
    $g = Invoke-Gen $p $Predict; $mem = Get-Mem
    $rec = [ordered]@{ ts = (Get-Date).ToString('s'); label = $Label; model = $Model; ctx = $Ctx; num_thread = $NumThread; num_batch = $NumBatch; run = $i; warm_load_s = $warm.load_s }
    foreach ($h in $g, $mem) { foreach ($k in $h.Keys) { $rec[$k] = $h[$k] } }
    $res += [pscustomobject]$rec
    Add-Content -Path (Join-Path $Out 'microtests.jsonl') -Value ([pscustomobject]$rec | ConvertTo-Json -Compress) -Encoding UTF8
}
if ($Unload) { (@{ model = $Model; keep_alive = 0 } | ConvertTo-Json -Compress) | docker exec -i $C /bin/bash /tmp/localai-post.sh /api/generate 60 | Out-Null }
$avg = { param($k) [math]::Round((($res | Measure-Object $k -Average).Average), 2) }
'{0,-18} t/s {1,6}  ttft {2,5}s  prompt {3,6} t/s  load {4,5}s  wsl {5} Gio  swap {6}  win {7}  wall {8}s' -f $Label, (& $avg out_tps), (& $avg ttft_s), (& $avg prompt_tps), $warm.load_s, $res[-1].wsl_used_gib, $res[-1].swap_used_gib, $res[-1].win_avail_gib, ((& $avg wall_s) * $Runs + $warm.wall_s)
