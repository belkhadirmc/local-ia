# Guide d'administration

Point d'entrée unique : `.\local-ai.ps1 <commande>` (`help` pour la liste). Toute action modifiante est journalisée
(`runtime/logs/audit.jsonl`, 30 jours) ; les changements de configuration créent un point de restauration BK1.

## Services

| Commande | Effet |
|---|---|
| `status` | état en lecture seule (Docker, WSL2, ressources, modules, MCP, profil de sécurité, arrêt d'urgence) |
| `config` | 18 contrôles statiques (YAML, Compose, épinglage des images, agents, MCP, OpenCode, V1 locale, passerelle) |
| `start [ollama\|opencode]` | contrôle préalable puis démarrage (sentinelle RAM, Ollama, passerelle, OpenCode) ; jamais de téléchargement |
| `stop [ollama\|opencode]` | arrêt sans suppression |
| `emergency-stop [status\|clear]` | interrompt sessions, agents, relais MCP/Continue, Dev Containers ; décharge les modèles ; bloque les démarrages et la passerelle |

Composants (`docker ps`) : `local-ai-ollama-1` (moteur, réseau `local-ai-inference` seul), `local-ai-ollama-gate-1` (passerelle,
seul accès au moteur), `local-ai-opencode-net-1` + `local-ai-opencode-1` (OpenCode, 127.0.0.1:4096, sans route Internet).

## Profils

| Commande | Effet |
|---|---|
| `profile list \| show <A\|B\|C> \| apply <A\|B\|C> --confirm` | performance (WSL2 + Ollama) : BK1 `.wslconfig` comprise, redémarrage WSL2 si besoin, vérification, rollback |
| `permissions profile <S1-S4>` | sécurité (S2 par défaut) |

Profil **B** (validé) : 24 Gio, 16 vCPU (Ollama 8 threads), KV q8_0, contexte 8192, keep_alive 5 min. A (économe) et C (maximal)
sont définis mais non mesurés (R28). Réseau : **N1** seul en V1 ; N2 (fenêtre de maintenance), N3 (cloud, hors V1), N4 (MCP) réservés.

## Agents, modèles, permissions

`agent list|model|reset|handoff`, `fallback list|check|mode`, `model list|show` (lecture seule ; `pull`/`rm` refusés : aucun
téléchargement implicite), `permissions list|check|grant|revoke|reset|profile`. Voir [agents](agents-locaux.md).

## Supervision

`monitor status | watch [s] [n] | simulate <Gio>|off` — seuils `config/monitoring/thresholds.yaml` (ADR-0001) : SSD alerte 45 /
critique 30 / urgence 15 Gio ; RAM WSL2 85/95 % ; RAM Windows ≥ 4 Gio ; swap ≤ 2 Gio ; CPU 95 % sur 5 min. Historique
`runtime/monitor` (7 jours). Journal de la passerelle : `docker logs local-ai-ollama-gate-1` (admissions, refus, abandons).

## Projets, outils, Continue, MCP

`project list|create|open|stop`, `tools status|verify|install --confirm`, `continue install|on|off|status`,
`mcp list|status|enable <id> --authorize-n4 [--witness]|disable <id> [--revoke]` (MCP désactivés ; activation sur décision, jeton
lecture seule fourni par l'utilisateur, R7).

## Sauvegarde, restauration, maintenance

`backup list|status|create|verify|delete`, `restore`, `maintenance status` : voir [sauvegarde-restauration](sauvegarde-restauration.md)
et [maintenance](maintenance.md).
