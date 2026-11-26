#Requires -Version 5.1
<#
.SYNOPSIS
  Architecture MCP N4 (10.B.1) : génération et pilotage des relais isolés d'un serveur MCP. Chargé par local-ai.ps1.
.DESCRIPTION
  Pour un serveur <id> (mcp/<id>/server.yaml, section n4) :
    opencode-net ──(local-ai-mcp-relay, interne)──> mcp-relay-<id>  (squid reverse proxy : chemin MCP seul, injecte le jeton)
    type container-http : mcp-relay-<id> ──(local-ai-mcp-srv-<id>, interne)──> mcp-<id> (image officielle, HTTPS_PROXY)
                          mcp-<id> ──(local-ai-mcp-srv-<id>)──> mcp-egress-<id> (squid : CONNECT vers egress_allowlist uniquement)
                          mcp-egress-<id> ──(local-ai-mcp, N4)──> Internet
    type remote-http    : mcp-relay-<id> ──(local-ai-mcp-srv-<id>)──> mcp-egress-<id> ──(N4)──> origine HTTPS fixe
  OpenCode et Ollama n'ont jamais de route vers Internet. Les jetons restent dans secrets/ (montés en lecture seule dans le relais).
  Mode témoin (-Witness) : jeton fictif, destinations remplacées par des services locaux, réseau N4 remplacé par un réseau interne.
#>
Set-StrictMode -Version Latest

$script:N4Squid = 'ubuntu/squid:6.6-24.04_edge@sha256:d588976774988e439af518940316004280dec80772c19af1cc33ae39afa5d2eb'
$script:N4Witness = 'ghcr.io/anomalyco/opencode:2.3.2@sha256:43d4d0fb1d94fed8db615f865df7661104a39af6ca94dad631c09844b5e3ff22'

function Get-N4Definition([string]$Root, [string]$Id) {
    $f = Join-Path $Root "mcp\$Id\server.yaml"
    if (-not (Test-Path $f)) { throw "Serveur MCP '$Id' : définition absente." }
    $t = [IO.File]::ReadAllText($f, (New-Object Text.UTF8Encoding $false))
    $n4 = [regex]::Match($t, '(?ms)^n4:\s*\r?\n((?:[ \t]+[^\r\n]*\r?\n?)+)').Groups[1].Value
    if (-not $n4) { throw "Serveur MCP '$Id' : section n4 absente." }
    $g = { param($k) $m = [regex]::Match($n4, '(?m)^\s+' + $k + ':\s*"?([^"\r\n#]*)"?'); if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null } }
    $list = { param($k) $m = [regex]::Match($n4, '(?m)^\s+' + $k + ':\s*\[([^\]]*)\]'); if ($m.Success) { @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ }) } else { @() } }
    [pscustomobject]@{
        Id = $Id; Type = (& $g 'relay_type'); Image = (& $g 'image'); Command = (& $list 'command'); UpstreamPort = (& $g 'upstream_port')
        Path = (& $g 'path'); Origin = (& $g 'origin'); Allow = (& $list 'egress_allowlist'); AuthHeader = (& $g 'auth_header')
        SecretVar = (& $g 'secret_var'); Env = (& $list 'environment'); SecretFile = (Join-Path $Root "secrets\mcp-$Id.env")
    }
}

function Get-N4Dir([string]$Root, [string]$Id) { Join-Path $Root "runtime\mcp\$Id" }

function New-N4Files([string]$Root, $D, [switch]$Witness) {
    # Génère runtime/mcp/<id>/ (compose + configurations squid) et, hors témoin, secrets/mcp-<id>.relay-auth.conf (jeton).
    $u = New-Object Text.UTF8Encoding $false
    $dir = Get-N4Dir $Root $D.Id; New-Item -ItemType Directory -Force $dir | Out-Null
    $srvNet = "local-ai-mcp-srv-$($D.Id)"; $wanNet = if ($Witness) { "local-ai-mcp-witness-wan-$($D.Id)" } else { 'local-ai-mcp' }
    $allow = @(if ($Witness) { 'witness-allowed' } else { $D.Allow })
    if (-not $allow.Count) { throw "Serveur MCP '$($D.Id)' : egress_allowlist vide (refus)." }
    # --- jeton : témoin = valeur fictive ; réel = secrets/mcp-<id>.env (jamais affiché)
    $authConf = if ($Witness) { Join-Path $dir 'relay-auth.conf' } else { Join-Path $Root "secrets\mcp-$($D.Id).relay-auth.conf" }
    if ($Witness) { $token = if ($D.SecretVar -eq 'GITHUB_PERSONAL_ACCESS_TOKEN') { ('gh' + 'p_') + 'TEMOINLOCALFICTIF' + ('0' * 19) } else { 'TEMOIN-LOCAL-FICTIF' } }   # format PAT exigé par le serveur GitHub ; valeur manifestement factice
    else {
        if (-not (Test-Path $D.SecretFile)) { throw "secret '$($D.SecretFile.Substring($Root.Length + 1))' absent" }
        $line = Get-Content $D.SecretFile | Where-Object { $_ -match ('^\s*' + [regex]::Escape($D.SecretVar) + '=(.+)$') } | Select-Object -First 1
        if (-not $line) { throw "secret : variable $($D.SecretVar) vide ou absente" }
        $token = ($line -replace ('^\s*' + [regex]::Escape($D.SecretVar) + '='), '').Trim()
    }
    $hdr = $D.AuthHeader.Replace('{TOKEN}', $token)
    [IO.File]::WriteAllText($authConf, "request_header_add Authorization `"$hdr`" all`n", $u); $token = $null; $hdr = $null
    # --- relais (reverse proxy) : seul le chemin MCP, méthodes MCP, jeton client éventuel supprimé puis remplacé
    $upHost = if ($D.Type -eq 'container-http') { "mcp-$($D.Id)" } else { "mcp-egress-$($D.Id)" }
    $upPort = if ($D.Type -eq 'container-http') { $D.UpstreamPort } else { '3129' }
    $relay = @"
# Relais MCP N4 ($($D.Id)) — généré par local-ai.ps1 mcp enable. Ne pas éditer.
http_port 8080 accel defaultsite=mcp-$($D.Id) no-vhost
cache_peer $upHost parent $upPort 0 no-query originserver name=upstream
acl mcp_path urlpath_regex ^$([regex]::Escape($D.Path))(/|$|\?)
acl mcp_methods method GET POST DELETE OPTIONS
http_access allow mcp_path mcp_methods
http_access deny all
cache_peer_access upstream allow mcp_path
never_direct allow all
request_header_access Authorization deny all
include $(if ($Witness) { '/etc/local-ai/relay-auth.conf' } else { '/etc/local-ai/relay-auth.conf' })
cache deny all
cache_mem 8 MB
pid_filename /run/squid/squid.pid
access_log stdio:/dev/stdout
cache_log stdio:/dev/stderr
coredump_dir /var/spool/squid
via off
forwarded_for delete
httpd_suppress_version_string on
"@
    [IO.File]::WriteAllText((Join-Path $dir 'relay.conf'), ($relay -replace "`r`n", "`n") + "`n", $u)
    # --- sortie : CONNECT 443 vers la liste blanche (container-http) ; origine fixe en TLS (remote-http)
    $dst = ($allow | ForEach-Object { if ($_ -match '^(.+?)(:\d+)?$') { $Matches[1] } }) -join ' '
    if ($D.Type -eq 'container-http') {
        $egress = @"
# Sortie MCP N4 ($($D.Id)) — liste blanche par destination. Généré, ne pas éditer.
http_port 3128
acl allowed_dst dstdomain $dst
acl ssl_port port 443
acl witness_port port 8080
acl CONNECT method CONNECT
http_access deny CONNECT !ssl_port $(if ($Witness) { '!witness_port' })
http_access allow allowed_dst
http_access deny all
"@
    } else {
        $o = if ($Witness) { 'witness-allowed' } else { ([uri]$D.Origin).Host }
        $egress = @"
# Sortie MCP N4 ($($D.Id)) — origine distante fixe. Généré, ne pas éditer.
http_port 3129 accel defaultsite=$o no-vhost
cache_peer $o parent $(if ($Witness) { '8080 0 no-query originserver' } else { '443 0 no-query originserver tls tls-default-ca=on' }) name=origin
acl origin_dst dstdomain $o
http_access allow all
cache_peer_access origin allow all
never_direct allow all
"@
    }
    $egress += @"

cache deny all
cache_mem 8 MB
pid_filename /run/squid/squid.pid
access_log stdio:/dev/stdout
cache_log stdio:/dev/stderr
coredump_dir /var/spool/squid
via off
forwarded_for delete
httpd_suppress_version_string on
"@
    [IO.File]::WriteAllText((Join-Path $dir 'egress.conf'), ($egress -replace "`r`n", "`n") + "`n", $u)
    # --- compose (projet DÉDIÉ local-ai-mcp-<id> : aucune action possible sur les conteneurs Ollama/OpenCode)
    $sq = @"
    image: $script:N4Squid
    entrypoint: ["/usr/sbin/squid", "-N", "-f", "/etc/local-ai/squid.conf"]
    command: []
    user: "13:13"
    read_only: true
    tmpfs: ["/var/spool/squid:uid=13,gid=13,size=16m", "/var/log/squid:uid=13,gid=13,size=8m", "/run/squid:uid=13,gid=13,size=1m"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    mem_limit: 128m
    pids_limit: 64
    restart: "no"
    labels: {local-ai.module: mcp, local-ai.mcp: "$($D.Id)"$(if ($Witness) { ', local-ai.temporary: "true"' })}
"@
    $authMount = if ($Witness) { './relay-auth.conf' } else { "../../../secrets/mcp-$($D.Id).relay-auth.conf" }
    $svc = @"
# Généré par local-ai.ps1 mcp enable $($D.Id)$(if ($Witness) { ' (TÉMOIN LOCAL)' }). Ne pas éditer.
services:
  mcp-relay-$($D.Id):
$sq
    profiles: [mcp-$($D.Id)]
    networks: [local-ai-mcp-relay, $srvNet]
    volumes:
      - ./relay.conf:/etc/local-ai/squid.conf:ro
      - ${authMount}:/etc/local-ai/relay-auth.conf:ro
  mcp-egress-$($D.Id):
$sq
    profiles: [mcp-$($D.Id)]
    networks: [$srvNet, $wanNet]
    volumes:
      - ./egress.conf:/etc/local-ai/squid.conf:ro
"@
    # squid résout ses origines au démarrage : en mode témoin, la sortie démarre après les services témoins
    if ($Witness) { $svc += "`n    depends_on: [witness-allowed, witness-blocked]" }
    if ($D.Type -eq 'container-http') {
        $envLines = @(@($D.Env) + @("HTTPS_PROXY=http://mcp-egress-$($D.Id):3128", "HTTP_PROXY=http://mcp-egress-$($D.Id):3128", 'NO_PROXY=')) | ForEach-Object { "      - `"$_`"" }
        $svc += @"

  mcp-$($D.Id):
    image: $($D.Image)
    profiles: [mcp-$($D.Id)]
    command: [$((@($D.Command) | ForEach-Object { "`"$_`"" }) -join ', ')]
    user: "65532:65532"
    read_only: true
    tmpfs: ["/tmp:size=16m"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    mem_limit: 256m
    pids_limit: 64
    restart: "no"
    networks: [$srvNet]
    environment:
$($envLines -join "`n")
    labels: {local-ai.module: mcp, local-ai.mcp: "$($D.Id)"$(if ($Witness) { ', local-ai.temporary: "true"' })}
"@
    }
    if ($Witness) {
        $svc += @"

  witness-allowed:
    image: $script:N4Witness
    profiles: [mcp-$($D.Id)]
    command: ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
    user: "1000:1000"
    environment: ["HOME=/tmp", "OPENCODE_DISABLE_MODELS_FETCH=1", "OPENCODE_DISABLE_AUTOUPDATE=1"]
    read_only: true
    tmpfs: ["/tmp:uid=1000,gid=1000,size=64m"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    networks: [$wanNet]
    labels: {local-ai.temporary: "true", local-ai.module: mcp, local-ai.mcp: "$($D.Id)"}
  witness-blocked:
    image: $script:N4Witness
    profiles: [mcp-$($D.Id)]
    command: ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
    user: "1000:1000"
    environment: ["HOME=/tmp", "OPENCODE_DISABLE_MODELS_FETCH=1", "OPENCODE_DISABLE_AUTOUPDATE=1"]
    read_only: true
    tmpfs: ["/tmp:uid=1000,gid=1000,size=64m"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    networks: [$wanNet]
    labels: {local-ai.temporary: "true", local-ai.module: mcp, local-ai.mcp: "$($D.Id)"}
"@
    }
    $wanDef = if ($Witness) { "  ${wanNet}:`n    name: $wanNet`n    internal: true`n    labels: {local-ai.temporary: `"true`"}" } else { "  local-ai-mcp:`n    name: local-ai-mcp`n    driver: bridge`n    internal: false`n    labels: {local-ai.network: mcp, local-ai.authorization: required, local-ai.profile: N4}" }
    $svc += @"

networks:
  local-ai-mcp-relay:
    name: local-ai-mcp-relay
    external: true
  ${srvNet}:
    name: $srvNet
    internal: true
    labels: {local-ai.network: mcp-srv, local-ai.mcp: "$($D.Id)"}
$wanDef
"@
    [IO.File]::WriteAllText((Join-Path $dir 'compose.yaml'), ($svc -replace "`r`n", "`n") + "`n", $u)
    $dir
}

function Invoke-N4Compose([string]$Root, [string]$Id, [string[]]$ComposeArgs) {
    $f = Join-Path (Get-N4Dir $Root $Id) 'compose.yaml'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & docker compose -p "local-ai-mcp-$Id" -f $f --profile "mcp-$Id" @ComposeArgs 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ Code = $code; Output = ($out -join "`n") }
}
