# Ollama

Déployé en 4.B.1 : `ollama/ollama:0.40.18@sha256:4e0d5daa…040b` (linux/amd64), CPU uniquement.

- Réseau : `local-ai-core` (interne) ; aucun port publié. Exposition 127.0.0.1 possible via `compose/overrides/ollama-localhost.yaml` (désactivée, voir ADR-0003 R1).
- Volume : `local-ai-ollama` (externe) monté sur `/models` ; propriétaire 1000:1000 via `ollama-init` (root, sans réseau, CAP_CHOWN seul).
- Variables : `ollama.env` (HOST, NO_CLOUD=1, NUM_PARALLEL=1, MAX_LOADED_MODELS=1, CONTEXT_LENGTH=8192, KEEP_ALIVE=5m, MODELS=/models, VULKAN=0).
- `HOME=/tmp` (tmpfs) : la clé d'identité Ollama est régénérée à chaque démarrage (aucun usage cloud).
- Démarrage / arrêt : `.\local-ai.ps1 start` / `.\local-ai.ps1 stop`.
