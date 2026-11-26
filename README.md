# local-ai

Infrastructure de développement multi-agent locale : Docker Desktop (WSL2), Ollama, OpenCode, Continue, VS Code.
État (9.B.1) : **Ollama 0.40.18** (CPU, réseau interne, aucun port publié) avec **7 modèles** (52,98 Gio, aucun chargé au repos, benchmarks 6.B.1) ;
**OpenCode 2.3.2** sur `http://127.0.0.1:4096` (authentification locale, sans accès Internet, fournisseur Ollama interne uniquement) ;
**10 agents** finalisés (9 dans OpenCode, Assistant par défaut ; autocomplétion Continue à l'étape 11), permissions S2 et délégations de profondeur 1 appliquées par le serveur ;
MCP GitHub, GitLab, Jira, Confluence **préparés et désactivés**.

## Arborescence

| Dossier | Rôle |
|---|---|
| `compose/` | `services/` socle inclus, `templates/` modules (ollama et opencode actifs), `overrides/` surcharges sur autorisation |
| `config/` | Ollama, OpenCode, Continue, réseau, sécurité, supervision |
| `agents/` | définitions YAML indépendantes d'OpenCode, prompts, catalogue d'outils |
| `models/` | registre des modèles, benchmarks |
| `mcp/` | registre et serveurs officiels GitHub, GitLab, Jira, Confluence (préparés, désactivés) |
| `profiles/` | performance A/B/C, réseau N1-N4, sécurité S1-S4, sauvegarde BK1-BK3 |
| `scripts/` | lifecycle, profils, supervision, maintenance, sauvegarde (à venir) |
| `projects/` | projets indépendants (non suivis), `templates/` suivis |
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
.\local-ai.ps1 mcp list|status           # serveurs MCP préparés (enable refusé tant que N4 non implémenté)
.\local-ai.ps1 agent list                # agents, modèles, écarts à l'affectation initiale, avertissements outils/RAM
.\local-ai.ps1 agent model <agent> [<modèle>]   # afficher / changer durablement (BK1 + rollback, OpenCode régénéré)
.\local-ai.ps1 agent reset <agent|all>   # revenir aux affectations initiales (agents/assignments.initial.yaml)
```

Sélection **temporaire** d'un modèle : sélecteur de la session dans le Web ou le TUI (7 modèles du registre).
OpenCode Desktop (Windows) : **non utilisé** — il impose un serveur autonome sur l'hôte avec accès Internet (ADR-0008, R9).

Mot de passe Web/API : `secrets/opencode.env` (non versionné). Les autres commandes (`profile`, `agent`, `monitor`, `permissions`,
`backup`, `restore`, `maintenance`, `emergency-stop`) sont prévues et échouent explicitement tant qu'elles ne sont pas implémentées.

## Profils par défaut

`profiles/defaults.yaml` : performance **B**, réseau **N1**, sécurité **S2**, sauvegarde **BK1** (état souhaité vs appliqué).

Voir `docs/decisions/0001-politiques-validees.md` pour les seuils et politiques.
