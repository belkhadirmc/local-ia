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
$ReasoningEffort = @{ 'qwen3.5' = 'none'; 'gpt-oss' = 'low' }   # qwen2.5-coder, qwen3-coder : pas de mode thinking
foreach ($b in ([regex]::Split($reg, '(?m)^\s*-\s+id:\s*') | Select-Object -Skip 1)) {
    $id = ($b -split '\s')[0]; $tag = Get-Val $b 'tag'
    $idToTag[$id] = $tag
    $models[$tag] = [ordered]@{ name = "$tag (local)"; limit = [ordered]@{ context = $MaxCtx; output = 4096 } }
    # 9.B.2 : raisonnement (thinking) réglé comme en 6.B.1 (models/benchmarks/suite.yaml, section thinking). Sans ce réglage,
    # qwen3.5 raisonne par défaut via /v1 (jusqu'à 4096 tokens à ~7 tok/s sur CPU) : aucune réponse visible pendant des minutes.
    $fam = ($tag -split ':')[0]
    if ($ReasoningEffort.ContainsKey($fam)) { $models[$tag].body = [ordered]@{ reasoning_effort = $ReasoningEffort[$fam] } }
}

# --- agents (Continue exclu : autocomplétion hors OpenCode)
$agents = [ordered]@{}; $delegMap = [ordered]@{}; $subs = [ordered]@{}; $DelegSuffix = '-delegue'
$Common = [IO.File]::ReadAllText((Join-Path $Root 'agents\prompts\_common.md'), $Utf8).Trim()
foreach ($f in (Get-ChildItem (Join-Path $Root 'agents\definitions') -Filter *.yaml | Sort-Object Name)) {
    $t = [IO.File]::ReadAllText($f.FullName, $Utf8)
    if ((Get-Val $t 'type') -eq 'continue-autocomplete') { continue }
    $id = Get-Val $t 'id'; $ref = Get-Val $t 'ref'
    if (-not $idToTag.ContainsKey($ref)) { throw "Agent $id : modèle '$ref' absent du registre." }
    $perm = @{}
    $permBlock = [regex]::Match($t, '(?ms)^permissions:\s*\r?\n((?:\s+[^\r\n]+\r?\n)+)').Groups[1].Value
    foreach ($k in 'read', 'edit', 'bash', 'network', 'mcp') { $perm[$k] = Get-Val $permBlock $k }
    $tools = @(Get-List $t 'tools')
    $deleg = @(Get-List $t 'can_delegate_to')
    $prompt = [IO.File]::ReadAllText((Join-Path $f.DirectoryName (Get-Val $t 'instructions')), $Utf8).Trim() + "`n`n" + $Common
    $depth = Get-Val $t 'max_depth'
    if ($deleg.Count -and $depth -ne '1') { throw "Agent $id : max_depth doit valoir 1 (trouvé '$depth')." }
    $delegMap[$id] = $deleg
    $rules = New-Object System.Collections.Generic.List[object]
    $rules.Add((Rule '*' '*' 'deny')); $rules.Add((Rule 'question' '*' 'allow'))
    foreach ($tl in 'read', 'grep', 'glob') { if ($tools -contains $tl) { $rules.Add((Rule $tl '*' $(if ($perm.read -eq 'allow') { 'allow' } else { 'ask' }))) } }
    if ($tools -contains 'edit' -or $tools -contains 'write') { $rules.Add((Rule 'edit' '*' $(if ($perm.edit -in 'allow', 'ask') { 'ask' } else { 'deny' }))) }
    if ($tools -contains 'bash' -and $perm.bash -ne 'deny') { $rules.Add((Rule 'shell' '*' 'ask')) }
    elseif ($tools -contains 'test') { foreach ($p in 'npm test*', 'pytest*', 'python -m pytest*', 'go test*', 'cargo test*', 'make test*', 'bash -n *') { $rules.Add((Rule 'shell' $p 'ask')) } }
    if ($tools -contains 'git-read') { foreach ($p in 'git status*', 'git diff*', 'git log*', 'git show*') { $rules.Add((Rule 'shell' $p 'allow')) } }
    # Délégations : refus par défaut ; seules les variantes « <cible>-delegue » déclarées sont autorisées (S2 : delegation allow).
    $rules.Add((Rule 'subagent' '*' 'deny'))
    foreach ($p in 'git push*', 'sudo *', 'curl *', 'wget *') { $rules.Add((Rule 'shell' $p 'deny')) }
    foreach ($a in 'webfetch', 'websearch', 'external_directory') { $rules.Add((Rule $a '*' 'deny')) }
    $rules.Add((Rule 'read' '*.env' 'deny')); $rules.Add((Rule 'read' '*secrets*' 'deny'))
    $base = $rules.ToArray()
    foreach ($d in $deleg) { $rules.Add((Rule 'subagent' "$d$DelegSuffix" 'allow')) }
    $label = "$(Get-Val $t 'name') — $(Get-Val $t 'role')"
    $sys = $prompt
    if ($deleg.Count) { $sys += "`n`nIdentifiants de délégation (outil subagent, une tâche à la fois) : " + (($deleg | ForEach-Object { "$_$DelegSuffix" }) -join ', ') + '.' }
    $agents[$id] = [ordered]@{ description = $label; mode = 'all'; model = "ollama/$($idToTag[$ref])"; system = $sys; permissions = $rules.ToArray() }
    # Variante déléguée (profondeur 1 imposée : aucune délégation possible), cachée, même modèle et mêmes permissions de base.
    $subs[$id] = [ordered]@{ description = "$label (agent délégué, ne délègue pas)"; mode = 'subagent'; hidden = $true; model = "ollama/$($idToTag[$ref])"
        system = $prompt + "`n`nTu interviens comme agent délégué : ne délègue pas, traite la tâche reçue et rends un résultat complet à l'agent appelant."; permissions = $base }
}
# Seules les cibles réellement déclarées reçoivent une variante déléguée.
foreach ($dst in (@($delegMap.Values | ForEach-Object { $_ }) | Sort-Object -Unique)) { if ($subs.Contains($dst)) { $agents["$dst$DelegSuffix"] = $subs[$dst] } }

# --- contrôle des délégations : cibles existantes (OpenCode), pas d'auto-délégation, pas de cycle
foreach ($src in $delegMap.Keys) {
    foreach ($dst in $delegMap[$src]) {
        if ($dst -eq $src) { throw "Délégation : $src se délègue à lui-même." }
        if (-not $agents.Contains($dst)) { throw "Délégation : $src -> $dst (agent inconnu ou hors OpenCode)." }
    }
}
function Test-Cycle([string]$Node, [string[]]$Path) {
    foreach ($n in @($delegMap[$Node])) { if ($Path -contains $n) { throw "Délégation : cycle $(($Path + $n) -join ' -> ')" }; Test-Cycle $n ($Path + $n) }
}
foreach ($src in $delegMap.Keys) { Test-Cycle $src @($src) }
# Agents intégrés d'OpenCode à usage général désactivés : seuls les 9 agents local-ai sont sélectionnables ou délégables.
foreach ($b in 'build', 'plan', 'general', 'explore') { $agents[$b] = [ordered]@{ disabled = $true } }

$cfg = [ordered]@{
    '$schema'     = 'https://opencode.ai/config.json'
    model         = "ollama/$($idToTag['qwen3.5-4b'])"
    default_agent = 'assistant'
    update        = 'disable'
    share         = 'disabled'
    websearch     = $false
    lsp           = $false
    formatter     = $false
    providers     = [ordered]@{ ollama = [ordered]@{ name = 'Ollama (local-ai, interne)'; settings = [ordered]@{ baseURL = 'http://ollama:11434/v1'; timeout = $false; headerTimeout = 1500000; chunkTimeout = 600000 }; models = $models } }
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
Write-Output ("opencode.json : {0} modèles, {1} agents local-ai, {2} variantes déléguées, 4 intégrés désactivés" -f $models.Count, $delegMap.Count, ($agents.Count - $delegMap.Count - 4))
