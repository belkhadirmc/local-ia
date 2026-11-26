# Sauvegarde / restauration local-ai (15.B.1, ADR-0015) — dot-sourcé par local-ai.ps1.
#   backup list | status | create BK1|BK2|BK3 [--external <dossier>] | verify <id|chemin> | delete <id> --confirm
#   restore <id> [--item <nom>] (--target-dir <dossier> | --volume-suffix <suffixe> | --production) [--confirm]
#   maintenance status
# BK1 = configurations (dépôt suivi, .env sans secret, .wslconfig, réglages Docker sans identifiants) ;
# BK2 = projets (projects/), sessions (volume local-ai-opencode), workspaces et caches de projets, volume local-ai-tools ;
# BK3 = BK1 + BK2 (+ modèles UNIQUEMENT vers un stockage externe, --external ; jamais de duplication locale des modèles).
# Quota global 10 Gio (backups/ en entier), contrôle d'espace préalable, manifeste + SHA256SUMS + empreintes par fichier,
# archives cohérentes (OpenCode et Dev Containers mis en pause pendant l'archivage), aucun secret en clair (secrets/ exclu,
# fichiers suspects écartés), aucune suppression automatique. Restauration : prévisualisation sans --confirm ; témoins
# (dossier vide / nouveaux volumes suffixés) ; production seulement avec --production --confirm, services arrêtés et
# sauvegarde de sécurité préalable de ce qui sera remplacé.
$BackupRoot = Join-Path $Root 'backups'
$BackupSets = Join-Path $BackupRoot 'sets'
$BackupQuotaGiB = 10
$SecretPattern = '(?i)(password|passwd|secret|token|api[_-]?key|bearer|credential)\s*["'':=]\s*["'']?[^\s"'']{8,}|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|glpat-'

function Get-BackupImage { "$(Get-EnvValue 'OPENCODE_IMAGE_REPO'):$(Get-EnvValue 'OPENCODE_IMAGE_TAG')@sha256:$(Get-EnvValue 'OPENCODE_IMAGE_SHA256')" }
function Get-DirSizeBytes([string]$Path) { if (-not (Test-Path $Path)) { return 0 }; $s = (Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; if ($s) { [double]$s } else { 0 } }
function Get-BackupQuotaGiB {
    # Le quota validé (10 Gio) peut être ABAISSÉ pour les tests (LOCAL_AI_BACKUP_QUOTA_GIB), jamais relevé.
    $q = $BackupQuotaGiB; $e = $env:LOCAL_AI_BACKUP_QUOTA_GIB
    if ($e) { $v = [double]::Parse($e, [Globalization.CultureInfo]::InvariantCulture); if ($v -lt $q) { $q = $v } }
    $q
}
function Get-VolumeBytes([string]$Name) {
    $o = (Invoke-Native docker @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '1000:1000', '-v', "${Name}:/v:ro", '--entrypoint', '/bin/busybox', (Get-BackupImage), 'du', '-sk', '/v')).Output
    if ($o -match '^(\d+)') { [double]$Matches[1] * 1024 } else { 0 }
}
function Get-Bk2Volumes {
    # Volumes témoins de restauration (label local-ai.volume=restore-test) exclus
    $v = @((Invoke-Native docker @('volume', 'ls', '--format', '{{.Name}}|{{.Labels}}')).Output -split "`n" | Where-Object { $_ -notmatch 'local-ai\.volume=restore-test' } | ForEach-Object { ($_ -split '\|')[0] } | Where-Object { $_ -match '^local-ai-(opencode|tools|workspace-(?!none$).+|cache-.+)$' })
    @($v | Sort-Object)
}
function Test-SecretFile([string]$Path) { try { [regex]::IsMatch([IO.File]::ReadAllText($Path), $SecretPattern) } catch { $true } }
function Invoke-Tar([string]$Mount, [string]$Out, [string]$Name, [switch]$ReadOnlyVolume) {
    # Archive + empreintes par fichier, dans un conteneur sans réseau (busybox de l'image OpenCode épinglée).
    $src = if ($ReadOnlyVolume) { "${Mount}:/src:ro" } else { "${Mount}:/src:ro" }
    $cmd = "cd /src && find . -type f -exec sha256sum {} + | sort -k2 > /out/$Name.files.sha256 && tar -czf /out/$Name.tar.gz . && echo ok"
    $r = Invoke-Native docker @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '1000:1000', '-v', $src, '-v', "${Out}:/out", '--entrypoint', '/bin/busybox', (Get-BackupImage), 'sh', '-c', $cmd)
    if ($r.Code -ne 0 -or $r.Output -notmatch 'ok') { throw "archivage $Name : $($r.Output)" }
}
function Get-BackupSet([string]$IdOrPath) {
    $d = if (Test-Path $IdOrPath -PathType Container) { (Resolve-Path $IdOrPath).Path } else { Join-Path $BackupSets $IdOrPath }
    if (-not (Test-Path (Join-Path $d 'manifest.json'))) { throw "Sauvegarde introuvable : $IdOrPath (backup list)." }
    [pscustomobject]@{ Dir = $d; Manifest = (Get-Content (Join-Path $d 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json) }
}
function Test-BackupSet([string]$IdOrPath) {
    $s = Get-BackupSet $IdOrPath; $err = @()
    $sums = Join-Path $s.Dir 'SHA256SUMS.txt'
    if (-not (Test-Path $sums)) { $err += 'SHA256SUMS.txt absent' } else {
        $listed = @{}
        foreach ($l in (Get-Content $sums)) { $h, $rel = $l -split '\s+', 2; $listed[$rel] = $true; $f = Join-Path $s.Dir $rel
            if (-not (Test-Path $f)) { $err += "manquant : $rel"; continue }
            if ((Get-FileHash $f -Algorithm SHA256).Hash.ToLowerInvariant() -ne $h) { $err += "empreinte différente : $rel" } }
        foreach ($f in (Get-ChildItem $s.Dir -File | Where-Object { $_.Name -notin 'SHA256SUMS.txt' })) { if (-not $listed.ContainsKey($f.Name)) { $err += "fichier non répertorié : $($f.Name)" } }
    }
    foreach ($it in @($s.Manifest.items)) {
        $a = Join-Path $s.Dir $it.archive
        if ((Test-Path $a) -and (Get-FileHash $a -Algorithm SHA256).Hash.ToLowerInvariant() -ne $it.sha256) { $err += "manifeste : empreinte de $($it.archive)" }
        if (Test-Path $a) { $r = Invoke-Native docker @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '1000:1000', '-v', "$($s.Dir):/b:ro", '--entrypoint', '/bin/busybox', (Get-BackupImage), 'sh', '-c', "tar -tzf /b/$($it.archive) > /dev/null && echo ok")
            if ($r.Output -notmatch 'ok') { $err += "archive illisible : $($it.archive)" } }
    }
    [pscustomobject]@{ Id = $s.Manifest.id; Dir = $s.Dir; Ok = ($err.Count -eq 0); Errors = $err; Items = @($s.Manifest.items).Count }
}
function Write-SetSums([string]$Dir) {
    $lines = foreach ($f in (Get-ChildItem $Dir -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name)) { "$((Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($f.Name)" }
    [IO.File]::WriteAllLines((Join-Path $Dir 'SHA256SUMS.txt'), [string[]]$lines)
}
function New-BackupSet([string]$Kind, [string]$External) {
    if ($Kind -notin 'BK1', 'BK2', 'BK3') { throw 'Profil : BK1, BK2 ou BK3.' }
    Assert-NoEmergency
    if (-not (Test-DockerEngine)) { throw 'Docker Engine indisponible.' }
    if ($Kind -eq 'BK3' -and $External) {
        # Modèles : stockage EXTERNE uniquement (jamais sur le disque système ni sous le dépôt) — aucune duplication locale.
        if (-not (Test-Path $External -PathType Container)) { throw "Stockage externe introuvable : $External" }
        $full = (Resolve-Path $External).Path; $sys = $env:SystemDrive.TrimEnd('\')
        if ($full -like "$sys*" -or $full -like "$Root*") { throw "Refus : $full est sur le disque système ($sys) ou sous le dépôt ; les modèles ne sont jamais dupliqués localement." }
    }
    $loaded = @(Get-LoadedModels); if ($Kind -ne 'BK1' -and $loaded.Count) { throw "Inférence en cours ($($loaded -join ', ')) : sauvegarde des sessions refusée pour garantir une archive cohérente." }
    # Estimation (borne haute : tailles non compressées) + quota + espace disque
    $vols = if ($Kind -ne 'BK1') { Get-Bk2Volumes } else { @() }
    $est = 50MB; foreach ($v in $vols) { $est += Get-VolumeBytes $v }
    $used = Get-DirSizeBytes $BackupRoot; $q = Get-BackupQuotaGiB
    if (($used + $est) / 1GB -gt $q) { throw ('Quota local dépassé : {0:N2} Gio utilisés + {1:N2} Gio estimés > {2} Gio. Aucune suppression automatique : libérer manuellement (backup delete <id> --confirm).' -f ($used / 1GB), ($est / 1GB), $q) }
    $minFree = if ($env:LOCAL_AI_BACKUP_MIN_FREE_GIB) { [double]$env:LOCAL_AI_BACKUP_MIN_FREE_GIB } else { (Get-Thresholds).SsdWarn }
    $free = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Root.Substring(0,2))'").FreeSpace
    if (($free - $est) / 1GB -lt $minFree) { throw ('Espace insuffisant : {0:N1} Gio libres - {1:N2} Gio estimés < {2} Gio (seuil d''alerte SSD).' -f ($free / 1GB), ($est / 1GB), $minFree) }
    $id = "${Kind}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"; $dir = Join-Path $BackupSets $id; New-Item -ItemType Directory -Force $dir | Out-Null
    $items = New-Object System.Collections.Generic.List[object]; $excluded = New-Object System.Collections.Generic.List[string]
    $addItem = { param($name, $type, $source) $a = Join-Path $dir "$name.tar.gz"
        $items.Add([ordered]@{ name = $name; type = $type; source = $source; archive = "$name.tar.gz"; files_sha256 = "$name.files.sha256"
            sha256 = (Get-FileHash $a -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = (Get-Item $a).Length; files = @(Get-Content (Join-Path $dir "$name.files.sha256")).Count }) }
    try {
        # --- configurations (BK1, BK3)
        if ($Kind -in 'BK1', 'BK3') {
            $st = Join-Path $dir '_staging'; New-Item -ItemType Directory -Force "$st\repo", "$st\host" | Out-Null
            $prevOut = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
            try { $tracked = @((Invoke-Native git @('-C', $Root, '-c', 'core.quotepath=off', 'ls-files')).Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^(backups|runtime|secrets|exports)/' }) }
            finally { [Console]::OutputEncoding = $prevOut }
            # Fichiers suivis : déjà soumis au contrôle de confidentialité avant chaque push ; fichiers NON suivis (.env) et réglages
            # hôte : analyse de motifs de secret, exclusion en cas de doute.
            foreach ($rel in $tracked + @('.env')) { $src = Join-Path $Root $rel; if (-not (Test-Path $src -PathType Leaf)) { continue }
                if ($rel -eq '.env' -and (Test-SecretFile $src)) { $excluded.Add("repo/$rel (motif de secret)"); continue }
                $dst = Join-Path "$st\repo" $rel; New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null; Copy-Item $src $dst }
            foreach ($h in @("$env:USERPROFILE\.wslconfig", "$env:USERPROFILE\.docker\daemon.json", "$env:APPDATA\Docker\settings-store.json")) {
                if (-not (Test-Path $h)) { continue }; if (Test-SecretFile $h) { $excluded.Add("host/$(Split-Path $h -Leaf) (motif de secret)"); continue }
                Copy-Item $h (Join-Path "$st\host" (Split-Path $h -Leaf)) }
            $excluded.Add('secrets/ (jamais sauvegardé en clair)'); $excluded.Add('%USERPROFILE%\.docker\config.json (identifiants de registre possibles)')
            Invoke-Tar $st $dir 'configurations'; & $addItem 'configurations' 'files' 'dépôt suivi + .env + réglages hôte'
            Remove-Item -Recurse -Force $st
        }
        # --- projets, sessions, outils (BK2, BK3)
        if ($Kind -in 'BK2', 'BK3') {
            $pj = Join-Path $Root 'projects'; $st = Join-Path $dir '_staging'; New-Item -ItemType Directory -Force $st | Out-Null
            foreach ($p in (Get-ChildItem $pj -Directory | Where-Object Name -ne 'templates')) { Copy-Item -Recurse $p.FullName (Join-Path $st $p.Name) }
            Invoke-Tar $st $dir 'projects-config'; & $addItem 'projects-config' 'files' 'projects/<id>/.devcontainer'; Remove-Item -Recurse -Force $st
            $paused = @()
            try {
                foreach ($c in @((Invoke-Native docker @('ps', '--format', '{{.Names}}', '--filter', 'name=local-ai-opencode-1', '--filter', 'status=running')).Output -split "`n" | Where-Object { $_ }) +
                               @((Invoke-Native docker @('ps', '--format', '{{.Names}}', '--filter', 'label=local-ai.module=project', '--filter', 'status=running')).Output -split "`n" | Where-Object { $_ })) {
                    if ((Invoke-Native docker @('pause', $c)).Code -eq 0) { $paused += $c } }
                foreach ($v in $vols) { Invoke-Tar $v $dir "vol-$v" -ReadOnlyVolume; & $addItem "vol-$v" 'volume' $v }
            } finally {
                foreach ($c in $paused) { Invoke-Native docker @('unpause', $c) | Out-Null }
                # Un contrôle de santé tombé pendant la pause peut marquer OpenCode « unhealthy » : attente du rétablissement (≤ 90 s).
                if ($paused -contains 'local-ai-opencode-1') { for ($i = 0; $i -lt 30; $i++) { if ((Invoke-Native docker @('inspect', '-f', '{{.State.Health.Status}}', 'local-ai-opencode-1')).Output.Trim() -eq 'healthy') { break }; Start-Sleep 3 } }
            }
            $excluded.Add('volume local-ai-ollama (modèles : BK3 --external uniquement)')
        }
        if ($Kind -eq 'BK3' -and $External) {
            $ext = Join-Path (Resolve-Path $External).Path "local-ai-models-$id"; New-Item -ItemType Directory -Force $ext | Out-Null
            Invoke-Tar 'local-ai-ollama' $ext 'vol-local-ai-ollama' -ReadOnlyVolume
            $excluded.Add("volume local-ai-ollama archivé HORS dépôt : $ext")
        }
        $m = [ordered]@{ schema = 'local-ai/backup/v1'; id = $id; profile = $Kind; created = (Get-Date).ToString('o'); local_ai = 'v1.0.0'
            items = $items.ToArray(); excluded = $excluded.ToArray(); quota_gib = $q; secrets = 'aucun (secrets/ exclu, fichiers suspects écartés)' }
        [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($m | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
        Write-SetSums $dir
        $v = Test-BackupSet $id; if (-not $v.Ok) { throw "vérification après création : $($v.Errors -join ' ; ')" }
    } catch { if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }; Write-Audit 'backup.create' $Kind 'échec' $_.Exception.Message; throw }
    Write-Audit 'backup.create' $id 'créé' ('{0} éléments, {1:N1} Mio' -f $items.Count, ((Get-DirSizeBytes $dir) / 1MB))
    [pscustomobject]@{ Id = $id; Elements = $items.Count; Taille = '{0:N2} Mio' -f ((Get-DirSizeBytes $dir) / 1MB); Exclus = ($excluded -join ' | ') }
}
function Get-BackupList {
    $sets = if (Test-Path $BackupSets) { @(Get-ChildItem $BackupSets -Directory | Sort-Object Name) } else { @() }
    foreach ($d in $sets) { $mf = Join-Path $d.FullName 'manifest.json'; if (-not (Test-Path $mf)) { continue }
        $m = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        [pscustomobject]@{ Id = $m.id; Profil = $m.profile; Cree = ([datetime]$m.created).ToString('yyyy-MM-dd HH:mm'); Elements = @($m.items).Count; Taille = '{0:N2} Mio' -f ((Get-DirSizeBytes $d.FullName) / 1MB) } }
}
function Invoke-Backup {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'status' }
    $opt = { param($n) $k = [array]::IndexOf($Args0, $n); if ($k -ge 0 -and $k + 1 -lt $Args0.Count) { $Args0[$k + 1] } else { $null } }
    switch ($sub) {
        'list' { $l = @(Get-BackupList); if ($l.Count) { $l | Format-Table -AutoSize | Out-String -Width 160 | Write-Output } else { Write-Output 'Aucune sauvegarde (backup create BK1|BK2|BK3).' }
            Write-Output "Points de restauration d'actions et d'agents (BK1, backups/restore-points) : $(@(Get-ChildItem (Join-Path $BackupRoot 'restore-points') -Directory -ErrorAction SilentlyContinue).Count)" }
        'status' {
            $used = Get-DirSizeBytes $BackupRoot; $q = Get-BackupQuotaGiB; $l = @(Get-BackupList)
            Write-Output ('Utilisation locale : {0:N2} Gio / {1} Gio ({2:N1} %)' -f ($used / 1GB), $q, (100 * $used / 1GB / $q))
            foreach ($p in 'BK1', 'BK2', 'BK3') { $x = @($l | Where-Object Profil -eq $p); Write-Output ("{0} : {1} sauvegarde(s){2}" -f $p, $x.Count, $(if ($x.Count) { ", dernière $($x[-1].Id)" } else { '' })) }
            if ($used / 1GB -gt 0.8 * $q) { Write-Output 'ALERTE : plus de 80 % du quota ; suppression MANUELLE uniquement (backup delete <id> --confirm).' }
            Write-Output 'Rétention : aucune suppression automatique ; quota global 10 Gio ; secrets jamais en clair ; modèles hors local (BK3 --external).'
        }
        'create' { if ($Args0.Count -lt 2) { throw 'Usage : backup create BK1|BK2|BK3 [--external <dossier>]' }; New-BackupSet $Args0[1].ToUpperInvariant() (& $opt '--external') | Format-List | Out-String | Write-Output }
        'verify' { if ($Args0.Count -lt 2) { throw 'Usage : backup verify <id|chemin>' }
            $v = Test-BackupSet $Args0[1]; Write-Audit 'backup.verify' $v.Id $(if ($v.Ok) { 'conforme' } else { 'NON CONFORME' }) ($v.Errors -join ' ; ')
            if ($v.Ok) { Write-Output "Sauvegarde $($v.Id) : CONFORME ($($v.Items) archives, empreintes et lisibilité vérifiées)." } else { throw "Sauvegarde $($v.Id) NON CONFORME : $($v.Errors -join ' ; ')" } }
        'delete' { if ($Args0.Count -lt 2) { throw 'Usage : backup delete <id> --confirm' }; $s = Get-BackupSet $Args0[1]
            if ($Args0 -notcontains '--confirm') { Write-Output ('Suppression DÉFINITIVE de {0} ({1:N2} Mio). Relancer avec --confirm.' -f $s.Manifest.id, ((Get-DirSizeBytes $s.Dir) / 1MB)); return }
            Remove-Item -Recurse -Force $s.Dir; Write-Audit 'backup.delete' $s.Manifest.id 'supprimé' 'demande explicite'; Write-Output "Sauvegarde $($s.Manifest.id) supprimée." }
        default { throw 'Usage : backup list | status | create BK1|BK2|BK3 [--external <dossier>] | verify <id|chemin> | delete <id> --confirm' }
    }
}
function Invoke-Restore {
    param([string[]]$Args0)
    if (-not $Args0 -or -not $Args0[0]) { throw 'Usage : restore <id> [--item <nom>] (--target-dir <dossier> | --volume-suffix <suffixe> | --production) [--confirm]' }
    $opt = { param($n) $k = [array]::IndexOf($Args0, $n); if ($k -ge 0 -and $k + 1 -lt $Args0.Count) { $Args0[$k + 1] } else { $null } }
    $s = Get-BackupSet $Args0[0]; $v = Test-BackupSet $s.Dir
    if (-not $v.Ok) { throw "Restauration refusée : sauvegarde non conforme ($($v.Errors -join ' ; '))." }
    $only = & $opt '--item'; $tdir = & $opt '--target-dir'; $sfx = & $opt '--volume-suffix'; $prod = $Args0 -contains '--production'; $go = $Args0 -contains '--confirm'
    if (-not $prod -and -not $tdir -and -not $sfx) { throw 'Cible requise : --target-dir <dossier> (fichiers), --volume-suffix <suffixe> (volumes témoins) ou --production.' }
    if ($sfx -and $sfx -notmatch '^[a-z0-9-]{2,20}$') { throw 'Suffixe : 2 à 20 caractères [a-z0-9-].' }
    $items = @($s.Manifest.items | Where-Object { -not $only -or $_.name -eq $only }); if (-not $items.Count) { throw "Élément '$only' absent de $($s.Manifest.id)." }
    $plan = foreach ($it in $items) {
        $target = if ($it.type -eq 'volume') { if ($prod) { $it.source } elseif ($sfx) { "$($it.source)-$sfx" } else { $null } }
                  elseif ($prod) { if ($it.name -eq 'projects-config') { Join-Path $Root 'projects' } else { "$Root (repo/) + profil utilisateur (host/)" } }
                  elseif ($tdir) { Join-Path $tdir $it.name } else { $null }
        $exists = if ($it.type -eq 'volume' -and $target) { (Invoke-Native docker @('volume', 'inspect', $target)).Code -eq 0 } elseif ($target -and -not $prod) { (Test-Path $target) -and @(Get-ChildItem $target -Force -ErrorAction SilentlyContinue).Count -gt 0 } else { $true }
        [pscustomobject]@{ Element = $it.name; Type = $it.type; Fichiers = $it.files; Taille = '{0:N2} Mio' -f ($it.bytes / 1MB); Cible = $(if ($target) { $target } else { '(ignoré : aucune cible pour ce type)' }); Existant = $exists }
    }
    Write-Output "Restauration de $($s.Manifest.id) ($($s.Manifest.profile), $($s.Manifest.created)) — sauvegarde CONFORME. Mode : $(if ($prod) { 'PRODUCTION (remplacement)' } else { 'témoin (aucun écrasement)' })"
    $plan | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    if (-not $prod -and @($plan | Where-Object { $_.Existant -and $_.Cible -notlike '(ignoré*' }).Count) { throw 'Cible témoin déjà existante ou non vide : aucun écrasement (choisir une autre cible).' }
    if (-not $go) { Write-Output 'PRÉVISUALISATION uniquement : rien n''a été modifié. Relancer avec --confirm.'; return }
    Assert-NoEmergency
    if ($prod) {
        $inUse = @((Invoke-Native docker @('ps', '--format', '{{.Names}}', '--filter', 'status=running')).Output -split "`n" | Where-Object { $_ -match '^local-ai-(opencode-1|proj-)' })
        if (@($items | Where-Object type -eq 'volume').Count -and $inUse.Count) { throw "Services utilisant les volumes en cours d'exécution ($($inUse -join ', ')) : .\local-ai.ps1 stop opencode et project stop <id> avant restauration de production." }
        $safety = New-BackupSet $(if (@($items | Where-Object type -eq 'volume').Count) { 'BK2' } else { 'BK1' }) $null
        Write-Output "Sauvegarde de sécurité préalable : $($safety.Id)"
    }
    $img = Get-BackupImage; $res = @()
    foreach ($it in $items) {
        $p = $plan | Where-Object Element -eq $it.name; if ($p.Cible -like '(ignoré*') { continue }
        $tmp = $null
        if ($it.type -eq 'volume') {
            $vol = $p.Cible; if (-not $prod) { $r = Invoke-Native docker @('volume', 'create', '--label', 'local-ai.volume=restore-test', '--label', "local-ai.restore-of=$($it.source)", $vol); if ($r.Code -ne 0) { throw $r.Output } }
            $mount = "${vol}:/dst"; $own = '0:0'   # root + CHOWN/DAC_OVERRIDE/FOWNER : un volume neuf appartient à root ; propriétaires restaurés par tar
        } else {
            $tmp = if ($prod) { Join-Path $BackupRoot "_restore_$(Get-Date -Format yyyyMMddHHmmss)" } else { $p.Cible }
            New-Item -ItemType Directory -Force $tmp | Out-Null; $mount = "${tmp}:/dst"; $own = $null
        }
        $cmd = "tar -xzf /b/$($it.archive) -C /dst && cd /dst && find . -type f -exec sha256sum {} + | sort -k2 > /tmp/now && cmp -s /tmp/now /b/$($it.files_sha256) && echo identique || echo DIFFERENT"
        $usr = if ($own) { @('--user', $own) } else { @('--user', '1000:1000') }
        $caps = if ($own -eq '0:0') { @('--cap-add', 'CHOWN', '--cap-add', 'DAC_OVERRIDE', '--cap-add', 'FOWNER') } else { @() }
        $r = Invoke-Native docker (@('run', '--rm', '--network', 'none', '--read-only', '--tmpfs', '/tmp', '--cap-drop', 'ALL') + $caps + @('--security-opt', 'no-new-privileges') + $usr + @('-v', "$($s.Dir):/b:ro", '-v', $mount, '--entrypoint', '/bin/busybox', $img, 'sh', '-c', $cmd))
        $ok = $r.Output -match 'identique'
        if ($ok -and $prod -and $it.type -ne 'volume') {
            if ($it.name -eq 'projects-config') { Copy-Item -Recurse -Force (Join-Path $tmp '*') (Join-Path $Root 'projects') }
            else { Copy-Item -Recurse -Force (Join-Path $tmp 'repo\*') $Root
                   foreach ($h in (Get-ChildItem (Join-Path $tmp 'host') -File -ErrorAction SilentlyContinue)) { $dst = switch ($h.Name) { '.wslconfig' { "$env:USERPROFILE\.wslconfig" } 'daemon.json' { "$env:USERPROFILE\.docker\daemon.json" } 'settings-store.json' { "$env:APPDATA\Docker\settings-store.json" } }; if ($dst) { Copy-Item -Force $h.FullName $dst } } }
            Remove-Item -Recurse -Force $tmp
        }
        $res += [pscustomobject]@{ Element = $it.name; Cible = $p.Cible; Integrite = $(if ($ok) { 'identique au manifeste' } else { "ÉCHEC : $($r.Output)" }) }
    }
    Write-Audit 'restore' $s.Manifest.id $(if ($prod) { 'production' } else { 'témoin' }) (($res | ForEach-Object { "$($_.Element)=$($_.Integrite)" }) -join ' ; ')
    $res | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    if (@($res | Where-Object { $_.Integrite -notlike 'identique*' }).Count) { throw 'Restauration incomplète (voir ci-dessus).' }
    if ($prod) { Write-Output 'Restauration de production terminée. Redémarrer : .\local-ai.ps1 start opencode (puis config).' }
}
function Invoke-Maintenance {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'status' }
    if ($sub -ne 'status') { throw 'Usage : maintenance status (lecture seule ; aucune purge automatique)' }
    $df = (Invoke-Native docker @('system', 'df', '--format', '{{.Type}}|{{.TotalCount}}|{{.Size}}|{{.Reclaimable}}')).Output -split "`n" | Where-Object { $_ }
    foreach ($l in $df) { $t, $n, $sz, $rc = $l -split '\|'; [pscustomobject]@{ Element = "Docker : $t"; Valeur = "$n, $sz (récupérable $rc)" } }
    $used = Get-DirSizeBytes $BackupRoot
    [pscustomobject]@{ Element = 'Sauvegardes locales'; Valeur = ('{0:N2} Gio / {1} Gio ; {2} sauvegarde(s), {3} point(s) de restauration' -f ($used / 1GB), (Get-BackupQuotaGiB), @(Get-BackupList).Count, @(Get-ChildItem (Join-Path $BackupRoot 'restore-points') -Directory -ErrorAction SilentlyContinue).Count) }
    $logs = Join-Path $Root 'runtime\logs'; [pscustomobject]@{ Element = 'Journaux (runtime/logs)'; Valeur = ('{0:N2} Mio ; audit 30 j, métriques 7 j (monitor)' -f ((Get-DirSizeBytes $logs) / 1MB)) }
    [pscustomobject]@{ Element = 'Métriques (runtime/monitor)'; Valeur = ('{0} fichier(s), {1:N2} Mio' -f @(Get-ChildItem (Join-Path $Root 'runtime\monitor') -Filter 'metrics-*.jsonl' -ErrorAction SilentlyContinue).Count, ((Get-DirSizeBytes (Join-Path $Root 'runtime\monitor')) / 1MB)) }
    [pscustomobject]@{ Element = 'Sentinelle RAM'; Valeur = $(if (Get-SentinelPid) { "active (PID $(Get-SentinelPid))" } else { 'arrêtée (garde RAM en repli prudent)' }) }
    [pscustomobject]@{ Element = 'Arrêt d''urgence'; Valeur = $(if (Test-Path $EmergencyFlag) { 'ACTIF' } else { 'inactif' }) }
    $oc = & (Join-Path $Root 'config\opencode\generate-config.ps1') -Check; [pscustomobject]@{ Element = 'Configuration OpenCode'; Valeur = "$oc" }
    [pscustomobject]@{ Element = 'Modèles chargés'; Valeur = $(if (@(Get-LoadedModels).Count) { (Get-LoadedModels) -join ', ' } else { 'aucun' }) }
    [pscustomobject]@{ Element = 'Mises à jour'; Valeur = 'aucune vérification en ligne (N1) ; images et extensions épinglées, mise à jour sur décision (guide maintenance)' }
    [pscustomobject]@{ Element = 'Purge'; Valeur = 'aucune automatique : docker image/volume/builder prune et backup delete sur décision explicite uniquement' }
}
