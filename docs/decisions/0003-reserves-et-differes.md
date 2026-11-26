# ADR-0003 — Réserves et fonctionnalités différées (clôture étape 3)

Statut : ouvert — à traiter avant ou pendant le déploiement (étape 4+).

## Réserves

| # | Réserve | Traitement prévu |
|---|---|---|
| R1 | **Testé en 7.B.1 : `enable_ip_masquerade=false` ne bloque PAS la sortie** sous Docker Desktop (1.1.1.1, github.com joignables) ; un réseau interne ne publie aucun port. **Traité** pour OpenCode : suppression des routes par défaut dans son espace réseau par un garde éphémère (`NET_ADMIN` seul) et vérification d’échec de sortie obligatoire avant démarrage (ADR-0007). | Toute autre publication 127.0.0.1 doit réutiliser ce montage ; la surcharge `*-localhost.yaml` seule est insuffisante. |
| R2 | Compose impose la structure `dépôt:version@sha256:<digest>` mais ne valide pas le format du digest. | Contrôle par `local-ai.ps1 config` (64 hex, tag ≠ latest) ; échec de pull si digest invalide. |
| R3 | Docker Engine : `builder.gc` actif (`defaultKeepStorage: 20GB`) — purge automatique du cache BuildKit. Non critique, mais à arbitrer avant toute compilation d'image (OpenCode, MCP). | Décision avant la première construction ; aucune modification Docker en 3.B.2. |
| R4 | ACL Windows : `secrets/`, `backups/`, `runtime/` restreints à l'utilisateur, SYSTEM et Administrateurs (héritage retiré ; avant : ACL 100 % héritées, dont Utilisateurs RX et Utilisateurs authentifiés M). ACL du parent sauvegardée : `backups/config/acl_parent_3.B.2_*.txt`. | Retour arrière : `icacls <dossier> /reset /T` (réapplique l'héritage du parent). |
| R5 | Affectations des modèles aux agents non confirmées (outil `local-ai.ps1 agent` disponible depuis 8.B.1, référence `agents/assignments.initial.yaml`) ; benchmarks 6.B.1 réalisés (recommandations par rôle dans `models/benchmarks/report.md`). | Décision d'affectation (étape suivante). |
| R7 | MCP (GitHub, GitLab, Jira, Confluence) préparés mais **non activables** : architecture N4 (relais MCP isolé, sortie limitée par destination) non implémentée ; aucune image de relais autorisée. | Étape dédiée : choix et épinglage d’un relais, filtrage de sortie, jetons en lecture seule créés par l’utilisateur. |
| R8 | OpenCode : la page Web (`/`) est servie sans authentification (coquille statique) ; l’API exige l’authentification Basic. Agents sur `qwen2.5-coder:*` et `qwen3-coder:30b` : appels d’outils non extraits par Ollama (6.B.1). | Surveillance des versions OpenCode ; affectations à revoir (R5). |
| R9 | OpenCode Desktop (Windows) incompatible : CLI 2.4.2 téléchargée au lancement et serveur autonome sur l’hôte avec accès Internet (8.B.1) ; non connecté, application fermée. | Désinstallation recommandée ; réévaluer si une option « serveur distant uniquement » documentée apparaît. |
| R10 | Sélection temporaire : la session accepte tout modèle (cloud, hors registre) ; seul le refus à l’exécution (`provider.use`, registre) protège. | Contrôle à l’exécution vérifié ; à surveiller à chaque mise à jour d’OpenCode. |
| R11 | OpenCode 2.3.2 ignore `subagent_depth` : profondeur 1 imposée par construction (délégation vers des variantes cachées `<agent>-delegue` sans aucune délégation) ; prompts non suffisants seuls. | Revoir si une version épinglée applique `subagent_depth` ; contrôle par le générateur (cibles, cycles, max_depth). |
| R12 | Délégations lentes sur CPU : une seule inférence à la fois (`OLLAMA_NUM_PARALLEL=1`), la sous-session attend la fin des requêtes du parent et change de modèle ; une sous-session non terminée reste « running » et bloque la file. | Déléguer à des agents légers, interrompre les sessions bloquées (`POST /api/session/{id}/interrupt`), pas de délégation en chaîne. |
| R13 | Premier message à froid lent (≈ 110 s avec qwen3.5:4b) : chargement + traitement CPU du prompt système OpenCode (≈ 2 840 tokens) ; ensuite 9 à 12 s grâce au cache. Raisonnement désactivé pour qwen3.5, `low` pour gpt-oss (9.B.2). | Patienter au premier message ; ne pas réactiver le raisonnement sur CPU sans délai adapté. |
| R6 | `qwen3-coder:30b` : contexte 8192 **validé** en 6.B.1 (prompt de 7249 tokens, aiguille 100 %), pic 84,6 % de RAM WSL2 hors cache (alerte 85 %) et RAM Windows disponible minimale 4,35 Gio (interruption < 4 Gio) : marge quasi nulle ; appels d'outils non extraits par Ollama 0.40.18 (balise `<tool_call>` ouvrante absente). | Usage exclusif (aucune charge concurrente) ; pas de contexte > 8192 en profil B ; ne pas l'affecter à un rôle à outils sans correctif de modèle de prompt. |

## Fonctionnalités différées

- Images MCP (référence GitHub épinglée, non téléchargée). OpenCode épinglé et déployé en 7.B.1 (ADR-0007) ; Ollama en 4.B.1 (ADR-0004).
- Modèle Continue à valider. (Configuration OpenCode générée depuis `agents/definitions/` en 7.B.1.)
- Commandes `local-ai.ps1` : model pull/rm, profile, agent, mcp enable (refus explicite), monitor, permissions, backup, restore, maintenance, emergency-stop.
- Tests d'exécution : sécurité, isolation réseau, localhost, supervision (seuils `config/monitoring/thresholds.yaml`).
- État appliqué des profils N1/S2 : non appliqué tant qu'aucun service n'est déployé (`profiles/defaults.yaml`).