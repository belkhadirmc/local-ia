# ADR-0003 — Réserves et fonctionnalités différées (clôture étape 3)

Statut : ouvert — à traiter avant ou pendant le déploiement (étape 4+).

## Réserves

| # | Réserve | Traitement prévu |
|---|---|---|
| R1 | La surcharge localhost (127.0.0.1) limite l'exposition entrante mais ne garantit pas le blocage Internet sortant ; `enable_ip_masquerade=false` non testé. | Test réel au déploiement d'Ollama (route, résolution, connexion sortante). |
| R2 | Compose impose la structure `dépôt:version@sha256:<digest>` mais ne valide pas le format du digest. | Contrôle par `local-ai.ps1 config` (64 hex, tag ≠ latest) ; échec de pull si digest invalide. |
| R3 | Docker Engine : `builder.gc` actif (`defaultKeepStorage: 20GB`) — purge automatique du cache BuildKit. Non critique, mais à arbitrer avant toute compilation d'image (OpenCode, MCP). | Décision avant la première construction ; aucune modification Docker en 3.B.2. |
| R4 | ACL Windows : `secrets/`, `backups/`, `runtime/` restreints à l'utilisateur, SYSTEM et Administrateurs (héritage retiré ; avant : ACL 100 % héritées, dont Utilisateurs RX et Utilisateurs authentifiés M). ACL du parent sauvegardée : `backups/config/acl_parent_3.B.2_*.txt`. | Retour arrière : `icacls <dossier> /reset /T` (réapplique l'héritage du parent). |
| R5 | Affectations des modèles aux agents non confirmées (tags et digests vérifiés en 5.B.1). | Benchmarks (models/benchmarks/). |
| R6 | `qwen3-coder:30b` : 78,9 % de RAM WSL2 au test (contexte 2048) ; le contexte 8192 par défaut reste à valider sous charge. | Benchmarks / ajustement du contexte par agent. |

## Fonctionnalités différées

- Images épinglées OpenCode / MCP ; chemins de données OpenCode. (Ollama : épinglé et non-root, résolu en 4.B.1 — ADR-0004.)
- Format de configuration OpenCode (export depuis `agents/definitions/`) ; modèle Continue à valider.
- Commandes `local-ai.ps1` : model pull/rm, profile, agent, mcp, monitor, permissions, backup, restore, maintenance, emergency-stop.
- Tests d'exécution : sécurité, isolation réseau, localhost, supervision (seuils `config/monitoring/thresholds.yaml`).
- État appliqué des profils N1/S2 : non appliqué tant qu'aucun service n'est déployé (`profiles/defaults.yaml`).