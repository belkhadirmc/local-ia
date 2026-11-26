# Supervision légère (12.B.1) — dot-sourcé par local-ai.ps1. Commandes : monitor status | watch [secondes] [nombre].
# Aucun service résident : un échantillon par appel (CIM Windows + /proc de la VM WSL2 + ollama ps), historique JSONL local,
# seuils validés de config/monitoring/thresholds.yaml (ADR-0001), rétention 7 j métriques / 30 j audit. Aucune suppression critique.
$MonDir = Join-Path $Root 'runtime\monitor'
$MonState = Join-Path $Root 'runtime\state\monitor.json'

function Get-Thresholds {
    $t = [IO.File]::ReadAllText((Join-Path $Root 'config\monitoring\thresholds.yaml'))
    $n = { param($sec, $k) [double]([regex]::Match($t, "(?m)^$sec\s*:\s*\n(?:\s+\S.*\n)*?\s+$k\s*:\s*([\d.]+)")).Groups[1].Value }
    [pscustomobject]@{ SsdWarn = & $n 'disk_ssd_free_gib' 'warning'; SsdCrit = & $n 'disk_ssd_free_gib' 'critical'; SsdEmerg = & $n 'disk_ssd_free_gib' 'emergency'
        WslWarn = & $n 'wsl2_ram_percent' 'warning'; WslCrit = & $n 'wsl2_ram_percent' 'critical'
        Cpu = & $n 'cpu_percent' 'threshold'; CpuMin = & $n 'cpu_percent' 'duration_minutes'
        WinMin = [double]([regex]::Match($t, '(?m)^windows_ram_free_min_gib:\s*([\d.]+)')).Groups[1].Value
        SwapMax = [double]([regex]::Match($t, '(?m)^swap_used_max_gib:\s*([\d.]+)')).Groups[1].Value
        MetricsDays = & $n 'retention' 'metrics_days'; AuditDays = & $n 'retention' 'audit_days' }
}
function Get-RefThroughput([string]$Model) {
    $f = Join-Path $Root 'config\monitoring\throughput.yaml'; if (-not (Test-Path $f)) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($f), "(?m)^\s+`"?$([regex]::Escape($Model))`"?:\s*([\d.]+)"); if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
}
function Get-MonitorSample {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = [math]::Round((@(Get-CimInstance Win32_Processor) | Measure-Object LoadPercentage -Average).Average, 0)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $s = [ordered]@{ ts = (Get-Date).ToString('s'); cpu_pct = $cpu
        win_avail_gib = [math]::Round($os.FreePhysicalMemory / 1MB, 2); win_total_gib = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        ssd_free_gib = [math]::Round($disk.FreeSpace / 1GB, 1)
        wsl_total_gib = $null; wsl_used_gib = $null; wsl_pct = $null; wsl_cache_gib = $null; swap_used_gib = $null; wsl_cpus = $null
        model = $null; model_size = $null; inference = 'indisponible'; ref_tps = $null; containers = '' }
    if (Test-DockerEngine) {
        $mi = @{}; foreach ($l in (((Invoke-Native wsl @('-d', 'docker-desktop', '--', 'cat', '/proc/meminfo')).Output -replace "`0", '') -split "`n")) { if ($l -match '^(\w+):\s+(\d+)') { $mi[$Matches[1]] = [double]$Matches[2] / 1MB } }
        if ($mi.Count) { $s.wsl_total_gib = [math]::Round($mi.MemTotal, 2); $s.wsl_used_gib = [math]::Round($mi.MemTotal - $mi.MemAvailable, 2)
            $s.wsl_pct = [math]::Round(100 * ($mi.MemTotal - $mi.MemAvailable) / $mi.MemTotal, 1); $s.wsl_cache_gib = [math]::Round($mi.Cached, 2); $s.swap_used_gib = [math]::Round($mi.SwapTotal - $mi.SwapFree, 2) }
        $s.wsl_cpus = (Invoke-Native docker @('info', '--format', '{{.NCPU}}')).Output.Trim()
        $s.containers = ((Invoke-Native docker @('ps', '--filter', 'name=local-ai-', '--format', '{{.Names}}={{.Status}}')).Output -split "`n" | Where-Object { $_ } | ForEach-Object { $n, $st = $_ -split '=', 2; "$($n -replace '^local-ai-' -replace '-1$'):$(if ($st -match 'unhealthy') { 'KO' } elseif ($st -match 'healthy|Up') { 'ok' } else { '?' })" }) -join ' '
        try { $c = Get-OllamaContainer; $ps = @((Invoke-Native docker @('exec', $c, '/bin/ollama', 'ps')).Output -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() })
            if ($ps.Count) { $f = $ps[0] -split '\s{2,}'; $s.model = $f[0]; $s.model_size = $f[2]; $s.inference = 'occupée (1 modèle max)'; $s.ref_tps = Get-RefThroughput $f[0] }
            else { $s.inference = 'libre' } } catch { $s.inference = 'Ollama arrêté' }
    }
    [pscustomobject]$s
}
function Get-MonitorAlerts($S, $T) {
    $a = New-Object System.Collections.Generic.List[object]
    $add = { param($lvl, $msg) $a.Add([pscustomobject]@{ Niveau = $lvl; Alerte = $msg }) }
    if ($S.ssd_free_gib -le $T.SsdEmerg) { & $add 'urgence' "SSD libre $($S.ssd_free_gib) Gio <= $($T.SsdEmerg) : proposer emergency-stop (validation manuelle)" }
    elseif ($S.ssd_free_gib -le $T.SsdCrit) { & $add 'critique' "SSD libre $($S.ssd_free_gib) Gio <= $($T.SsdCrit)" }
    elseif ($S.ssd_free_gib -le $T.SsdWarn) { & $add 'alerte' "SSD libre $($S.ssd_free_gib) Gio <= $($T.SsdWarn)" }
    if ($null -ne $S.wsl_pct) { if ($S.wsl_pct -ge $T.WslCrit) { & $add 'critique' "RAM WSL2 $($S.wsl_pct) % >= $($T.WslCrit) %" } elseif ($S.wsl_pct -ge $T.WslWarn) { & $add 'alerte' "RAM WSL2 $($S.wsl_pct) % >= $($T.WslWarn) %" } }
    if ($S.win_avail_gib -lt $T.WinMin) { & $add 'critique' "RAM Windows libre $($S.win_avail_gib) Gio < $($T.WinMin) Gio" }
    if ($null -ne $S.swap_used_gib -and $S.swap_used_gib -gt $T.SwapMax) { & $add 'alerte' "swap $($S.swap_used_gib) Gio > $($T.SwapMax) Gio" }
    # CPU soutenu : tous les échantillons de l'historique des N dernières minutes (au moins 3) au-dessus du seuil
    $since = (Get-Date).AddMinutes(-$T.CpuMin); $hist = @(Get-MonitorHistory | Where-Object { [datetime]$_.ts -ge $since }) + @($S)
    if ($hist.Count -ge 3 -and -not @($hist | Where-Object { $_.cpu_pct -lt $T.Cpu }).Count) { & $add 'alerte' "CPU >= $($T.Cpu) % soutenu sur $($T.CpuMin) min" }
    $a.ToArray()
}
function Get-MonitorHistory {
    $f = Join-Path $MonDir ("metrics-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd')); if (-not (Test-Path $f)) { return @() }
    @(Get-Content $f -Tail 120 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
}
function Save-MonitorSample($S, $Alerts) {
    New-Item -ItemType Directory -Force $MonDir, (Split-Path $MonState) | Out-Null
    $u = New-Object Text.UTF8Encoding $false
    $rec = [ordered]@{}; foreach ($p in $S.PSObject.Properties) { $rec[$p.Name] = $p.Value }; $rec.alerts = @($Alerts | ForEach-Object { "$($_.Niveau): $($_.Alerte)" })
    [IO.File]::AppendAllText((Join-Path $MonDir ("metrics-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))), (($rec | ConvertTo-Json -Compress) + "`n"), $u)
    $lvl = if (@($Alerts | Where-Object Niveau -eq 'urgence').Count) { 'urgence' } elseif (@($Alerts | Where-Object Niveau -eq 'critique').Count) { 'critique' } elseif (@($Alerts).Count) { 'alerte' } else { 'ok' }
    $prev = if (Test-Path $MonState) { try { (Get-Content $MonState -Raw | ConvertFrom-Json).level } catch { 'ok' } } else { 'ok' }
    [IO.File]::WriteAllText($MonState, ([ordered]@{ ts = $S.ts; level = $lvl; alerts = $rec.alerts } | ConvertTo-Json -Compress), $u)
    if ($lvl -ne $prev -and $lvl -in 'critique', 'urgence') { Write-Audit 'monitor' $lvl 'alerte' ($rec.alerts -join ' ; ') }
    $lvl
}
function Invoke-MonitorRetention($T) {
    # Métriques : fichiers journaliers de plus de 7 jours supprimés (non critiques). Audit : entrées de plus de 30 jours retirées
    # de audit.jsonl, opération elle-même journalisée. Jamais de suppression de modèle, volume, session ou sauvegarde.
    $lim = (Get-Date).Date.AddDays(-$T.MetricsDays)
    Get-ChildItem $MonDir -Filter 'metrics-*.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^metrics-(\d{8})$' -and [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null) -lt $lim } | Remove-Item -Force
    $af = Join-Path $Root 'runtime\logs\audit.jsonl'
    if (Test-Path $af) {
        $alim = (Get-Date).AddDays(-$T.AuditDays); $lines = [IO.File]::ReadAllLines($af)
        $keep = @($lines | Where-Object { $m = [regex]::Match($_, '"ts":"([^"]+)"'); -not $m.Success -or [datetime]$m.Groups[1].Value -ge $alim })
        if ($keep.Count -lt $lines.Count) { [IO.File]::WriteAllLines($af, [string[]]$keep, (New-Object Text.UTF8Encoding $false)); Write-Audit 'monitor retention' 'audit' 'ok' "$($lines.Count - $keep.Count) entrée(s) > $($T.AuditDays) j retirée(s)" }
    }
}
function Assert-ResourcesOk {
    # Seuil critique : blocage des nouveaux chargements de modèle déclenchés par local-ai (continue on, microtests).
    $T = Get-Thresholds; $S = Get-MonitorSample; $al = @(Get-MonitorAlerts $S $T | Where-Object { $_.Niveau -in 'critique', 'urgence' })
    if ($al.Count) { throw "Ressources critiques, chargement de modèle bloqué : $(($al | ForEach-Object Alerte) -join ' ; ')" }
}
function Format-MonitorLine($S, [string]$Lvl) {
    '{0:HH:mm:ss} [{1}] CPU {2}% | Win libre {3} Gio | WSL2 {4}/{5} Gio ({6}%, cache {7}) | swap {8} | SSD {9} Gio | modèle {10} | inférence {11}{12}' -f ([datetime]$S.ts), $Lvl, $S.cpu_pct, $S.win_avail_gib,
        $S.wsl_used_gib, $S.wsl_total_gib, $S.wsl_pct, $S.wsl_cache_gib, $S.swap_used_gib, $S.ssd_free_gib, $(if ($S.model) { "$($S.model) ($($S.model_size))" } else { 'aucun' }), $S.inference,
        $(if ($S.ref_tps) { ", ~$($S.ref_tps) t/s attendus" } else { '' })
}
function Invoke-Monitor {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'status' }
    $T = Get-Thresholds
    switch ($sub) {
        'status' {
            $S = Get-MonitorSample; $al = @(Get-MonitorAlerts $S $T); $lvl = Save-MonitorSample $S $al; Invoke-MonitorRetention $T
            [pscustomobject]@{ Mesure = 'CPU Windows (charge)'; Valeur = "$($S.cpu_pct) % (seuil $($T.Cpu) % sur $($T.CpuMin) min)" }
            [pscustomobject]@{ Mesure = 'RAM Windows libre'; Valeur = "$($S.win_avail_gib) / $($S.win_total_gib) Gio (min $($T.WinMin))" }
            [pscustomobject]@{ Mesure = 'RAM WSL2 hors cache'; Valeur = "$($S.wsl_used_gib) / $($S.wsl_total_gib) Gio = $($S.wsl_pct) % (alerte $($T.WslWarn), critique $($T.WslCrit)) ; cache $($S.wsl_cache_gib) Gio ; $($S.wsl_cpus) vCPU" }
            [pscustomobject]@{ Mesure = 'Swap WSL2'; Valeur = "$($S.swap_used_gib) Gio (max $($T.SwapMax))" }
            [pscustomobject]@{ Mesure = 'SSD C: libre'; Valeur = "$($S.ssd_free_gib) Gio (alerte $($T.SsdWarn), critique $($T.SsdCrit), urgence $($T.SsdEmerg))" }
            [pscustomobject]@{ Mesure = 'Modèle actif'; Valeur = $(if ($S.model) { "$($S.model) ($($S.model_size))" } else { 'aucun' }) }
            [pscustomobject]@{ Mesure = 'Débit disponible'; Valeur = "inférence $($S.inference)$(if ($S.ref_tps) { " ; référence $($S.ref_tps) t/s (12.B.1/6.B.1)" })" }
            [pscustomobject]@{ Mesure = 'Conteneurs'; Valeur = $S.containers }
            [pscustomobject]@{ Mesure = 'Niveau'; Valeur = "$lvl$(if ($al.Count) { ' : ' + (($al | ForEach-Object { "$($_.Niveau) $($_.Alerte)" }) -join ' ; ') })" }
        }
        'watch' {
            $iv = if ($Args0.Count -ge 2) { [math]::Max(5, [int]$Args0[1]) } else { 15 }; $n = if ($Args0.Count -ge 3) { [int]$Args0[2] } else { 0 }
            Invoke-MonitorRetention $T; Write-Output "Supervision toutes les $iv s$(if ($n) { ", $n mesures" } else { ' (Ctrl+C pour arrêter)' }). Historique : runtime\monitor\"
            for ($i = 1; $n -eq 0 -or $i -le $n; $i++) {
                $S = Get-MonitorSample; $al = @(Get-MonitorAlerts $S $T); $lvl = Save-MonitorSample $S $al
                Write-Output (Format-MonitorLine $S $lvl); foreach ($x in $al) { Write-Output "    ! $($x.Niveau) : $($x.Alerte)" }
                if ($n -eq 0 -or $i -lt $n) { Start-Sleep $iv }
            }
        }
        default { throw 'Usage : monitor status | watch [secondes>=5] [nombre]' }
    }
}
