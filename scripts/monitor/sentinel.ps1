#Requires -Version 5.1
# Sentinelle RAM hôte (14.B.1) : publie toutes les 2 s la RAM Windows libre dans runtime\state\host-ram.json (écriture atomique),
# lue par la passerelle d'inférence (montage en lecture seule). Processus léger, sans privilège, démarré par local-ai.ps1 start,
# arrêté par local-ai.ps1 stop (fichier sentinel.stop) ou automatiquement quand le conteneur ollama n'existe plus.
param([int]$IntervalSeconds = 2)
$ErrorActionPreference = 'Continue'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$State = Join-Path $Root 'runtime\state'
New-Item -ItemType Directory -Force $State | Out-Null
$Out = Join-Path $State 'host-ram.json'; $Tmp = "$Out.tmp"; $Stop = Join-Path $State 'sentinel.stop'; $PidFile = Join-Path $State 'sentinel.pid'
Remove-Item $Stop -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($PidFile, "$PID")
$u = New-Object Text.UTF8Encoding $false
$i = 0
try {
    while (-not (Test-Path $Stop)) {
        $os = Get-CimInstance Win32_OperatingSystem
        $j = '{{"ts_unix":{0},"win_free_gib":{1},"win_total_gib":{2},"pid":{3}}}' -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(),
            ([math]::Round($os.FreePhysicalMemory / 1MB, 2)).ToString([Globalization.CultureInfo]::InvariantCulture),
            ([math]::Round($os.TotalVisibleMemorySize / 1MB, 2)).ToString([Globalization.CultureInfo]::InvariantCulture), $PID
        [IO.File]::WriteAllText($Tmp, $j, $u); Move-Item -Force $Tmp $Out
        if ((++$i % 15) -eq 0) { $c = & docker ps -aq --filter name=local-ai-ollama-1 2>$null; if (-not $c) { break } }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    Remove-Item $PidFile, $Tmp -ErrorAction SilentlyContinue
}
