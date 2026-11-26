# Tests

- `integration/compose-activation.yaml` : validation de structure (`config -q --no-interpolate`).
- `gate/` : passerelle, JSON strict, Continue, arrêt d'urgence ; `agents/` : agents par l'API ; `backup/` : sauvegarde/restauration.
- Sécurité : contrôles intégrés aux tests ci-dessus et à `config` (isolation, sortie Internet, permissions) ; `unit/` réservé.
- Validation globale : `.\local-ai.ps1 config`.

## 14.B.1

- `gate/json.t.pl` : analyseur JSON strict (Perl, image Ollama, sans réseau).
- `gate/gate-checks.sh` : passerelle sans inférence (exécuté dans l'espace réseau OpenCode).
- `gate/continue-checks.mjs` : relais Continue + exclusion mutuelle (≈ 15 s d'inférence 1.5b).
- `gate/emergency-probe.pl` : refus d'inférence sous arrêt d'urgence.
- `agents/run-agent.mjs` : test pratique d'un agent par l'API (modèle de session, permissions journalisées).

## 15.B.1

- `backup/run-backup-tests.ps1` : sauvegarde/restauration sur cibles témoins (20 contrôles) ; `backup/check_sessions.py` : intégrité SQLite des sessions restaurées.
