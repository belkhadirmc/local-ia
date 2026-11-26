# ADR-0011 — VS Code, Continue, Dev Containers et projets (11.B.1)

Statut : appliqué le 2026-11-26. Affectations, permissions, MCP (désactivés) et isolation N1 inchangés.
Sauvegarde BK1 préalable : `backups/restore-points/11.B.1_20261126_162046` (dépôt + `settings.json` de VS Code + liste des extensions).

## Extensions (VS Code 1.147.0)

| Extension | Version | Choix |
|---|---|---|
| `Continue.continue` (éditeur vérifié « Continue ») | **2.0.0** (win32-x64) | dernière **stable** ; 2.1.0 = préversion ; moteur `^1.70.0` |
| `ms-vscode-remote.remote-containers` (Microsoft, vérifié) | **0.481.0** | dernière **stable** ; 0.482/0.483 = préversions ; moteur `^1.101.0` |

Installées par version explicite (`code --install-extension <id>@<version>`, signature vérifiée par VS Code). Réglages réels lus dans
le `package.json` et le code de Continue 2.0.0 (et non supposés) : `continue.*`, `~/.continue/config.yaml`,
`~/.continue/index/globalContext.json` (`sharedConfig`), points d'accès Ollama utilisés : `/api/generate`, `/api/show`, `/api/tags`.

## Continue : autocomplétion locale uniquement, désactivée par défaut

- `config/continue/config.yaml` → `~/.continue/config.yaml` : un seul modèle `qwen2.5-coder:1.5b`, rôle `autocomplete`, `apiBase`
  `http://127.0.0.1:11435` (relais), contexte 2048, `keepAlive` 120 s ; aucun modèle de chat/édition/embedding, `context: []`, aucun MCP.
- `globalContext.json` : `allowAnonymousTelemetry: false`, `disableIndexing: true`, `disableSessionTitles: true`.
- VS Code (`config/vscode/settings.local-ai.json`, fusion avec sauvegarde) : `continue.telemetryEnabled: false`,
  `continue.enableTabAutocomplete: false`, `enableNextEdit`/`enableQuickActions`/`showInlineTip`/`enableConsole: false`,
  `pauseCodebaseIndexOnStart: true`, `remoteConfigServerUrl: ""` ; profil de terminal **« OpenCode (local-ai) »** (`local-ai.ps1 tui`).
- `local-ai.ps1 continue install | on [--vscode] | off | status`. `on` est **manuel** et refusé si une session OpenCode est active ou si
  un autre modèle est chargé ; `off` arrête le relais et décharge le modèle.

## Relais d'autocomplétion (`compose/templates/continue.yaml`, `config/continue/relay.pl`)

- `127.0.0.1:11435` uniquement ; l'API Ollama n'est **jamais publiée** (11434 injoignable depuis l'hôte).
- Relais Perl (image Ollama épinglée déjà présente, modules de base, script en lecture seule ; aucune construction ni téléchargement) :
  `GET /`, `GET /api/tags` (liste réduite au modèle autorisé), `POST /api/show` et `POST /api/generate` du **seul** `qwen2.5-coder:1.5b`
  (toute clé `model` différente → 403) ; toute autre route (`/api/chat`, `/api/pull`, `/api/delete`, `/api/ps`…) → 403 ; corps > 1 Mio → 413 ;
  `keep_alive` plafonné à 120 s (Continue envoie 1800 s).
- **Aucune concurrence** : si un autre modèle est chargé (inférence OpenCode), `POST /api/generate` → **409**, sans déchargement ni substitution.
- Réseau : même montage que pour OpenCode (R1) — porteur `continue-net` (uid 1000, sans capacité, port publié sur 127.0.0.1), garde
  `continue-egress-guard` (NET_ADMIN seul) qui supprime la route par défaut et vérifie l'échec de sortie, relais en `network_mode: service:`.

## Projets Dev Containers (`projects/templates/devcontainer/`, `local-ai.ps1 project list|create|open|stop`)

- Image officielle `mcr.microsoft.com/devcontainers/base:3.0.14-noble` (= `ubuntu24.04`/`noble`), digest amd64 `sha256:6d5b4ab2…7e1a`,
  Ubuntu 24.04.5 LTS, utilisateur `vscode` (1000), ≈ 284 Mio compressés / 756 Mo locaux.
- Par projet `<id>` : volume persistant dédié `local-ai-workspace-<id>`, cache séparé `local-ai-cache-<id>` (montages `nocopy`, fichiers
  marqueurs : Docker ne réattribue pas le volume à root), réseau **interne** `local-ai-project-<id>`, conteneur `dev` non-root,
  `cap_drop: ALL`, `no-new-privileges` (sudo inopérant), 4 Gio / 512 pids, aucun socket Docker, aucun montage Windows.
- **Partage avec OpenCode** : seul le projet **ouvert** (`LOCAL_AI_PROJECT` dans `.env`) est monté dans OpenCode sous `/data/workspace/<id>` ;
  sinon volume vide `local-ai-workspace-none` en lecture seule. `project open` recrée uniquement le conteneur `opencode` (espace réseau isolé conservé).
- Arrêt d'urgence étendu : relais Continue et Dev Containers arrêtés.

## Tests 11.B.1 (« API » = requêtes directes ; « interface » = VS Code réellement manipulé)

| Test | Type | Résultat |
|---|---|---|
| Installation et épinglage des 2 extensions, lecture des réglages réels | CLI | PASS |
| Autocomplétion réelle FIM via le relais (`def add(a, b):` → `return a + b` ; JS `isEven` → `return n % 2 === 0;`), 3,6–3,7 s à froid, 0,2 s à chaud | API | PASS |
| Filtrage du relais : 8 refus (routes, autre modèle, double clé `model`) ; Ollama 11434 et relais via IP LAN injoignables | API | PASS |
| Conflit : autre modèle chargé → 409, aucune substitution ; `continue on` refusé dans ce cas | API/CLI | PASS |
| `continue on`/`off`/`status`, relais arrêté par défaut, `enableTabAutocomplete` false, télémétrie désactivée | CLI | PASS |
| Accès OpenCode : Web 200, API sans authentification 401, OpenCode 2.3.2 | API | PASS |
| Projet témoin : vscode uid 1000, CapEff 0, NoNewPrivs 1, sudo bloqué, pas de socket Docker, seul son workspace visible | Conteneur | PASS |
| Isolation : depuis le Dev Container, Internet, Ollama, OpenCode et l'autre projet injoignables ; OpenCode ne voit que le projet ouvert | Conteneur | PASS |
| Partage et persistance : fichiers écrits des deux côtés, conservés après arrêt/réouverture ; bascule `demo-a` → `demo-b` | Conteneur | PASS (après correctif `nocopy`) |
| Complétion dans l'éditeur VS Code (Continue), ouverture « Reopen in Container », terminal « OpenCode (local-ai) » | Interface | Non effectué en 11.B.1 ; **PASS manuel par l'utilisateur** (Continue/Tab, TUI via profil VS Code, Dev Container demo Ubuntu 24.04.5 non-root), consigné en 12.B.1 |

Ressources de test supprimées (projets `demo-a`, `demo-b` : conteneurs, réseaux, volumes, dossiers, points de montage vides).

## Correctif 11.B.2 — TUI OpenCode et épinglage des extensions

BK1 : `backups/restore-points/11.B.2_20261126_182952`.

- **Cause** : `local-ai.ps1 tui` échouait (`Failed to initialize OpenTUI render library … /tmp/.bun-1000-*.so: Operation not permitted`).
  Bun extrait les bibliothèques natives d'OpenTUI dans `TMPDIR` (défaut `/tmp`), monté en tmpfs `noexec`.
- **Correctif minimal** : tmpfs dédié `/tui-tmp` (64 Mio, `exec,nosuid,nodev`, uid/gid 1000, mode 0700) dans le service `opencode` ;
  `local-ai.ps1 tui` passe `TMPDIR=/tui-tmp` au seul `docker exec` du TUI. `/tmp` reste `noexec,nosuid,nodev` ; le serveur n'a pas de
  `TMPDIR` ; uid 1000, `cap_drop: ALL`, racine en lecture seule, `no-new-privileges` inchangés. Bun respecte `TMPDIR` (vérifié).
- **Extensions** : `Continue.continue@2.0.0` et `ms-vscode-remote.remote-containers@0.481.0` épinglées (`pinned: true`, stables) ; mises à
  jour automatiques désactivées manuellement par l'utilisateur (R21 levée).

| Test 11.B.2 | Type | Résultat |
|---|---|---|
| Échec reproduit avant correctif (`/tmp` noexec) | CLI | PASS (reproduit) |
| `local-ai.ps1 tui` dans un vrai terminal (commande identique au profil VS Code) : écran OpenCode 2.3.2, Assistant, modèle local ; bibliothèque chargée depuis `/tui-tmp` | Terminal | PASS |
| Profil « OpenCode (local-ai) » ouvert depuis VS Code | Interface | PASS manuel par l'utilisateur (consigné en 12.B.1) |
| `/tmp` toujours noexec (exécution refusée), serveur sans `TMPDIR` | Conteneur | PASS |
| Web 200, API sans authentification 401, 4 sessions conservées, aucune route par défaut, Internet injoignable, 11434 non publié | API | PASS |
| Autocomplétion et Tab Continue dans l'éditeur | Interface (utilisateur) | PASS (validé manuellement) |
| `local-ai.ps1 config` | CLI | 16 PASS, 0 FAIL |
