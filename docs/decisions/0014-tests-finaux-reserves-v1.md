# ADR-0014 — Tests finaux et résolution des réserves V1 (14.B.1)

Statut : appliqué le 2026-11-26. Profil B, N1, S2, 7 modèles, 10 agents, affectations **inchangées** (`assignments.initial.yaml` intact),
une inférence et un modèle à la fois. Sauvegarde BK1 : `backups/restore-points/14.B.1_20261126_202128`. Inférence cumulée ≈ 17 min (≤ 20).

## Corrections

### R5/R6/R8 — appels d'outils (diagnostic)

| Modèle | Rendu / analyseur Ollama | Outils (6.B.1) | Cause |
|---|---|---|---|
| qwen3.5:4b, qwen3.5:9b | `RENDERER/PARSER qwen3.5` natifs | 100 | — |
| gpt-oss:20b | gabarit harmony natif | 100 | — |
| qwen3-coder:30b | `RENDERER/PARSER qwen3-coder` natifs | 0 | le **modèle** émet `<function=…>` sans la balise ouvrante `<tool_call>` attendue par l'analyseur |
| qwen2.5-coder:1.5b/7b/14b | gabarit `{{ .Tools }}` + `<tool_call>` | 0 | le **modèle** écrit le JSON de l'appel en texte libre, sans balises |

Aucune configuration (OpenCode ou Ollama) ne corrige un modèle qui ne produit pas le format attendu ; un gabarit modifié
exigerait des modèles dérivés (hors périmètre). **Correction fiable = affectation à un modèle à outils natifs** (proposée
ci-dessous, sur accord). Validation : 9 rôles exécutés avec qwen3.5:4b en sélection de **session** (aucun changement durable).

### R12 — délégation

Délégation complète testée après le correctif de réflexion : le modèle parent a rendu une réponse **vide** sans appeler l'outil,
et les cibles déclarées (architect/developer/documentalist : 20b, 30b, 9b) sont refusées par la garde RAM avec l'usage Windows
actuel. Délégation automatique jugée instable → **transfert manuel imposé** (`delegation_mode: manual` dans S1–S4) :
aucune règle `subagent` (refus), l'agent termine par « Transfert -> <agent> : <consigne> », l'utilisateur lance
`local-ai.ps1 agent handoff <agent> "<consigne>" [--model <tag>]` (nouvelle session, aucune attente imbriquée). Testé : PASS.
Retour possible : `delegation_mode: auto` (variantes `<agent>-delegue` conservées).

### R14/R15/R17 — identifiants, shell, MCP (risques réduits, non éliminés)

- **R14** : clé `shell` d'OpenCode → `/etc/local-ai/agent-shell` (lecture seule) qui retire `OPENCODE_PASSWORD` avant `exec /bin/sh`.
  Vérifié par `POST /api/shell` du serveur : `env` sans mot de passe. **Résidu** : `/proc/1/environ` reste lisible par le même uid
  (refusé par motifs + validation humaine).
- **R15** : 21 refus techniques ajoutés (code en ligne `sh -c`/`bash -c`/`python -c`/`perl -e`/`node -e`, `eval`, `exec`, `base64`,
  `xxd`, `openssl`, `alias`, `source`, `/dev/tcp`, `/tui-tmp`). **Résidu** : une obfuscation inédite retombe sur `ask`.
- **R17** : refus `:8080`, `local-ai-mcp`, `mcp-relay`, `mcp-egress` ; moteur et passerelle (`:11434`, `ollama-engine`,
  `ollama-gate`) refusés aux commandes d'agent. MCP toujours désactivés. **Résidu** : un relais activé reste joignable au niveau réseau.
- Évaluation déterministe (`permissions check`) : 15/15 PASS.

### R20 et R24 — passerelle d'inférence (`config/gate/gate.pl`, service `ollama-gate`)

- **Seul chemin vers Ollama** : Ollama passe sur le réseau interne `local-ai-inference` ; la passerelle porte l'alias `ollama` sur
  `local-ai-core` (URL d'OpenCode et de Continue inchangées). Moteur injoignable depuis OpenCode et les Dev Containers (vérifié).
- **JSON strict** : `config/gate/LocalAiJson.pm` (Perl de base, JSON::PP absent) — clé dupliquée, virgule finale, données en trop,
  profondeur > 64 refusées ; nombres conservés à l'identique ; 21/21 tests unitaires. Utilisé aussi par le relais Continue
  (modèle et `keep_alive` réécrit par réencodage, plus d'expressions régulières).
- **Routes** : lecture + inférence uniquement ; `pull`, `push`, `create`, `copy`, `delete`, `blobs` → 403. Modèles limités au registre.
- **Exclusion mutuelle réelle** : verrou unique pour toute inférence ; OpenCode attend son tour, Continue reçoit 409
  (testé : 409 pendant une génération OpenCode du même modèle, 200 ensuite).
- **RAM avant** : un modèle non chargé n'est admis que si la VM peut le contenir et si la RAM Windows **projetée** reste ≥ 4 Gio
  (croissance = min(RAM libre VM, 2 × taille − modèle déchargé), poids + cache de pages ; mesuré : 14B → −12,7 Gio côté Windows).
  Mesure Windows publiée toutes les 2 s par la **sentinelle** hôte (`scripts/monitor/sentinel.ps1`, démarrée par `start`).
  Sans mesure fraîche : seuls les modèles ≤ 8 Gio sont admis (seuils non garantis → **30B, 20B, 14B bloqués**).
  Réévaluation 20 s puis refus **non réessayable** (400) : un 503 était réessayé indéfiniment par OpenCode (session muette).
- **RAM pendant** : contrôle chaque seconde ; Windows < 4 Gio ou VM < 0,5 Gio pendant 3 s → requête abandonnée, modèle déchargé.
- **Arrêt d'urgence** : `runtime/state/emergency.json` → toute inférence refusée (testé : 400).
- Couvre Web, TUI, agents et Continue (tous passent par la passerelle).

## Tests

Projet témoin `t14-pyapp` (Python, bibliothèque standard : inventaire avec 2 défauts volontaires), Dev Container et partage OpenCode.
Aucun interpréteur Python n'existe dans les images OpenCode, Dev Container ou Ollama (R30) : les agents écrivent, les tests sont
exécutés hors agents (Python hôte isolé `-I`, après relecture du code) → **4/4 tests OK**, `restock` conforme.

| Agent | Affectation actuelle | Résultat sur l'affectation | Test avec qwen3.5:4b (session) |
|---|---|---|---|
| assistant | qwen3.5:4b | **PASS** lecture (outil `read`, défaut repéré, 155 s à froid) | — |
| architect | gpt-oss:20b | **BLOQUÉ** par la garde RAM (refus explicite en 22 s, aucune inférence) | NON TESTÉ (budget) |
| developer | qwen3-coder:30b | bloqué RAM + outils 0 (6.B.1) | **PASS** édition (`restock`, 118 s) |
| debugger | qwen2.5-coder:14b | outils 0 (6.B.1) | **PASS** correction (`>` → `<`, 153 s) |
| qa | qwen2.5-coder:7b | outils 0 (6.B.1) | **PASS** test ajouté (résumé coupé par le délai) |
| devops | qwen3-coder:30b | bloqué RAM + outils 0 | **PASS** Makefile (91 s) |
| reviewer | gpt-oss:20b | bloqué RAM | **PASS** relecture (69 s) |
| security | gpt-oss:20b | bloqué RAM | **FAIL qualité** (menace SQL inventée, délai) |
| documentalist | qwen3.5:9b | admissible si RAM Windows ≥ ~14 Gio ; NON TESTÉ | **PASS** README (résumé coupé) |
| délégation (R12) | — | **INSTABLE** (réponse vide) → transfert manuel | `agent handoff` **PASS** |
| autocomplete (Continue) | qwen2.5-coder:1.5b | **PASS** FIM via passerelle (`return a + b`) ; Tab/VS Code validés manuellement (11.B.1) | — |

Non-régressions : passerelle 15/15, relais Continue 7/7, JSON 21/21, permissions 15/15, arrêt d'urgence (relais, Dev Containers,
OpenCode, blocage de la passerelle) PASS, isolation (sortie Internet bloquée pour OpenCode, passerelle, Ollama, Dev Container ;
moteur injoignable) PASS, persistance (projet après arrêt/réouverture, 5 sessions utilisateur) PASS, `config` 18 PASS / 0 FAIL.
Interface VS Code / Dev Containers : validations manuelles 11.B.1 réutilisées (non refaites).

## Affectations recommandées (NON appliquées — accord requis)

| Agent | Actuelle | Recommandée | Justification |
|---|---|---|---|
| assistant | qwen3.5:4b | **inchangée** | PASS, meilleur score global 6.B.1 (79,8) |
| architect | gpt-oss:20b | qwen3.5:4b (gpt-oss:20b en sélection de session si la RAM l'admet) | 20b bloqué par la garde RAM avec ~14 Gio d'usage Windows |
| developer | qwen3-coder:30b | **qwen3.5:4b** | outils 0 + 30B bloqué ; 4b : code 83, outils 100, PASS |
| devops | qwen3-coder:30b | **qwen3.5:4b** | idem, PASS |
| debugger | qwen2.5-coder:14b | **qwen3.5:4b** | outils 0 ; PASS |
| qa | qwen2.5-coder:7b | **qwen3.5:4b** | outils 0 ; PASS |
| reviewer | gpt-oss:20b | qwen3.5:4b (gpt-oss:20b en session si RAM) | PASS ; 20b bloqué en usage courant |
| security | gpt-oss:20b | **inchangée** (gpt-oss:20b, raisonnement 98) avec RAM libérée ; sinon qwen3.5:9b (non testé) | 4b insuffisant en sécurité (FAIL qualité) |
| documentalist | qwen3.5:9b | qwen3.5:4b (ou 9b conservé) | 9b correct mais 2,7× plus lent et souvent non admis |
| autocomplete | qwen2.5-coder:1.5b | **inchangée** | PASS |

Application sur accord : `.\local-ai.ps1 agent model <agent> qwen3.5:4b-q4_K_M` (BK1 + rollback ; `agent reset` pour revenir).

## Aptitude réelle de la V1

Apte pour un usage **local, séquentiel et supervisé** : lecture/explication, édition, correction, écriture de tests, fichiers DevOps,
relecture et documentation avec qwen3.5:4b (≈ 1 à 2,5 min par tâche courte à froid), autocomplétion Continue, isolation N1 et
garde-fous effectifs. **Non apte en l'état** avec les affectations actuelles (7 agents OpenCode sur 9 inopérants : architect, reviewer, security bloqués par la RAM ; developer, devops, debugger, qa sans appels d'outils) → R5 bloquante
jusqu'à l'accord sur les affectations. Les modèles ≥ 14B ne sont utilisables que si la RAM Windows libre le permet (fermer des
applications) ; délégation manuelle uniquement ; exécution des tests hors agents (R30).

## 14.B.2 — Finalisation V1 : repli local contrôlé et Python/Git isolés

BK1 : `backups/restore-points/14.B.2_20261126_213641`. Les 10 affectations initiales et les 7 modèles sont **conservés**
(`agents/definitions`, `assignments.initial.yaml` inchangés ; les recommandations ci-dessus restent non appliquées).

### Repli local contrôlé (`config/agents/fallback.yaml` -> `config/gate/fallback.json`)

| Agent | Initial | Chaîne de repli | Mode |
|---|---|---|---|
| architect, reviewer | gpt-oss:20b | qwen3.5:9b -> qwen3.5:4b | auto |
| developer, devops | qwen3-coder:30b | qwen3.5:9b -> qwen3.5:4b | auto |
| debugger | qwen2.5-coder:14b | qwen3.5:9b -> qwen3.5:4b | auto |
| qa | qwen2.5-coder:7b | qwen3.5:4b | auto |
| documentalist | qwen3.5:9b | qwen3.5:4b | auto |
| security | gpt-oss:20b | qwen3.5:9b **uniquement** | ask (confirmation) |
| assistant, autocomplete | inchangés | — | off |

- **Déclencheurs** : RAM insuffisante (admission **à blanc** de la passerelle, `POST /local-ai/admission`, aucune inférence) ou
  incompatibilité d'outils avérée (`tools_incompatible` : qwen2.5-coder:*, qwen3-coder:30b — diagnostic 14.B.1).
- **Avant exécution** (`local-ai.ps1 agent handoff <agent> "<consigne>"`) : modèle initial s'il est admis et compatible, sinon
  premier de la chaîne qui l'est ; `auto` appliqué au **modèle de la session** de cette tâche ; `ask` proposé, appliqué avec
  `--accept-fallback` ; `off` sans repli. Aucun modèle admissible -> tâche non lancée (la garde n'est jamais contournée).
- **Après démarrage** (`--watch <s>`) : échec (garde RAM, outils) -> repli **proposé**, jamais rejoué.
- **Vérification** : modèle **affiché** (modèle de la session, montré par le Web/TUI) contrôlé avant l'envoi de la consigne ;
  modèle **réellement utilisé** lu dans les messages (`model.id`) et dans le journal de la passerelle (`{agent}`).
- **Journal** : `runtime/logs/fallback.jsonl` + audit (`agent.fallback`) : agent, modes, modèles, motif, seuils simulés, résultat, session.
- **Retour au modèle initial** : automatique à la tâche suivante (le repli ne vit que dans la session).
- `local-ai.ps1 fallback list | check <agent|all> | mode <agent> auto|ask|off` (BK1 + régénération, effet immédiat).
- **Limite (OpenCode 2.3.2)** : une session ouverte **directement** dans le Web ou le TUI envoie sa requête sans point
  d'interception ; la passerelle ne substitue **jamais** un modèle en silence (le modèle affiché resterait faux). Repli **manuel
  assisté** : refus explicite (outils incompatibles ou RAM) avec la proposition propre à l'agent (marqueur `[local-ai agent=<id>]`
  ajouté aux prompts système), à appliquer par le sélecteur de modèle de la session ou par `agent handoff` (R33).
- Seuils simulés pour les tests : `local-ai.ps1 monitor simulate <Gio>|off` — **pessimistes uniquement** (bornés par la mesure réelle).

### R30 — Python et Git isolés

Arbitrage R3 : **aucune construction d'image** (cache BuildKit non sollicité). Volume `local-ai-tools` (lecture seule) peuplé une fois
depuis l'image OpenCode épinglée (Alpine 3.24, clés apk de l'image) : `python3=3.14.10-r2`, `git=2.54.1-r0`, 34 paquets inventoriés
avec sommes (`config/tools/lock.txt`). Enveloppes `bin/python3`, `bin/git` (chargeur musl du volume : utilisables dans OpenCode et
les Dev Containers Ubuntu ; Git sans configuration système, sans pager, maintenance automatique désactivée). Montage en lecture
seule dans OpenCode (PATH du shell des agents) et dans le modèle de Dev Container (nouveaux projets ; `demo` non modifié).
Permissions **inchangées** (`python3 -m unittest` = ask, `python3 -c` = refus, `git status` = autorisé, `git push` = refus).
`local-ai.ps1 tools status | verify | install --confirm`.

### Tests 14.B.2

| Test | Résultat |
|---|---|
| `fallback check all` en RAM réelle (22 Gio libres) : 20B -> 9B (RAM), 30B/14B -> 9B (outils), 7B -> 4B, security -> 9B sur confirmation | PASS (sans inférence) |
| Seuils simulés 40 / 12 / 5 Gio : initial conservé / 4B (security : aucun) / aucun modèle (rien de forcé) | PASS |
| Simulation optimiste bornée (40 demandé -> 22,8 publié) | PASS |
| `ask` : security -> proposition, aucune session sans `--accept-fallback` | PASS |
| `auto` réel : reviewer 20B -> 4B ; affiché = utilisé = 4B (session, messages, passerelle `{reviewer}`), 95 s | PASS |
| Après démarrage : RAM simulée 2 Gio pendant l'inférence -> abandon en 2 s, modèle déchargé, repli proposé sans rejeu | PASS (abandon R31 déclenché réellement) |
| Web/TUI direct (developer sur 30B) : refus explicite + « REPLI PROPOSÉ … developer -> qwen3.5:9b », modèle affiché réel | PASS |
| `fallback mode qa off` puis `auto` (BK1, effet immédiat) | PASS |
| Python 3.14.10 / Git 2.54.1 : OpenCode (shell des agents, sans mot de passe) et image Dev Container, lecture seule, sans réseau | PASS |
| Non-régression : passerelle 15/15, JSON 21/21, Continue 7/7, permissions 8/8, arrêt d'urgence, `config` 18/0 | PASS |

### Aptitude V1 après 14.B.2

**Apte** pour un usage local séquentiel supervisé avec les affectations initiales : les 9 agents OpenCode deviennent opérationnels
par repli contrôlé (9B ou 4B selon la RAM, security sur confirmation) via `agent handoff`, et par repli manuel assisté dans le
Web/TUI ; tests exécutables par les agents (Python/Git isolés, validation humaine). R5 devient acceptable (affectations conservées par choix).
