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
    'mcp'    = 'mcp list | status | enable <id> | disable <id> (enable refusé tant que N4 non implémenté)'
}
# Modules démarrables : profils Compose, image (variables .env), volumes externes requis, services arrêtés par stop
$Modules = @{
    'ollama'   = @{ Profiles = @('ollama'); ImagePrefix = 'OLLAMA'; Volumes = @('local-ai-ollama'); Service = 'ollama'; StopServices = @(); Secrets = @() }
    'opencode' = @{ Profiles = @('ollama', 'opencode'); ImagePrefix = 'OPENCODE'; Volumes = @('local-ai-ollama', 'local-ai-opencode'); Service = 'opencode'
                    StopServices = @('opencode', 'opencode-net'); Secrets = @('secrets\opencode.env'); ConfigCheck = 'config\opencode\generate-config.ps1' }
}
$Planned = [ordered]@{
    'profile'        = 'Afficher / appliquer un profil (A-C, N1-N4, S1-S4, BK1-BK3)'
    'agent'          = 'Gérer les agents'
    'monitor'        = 'Supervision selon config/monitoring/thresholds.yaml'
    'permissions'    = 'Consulter / modifier les permissions'
    'backup'         = 'Sauvegarde BK1 / BK2 / BK3'
    'restore'        = 'Restauration depuis un point de sauvegarde'
    'maintenance'    = 'Fenêtre de maintenance (profil N2)'
    'emergency-stop' = "Arrêt d'urgence de tous les services local-ai"
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
    Write-Output ("MCP               : {0} activé(s) / 4 préparés (N4 non implémenté)" -f $mcpOn)
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
    Assert-Preflight $m
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
            $why = @()
            if ($s.Activation -ne 'implemented') { $why += "activation '$($s.Activation)' : architecture N4 (relais MCP isolé, filtrage de sortie) non implémentée" }
            $applied = [regex]::Match((Get-Content (Join-Path $Root 'profiles\defaults.yaml') -Raw), '(?ms)^applied:.*?network:\s*\r?\n\s+profile:\s*(\S+)').Groups[1].Value
            if ($applied -ne 'N4') { $why += "profil réseau appliqué '$applied' (N4 requis, validation explicite préalable)" }
            if (-not $s.Secret -or -not (Test-Path (Join-Path $Root $s.Secret))) { $why += "secret '$($s.Secret)' absent (aucun jeton créé sans validation)" }
            if ($Args0 -notcontains '--authorize-n4') { $why += "autorisation explicite absente (--authorize-n4)" }
            Write-Error ("Activation MCP '{0}' REFUSÉE :`n - {1}" -f $s.Id, ($why -join "`n - ")) -ErrorAction Continue
            exit 3
        }
        'disable' {
            $s = & $pick
            $u = New-Object Text.UTF8Encoding $false; $changed = 0
            foreach ($f in @($s.Definition, (Join-Path $Root 'mcp\registry.yaml'))) {
                $t = [IO.File]::ReadAllText($f, $u)
                $n = if ($f -like '*registry.yaml') { [regex]::Replace($t, '(?ms)(-\s+id:\s*' + [regex]::Escape($s.Id) + '\s.*?^\s+enabled:\s*)true', '${1}false') } else { [regex]::Replace($t, '(?m)^enabled:\s*true', 'enabled: false') }
                if ($n -ne $t) { [IO.File]::WriteAllText($f, $n, $u); $changed++ }
            }
            Write-Output ("MCP {0} : {1} (aucun secret ni réseau modifié)." -f $s.Id, $(if ($changed) { 'désactivé' } else { 'déjà désactivé' }))
        }
        default { Write-Error ("Sous-commande 'mcp {0}' NON IMPLÉMENTÉE (disponibles : list, status, enable, disable)." -f $sub) -ErrorAction Continue; exit 2 }
    }
}

function Start-Tui {
    if (-not (Test-DockerEngine)) { throw 'Docker Engine indisponible.' }
    $id = (Invoke-Native docker @('compose', '-f', (Join-Path $Root 'compose.yaml'), '--profile', 'ollama', '--profile', 'opencode', 'ps', '-q', '--status', 'running', 'opencode')).Output.Trim()
    if (-not $id) { throw "OpenCode n'est pas démarré (.\local-ai.ps1 start opencode)." }
    & docker exec -it -w /data/workspace $id opencode --server http://127.0.0.1:4096
}

switch ($Command.ToLowerInvariant()) {
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
