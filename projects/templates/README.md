# Modèles de projet (11.B.1)

`devcontainer/` : modèle Dev Containers (`devcontainer.json` + `compose.yaml`) instancié par `.\local-ai.ps1 project create <id>`
dans `projects/<id>/.devcontainer/` (non versionné).

Chaque projet `<id>` :

- workspace persistant dédié : volume externe `local-ai-workspace-<id>` (jamais le disque Windows) ;
- cache séparé : volume `local-ai-cache-<id>` (recréable) ;
- réseau interne `local-ai-project-<id>` : ni Internet, ni autre projet, ni Ollama ;
- conteneur `dev` : image officielle `mcr.microsoft.com/devcontainers/base:3.0.14-noble` épinglée par digest, utilisateur `vscode` (1000),
  `cap_drop: ALL`, `no-new-privileges`, aucun socket Docker.

Partage avec OpenCode : seul le projet **ouvert** (`project open <id>`, variable `LOCAL_AI_PROJECT` de `.env`) est monté dans OpenCode,
sous `/data/workspace/<id>`. Les autres projets ne sont jamais montés. Voir `docs/guides/projects.md`.
