# Agents

10 agents : 9 dans OpenCode, 1 autocomplétion (Continue). Définitions : `agents/definitions/*.yaml`, prompts : `agents/prompts/*.md`,
affectations initiales (référence de restauration, inchangée) : `agents/assignments.initial.yaml`. Configuration OpenCode générée :
`config/opencode/generate-config.ps1` (ne pas éditer `opencode.json` à la main).

| Agent | Rôle | Modèle initial | Outils | Repli (mode) |
|---|---|---|---|---|
| assistant | point d'entrée, lecture, orientation | qwen3.5:4b | lecture | aucun (off) |
| architect | conception, plan de tâches | gpt-oss:20b | lecture, git (lecture) | 9B -> 4B (auto) |
| developer | implémentation | qwen3-coder:30b | lecture, édition et shell (ask), git (lecture) | 9B -> 4B (auto) |
| devops | Docker, CI, scripts | qwen3-coder:30b | lecture, édition et shell (ask), git (lecture) | 9B -> 4B (auto) |
| debugger | diagnostic, correction | qwen2.5-coder:14b | lecture, édition et shell (ask), tests, git (lecture) | 9B -> 4B (auto) |
| qa | tests | qwen2.5-coder:7b | lecture, écriture (ask), tests `pytest` (ask), git (lecture) | 4B (auto) |
| reviewer | relecture | gpt-oss:20b | lecture, git (lecture) | 9B -> 4B (auto) |
| security | revue de sécurité | gpt-oss:20b | lecture, git (lecture) | 9B **sur confirmation** (ask) |
| documentalist | documentation | qwen3.5:9b | lecture, édition (ask), git (lecture) | 4B (auto) |
| autocomplete | autocomplétion (Continue) | qwen2.5-coder:1.5b | — | aucun (off) |

**Limites connues** : qwen2.5-coder et qwen3-coder ne produisent pas d'appels d'outils exploitables par Ollama 0.40.18 (6.B.1, 14.B.1) ;
d'où le repli automatique pour les agents à outils. qwen3.5:4b est faible en analyse de sécurité (R32) : préférer gpt-oss:20b avec
la RAM libérée. Recommandations d'affectation (non appliquées) : ADR-0014.

## Commandes

```powershell
.\local-ai.ps1 agent list                         # modèles, écarts, avertissements outils/RAM
.\local-ai.ps1 agent model <agent> [<modèle>]     # changement DURABLE (BK1 + rollback) — sur décision explicite
.\local-ai.ps1 agent reset <agent|all>            # retour aux affectations initiales
.\local-ai.ps1 agent handoff <agent> "<consigne>" [--accept-fallback] [--watch <s>] [--model <tag>]
.\local-ai.ps1 fallback list | check <agent|all> | mode <agent> auto|ask|off
.\local-ai.ps1 permissions list | check <agent> <action> <ressource> | grant | revoke | reset | profile <S1-S4>
```

## Permissions (S2)

Base `deny` ; lecture `allow` ; édition et shell `ask` ; `git status/diff/log/show` autorisés aux agents « git-read » ; délégation
désactivée (`delegation_mode: manual`). Refus techniques prioritaires (extrait) : `git push`, `sudo`, `curl`, `wget`, `docker`,
`/proc/`, `environ`, `OPENCODE_PASSWORD`, code en ligne (`sh -c`, `python -c`, `perl -e`, `node -e`, `eval`), `base64`, `/tui-tmp`,
accès direct au moteur Ollama et aux relais MCP, lecture de `secrets/`, `*.env`, `/etc/opencode/*`. Commandes composées (`;` `&` `|`
redirections, substitutions) : toujours soumises à validation. Évaluation sans inférence : `permissions check`.
