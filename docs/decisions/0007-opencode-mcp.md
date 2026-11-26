# ADR-0007 — Déploiement d'OpenCode et préparation MCP (7.B.1)

Statut : appliqué le 2026-11-26. Affectations des agents **inchangées** (définitions initiales).

## OpenCode

- **Image** : `ghcr.io/anomalyco/opencode:2.3.2`, manifeste linux/amd64 `sha256:43d4d0fb1d94fed8db615f865df7661104a39af6ca94dad631c09844b5e3ff22`
  (index `sha256:be07cc4a…15f5a`), Alpine 3.24, ≈ 128 Mio compressés / 279 Mo locaux. Version stable retenue : dernière de la
  série 2.3 (publiée le 2026-11-18, sans correctif depuis) ; 2.4.x écartée (trois versions en trois jours, 2.4.2 publiée le jour même).
  Documentation officielle lue (opencode.ai/docs : config, server, web, providers, cli, mcp-servers, permissions, network) ;
  options vérifiées sur le binaire 2.3.2 (variables `OPENCODE_*`, `opencode debug paths`). Fenêtre N2 limitée au `docker pull`
  épinglé par le démon (aucun conteneur sur réseau sortant), retour immédiat en N1.
- **Services** (profil Compose `opencode`, `restart: "no"`, logs `local` 10m/5) :
  - `opencode-init` : root, `network_mode: none`, `CAP_CHOWN` seul — crée `/data/workspace` et attribue `/data` à 1000:1000 ;
  - `opencode-net` : porteur de l'espace réseau (`local-ai-core` + `local-ai-localhost`, port `127.0.0.1:4096`), uid 1000, sans capacité ;
  - `egress-guard` : éphémère, root + `NET_ADMIN` seul, dans l'espace réseau d'`opencode-net` : supprime les routes par défaut
    (IPv4/IPv6) puis **vérifie l'échec** d'une connexion vers 1.1.1.1 ; sinon OpenCode ne démarre pas (échec fermé) ;
  - `opencode` : `opencode serve --hostname 0.0.0.0 --port 4096`, uid 1000, `cap_drop ALL`, Seccomp par défaut, `no-new-privileges`,
    racine en lecture seule, `/tmp` en tmpfs, 2 Gio / 512 pids, aucun socket Docker ; healthcheck = API authentifiée + absence de route par défaut.
- **Données** : volume externe `local-ai-opencode` (labels `critical`, module `opencode`) sur `/data` (`HOME`, base de sessions,
  `workspace/`). Configuration : `config/opencode/opencode.json` montée en lecture seule comme configuration système
  (`/etc/opencode`, priorité maximale), générée par `config/opencode/generate-config.ps1` depuis `models/registry.yaml` et `agents/definitions/`.
- **Fournisseur** : Ollama interne uniquement (`http://ollama:11434/v1`), 7 modèles, `limit.context` 8192, sortie 4096 (profil B).
  Politiques : `provider.use` refusé sauf `ollama` ; `websearch.use`, `mcp.use` et intégrations refusés, sauf l'intégration `ollama`
  (nécessaire à la découverte locale). `update: disable`, `share: disabled`, `websearch: false`, LSP et formateurs désactivés ;
  `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_DISABLE_MODELS_FETCH`, `OPENCODE_DISABLE_FREE_MODELS`, `OPENCODE_DISABLE_CLAUDE_CODE*` = 1.
  Aucun réglage de télémétrie trouvé (documentation, schéma) ; aucune sortie réseau possible de toute façon (R1).
- **Agents** : 9 agents OpenCode (Continue exclu), modèles et permissions des définitions : base `deny` ; lecture/recherche selon
  `read` ; `edit` en `ask` ou `deny` ; `shell` en `ask` seulement si `bash: ask` ; lecture Git autorisée ; délégations en `ask` ;
  `webfetch`, `websearch`, `external_directory`, `git push`, `sudo`, `curl`, `wget`, `*.env`, `*secrets*` refusés. Agent par défaut : `assistant`.
- **Accès** : Web et API sur `http://127.0.0.1:4096` uniquement ; authentification Basic (utilisateur `opencode`, mot de passe
  aléatoire de 256 bits dans `secrets/opencode.env`, non versionné, jamais affiché). Terminal : `.\local-ai.ps1 tui` (dans le conteneur).
- **Administration** : `local-ai.ps1 start|stop opencode` (démarre aussi Ollama ; l'arrêt d'OpenCode ne touche pas Ollama),
  `status` (santé, port, modèles chargés, MCP), `config` (3 contrôles ajoutés : configuration à jour, isolation/exposition, secret).
  Toujours redémarrer via `start opencode` : un redémarrage isolé d'`opencode-net` rétablirait la route (son healthcheck passe alors en échec).

## Tests 7.B.1 (courts, aucun benchmark)

| Test | Résultat |
|---|---|
| Démarrage et santé (`opencode-init`, `egress-guard`, `opencode-net`, `opencode`) | PASS |
| Persistance : arrêt/démarrage puis recréation forcée (sessions et fichier témoin conservés, garde relancé) | PASS |
| Sécurité : uid 1000, CapEff 0, NoNewPrivs 1, Seccomp 2, racine en lecture seule, aucun socket Docker | PASS |
| Isolation sortante (R1) : 1.1.1.1, github.com, opencode.ai, models.dev, host.docker.internal, passerelles injoignables ; DNS résolu mais connexion impossible ; Ollama interne joignable | PASS |
| Accès : API 401 sans mot de passe ou avec un mauvais, 200 authentifiée ; page Web 200 ; port lié à 127.0.0.1 seulement, injoignable depuis l'adresse LAN | PASS |
| Visibilité : 7 modèles Ollama via l'API OpenCode, contexte 8192 | PASS |
| Inférence courte `qwen3.5:4b-q4_K_M` (agent assistant) | PASS (« PRÊT », 93 s à froid) |
| Appel d'outil **réellement exécuté** : `read` d'un fichier témoin, contenu exact restitué | PASS |
| Outil refusé : `shell` → « Permission denied », rien exécuté | PASS |

Constat R1 : avec un simple pont `enable_ip_masquerade=false`, la sortie Internet fonctionnait (testé puis retiré aussitôt).

## MCP (préparés, tous désactivés)

- Définitions officielles dans `mcp/<id>/server.yaml` (+ `permissions.yaml`, `.env.example`, `opencode.snippet.json` désactivé) :
  GitHub (`ghcr.io/github/github-mcp-server:v2.3.0@sha256:110ce018…7926`, stdio, `--read-only`, jeux d'outils
  context/repos/issues/pull_requests ; image **non téléchargée**), GitLab (`/api/v4/mcp`, HTTP, OAuth 2.0 ou PAT à granularité fine),
  Jira et Confluence (Atlassian Rovo, `https://mcp.atlassian.com/v2/mcp`, OAuth 2.1).
- Architecture N4 cible (non implémentée) : OpenCode reste sans route ; un relais MCP par serveur sur `local-ai-mcp`, sortie
  limitée à `egress_allowlist`, secrets `secrets/mcp-<id>.env`. `local-ai.ps1 mcp list|status|enable|disable` : `enable` refuse
  explicitement (activation non implémentée, profil N4 non appliqué, secret absent, autorisation `--authorize-n4` absente).
- Aucun compte connecté, aucun jeton créé, aucun accès externe. Réserves R7 et R8 (ADR-0003).
