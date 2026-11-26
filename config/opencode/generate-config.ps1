#Requires -Version 5.1
<#
.SYNOPSIS
  Génère config/opencode/opencode.json (configuration système OpenCode 2.3.x, montée en lecture seule dans /etc/opencode)
  à partir de models/registry.yaml, agents/definitions/*.yaml et agents/prompts/*.md. Aucun secret.
.DESCRIPTION
  - Fournisseur unique : Ollama interne (http://ollama:11434/v1), 7 modèles du registre, contexte limité à 8192 (profil B).
  - Politiques : tout fournisseur refusé sauf ollama ; recherche web, MCP et intégrations refusés.
  - Agents : affectations INITIALES des définitions (non modifiées), permissions traduites en règles OpenCode.
  - -Check : compare au fichier existant sans écrire (code 1 si différent).
#>
[CmdletBinding()]
param([switch]$Check)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8 = New-Object Text.UTF8Encoding $false
$Out = Join-Path $PSScriptRoot 'opencode.json'
$MaxCtx = 8192

function Get-Val([string]$Text, [string]$Key) { $m = [regex]::Match($Text, '(?m)^\s*' + [regex]::Escape($Key) + ':\s*"?([^"\r\n#]*)"?'); if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null } }
function Get-List([string]$Text, [string]$Key) {
    $m = [regex]::Match($Text, '(?ms)^(\s*)' + [regex]::Escape($Key) + ':\s*\r?\n((?:\1\s+-\s*[^\r\n]+\r?\n?)*)')
    if (-not $m.Success) { return @() }
    @([regex]::Matches($m.Groups[2].Value, '-\s*([^\s\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
}
function Rule([string]$a, [string]$r, [string]$e) { [ordered]@{ action = $a; resource = $r; effect = $e } }

# --- modèles du registre
$reg = [IO.File]::ReadAllText((Join-Path $Root 'models\registry.yaml'), $Utf8)
$models = [ordered]@{}; $idToTag = @{}
foreach ($b in ([regex]::Split($reg, '(?m)^\s*-\s+id:\s*') | Select-Object -Skip 1)) {
    $id = ($b -split '\s')[0]; $tag = Get-Val $b 'tag'
    $idToTag[$id] = $tag
    $models[$tag] = [ordered]@{ name = "$tag (local)"; limit = [ordered]@{ context = $MaxCtx; output = 4096 } }
}

# --- agents (Continue exclu : autocomplétion hors OpenCode)
$agents = [ordered]@{}
foreach ($f in (Get-ChildItem (Join-Path $Root 'agents\definitions') -Filter *.yaml | Sort-Object Name)) {
    $t = [IO.File]::ReadAllText($f.FullName, $Utf8)
    if ((Get-Val $t 'type') -eq 'continue-autocomplete') { continue }
    $id = Get-Val $t 'id'; $ref = Get-Val $t 'ref'
    if (-not $idToTag.ContainsKey($ref)) { throw "Agent $id : modèle '$ref' absent du registre." }
    $perm = @{}
    $permBlock = [regex]::Match($t, '(?ms)^permissions:\s*\r?\n((?:\s+[^\r\n]+\r?\n)+)').Groups[1].Value
    foreach ($k in 'read', 'edit', 'bash', 'network', 'mcp') { $perm[$k] = Get-Val $permBlock $k }
    $tools = Get-List $t 'tools'
    $deleg = Get-List $t 'can_delegate_to'
    $prompt = [IO.File]::ReadAllText((Join-Path $f.DirectoryName (Get-Val $t 'instructions')), $Utf8).Trim()
    $rules = New-Object System.Collections.Generic.List[object]
    $rules.Add((Rule '*' '*' 'deny')); $rules.Add((Rule 'question' '*' 'allow'))
    foreach ($tl in 'read', 'grep', 'glob') { if ($tools -contains $tl) { $rules.Add((Rule $tl '*' $(if ($perm.read -eq 'allow') { 'allow' } else { 'ask' }))) } }
    if ($tools -contains 'edit' -or $tools -contains 'write') { $rules.Add((Rule 'edit' '*' $(if ($perm.edit -in 'allow', 'ask') { 'ask' } else { 'deny' }))) }
    if ($tools -contains 'bash' -and $perm.bash -ne 'deny') { $rules.Add((Rule 'shell' '*' 'ask')) }
    elseif ($tools -contains 'test') { foreach ($p in 'npm test*', 'pytest*', 'python -m pytest*', 'go test*', 'cargo test*', 'make test*', 'bash -n *') { $rules.Add((Rule 'shell' $p 'ask')) } }
    if ($tools -contains 'git-read') { foreach ($p in 'git status*', 'git diff*', 'git log*', 'git show*') { $rules.Add((Rule 'shell' $p 'allow')) } }
    foreach ($d in $deleg) { $rules.Add((Rule 'subagent' $d 'ask')) }
    foreach ($p in 'git push*', 'sudo *', 'curl *', 'wget *') { $rules.Add((Rule 'shell' $p 'deny')) }
    foreach ($a in 'webfetch', 'websearch', 'external_directory') { $rules.Add((Rule $a '*' 'deny')) }
    $rules.Add((Rule 'read' '*.env' 'deny')); $rules.Add((Rule 'read' '*secrets*' 'deny'))
    $agents[$id] = [ordered]@{
        description = "$(Get-Val $t 'name') — $(Get-Val $t 'role')"
        mode        = 'all'
        model       = "ollama/$($idToTag[$ref])"
        system      = $prompt
        permissions = $rules.ToArray()
    }
}

$cfg = [ordered]@{
    '$schema'     = 'https://opencode.ai/config.json'
    model         = "ollama/$($idToTag['qwen3.5-4b'])"
    default_agent = 'assistant'
    update        = 'disable'
    share         = 'disabled'
    websearch     = $false
    lsp           = $false
    formatter     = $false
    providers     = [ordered]@{ ollama = [ordered]@{ name = 'Ollama (local-ai, interne)'; settings = [ordered]@{ baseURL = 'http://ollama:11434/v1' }; models = $models } }
    policies      = @(
        (Rule 'provider.use' '*' 'deny'), (Rule 'provider.use' 'ollama' 'allow'),
        (Rule 'websearch.use' '*' 'deny'), (Rule 'mcp.use' '*' 'deny'),
        (Rule 'integration.connect' '*' 'deny'), (Rule 'integration.use' '*' 'deny'),
        (Rule 'integration.connect' 'ollama' 'allow'), (Rule 'integration.use' 'ollama' 'allow')
    )
    permissions   = @(
        (Rule '*' '*' 'ask'), (Rule 'read' '*' 'allow'), (Rule 'glob' '*' 'allow'), (Rule 'grep' '*' 'allow'),
        (Rule 'webfetch' '*' 'deny'), (Rule 'websearch' '*' 'deny'), (Rule 'external_directory' '*' 'deny'),
        (Rule 'shell' 'git push*' 'deny'), (Rule 'shell' 'sudo *' 'deny'),
        (Rule 'read' '*.env' 'deny'), (Rule 'read' '*secrets*' 'deny')
    )
    mcp           = [ordered]@{ servers = [ordered]@{} }
    agents        = $agents
}
$json = ($cfg | ConvertTo-Json -Depth 12) -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
$json = ($json -replace "`r`n", "`n") + "`n"
if ($Check) {
    $cur = if (Test-Path $Out) { [IO.File]::ReadAllText($Out, $Utf8) } else { '' }
    if ($cur -ne $json) { Write-Output 'opencode.json : NON À JOUR (relancer config/opencode/generate-config.ps1)'; exit 1 }
    Write-Output 'opencode.json : à jour'; exit 0
}
[IO.File]::WriteAllText($Out, $json, $Utf8)
Write-Output ("opencode.json : {0} modèles, {1} agents" -f $models.Count, $agents.Count)
