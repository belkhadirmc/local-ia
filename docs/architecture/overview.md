# Architecture Local-IA v1.0.0

## Hôte

Windows 11 Pro, AMD Ryzen 7 5700U (8 cœurs / 16 threads), 37,9 Gio de RAM **asymétrique** (32 + 8 Gio : dual channel sur 16 Gio, R23),
SSD système ; Docker Desktop (CLI 4.99), Engine 29.9.3, Compose 5.7.0, WSL2 profil B (24 Gio, 16 vCPU, swap 8 Gio) ;
VS Code 1.147 (Continue 2.0.0, Dev Containers 0.481.0 épinglées). Aucun GPU utilisable (Vega 8, R26).

## Flux

```
VS Code / navigateur / terminal (hôte)
   │ 127.0.0.1:4096 (Basic)              │ 127.0.0.1:11435
   ▼                                     ▼
opencode-net ─(netns, sans route)─ opencode        continue-net ─ continue-relay (off par défaut)
   │ local-ai-core (interne)                         │ local-ai-core
   └──────────────► ollama-gate (alias « ollama ») ◄─┘
                     │ JSON strict · registre · verrou unique · garde RAM avant/pendant · repli proposé
                     ▼ local-ai-inference (interne)
                   ollama (moteur CPU, 7 modèles, OLLAMA_NO_CLOUD=1, un modèle à la fois)
sentinelle hôte (PowerShell) ── runtime/state/host-ram.json (RAM Windows, 2 s) ──► ollama-gate (lecture seule)
Dev Containers projet ── local-ai-project-<id> (interne) ; workspace partagé avec OpenCode seulement pour le projet ouvert
```

## Composants

| Élément | Emplacement | Rôle |
|---|---|---|
| Compose | `compose.yaml` → `compose/services/core.yaml`, `compose/templates/{ollama,opencode,continue}.yaml` | modules à double garde (profil + image épinglée) ; surcharges réseau explicites `compose/overrides/` |
| Passerelle | `config/gate/gate.pl`, `LocalAiJson.pm`, `fallback.json`, `admit.pl` | seul accès au moteur |
| OpenCode | image `ghcr.io/anomalyco/opencode:2.3.2@sha256:43d4…ff22`, `config/opencode/opencode.json` (généré) | serveur Web/TUI/API, 9 agents |
| Ollama | `ollama/ollama:0.40.18@sha256:4e0d…040b`, volume `local-ai-ollama` | moteur d'inférence CPU |
| Outils | volume `local-ai-tools` (lecture seule) | Python 3.14.10, Git 2.54.1 isolés (`config/tools/lock.txt`) |
| Projets | `projects/templates/devcontainer/`, volumes `local-ai-workspace-<id>`, `local-ai-cache-<id>` | Dev Containers non-root |
| MCP (désactivés) | `mcp/`, `scripts/mcp/n4.ps1` | relais N4 isolés, sortie filtrée par destination |
| Administration | `local-ai.ps1` + `scripts/{perf,monitor,agents,tools,backup,mcp}/` | commandes, profils, supervision, repli, sauvegarde |

## Réseaux

`local-ai-core` (interne : OpenCode, passerelle, relais Continue), `local-ai-inference` (interne : passerelle ↔ moteur),
`local-ai-localhost` (publication 127.0.0.1), `local-ai-mcp-relay` (interne, relais MCP), `local-ai-project-<id>` (interne, un par projet).
Réservés et inactifs : `local-ai-egress` (N2), `local-ai-cloud` (N3, hors V1, ADR-0013), `local-ai-mcp` (N4).
La liaison 127.0.0.1 limite l'exposition entrante mais ne bloque pas la sortie : la sortie est bloquée par suppression des routes (R1).

## Données persistantes

| Volume / dossier | Contenu | Sauvegarde |
|---|---|---|
| `local-ai-ollama` | modèles (≈ 57 Go) | BK3 externe uniquement |
| `local-ai-opencode` | sessions (SQLite), journaux OpenCode | BK2 |
| `local-ai-tools` | Python/Git isolés | BK2 |
| `local-ai-workspace-<id>`, `local-ai-cache-<id>` | projets | BK2 |
| dépôt (`config/`, `profiles/`, `agents/`, …) | configuration versionnée | BK1 + Git |
| `secrets/` | mot de passe local, jetons | jamais (à conserver hors dépôt) |
| `runtime/` | état, journaux, métriques, résultats de tests | non sauvegardé |
| `backups/` | BK1–BK3 et points de restauration | quota 10 Gio |

Décisions : `docs/decisions/` (ADR-0001 à ADR-0015) ; réserves : ADR-0003.
