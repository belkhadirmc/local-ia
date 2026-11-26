# ADR-0008 — OpenCode Desktop et sélection manuelle des modèles (8.B.1)

Statut : appliqué le 2026-11-26. Affectations des agents **inchangées** (restaurées après tests).

## OpenCode Desktop — BLOQUÉ (incompatible avec les politiques)

- **Source et intégrité** : `opencode-desktop-win-x64.exe` v2.3.2 (même version que le serveur Docker), release GitHub
  `anomalyco/opencode` ; 269 731 480 octets ; sha256 `1e73b4f49f591971f4ad61c5a39b284bf74d41f50ca1b84e68ccf2ab2be91e8d`
  = digest GitHub = `SHA256SUMS` ; signature Authenticode **valide** « Anomaly Innovations, Inc » (Microsoft ID Verified CS) ;
  installateur NSIS, installation utilisateur silencieuse (`/S`) dans `%LOCALAPPDATA%\Programs\ai.opencode.desktop` (« OpenCode 2.3.2 »).
- **Constat** (lancement observé à 13:12, avant l'installation silencieuse de 13:16 qui a réinstallé la même version) :
  au démarrage, Desktop **télécharge sa propre CLI** (`%APPDATA%\ai.opencode.desktop\cli\2.4.2-x64\opencode-cli.exe`, version
  ≠ 2.3.2) et lance un **serveur autonome sur l'hôte Windows** (`opencode-cli serve --service`, 127.0.0.1:28894), avec connexion
  sortante HTTPS vers Internet (104.18.11.66:443) et surveillance de `C:\`, `C:\Users\<utilisateur>`, `Documents` ; mot de passe
  et base dans le profil Windows (`~\.config\opencode\service.json`, `~\.local\share\opencode`).
  Aucun réglage documenté pour désactiver ce serveur local, les mises à jour de Desktop ou sa CLI embarquée.
- **Décision** : Desktop **non connecté** au serveur `http://127.0.0.1:4096` ; service local arrêté (`service stop`), aucun processus
  restant, aucun démarrage automatique. Application laissée installée mais fermée ; désinstallation recommandée
  (`%LOCALAPPDATA%\Programs\ai.opencode.desktop\Uninstall OpenCode.exe`) ; données du profil Windows non supprimées (non créées par local-ai).
  Accès conservés : **Web** (`http://127.0.0.1:4096`) et **TUI** (`.\local-ai.ps1 tui`). Réserve R9.

## Sélection des modèles

- **Temporaire** (session) : `POST /api/session/{id}/model` — API du serveur utilisée par le Web et le TUI. Les 7 modèles du
  registre sont sélectionnables (vérifiés un par un). Un modèle hors registre ou d'un fournisseur cloud est **accepté par la
  session** mais refusé à l'exécution (« Model unavailable », politique `provider.use`) : aucune requête n'est émise.
- **Permanente** : `local-ai.ps1 agent list | agent model <agent> [<modèle>] | agent reset <agent|all>`.
  - Modèle validé contre `models/registry.yaml` (id ou tag ; aucun téléchargement) ; agent validé contre `agents/definitions/`.
  - Avertissements sans substitution automatique : outils (score tools 6.B.1 = 0 ; agent à outils edit/bash/test), RAM (pic à 8192 ≥ 50 % / ≥ 80 %).
  - Séquence : point de restauration **BK1** (`backups/restore-points/agent_<agent>_<horodatage>/`, définition + `opencode.json`,
    `SHA256SUMS.txt`, `manifest.yaml`, aucun secret) → modification de `model.ref` → régénération `opencode.json` → redémarrage
    d'OpenCode (espace réseau isolé conservé) → vérification de l'agent via l'API ; en cas d'échec, **rollback** (contrôle sha256) et régénération.
  - Référence de restauration : `agents/assignments.initial.yaml` (affectations initiales figées). Continue : définition modifiable,
    hors OpenCode (intégration différée à l'étape 11).
- **Délais fournisseur** : `headerTimeout` 1 500 000 ms, `chunkTimeout` 600 000 ms, `timeout: false` — une requête Web antérieure
  avait été coupée à 120 s (HTTP 500 côté Ollama) alors que le traitement du prompt sur CPU dépasse 2 min pour les gros modèles (6.B.1).

## Tests 8.B.1 (courts)

| Test | Résultat |
|---|---|
| Desktop : source, sha256, signature | PASS |
| Desktop : connexion au serveur local sans serveur autonome | **BLOQUÉ** (serveur hôte imposé, CLI 2.4.2 téléchargée) |
| Sélection temporaire des 7 modèles (API Web/TUI) ; modèles cloud/hors registre refusés à l'exécution | PASS |
| `agent list`, `agent model <agent>`, refus modèle hors registre et agent inconnu | PASS |
| Changement permanent `qa` → `qwen3.5:4b-q4_K_M` (définition, `opencode.json`, API) | PASS |
| Persistance après `stop`/`start opencode` | PASS |
| Échec simulé (`LOCAL_AI_TEST_FAIL_RELOAD=1`) → rollback | PASS |
| `agent reset qa` puis `agent reset all` (idempotent, 10/10 initiales) | PASS |
| Isolation conservée (aucune route par défaut, sortie bloquée) | PASS |
