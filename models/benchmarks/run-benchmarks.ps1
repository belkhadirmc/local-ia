#Requires -Version 5.1
<#
.SYNOPSIS
  Benchmarks local-ai (6.B.1) : qualité, performances et mémoire des modèles du registre, via l'API Ollama interne (N1).
.DESCRIPTION
  - Un seul modèle et une seule requête à la fois ; sorties et délais bornés ; déchargement entre séries.
  - Surveillance chaque seconde (RAM WSL2 hors cache, swap, RAM Windows disponible, CPU, RAM conteneur) ; interruption sécurisée.
  - Code généré exécuté uniquement dans un bac à sable Docker isolé (image existante, sans réseau, lecture seule, sans capacités).
  - Critères : suite.yaml + cases/*.json. Résultats bruts : results/<horodatage>/ (hors Git). Synthèse : summary.csv/json, report.md.
.EXAMPLE
  .\run-benchmarks.ps1                       # 7 modèles, protocole complet
  .\run-benchmarks.ps1 -Models qwen2.5-coder:1.5b -Quick   # essai à blanc
#>
[CmdletBinding()]
param(
    [string[]]$Models,
    [switch]$Quick,
    [switch]$NoSummary,
    # Dossier results/<horodatage> d'une exécution précédente : ses modèles complets (non relancés ici) sont repris pour la notation.
    [string]$MergeFrom
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Root = (Resolve-Path (Join-Path $Here '..\..')).Path
$Utf8 = New-Object Text.UTF8Encoding $false
$OutputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
Add-Type -AssemblyName Microsoft.VisualBasic
# Empêche la mise en veille pendant l'exécution (propre au processus, levé automatiquement à sa fin ; aucun réglage système).
Add-Type -Namespace LocalAi -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
[void][LocalAi.Power]::SetThreadExecutionState([uint32]'0x80000001')
$Inv = [Globalization.CultureInfo]::InvariantCulture
# Les erreurs natives (stderr) ne doivent pas interrompre la suite : contrôles explicites par code retour / contenu.
$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------------ configuration
function Read-SimpleYaml([string]$Path) {
    $root = @{}; $stack = New-Object System.Collections.ArrayList
    [void]$stack.Add(@{ indent = -1; map = $root })
    foreach ($line in [IO.File]::ReadAllLines($Path, $Utf8)) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -notmatch '^(\s*)([^:#"]+?):\s*(.*?)\s*$') { continue }
        $ind = $Matches[1].Length; $k = $Matches[2].Trim(); $v = $Matches[3]
        while ($stack[$stack.Count - 1].indent -ge $ind) { $stack.RemoveAt($stack.Count - 1) }
        $parent = $stack[$stack.Count - 1].map
        if ($v -eq '') { $m = @{}; $parent[$k] = $m; [void]$stack.Add(@{ indent = $ind; map = $m }) }
        else {
            if ($v -match '^"(.*)"$') { $v = $Matches[1] }
            elseif ($v -match '^[-+]?\d+(\.\d+)?$') { $v = [double]$v }
            $parent[$k] = $v
        }
    }
    $root
}
$S = Read-SimpleYaml (Join-Path $Here 'suite.yaml')
$RT = $S.runtime; $TH = $S.thresholds; $SB = $S.sandbox; $NORM = $S.normalization
$Cases = @{}; Get-ChildItem (Join-Path $Here 'cases') -Filter *.json | ForEach-Object { $j = [IO.File]::ReadAllText($_.FullName, $Utf8) | ConvertFrom-Json; $Cases[$j.id] = $j }
$QualityOrder = 'code_gen', 'debug', 'qa', 'fim', 'devops', 'review', 'security', 'architecture', 'multifile', 'instructions', 'documentation', 'tools'

$registry = [IO.File]::ReadAllText((Join-Path $Root 'models\registry.yaml'), $Utf8)
$allTags = @([regex]::Matches($registry, '(?m)^\s+tag:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
if (-not $Models) { $Models = $allTags }
foreach ($m in $Models) { if ($allTags -notcontains $m) { throw "Modèle '$m' absent de models/registry.yaml (aucun téléchargement)." } }

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$Out = Join-Path $Here "results\$ts"
New-Item -ItemType Directory -Force $Out | Out-Null
$RawFile = Join-Path $Out 'raw.jsonl'; $SampleFile = Join-Path $Out 'samples.csv'; $LogFile = Join-Path $Out 'run.log'
[IO.File]::WriteAllText($SampleFile, "time,label,wsl_used_gib,wsl_pct,swap_gib,win_avail_gib,ctr_anon_gib,cpu_pct`n", $Utf8)
function Write-Log([string]$m) { $l = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; [IO.File]::AppendAllText($LogFile, $l + "`n", $Utf8); Write-Host $l }
function Save-Raw($obj) { [IO.File]::AppendAllText($RawFile, (($obj | ConvertTo-Json -Depth 12 -Compress) + "`n"), $Utf8) }
$Anomalies = New-Object System.Collections.Generic.List[string]

# ------------------------------------------------------------------ Ollama access (internal API, N1)
$PostSh = @'
sed '1s/^\xEF\xBB\xBF//' > /tmp/localai-req.json
len=$(wc -c < /tmp/localai-req.json)
exec 3<>/dev/tcp/127.0.0.1/11434 || { echo '{"error":"connect"}'; exit 1; }
{ printf 'POST %s HTTP/1.0\r\nHost: ollama\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n' "$1" "$len"; cat /tmp/localai-req.json; } >&3
timeout "$2" cat <&3 | tr -d '\r' | awk 'b{print} /^$/{b=1}'
'@ -replace "`r", ''
function Get-OllamaId { (docker compose -f (Join-Path $Root 'compose.yaml') --profile ollama ps -q --status running ollama 2>$null | Select-Object -First 1) }
function Initialize-Client {
    $script:C = Get-OllamaId
    if (-not $script:C) { throw 'Ollama non démarré (.\local-ai.ps1 start).' }
    $PostSh | docker exec -i $script:C /bin/sh -c "sed '1s/^\xEF\xBB\xBF//' > /tmp/localai-post.sh" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'copie du client HTTP impossible' }
}
function Restart-Ollama {
    Write-Log 'INTERRUPTION : redémarrage sécurisé d''Ollama (déchargement forcé)'
    & (Join-Path $Root 'local-ai.ps1') stop | Out-Null
    & (Join-Path $Root 'local-ai.ps1') start | Out-Null
    Initialize-Client
}
function Get-Loaded { @((docker exec $script:C /bin/ollama ps 2>$null) | Select-Object -Skip 1 | Where-Object { $_.Trim() }) }
function Invoke-Unload([string]$Model) {
    $b = @{ model = $Model; keep_alive = 0 } | ConvertTo-Json -Compress
    $b | docker exec -i $script:C /bin/bash /tmp/localai-post.sh /api/generate 60 | Out-Null
    for ($i = 0; $i -lt 20 -and @(Get-Loaded).Count -gt 0; $i++) { Start-Sleep 1 }
}

# ------------------------------------------------------------------ monitoring (1 s)
$script:prevCpu = $null
function Get-Sample([string]$Label) {
    $raw = (wsl -d docker-desktop -- cat /proc/meminfo /proc/stat) -replace "`0", ''
    $v = @{}
    foreach ($l in $raw) {
        if ($l -match '^(MemTotal|MemAvailable|SwapTotal|SwapFree):\s+(\d+)') { $v[$Matches[1]] = [double]$Matches[2] * 1KB }
        elseif ($l -match '^cpu\s+(.+)$') { $n = $Matches[1].Trim() -split '\s+' | ForEach-Object { [double]$_ }; $v.cpuIdle = $n[3] + $n[4]; $v.cpuTotal = ($n | Measure-Object -Sum).Sum }
    }
    $cpu = $null
    if ($script:prevCpu) { $dt = $v.cpuTotal - $script:prevCpu.t; if ($dt -gt 0) { $cpu = 100 * (1 - ($v.cpuIdle - $script:prevCpu.i) / $dt) } }
    $script:prevCpu = @{ t = $v.cpuTotal; i = $v.cpuIdle }
    $anon = $null
    if ($script:C) { $ms = docker exec $script:C /bin/cat /sys/fs/cgroup/memory.stat 2>$null; $a = $ms | Where-Object { $_ -match '^anon \d+' } | Select-Object -First 1; if ($a) { $anon = [double]($a -split ' ')[1] / 1GB } }
    $s = [pscustomobject]@{
        Time = Get-Date; Label = $Label
        UsedGiB = ($v.MemTotal - $v.MemAvailable) / 1GB; Pct = 100 * ($v.MemTotal - $v.MemAvailable) / $v.MemTotal; TotalGiB = $v.MemTotal / 1GB
        SwapGiB = ($v.SwapTotal - $v.SwapFree) / 1GB
        WinAvailGiB = (New-Object Microsoft.VisualBasic.Devices.ComputerInfo).AvailablePhysicalMemory / 1GB
        CtrAnonGiB = $anon; Cpu = $cpu
    }
    [IO.File]::AppendAllText($SampleFile, [string]::Format($Inv, "{0},{1},{2:F3},{3:F1},{4:F3},{5:F3},{6},{7}`n", $s.Time.ToString('s'), $Label, $s.UsedGiB, $s.Pct, $s.SwapGiB, $s.WinAvailGiB, $(if ($null -ne $anon) { $anon.ToString('F3', $Inv) } else { '' }), $(if ($null -ne $cpu) { $cpu.ToString('F1', $Inv) } else { '' })), $Utf8)
    $s
}
$script:cpuHotSince = $null; $script:cpuAlerts = 0

function Invoke-Measured([string]$Label, [string]$ApiPath, $Body, [int]$TimeoutS) {
    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    $job = Start-Job -ScriptBlock {
        param($c, $json, $path, $tmo)
        $u = New-Object Text.UTF8Encoding $false; $OutputEncoding = $u; [Console]::OutputEncoding = $u
        $json | docker exec -i $c /bin/bash /tmp/localai-post.sh $path $tmo 2>&1 | ForEach-Object { "$_" }
    } -ArgumentList $script:C, $json, $ApiPath, $TimeoutS
    $mon = @{ PeakUsed = 0.0; PeakPct = 0.0; PeakSwap = 0.0; MinWin = [double]::MaxValue; PeakAnon = 0.0; PeakCpu = 0.0; Alert85 = $false; Aborted = $null }
    $t0 = Get-Date
    while ($job.State -eq 'Running') {
        $s = Get-Sample $Label
        if ($s.UsedGiB -gt $mon.PeakUsed) { $mon.PeakUsed = $s.UsedGiB }; if ($s.Pct -gt $mon.PeakPct) { $mon.PeakPct = $s.Pct }
        if ($s.SwapGiB -gt $mon.PeakSwap) { $mon.PeakSwap = $s.SwapGiB }; if ($s.WinAvailGiB -lt $mon.MinWin) { $mon.MinWin = $s.WinAvailGiB }
        if ($null -ne $s.CtrAnonGiB -and $s.CtrAnonGiB -gt $mon.PeakAnon) { $mon.PeakAnon = $s.CtrAnonGiB }
        if ($null -ne $s.Cpu) {
            if ($s.Cpu -gt $mon.PeakCpu) { $mon.PeakCpu = $s.Cpu }
            if ($s.Cpu -gt $TH.cpu_alert_pct) { if (-not $script:cpuHotSince) { $script:cpuHotSince = Get-Date } elseif (((Get-Date) - $script:cpuHotSince).TotalMinutes -ge $TH.cpu_alert_minutes) { $script:cpuAlerts++; Write-Log "ALERTE CPU > $($TH.cpu_alert_pct) % depuis $($TH.cpu_alert_minutes) min ($Label)"; $script:cpuHotSince = Get-Date } }
            else { $script:cpuHotSince = $null }
        }
        if ($s.Pct -ge $TH.wsl_ram_alert_pct -and -not $mon.Alert85) { $mon.Alert85 = $true; Write-Log ("ALERTE RAM WSL2 {0:N1} % ({1})" -f $s.Pct, $Label) }
        if ($s.Pct -ge $TH.wsl_ram_abort_pct) { $mon.Aborted = "RAM WSL2 {0:N1} %" -f $s.Pct }
        elseif ($s.SwapGiB -gt $TH.swap_abort_gib) { $mon.Aborted = "swap {0:N2} Gio" -f $s.SwapGiB }
        elseif ($s.WinAvailGiB -lt $TH.windows_avail_min_gib) { $mon.Aborted = "RAM Windows disponible {0:N2} Gio" -f $s.WinAvailGiB }
        elseif (((Get-Date) - $t0).TotalSeconds -gt ($TimeoutS + 30)) { $mon.Aborted = 'délai dépassé' }
        if ($mon.Aborted) { break }
        $el = ((Get-Date) - $s.Time).TotalMilliseconds; if ($el -lt 1000) { Start-Sleep -Milliseconds (1000 - $el) }
    }
    $wall = ((Get-Date) - $t0).TotalSeconds
    if ($mon.Aborted) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force; Write-Log "INTERRUPTION $Label : $($mon.Aborted)"; Restart-Ollama; return @{ Resp = $null; Raw = ''; Mon = $mon; Wall = $wall } }
    $raw = (Receive-Job $job) -join "`n"; Remove-Job $job -Force
    $resp = $null
    $line = ($raw -split "`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if ($line) { try { $resp = $line | ConvertFrom-Json } catch { $resp = $null } }
    if ($mon.MinWin -eq [double]::MaxValue) { $mon.MinWin = $null }
    @{ Resp = $resp; Raw = $raw; Mon = $mon; Wall = $wall }
}
function Get-Prop($o, [string]$p) { if ($null -ne $o -and ($o.PSObject.Properties.Name -contains $p)) { $o.$p } else { $null } }
function Get-Metrics($resp) {
    $ld = [double](Get-Prop $resp 'load_duration'); $pc = [double](Get-Prop $resp 'prompt_eval_count'); $pd = [double](Get-Prop $resp 'prompt_eval_duration')
    $ec = [double](Get-Prop $resp 'eval_count'); $ed = [double](Get-Prop $resp 'eval_duration'); $td = [double](Get-Prop $resp 'total_duration')
    [ordered]@{
        load_s = [math]::Round($ld / 1e9, 2); prompt_tokens = [int]$pc; prompt_s = [math]::Round($pd / 1e9, 2)
        in_tps = $(if ($pd -gt 0) { [math]::Round($pc / ($pd / 1e9), 1) } else { $null })
        out_tokens = [int]$ec; out_tps = $(if ($ed -gt 0) { [math]::Round($ec / ($ed / 1e9), 2) } else { $null })
        ttft_s = [math]::Round(($ld + $pd) / 1e9, 2); total_s = [math]::Round($td / 1e9, 2)
    }
}

# ------------------------------------------------------------------ evaluation helpers
function Get-CodeBlock([string]$Text, [string[]]$Langs) {
    foreach ($l in $Langs) { $m = [regex]::Match($Text, '```' + $l + '[^\n]*\n([\s\S]*?)```'); if ($m.Success) { return $m.Groups[1].Value } }
    $m = [regex]::Match($Text, '```[^\n]*\n([\s\S]*?)```'); if ($m.Success) { return $m.Groups[1].Value }
    $Text
}
function Invoke-Sandbox([string]$Code, [string]$Tests, [bool]$EvalGen) {
    $mark = 'LAI' + ([guid]::NewGuid().ToString('N').Substring(0, 10))
    $t = $Tests.Replace('echo "PASS ', "echo `"$mark PASS ").Replace('echo "FAIL ', "echo `"$mark FAIL ")
    $script = "IFS= read -r -d '' __GEN <<'__LOCALAI_GEN_EOF__'`n$Code`n__LOCALAI_GEN_EOF__`n"
    if ($EvalGen) { $script += "eval `"`$__GEN`" >/dev/null 2>&1`n" }
    $script += $t
    $name = 'local-ai-bench-sbx-' + $mark.Substring(3, 8).ToLower()
    $out = ("`n" + ($script -replace "`r", '') + "`n") | docker run --rm -i --name $name --label local-ai.temporary=true --network none --read-only `
        --tmpfs "/tmp:size=16m,uid=1000,gid=1000" --cap-drop ALL --security-opt no-new-privileges:true --user 1000:1000 `
        --memory $SB.memory --pids-limit ([int]$SB.pids_limit) --cpus ([string]$SB.cpus) --entrypoint /usr/bin/timeout $SB.image ([string][int]$SB.timeout_s) /bin/bash -s 2>&1 | ForEach-Object { "$_" }
    $lines = @($out | Where-Object { $_ -match "^$mark (PASS|FAIL) " } | ForEach-Object { $_.Substring($mark.Length + 1) })
    $lines
}
function Test-Static($Case, [string]$Text, [string]$WorkDir) {
    $res = @()
    $json = $null; $jsonOk = $false
    # Le contenu JSON est évalué une fois une éventuelle clôture ``` retirée ; la clôture reste pénalisée par raw_json_only.
    $jsonText = [regex]::Replace($Text.Trim(), '^```[a-zA-Z]*\s*\n([\s\S]*?)\n?```$', '$1')
    try { $json = $jsonText.Trim() | ConvertFrom-Json -ErrorAction Stop; $jsonOk = $json -is [pscustomobject] } catch { $jsonOk = $false }
    $subject = if ((Get-Prop $Case 'extract') -eq 'yaml') { Get-CodeBlock $Text @('yaml', 'yml') } else { $Text }
    foreach ($c in $Case.checks) {
        $ok = $false
        switch ($c.type) {
            'regex' { $ok = [regex]::IsMatch($subject, $c.pattern) }
            'not_regex' { $ok = -not [regex]::IsMatch($subject, $c.pattern) }
            'max_words' { $ok = @($Text -split '\s+' | Where-Object { $_ -match '\w' }).Count -le [int]$c.value }
            'json_parse' { $ok = $jsonOk }
            'json_keys_exact' { $ok = $jsonOk -and ((@($json.PSObject.Properties.Name | Sort-Object) -join ',') -eq (@($c.keys | Sort-Object) -join ',')) }
            'json_eq' { $ok = $jsonOk -and ((Get-Prop $json $c.key) -is [string]) -and ((Get-Prop $json $c.key) -ceq $c.value) }
            'json_int' { $v = Get-Prop $json $c.key; $ok = $jsonOk -and ($v -is [int] -or $v -is [long]) -and ($v -eq $c.value) }
            'json_tags' {
                $a = Get-Prop $json $c.key
                $ok = $jsonOk -and ($a -is [array]) -and ($a.Count -eq [int]$c.length) -and (@($a | Where-Object { $_ -isnot [string] -or $_ -cne $_.ToLowerInvariant() -or $c.allowed -notcontains $_ }).Count -eq 0) -and ((@($a) -join ',') -ceq (@([string[]]$a | Sort-Object -CaseSensitive) -join ','))
            }
            'section_bullets' {
                $m = [regex]::Match($Text, '(?ms)^###\s*' + [regex]::Escape($c.section) + '\s*$(.*?)(?=^#{1,6}\s|\z)')
                $ok = $m.Success -and (@($m.Groups[1].Value -split "`n" | Where-Object { $_ -match '^\s*[-*+]\s+\S' }).Count -eq [int]$c.count)
            }
            'compose_valid' {
                $f = Join-Path $WorkDir ("compose-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yaml')
                [IO.File]::WriteAllText($f, $subject, $Utf8)
                $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                docker compose -f $f -p localai-bench-validate config -q --no-interpolate *> $null; $ok = ($LASTEXITCODE -eq 0)
                $ErrorActionPreference = $prev
            }
            default { throw "type de critère inconnu : $($c.type)" }
        }
        $res += [pscustomobject]@{ name = $c.name; pass = [bool]$ok }
    }
    $res
}
function Get-ThinkParam([string]$Tag) { $fam = ($Tag -split ':')[0]; $t = $S.thinking[$fam]; if (-not $t -or $t -eq 'none') { $null } elseif ($t -eq 'false') { $false } elseif ($t -eq 'true') { $true } else { $t } }
function New-GenBody([string]$Tag, [string]$Prompt, [int]$Ctx, [int]$Predict, [hashtable]$Extra) {
    $b = [ordered]@{ model = $Tag; prompt = $Prompt; stream = $false; keep_alive = '10m'
        options = [ordered]@{ num_ctx = $Ctx; num_predict = $Predict; temperature = [double]$RT.temperature; seed = [int]$RT.seed } }
    $th = Get-ThinkParam $Tag; if ($null -ne $th) { $b.think = $th }
    if ($Extra) { foreach ($k in $Extra.Keys) { $b[$k] = $Extra[$k] } }
    $b
}
function New-LongPrompt([int]$Tokens, [string]$Nonce) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("Request id: $Nonce. The following Python module is long; read it carefully.")
    $n = [int][math]::Ceiling($Tokens / 46.0); $k = [int][math]::Floor($n / 3)
    for ($i = 1; $i -le $n; $i++) {
        $val = ($i * 7919 + 1237) % 100000
        [void]$sb.AppendLine("def f_$i(x):"); [void]$sb.AppendLine("    `"`"`"Helper ${i}: transforms the input value.`"`"`"")
        [void]$sb.AppendLine("    MAGIC_TOKEN = $val"); [void]$sb.AppendLine("    y = x * $(($i % 13) + 2) + $(($i * 31) % 97)"); [void]$sb.AppendLine("    return y - MAGIC_TOKEN"); [void]$sb.AppendLine('')
    }
    $answer = [string](($k * 7919 + 1237) % 100000)
    [void]$sb.AppendLine("Question: in function f_$k, what is the value assigned to MAGIC_TOKEN? Answer with the number only.")
    @{ Prompt = $sb.ToString(); Answer = $answer; Functions = $n }
}
function Get-Median([double[]]$x) { $x = @($x | Where-Object { $null -ne $_ } | Sort-Object); if ($x.Count -eq 0) { return $null }; if ($x.Count % 2) { $x[[int][math]::Floor($x.Count / 2)] } else { ($x[$x.Count / 2 - 1] + $x[$x.Count / 2]) / 2 } }
function Get-Capabilities([string]$Tag) {
    $t = (docker exec $script:C /bin/ollama show $Tag) -join "`n"; $i = $t.IndexOf('Capabilities'); if ($i -lt 0) { return @() }
    $seg = $t.Substring($i); $j = $seg.IndexOf("`n`n", 14); if ($j -gt 0) { $seg = $seg.Substring(0, $j) }
    @([regex]::Matches($seg, '(?m)^\s+(completion|tools|insert|thinking|vision|embedding)\b') | ForEach-Object { $_.Groups[1].Value })
}

# ------------------------------------------------------------------ preflight
$free = (Get-PSDrive C).Free / 1GB
if ($free -lt $TH.ssd_min_free_gib) { throw ("SSD libre {0:N1} Gio < {1} Gio : opérations volumineuses bloquées." -f $free, $TH.ssd_min_free_gib) }
Initialize-Client
foreach ($l in Get-Loaded) { $tag = ($l -split '\s+')[0]; Write-Log "déchargement préalable de $tag"; Invoke-Unload $tag }
Start-Sleep 5
$base = Get-Sample 'baseline'; Start-Sleep 1; $base = Get-Sample 'baseline'
Write-Log ("Début {0} | modèles: {1} | base RAM WSL2 {2:N2}/{3:N2} Gio | Windows dispo {4:N2} Gio | SSD {5:N1} Gio" -f $ts, $Models.Count, $base.UsedGiB, $base.TotalGiB, $base.WinAvailGiB, $free)
$memCap = [double]$TH.wsl_ram_alert_pct / 100 * $base.TotalGiB

# ------------------------------------------------------------------ main loop
$results = [ordered]@{}
foreach ($tag in $Models) {
    $R = [ordered]@{ model = $tag; think = $(if ($null -ne (Get-ThinkParam $tag)) { [string](Get-ThinkParam $tag) } else { 'n/a' }); capabilities = @(Get-Capabilities $tag)
        speed = $null; cases = [ordered]@{}; long = [ordered]@{}; contexts = [ordered]@{}; peaks = [ordered]@{}; restitution = $null; errors = @(); aborted = $null }
    $results[$tag] = $R
    if ((Get-PSDrive C).Free / 1GB -lt $TH.ssd_min_free_gib) { $R.aborted = 'SSD sous le seuil'; Write-Log "BLOQUÉ $tag : SSD"; continue }
    $winBefore = (Get-Sample "${tag}:before").WinAvailGiB
    $phase4096 = @{ PeakUsed = 0.0; PeakPct = 0.0; PeakSwap = 0.0; MinWin = [double]::MaxValue; PeakAnon = 0.0; PeakCpu = 0.0; Alert85 = $false }
    $merge = { param($mon) foreach ($k in 'PeakUsed', 'PeakPct', 'PeakSwap', 'PeakAnon', 'PeakCpu') { if ($mon[$k] -gt $phase4096[$k]) { $phase4096[$k] = $mon[$k] } }; if ($null -ne $mon.MinWin -and $mon.MinWin -lt $phase4096.MinWin) { $phase4096.MinWin = $mon.MinWin }; if ($mon.Alert85) { $phase4096.Alert85 = $true } }
    $ctxQ = [int]$RT.quality_num_ctx; $tmo = [int]$RT.request_timeout_s

    # --- speed: cold then warm repeats (short prompt, nonce to defeat prompt cache)
    $speedRuns = @(); $reps = if ($Quick) { 1 } else { [int]$RT.speed_repeats }
    for ($i = 0; $i -le $reps -and -not $R.aborted; $i++) {
        $p = "Request id: $([guid]::NewGuid().ToString('N').Substring(0,8)). Explain in about 150 words how a hash table handles collisions."
        $rq = Invoke-Measured "${tag}:speed$i" '/api/generate' (New-GenBody $tag $p $ctxQ ([int]$RT.speed_num_predict) $null) $tmo
        & $merge $rq.Mon
        if ($rq.Mon.Aborted) { $R.aborted = "speed: $($rq.Mon.Aborted)"; break }
        $err = Get-Prop $rq.Resp 'error'; if ($err -or -not $rq.Resp) { $R.errors += "speed$i : $(if($err){$err}else{'réponse vide'})"; continue }
        $mt = Get-Metrics $rq.Resp; $mt.cold = ($i -eq 0); $speedRuns += [pscustomobject]$mt
        Save-Raw ([ordered]@{ model = $tag; step = "speed$i"; num_ctx = $ctxQ; metrics = $mt; mon = $rq.Mon })
    }
    $cold = $speedRuns | Where-Object { $_.cold } | Select-Object -First 1
    $warm = @($speedRuns | Where-Object { -not $_.cold })
    $R.speed = [ordered]@{
        load_cold_s = $(if ($cold) { $cold.load_s } else { $null }); ttft_cold_s = $(if ($cold) { $cold.ttft_s } else { $null })
        ttft_warm_s = Get-Median ($warm | ForEach-Object { $_.ttft_s }); out_tps = Get-Median ($warm | ForEach-Object { $_.out_tps })
        in_tps_short = Get-Median ($warm | ForEach-Object { $_.in_tps }); repeats = $warm.Count
    }
    Write-Log ("{0} vitesse : chargement {1}s, 1er token froid {2}s / chaud {3}s, sortie {4} tok/s (n={5})" -f $tag, $R.speed.load_cold_s, $R.speed.ttft_cold_s, $R.speed.ttft_warm_s, $R.speed.out_tps, $warm.Count)

    # --- quality cases (ctx 4096)
    foreach ($cid in $QualityOrder) {
        if ($R.aborted) { break }
        $case = $Cases[$cid]
        $entry = [ordered]@{ validation = $case.validation; status = 'done'; score = $null; detail = @() }
        $R.cases[$cid] = $entry
        $req = Get-Prop $case 'requires_capability'
        if ($req -and ($R.capabilities -notcontains $req)) { $entry.status = 'not_supported'; $entry.detail = @("capacité $req absente"); continue }
        switch ($case.kind) {
            'tools' {
                $parts = @()
                foreach ($q in $case.requests) {
                    $body = [ordered]@{ model = $tag; stream = $false; keep_alive = '10m'; tools = $case.tools
                        messages = @(@{ role = 'system'; content = $case.system }, @{ role = 'user'; content = $q.user })
                        options = [ordered]@{ num_ctx = $ctxQ; num_predict = 512; temperature = [double]$RT.temperature; seed = [int]$RT.seed } }
                    $thk = Get-ThinkParam $tag; if ($null -ne $thk) { $body.think = $thk }
                    $rq = Invoke-Measured "${tag}:tools" '/api/chat' $body $tmo; & $merge $rq.Mon
                    if ($rq.Mon.Aborted) { $R.aborted = "tools: $($rq.Mon.Aborted)"; break }
                    $msg = Get-Prop $rq.Resp 'message'; $calls = @(Get-Prop $msg 'tool_calls' | Where-Object { $_ })
                    $sc = 0.0; $d = 'aucun appel d''outil'
                    if ($calls.Count -gt 0) {
                        $f = $calls[0].function; $args0 = $f.arguments; if ($args0 -is [string]) { try { $args0 = $args0 | ConvertFrom-Json } catch {} }
                        $av = [string](Get-Prop $args0 $q.arg)
                        if ($f.name -eq $q.expect_tool) { $sc += 0.5 }; if ($av -match $q.arg_pattern) { $sc += 0.5 }
                        $d = "$($f.name)($($q.arg)=$av)"
                    }
                    $err = Get-Prop $rq.Resp 'error'; if ($err) { $d = "erreur: $err" }
                    $parts += $sc; $entry.detail += $d
                    Save-Raw ([ordered]@{ model = $tag; step = "case:tools"; request = $q.user; score = $sc; detail = $d; metrics = (Get-Metrics $rq.Resp); response = $msg; mon = $rq.Mon })
                }
                if (-not $R.aborted) { $entry.score = ($parts | Measure-Object -Average).Average }
            }
            'fim' {
                $rq = Invoke-Measured "${tag}:fim" '/api/generate' (New-GenBody $tag $case.prefix $ctxQ ([int]$case.num_predict) @{ suffix = $case.suffix }) $tmo; & $merge $rq.Mon
                if ($rq.Mon.Aborted) { $R.aborted = "fim: $($rq.Mon.Aborted)"; break }
                $mid = [string](Get-Prop $rq.Resp 'response'); $err = Get-Prop $rq.Resp 'error'
                if ($err) { $entry.status = 'error'; $entry.detail = @("$err"); $R.errors += "fim: $err"; continue }
                $lines = Invoke-Sandbox ($case.prefix + $mid + $case.suffix) $case.tests $true
                $entry.score = @($lines | Where-Object { $_ -like 'PASS *' }).Count / [double]$case.expected_tests; $entry.detail = $lines
                Save-Raw ([ordered]@{ model = $tag; step = 'case:fim'; response = $mid; tests = $lines; score = $entry.score; metrics = (Get-Metrics $rq.Resp); mon = $rq.Mon })
            }
            default {
                $rq = Invoke-Measured "${tag}:$cid" '/api/generate' (New-GenBody $tag $case.prompt $ctxQ ([int]$RT.quality_num_predict) $null) $tmo; & $merge $rq.Mon
                if ($rq.Mon.Aborted) { $R.aborted = "${cid}: $($rq.Mon.Aborted)"; break }
                $text = [string](Get-Prop $rq.Resp 'response'); $err = Get-Prop $rq.Resp 'error'
                if ($err -or -not $rq.Resp) { $entry.status = 'error'; $entry.detail = @($(if ($err) { "$err" } else { 'réponse vide/délai' })); $R.errors += "${cid}: $($entry.detail -join ' ')"; continue }
                if ($case.kind -eq 'exec') {
                    $code = Get-CodeBlock $text @('bash', 'sh', 'shell')
                    $lines = Invoke-Sandbox $code $case.tests ([bool]$case.eval_gen)
                    $entry.score = @($lines | Where-Object { $_ -like 'PASS *' }).Count / [double]$case.expected_tests; $entry.detail = $lines
                } else {
                    $chk = Test-Static $case $text $Out
                    $entry.score = @($chk | Where-Object pass).Count / [double]@($chk).Count; $entry.detail = @($chk | ForEach-Object { "$($_.name)=$(if($_.pass){'ok'}else{'KO'})" })
                }
                $entry.tokens = (Get-Metrics $rq.Resp).out_tokens
                $entry.truncated = ((Get-Prop $rq.Resp 'done_reason') -eq 'length')
                Save-Raw ([ordered]@{ model = $tag; step = "case:$cid"; think = (Get-Prop $rq.Resp 'thinking'); response = $text; detail = $entry.detail; score = $entry.score; metrics = (Get-Metrics $rq.Resp); done_reason = (Get-Prop $rq.Resp 'done_reason'); mon = $rq.Mon })
            }
        }
        if ($entry.score -ne $null) { Write-Log ("{0} {1} : {2:N2}{3}" -f $tag, $cid, $entry.score, $(if ($entry.Contains('truncated') -and $entry.truncated) { ' (tronqué)' } else { '' })) }
    }

    # --- long contexts : 4096 then 8192 (progressive, margin-gated)
    $ctxList = @(4096, 8192)
    foreach ($ctx in $ctxList) {
        if ($R.aborted) { break }
        if ($ctx -gt 4096) {
            if ($phase4096.Alert85 -or $phase4096.PeakPct -ge $TH.wsl_ram_alert_pct) { $R.contexts["$ctx"] = 'non testé (marge RAM insuffisante : alerte 85 %)'; Write-Log "$tag : $ctx non testé (marge)"; continue }
        }
        $target = if ($ctx -eq 4096) { [int]$RT.long_tokens_4096 } else { [int]$RT.long_tokens_8192 }
        $runs = @()
        for ($i = 0; $i -lt 2; $i++) {
            $lp = New-LongPrompt $target ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $rq = Invoke-Measured "${tag}:long$ctx-$i" '/api/generate' (New-GenBody $tag $lp.Prompt $ctx ([int]$RT.long_num_predict) $null) ([int]$RT.long_timeout_s)
            if ($ctx -eq 4096) { & $merge $rq.Mon }
            if ($rq.Mon.Aborted) { $R.aborted = "long${ctx}: $($rq.Mon.Aborted)"; $R.contexts["$ctx"] = "interrompu ($($rq.Mon.Aborted))"; break }
            $err = Get-Prop $rq.Resp 'error'; if ($err -or -not $rq.Resp) { $R.errors += "long${ctx}: $(if($err){$err}else{'réponse vide/délai'})"; continue }
            $mt = Get-Metrics $rq.Resp; $resp = [string](Get-Prop $rq.Resp 'response')
            $ok = [regex]::IsMatch($resp, '\b' + $lp.Answer + '\b')
            $runs += [pscustomobject]@{ metrics = $mt; correct = $ok; mon = $rq.Mon }
            Save-Raw ([ordered]@{ model = $tag; step = "long$ctx-$i"; num_ctx = $ctx; functions = $lp.Functions; answer = $lp.Answer; response = $resp; correct = $ok; metrics = $mt; mon = $rq.Mon })
        }
        if ($runs.Count) {
            $R.long["$ctx"] = [ordered]@{
                prompt_tokens = Get-Median ($runs | ForEach-Object { $_.metrics.prompt_tokens }); in_tps = Get-Median ($runs | ForEach-Object { $_.metrics.in_tps })
                ttft_s = Get-Median ($runs | ForEach-Object { $_.metrics.ttft_s }); out_tps = Get-Median ($runs | ForEach-Object { $_.metrics.out_tps })
                load_s = ($runs[0].metrics.load_s); total_s = Get-Median ($runs | ForEach-Object { $_.metrics.total_s })
                needle = (@($runs | Where-Object correct).Count / [double]$runs.Count)
                peak_wsl_gib = [math]::Round((($runs | ForEach-Object { $_.mon.PeakUsed }) | Measure-Object -Maximum).Maximum, 2)
                peak_pct = [math]::Round((($runs | ForEach-Object { $_.mon.PeakPct }) | Measure-Object -Maximum).Maximum, 1)
                peak_swap_gib = [math]::Round((($runs | ForEach-Object { $_.mon.PeakSwap }) | Measure-Object -Maximum).Maximum, 2)
                peak_ctr_anon_gib = [math]::Round((($runs | ForEach-Object { $_.mon.PeakAnon }) | Measure-Object -Maximum).Maximum, 2)
            }
            if (-not $R.contexts.Contains("$ctx")) { $R.contexts["$ctx"] = $(if ($R.long["$ctx"].peak_pct -lt $TH.wsl_ram_abort_pct -and $R.long["$ctx"].peak_swap_gib -le $TH.swap_abort_gib) { 'validé' } else { 'non validé (seuil)' }) }
            Write-Log ("{0} contexte {1} : {2} tokens, entrée {3} tok/s, 1er token {4}s, aiguille {5:P0}, pic {6:N1} % RAM" -f $tag, $ctx, $R.long["$ctx"].prompt_tokens, $R.long["$ctx"].in_tps, $R.long["$ctx"].ttft_s, $R.long["$ctx"].needle, $R.long["$ctx"].peak_pct)
        }
    }
    $R.peaks = [ordered]@{ wsl_used_gib_4096 = [math]::Round($phase4096.PeakUsed, 2); wsl_pct_4096 = [math]::Round($phase4096.PeakPct, 1); swap_gib = [math]::Round($phase4096.PeakSwap, 2)
        ctr_anon_gib_4096 = [math]::Round($phase4096.PeakAnon, 2); win_avail_min_gib = $(if ($phase4096.MinWin -ne [double]::MaxValue) { [math]::Round($phase4096.MinWin, 2) } else { $null }); cpu_peak_pct = [math]::Round($phase4096.PeakCpu, 0) }

    # --- unload + short restitution
    Invoke-Unload $tag; Start-Sleep 10
    $after = Get-Sample "${tag}:after"
    $R.restitution = [ordered]@{ win_avail_before_gib = [math]::Round($winBefore, 2); win_avail_min_gib = $R.peaks.win_avail_min_gib; win_avail_after10s_gib = [math]::Round($after.WinAvailGiB, 2); wsl_used_after10s_gib = [math]::Round($after.UsedGiB, 2); loaded_after = @(Get-Loaded).Count }
    Write-Log ("{0} terminé : pic RAM WSL2 (4096) {1:N2} Gio ({2:N1} %), conteneur {3:N2} Gio ; après déchargement +10 s : Windows dispo {4:N2} Gio{5}" -f $tag, $R.peaks.wsl_used_gib_4096, $R.peaks.wsl_pct_4096, $R.peaks.ctr_anon_gib_4096, $after.WinAvailGiB, $(if ($R.aborted) { " | INTERROMPU: $($R.aborted)" } else { '' }))
}

# ------------------------------------------------------------------ final restitution (idle, cache not flushed)
$rest = @(); $restT0 = Get-Date
foreach ($wt in 0, 60, 180, 300) {
    if ($Quick -and $wt -gt 0) { break }
    $wait = $wt - ((Get-Date) - $restT0).TotalSeconds; if ($wait -gt 0) { Start-Sleep -Seconds ([int][math]::Ceiling($wait)) }
    $smp = Get-Sample "restitution+$wt"
    $rest += [ordered]@{ t_s = $wt; win_avail_gib = [math]::Round($smp.WinAvailGiB, 2); wsl_used_gib = [math]::Round($smp.UsedGiB, 2); ctr_anon_gib = $(if ($null -ne $smp.CtrAnonGiB) { [math]::Round($smp.CtrAnonGiB, 2) } else { $null }) }
}
Get-ChildItem $Out -Filter 'compose-*.yaml' | Remove-Item -Force
$left = @(docker ps -aq --filter label=local-ai.temporary=true --filter name=local-ai-bench-sbx-)
if ($left.Count) { docker rm -f $left | Out-Null; $Anomalies.Add("$($left.Count) bac(s) à sable résiduel(s) supprimé(s)") }

# ------------------------------------------------------------------ merge (modèles complets d'une exécution précédente, non relancés)
function ConvertTo-OrderedHash($o) {
    if ($o -is [System.Management.Automation.PSCustomObject]) { $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-OrderedHash $p.Value }; return $h }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return , @($o | ForEach-Object { ConvertTo-OrderedHash $_ }) }
    $o
}
$merged = @()
if ($MergeFrom) {
    $prev = [IO.File]::ReadAllText((Join-Path $MergeFrom 'summary.json'), $Utf8) | ConvertFrom-Json
    $all = [ordered]@{}
    foreach ($t in $allTags) {
        if ($results.Contains($t)) { $all[$t] = $results[$t] }
        elseif ($prev.models.PSObject.Properties.Name -contains $t -and -not $prev.models.$t.aborted) {
            $h = ConvertTo-OrderedHash $prev.models.$t; $h.errors = @($h.errors | Where-Object { $_ }); $h.source_run = $prev.run; $all[$t] = $h; $merged += $t
        }
    }
    $results = $all
    if ($merged.Count) { $Anomalies.Add("$($merged.Count) modèle(s) repris de l'exécution $($prev.run) (non relancés) : $($merged -join ', ')") }
}

# ------------------------------------------------------------------ scoring
function Clamp01([double]$x) { [math]::Max(0.0, [math]::Min(1.0, $x)) }
$W = $S.weights
$catCases = @{ code = @('code_gen', 'debug', 'qa', 'fim', 'devops'); reasoning = @('review', 'security', 'architecture', 'multifile', 'long_4096', 'long_8192'); instructions = @('instructions', 'documentation'); tools = @('tools') }
$summary = @()
foreach ($tag in $results.Keys) {
    $R = $results[$tag]
    $cs = @{}
    foreach ($k in $R.cases.Keys) { if ($R.cases[$k].status -eq 'done' -and $null -ne $R.cases[$k].score) { $cs[$k] = [double]$R.cases[$k].score } }
    foreach ($ctx in $R.long.Keys) { $cs["long_$ctx"] = [double]$R.long[$ctx].needle }
    $cat = [ordered]@{}
    foreach ($c in $catCases.Keys) { $v = @($catCases[$c] | Where-Object { $cs.ContainsKey($_) } | ForEach-Object { $cs[$_] }); $cat[$c] = $(if ($v.Count) { ($v | Measure-Object -Average).Average } else { $null }) }
    $sp = $null
    if ($R.speed -and $R.speed.out_tps) {
        $p1 = Clamp01 ($R.speed.out_tps / [double]$NORM.speed_out_tps_target)
        $p2 = if ($R.speed.ttft_warm_s) { Clamp01 ([double]$NORM.speed_ttft_short_target_s / [math]::Max(0.01, $R.speed.ttft_warm_s)) } else { $null }
        $p3 = if ($R.long.Contains('4096')) { Clamp01 ([double]$NORM.speed_ttft_long_target_s / [math]::Max(0.01, $R.long['4096'].ttft_s)) } else { $null }
        $parts = @(@($p1, [double]$NORM.speed_weight_out_tps), @($p2, [double]$NORM.speed_weight_ttft_short), @($p3, [double]$NORM.speed_weight_ttft_long)) | Where-Object { $null -ne $_[0] }
        $sp = ($parts | ForEach-Object { $_[0] * $_[1] } | Measure-Object -Sum).Sum / ($parts | ForEach-Object { $_[1] } | Measure-Object -Sum).Sum
    }
    $cat.speed = $sp
    $cat.memory = if ($R.peaks.wsl_used_gib_4096 -gt 0) { Clamp01 (1 - ($R.peaks.wsl_used_gib_4096 - $base.UsedGiB) / ($memCap - $base.UsedGiB)) } else { $null }
    $num = 0.0; $den = 0.0
    foreach ($c in 'code', 'reasoning', 'speed', 'memory', 'tools', 'instructions') { if ($null -ne $cat[$c]) { $num += [double]$W[$c] * $cat[$c]; $den += [double]$W[$c] } }
    $score = if ($den -gt 0) { [math]::Round(100 * $num / $den, 1) } else { $null }
    $metric = @{}; foreach ($k in $cs.Keys) { $metric[$k] = $cs[$k] }
    $lv = @($cs.Keys | Where-Object { $_ -like 'long_*' } | ForEach-Object { $cs[$_] }); if ($lv.Count) { $metric.long = ($lv | Measure-Object -Average).Average }
    if ($null -ne $cat.speed) { $metric.speed = $cat.speed }; if ($null -ne $cat.memory) { $metric.memory = $cat.memory }; if ($null -ne $cat.instructions) { $metric.instructions = $cat.instructions }
    $roleScores = [ordered]@{}
    foreach ($role in $S.roles.Keys) {
        $rw = $S.roles[$role]
        if ($rw.ContainsKey('fim') -and -not $metric.ContainsKey('fim')) { $roleScores[$role] = $null; continue }
        $n2 = 0.0; $d2 = 0.0; foreach ($k in $rw.Keys) { if ($metric.ContainsKey($k)) { $n2 += [double]$rw[$k] * $metric[$k]; $d2 += [double]$rw[$k] } }
        $roleScores[$role] = $(if ($d2 -gt 0) { [math]::Round(100 * $n2 / $d2, 1) } else { $null })
    }
    $R.categories = $cat; $R.score = $score; $R.role_scores = $roleScores; $R.weights_used = $den
    $summary += [pscustomobject]([ordered]@{
            model = $tag; score = $score; code = $(if ($null -ne $cat.code) { [math]::Round(100 * $cat.code, 0) } else { $null }); reasoning = $(if ($null -ne $cat.reasoning) { [math]::Round(100 * $cat.reasoning, 0) } else { $null })
            instructions = $(if ($null -ne $cat.instructions) { [math]::Round(100 * $cat.instructions, 0) } else { $null }); tools = $(if ($null -ne $cat.tools) { [math]::Round(100 * $cat.tools, 0) } else { $null })
            speed = $(if ($null -ne $cat.speed) { [math]::Round(100 * $cat.speed, 0) } else { $null }); memory = $(if ($null -ne $cat.memory) { [math]::Round(100 * $cat.memory, 0) } else { $null })
            out_tps = $R.speed.out_tps; ttft_warm_s = $R.speed.ttft_warm_s; load_cold_s = $R.speed.load_cold_s
            in_tps_4096 = $(if ($R.long.Contains('4096')) { $R.long['4096'].in_tps } else { $null }); ttft_4096_s = $(if ($R.long.Contains('4096')) { $R.long['4096'].ttft_s } else { $null })
            in_tps_8192 = $(if ($R.long.Contains('8192')) { $R.long['8192'].in_tps } else { $null }); ttft_8192_s = $(if ($R.long.Contains('8192')) { $R.long['8192'].ttft_s } else { $null })
            peak_wsl_gib_4096 = $R.peaks.wsl_used_gib_4096; peak_pct_4096 = $R.peaks.wsl_pct_4096
            peak_wsl_gib_8192 = $(if ($R.long.Contains('8192')) { $R.long['8192'].peak_wsl_gib } else { $null }); peak_pct_8192 = $(if ($R.long.Contains('8192')) { $R.long['8192'].peak_pct } else { $null })
            ctx_4096 = $(if ($R.contexts.Contains('4096')) { $R.contexts['4096'] } else { 'non testé' }); ctx_8192 = $(if ($R.contexts.Contains('8192')) { $R.contexts['8192'] } else { 'non testé' })
            aborted = $R.aborted; errors = ($R.errors -join ' | ')
        })
}
$ranking = [ordered]@{}
foreach ($role in $S.roles.Keys) {
    $ranked = @($results.Values | Where-Object { $null -ne $_.role_scores[$role] } | Sort-Object { $_.role_scores[$role] } -Descending | ForEach-Object { [ordered]@{ model = $_.model; score = $_.role_scores[$role] } })
    $ranking[$role] = [ordered]@{ principal = $(if ($ranked.Count) { $ranked[0] } else { $null }); alternatives = @($ranked | Select-Object -Skip 1 -First 2); all = $ranked }
}
$doc = [ordered]@{
    suite_version = $S.suite_version; run = $ts; quick = [bool]$Quick; profile = $RT.profile; merged_from = $(if ($merged.Count) { $prev.run } else { $null }); merged_models = @($merged)
    environment = [ordered]@{ wsl_total_gib = [math]::Round($base.TotalGiB, 2); baseline_wsl_used_gib = [math]::Round($base.UsedGiB, 2); baseline_win_avail_gib = [math]::Round($base.WinAvailGiB, 2); ssd_free_start_gib = [math]::Round($free, 2); ssd_free_end_gib = [math]::Round((Get-PSDrive C).Free / 1GB, 2); cpu_alerts = $script:cpuAlerts }
    weights = $W; models = $results; ranking = $ranking; restitution_final = $rest; anomalies = @($Anomalies)
}
($doc | ConvertTo-Json -Depth 12) | ForEach-Object { [IO.File]::WriteAllText((Join-Path $Out 'summary.json'), $_, $Utf8) }
$summary | Export-Csv (Join-Path $Out 'summary.csv') -NoTypeInformation -Encoding UTF8
if (-not $NoSummary -and -not $Quick) {
    Copy-Item (Join-Path $Out 'summary.json') (Join-Path $Here 'summary.json') -Force
    Copy-Item (Join-Path $Out 'summary.csv') (Join-Path $Here 'summary.csv') -Force
}
Write-Log ("Fin : {0} modèle(s) ; résultats {1} ; Ollama chargés : {2}" -f $results.Count, $Out, @(Get-Loaded).Count)

$bad = @($results.Values | Where-Object { $_.aborted }).Count
exit $(if ($bad) { 3 } else { 0 })
