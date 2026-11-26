# ADR-0010 — Sécurité avancée et MCP N4 (10.B.1)

Statut : appliqué le 2026-11-26. Profil par défaut **S2**. MCP **tous désactivés** à la fin de l'action. Aucun compte connecté, aucun jeton créé.
Sauvegarde BK1 préalable : `backups/restore-points/10.B.1_20261126_153514` (agents, config, profils, compose, mcp ; aucun secret).

## Profils S1–S4 (générateur OpenCode, `profiles/defaults.yaml` → `desired.security`)

| Profil | edit | shell | Git lecture | Délégation | MCP | Remarque |
|---|---|---|---|---|---|---|
| S1 supervisé | ask | ask | ask | ask | deny | tout appel d'écriture ou commande validé |
| **S2 semi-autonome (défaut)** | ask | ask | allow | **ask** (validation rétablie) | ask | |
| S3 autonome contrôlé | allow | allow | allow | allow | ask | exige `permissions profile S3 --confirm` |
| S4 personnalisé | S1 + `profiles/custom/*.yaml` | | | | | règles `- {agent, action, resource, effect}` |

Un profil n'élargit jamais une capacité refusée par la définition de l'agent. Profondeur de délégation : 1 dans tous les profils (imposée
techniquement, R11 ; S3 déclarait 2, ramené à 1). Changement : `local-ai.ps1 permissions profile <S>` (BK1, régénération, rollback).

## Permissions

- Ordre des règles (la dernière correspondante l'emporte) : base `deny` → outils de la définition (effet du profil) → règles anti-chaînage
  → autorisations accordées → **refus techniques** (toujours derniers, donc prioritaires et non surchargeables).
- Refus techniques (33) : `shell` contenant `git push`, `sudo`, `curl`, `wget`, `nc`, `ssh`, `scp`, `/proc/`, `environ`,
  `OPENCODE_PASSWORD`, `opencode api|run|serve`, `:4096`, `mcp-relay`, `mcp-egress`, `docker` ; `webfetch`, `websearch`, `external_directory` ;
  `read`/`edit` de `*.env`, `*.env.*`, `*secrets*`, `/proc/*`, `/etc/opencode/*`.
- **Anti-chaînage** (faille trouvée et corrigée) : OpenCode compare des préfixes, `git status; rm -rf src` était **autorisé** pour le reviewer.
  Toute commande contenant `;`, `&`, `|`, `` ` ``, `$(`, `>`, `<`, saut de ligne, `--output`, `--ext-diff`, `-c core.` retombe sur l'effet
  shell de base de l'agent (deny pour les agents sans shell, ask sinon).
- `local-ai.ps1 permissions list | check <agent> <action> <ressource> | grant | revoke | reset | profile` :
  - `check` utilise l'évaluateur du serveur (`POST /api/session/{id}/permission`, session temporaire supprimée) : résultat déterministe, sans inférence ;
  - `grant <agent|*> <action> <ressource> [--effect allow|ask] [--project <nom>]` : autorisation **persistante** (`config/security/grants.yaml`),
    BK1 + régénération + rollback ; refus explicites : action ou ressource couverte par un refus technique, `deny` (utiliser revoke),
    délégation hors variantes `-delegue`, MCP non activé, portée projet pour `shell`, virgule dans la ressource ;
  - portées : **une fois** = « Autoriser une fois » dans le Web/TUI ; **persistante** = `grant` (local-ai) ou « Toujours » (OpenCode, par
    projet, listée et révocable : `revoke saved <id>`) ; **session** : non prise en charge par OpenCode 2.3.2 (refus explicite) ;
  - portée **projet** : préfixe `<projet>/` des chemins (`read`, `grep`, `glob`, `edit`) ; agent ou `*` ; outil MCP `<serveur>_<outil>`.

## Arrêt d'urgence et audit

- `local-ai.ps1 emergency-stop` : drapeau `runtime/state/emergency.json`, interruption des sessions actives (API), arrêt des relais MCP
  (étiquette `local-ai.module=mcp`), arrêt d'OpenCode et de son espace réseau, déchargement des modèles. **Aucune suppression.**
  `start` et `mcp enable` refusés tant que le drapeau existe ; `emergency-stop status|clear` ; redémarrage explicite ensuite.
- Journal d'audit `runtime/logs/audit.jsonl` (non versionné) : start, agent, permissions, profils, MCP, urgence ; masquage des motifs de
  secret ; aucun contenu de fichier. Vérifié : le mot de passe OpenCode n'y figure pas.

## MCP N4 (`scripts/mcp/n4.ps1`)

- **Images** (téléchargées, épinglées par digest, officielles) : `ubuntu/squid:6.6-24.04_edge@sha256:d5889767…d2eb` (Canonical, Ubuntu 24.04 LTS ;
  canal `_beta` écarté car daté de 2025) et `ghcr.io/github/github-mcp-server:v2.3.0@sha256:110ce018…7926` (mode `http` natif :
  **aucune construction d'image**, R3 non concerné). ≈ 280 Mo au total.
- **Flux container-http (GitHub)** : OpenCode → `local-ai-mcp-relay` (interne) → `mcp-relay-<id>` (squid reverse proxy : chemin MCP et
  méthodes MCP seuls, en-tête `Authorization` du client supprimé puis jeton injecté depuis `secrets/`) → `local-ai-mcp-srv-<id>` (interne) →
  serveur officiel (`--read-only`, jeux d'outils context/repos/issues/pull_requests) → `mcp-egress-<id>` (squid : `CONNECT` 443 vers la liste
  blanche uniquement) → `local-ai-mcp` (N4). **Flux remote-http (GitLab, Jira, Confluence)** : relais → sortie vers une origine HTTPS fixe.
- Durcissement : uid 13 (squid) / 65532 (serveur), racine en lecture seule, tmpfs, `cap_drop ALL`, `no-new-privileges`, 128–256 Mio, 64 pids,
  aucun socket Docker, **projet Compose dédié `local-ai-mcp-<id>`**.
- `mcp enable <id> --authorize-n4 [--witness]` : refus si autorisation absente, arrêt d'urgence, image absente ou non épinglée, secret
  absent, réseau relais absent ; sinon génération (`runtime/mcp/<id>/`), démarrage, sonde depuis l'espace réseau d'OpenCode, activation
  (`mcp/registry.yaml`), régénération OpenCode (`mcp.use` autorisé pour ce seul serveur ; outils `<id>_*` en `ask` pour les agents autorisés)
  et rollback en cas d'échec. `mcp disable <id> [--revoke]` : arrêt et suppression des relais (fichiers générés uniquement), copie relais du
  jeton supprimée avec `--revoke` (le jeton chez le fournisseur reste à révoquer par l'utilisateur).

## Tests 10.B.1 (courts ; « simulé » = témoin local, aucune connexion externe)

| Test | Résultat |
|---|---|
| Contournements shell (25 cas : `bash -c`, `sh -c`, `/proc/1/environ`, `printenv`, `opencode api`, `:4096`, chaînage `;` `&&` `|` `$()` saut de ligne, `--output`) | PASS après correctif anti-chaînage |
| Chemins (`../`, `*.env`, `*.env.*`, `secrets`, `/etc/opencode`, `external_directory`) ; sous-agents (non-variante, hors liste, variante → délégation) ; webfetch | PASS |
| `grant` (portée projet) → allow, autre chemin → ask, `.env` du projet → deny ; 7 refus explicites ; `revoke` → ask ; `reset` | PASS |
| Profils : S1 (Git lecture → ask), S3 sans `--confirm` refusé, retour S2 | PASS |
| Isolation N1 : Ollama et OpenCode sans route par défaut, 1.1.1.1 injoignable | PASS |
| MCP : `enable` refusé sans autorisation, et sans secret en mode réel | PASS |
| MCP témoin : `initialize` via relais (jeton injecté), OpenCode « connected », 26 outils tous `readOnlyHint`, 0 outil d'écriture, `create_issue` → outil inconnu, relais hors chemin MCP → 403 | PASS (simulé) |
| Filtrage par destination : liste blanche 200, hors liste 403, 1.1.1.1 403, sans proxy injoignable ; `CONNECT api.github.com:443` du serveur **refusé** (hors liste témoin) | PASS (simulé) |
| Depuis OpenCode : proxy de sortie, serveur MCP, témoins et Internet injoignables | PASS |
| Permissions MCP : developer `github_*` → ask ; assistant, qa → deny ; serveur non activé → deny | PASS |
| Arrêt d'urgence : 1 session active interrompue, 3 relais arrêtés, OpenCode arrêté, 1 modèle déchargé ; `start`/`mcp enable` refusés ; `clear` + `start` → sain, 5 sessions et 7 modèles conservés | PASS |
| `mcp disable` : relais, réseaux de test et fichiers générés supprimés ; configuration identique au générateur | PASS |
| Connexion réelle à GitHub, GitLab, Atlassian | NON TESTÉ (aucun jeton ni accord) |

## Incident corrigé

Premier `mcp disable` : `docker compose -p local-ai … down --remove-orphans` a supprimé les **conteneurs** Ollama et OpenCode
(orphelins du point de vue du fichier MCP). **Volumes intacts** (7 modèles, sessions conservées), conteneurs recréés par `start opencode`.
Correctif : projet Compose dédié `local-ai-mcp-<id>`, plus aucun `--remove-orphans`.
