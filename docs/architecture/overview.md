# Architecture local-ai

- **Hôte** : Windows 11 Pro, Ryzen 7 5700U (16 threads), 40 Go RAM ; Docker Desktop 4.99 (CLI), Engine 29.9.3, Compose 5.7.0, WSL2.
- **Compose** : `compose.yaml` inclut le socle `compose/services/core.yaml` ; modules Ollama, OpenCode, MCP et projet
  dans `compose/templates/` (inactifs, double garde : `profiles` + image obligatoire) ; surcharges explicites dans `compose/overrides/`.
- **Réseaux** : `local-ai-core` et `local-ai-project-*` internes ; `local-ai-egress` (N2), `local-ai-cloud` (N3, réservé hors V1 — ADR-0013),
  `local-ai-mcp` (N4) sur autorisation ; `local-ai-localhost` pour publication 127.0.0.1 uniquement.
  Toutes ces surcharges sont **désactivées par défaut** (appliquées uniquement via `-f` explicite).
  La liaison 127.0.0.1 limite l'exposition entrante mais **ne garantit pas** le blocage d'Internet sortant.
- **Volumes critiques externes** : `local-ai-ollama`, `local-ai-opencode`, `local-ai-workspace-<id>` ; caches `local-ai-cache-<id>`.
- **Agents** : 9 agents OpenCode + autocomplétion Continue, définitions indépendantes, un seul modèle chargé à la fois.
