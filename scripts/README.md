# scripts

Modules dot-sourcés par `local-ai.ps1` (point d'entrée unique) :

| Dossier | Rôle |
|---|---|
| `mcp/n4.ps1` | relais MCP N4 (désactivés par défaut) |
| `perf/profile.ps1` | profils de performance A/B/C (`profile`) |
| `monitor/monitor.ps1`, `monitor/sentinel.ps1` | supervision (`monitor`), sentinelle RAM hôte pour la passerelle |
| `agents/fallback.ps1` | repli local contrôlé (`fallback`, `agent handoff`) |
| `tools/tools.ps1`, `tools/install-tools.sh` | Python/Git isolés (`tools`) |
| `backup/backup.ps1` | sauvegarde, restauration, maintenance (`backup`, `restore`, `maintenance`) |
