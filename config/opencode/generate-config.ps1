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

# --- profil de sécurité actif (profiles/defaults.yaml, desired.security ; S2 par défaut)
$defaults = [IO.File]::ReadAllText((Join-Path $Root 'profiles\defaults.yaml'), $Utf8)
$SecProfile = [regex]::Match($defaults, '(?ms)^desired:.*?^\s+security:\s*(S[1-4])').Groups[1].Value
if (-not $SecProfile) { $SecProfile = 'S2' }
# 14.B.1 (R12) : mode de délégation du profil actif (manual | auto) ; manual par défaut en V1.
$DelegationMode = [regex]::Match([IO.File]::ReadAllText((Join-Path $Root "profiles\security\$SecProfile.yaml"), $Utf8), '(?m)^\s*delegation_mode:\s*(manual|auto)').Groups[1].Value
if (-not $DelegationMode) { $DelegationMode = 'manual' }
# Effet appliqué à une capacité prévue par la définition (jamais d'élargissement d'une capacité refusée par la définition).
function Get-Effect([string]$Kind, [string]$DefEffect) {
    if ($DefEffect -eq 'deny') { return 'deny' }
    switch ($SecProfile) {
        'S3' { switch ($Kind) { 'mcp' { 'ask' } default { 'allow' } } }
        'S2' { switch ($Kind) { 'git-read' { 'allow' } default { 'ask' } } }
        default { switch ($Kind) { 'mcp' { 'deny' } default { 'ask' } } }   # S1 et S4 (S4 hérite de S1)
    }
}
# Autorisations persistantes (config/security/grants.yaml) + surcharges S4 (profiles/custom/*.yaml) ; jamais prioritaires sur $HardDeny.
$GrantRules = @()
foreach ($gf in @((Join-Path $Root 'config\security\grants.yaml')) + @(if ($SecProfile -eq 'S4') { Get-ChildItem (Join-Path $Root 'profiles\custom') -Filter *.yaml -ErrorAction SilentlyContinue | ForEach-Object FullName })) {
    if (-not (Test-Path $gf)) { continue }
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($gf, $Utf8), '(?m)^\s*-\s*\{([^}\r\n]*)\}')) {
        $kv = @{}; foreach ($p in ($m.Groups[1].Value -split ',')) { if ($p -match '^\s*(\w+):\s*"?([^"]*)"?\s*$') { $kv[$Matches[1]] = $Matches[2] } }
        if ($kv.agent -and $kv.action -and $kv.resource -and $kv.effect -in 'allow', 'ask', 'deny') { $GrantRules += [pscustomobject]$kv }
    }
}
function Get-Grants([string]$AgentId) { foreach ($g in $GrantRules) { if ($g.agent -in '*', $AgentId) { Rule $g.action $g.resource $g.effect } } }
# Refus techniques prioritaires (ajoutés en dernier : « la dernière règle correspondante l'emporte »).
$HardDeny = @()
foreach ($p in '*git push*', '*sudo*', '*curl*', '*wget*', 'nc *', '* nc *', '*ssh *', '*scp *', '*/proc/*', '*environ*', '*OPENCODE_PASSWORD*', '*opencode api*', '*opencode run*', '*opencode serve*', '*:4096*', '*mcp-relay*', '*mcp-egress*', '*docker*') { $HardDeny += Rule 'shell' $p 'deny' }
# 14.B.1 (R14/R15/R17) : code en ligne et contournements usuels des motifs, exécution depuis le tmpfs exécutable du TUI,
# accès direct au moteur / à la passerelle d'inférence et aux relais MCP. Ne remplace pas la validation humaine (R15).
foreach ($p in '*sh -c*', '*bash -c*', '*eval *', '*exec *', '*python* -c*', '*perl -e*', '*perl -E*', '*node -e*', '*node --eval*', '*base64*', '*xxd*', '*openssl*',
               '*/tui-tmp*', '*:11434*', '*ollama-engine*', '*ollama-gate*', '*:8080*', '*local-ai-mcp*', '*alias *', '*source *', '*/dev/tcp*') { $HardDeny += Rule 'shell' $p 'deny' }
foreach ($a in 'webfetch', 'websearch', 'external_directory') { $HardDeny += Rule $a '*' 'deny' }
foreach ($a in 'read', 'edit') { foreach ($p in '*.env', '*.env.*', '*secrets*', '/proc/*', '*/proc/*', '/etc/opencode/*') { $HardDeny += Rule $a $p 'deny' } }
# MCP activés : registre (enabled: true, activation réelle) ou relais témoin local en cours (runtime/mcp/<id>/witness).
$McpEnabled = [ordered]@{}
$mreg = [IO.File]::ReadAllText((Join-Path $Root 'mcp\registry.yaml'), $Utf8)
foreach ($b in ([regex]::Split($mreg, '(?m)^\s*-\s+id:\s*') | Select-Object -Skip 1)) {
    $sid = ($b -split '\s')[0]
    $on = (Get-Val $b 'enabled') -eq 'true' -or (Test-Path (Join-Path $Root "runtime\mcp\$sid\witness"))
    if ($on) {
        $st = [IO.File]::ReadAllText((Join-Path $Root "mcp\$sid\server.yaml"), $Utf8)
        $McpEnabled[$sid] = "http://mcp-relay-${sid}:8080" + [regex]::Match($st, '(?ms)^n4:.*?^\s+path:\s*(\S+)').Groups[1].Value
    }
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
    $authorizable = @(Get-List $t 'authorizable')
    # Règles : base deny -> outils de la définition (effet selon le profil) -> autorisations accordées -> REFUS TECHNIQUES (dernier = prioritaire).
    $rules = New-Object System.Collections.Generic.List[object]
    $rules.Add((Rule '*' '*' 'deny')); $rules.Add((Rule 'question' '*' 'allow'))
    foreach ($tl in 'read', 'grep', 'glob') { if ($tools -contains $tl) { $rules.Add((Rule $tl '*' $(if ($perm.read -eq 'allow') { 'allow' } else { 'ask' }))) } }
    if ($tools -contains 'edit' -or $tools -contains 'write') { $rules.Add((Rule 'edit' '*' (Get-Effect 'edit' $perm.edit))) }
    if ($tools -contains 'bash' -and $perm.bash -ne 'deny') { $rules.Add((Rule 'shell' '*' (Get-Effect 'shell' $perm.bash))) }
    elseif ($tools -contains 'test') { foreach ($p in 'npm test*', 'pytest*', 'python -m pytest*', 'go test*', 'cargo test*', 'make test*', 'bash -n *') { $rules.Add((Rule 'shell' $p (Get-Effect 'shell' 'ask'))) } }
    if ($tools -contains 'git-read') { foreach ($p in 'git status*', 'git diff*', 'git log*', 'git show*') { $rules.Add((Rule 'shell' $p (Get-Effect 'git-read' 'allow'))) } }
    # 10.B.1 : OpenCode compare des préfixes sans découper les commandes composées (« git status; rm -rf x » était autorisé).
    # Toute commande composée, redirigée ou substituée retombe sur l'effet shell de base de l'agent (deny ou ask), jamais sur un allow partiel.
    $baseShell = if ($tools -contains 'bash' -and $perm.bash -ne 'deny') { Get-Effect 'shell' $perm.bash } else { 'deny' }
    foreach ($p in '*;*', '*&*', '*|*', '*`*', '*$(*', '*>*', '*<*', "*`n*", "*`r*", '*--output*', '*--ext-diff*', '*-c core.*') { $rules.Add((Rule 'shell' $p $baseShell)) }
    # MCP : outils des seuls serveurs activés ET autorisables pour l'agent (sinon refus par la règle de base).
    foreach ($s in $McpEnabled.Keys) { if ($authorizable -contains $s -and $perm.mcp -ne 'deny') { $rules.Add((Rule "${s}_*" '*' (Get-Effect 'mcp' $perm.mcp))) } }
    $rules.Add((Rule 'subagent' '*' 'deny'))
    foreach ($g in (Get-Grants $id)) { $rules.Add($g) }
    $base = @($rules.ToArray()) + $HardDeny
    # 14.B.1 (R12) : délégation automatique instable sur CPU (réponse vide du modèle, cibles bloquées par la garde RAM) ->
    # mode « manual » du profil : aucune règle subagent (refus de base), l'agent rédige un transfert que l'utilisateur lance
    # (local-ai.ps1 agent handoff). Mode « auto » : délégation validée (S2) vers les variantes <agent>-delegue.
    if ($DelegationMode -ne 'manual') { foreach ($d in $deleg) { $rules.Add((Rule 'subagent' "$d$DelegSuffix" (Get-Effect 'delegation' 'allow'))) } }
    foreach ($h in $HardDeny) { $rules.Add($h) }
    $label = "$(Get-Val $t 'name') — $(Get-Val $t 'role')"
    $sys = $prompt
    if ($deleg.Count -and $DelegationMode -eq 'manual') { $sys += "`n`nDélégation automatique désactivée (V1). Pour confier une tâche à " + ($deleg -join ', ') + ", termine ta réponse par une ligne « Transfert -> <agent> : <consigne autonome et complète> » ; l'utilisateur la lance lui-même (une tâche à la fois)." }
    elseif ($deleg.Count) { $sys += "`n`nIdentifiants de délégation (outil subagent, une tâche à la fois) : " + (($deleg | ForEach-Object { "$_$DelegSuffix" }) -join ', ') + '.' }
    # 14.B.2 : marqueur d'agent lu par la passerelle (repli manuel assisté : suggestion de modèle propre à l'agent).
    $sys += "`n`n[local-ai agent=$id]"
    $agents[$id] = [ordered]@{ description = $label; mode = 'all'; model = "ollama/$($idToTag[$ref])"; system = $sys; permissions = $rules.ToArray() }
    # Variante déléguée (profondeur 1 imposée : aucune délégation possible), cachée, même modèle et mêmes permissions de base.
    $subs[$id] = [ordered]@{ description = "$label (agent délégué, ne délègue pas)"; mode = 'subagent'; hidden = $true; model = "ollama/$($idToTag[$ref])"
        system = $prompt + "`n`nTu interviens comme agent délégué : ne délègue pas, traite la tâche reçue et rends un résultat complet à l'agent appelant.`n`n[local-ai agent=$id]"; permissions = $base }
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
    shell         = '/etc/local-ai/agent-shell'   # 14.B.1 (R14) : commandes d'agent sans OPENCODE_PASSWORD
    update        = 'disable'
    share         = 'disabled'
    websearch     = $false
    lsp           = $false
    formatter     = $false
    providers     = [ordered]@{ ollama = [ordered]@{ name = 'Ollama (local-ai, interne)'; settings = [ordered]@{ baseURL = 'http://ollama:11434/v1'; timeout = $false; headerTimeout = 1500000; chunkTimeout = 600000 }; models = $models } }
    policies      = @(
        (Rule 'provider.use' '*' 'deny'), (Rule 'provider.use' 'ollama' 'allow'),
        (Rule 'websearch.use' '*' 'deny'), (Rule 'mcp.use' '*' 'deny')) + @($McpEnabled.Keys | ForEach-Object { Rule 'mcp.use' $_ 'allow' }) + @(
        (Rule 'integration.connect' '*' 'deny'), (Rule 'integration.use' '*' 'deny'),
        (Rule 'integration.connect' 'ollama' 'allow'), (Rule 'integration.use' 'ollama' 'allow')
    )
    permissions   = @((Rule '*' '*' 'ask'), (Rule 'read' '*' 'allow'), (Rule 'glob' '*' 'allow'), (Rule 'grep' '*' 'allow')) + $HardDeny
    mcp           = [ordered]@{ servers = $(
            $srv = [ordered]@{}; foreach ($s in $McpEnabled.Keys) { $srv[$s] = [ordered]@{ type = 'remote'; url = $McpEnabled[$s]; oauth = $false } }; $srv) }
    agents        = $agents
}
$json = ($cfg | ConvertTo-Json -Depth 12) -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
$json = ($json -replace "`r`n", "`n") + "`n"
# 14.B.2 : politique de repli (config/agents/fallback.yaml) -> config/gate/fallback.json, lu par la passerelle et local-ai.ps1.
$fbSrc = [IO.File]::ReadAllText((Join-Path $Root 'config\agents\fallback.yaml'), $Utf8)
$fb = [ordered]@{ schema = 'local-ai/agent-fallback/v1'; tools_incompatible = @([regex]::Matches(([regex]::Match($fbSrc, '(?m)^tools_incompatible:[^\n]*\n((?:[ \t]+-[^\n]*\n)+)')).Groups[1].Value, '-\s*"?([^"\s#]+)') | ForEach-Object { $_.Groups[1].Value }); agents = [ordered]@{} }
foreach ($m in [regex]::Matches($fbSrc, '(?m)^\s+([a-z]+):\s*\{\s*mode:\s*(auto|ask|off),\s*chain:\s*"([^"]*)"\s*\}')) {
    $ch = @($m.Groups[3].Value -split ',' | Where-Object { $_ })
    foreach ($x in $ch) { if (-not ($models.Keys -contains $x)) { throw "fallback.yaml : modèle '$x' absent du registre." } }
    $fb.agents[$m.Groups[1].Value] = [ordered]@{ mode = $m.Groups[2].Value; chain = $ch }
}
foreach ($aid in $delegMap.Keys) { if (-not $fb.agents.Contains($aid)) { throw "fallback.yaml : agent '$aid' sans politique de repli." } }
$fbOut = Join-Path $Root 'config\gate\fallback.json'
$fbJson = (($fb | ConvertTo-Json -Depth 6) -replace "`r`n", "`n") + "`n"
if ($Check) {
    $cur = if (Test-Path $Out) { [IO.File]::ReadAllText($Out, $Utf8) } else { '' }
    $curFb = if (Test-Path $fbOut) { [IO.File]::ReadAllText($fbOut, $Utf8) } else { '' }
    if ($cur -ne $json -or $curFb -ne $fbJson) { Write-Output 'opencode.json / fallback.json : NON À JOUR (relancer config/opencode/generate-config.ps1)'; exit 1 }
    Write-Output 'opencode.json : à jour'; exit 0
}
[IO.File]::WriteAllText($Out, $json, $Utf8)
[IO.File]::WriteAllText($fbOut, $fbJson, $Utf8)
Write-Output ("opencode.json : {0} modèles, {1} agents local-ai, {2} variantes déléguées, 4 intégrés désactivés" -f $models.Count, $delegMap.Count, ($agents.Count - $delegMap.Count - 4))
