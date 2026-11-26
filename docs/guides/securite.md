# Sécurité

Modèle : **local, isolé, supervisé**. Garanties vérifiées par tests (ADR-0007, 0010, 0013, 0014) et **limites assumées** (réserves).

## Isolation réseau (N1)

- OpenCode : espace réseau sans route par défaut (garde de sortie `NET_ADMIN` éphémère, R1) ; sortie Internet vérifiée bloquée à
  chaque démarrage ; publication **127.0.0.1:4096** uniquement ; API protégée par mot de passe (page Web statique servie sans, R8).
- Ollama : réseau interne `local-ai-inference` seul, aucun port publié ; joint **uniquement** par la passerelle d'inférence.
- Continue : relais 127.0.0.1:11435, même montage sans route ; modèle unique.
- Dev Containers : réseau interne par projet ; ni Internet, ni moteur, ni OpenCode, ni autre projet.
- MCP (N4, désactivés) : relais isolés, sortie filtrée par destination, lecture seule (R7, R16, R17).

## Conteneurs

uid 1000 (sauf gardes éphémères), `cap_drop: ALL`, `no-new-privileges`, racine en lecture seule, `/tmp` noexec (TUI : tmpfs
exécutable dédié `/tui-tmp`, R22), limites mémoire/pids, aucun socket Docker, aucun montage du disque Windows, images épinglées par
digest (`config` refuse `latest` et les digests invalides).

## Passerelle d'inférence (`config/gate/gate.pl`)

JSON strict (clé dupliquée refusée), modèles du registre seulement, routes d'administration (`pull`, `delete`, `create`…) refusées,
une inférence à la fois, garde RAM avant et pendant l'inférence (30B/20B/14B refusés si la RAM Windows ne peut être garantie),
refus des modèles sans appels d'outils exploitables pour les agents à outils, arrêt d'urgence, aucun modèle substitué en silence.

## Agents (S2)

Permissions générées (base `deny`, `ask` pour édition/shell, refus techniques prioritaires, anti-chaînage), shell des agents sans
`OPENCODE_PASSWORD` (`/etc/local-ai/agent-shell`), délégation automatique désactivée, accès limité au projet ouvert.

## Secrets

`secrets/` (ACL restreinte, R4) : jamais versionné, jamais sauvegardé en clair, jamais lisible par les agents. Contrôle de
confidentialité avant chaque push (motifs d'identifiants, adresse, chemins personnels, mot de passe local).

## Limites (non éliminées)

| Réserve | Risque résiduel |
|---|---|
| R14 | `/proc/1/environ` lisible par le même uid : une commande approuvée pourrait y lire le mot de passe (motifs refusés + validation) |
| R15 | une obfuscation inédite d'une commande retombe sur `ask`, pas sur un refus : lire chaque commande avant d'approuver |
| R17 | un relais MCP activé est joignable depuis l'espace réseau d'OpenCode (jeton jamais exposé, portée minimale) |
| R22 | code exécutable possible dans `/tui-tmp` (uid 1000) |
| R31 | garde RAM fondée sur une projection prudente (facteur 2) |

En cas de doute : `.\local-ai.ps1 emergency-stop` (rien n'est supprimé), puis analyse de `runtime/logs/audit.jsonl`.
