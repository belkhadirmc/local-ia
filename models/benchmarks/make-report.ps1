#Requires -Version 5.1
<# Génère report.md à partir de summary.json (6.B.1). Lecture seule hors report.md. #>
[CmdletBinding()]
param([string]$Summary = (Join-Path $PSScriptRoot 'summary.json'), [string]$Out = (Join-Path $PSScriptRoot 'report.md'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$u = New-Object Text.UTF8Encoding $false
$d = [IO.File]::ReadAllText($Summary, $u) | ConvertFrom-Json
function P($o, $p) { if ($null -ne $o -and ($o.PSObject.Properties.Name -contains $p)) { $o.$p } else { $null } }
function F($v, $fmt = '{0}') { if ($null -eq $v -or "$v" -eq '') { '—' } else { $fmt -f $v } }
$models = @($d.models.PSObject.Properties | ForEach-Object { $_.Value })
$cases = 'code_gen', 'debug', 'qa', 'fim', 'devops', 'review', 'security', 'architecture', 'multifile', 'instructions', 'documentation', 'tools'
$L = New-Object System.Collections.Generic.List[string]
$L.Add('# Benchmarks local-ai — 6.B.1'); $L.Add('')
$L.Add(("Exécution ``{0}`` · profil {1} · CPU uniquement · RAM WSL2 {2} Gio (base {3} Gio) · RAM Windows disponible au départ {4} Gio · SSD {5} → {6} Gio." -f $d.run, $d.profile, $d.environment.wsl_total_gib, $d.environment.baseline_wsl_used_gib, $d.environment.baseline_win_avail_gib, $d.environment.ssd_free_start_gib, $d.environment.ssd_free_end_gib))
$mf = P $d 'merged_from'
if ($mf) { $L.Add(''); $L.Add(("Modèles repris de l'exécution ``{0}`` (complets, non relancés) : {1}. Les autres ont été relancés dans ``{2}`` après une mise en veille de Windows et des interruptions de sécurité." -f $mf, (@($d.merged_models) -join ', '), $d.run)) }
$L.Add(''); $L.Add('Protocole : `suite.yaml` et `cases/*.json` (critères figés avant exécution, mêmes exercices pour tous). Une requête et un modèle à la fois, température 0, graine 42.')
$L.Add('Validation : **exécutée** (code_gen, debug, qa, fim — Bash dans un bac à sable Docker sans réseau, lecture seule, sans capacités), **statique** (critères regex/structure, devops analysé par `docker compose config`), **simulée** (tools : appels d''outils vérifiés, aucun outil exécuté).')
$L.Add(''); $L.Add('## Synthèse'); $L.Add('')
$L.Add('| Modèle | Score /100 | Code | Raison. | Instr. | Outils | Vitesse | Mémoire | Sortie tok/s | 1er token chaud | Chargement froid | Entrée tok/s 4096 / 8192 | Pic RAM WSL2 4096 / 8192 | Contexte 4096 | Contexte 8192 |')
$L.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($m in ($models | Sort-Object { if ($null -ne $_.score) { $_.score } else { -1 } } -Descending)) {
    $c = $m.categories; $l4 = P $m.long '4096'; $l8 = P $m.long '8192'
    $pct = { param($x) if ($null -eq $x) { '—' } else { [math]::Round(100 * $x) } }
    $L.Add(("| {0} | **{1}** | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} s | {10} s | {11} / {12} | {13} / {14} | {15} | {16} |" -f $m.model, (F $m.score), (& $pct $c.code), (& $pct $c.reasoning), (& $pct $c.instructions), (& $pct $c.tools), (& $pct $c.speed), (& $pct $c.memory),
            (F $m.speed.out_tps '{0:N1}'), (F $m.speed.ttft_warm_s '{0:N2}'), (F $m.speed.load_cold_s '{0:N1}'), (F (P $l4 'in_tps') '{0:N1}'), (F (P $l8 'in_tps') '{0:N1}'),
            $(if ($l4) { "{0:N1} Gio ({1} %)" -f $m.peaks.wsl_used_gib_4096, $m.peaks.wsl_pct_4096 } else { '—' }), $(if ($l8) { "{0:N1} Gio ({1} %)" -f $l8.peak_wsl_gib, $l8.peak_pct } else { '—' }),
            (F (P $m.contexts '4096') ), (F (P $m.contexts '8192'))))
}
$L.Add(''); $L.Add('Pondération : code 40, raisonnement 15, vitesse 15, mémoire 10, outils 10, instructions 10. Catégorie non réalisée = exclue et poids renormalisés.')
$L.Add('Normalisation : vitesse = 0,5 × min(1, sortie/20 tok/s) + 0,2 × min(1, 1 s / 1er token chaud) + 0,3 × min(1, 30 s / 1er token à 4096) ; mémoire = 1 − (pic RAM WSL2 hors cache à 4096 − base) / (85 % RAM WSL2 − base).')
$L.Add(''); $L.Add('## Détail par exercice (0–100)'); $L.Add('')
$L.Add('| Modèle | ' + ($cases -join ' | ') + ' | aiguille 4096 | aiguille 8192 |'); $L.Add('|---|' + (('---|') * ($cases.Count + 2)))
foreach ($m in $models) {
    $cells = foreach ($k in $cases) { $e = P $m.cases $k; if (-not $e) { 'n.r.' } elseif ($e.status -eq 'not_supported') { 'n.s.' } elseif ($e.status -ne 'done' -or $null -eq $e.score) { 'err' } else { [math]::Round(100 * $e.score) } }
    $n4 = P (P $m.long '4096') 'needle'; $n8 = P (P $m.long '8192') 'needle'
    $L.Add("| $($m.model) | " + ($cells -join ' | ') + " | $(if($null -ne $n4){[math]::Round(100*$n4)}else{'n.r.'}) | $(if($null -ne $n8){[math]::Round(100*$n8)}else{'n.r.'}) |")
}
$L.Add(''); $L.Add('n.s. = capacité absente (insert/FIM) ; n.r. = non réalisé ; err = erreur ou délai.')
$L.Add(''); $L.Add('## Recommandations par rôle (affectations NON modifiées)'); $L.Add('')
$L.Add('| Rôle | Principal | Alternatives |'); $L.Add('|---|---|---|')
$roleNames = [ordered]@{ architect = 'Architecte'; reviewer = 'Reviewer'; security = 'Sécurité'; developer = 'Développeur'; devops = 'DevOps'; debugger = 'Debugger'; qa = 'QA'; documentalist = 'Documentaliste'; assistant = 'Assistant'; autocomplete = 'Autocomplétion (Continue)' }
foreach ($rk in $roleNames.Keys) {
    $r = P $d.ranking $rk; if (-not $r) { continue }
    $alts = @($r.alternatives | ForEach-Object { "{0} ({1:N1})" -f $_.model, $_.score }) -join ', '
    $L.Add(("| {0} | {1} | {2} |" -f $roleNames[$rk], $(if ($r.principal) { "**{0}** ({1:N1})" -f $r.principal.model, $r.principal.score } else { '—' }), $(if ($alts) { $alts } else { '—' })))
}
$L.Add(''); $L.Add('## Restitution mémoire après déchargement (cache non vidé)'); $L.Add('')
$L.Add('| Modèle | Windows dispo avant | min pendant | +10 s après déchargement | RAM WSL2 +10 s |'); $L.Add('|---|---|---|---|---|')
foreach ($m in $models) { $r = $m.restitution; if ($r) { $L.Add(("| {0} | {1} Gio | {2} Gio | {3} Gio | {4} Gio |" -f $m.model, $r.win_avail_before_gib, (F $r.win_avail_min_gib), $r.win_avail_after10s_gib, $r.wsl_used_after10s_gib)) } }
$L.Add(''); $L.Add('Après la dernière série, au repos :'); $L.Add('')
$L.Add('| t (s) | Windows dispo | RAM WSL2 hors cache | RAM conteneur (anon) |'); $L.Add('|---|---|---|---|')
foreach ($r in $d.restitution_final) { $L.Add(("| {0} | {1} Gio | {2} Gio | {3} Gio |" -f $r.t_s, $r.win_avail_gib, $r.wsl_used_gib, (F $r.ctr_anon_gib))) }
$L.Add(''); $L.Add('## Incidents'); $L.Add('')
$inc = @()
foreach ($m in $models) { if ($m.aborted) { $inc += "- $($m.model) : interrompu — $($m.aborted)" }; foreach ($e in @($m.errors)) { if ($e) { $inc += "- $($m.model) : $e" } } }
foreach ($a in @($d.anomalies)) { if ($a) { $inc += "- $a" } }
if ($d.environment.cpu_alerts) { $inc += "- Alertes CPU > 95 % pendant 5 min : $($d.environment.cpu_alerts)" }
if ($inc.Count) { $inc | ForEach-Object { $L.Add($_) } } else { $L.Add('Aucun incident (aucune interruption, aucun dépassement de seuil critique).') }
# Constats rédigés après lecture des résultats bruts (facultatif) : report-notes.md
$notes = Join-Path (Split-Path $Out) 'report-notes.md'
if (Test-Path $notes) { $L.Add(''); foreach ($nl in [IO.File]::ReadAllLines($notes, $u)) { $L.Add($nl) } }
$L.Add(''); $L.Add('## Limites'); $L.Add('')
$L.Add('- Une seule passe qualité par exercice (température 0) : écarts de quelques points non significatifs.')
$L.Add('- Code exécuté en Bash uniquement (seuls bash/perl/awk sont disponibles dans l''image existante) ; Python évalué statiquement.')
$L.Add('- Contexte long : prompts synthétiques (aiguille dans un module généré) ; vitesses médianes sur 2 exécutions par contexte, 3 répétitions pour la vitesse courte.')
$L.Add('- Résultats bruts (réponses, échantillons 1 s) : `results/<horodatage>/` (non versionné).')
[IO.File]::WriteAllText($Out, (($L -join "`n") + "`n"), $u)
"report: $Out"
