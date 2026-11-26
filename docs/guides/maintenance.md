# Maintenance

`.\local-ai.ps1 maintenance status` (lecture seule) : espace Docker (images, volumes, cache de construction), sauvegardes / quota,
journaux et métriques, sentinelle RAM, arrêt d'urgence, configuration OpenCode, modèles chargés. **Aucune purge automatique.**

## Routine

| Fréquence | Action |
|---|---|
| à chaque session | `monitor status` ; fermer les applications lourdes avant un modèle ≥ 14B |
| hebdomadaire | `config`, `maintenance status`, `backup create BK1` (configurations) |
| avant un changement | `backup create BK2` (projets, sessions, outils) puis `backup verify <id>` |
| mensuelle | `backup status` (quota 10 Gio), suppression manuelle des sauvegardes obsolètes (`backup delete <id> --confirm`) |

Rétention : métriques 7 jours et audit 30 jours (appliquées par `monitor`) ; sauvegardes sans expiration automatique, bornées par le
quota global de 10 Gio (`backups/`).

## Mises à jour (sur décision, jamais automatiques)

Images, extensions VS Code et outils sont **épinglés**. Une mise à jour suit toujours : BK1 + BK2 → nouvelle version vérifiée (source,
digest, signature) → fenêtre réseau N2 limitée au téléchargement → réépinglage (`.env`, `config/tools/lock.txt`) → `config` →
tests de non-régression (`tests/`) → ADR. Points d'attention : OpenCode (format de configuration V2, `subagent_depth` R11, crochet
pré-requête R33), Ollama (extraction des appels d'outils R34), squid `_edge` (R16), dépôt Alpine des outils (R35), cache BuildKit
avant toute construction (R3).

## Nettoyage (manuel)

- Conteneurs arrêtés de test : `docker ps -a --filter label=local-ai.temporary=true`.
- Volumes témoins de restauration : `docker volume ls --filter label=local-ai.volume=restore-test` puis `docker volume rm <nom>`.
- Images : `docker image prune` uniquement après vérification que les images épinglées restent présentes (`config`).
- Ne jamais supprimer `local-ai-ollama`, `local-ai-opencode`, `local-ai-tools`, `local-ai-workspace-*` sans sauvegarde vérifiée.
