# ADR-0009 — Finalisation des 10 agents (9.B.1)

Statut : appliqué le 2026-11-26. Affectations **initiales conservées** (gestion manuelle `local-ai.ps1 agent`, ADR-0008).
Sauvegarde BK1 préalable : `backups/restore-points/9.B.1_20261126_135507` (agents/, config/opencode/, profils ; aucun secret).

## Agents et affectations

| Agent | Modèle (initial) | Client | edit | shell | Délégations autorisées |
|---|---|---|---|---|---|
| assistant (défaut) | qwen3.5:4b-q4_K_M | OpenCode | deny | deny | architect, developer, documentalist |
| architect | gpt-oss:20b | OpenCode | deny | Git lecture | developer, devops, reviewer, security, documentalist |
| developer | qwen3-coder:30b | OpenCode | ask | ask | qa, debugger |
| devops | qwen3-coder:30b | OpenCode | ask | ask | security |
| debugger | qwen2.5-coder:14b | OpenCode | ask | ask | qa |
| qa | qwen2.5-coder:7b | OpenCode | ask | tests (ask) + Git lecture | — |
| documentalist | qwen3.5:9b-q4_K_M | OpenCode | ask | Git lecture | — |
| reviewer | gpt-oss:20b | OpenCode | deny | Git lecture | — |
| security | gpt-oss:20b | OpenCode | deny | Git lecture | — |
| autocomplete | qwen2.5-coder:1.5b | Continue (étape 11) | — | — | — |

## Décisions

- **Prompts** (`agents/prompts/*.md`) : mission, expertise, méthode, limites, qualité, livrables, collaboration ; règles S2 communes
  dans `agents/prompts/_common.md`, ajoutées par le générateur à chaque agent OpenCode.
- **Permissions S2** (traduites des définitions, sans élargissement) : base `deny` ; lecture/recherche `allow` ; `edit` et `shell` en
  `ask` uniquement si la définition le prévoit ; commandes Git de lecture `allow` pour `git-read` ; commandes de test en `ask` pour `qa` ;
  toujours refusés : `webfetch`, `websearch`, `external_directory`, `git push`, `sudo`, `curl`, `wget`, `*.env`, `*secrets*`.
  Agents intégrés `build`, `plan`, `general`, `explore` **désactivés** (aucune porte d'entrée plus permissive).
- **Délégations appliquées par le serveur** : `subagent` refusé par défaut, `allow` uniquement vers les cibles déclarées.
  OpenCode 2.3.2 **ignore `subagent_depth`** (clé absente de la configuration chargée) : la profondeur 1 est imposée par construction —
  chaque cible est exposée sous une variante cachée `<agent>-delegue` (même modèle, mêmes permissions de base, **aucune délégation**).
  Les agents sélectionnables ne sont pas délégables directement. Le générateur échoue si une cible est inconnue ou hors OpenCode,
  en cas d'auto-délégation, de cycle ou de `max_depth` ≠ 1. `agent model`/`reset` régénèrent et vérifient aussi la variante.
- **Limites documentées, sans substitution automatique** : appels d'outils non extraits pour `qwen2.5-coder:*` et `qwen3-coder:30b`
  (debugger, developer, devops, qa : outils d'édition/shell peu fiables, 6.B.1) ; RAM : `qwen3-coder:30b` 84,6 % à 8192 (usage exclusif),
  `gpt-oss:20b` 61,8 %. Délégations lentes sur CPU (une inférence à la fois, changement de modèle) : R11, R12.

## Tests 9.B.1 (courts)

| Test | Résultat |
|---|---|
| Cohérence des 10 définitions (modèles, prompts, délégations, profondeur, cycles) — `local-ai.ps1 config` + générateur | PASS |
| Visibilité : 9 agents sélectionnables, Assistant par défaut, 8 variantes cachées, agents intégrés désactivés (API `/api/agent`) | PASS |
| Permissions chargées par le serveur (edit/shell/subagent par agent) | PASS |
| Délégation autorisée réelle : assistant → `documentalist-delegue` acceptée par le serveur, sous-session créée (agent et modèle corrects) | PASS (routage) |
| … réponse de la sous-session dans le délai | NON OBTENUE (file CPU : requête en attente ~23 min puis interrompue ; relance : le modèle 4B n'a pas appelé l'outil) |
| Délégation refusée : assistant → `security-delegue` → « Permission denied: subagent » | PASS |
| `agent model documentalist` puis `agent reset` (définition, variante, API, BK1) ; 0 écart aux affectations initiales | PASS |

Sessions de test supprimées (titres `9B1-*` et sous-session) ; sessions préexistantes conservées. Aucun modèle chargé à la fin.
