# local-ai

Infrastructure de développement multi-agent locale : Docker Desktop (WSL2), Ollama, OpenCode, Continue, VS Code.
Étape 3.B.1 : **fondations uniquement** — aucun service déployé, aucun modèle téléchargé.

## Arborescence

| Dossier | Rôle |
|---|---|
| `compose/` | `services/` socle inclus, `templates/` modules inactifs, `overrides/` surcharges sur autorisation |
| `config/` | Ollama, OpenCode, Continue, réseau, sécurité, supervision |
| `agents/` | définitions YAML indépendantes d'OpenCode, prompts, catalogue d'outils |
| `models/` | registre des modèles, benchmarks |
| `mcp/` | registre et modèles GitHub, GitLab, Jira, Confluence (désactivés) |
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
```

Les autres commandes (`start`, `stop`, `profile`, `model`, `agent`, `mcp`, `monitor`, `permissions`,
`backup`, `restore`, `maintenance`, `emergency-stop`) sont prévues et échouent explicitement tant qu'elles ne sont pas implémentées.

## Profils par défaut

`profiles/defaults.yaml` : performance **B**, réseau **N1**, sécurité **S2**, sauvegarde **BK1** (état souhaité vs appliqué).

Voir `docs/decisions/0001-politiques-validees.md` pour les seuils et politiques.
