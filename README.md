# local-ai

Infrastructure de développement multi-agent locale : Docker Desktop (WSL2), Ollama, OpenCode, Continue, VS Code.
**V1 100 % locale** : aucun modèle cloud, aucun basculement automatique ; N3 conservé comme point d'extension futur (ADR-0013).
État (13.B.1) : **Ollama 0.40.18** (CPU, réseau interne, aucun port publié) avec **7 modèles** (52,98 Gio, aucun chargé au repos, benchmarks 6.B.1) ;
**OpenCode 2.3.2** sur `http://127.0.0.1:4096` (authentification locale, sans accès Internet, fournisseur Ollama interne uniquement) ;
**10 agents** finalisés (9 dans OpenCode, Assistant par défaut ; autocomplétion Continue à l'étape 11), permissions S2 et délégations de profondeur 1 appliquées par le serveur ; raisonnement des modèles qwen3.5 désactivé dans OpenCode (9.B.2 : premier message ≈ 110 s à froid, puis ≈ 10 s) ;
sécurité S1–S4 (S2 par défaut), permissions gérées, refus techniques prioritaires, arrêt d'urgence et journal d'audit (10.B.1) ;
MCP GitHub, GitLab, Jira, Confluence **préparés et désactivés**, architecture N4 (relais isolés, sortie filtrée par destination) prête ;
VS Code : **Continue 2.0.0** (autocomplétion locale qwen2.5-coder:1.5b via relais 127.0.0.1:11435, désactivée par défaut, Tab validé) et **Dev Containers 0.481.0**, extensions épinglées
(projets isolés : workspace dédié, réseau interne, seul le projet ouvert partagé avec OpenCode) — guide : `docs/guides/projects.md` ;
tests d'interface VS Code (Continue/Tab, TUI, Dev Container Ubuntu 24.04.5 non-root) validés manuellement ;
performances (12.B.1, ADR-0012) : WSL2 16 vCPU / 24 Gio, Ollama 8 threads, cache KV q8_0 — qwen3.5:4b **8,5 t/s (+22 %)**, qwen3-coder:30b 8,65 t/s (+7 %) ;
profils A/B/C appliqués par `profile apply`, supervision légère `monitor`.

## Arborescence

| Dossier | Rôle |
|---|---|
| `compose/` | `services/` socle inclus, `templates/` modules (ollama et opencode actifs), `overrides/` surcharges sur autorisation |
| `config/` | Ollama, OpenCode, Continue, réseau, sécurité, supervision |
| `agents/` | définitions YAML indépendantes d'OpenCode, prompts, catalogue d'outils |
| `models/` | registre des modèles, benchmarks |
| `mcp/` | registre et serveurs officiels GitHub, GitLab, Jira, Confluence (préparés, désactivés) |
| `profiles/` | performance A/B/C, réseau N1-N4, sécurité S1-S4, sauvegarde BK1-BK3 |
| `scripts/` | MCP N4, profils de performance (`perf/`), supervision (`monitor/`) ; maintenance et sauvegarde à venir |
| `projects/` | projets Dev Containers (non suivis), `templates/devcontainer/` suivi (11.B.1) |
| `secrets/` | identifiants réels — jamais versionnés |
| `runtime/`, `backups/`, `exports/` | données locales — jamais versionnées |
| `tests/`, `docs/` | tests, architecture, guides, décisions |

## Administration

```powershell
.\local-ai.ps1 help      # aide
.\local-ai.ps1 status    # état en lecture seule
.\local-ai.ps1 config    # validation de la configuration
.\local-ai.ps1 start [ollama|opencode]   # validation préalable puis démarrage, sans téléchargement implicite
.\local-ai.ps1 stop [ollama|opencode]    # arrêt sans suppression (conteneurs, réseau, volume conservés)
.\local-ai.ps1 tui                       # interface terminal OpenCode (Web : http://127.0.0.1:4096, utilisateur opencode)
.\local-ai.ps1 model list                # modèles présents vs registre
.\local-ai.ps1 model show <tag>          # détails d'un modèle référencé
.\local-ai.ps1 mcp list|status           # serveurs MCP et relais N4
.\local-ai.ps1 mcp enable <id> --authorize-n4 [--witness]   # active un MCP (jeton requis) ; --witness = test local sans connexion
.\local-ai.ps1 mcp disable <id> [--revoke]                  # arrête et supprime les relais ; --revoke retire la copie du jeton
.\local-ai.ps1 permissions list|check|grant|revoke|reset|profile   # S1-S4, autorisations persistantes, évaluation sans inférence
.\local-ai.ps1 emergency-stop [status|clear]                # interrompt sessions, agents et MCP ; décharge les modèles (sans suppression)
.\local-ai.ps1 continue install|on|off|status               # autocomplétion Continue locale (relais 127.0.0.1:11435), activation manuelle
.\local-ai.ps1 project list|create|open|stop <id>           # projets Dev Containers isolés ; seul le projet ouvert est partagé avec OpenCode
.\local-ai.ps1 agent list                # agents, modèles, écarts à l'affectation initiale, avertissements outils/RAM
.\local-ai.ps1 agent model <agent> [<modèle>]   # afficher / changer durablement (BK1 + rollback, OpenCode régénéré)
.\local-ai.ps1 agent reset <agent|all>   # revenir aux affectations initiales (agents/assignments.initial.yaml)
.\local-ai.ps1 profile list|show <A|B|C>         # profils de performance ; * = appliqué
.\local-ai.ps1 profile apply <A|B|C> --confirm   # BK1 (.wslconfig comprise), redémarrage WSL2 si besoin, vérification, rollback
.\local-ai.ps1 monitor status                    # CPU, RAM Windows/WSL2, swap, SSD, modèle actif, débit, alertes
.\local-ai.ps1 monitor watch [s] [n]             # mesure périodique, historique runtime/monitor (7 j)
.\models\benchmarks\microtest.ps1 -Label x [-NumThread n] [-Ctx n]   # microtest court (128 tokens), pas un benchmark complet
```

Sélection **temporaire** d'un modèle : sélecteur de la session dans le Web ou le TUI (7 modèles du registre).
OpenCode Desktop (Windows) : **non utilisé** — il impose un serveur autonome sur l'hôte avec accès Internet (ADR-0008, R9).

Mot de passe Web/API : `secrets/opencode.env` (non versionné). Les autres commandes (`backup`, `restore`, `maintenance`) sont prévues et échouent explicitement tant qu'elles ne sont pas implémentées.

## Profils par défaut

`profiles/defaults.yaml` : performance **B**, réseau **N1**, sécurité **S2**, sauvegarde **BK1** (état souhaité vs appliqué).
Profil réseau **N3** (IA cloud) : réservé, non applicable en V1 ; extension future selon `docs/decisions/0013-cloud-differe-hors-v1.md`.
`.\local-ai.ps1 config` contrôle en permanence l'absence de fournisseur, de modèle et de repli cloud.

Voir `docs/decisions/0001-politiques-validees.md` pour les seuils et politiques.
