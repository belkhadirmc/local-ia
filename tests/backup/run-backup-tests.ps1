#Requires -Version 5.1
# Tests de sauvegarde / restauration (15.B.1) — cibles TÉMOINS uniquement (dossiers runtime\tests\restore, volumes suffixés),
# aucun écrasement de production. Usage : .\tests\backup\run-backup-tests.ps1 -Bk1 <id> -Bk2 <id>
param([Parameter(Mandatory)][string]$Bk1, [Parameter(Mandatory)][string]$Bk2, [string]$Suffix = 'rt15')
$ErrorActionPreference = 'Continue'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent; Set-Location $Root
$L = Join-Path $Root 'local-ai.ps1'; $T = Join-Path $Root 'runtime\tests\restore'
$res = New-Object System.Collections.Generic.List[object]
function Add-Res([string]$Name, [bool]$Ok, [string]$Detail = '') { $res.Add([pscustomobject]@{ Test = $Name; Resultat = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail }) }
function Run([string[]]$A) { $o = & $L @A 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o -join "`n") } }
$img = docker inspect -f '{{.Config.Image}}' local-ai-opencode-1
if (Test-Path $T) { Remove-Item -Recurse -Force $T }; New-Item -ItemType Directory -Force $T | Out-Null

# 1. Intégrité
foreach ($id in $Bk1, $Bk2) { $r = Run @('backup', 'verify', $id); Add-Res "verify $id" ($r.Code -eq 0 -and $r.Out -match 'CONFORME') ($r.Out -split "`n" | Select-Object -Last 1) }
# 2. Prévisualisation BK1 : rien d'écrit
$r = Run @('restore', $Bk1, '--target-dir', "$T\bk1"); Add-Res 'restore BK1 prévisualisation (aucune écriture)' ($r.Code -eq 0 -and $r.Out -match 'PRÉVISUALISATION' -and -not (Test-Path "$T\bk1")) ''
# 3. Restauration BK1 témoin + comparaison avec le dépôt
$r = Run @('restore', $Bk1, '--target-dir', "$T\bk1", '--confirm'); $okx = $r.Code -eq 0 -and $r.Out -match 'identique au manifeste'
$cmp = 0; $diff = 0; foreach ($f in 'local-ai.ps1', 'config\opencode\opencode.json', 'config\gate\gate.pl', 'profiles\defaults.yaml', '.env') { $a = Join-Path "$T\bk1\configurations\repo" $f; $b = Join-Path $Root $f
    if ((Test-Path $a) -and (Get-FileHash $a).Hash -eq (Get-FileHash $b).Hash) { $cmp++ } else { $diff++ } }
Add-Res 'restore BK1 configurations (témoin, intégrité + 5 fichiers comparés au dépôt)' ($okx -and $diff -eq 0) "$cmp identiques, $diff différents ; hôte : $((Get-ChildItem "$T\bk1\configurations\host" -File -ErrorAction SilentlyContinue).Name -join ', ')"
Add-Res 'BK1 sans secret en clair (secrets/ absent)' (-not (Test-Path "$T\bk1\configurations\repo\secrets")) ''
# 4. Cible témoin non vide refusée
$r = Run @('restore', $Bk1, '--target-dir', "$T\bk1", '--confirm'); Add-Res 'restore vers cible non vide refusée' ($r.Code -ne 0 -and $r.Out -match 'aucun écrasement') ''
# 5. Restauration BK2 témoin : volumes suffixés + projets
$r = Run @('restore', $Bk2, '--volume-suffix', $Suffix, '--confirm'); Add-Res "restore BK2 volumes témoins (-$Suffix)" ($r.Code -eq 0 -and ([regex]::Matches($r.Out, 'identique au manifeste')).Count -ge 4) (([regex]::Matches($r.Out, 'identique au manifeste')).Count.ToString() + ' volumes identiques')
$r = Run @('restore', $Bk2, '--item', 'projects-config', '--target-dir', "$T\bk2-projects", '--confirm'); Add-Res 'restore BK2 projets (configuration Dev Container)' ($r.Code -eq 0 -and (Test-Path "$T\bk2-projects\projects-config\demo\.devcontainer\devcontainer.json")) ''
# 6. Sessions restaurées : intégrité SQLite et nombre de sessions (Python isolé du volume local-ai-tools restauré)
# Script Python dans un fichier monté (PowerShell 5.1 altère les guillemets des arguments natifs)
$py = docker run --rm --network none --read-only --tmpfs /tmp --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges -v "local-ai-opencode-${Suffix}:/s:ro" -v "local-ai-tools-${Suffix}:/opt/local-ai-tools:ro" -v "$(Join-Path $Root 'tests\backup'):/t:ro" --entrypoint /opt/local-ai-tools/bin/python3 $img /t/check_sessions.py 2>&1
Add-Res 'sessions restaurées : SQLite intègre et sessions présentes (Python du volume outils restauré)' (("$py" -match '^ok') -and ("$py" -match '\s([1-9]\d*)\s*$')) ("$py" -replace "`n", ' | ')
$tv = docker run --rm --network none --read-only --user 1000:1000 --cap-drop ALL -v "local-ai-tools-${Suffix}:/opt/local-ai-tools:ro" --entrypoint /bin/sh $img -c '/opt/local-ai-tools/bin/python3 --version; /opt/local-ai-tools/bin/git --version; cat /opt/local-ai-tools/lock.txt | wc -l' 2>&1
Add-Res 'outils restaurés : Python, Git et inventaire (34 paquets)' (("$tv" -match 'Python 3\.14') -and ("$tv" -match 'git version 2\.54') -and ("$tv" -match '\b34\b')) ("$tv" -replace "`n", ' | ')
# 7. Volume témoin déjà existant : refus
$r = Run @('restore', $Bk2, '--item', 'vol-local-ai-opencode', '--volume-suffix', $Suffix, '--confirm'); Add-Res 'restore vers volume témoin existant refusée' ($r.Code -ne 0 -and $r.Out -match 'aucun écrasement') ''
# 8. Production sans arrêt des services : refus (aucun écrasement)
$r = Run @('restore', $Bk2, '--item', 'vol-local-ai-opencode', '--production', '--confirm'); Add-Res 'restore production refusée tant que les services tournent' ($r.Code -ne 0 -and $r.Out -match 'en cours d.exécution') ''
# 9. Corruption : copie de BK2 altérée (1 octet) -> verify et restore refusés
$cd = Join-Path $T "corrupt-$Bk2"; Copy-Item -Recurse (Join-Path $Root "backups\sets\$Bk2") $cd
$f = Join-Path $cd 'vol-local-ai-opencode.tar.gz'; $b = [IO.File]::ReadAllBytes($f); $b[[int]($b.Length / 2)] = $b[[int]($b.Length / 2)] -bxor 0xFF; [IO.File]::WriteAllBytes($f, $b)
$r = Run @('backup', 'verify', $cd); Add-Res 'corruption détectée par verify' ($r.Code -ne 0 -and $r.Out -match 'empreinte') (($r.Out -split "`n" | Select-Object -First 1) -replace '^.*NON CONFORME', 'NON CONFORME')
$r = Run @('restore', $cd, '--volume-suffix', 'rtx', '--confirm'); Add-Res 'restauration d''une sauvegarde corrompue refusée' ($r.Code -ne 0 -and $r.Out -match 'non conforme') ''
Remove-Item -Recurse -Force $cd
# 10. Quota : refus (abaissé pour le test), relèvement impossible
$env:LOCAL_AI_BACKUP_QUOTA_GIB = '0.01'; $r = Run @('backup', 'create', 'BK2'); Add-Res 'refus de quota (quota abaissé à 0,01 Gio)' ($r.Code -ne 0 -and $r.Out -match 'Quota local dépassé') (($r.Out -split "`n" | Where-Object { $_ -match 'Quota' } | Select-Object -First 1) -replace '^.*: Quota', 'Quota')
$env:LOCAL_AI_BACKUP_QUOTA_GIB = '50'; $r = Run @('backup', 'status'); Add-Res 'quota non relevable au-delà de 10 Gio' ($r.Out -match '/ 10 Gio') ''
Remove-Item Env:LOCAL_AI_BACKUP_QUOTA_GIB
# 11. Espace disque : refus
$env:LOCAL_AI_BACKUP_MIN_FREE_GIB = '100000'; $r = Run @('backup', 'create', 'BK1'); Add-Res 'refus d''espace insuffisant' ($r.Code -ne 0 -and $r.Out -match 'Espace insuffisant') ''; Remove-Item Env:LOCAL_AI_BACKUP_MIN_FREE_GIB
# 12. BK3 : modèles jamais en local
$r = Run @('backup', 'create', 'BK3', '--external', $env:TEMP); Add-Res 'BK3 : stockage des modèles sur le disque système refusé' ($r.Code -ne 0 -and $r.Out -match 'disque système') ''
$r = Run @('backup', 'create', 'BK3', '--external', 'Z:\absent'); Add-Res 'BK3 : stockage externe absent refusé' ($r.Code -ne 0 -and $r.Out -match 'introuvable') ''
# 13. Aucune sauvegarde orpheline créée par les refus
$sets = @(Get-ChildItem (Join-Path $Root 'backups\sets') -Directory).Name; Add-Res 'aucune sauvegarde partielle laissée par les refus' ($sets.Count -eq 2 -and $sets -contains $Bk1 -and $sets -contains $Bk2) ($sets -join ', ')
$res | Format-Table -AutoSize -Wrap | Out-String -Width 220
"{0} PASS / {1} FAIL" -f @($res | Where-Object Resultat -eq 'PASS').Count, @($res | Where-Object Resultat -eq 'FAIL').Count
