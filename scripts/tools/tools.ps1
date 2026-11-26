# Python et Git isolés (14.B.2, R30) — dot-sourcé par local-ai.ps1 : tools status | verify | install --confirm.
# Volume local-ai-tools (lecture seule pour OpenCode et les Dev Containers), versions épinglées, inventaire config/tools/lock.txt.
# Aucune construction d'image (R3 non sollicité). install = seule fenêtre réseau (dépôt Alpine 3.24 main, signatures apk).
function Invoke-Tools {
    param([string[]]$Args0)
    $sub = if ($Args0 -and $Args0[0]) { $Args0[0].ToLowerInvariant() } else { 'status' }
    $img = "$(Get-EnvValue 'OPENCODE_IMAGE_REPO'):$(Get-EnvValue 'OPENCODE_IMAGE_TAG')@sha256:$(Get-EnvValue 'OPENCODE_IMAGE_SHA256')"
    $lock = Join-Path $Root 'config\tools\lock.txt'
    $have = (Invoke-Native docker @('volume', 'inspect', 'local-ai-tools')).Code -eq 0
    $run = { param([string]$Cmd) (Invoke-Native docker @('run', '--rm', '--network', 'none', '--read-only', '--tmpfs', '/tmp:exec,uid=1000', '--user', '1000:1000', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '-v', 'local-ai-tools:/opt/local-ai-tools:ro', '--entrypoint', '/bin/sh', $img, '-c', $Cmd)).Output.Trim() }
    switch ($sub) {
        'status' {
            if (-not $have) { Write-Output 'Volume local-ai-tools absent : .\local-ai.ps1 tools install --confirm'; return }
            Write-Output (& $run '/opt/local-ai-tools/bin/python3 --version; /opt/local-ai-tools/bin/git --version')
            Write-Output 'Disponibles dans OpenCode (shell des agents) et les nouveaux Dev Containers, en lecture seule, sans réseau.'
        }
        'verify' {
            if (-not $have) { throw 'Volume local-ai-tools absent.' }
            $cur = (& $run 'cat /opt/local-ai-tools/lock.txt') -replace "`r", ''
            $ref = ([IO.File]::ReadAllText($lock)) -replace "`r", ''
            if ($cur.Trim() -ne $ref.Trim()) { throw 'Inventaire du volume différent de config/tools/lock.txt (versions ou sommes).' }
            $t = & $run 'export PATH=/opt/local-ai-tools/bin:$PATH; cd /tmp; python3 --version; git --version; touch /opt/local-ai-tools/x 2>/dev/null && echo ECRITURE || echo lecture-seule'
            Write-Output "Épinglage conforme ($(@($ref.Trim() -split "`n").Count) paquets). $($t -replace "`n", ' | ')"
        }
        'install' {
            if ($Args0 -notcontains '--confirm') { Write-Output 'Installation : conteneur temporaire avec accès réseau au dépôt Alpine 3.24 (≈ 25 Mio, signatures apk), puis volume en lecture seule. Relancer avec --confirm.'; return }
            if (-not $have) { $r = Invoke-Native docker @('volume', 'create', '--label', 'local-ai.volume=tools', '--label', 'local-ai.module=tools', 'local-ai-tools'); if ($r.Code -ne 0) { throw $r.Output } }
            $r = Invoke-Native docker @('run', '--rm', '--user', '0:0', '--cap-drop', 'ALL', '--cap-add', 'CHOWN', '--cap-add', 'DAC_OVERRIDE', '--cap-add', 'FOWNER', '--security-opt', 'no-new-privileges', '-v', 'local-ai-tools:/opt/local-ai-tools', '-v', "$(Join-Path $Root 'scripts\tools'):/s:ro", '--entrypoint', '/bin/sh', $img, '/s/install-tools.sh')
            if ($r.Code -ne 0) { throw "installation : $($r.Output)" }
            Write-Audit 'tools.install' 'local-ai-tools' 'installé' $r.Output
            Write-Output "$($r.Output) ; vérifier : .\local-ai.ps1 tools verify"
        }
        default { throw 'Usage : tools status | verify | install --confirm' }
    }
}
