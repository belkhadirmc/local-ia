# Local-IA v1.0.0

Infrastructure de développement **multi-agent 100 % locale** pour Windows 11 : Docker Desktop (WSL2), Ollama (CPU), OpenCode,
Continue et VS Code / Dev Containers. Aucun modèle cloud, aucune sortie Internet des conteneurs, supervision humaine (profil S2).

| Composant | Version / état |
|---|---|
| Ollama | 0.40.18 (épinglé), 7 modèles locaux (≈ 53 Gio), un modèle et une inférence à la fois |
| Passerelle d'inférence | seul accès au moteur : JSON strict, verrou unique, garde RAM avant/pendant, repli proposé |
| OpenCode | 2.3.2 (épinglé), Web/TUI sur `http://127.0.0.1:4096`, 9 agents + autocomplétion Continue |
| VS Code | Continue 2.0.0 et Dev Containers 0.481.0 épinglés, profil de terminal « OpenCode (local-ai) » |
| Outils agents | Python 3.14.10 et Git 2.54.1 isolés (lecture seule) |
| Profils | performance **B**, réseau **N1**, sécurité **S2**, sauvegarde **BK1** |
| Performances (profil B) | qwen3.5:4b ≈ 8,5 t/s, qwen3-coder:30b ≈ 8,65 t/s (ADR-0012) |

## Documentation

| Guide | Contenu |
|---|---|
| [Démarrage](docs/guides/demarrage.md) | prérequis, premier lancement, premier projet |
| [Utilisateur](docs/guides/utilisateur.md) | OpenCode, repli, délégation manuelle, Continue, bon usage de la RAM |
| [Agents](docs/guides/agents-locaux.md) | les 10 agents, modèles, replis, permissions |
| [Projets](docs/guides/projects.md) | Dev Containers, partage avec OpenCode |
| [Administration](docs/guides/administration.md) | toutes les commandes `local-ai.ps1` |
| [Sécurité](docs/guides/securite.md) | isolation, permissions, secrets, limites |
| [Maintenance](docs/guides/maintenance.md) | routine, mises à jour, nettoyage |
| [Sauvegarde et restauration](docs/guides/sauvegarde-restauration.md) | BK1/BK2/BK3, quota, restauration témoin/production |
| [Dépannage](docs/guides/depannage.md) | symptômes et solutions |
| [Extensions](docs/guides/extensions.md) | MCP, cloud (hors V1), nouveaux modèles/agents/outils |
| [Architecture](docs/architecture/overview.md) · [Décisions](docs/decisions/) · [Réserves](docs/decisions/0003-reserves-et-differes.md) | conception, ADR-0001 à 0015, R1–R36 |
| [CHANGELOG](CHANGELOG.md) · [ROADMAP](ROADMAP.md) | historique, évolutions possibles |

## Commandes principales

```powershell
.\local-ai.ps1 help | status | config
.\local-ai.ps1 start opencode | stop opencode | tui | emergency-stop [status|clear]
.\local-ai.ps1 agent list | handoff <agent> "<consigne>" [--accept-fallback] [--watch <s>]
.\local-ai.ps1 fallback list | check all | mode <agent> auto|ask|off
.\local-ai.ps1 project list | create <id> | open <id> | stop <id>
.\local-ai.ps1 continue on | off | status
.\local-ai.ps1 monitor status | watch | maintenance status
.\local-ai.ps1 backup status | create BK1|BK2|BK3 | verify <id> | restore <id> --target-dir <dossier> [--confirm]
.\local-ai.ps1 profile list | permissions list | mcp list | tools status | model list
```

## Arborescence

| Dossier | Rôle |
|---|---|
| `compose/` | socle (`services/`), modules (`templates/` : ollama + passerelle, opencode, continue), surcharges explicites (`overrides/`) |
| `config/` | Ollama, passerelle (`gate/`), OpenCode (généré), Continue, agents (repli), outils, réseau, sécurité, supervision |
| `agents/` | définitions, prompts, affectations initiales (référence de restauration) |
| `models/` | registre des 7 modèles, benchmarks et microtests |
| `mcp/` | serveurs GitHub, GitLab, Jira, Confluence (préparés, désactivés) |
| `profiles/` | performance A/B/C, réseau N1–N4, sécurité S1–S4, sauvegarde BK1–BK3, `defaults.yaml` (souhaité / appliqué) |
| `scripts/` | MCP N4, profils, supervision et sentinelle, repli, outils, sauvegarde |
| `projects/` | modèle Dev Container (suivi) ; projets (non suivis) |
| `tests/` | passerelle, Continue, agents, sauvegarde |
| `secrets/`, `runtime/`, `backups/`, `exports/` | données locales — **jamais versionnées** |

## Limites connues (v1.0.0)

Usage **séquentiel et supervisé** sur CPU : premier message ≈ 1–2 min à froid ; modèles ≥ 14B admis seulement si la RAM Windows le
permet ; plusieurs modèles de code n'appellent pas les outils (repli automatique vers qwen3.5) ; repli manuel assisté dans le Web/TUI ;
délégation manuelle ; risques résiduels documentés (R14, R15, R17, R22, R31). Détail : [réserves](docs/decisions/0003-reserves-et-differes.md).

Mot de passe Web/API : `secrets/opencode.env` (non versionné, jamais sauvegardé en clair). OpenCode Desktop n'est pas utilisé (R9).
