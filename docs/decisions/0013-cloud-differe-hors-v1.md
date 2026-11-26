# ADR-0013 — IA cloud différée hors V1

Statut : décidé et appliqué le 2026-11-26 (13.B.1). Sauvegarde BK1 : `backups/restore-points/13.B.1_20261126_200204`.

## Décision

- **La V1 est 100 % locale** : seuls les 7 modèles Ollama du registre sont utilisables (OpenCode, Continue, agents).
  Aucune intégration de modèle cloud : ni relais, ni client, ni fournisseur, ni clé, ni réseau attaché.
- **Aucun basculement automatique** : pas de modèle de repli, ni local→cloud, ni entre modèles locaux.
- **Points d'extension conservés, inactifs** : profil réseau N3 (`status: deferred_post_v1`), surcharge
  `compose/overrides/cloud.yaml` (réseau `local-ai-cloud`, déclaré par aucun service), architecture modulaire
  (`compose/templates/`, profils Compose, générateur `config/opencode/generate-config.ps1`, politiques OpenCode).

## Garanties en place (vérifiées le 2026-11-26, sans nouvelle inférence)

| Couche | Garantie | Vérification |
|---|---|---|
| OpenCode : fournisseurs | un seul fournisseur `ollama` (`http://ollama:11434/v1`, réseau interne, sans clé) | `/api/provider` = `ollama` seul ; `/api/model` = 7 modèles, tous `ollama/*` |
| OpenCode : politiques | `provider.use` refusé pour `*`, autorisé pour `ollama` seul ; `integration.*`, `websearch.use`, `mcp.use` refusés | `opencode.json` ; 8.B.1 : modèle cloud/hors registre accepté par la session mais **refusé à l'exécution**, aucune requête (R10) |
| OpenCode : repli | aucun `small_model`, aucune clé de repli ; modèle par défaut et 9 agents sur `ollama/*` | `opencode.json`, `/api/model/default`, `/api/config` |
| OpenCode : catalogue | `OPENCODE_DISABLE_MODELS_FETCH`, `_FREE_MODELS`, `_AUTOUPDATE`, `_CLAUDE_CODE*` = 1 ; `share` désactivé, recherche web désactivée | variables du conteneur ; `/api/websearch/provider` vide |
| Ollama | `OLLAMA_NO_CLOUD=1` ; 7 modèles locaux, aucun modèle `:cloud` ; `MAX_LOADED_MODELS=1`, `NUM_PARALLEL=1` | variables du conteneur, `ollama list` |
| Continue | un seul modèle `qwen2.5-coder:1.5b` via le relais local 127.0.0.1:11435 ; relais : **409 sans substitution** si un autre modèle est chargé | `config/continue/config.yaml` ; 11.B.1 |
| Réseau (N1) | Ollama sur `local-ai-core` seul ; OpenCode sans route par défaut ; sortie Internet vérifiée bloquée ; réseaux `local-ai-cloud`/`local-ai-egress` inexistants | 7.B.1, 12.B.1, contrôle 13.B.1 |
| MCP | 4 serveurs désactivés, aucun conteneur ni jeton | `mcp list` |
| Régression | nouveau contrôle `local-ai.ps1 config` « **V1 locale (aucun cloud)** » : fournisseur ollama seul, aucun `small_model`/`enabled_providers`, modèles `ollama/*`, `provider.use` limité, `OLLAMA_NO_CLOUD=1`, aucun modèle cloud au registre, Continue local | PASS ; test négatif (`OLLAMA_NO_CLOUD=0` temporaire) → FAIL, fichier restauré |

## Procédure d'extension future (post-V1), sans refonte du socle

À n'engager qu'après une décision explicite de l'utilisateur, avec un nouvel ADR qui remplace la présente décision et une sauvegarde BK1.

1. **Arbitrage** : fournisseur, modèles, données autorisées à sortir, coût, rétention ; agents concernés (jamais par défaut).
2. **Secret** : clé fournie par l'utilisateur dans `secrets/cloud-<fournisseur>.env` (non versionné), jamais dans `opencode.json`.
3. **Réseau** : appliquer N3 par session ; relais dédié sur le modèle N4 (`scripts/mcp/n4.ps1`) : conteneur porteur sur `local-ai-cloud`,
   sortie filtrée par destination (liste blanche du seul point d'accès du fournisseur), injection du secret par le relais.
   OpenCode reste sans route par défaut et ne joint que le relais (réseau interne dédié).
4. **OpenCode** : ajouter le fournisseur dans `generate-config.ps1` derrière une option explicite (désactivée par défaut), avec
   `provider.use` autorisé pour ce fournisseur uniquement ; aucun `small_model` ni repli automatique ; modèles cloud absents des
   affectations initiales (`agents/assignments.initial.yaml`) et sélection uniquement manuelle par session.
5. **Ollama** : conserver `OLLAMA_NO_CLOUD=1` (les modèles cloud d'Ollama restent exclus ; le cloud passerait par le relais dédié).
6. **Garde-fous** : adapter le contrôle « V1 locale » en contrôle « cloud explicitement autorisé » (liste blanche), ajouter
   `cloud on|off|status` sur le modèle de `continue on|off`, journal d'audit, arrêt d'urgence étendu au relais.
7. **Tests** : sortie limitée au seul point d'accès, refus des autres destinations, absence de repli, retour à l'état local par `cloud off`.

Le socle (Compose, profils, générateur, politiques, supervision) n'est pas modifié par cette procédure : seuls un module, une
surcharge réseau déjà réservée et une option du générateur sont ajoutés.
