# Profils de performance A/B/C (12.B.1) — dot-sourcé par local-ai.ps1. Commandes : profile list | show <id> | apply <id> --confirm.
# apply : refus si arrêt d'urgence, modèle chargé ou inférence ; BK1 (.wslconfig, ollama.env, defaults.yaml) ; écriture ;
# redémarrage WSL2/Docker seulement si .wslconfig change, sinon recréation du seul conteneur ollama ; vérification ; rollback si échec.
$PerfDir = Join-Path $Root 'profiles\performance'
$OllamaEnvFile = Join-Path $Root 'config\ollama\ollama.env'
$WslConfigFile = Join-Path $env:USERPROFILE '.wslconfig'
$PerfOllamaKeys = 'OLLAMA_CONTEXT_LENGTH', 'OLLAMA_KEEP_ALIVE', 'OLLAMA_KV_CACHE_TYPE', 'OLLAMA_NUM_PARALLEL', 'OLLAMA_MAX_LOADED_MODELS'
$PerfWslKeys = 'memory', 'processors', 'swap'

function Get-PerfProfile([string]$Id) {
    $Id = $Id.ToUpperInvariant(); $f = Join-Path $PerfDir "$Id.yaml"
    if ($Id -notmatch '^[ABC]$' -or -not (Test-Path $f)) { throw "Profil de performance inconnu : $Id (A, B ou C)." }
    $t = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
    $get = { param($k) $m = [regex]::Match($t, "(?m)^\s+$([regex]::Escape($k)):\s*`"?([^`"\r\n#]+?)`"?\s*$"); if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null } }
    $p = [ordered]@{ id = $Id; file = $f; label = ([regex]::Match($t, '(?m)^label:\s*"?([^"\r\n]+)')).Groups[1].Value
        status = ([regex]::Match($t, '(?m)^status:\s*(\S+)')).Groups[1].Value; note = ([regex]::Match($t, '(?m)^note:\s*"?([^"\r\n]+)')).Groups[1].Value
        wsl = [ordered]@{}; ollama = [ordered]@{} }
    foreach ($k in $PerfWslKeys) { $p.wsl[$k] = & $get $k }
    foreach ($k in $PerfOllamaKeys) { $p.ollama[$k] = & $get $k }
    [pscustomobject]$p
}
function Get-WslConfigValues {
    $v = [ordered]@{}; $t = if (Test-Path $WslConfigFile) { [IO.File]::ReadAllText($WslConfigFile) } else { '' }
    foreach ($k in $PerfWslKeys) { $m = [regex]::Match($t, "(?m)^\s*$k\s*=\s*(\S+)"); $v[$k] = if ($m.Success) { $m.Groups[1].Value } else { $null } }
    $v
}
function Get-OllamaEnvValues {
    $v = [ordered]@{}; $t = [IO.File]::ReadAllText($OllamaEnvFile)
    foreach ($k in $PerfOllamaKeys) { $m = [regex]::Match($t, "(?m)^$k=(\S*)"); $v[$k] = if ($m.Success) { $m.Groups[1].Value } else { $null } }
    $v
}
function Get-PerfDiff($P) {
    $w = Get-WslConfigValues; $o = Get-OllamaEnvValues; $d = @()
    foreach ($k in $PerfWslKeys) { if ("$($w[$k])" -ne "$($P.wsl[$k])") { $d += [pscustomobject]@{ Cible = '.wslconfig'; Cle = $k; Actuel = $w[$k]; Profil = $P.wsl[$k] } } }
    foreach ($k in $PerfOllamaKeys) { if ("$($o[$k])" -ne "$($P.ollama[$k])") { $d += [pscustomobject]@{ Cible = 'ollama.env'; Cle = $k; Actuel = $o[$k]; Profil = $P.ollama[$k] } } }
    , $d
}
function Get-AppliedPerfId { foreach ($id in 'A', 'B', 'C') { if ((Get-PerfDiff (Get-PerfProfile $id)).Count -eq 0) { return $id } }; $null }

function Set-KeyValueFile([string]$Path, [string]$Sep, [hashtable]$Values) {
    $u = New-Object Text.UTF8Encoding $false; $t = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    foreach ($k in $Values.Keys) {
        $pat = "(?m)^(\s*)$([regex]::Escape($k))\s*$([regex]::Escape($Sep))\s*\S*"
        if ([regex]::IsMatch($t, $pat)) { $t = [regex]::Replace($t, $pat, "`${1}$k$Sep$($Values[$k])") }
        elseif ($Sep -eq '=' -and $Path -eq $WslConfigFile) { $t = [regex]::Replace($t, '(?m)^\[wsl2\]\s*$', "[wsl2]`n$k=$($Values[$k])") }
        else { $t = $t.TrimEnd("`n") + "`n$k$Sep$($Values[$k])`n" }
    }
    if ($Path -eq $WslConfigFile) { $t = $t -replace "`n", "`r`n" }
    [IO.File]::WriteAllText($Path, $t, $u)
}
function Restart-DockerWsl {
    # Séquence validée en 12.B.1 : arrêt Docker Desktop, wsl --shutdown, attente de l'arrêt effectif, redémarrage (1 nouvel essai).
    for ($try = 1; $try -le 2; $try++) {
        Invoke-Native docker @('desktop', 'stop', '--timeout', '120') | Out-Null
        Invoke-Native wsl @('--shutdown') | Out-Null
        for ($i = 0; $i -lt 30; $i++) { $l = ((Invoke-Native wsl @('-l', '-v')).Output -replace "`0", ''); if ($l -notmatch 'Running') { break }; Start-Sleep 2 }
        Start-Sleep 8
        Invoke-Native docker @('desktop', 'start', '--timeout', '300') | Out-Null
        for ($i = 0; $i -lt 60; $i++) { if (Test-DockerEngine) { return }; Start-Sleep 5 }
    }
    throw 'Docker Desktop ne redémarre pas.'
}
function Test-PerfApplied($P) {
    $err = @()
    $info = (Invoke-Native docker @('info', '--format', '{{.NCPU}} {{.MemTotal}}')).Output.Trim() -split ' '
    if ($info[0] -ne $P.wsl.processors) { $err += "CPU WSL2 : $($info[0]) au lieu de $($P.wsl.processors)" }
    $memWanted = [double]($P.wsl.memory -replace '[^\d.]', ''); $memGot = [double]$info[1] / 1GB
    if ([math]::Abs($memGot - $memWanted) -gt 1.5) { $err += ('RAM WSL2 : {0:N1} Gio au lieu de {1}' -f $memGot, $P.wsl.memory) }
    $c = Get-OllamaContainer
    # Variables effectives du conteneur via docker inspect (aucun guillemet dans les arguments natifs : PowerShell 5.1 les altère)
    $envIn = @((Invoke-Native docker @('inspect', '--format', '{{range .Config.Env}}{{println .}}{{end}}', $c)).Output -split "`n" | ForEach-Object { $_.Trim() })
    foreach ($k in $PerfOllamaKeys) { if ($envIn -notcontains "$k=$($P.ollama[$k])") { $err += "Ollama : $k <> $($P.ollama[$k])" } }
    , $err
}
function Update-DefaultsPerformance([string]$Id) {
    $f = Join-Path $Root 'profiles\defaults.yaml'; $u = New-Object Text.UTF8Encoding $false; $t = [IO.File]::ReadAllText($f, $u)
    $t = [regex]::Replace($t, '(?m)^(desired:\s*\n\s+performance:\s*)\S+', "`${1}$Id")
    $t = [regex]::Replace($t, '(?ms)^(applied:\s*\n\s+performance:\s*\n\s+profile:\s*)\S+', "`${1}$Id")
    $t = [regex]::Replace($t, '(?m)^(\s+verified:\s*)"[^"]*"(\s*#\s*performance)', "`${1}`"$((Get-Date).ToString('yyyy-MM-dd')) (profile apply $Id)`"`$2")
    [IO.File]::WriteAllText($f, $t, $u)
}

function Invoke-Profile {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'list' }
    switch ($sub) {
        'list' {
            $cur = Get-AppliedPerfId
            foreach ($id in 'A', 'B', 'C') { $p = Get-PerfProfile $id
                [pscustomobject]@{ Profil = $id + $(if ($id -eq $cur) { ' *' } else { '' }); Libelle = $p.label; Statut = $p.status; WSL2 = "$($p.wsl.memory) / $($p.wsl.processors) vCPU / swap $($p.wsl.swap)"
                    Ollama = "ctx $($p.ollama.OLLAMA_CONTEXT_LENGTH), keep_alive $($p.ollama.OLLAMA_KEEP_ALIVE), KV $($p.ollama.OLLAMA_KV_CACHE_TYPE)" } }
            Write-Output ("* = appliqué. Réseau, sécurité, sauvegarde (souhaités) : {0}" -f (([regex]::Matches([IO.File]::ReadAllText((Join-Path $Root 'profiles\defaults.yaml')), '(?m)^\s+(network|security|backup):\s*(\S+)$') | Select-Object -First 3 | ForEach-Object { $_.Groups[2].Value }) -join ' / '))
        }
        'show' {
            if ($Args0.Count -lt 2) { throw 'Usage : profile show <A|B|C>' }
            $p = Get-PerfProfile $Args0[1]; Write-Output "Profil $($p.id) — $($p.label) [$($p.status)]"; Write-Output "Note : $($p.note)"
            $d = Get-PerfDiff $p; if ($d.Count) { Write-Output 'Écarts avec l''état actuel :'; $d | Format-Table -AutoSize | Out-String -Width 160 | Write-Output } else { Write-Output 'Aucun écart : profil appliqué.' }
        }
        'apply' {
            if ($Args0.Count -lt 2) { throw 'Usage : profile apply <A|B|C> --confirm' }
            $p = Get-PerfProfile $Args0[1]; Assert-NoEmergency
            $d = Get-PerfDiff $p
            if (-not $d.Count) { Write-Output "Profil $($p.id) déjà appliqué (aucun écart)."; return }
            Write-Output "Profil $($p.id) — $($p.label) [$($p.status)] : $($p.note)"; $d | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
            $wslChange = @($d | Where-Object Cible -eq '.wslconfig').Count -gt 0
            if ($wslChange) { Write-Output 'Effet : arrêt de Docker Desktop et de WSL2 (wsl --shutdown), puis redémarrage d''Ollama et d''OpenCode. Sessions et volumes conservés.' }
            else { Write-Output 'Effet : recréation du seul conteneur ollama (modèle déchargé). OpenCode conservé.' }
            if ($Args0 -notcontains '--confirm') { Write-Output 'Aucune modification. Relancer avec --confirm pour appliquer.'; return }
            $loaded = @(Get-LoadedModels); if ($loaded.Count) { throw "Modèle chargé ($($loaded -join ', ')) : attendre la fin de l'inférence ou .\local-ai.ps1 continue off." }
            $files = @($WslConfigFile, $OllamaEnvFile, (Join-Path $Root 'profiles\defaults.yaml'))
            $bk = New-AgentRestorePoint "profile-$($p.id)" $files
            Write-Audit 'profile apply' $p.id 'demandé' "sauvegarde $bk"
            $ocWas = [bool](Get-OpenCodeId)
            $do = {
                $ow = @{}; foreach ($k in $PerfOllamaKeys) { $ow[$k] = $p.ollama[$k] }; Set-KeyValueFile $OllamaEnvFile '=' $ow
                if ($wslChange) { $ww = @{}; foreach ($k in $PerfWslKeys) { $ww[$k] = $p.wsl[$k] }; Set-KeyValueFile $WslConfigFile '=' $ww
                    Stop-Module @('opencode') | Out-Null; Stop-Module @('ollama') | Out-Null; Restart-DockerWsl }
                if ($ocWas -or $wslChange) { Start-Module @('opencode') | Out-Null } else { Push-Location $Root; try { Invoke-Native docker @('compose', '-f', 'compose.yaml', '--profile', 'ollama', 'up', '-d', '--no-deps', '--force-recreate', 'ollama') | Out-Null } finally { Pop-Location } }
                for ($i = 0; $i -lt 40; $i++) { try { Get-OllamaContainer | Out-Null; break } catch { Start-Sleep 3 } }
            }
            $errs = @()
            try { & $do; $errs = Test-PerfApplied $p } catch { $errs = @($_.Exception.Message) }
            if ($errs.Count) {
                Write-Output "ÉCHEC de vérification : $($errs -join ' ; '). Rollback depuis $bk"
                Restore-AgentRestorePoint $bk
                try { if ($wslChange) { Stop-Module @('opencode') | Out-Null; Stop-Module @('ollama') | Out-Null; Restart-DockerWsl }; Start-Module @('opencode') | Out-Null } catch { Write-Output "Rollback : redémarrage à vérifier ($($_.Exception.Message))" }
                Write-Audit 'profile apply' $p.id 'rollback' ($errs -join ' ; '); throw "Profil $($p.id) non appliqué (état restauré)."
            }
            Update-DefaultsPerformance $p.id
            Write-Audit 'profile apply' $p.id 'appliqué' "sauvegarde $bk"
            Write-Output "Profil $($p.id) appliqué et vérifié (CPU/RAM WSL2, variables Ollama). Sauvegarde : $bk"
        }
        default { throw 'Usage : profile list | show <A|B|C> | apply <A|B|C> --confirm' }
    }
}
