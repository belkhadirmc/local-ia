#Requires -Version 5.1
<#
.SYNOPSIS
  Administration de local-ai. Implémenté : help, status (lecture seule), config (validation).
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
    'start'  = 'Démarre un module activé (défaut : ollama) après validation ; aucun téléchargement implicite'
    'stop'   = 'Arrête un module (défaut : ollama) sans supprimer conteneurs, réseau ni volume'
}
# Modules démarrables : profil Compose, image (variables .env), volumes externes requis
$Modules = @{
    'ollama' = @{ Profile = 'ollama'; ImagePrefix = 'OLLAMA'; Volumes = @('local-ai-ollama'); Service = 'ollama' }
}
$Planned = [ordered]@{
    'profile'        = 'Afficher / appliquer un profil (A-C, N1-N4, S1-S4, BK1-BK3)'
    'model'          = 'Gérer les modèles Ollama'
    'agent'          = 'Gérer les agents'
    'mcp'            = 'Activer / désactiver les serveurs MCP'
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

        # 6. .env non sensible
        $secretLines = @(Get-Content .env, .env.example -ErrorAction SilentlyContinue | Where-Object { $_ -match '^(?!#)\w*(TOKEN|PASSWORD|SECRET|API_KEY)\w*=\S+' })
        Add-Result '.env sans secret' $(if ($secretLines) { 'FAIL' } else { 'PASS' }) ''

        # 7. Exclusions Git
        if (Test-Path .git) {
            $mustIgnore = '.env', 'secrets/mcp-github.env', 'backups/restore-points/x/f.json', 'runtime/logs/a.log', 'exports/e.zip', 'projects/demo/app.py', 'models/m.gguf', '.opencode/state.json'
            $mustTrack = '.env.example', 'secrets/README.md', 'projects/templates/README.md', 'mcp/github/.env.example', 'config/ollama/ollama.env'
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
        $r = Invoke-Native docker @('compose', '--profile', $m.Profile, 'up', '-d', '--pull', 'never', '--no-build')
        if ($r.Code -ne 0) { throw "docker compose up a échoué : $($r.Output)" }
        $deadline = (Get-Date).AddSeconds(120)
        do {
            $id = (Invoke-Native docker @('compose', '--profile', $m.Profile, 'ps', '-q', $m.Service)).Output.Trim()
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
        $r = Invoke-Native docker @('compose', '--profile', $m.Profile, 'stop')
        if ($r.Code -ne 0) { throw "docker compose stop a échoué : $($r.Output)" }
        Write-Output "Module $($m.Name) arrêté (conteneurs, réseau et volume conservés)."
    } finally { Pop-Location }
}

switch ($Command.ToLowerInvariant()) {
    'help'   { Show-Help; exit 0 }
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
