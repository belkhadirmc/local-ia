# Tests

- `integration/compose-activation.yaml` : validation de structure (`config -q --no-interpolate`).
- `unit/`, `security/` : à venir.
- Validation globale : `.\local-ai.ps1 config`.

## 14.B.1

- `gate/json.t.pl` : analyseur JSON strict (Perl, image Ollama, sans réseau).
- `gate/gate-checks.sh` : passerelle sans inférence (exécuté dans l'espace réseau OpenCode).
- `gate/continue-checks.mjs` : relais Continue + exclusion mutuelle (≈ 15 s d'inférence 1.5b).
- `gate/emergency-probe.pl` : refus d'inférence sous arrêt d'urgence.
- `agents/run-agent.mjs` : test pratique d'un agent par l'API (modèle de session, permissions journalisées).
