#Requires -Version 5.1
<#
.SYNOPSIS
  Administration de local-ai. Implémenté : help, status, config, start/stop (ollama, opencode), model, tui, mcp.
.EXAMPLE
  .\local-ai.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

$Implemented = [ordered]@{
    'help'   = 'Affiche cette aide'
    'status' = 'État en lecture seule : Docker, WSL2, ressources, disque, inventaire local-ai'
    'config' = 'Valide YAML, Compose, références agents/modèles, MCP, exclusions Git'
    'start'  = 'start [ollama|opencode] : démarre un module après validation (opencode démarre aussi ollama) ; aucun téléchargement implicite'
    'stop'   = 'stop [ollama|opencode] : arrête un module sans supprimer conteneurs, réseau ni volume'
    'model'  = 'model list | model show <tag> (lecture seule ; pull/rm NON IMPLÉMENTÉS)'
    'tui'    = 'Interface terminal OpenCode (dans le conteneur, serveur interne)'
    'mcp'    = 'mcp list | status | enable <id> --authorize-n4 [--witness] | disable <id> [--revoke] (relais N4 isolés)'
    'agent'  = 'agent list | agent model <agent> [<modèle>] | agent reset <agent|all> (BK1 + rollback, OpenCode régénéré)'
    'permissions'    = 'permissions list|check|grant|revoke|reset|profile (S1-S4, autorisations persistantes, refus techniques prioritaires)'
    'emergency-stop' = 'emergency-stop [status|clear] : interrompt les sessions, arrête agents et relais MCP, décharge les modèles (sans suppression)'
    'continue'       = 'continue install|on|off|status : autocomplétion locale qwen2.5-coder:1.5b via relais 127.0.0.1:11435 (désactivée par défaut)'
    'project'        = 'project list|create <id>|open <id>|stop <id> : projets Dev Containers isolés ; seul le projet ouvert est partagé avec OpenCode'
}
# Modules démarrables : profils Compose, image (variables .env), volumes externes requis, services arrêtés par stop
$Modules = @{
    'ollama'   = @{ Profiles = @('ollama'); ImagePrefix = 'OLLAMA'; Volumes = @('local-ai-ollama'); Service = 'ollama'; StopServices = @(); Secrets = @() }
    'opencode' = @{ Profiles = @('ollama', 'opencode'); ImagePrefix = 'OPENCODE'; Volumes = @('local-ai-ollama', 'local-ai-opencode'); Service = 'opencode'
                    StopServices = @('opencode', 'opencode-net'); Secrets = @('secrets\opencode.env'); ConfigCheck = 'config\opencode\generate-config.ps1' }
}
$Planned = [ordered]@{
    'profile'        = 'Afficher / appliquer un profil (A-C, N1-N4, S1-S4, BK1-BK3)'
    'monitor'        = 'Supervision selon config/monitoring/thresholds.yaml'
    'backup'         = 'Sauvegarde BK1 / BK2 / BK3'
    'restore'        = 'Restauration depuis un point de sauvegarde'
    'maintenance'    = 'Fenêtre de maintenance (profil N2)'
}
$EmergencyFlag = Join-Path $Root 'runtime\state\emergency.json'
. (Join-Path $Root 'scripts\mcp\n4.ps1')

function Write-Audit([string]$Action, [string]$Target, [string]$Result, [string]$Detail = '') {
    # Journal d'audit local (runtime/logs/audit.jsonl, non versionné). Jamais de secret ni de contenu de fichier.
    $dir = Join-Path $Root 'runtime\logs'; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $clean = ($Detail -replace '(?i)(token|password|secret|bearer|basic)\s*[:=]?\s*\S+', '$1=<masqué>')
    $o = [ordered]@{ ts = (Get-Date).ToString('o'); action = $Action; target = $Target; result = $Result; detail = $clean; profile = (Get-SecProfile) }
    [IO.File]::AppendAllText((Join-Path $dir 'audit.jsonl'), (($o | ConvertTo-Json -Compress) + "`n"), (New-Object Text.UTF8Encoding $false))
}

function Get-SecProfile {
    $m = [regex]::Match((Get-Content (Join-Path $Root 'profiles\defaults.yaml') -Raw -Encoding UTF8), '(?ms)^desired:.*?^\s+security:\s*(S[1-4])')
    if ($m.Success) { $m.Groups[1].Value } else { 'S2' }
}

function Assert-NoEmergency {
    if (Test-Path $EmergencyFlag) { throw "Arrêt d'urgence actif ($((Get-Content $EmergencyFlag -Raw | ConvertFrom-Json).ts)) : lever avec .\local-ai.ps1 emergency-stop clear" }
}

function Show-Help {
    Write-Output 'local-ai.ps1 <commande> [arguments]'
    Write-Output ''
    Write-Output 'Commandes implémentées :'
    foreach ($k in $Implemented.Keys) { Write-Output ('  {0,-15} {1}' -f $k, $Implemented[$k]) }
    Write-Output ''
    Write-Output 'Commandes prévues (NON IMPLÉMENTÉES, échouent explicitement) :'
    foreach ($k in $Planned.Keys) { Write-Output ('  {0,-15} {1}' -f $k, $Planned[$k]) }
}

function Invoke-Native {
    param([string]$Exe, [string[]]$ArgList)
    # PowerShell 5.1 : stderr natif + ErrorActionPreference=Stop deviendrait une exception.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ Code = $code; Output = ($out -join "`n") }
}

function Test-DockerEngine {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    (Invoke-Native docker @('info', '--format', '{{.ServerVersion}}')).Code -eq 0
}

function Get-YamlValue {
    param([string]$Path, [string]$Key)
    $m = Select-String -Path $Path -Pattern ('^\s*' + [regex]::Escape($Key) + ':\s*(\S+)') | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value.Trim('"') } else { $null }
}

function Show-Status {
    Write-Output '== local-ai status (lecture seule)'
    $thr = @{ Warning = 45; Critical = 30; Emergency = 15 }
    $free = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
    $level = if ($free -le $thr.Emergency) { 'URGENCE' } elseif ($free -le $thr.Critical) { 'CRITIQUE' } elseif ($free -le $thr.Warning) { 'ALERTE' } else { 'OK' }
    Write-Output ("SSD C: libre      : {0} Gio [{1}] (seuils 45/30/15)" -f $free, $level)

    $wsl = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $wsl) {
        $vals = (Get-Content $wsl | Where-Object { $_ -match '^(memory|processors|swap|autoMemoryReclaim)=' }) -join ' '
        Write-Output "WSL2 .wslconfig   : $vals"
    } else { Write-Output 'WSL2 .wslconfig   : absent' }

    $defaults = Join-Path $Root 'profiles\defaults.yaml'
    if (Test-Path $defaults) {
        $d = Get-Content $defaults -Raw
        $m = [regex]::Match($d, '(?ms)^desired:\s*\n\s+performance:\s*(\S+)\s*\n\s+network:\s*(\S+)\s*\n\s+security:\s*(\S+)\s*\n\s+backup:\s*(\S+)')
        if ($m.Success) { Write-Output ("Profils souhaités : {0}+{1}+{2}+{3}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value) }
    }

    if (-not (Test-DockerEngine)) { Write-Output 'Docker Engine     : INDISPONIBLE (Docker Desktop arrêté ?)'; return }
    $v = Invoke-Native docker @('version', '--format', '{{.Server.Version}}')
    $c = Invoke-Native docker @('compose', 'version', '--short')
    $i = Invoke-Native docker @('info', '--format', '{{.NCPU}}|{{.MemTotal}}|{{.LoggingDriver}}')
    $p = $i.Output.Split('|')
    Write-Output ("Docker Engine     : {0} | Compose {1}" -f $v.Output, $c.Output)
    Write-Output ("Ressources Docker : {0} CPU | {1} Gio RAM | logs {2}" -f $p[0], [math]::Round([double]$p[1] / 1GB, 2), $p[2])
    $ctr = @((Invoke-Native docker @('ps', '-aq', '--filter', 'label=com.docker.compose.project=local-ai')).Output -split "`n" | Where-Object { $_ }).Count
    $net = @((Invoke-Native docker @('network', 'ls', '--filter', 'name=local-ai-', '--format', '{{.Name}}')).Output -split "`n" | Where-Object { $_ })
    $vol = @((Invoke-Native docker @('volume', 'ls', '--filter', 'name=local-ai-', '--format', '{{.Name}}')).Output -split "`n" | Where-Object { $_ })
    Write-Output ("Inventaire local-ai : {0} conteneur(s) | réseaux: {1} | volumes: {2}" -f $ctr, ($(if ($net) { $net -join ',' } else { 'aucun' })), ($(if ($vol) { $vol -join ',' } else { 'aucun' })))
    foreach ($svc in 'ollama', 'opencode', 'opencode-net') {
        $id = (Invoke-Native docker @('ps', '-aq', '--filter', 'label=com.docker.compose.project=local-ai', '--filter', "label=com.docker.compose.service=$svc")).Output.Trim()
        $h = if ($id) { (Invoke-Native docker @('inspect', $id, '--format', '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}')).Output.Trim() } else { 'absent' }
        $extra = ''
        if ($svc -eq 'opencode-net' -and $id) { $extra = ' | port ' + (Invoke-Native docker @('port', $id)).Output.Trim() }
        if ($svc -eq 'ollama' -and $h -like 'running*') { $extra = ' | chargés : ' + @((Invoke-Native docker @('exec', $id, '/bin/ollama', 'ps')).Output -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() }).Count }
        Write-Output ("{0,-17} : {1}{2}" -f $svc, $h, $extra)
    }
    $mcpOn = @(Select-String -Path (Join-Path $Root 'mcp\registry.yaml') -Pattern '^\s+enabled:\s*true').Count
    $relays = @((Invoke-Native docker @('ps', '--filter', 'label=local-ai.module=mcp', '--format', '{{.Names}}')).Output -split "`n" | Where-Object { $_ })
    Write-Output ("MCP               : {0} activé(s) / 4 préparés (N4) | relais actifs : {1}" -f $mcpOn, $(if ($relays) { $relays -join ',' } else { 'aucun' }))
    Write-Output ("Sécurité          : profil {0} | arrêt d'urgence : {1}" -f (Get-SecProfile), $(if (Test-Path $EmergencyFlag) { 'ACTIF' } else { 'non' }))
}

function Test-YamlFile {
    param([string]$Path)
    # Validation syntaxique YAML via le parseur de docker compose (bloc d'extension x-*) : aucune dépendance.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("local-ai-yaml-{0}.yaml" -f [guid]::NewGuid())
    try {
        $body = (Get-Content $Path -Encoding UTF8 | ForEach-Object { '  ' + $_ }) -join "`n"
        [IO.File]::WriteAllText($tmp, "x-check:`n$body`n", (New-Object Text.UTF8Encoding $false))
        $r = Invoke-Native docker @('compose', '-f', $tmp, 'config', '-q', '--no-interpolate')
        if ($r.Code -eq 0) { $null } else { $r.Output -replace [regex]::Escape($tmp), $Path }
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Test-Config {
    $results = New-Object System.Collections.Generic.List[object]
    function Add-Result([string]$Check, [string]$Status, [string]$Detail = '') { $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail }) }
    Push-Location $Root
    try {
        # 1. Fichiers requis
        $required = 'compose.yaml', 'compose\services\core.yaml', '.env.example', '.gitignore', '.gitattributes', 'README.md',
                    'profiles\defaults.yaml', 'models\registry.yaml', 'mcp\registry.yaml', 'config\ollama\ollama.env', 'config\monitoring\thresholds.yaml'
        $missing = @($required | Where-Object { -not (Test-Path $_) })
        Add-Result 'Fichiers requis' $(if ($missing) { 'FAIL' } else { 'PASS' }) ($missing -join ', ')

        $docker = Test-DockerEngine
        $yamlFiles = @(Get-ChildItem -Recurse -File -Include *.yaml, *.yml | Where-Object { $_.FullName -notmatch '\\(backups|runtime|exports|projects\\(?!templates))\\' })
        if (-not $docker -and -not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Add-Result 'YAML (syntaxe)' 'NON TESTÉ' 'docker CLI absent'
        } else {
            $bad = @()
            foreach ($f in $yamlFiles) { $e = Test-YamlFile $f.FullName; if ($e) { $bad += "$($f.Name): $e" } }
            Add-Result ("YAML (syntaxe, {0} fichiers)" -f $yamlFiles.Count) $(if ($bad) { 'FAIL' } else { 'PASS' }) ($bad -join ' | ')

            $r = Invoke-Native docker @('compose', 'config', '-q')
            Add-Result 'Compose racine (interpolé)' $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }) $r.Output
            $ov = @('compose\overrides\egress.yaml', 'compose\overrides\cloud.yaml', 'compose\overrides\mcp.yaml')
            $a = @('compose'); foreach ($o in $ov) { $a += @('-f', $o) }
            $r = Invoke-Native docker (@('compose', '-f', 'compose.yaml') + ($ov | ForEach-Object { '-f', $_ }) + @('config', '-q'))
            Add-Result 'Compose racine + surcharges réseau' $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }) $r.Output
            $act = @('compose', '-f', 'tests\integration\compose-activation.yaml') + (@($ov + 'compose\overrides\ollama-localhost.yaml', 'compose\overrides\opencode-localhost.yaml') | ForEach-Object { '-f', $_ }) + @('config', '-q', '--no-interpolate')
            $r = Invoke-Native docker $act
            Add-Result 'Compose modèles + surcharges (structure)' $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }) $r.Output
            $r = Invoke-Native docker @('compose', '-f', 'tests\integration\compose-activation.yaml', 'config', '-q')
            Add-Result 'Garde image obligatoire (doit échouer)' $(if ($r.Code -ne 0 -and $r.Output -match 'required variable') { 'PASS' } else { 'FAIL' }) ''
        }

        # 2b. Épinglage réel : structure dépôt:version@sha256 dans les modèles + format des valeurs définies
        $pinRe = '^\s*image:\s*\$\{(\w+)_IMAGE_REPO:\?[^}]*\}:\$\{\1_IMAGE_TAG:\?[^}]*\}@sha256:\$\{\1_IMAGE_SHA256:\?[^}]*\}\s*$'
        $imgLines = @(Select-String -Path compose\templates\*.yaml -Pattern '^\s*image:')
        $badPin = @($imgLines | Where-Object { $_.Line -notmatch $pinRe } | ForEach-Object { $_.Filename })
        Add-Result ("Modèles : structure dépôt:version@sha256 ({0})" -f $imgLines.Count) $(if ($badPin -or -not $imgLines) { 'FAIL' } else { 'PASS' }) ($badPin -join ', ')
        $vals = @{}
        if (Test-Path .env) { Get-Content .env | Where-Object { $_ -match '^\s*(\w+_IMAGE_(TAG|SHA256))=(.*)$' } | ForEach-Object { $vals[$Matches[1]] = $Matches[3].Trim() } }
        Get-ChildItem env: | Where-Object { $_.Name -match '_IMAGE_(TAG|SHA256)$' } | ForEach-Object { $vals[$_.Name] = $_.Value }
        $badVal = @($vals.Keys | Where-Object {
            ($_ -like '*_SHA256' -and $vals[$_] -notmatch '^[0-9a-f]{64}$') -or ($_ -like '*_TAG' -and ($vals[$_] -eq '' -or $vals[$_] -match '^(latest|stable|main|edge)$'))
        })
        if ($vals.Count -eq 0) { Add-Result 'Valeurs d''épinglage (digest 64 hex, tag explicite)' 'NON APPLICABLE' 'aucune image définie' }
        else { Add-Result 'Valeurs d''épinglage (digest 64 hex, tag explicite)' $(if ($badVal) { 'FAIL' } else { 'PASS' }) ($badVal -join ', ') }

        # 3. Interdits dans Compose
        $composeText = (Get-ChildItem compose, tests\integration -Recurse -File -Include *.yaml | Get-Content -Raw) -join "`n"
        $forbidden = @('docker\.sock', 'privileged:\s*true', 'network_mode:\s*"?host', 'seccomp[:=]unconfined', '^\s*-\s*"?[A-Za-z]:\\', '"0\.0\.0\.0:')
        $hits = @($forbidden | Where-Object { $composeText -match ('(?m)' + $_) })
        Add-Result 'Compose : aucun élément interdit' $(if ($hits) { 'FAIL' } else { 'PASS' }) ($hits -join ', ')

        # 4. Références agents -> modèles / prompts
        $ids = @(Select-String -Path models\registry.yaml -Pattern '^\s*-\s*id:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        $agents = @(Get-ChildItem agents\definitions -Filter *.yaml)
        $refErr = @()
        foreach ($ag in $agents) {
            $ref = Get-YamlValue $ag.FullName 'ref'
            if (-not $ref -or $ids -notcontains $ref) { $refErr += "$($ag.Name): modèle '$ref' inconnu" }
            $ins = Get-YamlValue $ag.FullName 'instructions'
            if (-not $ins -or -not (Test-Path (Join-Path $ag.DirectoryName $ins))) { $refErr += "$($ag.Name): instructions '$ins' absentes" }
        }
        Add-Result ("Références agents ({0}) -> modèles/prompts" -f $agents.Count) $(if ($refErr) { 'FAIL' } else { 'PASS' }) ($refErr -join ' | ')
        $unconfirmed = @($agents | Where-Object { (Get-Content $_.FullName -Raw) -match 'confirmed:\s*false' }).Count
        Add-Result 'Affectations de modèles confirmées' $(if ($unconfirmed) { 'DIFFÉRÉ' } else { 'PASS' }) "$unconfirmed/$($agents.Count) à confirmer après benchmarks"

        # 5. MCP désactivés
        $enabled = @(Get-ChildItem mcp -Recurse -Filter server.yaml | Where-Object { (Get-Content $_.FullName -Raw) -match '(?m)^enabled:\s*true' }) + @(Select-String -Path mcp\registry.yaml -Pattern '^\s+enabled:\s*true')
        Add-Result 'MCP désactivés par défaut' $(if ($enabled) { 'FAIL' } else { 'PASS' }) ''

        # 5b. OpenCode : configuration générée à jour, secret local présent, publication 127.0.0.1 uniquement, garde de sortie
        $r = Invoke-Native powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'config\opencode\generate-config.ps1', '-Check')
        Add-Result 'OpenCode : opencode.json à jour' $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }) $(if ($r.Code -ne 0) { $r.Output } else { '' })
        $oc = Get-Content compose\templates\opencode.yaml -Raw
        $ocErr = @()
        if ($oc -notmatch 'egress-guard:\s*\r?\n\s+condition:\s*service_completed_successfully') { $ocErr += 'garde de sortie non obligatoire' }
        if ([regex]::Matches($oc, '(?m)^\s*-\s*"(?!127\.0\.0\.1:)[^"]*:\d+"\s*$').Count) { $ocErr += 'port hors 127.0.0.1' }
        if ($oc -match 'cap_add:\s*\[(?!NET_ADMIN\]|CHOWN\])') { $ocErr += 'capacité non prévue' }
        Add-Result 'OpenCode : isolation et exposition' $(if ($ocErr) { 'FAIL' } else { 'PASS' }) ($ocErr -join ', ')
        Add-Result 'OpenCode : secret local' $(if (Test-Path secrets\opencode.env) { 'PASS' } else { 'FAIL' }) $(if (-not (Test-Path secrets\opencode.env)) { 'secrets/opencode.env absent' } else { '' })

        # 6. .env non sensible
        $secretLines = @(Get-Content .env, .env.example -ErrorAction SilentlyContinue | Where-Object { $_ -match '^(?!#)\w*(TOKEN|PASSWORD|SECRET|API_KEY)\w*=\S+' })
        Add-Result '.env sans secret' $(if ($secretLines) { 'FAIL' } else { 'PASS' }) ''

        # 7. Exclusions Git
        if (Test-Path .git) {
            $mustIgnore = '.env', 'secrets/mcp-github.env', 'secrets/opencode.env', 'backups/restore-points/x/f.json', 'runtime/logs/a.log', 'exports/e.zip', 'projects/demo/app.py', 'models/m.gguf', '.opencode/state.json'
            $mustTrack = '.env.example', 'secrets/README.md', 'projects/templates/README.md', 'mcp/github/.env.example', 'config/ollama/ollama.env', 'config/opencode/opencode.env'
            $notIgnored = @($mustIgnore | Where-Object { (Invoke-Native git @('check-ignore', '-q', '--no-index', $_)).Code -ne 0 })
            $wrongIgnored = @($mustTrack | Where-Object { (Invoke-Native git @('check-ignore', '-q', '--no-index', $_)).Code -eq 0 })
            Add-Result 'Exclusions Git' $(if ($notIgnored -or $wrongIgnored) { 'FAIL' } else { 'PASS' }) ((@($notIgnored | ForEach-Object { "non exclu: $_" }) + @($wrongIgnored | ForEach-Object { "exclu à tort: $_" })) -join ' | ')
        } else { Add-Result 'Exclusions Git' 'NON TESTÉ' 'dépôt Git absent' }
    } finally { Pop-Location }

    $results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Output
    $fail = @($results | Where-Object Status -eq 'FAIL').Count
    Write-Output ("Résultat : {0} PASS, {1} FAIL, {2} autres" -f @($results | Where-Object Status -eq 'PASS').Count, $fail, @($results | Where-Object { $_.Status -notin 'PASS', 'FAIL' }).Count)
    if ($fail) { exit 1 }
}

function Get-EnvValue {
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v) { return $v.Trim() }
    $f = Join-Path $Root '.env'
    if (Test-Path $f) {
        $m = Select-String -Path $f -Pattern ('^\s*' + [regex]::Escape($Name) + '=(.*)$') | Select-Object -Last 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    $null
}

function Resolve-Module {
    param([string[]]$Args0)
    $name = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'ollama' }
    if (-not $Modules.ContainsKey($name)) { throw "Module '$name' inconnu ou non activé (disponibles : $($Modules.Keys -join ', '))." }
    $m = $Modules[$name].Clone(); $m.Name = $name; $m
}

function Assert-Preflight {
    param($Module)
    $errs = @()
    if (-not (Test-DockerEngine)) { throw 'Docker Engine indisponible : démarrer Docker Desktop.' }
    Push-Location $Root
    try {
        $r = Invoke-Native docker @('compose', 'config', '-q')
        if ($r.Code -ne 0) { $errs += "docker compose config : $($r.Output)" }
        $p = $Module.ImagePrefix
        $repo = Get-EnvValue "${p}_IMAGE_REPO"; $tag = Get-EnvValue "${p}_IMAGE_TAG"; $sha = Get-EnvValue "${p}_IMAGE_SHA256"
        if (-not $repo) { $errs += "${p}_IMAGE_REPO absent" }
        if (-not $tag -or $tag -match '^(latest|stable|main|edge)$') { $errs += "${p}_IMAGE_TAG absent ou non explicite" }
        if ($sha -notmatch '^[0-9a-f]{64}$') { $errs += "${p}_IMAGE_SHA256 absent ou invalide (64 hex)" }
        if (-not $errs) {
            $ref = "${repo}@sha256:${sha}"
            if ((Invoke-Native docker @('image', 'inspect', $ref, '--format', '{{.Id}}')).Code -ne 0) {
                $errs += "image $repo`:$tag@sha256:$($sha.Substring(0,12))… absente localement (aucun téléchargement implicite : docker pull explicite requis)"
            }
        }
        foreach ($v in $Module.Volumes) {
            if ((Invoke-Native docker @('volume', 'inspect', $v, '--format', '{{.Name}}')).Code -ne 0) { $errs += "volume externe '$v' absent (à provisionner : docker volume create $v)" }
        }
        foreach ($s in $Module.Secrets) { if (-not (Test-Path $s)) { $errs += "secret '$s' absent (non versionné, voir secrets/README.md)" } }
        if ($Module.ContainsKey('ConfigCheck')) {
            $r = Invoke-Native powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Module.ConfigCheck, '-Check')
            if ($r.Code -ne 0) { $errs += $r.Output }
        }
        $free = (Get-PSDrive C).Free / 1GB
        if ($free -lt 30) { $errs += ("SSD libre {0:N1} Gio < 30 Gio : démarrage bloqué" -f $free) }
    } finally { Pop-Location }
    if ($errs) { throw ("Validation préalable ÉCHOUÉE :`n - " + ($errs -join "`n - ")) }
    Write-Output "Validation préalable : OK ($($Module.Name))"
}

function Start-Module {
    param([string[]]$Args0)
    $m = Resolve-Module $Args0
    Assert-NoEmergency
    Assert-Preflight $m
    Write-Audit 'start' $m.Name 'demandé'
    Push-Location $Root
    try {
        $pf = @($m.Profiles | ForEach-Object { '--profile', $_ })
        $r = Invoke-Native docker (@('compose') + $pf + @('up', '-d', '--pull', 'never', '--no-build'))
        if ($r.Code -ne 0) { throw "docker compose up a échoué : $($r.Output)" }
        $deadline = (Get-Date).AddSeconds(180)
        do {
            $id = (Invoke-Native docker (@('compose') + $pf + @('ps', '-q', $m.Service))).Output.Trim()
            $h = if ($id) { (Invoke-Native docker @('inspect', $id, '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')).Output.Trim() } else { 'absent' }
            if ($h -in 'healthy', 'unhealthy', 'exited', 'absent') { break }
            Start-Sleep -Seconds 3
        } while ((Get-Date) -lt $deadline)
        Write-Output "Module $($m.Name) : $h"
        if ($h -ne 'healthy') { exit 1 }
    } finally { Pop-Location }
}

function Stop-Module {
    param([string[]]$Args0)
    $m = Resolve-Module $Args0
    if (-not (Test-DockerEngine)) { throw 'Docker Engine indisponible.' }
    Push-Location $Root
    try {
        $pf = @($m.Profiles | ForEach-Object { '--profile', $_ })
        $r = Invoke-Native docker (@('compose') + $pf + @('stop') + @($m.StopServices))
        if ($r.Code -ne 0) { throw "docker compose stop a échoué : $($r.Output)" }
        Write-Output "Module $($m.Name) arrêté (conteneurs, réseau et volume conservés)."
    } finally { Pop-Location }
}

function Get-OllamaContainer {
    if (-not (Test-DockerEngine)) { throw 'Docker Engine indisponible.' }
    $id = (Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', 'ps', '-q', '--status', 'running', 'ollama')).Output.Trim()
    if (-not $id) { throw "Ollama n'est pas démarré (.\local-ai.ps1 start)." }
    $id
}

function Get-RegistryModels {
    $text = Get-Content (Join-Path $Root 'models\registry.yaml') -Raw -Encoding UTF8
    $blocks = [regex]::Split($text, '(?m)^\s*-\s+id:\s*') | Select-Object -Skip 1
    foreach ($b in $blocks) {
        $get = { param($k) $m = [regex]::Match($b, '(?m)^\s+' + $k + ':\s*"?([^"\r\n]*)"?'); if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null } }
        [pscustomobject]@{ Id = ($b -split '\s')[0]; Tag = (& $get 'tag'); Status = (& $get 'status'); Test = (& $get 'offline_test') }
    }
}

function Invoke-Model {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'list' }
    switch ($sub) {
        'list' {
            $c = Get-OllamaContainer
            $reg = @(Get-RegistryModels)
            $live = (Invoke-Native docker @('exec', $c, '/bin/ollama', 'list')).Output -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() }
            $rows = foreach ($l in $live) {
                $f = $l -split '\s{2,}'
                $r = $reg | Where-Object Tag -eq $f[0] | Select-Object -First 1
                [pscustomobject]@{ Tag = $f[0]; ID = $f[1]; Size = $f[2]; Registre = $(if ($r) { $r.Id } else { 'NON RÉFÉRENCÉ' }); Statut = $(if ($r) { $r.Status } else { '' }); Test = $(if ($r) { $r.Test } else { '' }) }
            }
            $liveTags = @($rows | ForEach-Object { $_.Tag })
            $missing = @($reg | Where-Object { $liveTags -notcontains $_.Tag } | ForEach-Object { $_.Tag })
            $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
            Write-Output ("Chargés : {0}" -f @((Invoke-Native docker @('exec', $c, '/bin/ollama', 'ps')).Output -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() }).Count)
            if ($missing) { Write-Output ("Référencés absents : {0}" -f ($missing -join ', ')) }
        }
        'show' {
            if (-not $Args0 -or $Args0.Count -lt 2) { throw 'Usage : .\local-ai.ps1 model show <tag>' }
            $tag = $Args0[1]
            if (-not (@(Get-RegistryModels) | Where-Object Tag -eq $tag)) { throw "Modèle '$tag' absent de models/registry.yaml." }
            $c = Get-OllamaContainer
            $r = Invoke-Native docker @('exec', $c, '/bin/ollama', 'show', $tag)
            if ($r.Code -ne 0) { throw "ollama show a échoué : $($r.Output)" }
            Write-Output $r.Output
        }
        default { Write-Error ("Sous-commande 'model {0}' NON IMPLÉMENTÉE (disponibles : list, show)." -f $sub) -ErrorAction Continue; exit 2 }
    }
}

# ------------------------------------------------------------------ agents (affectation manuelle des modèles)
function Get-ModelInfo {
    # Registre + synthèse des benchmarks 6.B.1 (outils, RAM) pour les avertissements.
    $text = Get-Content (Join-Path $Root 'models\registry.yaml') -Raw -Encoding UTF8
    foreach ($b in ([regex]::Split($text, '(?m)^\s*-\s+id:\s*') | Select-Object -Skip 1)) {
        $bm = [regex]::Match($b, '(?m)^\s+benchmark:\s*\{([^\r\n]*)\}').Groups[1].Value
        $num = { param($k) $m = [regex]::Match($bm, '\b' + $k + ':\s*([\d.]+)'); if ($m.Success) { [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) } else { $null } }
        [pscustomobject]@{ Id = ($b -split '\s')[0]; Tag = [regex]::Match($b, '(?m)^\s+tag:\s*(\S+)').Groups[1].Value
            Tools = (& $num 'tools'); Ram8192 = (& $num 'peak_wsl_pct_8192'); Score = (& $num 'score') }
    }
}

function Get-AgentInfo {
    $u = New-Object Text.UTF8Encoding $false
    $init = @{}; Get-Content (Join-Path $Root 'agents\assignments.initial.yaml') -Encoding UTF8 | Where-Object { $_ -match '^\s{2}([\w-]+):\s*(\S+)' } | ForEach-Object { $init[$Matches[1]] = $Matches[2] }
    foreach ($f in (Get-ChildItem (Join-Path $Root 'agents\definitions') -Filter *.yaml | Sort-Object Name)) {
        $t = [IO.File]::ReadAllText($f.FullName, $u)
        $tools = [regex]::Match($t, '(?ms)^tools:\s*\r?\n((?:\s+-\s*\S+\r?\n?)*)').Groups[1].Value
        [pscustomobject]@{ Id = [regex]::Match($t, '(?m)^id:\s*(\S+)').Groups[1].Value; Ref = [regex]::Match($t, '(?m)^\s+ref:\s*(\S+)').Groups[1].Value
            Initial = $init[[regex]::Match($t, '(?m)^id:\s*(\S+)').Groups[1].Value]; Continue = ($t -match '(?m)^type:\s*continue-autocomplete')
            UsesTools = [bool]($tools -match '-\s*(edit|write|bash|test)'); File = $f.FullName }
    }
}

function Get-ModelWarnings($Agent, $Model) {
    $w = @()
    if ($Agent.Continue) { $w += 'Continue : hors OpenCode, intégration différée (étape 11)' }
    elseif ($null -ne $Model.Tools -and $Model.Tools -eq 0) { $w += "OUTILS : appels d'outils non extraits par Ollama (6.B.1, tools=0)$(if ($Agent.UsesTools) { ' — agent à outils (edit/bash/test)' })" }
    if ($null -ne $Model.Ram8192 -and $Model.Ram8192 -ge 80) { $w += ("RAM : pic {0} % de RAM WSL2 à 8192 (alerte 85 %), usage exclusif" -f $Model.Ram8192) }
    elseif ($null -ne $Model.Ram8192 -and $Model.Ram8192 -ge 50) { $w += ("RAM : pic {0} % à 8192" -f $Model.Ram8192) }
    $w
}

function Invoke-OpenCodeReload {
    # Régénère la configuration OpenCode ; redémarre le service si actif (espace réseau isolé conservé) et vérifie l'agent.
    param([string]$AgentId, [string]$Tag)
    $r = Invoke-Native powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'config\opencode\generate-config.ps1'))
    if ($r.Code -ne 0) { throw "génération OpenCode : $($r.Output)" }
    $j = Get-Content (Join-Path $Root 'config\opencode\opencode.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($AgentId -and $env:LOCAL_AI_TEST_FAIL_RELOAD -eq '1') { throw 'échec simulé (LOCAL_AI_TEST_FAIL_RELOAD=1, test du rollback)' }
    if ($AgentId -and $Tag -and $j.agents.$AgentId.model -ne "ollama/$Tag") { throw "opencode.json : agent $AgentId -> $($j.agents.$AgentId.model) (attendu ollama/$Tag)" }
    $sv = $j.agents.PSObject.Properties["$AgentId-delegue"]; if ($AgentId -and $Tag -and $sv -and $sv.Value.model -ne "ollama/$Tag") { throw "opencode.json : variante $AgentId-delegue -> $($sv.Value.model) (attendu ollama/$Tag)" }
    $id = (Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'opencode', 'ps', '-q', '--status', 'running', 'opencode')).Output.Trim()
    if (-not $id) { return 'OpenCode arrêté : configuration appliquée au prochain démarrage' }
    $r = Invoke-Native docker @('restart', $id); if ($r.Code -ne 0) { throw "redémarrage OpenCode : $($r.Output)" }
    $deadline = (Get-Date).AddSeconds(120)
    do { Start-Sleep 3; $h = (Invoke-Native docker @('inspect', $id, '--format', '{{.State.Health.Status}}')).Output.Trim() } while ($h -ne 'healthy' -and (Get-Date) -lt $deadline)
    if ($h -ne 'healthy') { throw "OpenCode non sain après redémarrage ($h)" }
    if ($AgentId -and $Tag) {
        # Le serveur charge la configuration peu après le redémarrage : vérification répétée (30 s max), agent et variante déléguée.
        foreach ($ag in @($AgentId) + @(if ($sv) { "$AgentId-delegue" })) {
            $ok = $false
            for ($i = 0; $i -lt 10 -and -not $ok; $i++) {
                $a = (Invoke-Native docker @('exec', $id, 'opencode', 'api', '--server', 'http://127.0.0.1:4096', 'GET', "/api/agent/$ag")).Output
                $ok = $a -match ('"model":\{"id":"' + [regex]::Escape($Tag) + '","providerID":"ollama"'); if (-not $ok) { Start-Sleep 3 }
            }
            if (-not $ok) { throw "serveur OpenCode : agent $ag sans le modèle $Tag" }
        }
    }
    'OpenCode redémarré (sain), agent vérifié via l''API'
}

function New-AgentRestorePoint([string]$AgentId, [string[]]$Files) {
    # BK1 : copie des fichiers de configuration concernés + SHA256SUMS.txt + manifest (aucun secret).
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir = Join-Path $Root "backups\restore-points\agent_${AgentId}_$ts"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $sums = @(); $man = @("restore_point: agent_${AgentId}_$ts", 'profile: BK1', "created: $(Get-Date -Format s)", 'files:')
    foreach ($f in $Files) {
        $rel = $f.Substring($Root.Length + 1); $dst = Join-Path $dir $rel
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null; Copy-Item $f $dst
        $h = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLowerInvariant(); $sums += "$h  $($rel -replace '\\','/')"; $man += "  - $($rel -replace '\\','/')"
    }
    [IO.File]::WriteAllLines((Join-Path $dir 'SHA256SUMS.txt'), [string[]]$sums); [IO.File]::WriteAllLines((Join-Path $dir 'manifest.yaml'), [string[]]$man)
    $dir
}

function Restore-AgentRestorePoint([string]$Dir) {
    foreach ($l in (Get-Content (Join-Path $Dir 'SHA256SUMS.txt'))) {
        $h, $rel = $l -split '\s+', 2; $src = Join-Path $Dir $rel
        if ((Get-FileHash $src -Algorithm SHA256).Hash.ToLowerInvariant() -ne $h) { throw "intégrité du point de restauration : $rel" }
        Copy-Item $src (Join-Path $Root $rel) -Force
    }
}

function Set-AgentModel($Agent, $Model, [string]$Reason) {
    if ($Agent.Ref -eq $Model.Id) { return "Agent $($Agent.Id) : déjà sur $($Model.Id) ($($Model.Tag)), aucune modification." }
    $cfg = Join-Path $Root 'config\opencode\opencode.json'
    $bk = New-AgentRestorePoint $Agent.Id @($Agent.File, $cfg)
    $u = New-Object Text.UTF8Encoding $false
    try {
        $t = [IO.File]::ReadAllText($Agent.File, $u)
        $n = [regex]::Replace($t, '(?m)^(\s+ref:\s*)\S+', '${1}' + $Model.Id, 1)
        [IO.File]::WriteAllText($Agent.File, $n, $u)
        $msg = Invoke-OpenCodeReload $(if ($Agent.Continue) { $null } else { $Agent.Id }) $Model.Tag
    } catch {
        $err = $_.Exception.Message
        Restore-AgentRestorePoint $bk
        try { [void](Invoke-OpenCodeReload) } catch { }
        throw "ÉCHEC ($err) — ROLLBACK effectué depuis $($bk.Substring($Root.Length + 1))"
    }
    "Agent $($Agent.Id) : $($Agent.Ref) -> $($Model.Id) ($($Model.Tag)) [$Reason] | $msg | point BK1 : $($bk.Substring($Root.Length + 1))"
}

function Invoke-Agent {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'list' }
    $agents = @(Get-AgentInfo); $models = @(Get-ModelInfo)
    $findAgent = { param($n) $a = $agents | Where-Object Id -eq $n | Select-Object -First 1; if (-not $a) { throw "Agent '$n' inconnu (agents : $($agents.Id -join ', '))." }; $a }
    $findModel = { param($n) $m = $models | Where-Object { $_.Id -eq $n -or $_.Tag -eq $n } | Select-Object -First 1; if (-not $m) { throw "Modèle '$n' absent de models/registry.yaml (aucun téléchargement ; disponibles : $($models.Tag -join ', '))." }; $m }
    switch ($sub) {
        'list' {
            $agents | ForEach-Object { $a = $_; $m = $models | Where-Object Id -eq $a.Ref | Select-Object -First 1
                [pscustomobject]@{ Agent = $a.Id; Modèle = $(if ($m) { $m.Tag } else { "$($a.Ref) (INCONNU)" }); Initial = $(if ($a.Ref -eq $a.Initial) { 'oui' } else { "NON ($($a.Initial))" })
                    Client = $(if ($a.Continue) { 'Continue' } else { 'OpenCode' }); Avertissements = ((Get-ModelWarnings $a $m) -join ' ; ') } } | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Output
            Write-Output 'Sélection temporaire (session uniquement) : Web http://127.0.0.1:4096 ou TUI (.\local-ai.ps1 tui), sélecteur de modèle.'
        }
        'model' {
            if (-not $Args0 -or $Args0.Count -lt 2) { throw 'Usage : .\local-ai.ps1 agent model <agent> [<modèle>]' }
            $a = & $findAgent $Args0[1]
            if ($Args0.Count -lt 3) {
                $m = $models | Where-Object Id -eq $a.Ref | Select-Object -First 1; $mi = $models | Where-Object Id -eq $a.Initial | Select-Object -First 1
                Write-Output ("Agent {0} : {1} ({2}) | initial : {3} ({4}) | client : {5}" -f $a.Id, $a.Ref, $m.Tag, $a.Initial, $mi.Tag, $(if ($a.Continue) { 'Continue' } else { 'OpenCode' }))
                foreach ($w in (Get-ModelWarnings $a $m)) { Write-Output "  ! $w" }
                return
            }
            $m = & $findModel $Args0[2]
            foreach ($w in (Get-ModelWarnings $a $m)) { Write-Output "  ! $w (aucune substitution automatique)" }
            Write-Output (Set-AgentModel $a $m 'manuel')
        }
        'reset' {
            if (-not $Args0 -or $Args0.Count -lt 2) { throw 'Usage : .\local-ai.ps1 agent reset <agent|all>' }
            $targets = if ($Args0[1] -eq 'all') { $agents } else { @(& $findAgent $Args0[1]) }
            foreach ($a in $targets) { $m = & $findModel $a.Initial; Write-Output (Set-AgentModel $a $m 'restauration initiale') }
        }
        default { Write-Error ("Sous-commande 'agent {0}' NON IMPLÉMENTÉE (disponibles : list, model, reset)." -f $sub) -ErrorAction Continue; exit 2 }
    }
}

function Get-McpServers {
    $reg = Get-Content (Join-Path $Root 'mcp\registry.yaml') -Raw -Encoding UTF8
    foreach ($b in ([regex]::Split($reg, '(?m)^\s*-\s+id:\s*') | Select-Object -Skip 1)) {
        $id = ($b -split '\s')[0]
        $def = Join-Path $Root "mcp\$id\server.yaml"
        $d = if (Test-Path $def) { Get-Content $def -Raw -Encoding UTF8 } else { '' }
        $g = { param($t, $k) $m = [regex]::Match($t, '(?m)^\s*' + $k + ':\s*"?([^"\r\n#]*)"?'); if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null } }
        [pscustomobject]@{
            Id = $id; Name = (& $g $b 'name'); Enabled = ((& $g $b 'enabled') -eq 'true' -or (& $g $d 'enabled') -eq 'true')
            Status = (& $g $d 'status'); Activation = (& $g $d 'activation'); Transport = (& $g $d 'transport')
            Endpoint = $(if ((& $g $d 'transport') -eq 'stdio' -or -not (& $g $d 'url')) { & $g $d 'image' } else { & $g $d 'url' }); Secret = (& $g $d 'env_file'); Definition = $def
        }
    }
}

function Invoke-Mcp {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'list' }
    $servers = @(Get-McpServers)
    $pick = {
        if (-not $Args0 -or $Args0.Count -lt 2) { throw "Usage : .\local-ai.ps1 mcp $sub <id> (ids : $($servers.Id -join ', '))" }
        $s = $servers | Where-Object Id -eq $Args0[1].ToLowerInvariant() | Select-Object -First 1
        if (-not $s) { throw "Serveur MCP '$($Args0[1])' inconnu (ids : $($servers.Id -join ', '))." }
        $s
    }
    switch ($sub) {
        'list' { $servers | Select-Object Id, Name, @{ n = 'Activé'; e = { if ($_.Enabled) { 'OUI' } else { 'non' } } }, Status, Activation, Transport | Format-Table -AutoSize | Out-String -Width 200 | Write-Output }
        'status' {
            $ocMcp = 0
            $cfg = Join-Path $Root 'config\opencode\opencode.json'
            if (Test-Path $cfg) { $j = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json; $ocMcp = @($j.mcp.servers.PSObject.Properties).Count }
            $net = (Invoke-Native docker @('network', 'inspect', 'local-ai-mcp', '--format', '{{.Name}}')).Code -eq 0
            $rows = foreach ($s in $servers) {
                [pscustomobject]@{ Id = $s.Id; Activé = $(if ($s.Enabled) { 'OUI' } else { 'non' }); Activation = $s.Activation; Transport = $s.Transport
                    Secret = $(if ($s.Secret -and (Test-Path (Join-Path $Root $s.Secret))) { 'présent (non affiché)' } else { 'absent' }); Cible = $s.Endpoint }
            }
            $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
            Write-Output ("Réseau local-ai-mcp (N4) : {0} | serveurs MCP dans opencode.json : {1} | politique OpenCode mcp.use : deny *" -f $(if ($net) { 'présent' } else { 'absent' }), $ocMcp)
        }
        'enable' {
            $s = & $pick
            $witness = $Args0 -contains '--witness'
            $why = @()
            if ($Args0 -notcontains '--authorize-n4') { $why += 'autorisation explicite absente (--authorize-n4)' }
            if (Test-Path $EmergencyFlag) { $why += "arrêt d'urgence actif" }
            $d = $null; try { $d = Get-N4Definition $Root $s.Id } catch { $why += $_.Exception.Message }
            if ($d) {
                if ($d.Type -notin 'container-http', 'remote-http') { $why += "type de relais '$($d.Type)' non pris en charge" }
                $imgs = @($script:N4Squid) + @(if ($d.Type -eq 'container-http') { $d.Image }) + @(if ($witness) { $script:N4Witness })
                foreach ($i in $imgs) {
                    if ($i -notmatch '@sha256:[0-9a-f]{64}$') { $why += "image non épinglée : $i" }
                    elseif ((Invoke-Native docker @('image', 'inspect', $i, '--format', '{{.Id}}')).Code -ne 0) { $why += "image absente localement (aucun téléchargement implicite) : $i" }
                }
                if (-not $witness -and -not (Test-Path $d.SecretFile)) { $why += "secret 'secrets/mcp-$($s.Id).env' absent (jeton lecture seule à créer par l'utilisateur ; aucun jeton créé ici)" }
            }
            if ((Invoke-Native docker @('network', 'inspect', 'local-ai-mcp-relay', '--format', '{{.Name}}')).Code -ne 0) { $why += 'réseau local-ai-mcp-relay absent (.\local-ai.ps1 start opencode)' }
            if ($why) { Write-Audit 'mcp.enable' $s.Id 'refusé' ($why -join ' ; '); Write-Error ("Activation MCP '{0}' REFUSÉE :`n - {1}" -f $s.Id, ($why -join "`n - ")) -ErrorAction Continue; exit 3 }
            $dir = $null
            try {
                $dir = New-N4Files $Root $d -Witness:$witness
                $r = Invoke-N4Compose $Root $s.Id @('up', '-d', '--pull', 'never', '--no-build'); if ($r.Code -ne 0) { throw "démarrage des relais : $($r.Output)" }
                $netId = (Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'opencode', 'ps', '-q', 'opencode-net')).Output.Trim()
                $probe = ''; for ($i = 0; $i -lt 10 -and $probe -notmatch 'HTTP/1\.1 [2-4]\d\d'; $i++) { Start-Sleep 2; $probe = (Invoke-Native docker @('exec', $netId, '/bin/busybox', 'wget', '-S', '-q', '-O', '/dev/null', '-T', '5', "http://mcp-relay-$($s.Id):8080$($d.Path)")).Output }
                if ($probe -notmatch 'HTTP/1\.1 [2-4]\d\d') { throw "relais injoignable depuis OpenCode : $probe" }
                if ($witness) { [IO.File]::WriteAllText((Join-Path $dir 'witness'), (Get-Date).ToString('o')) }
                else { $rf = Join-Path $Root 'mcp\registry.yaml'; $t = [IO.File]::ReadAllText($rf); [IO.File]::WriteAllText($rf, [regex]::Replace($t, '(?ms)(-\s+id:\s*' + [regex]::Escape($s.Id) + '\s.*?^\s+enabled:\s*)false', '${1}true'), (New-Object Text.UTF8Encoding $false)) }
                $msg = Invoke-OpenCodeReload
            } catch {
                $err = $_.Exception.Message
                if ($dir) { [void](Invoke-N4Compose $Root $s.Id @('down')) ; Remove-Item (Join-Path $dir 'witness') -ErrorAction SilentlyContinue }
                if (-not $witness) { $rf = Join-Path $Root 'mcp\registry.yaml'; $t = [IO.File]::ReadAllText($rf); [IO.File]::WriteAllText($rf, [regex]::Replace($t, '(?ms)(-\s+id:\s*' + [regex]::Escape($s.Id) + '\s.*?^\s+enabled:\s*)true', '${1}false'), (New-Object Text.UTF8Encoding $false)) }
                try { [void](Invoke-OpenCodeReload) } catch { }
                Write-Audit 'mcp.enable' $s.Id 'échec+rollback' $err
                throw "Activation MCP '$($s.Id)' ÉCHOUÉE ($err) — relais arrêtés, configuration restaurée."
            }
            Write-Audit 'mcp.enable' $s.Id $(if ($witness) { 'activé (témoin local)' } else { 'activé (N4)' }) ($d.Allow -join ',')
            Write-Output ("MCP {0} : activé {1} — relais mcp-relay-{0}, sortie limitée à {2} | {3}" -f $s.Id, $(if ($witness) { 'en TÉMOIN LOCAL (jeton fictif, aucune connexion externe)' } else { '(N4, lecture seule)' }), $(if ($witness) { 'witness-allowed' } else { $d.Allow -join ', ' }), $msg)
        }
        'disable' {
            $s = & $pick
            $u = New-Object Text.UTF8Encoding $false; $changed = 0
            foreach ($f in @($s.Definition, (Join-Path $Root 'mcp\registry.yaml'))) {
                $t = [IO.File]::ReadAllText($f, $u)
                $n = if ($f -like '*registry.yaml') { [regex]::Replace($t, '(?ms)(-\s+id:\s*' + [regex]::Escape($s.Id) + '\s.*?^\s+enabled:\s*)true', '${1}false') } else { [regex]::Replace($t, '(?m)^enabled:\s*true', 'enabled: false') }
                if ($n -ne $t) { [IO.File]::WriteAllText($f, $n, $u); $changed++ }
            }
            $dir = Get-N4Dir $Root $s.Id
            if (Test-Path (Join-Path $dir 'compose.yaml')) { $r = Invoke-N4Compose $Root $s.Id @('down'); if ($r.Code -ne 0) { throw "arrêt des relais : $($r.Output)" }; $changed++ }
            $wasWitness = Test-Path (Join-Path $dir 'witness')
            if ($wasWitness -or (Test-Path $dir)) { Remove-Item $dir -Recurse -Force; $changed++ }   # fichiers générés uniquement (runtime/)
            $revoked = $false
            if ($Args0 -contains '--revoke') { $af = Join-Path $Root "secrets\mcp-$($s.Id).relay-auth.conf"; if (Test-Path $af) { Remove-Item $af -Force; $revoked = $true } }
            $msg = Invoke-OpenCodeReload
            Write-Audit 'mcp.disable' $s.Id 'désactivé' $(if ($revoked) { 'copie relais du jeton supprimée' } else { '' })
            Write-Output ("MCP {0} : {1}{2} | {3}" -f $s.Id, $(if ($changed) { 'désactivé, relais arrêtés et supprimés' } else { 'déjà désactivé' }), $(if ($revoked) { ' ; copie du jeton pour le relais supprimée (révoquer aussi le jeton chez le fournisseur)' } else { '' }), $msg)
        }
        default { Write-Error ("Sous-commande 'mcp {0}' NON IMPLÉMENTÉE (disponibles : list, status, enable, disable)." -f $sub) -ErrorAction Continue; exit 2 }
    }
}

function Start-Tui {
    if (-not (Test-DockerEngine)) { throw 'Docker Engine indisponible.' }
    $id = (Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'opencode', 'ps', '-q', '--status', 'running', 'opencode')).Output.Trim()
    if (-not $id) { throw "OpenCode n'est pas démarré (.\local-ai.ps1 start opencode)." }
    # 11.B.2 : OpenTUI (Bun) extrait des bibliothèques natives dans TMPDIR ; /tmp est noexec -> tmpfs exécutable dédié /tui-tmp.
    & docker exec -it -e TMPDIR=/tui-tmp -w /data/workspace $id opencode --server http://127.0.0.1:4096
}

# ------------------------------------------------------------------ permissions
function Get-OpenCodeId { (Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'opencode', 'ps', '-q', '--status', 'running', 'opencode')).Output.Trim() }
function Invoke-OcApi([string]$Method, [string]$Path, [string]$Data) {
    $id = Get-OpenCodeId; if (-not $id) { throw "OpenCode n'est pas démarré." }
    if (-not $Data) { return (Invoke-Native docker @('exec', $id, 'opencode', 'api', '--server', 'http://127.0.0.1:4096', $Method, $Path)).Output }
    # PowerShell 5.1 altère les arguments natifs contenant espaces et guillemets : corps JSON transmis par l'entrée standard (UTF-8 sans BOM).
    $prevEnc = $OutputEncoding; $OutputEncoding = New-Object Text.UTF8Encoding $false
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = $Data | & docker exec -i $id /bin/sh -c 'd=$(cat); exec opencode api --server http://127.0.0.1:4096 \"$0\" \"$1\" -d \"$d\"' $Method $Path 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $prev; $OutputEncoding = $prevEnc }
    $out -join "`n"
}
function Test-WildMatch([string]$Pattern, [string]$Value) { $Value -like ($Pattern -replace '\[', '`[' -replace '\]', '`]') }
$PermActions = 'read', 'grep', 'glob', 'edit', 'shell', 'subagent'
$HardOnly = 'webfetch', 'websearch', 'external_directory'

function Invoke-Permissions {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'list' }
    $u = New-Object Text.UTF8Encoding $false
    $gf = Join-Path $Root 'config\security\grants.yaml'
    $cfgFile = Join-Path $Root 'config\opencode\opencode.json'
    $opt = { param($n) $i = [array]::IndexOf($Args0, $n); if ($i -ge 0 -and $i + 1 -lt $Args0.Count) { $Args0[$i + 1] } else { $null } }
    $agentIds = @((Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).agents.PSObject.Properties | Where-Object { -not ($_.Value.PSObject.Properties.Name -contains 'disabled') } | ForEach-Object Name)
    $grants = { if (Test-Path $gf) { @([regex]::Matches([IO.File]::ReadAllText($gf, $u), '(?m)^\s*-\s*\{([^}\r\n]*)\}') | ForEach-Object { $kv = [ordered]@{}; foreach ($p in ($_.Groups[1].Value -split ',')) { if ($p -match '^\s*(\w+):\s*"?([^"]*)"?\s*$') { $kv[$Matches[1]] = $Matches[2] } }; [pscustomobject]$kv }) } else { @() } }
    $saveGrants = { param($list) $list = @($list | Where-Object { $_ })
        $lines = @('# Autorisations PERSISTANTES local-ai (10.B.1) — gérées par .\local-ai.ps1 permissions grant|revoke|reset. Ne pas éditer.',
            '# Fusionnées par config/opencode/generate-config.ps1 AVANT les refus techniques (qui restent prioritaires).', 'schema: local-ai/permission-grants/v1', 'grants:')
        foreach ($g in $list) { $lines += ('  - {' + ((@($g.PSObject.Properties) | ForEach-Object { "$($_.Name): `"$($_.Value)`"" }) -join ', ') + '}') }
        if (-not $list.Count) { $lines[-1] = 'grants: []' }
        [IO.File]::WriteAllText($gf, (($lines -join "`n") + "`n"), $u)
    }
    $apply = { param([string]$What)
        $bk = New-AgentRestorePoint 'permissions' @($gf, $cfgFile, (Join-Path $Root 'profiles\defaults.yaml'))
        try { $m = Invoke-OpenCodeReload; "$What | $m | point BK1 : $($bk.Substring($Root.Length + 1))" }
        catch { $e = $_.Exception.Message; Restore-AgentRestorePoint $bk; try { [void](Invoke-OpenCodeReload) } catch { }; throw "ÉCHEC ($e) — ROLLBACK depuis $($bk.Substring($Root.Length + 1))" }
    }
    switch ($sub) {
        'list' {
            $j = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Output ("Profil de sécurité actif : {0} (défaut S2) — refus techniques prioritaires : {1} règles" -f (Get-SecProfile), @($j.permissions | Where-Object effect -eq 'deny').Count)
            $only = & $opt '--agent'
            $rows = foreach ($a in $agentIds) {
                if ($only -and $a -ne $only) { continue }
                $p = @($j.agents.$a.permissions)
                $eff = { param($act) $r = $p | Where-Object { $_.action -eq $act -and $_.resource -eq '*' } | Select-Object -Last 1; if ($r) { $r.effect } else { 'deny' } }
                [pscustomobject]@{ Agent = $a; edit = (& $eff 'edit'); shell = (& $eff 'shell'); 'shell partiel' = (@($p | Where-Object { $_.action -eq 'shell' -and $_.resource -ne '*' -and $_.effect -ne 'deny' } | ForEach-Object { "$($_.resource):$($_.effect)" }) -join ' ')
                    Délégations = (@($p | Where-Object { $_.action -eq 'subagent' -and $_.effect -ne 'deny' } | ForEach-Object { "$($_.resource):$($_.effect)" }) -join ' ')
                    MCP = (@($p | Where-Object { $_.action -like '*_*' -and $_.action -notlike 'external*' -and $_.effect -ne 'deny' } | ForEach-Object { "$($_.action):$($_.effect)" }) -join ' ') }
            }
            $rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Output
            $gl = @(& $grants); Write-Output ("Autorisations persistantes local-ai : {0}" -f $gl.Count); if ($gl.Count) { $gl | Format-Table -AutoSize | Out-String -Width 220 | Write-Output }
            try { $sv = Invoke-OcApi 'GET' '/api/permission/saved' ''; $n = ([regex]::Matches($sv, '"id":"')).Count; Write-Output ("Autorisations OpenCode « toujours » (par projet, révocables) : {0}" -f $n); foreach ($m in [regex]::Matches($sv, '"id":"([^"]+)"[^}]*?"action":"([^"]+)","resource":"([^"]*)"')) { Write-Output ("  saved {0} : {1} {2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) } } catch { Write-Output "Autorisations OpenCode : non lues ($($_.Exception.Message))" }
            Write-Output 'Portées : once = « Autoriser une fois » dans le Web/TUI ; persistent = grant (local-ai) ou « Toujours » (OpenCode, par projet) ; session : non prise en charge par OpenCode 2.3.2.'
        }
        'check' {
            if ($Args0.Count -lt 4) { throw 'Usage : .\local-ai.ps1 permissions check <agent> <action> <ressource>' }
            $sess = Invoke-OcApi 'POST' '/api/session' ('{"title":"local-ai-permission-check","agent":"' + $Args0[1] + '"}')
            $sid = [regex]::Match($sess, '"id":"(ses_[A-Za-z0-9]+)"').Groups[1].Value; if (-not $sid) { throw "session de contrôle non créée : $sess" }
            try {
                $res = ($Args0[3..($Args0.Count - 1)] -join ' ') -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", '\r' -replace "`t", '\t'
                $r = Invoke-OcApi 'POST' "/api/session/$sid/permission" ('{"action":"' + $Args0[2] + '","resources":["' + $res + '"],"agent":"' + $Args0[1] + '"}')
                $e = [regex]::Match($r, '"effect":"(\w+)"').Groups[1].Value; if (-not $e) { throw "évaluation impossible : $r" }
                Write-Output ("{0} | {1} | {2} => {3}" -f $Args0[1], $Args0[2], ($Args0[3..($Args0.Count - 1)] -join ' '), $e.ToUpperInvariant())
            } finally { [void](Invoke-OcApi 'DELETE' "/api/session/$sid" '') }
        }
        'grant' {
            if ($Args0.Count -lt 4) { throw 'Usage : .\local-ai.ps1 permissions grant <agent|*> <action> <ressource> [--effect allow|ask] [--project <nom>] [--scope persistent]' }
            $agent, $action, $res = $Args0[1], $Args0[2], $Args0[3]
            $effect = if (& $opt '--effect') { & $opt '--effect' } else { 'allow' }; $scope = if (& $opt '--scope') { & $opt '--scope' } else { 'persistent' }; $project = & $opt '--project'
            $why = @()
            if ($scope -ne 'persistent') { $why += "portée '$scope' non prise en charge ici : 'once' = « Autoriser une fois » dans le Web/TUI ; 'session' non prise en charge par OpenCode 2.3.2" }
            if ($agent -ne '*' -and $agentIds -notcontains $agent) { $why += "agent '$agent' inconnu" }
            if ($agent -like '*-delegue') { $why += 'les variantes déléguées héritent des règles de base de leur agent (accorder à l''agent lui-même)' }
            if ($effect -notin 'allow', 'ask') { $why += "effet '$effect' invalide (allow|ask ; utiliser revoke pour retirer)" }
            if ($HardOnly -contains $action) { $why += "action '$action' : refus technique non surchargeable" }
            elseif ($PermActions -notcontains $action -and $action -notmatch '^[a-z0-9-]+_\S+$') { $why += "action '$action' inconnue (actions : $($PermActions -join ', '), <serveur>_<outil>)" }
            if ($res -match ',') { $why += 'ressource : virgule interdite' }
            if ($project) { if ($action -notin 'read', 'grep', 'glob', 'edit') { $why += 'portée projet : uniquement read, grep, glob, edit' } elseif ($project -notmatch '^[A-Za-z0-9._-]+$') { $why += 'nom de projet invalide' } else { $res = "$project/$($res.TrimStart('/'))" } }
            if ($action -eq 'subagent' -and $res -notlike '*-delegue') { $why += 'délégation : seules les variantes <agent>-delegue sont délégables (profondeur 1)' }
            if ($action -like '*_*' -and $action -notin $PermActions) { $srv = ($action -split '_')[0]; if (-not (@((Get-Content $cfgFile -Raw | ConvertFrom-Json).mcp.servers.PSObject.Properties | ForEach-Object Name) -contains $srv)) { $why += "MCP '$srv' non activé" } }
            $hard = @((Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).permissions | Where-Object { $_.effect -eq 'deny' -and $_.action -eq $action })
            foreach ($h in $hard) { if ((Test-WildMatch $h.resource $res) -or (Test-WildMatch $res $h.resource.Trim('*'))) { $why += "ressource '$res' couverte par le refus technique '$($h.action) $($h.resource)' (non surchargeable)" } }
            if ($why) { Write-Audit 'permissions.grant' "$agent $action $res" 'refusé' ($why -join ' ; '); throw ("Autorisation REFUSÉE :`n - " + ($why -join "`n - ")) }
            $list = @(& $grants); $g = [pscustomobject][ordered]@{ id = 'g' + (Get-Date -Format 'yyyyMMddHHmmss'); agent = $agent; action = $action; resource = $res; effect = $effect; project = $(if ($project) { $project } else { '*' }); created = (Get-Date -Format 's') }
            & $saveGrants (@($list) + $g)
            Write-Audit 'permissions.grant' "$agent $action $res" $effect $g.id
            Write-Output (& $apply "Autorisation $($g.id) : $agent $action $res -> $effect (persistante)")
        }
        'revoke' {
            if ($Args0.Count -lt 2) { throw 'Usage : .\local-ai.ps1 permissions revoke <id-autorisation> | revoke saved <id>' }
            if ($Args0[1] -eq 'saved') { $r = Invoke-OcApi 'DELETE' "/api/permission/saved/$($Args0[2])" ''; Write-Audit 'permissions.revoke' "saved $($Args0[2])" 'révoqué'; Write-Output "Autorisation OpenCode $($Args0[2]) révoquée. $r"; return }
            $list = @(& $grants); $keep = @($list | Where-Object id -ne $Args0[1]); if ($keep.Count -eq $list.Count) { throw "Autorisation '$($Args0[1])' introuvable." }
            & $saveGrants $keep; Write-Audit 'permissions.revoke' $Args0[1] 'révoqué'
            Write-Output (& $apply "Autorisation $($Args0[1]) révoquée")
        }
        'reset' {
            $who = if ($Args0.Count -ge 2) { $Args0[1] } else { 'all' }
            $list = @(& $grants); $keep = @(if ($who -ne 'all') { $list | Where-Object agent -ne $who })
            & $saveGrants $keep
            $nSaved = 0; if ($who -eq 'all') { try { $sv = Invoke-OcApi 'GET' '/api/permission/saved' ''; foreach ($m in [regex]::Matches($sv, '"id":"([^"]+)"')) { [void](Invoke-OcApi 'DELETE' "/api/permission/saved/$($m.Groups[1].Value)" ''); $nSaved++ } } catch { } }
            Write-Audit 'permissions.reset' $who 'réinitialisé' "local-ai: $($list.Count - $keep.Count), OpenCode: $nSaved"
            Write-Output (& $apply ("Réinitialisation {0} : {1} autorisation(s) local-ai et {2} autorisation(s) OpenCode retirées" -f $who, ($list.Count - $keep.Count), $nSaved))
        }
        'profile' {
            if ($Args0.Count -lt 2) { Write-Output "Profil de sécurité actif : $(Get-SecProfile)"; return }
            $p = $Args0[1].ToUpperInvariant(); if ($p -notmatch '^S[1-4]$') { throw 'Profil inconnu (S1, S2, S3, S4).' }
            if ($p -eq 'S3' -and $Args0 -notcontains '--confirm') { throw 'S3 (édition et commandes sans validation dans le workspace) exige --confirm.' }
            $df = Join-Path $Root 'profiles\defaults.yaml'; $t = [IO.File]::ReadAllText($df, $u)
            $t = [regex]::Replace($t, '(?ms)(^desired:.*?^\s+security:\s*)S[1-4]', '${1}' + $p, 1); $t = [regex]::Replace($t, '(?ms)(^applied:.*?^\s+security:\s*\r?\n\s+profile:\s*)S[1-4]', '${1}' + $p, 1)
            $bk = New-AgentRestorePoint 'profile' @($df, $cfgFile); [IO.File]::WriteAllText($df, $t, $u)
            try { $m = Invoke-OpenCodeReload } catch { Restore-AgentRestorePoint $bk; try { [void](Invoke-OpenCodeReload) } catch { }; throw "ÉCHEC — ROLLBACK ($($_.Exception.Message))" }
            Write-Audit 'permissions.profile' $p 'appliqué'; Write-Output "Profil de sécurité $p appliqué | $m"
        }
        default { Write-Error ("Sous-commande 'permissions {0}' NON IMPLÉMENTÉE (list, check, grant, revoke, reset, profile)." -f $sub) -ErrorAction Continue; exit 2 }
    }
}

# ------------------------------------------------------------------ arrêt d'urgence
function Invoke-EmergencyStop {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'stop' }
    switch ($sub) {
        'status' { if (Test-Path $EmergencyFlag) { Write-Output "ARRÊT D'URGENCE ACTIF : $(Get-Content $EmergencyFlag -Raw)" } else { Write-Output "Aucun arrêt d'urgence actif." } }
        'clear' {
            if (-not (Test-Path $EmergencyFlag)) { Write-Output "Aucun arrêt d'urgence actif."; return }
            Remove-Item $EmergencyFlag -Force; Write-Audit 'emergency.clear' 'local-ai' 'levé'
            Write-Output "Arrêt d'urgence levé. Redémarrage explicite : .\local-ai.ps1 start opencode (les MCP restent arrêtés ; mcp enable pour les relancer)."
        }
        'stop' {
            $steps = @()
            $dir = Split-Path $EmergencyFlag; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
            [IO.File]::WriteAllText($EmergencyFlag, (([ordered]@{ ts = (Get-Date).ToString('o'); by = 'local-ai.ps1 emergency-stop' }) | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
            # 1. sessions actives interrompues (aucune suppression)
            try { $act = Invoke-OcApi 'GET' '/api/session/active' ''; $ids = @([regex]::Matches($act, '"(ses_[A-Za-z0-9]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique); foreach ($s in $ids) { [void](Invoke-OcApi 'POST' "/api/session/$s/interrupt" '') }; $steps += "sessions interrompues : $($ids.Count)" } catch { $steps += 'sessions : OpenCode déjà arrêté' }
            # 2. relais MCP arrêtés (conteneurs conservés, réseau N4 coupé de fait)
            $mcp = @((Invoke-Native docker @('ps', '-q', '--filter', 'label=local-ai.module=mcp')).Output -split "`n" | Where-Object { $_ })
            if ($mcp.Count) { [void](Invoke-Native docker (@('stop', '-t', '5') + $mcp)) }; $steps += "relais MCP arrêtés : $($mcp.Count)"
            # 2b. relais Continue et Dev Containers des projets (11.B.1)
            [void](Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'continue', 'stop', '-t', '5', 'continue-relay', 'continue-net'))
            $dev = @((Invoke-Native docker @('ps', '-q', '--filter', 'label=local-ai.module=project')).Output -split "`n" | Where-Object { $_ })
            if ($dev.Count) { [void](Invoke-Native docker (@('stop', '-t', '5') + $dev)) }; $steps += "relais Continue arrêté ; Dev Containers arrêtés : $($dev.Count)"
            # 3. agents arrêtés (OpenCode et son espace réseau)
            $r = Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'opencode', 'stop', '-t', '10', 'opencode', 'opencode-net'); $steps += "OpenCode arrêté (code $($r.Code))"
            # 4. modèles déchargés (Ollama reste disponible, interne)
            try { $c = Get-OllamaContainer; $loaded = @((Invoke-Native docker @('exec', $c, '/bin/ollama', 'ps')).Output -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split '\s+')[0] }); foreach ($m in $loaded) { [void](Invoke-Native docker @('exec', $c, '/bin/ollama', 'stop', $m)) }; $steps += "modèles déchargés : $($loaded.Count)" } catch { $steps += 'Ollama : arrêté' }
            Write-Audit 'emergency.stop' 'local-ai' 'exécuté' ($steps -join ' ; ')
            Write-Output ("ARRÊT D'URGENCE : " + ($steps -join ' | ') + " | aucune donnée supprimée ; démarrages bloqués jusqu'à .\local-ai.ps1 emergency-stop clear")
        }
        default { Write-Error "Sous-commande 'emergency-stop $sub' inconnue (status, clear)." -ErrorAction Continue; exit 2 }
    }
}

# ------------------------------------------------------------------ Continue (autocomplétion locale)
function Get-JsonProp($o, [string]$n) { if ($null -ne $o -and (@($o.PSObject.Properties | ForEach-Object Name) -contains $n)) { $o.$n } else { $null } }
function Get-LoadedModels { try { $c = Get-OllamaContainer; @((Invoke-Native docker @('exec', $c, '/bin/ollama', 'ps')).Output -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split '\s+')[0] }) } catch { @() } }
function Set-VsCodeSettings([hashtable]$Values) {
    # Fusion dans %APPDATA%\Code\User\settings.json (JSON sans commentaire), copie de sauvegarde BK1 préalable.
    $f = Join-Path $env:APPDATA 'Code\User\settings.json'; $u = New-Object Text.UTF8Encoding $false
    $cur = if (Test-Path $f) { [IO.File]::ReadAllText($f, $u) | ConvertFrom-Json } else { [pscustomobject]@{} }
    $bk = Join-Path $Root ("backups\restore-points\vscode_" + (Get-Date -Format 'yyyyMMdd_HHmmss')); New-Item -ItemType Directory -Force $bk | Out-Null
    if (Test-Path $f) { Copy-Item $f (Join-Path $bk 'settings.json') }
    foreach ($k in $Values.Keys) { if (@($cur.PSObject.Properties | ForEach-Object Name) -contains $k) { $cur.$k = $Values[$k] } else { $cur | Add-Member -NotePropertyName $k -NotePropertyValue $Values[$k] } }
    [IO.File]::WriteAllText($f, ($cur | ConvertTo-Json -Depth 8), $u)
    $bk.Substring($Root.Length + 1)
}
$ContinueSvc = @('continue-relay', 'continue-net')
function Invoke-Continue {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'status' }
    $cf = { param($a) @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'continue') + $a }
    $relayState = { $id = (Invoke-Native docker (& $cf @('ps', '-q', 'continue-relay'))).Output.Trim(); if ($id) { (Invoke-Native docker @('inspect', $id, '--format', '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}')).Output.Trim() } else { 'arrêté' } }
    switch ($sub) {
        'status' {
            $vs = Join-Path $env:APPDATA 'Code\User\settings.json'; $tab = if (Test-Path $vs) { (Get-JsonProp (Get-Content $vs -Raw | ConvertFrom-Json) 'continue.enableTabAutocomplete') } else { $null }
            Write-Output ("Relais 127.0.0.1:11435 : {0} | VS Code continue.enableTabAutocomplete : {1} | config : {2} | télémétrie Continue : {3}" -f (& $relayState), $tab,
                $(if (Test-Path (Join-Path $env:USERPROFILE '.continue\config.yaml')) { 'installée' } else { 'absente' }),
                $(if (Test-Path $vs) { if ((Get-JsonProp (Get-Content $vs -Raw | ConvertFrom-Json) 'continue.telemetryEnabled') -eq $false) { 'désactivée' } else { 'ACTIVE' } } else { '?' }))
            Write-Output ("Modèles chargés : {0}" -f $(if (@(Get-LoadedModels).Count) { (Get-LoadedModels) -join ', ' } else { 'aucun' }))
        }
        'install' {
            $dir = Join-Path $env:USERPROFILE '.continue'; New-Item -ItemType Directory -Force (Join-Path $dir 'index') | Out-Null
            $cfgDst = Join-Path $dir 'config.yaml'; if (Test-Path $cfgDst) { Copy-Item $cfgDst "$cfgDst.bak-$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
            Copy-Item (Join-Path $Root 'config\continue\config.yaml') $cfgDst -Force
            $gc = Join-Path $dir 'index\globalContext.json'; $u = New-Object Text.UTF8Encoding $false
            $want = (Get-Content (Join-Path $Root 'config\continue\globalContext.json') -Raw | ConvertFrom-Json).sharedConfig
            $g = if (Test-Path $gc) { [IO.File]::ReadAllText($gc, $u) | ConvertFrom-Json } else { [pscustomobject]@{} }
            if (-not (@($g.PSObject.Properties | ForEach-Object Name) -contains 'sharedConfig')) { $g | Add-Member -NotePropertyName sharedConfig -NotePropertyValue ([pscustomobject]@{}) }
            foreach ($p in $want.PSObject.Properties) { if (@($g.sharedConfig.PSObject.Properties | ForEach-Object Name) -contains $p.Name) { $g.sharedConfig.($p.Name) = $p.Value } else { $g.sharedConfig | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value } }
            [IO.File]::WriteAllText($gc, ($g | ConvertTo-Json -Depth 6), $u)
            $vals = @{}; (Get-Content (Join-Path $Root 'config\vscode\settings.local-ai.json') -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $vals[$_.Name] = $_.Value }
            $bk = Set-VsCodeSettings $vals
            Write-Audit 'continue.install' 'vscode' 'appliqué' $bk
            Write-Output "Continue configuré : autocomplétion locale uniquement (désactivée), télémétrie et indexation désactivées, profil de terminal « OpenCode (local-ai) » ajouté | sauvegarde : $bk"
        }
        'on' {
            Assert-NoEmergency
            $why = @()
            try { $act = Invoke-OcApi 'GET' '/api/session/active' ''; if ($act -match 'ses_') { $why += 'session OpenCode active (une seule inférence à la fois)' } } catch { }
            $other = @(Get-LoadedModels | Where-Object { $_ -ne 'qwen2.5-coder:1.5b' }); if ($other) { $why += "modèle chargé par OpenCode : $($other -join ', ') (aucun déchargement automatique)" }
            if ($why) { Write-Audit 'continue.on' 'relais' 'refusé' ($why -join ' ; '); throw ("Activation Continue REFUSÉE :`n - " + ($why -join "`n - ")) }
            $r = Invoke-Native docker (& $cf @('up', '-d', '--pull', 'never', '--no-build', 'continue-relay')); if ($r.Code -ne 0) { throw "démarrage du relais : $($r.Output)" }
            $d = (Get-Date).AddSeconds(90); do { Start-Sleep 3; $st = & $relayState } while ($st -notmatch 'healthy' -and (Get-Date) -lt $d)
            if ($st -notmatch '\(healthy\)') { throw "relais non sain ($st)" }
            $msg = ''; if ($Args0 -contains '--vscode') { $msg = ' ; VS Code : continue.enableTabAutocomplete=true (sauvegarde ' + (Set-VsCodeSettings @{ 'continue.enableTabAutocomplete' = $true }) + ')' }
            Write-Audit 'continue.on' 'relais' 'activé' $msg
            Write-Output ("Relais d'autocomplétion actif sur 127.0.0.1:11435 (qwen2.5-coder:1.5b uniquement){0}. Activer dans VS Code : barre d'état « Continue » → Enable Tab Autocomplete. Pendant une inférence OpenCode, le relais répond 409 (aucune substitution)." -f $msg)
        }
        'off' {
            $r = Invoke-Native docker (& $cf (@('stop') + $ContinueSvc)); $vs = Join-Path $env:APPDATA 'Code\User\settings.json'
            $msg = ''; if ((Test-Path $vs) -and (Get-JsonProp (Get-Content $vs -Raw | ConvertFrom-Json) 'continue.enableTabAutocomplete') -eq $true) { $msg = ' ; VS Code : continue.enableTabAutocomplete=false (sauvegarde ' + (Set-VsCodeSettings @{ 'continue.enableTabAutocomplete' = $false }) + ')' }
            if (@(Get-LoadedModels) -contains 'qwen2.5-coder:1.5b') { try { [void](Invoke-Native docker @('exec', (Get-OllamaContainer), '/bin/ollama', 'stop', 'qwen2.5-coder:1.5b')) } catch { } }
            Write-Audit 'continue.off' 'relais' 'arrêté' $msg
            Write-Output "Relais d'autocomplétion arrêté (conteneurs conservés), qwen2.5-coder:1.5b déchargé$msg."
        }
        default { Write-Error "Sous-commande 'continue $sub' inconnue (install, on, off, status)." -ErrorAction Continue; exit 2 }
    }
}

# ------------------------------------------------------------------ projets (Dev Containers)
function Get-ActiveProject { $v = Get-EnvValue 'LOCAL_AI_PROJECT'; if ($v -and $v -ne 'none') { $v } else { $null } }
function Set-EnvValue([string]$Name, [string]$Value) {
    $f = Join-Path $Root '.env'; $u = New-Object Text.UTF8Encoding $false; $t = if (Test-Path $f) { [IO.File]::ReadAllText($f, $u) } else { '' }
    if ($t -match ('(?m)^' + [regex]::Escape($Name) + '=')) { $t = [regex]::Replace($t, '(?m)^' + [regex]::Escape($Name) + '=.*$', "$Name=$Value") } else { $t = $t.TrimEnd() + "`n$Name=$Value`n" }
    [IO.File]::WriteAllText($f, $t, $u)
}
function Update-OpenCodeWorkspace {
    # Recrée le seul conteneur opencode pour (dé)monter le workspace du projet actif ; espace réseau et garde de sortie inchangés.
    $r = Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'opencode', 'up', '-d', '--pull', 'never', '--no-build', '--no-deps', 'opencode')
    if ($r.Code -ne 0) { throw "OpenCode : $($r.Output)" }
    $d = (Get-Date).AddSeconds(120); do { Start-Sleep 3; $id = Get-OpenCodeId; $h = if ($id) { (Invoke-Native docker @('inspect', $id, '--format', '{{.State.Health.Status}}')).Output.Trim() } else { '' } } while ($h -ne 'healthy' -and (Get-Date) -lt $d)
    if ($h -ne 'healthy') { throw "OpenCode non sain ($h)" }
}
function Invoke-Project {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'list' }
    $id = if ($Args0.Count -ge 2) { $Args0[1].ToLowerInvariant() } else { $null }
    $pdir = { param($p) Join-Path $Root "projects\$p\.devcontainer" }
    $need = { if (-not $id) { throw "Usage : .\local-ai.ps1 project $sub <id>" }; if ($id -notmatch '^[a-z0-9][a-z0-9-]{1,30}$' -or $id -eq 'none') { throw "Identifiant de projet invalide : '$id' (a-z, 0-9, tiret ; 2 à 31 caractères)." } }
    $exists = { param($p) (Invoke-Native docker @('volume', 'inspect', "local-ai-workspace-$p", '--format', '{{.Name}}')).Code -eq 0 }
    switch ($sub) {
        'list' {
            $act = Get-ActiveProject
            $vols = @((Invoke-Native docker @('volume', 'ls', '--filter', 'label=local-ai.volume=workspace', '--format', '{{.Name}}')).Output -split "`n" | Where-Object { $_ } | ForEach-Object { $_ -replace '^local-ai-workspace-', '' })
            $rows = foreach ($p in $vols) { $c = (Invoke-Native docker @('ps', '-a', '--filter', "label=local-ai.project=$p", '--format', '{{.Status}}')).Output.Trim()
                [pscustomobject]@{ Projet = $p; Ouvert = $(if ($p -eq $act) { 'OUI (partagé avec OpenCode)' } else { 'non' }); 'Dev Container' = $(if ($c) { $c } else { 'non créé' }); Config = $(if (Test-Path (& $pdir $p)) { "projects/$p/.devcontainer" } else { 'absente' }) } }
            if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output } else { Write-Output 'Aucun projet.' }
            Write-Output ("Projet partagé avec OpenCode : {0}" -f $(if ($act) { "$act (/data/workspace/$act)" } else { 'aucun' }))
        }
        'create' {
            & $need; if (& $exists $id) { throw "Projet '$id' déjà existant." }
            foreach ($v in @(@("local-ai-workspace-$id", 'workspace'), @("local-ai-cache-$id", 'cache'))) { $r = Invoke-Native docker @('volume', 'create', '--label', "local-ai.volume=$($v[1])", '--label', "local-ai.project=$id", '--label', 'local-ai.module=project', $v[0]); if ($r.Code -ne 0) { throw $r.Output } }
            $img = "$(Get-EnvValue 'OPENCODE_IMAGE_REPO'):$(Get-EnvValue 'OPENCODE_IMAGE_TAG')@sha256:$(Get-EnvValue 'OPENCODE_IMAGE_SHA256')"
            $r = Invoke-Native docker @('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--cap-add', 'CHOWN', '--security-opt', 'no-new-privileges', '--user', '0:0', '-v', "local-ai-workspace-${id}:/w", '-v', "local-ai-cache-${id}:/c", '--entrypoint', '/bin/busybox', $img, 'sh', '-c', 'echo local-ai > /w/.local-ai-project && echo local-ai > /c/.local-ai-cache && chown 1000:1000 /w /c /w/.local-ai-project /c/.local-ai-cache')
            if ($r.Code -ne 0) { throw "initialisation des volumes : $($r.Output)" }
            $dst = & $pdir $id; New-Item -ItemType Directory -Force $dst | Out-Null; $u = New-Object Text.UTF8Encoding $false
            foreach ($f in 'devcontainer.json', 'compose.yaml') { [IO.File]::WriteAllText((Join-Path $dst $f), ([IO.File]::ReadAllText((Join-Path $Root "projects\templates\devcontainer\$f"), $u)).Replace('{{ID}}', $id), $u) }
            Write-Audit 'project.create' $id 'créé'
            Write-Output "Projet '$id' créé : volumes local-ai-workspace-$id et local-ai-cache-$id (uid 1000), réseau interne local-ai-project-$id, configuration projects/$id/.devcontainer."
        }
        'open' {
            & $need; Assert-NoEmergency; if (-not (& $exists $id)) { throw "Projet '$id' inconnu (project create $id)." }
            $r = Invoke-Native docker @('compose', '-f', (Join-Path (& $pdir $id) 'compose.yaml'), 'up', '-d', '--pull', 'never', '--no-build'); if ($r.Code -ne 0) { throw "Dev Container : $($r.Output)" }
            $prev = Get-ActiveProject; Set-EnvValue 'LOCAL_AI_PROJECT' $id; Set-EnvValue 'LOCAL_AI_PROJECT_RO' 'false'
            try { Update-OpenCodeWorkspace } catch { if ($prev) { Set-EnvValue 'LOCAL_AI_PROJECT' $prev } else { Set-EnvValue 'LOCAL_AI_PROJECT' 'none'; Set-EnvValue 'LOCAL_AI_PROJECT_RO' 'true' }; try { Update-OpenCodeWorkspace } catch { }; throw "ouverture : $($_.Exception.Message) — projet précédent rétabli" }
            Write-Audit 'project.open' $id 'ouvert' $(if ($prev -and $prev -ne $id) { "remplace $prev" } else { '' })
            Write-Output ("Projet '{0}' ouvert : Dev Container démarré ; partagé avec OpenCode sous /data/workspace/{0} (seul projet monté){1}. VS Code : ouvrir le dossier projects\{0} puis « Dev Containers: Reopen in Container »." -f $id, $(if ($prev -and $prev -ne $id) { " ; '$prev' n'est plus partagé" } else { '' }))
        }
        'stop' {
            & $need
            $f = Join-Path (& $pdir $id) 'compose.yaml'; if (Test-Path $f) { $r = Invoke-Native docker @('compose', '-f', $f, 'stop'); if ($r.Code -ne 0) { throw $r.Output } }
            $msg = ''; if ((Get-ActiveProject) -eq $id) { Set-EnvValue 'LOCAL_AI_PROJECT' 'none'; Set-EnvValue 'LOCAL_AI_PROJECT_RO' 'true'; Update-OpenCodeWorkspace; $msg = ' ; plus aucun projet partagé avec OpenCode' }
            Write-Audit 'project.stop' $id 'arrêté'
            Write-Output "Projet '$id' arrêté (volumes et données conservés)$msg."
        }
        default { Write-Error "Sous-commande 'project $sub' inconnue (list, create, open, stop)." -ErrorAction Continue; exit 2 }
    }
}

switch ($Command.ToLowerInvariant()) {
    'continue'       { try { Invoke-Continue $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'project'        { try { Invoke-Project $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'permissions'    { try { Invoke-Permissions $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'emergency-stop' { try { Invoke-EmergencyStop $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'agent'  { try { Invoke-Agent $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'mcp'    { try { Invoke-Mcp $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'tui'    { try { Start-Tui } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'help'   { Show-Help; exit 0 }
    'model'  { try { Invoke-Model $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'status' { Show-Status; exit 0 }
    'config' { Test-Config; exit 0 }
    'start'  { try { Start-Module $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    'stop'   { try { Stop-Module $Arguments } catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }; exit 0 }
    default {
        if ($Planned.Contains($Command.ToLowerInvariant())) {
            Write-Error ("Commande '{0}' NON IMPLÉMENTÉE (prévue : {1})." -f $Command, $Planned[$Command.ToLowerInvariant()]) -ErrorAction Continue
            exit 2
        }
        Write-Error ("Commande inconnue : '{0}'. Voir : .\local-ai.ps1 help" -f $Command) -ErrorAction Continue
        exit 64
    }
}
