# Repli local contrôlé (14.B.2) — dot-sourcé par local-ai.ps1. Politique : config/agents/fallback.yaml (-> config/gate/fallback.json).
# Décision AVANT exécution, par tâche : modèle initial de l'agent s'il est admis par la garde RAM (admission à blanc de la
# passerelle) et compatible outils ; sinon premier modèle de la chaîne qui l'est. auto = appliqué à la SESSION de la tâche ;
# ask = proposé, appliqué seulement avec --accept-fallback ; off = aucun repli. Jamais de changement d'affectation, de rejeu
# automatique ni de contournement de la garde : un modèle refusé n'est jamais forcé.
$FallbackJson = Join-Path $Root 'config\gate\fallback.json'
$FallbackYaml = Join-Path $Root 'config\agents\fallback.yaml'

function Get-FallbackPolicy { [IO.File]::ReadAllText($FallbackJson) | ConvertFrom-Json }
function Get-Admission([string[]]$Tags) {
    $prevOut = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false   # sortie UTF-8 de la passerelle
    try { $out = (Invoke-Native docker (@('exec', 'local-ai-ollama-gate-1', 'perl', '/etc/local-ai/admit.pl') + $Tags)).Output } finally { [Console]::OutputEncoding = $prevOut }
    $res = @{}; foreach ($l in ($out -split "`n" | Where-Object { $_ -match '^\{' })) { $o = $l | ConvertFrom-Json; $res[$o.model] = $o }
    foreach ($t in $Tags) { if (-not $res.ContainsKey($t)) { throw "admission à blanc indisponible pour $t (passerelle démarrée ?) : $out" } }
    $res
}
function Resolve-AgentModel([string]$AgentId, [switch]$AcceptFallback) {
    $a = @(Get-AgentInfo) | Where-Object Id -eq $AgentId | Select-Object -First 1; if (-not $a) { throw "Agent '$AgentId' inconnu." }
    $initial = (@(Get-ModelInfo) | Where-Object Id -eq $a.Ref | Select-Object -First 1).Tag
    $pol = (Get-FallbackPolicy).agents.$AgentId; if (-not $pol) { throw "Agent '$AgentId' sans politique de repli (config/agents/fallback.yaml)." }
    $chain = @($pol.chain | Where-Object { $_ })
    $adm = Get-Admission (@($initial) + $chain | Select-Object -Unique)
    $why = { param($t) $x = $adm[$t]; if (-not $x.tools_compatible) { 'outils incompatibles (6.B.1/14.B.1)' } elseif (-not $x.admitted) { "RAM : $($x.reason)" } else { $null } }
    $r = [ordered]@{ agent = $AgentId; mode = $pol.mode; initial = $initial; selected = $initial; fallback = $false; needs_confirmation = $false; blocked = $false
        motif = (& $why $initial); simulated = [bool]$adm[$initial].simulated; candidates = @() }
    if (-not $r.motif) { return [pscustomobject]$r }
    if ($pol.mode -eq 'off') { $r.blocked = -not $adm[$initial].admitted; return [pscustomobject]$r }
    foreach ($c in $chain) { $w = & $why $c; $r.candidates += "$c : $(if ($w) { $w } else { 'admis, outils OK' })"; if (-not $w) { $r.selected = $c; $r.fallback = $true; break } }
    if (-not $r.fallback) { $r.selected = $null; $r.blocked = $true; return [pscustomobject]$r }
    if ($pol.mode -eq 'ask' -and -not $AcceptFallback) { $r.needs_confirmation = $true }
    [pscustomobject]$r
}
function Write-FallbackLog($Decision, [string]$Result, [string]$Session = '') {
    $dir = Join-Path $Root 'runtime\logs'; New-Item -ItemType Directory -Force $dir | Out-Null
    $o = [ordered]@{ ts = (Get-Date).ToString('o'); agent = $Decision.agent; mode = $Decision.mode; initial = $Decision.initial; selected = $Decision.selected
        fallback = $Decision.fallback; motif = $Decision.motif; simulated = $Decision.simulated; result = $Result; session = $Session }
    [IO.File]::AppendAllText((Join-Path $dir 'fallback.jsonl'), (($o | ConvertTo-Json -Compress) + "`n"), (New-Object Text.UTF8Encoding $false))
    Write-Audit 'agent.fallback' $Decision.agent $Result ("$($Decision.initial) -> $($Decision.selected) ; $($Decision.motif)")
}
function Format-FallbackDecision($d) {
    if (-not $d.motif) { return "Modèle : $($d.initial) (initial, admis, outils OK)" }
    $m = "Motif : $($d.motif)$(if ($d.simulated) { ' [seuils SIMULÉS]' })"
    if ($d.blocked -and $d.mode -eq 'off') { return "$m`nPolitique off : aucun repli ; la passerelle refusera le modèle initial $($d.initial)." }
    if ($d.blocked) { return "$m`nAucun modèle de repli admissible ($($d.candidates -join ' | ')) : tâche NON lancée (garde RAM respectée)." }
    if ($d.needs_confirmation) { return "$m`nREPLI PROPOSÉ (politique ask) : $($d.agent) $($d.initial) -> $($d.selected). Relancer avec --accept-fallback pour l'appliquer à cette tâche." }
    if ($d.mode -eq 'off') { return "$m`nPolitique off : modèle initial $($d.initial) conservé." }
    "$m`nREPLI ($($d.mode)) : $($d.agent) $($d.initial) -> $($d.selected) pour cette tâche uniquement (affectation inchangée)."
}
function Invoke-Fallback {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'list' }
    switch ($sub) {
        'list' {
            $p = Get-FallbackPolicy
            foreach ($id in $p.agents.PSObject.Properties.Name) { $x = $p.agents.$id; $a = @(Get-AgentInfo) | Where-Object Id -eq $id | Select-Object -First 1
                [pscustomobject]@{ Agent = $id; Mode = $x.mode; Initial = (@(Get-ModelInfo) | Where-Object Id -eq $a.Ref | Select-Object -First 1).Tag; Chaine = (@($x.chain) -join ' -> ') } }
            Write-Output "Outils incompatibles : $(@($p.tools_incompatible) -join ', ')"
        }
        'check' {
            if ($Args0.Count -lt 2) { throw 'Usage : fallback check <agent|all>' }
            $ids = if ($Args0[1] -eq 'all') { @((Get-FallbackPolicy).agents.PSObject.Properties.Name | Where-Object { $_ -ne 'autocomplete' }) } else { @($Args0[1]) }
            foreach ($id in $ids) { $d = Resolve-AgentModel $id; [pscustomobject]@{ Agent = $id; Mode = $d.mode; Initial = $d.initial; Retenu = $(if ($d.blocked) { 'AUCUN' } elseif ($d.needs_confirmation) { "$($d.selected) (confirmation)" } else { $d.selected }); Motif = $d.motif; Simule = $d.simulated } }
        }
        'mode' {
            if ($Args0.Count -lt 3 -or $Args0[2] -notin 'auto', 'ask', 'off') { throw 'Usage : fallback mode <agent> auto|ask|off' }
            $id = $Args0[1]; $t = [IO.File]::ReadAllText($FallbackYaml)
            $pat = "(?m)^(\s+$([regex]::Escape($id)):\s*\{\s*mode:\s*)(auto|ask|off)"
            if (-not [regex]::IsMatch($t, $pat)) { throw "Agent '$id' absent de config/agents/fallback.yaml." }
            $bk = New-AgentRestorePoint "fallback-$id" @($FallbackYaml, $FallbackJson)
            [IO.File]::WriteAllText($FallbackYaml, [regex]::Replace($t, $pat, "`${1}$($Args0[2])"), (New-Object Text.UTF8Encoding $false))
            try { & (Join-Path $Root 'config\opencode\generate-config.ps1') | Out-Null } catch { Restore-AgentRestorePoint $bk; throw "régénération impossible, état restauré : $($_.Exception.Message)" }
            Write-Audit 'fallback.mode' $id $Args0[2] "sauvegarde $bk"
            Write-Output "Repli de $id : $($Args0[2]) (pris en compte immédiatement par la passerelle et agent handoff ; sauvegarde $bk)."
        }
        default { throw 'Usage : fallback list | check <agent|all> | mode <agent> auto|ask|off' }
    }
}
