# OpenCode (7.B.1)

- `opencode.json` : configuration **système** (montée en lecture seule sur `/etc/opencode/opencode.json`), **générée** — ne pas éditer :
  `powershell -File config/opencode/generate-config.ps1` (`-Check` : vérifie qu'elle est à jour ; utilisé par `local-ai.ps1 config`).
- `opencode.env` : variables non sensibles du conteneur (mises à jour, catalogue models.dev, modèles gratuits, import Claude Code désactivés).
- Secret : `secrets/opencode.env` (`OPENCODE_PASSWORD`, non versionné). Accès : http://127.0.0.1:4096 (utilisateur `opencode`) ou `.\local-ai.ps1 tui`.
- Fournisseur : Ollama interne `http://ollama:11434/v1`, contexte 8192 maximum. Détails : `docs/decisions/0007-opencode-mcp.md`.
