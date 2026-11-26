# Extensions

Le socle est modulaire : modules Compose dans `compose/templates/` (profils + image épinglée obligatoire), surcharges réseau
explicites dans `compose/overrides/`, configuration OpenCode **générée** (`config/opencode/generate-config.ps1`), politiques
OpenCode (`policies`, `permissions`), passerelle d'inférence, profils `profiles/`. Toute extension passe par un ADR, une sauvegarde
BK1/BK2 et des tests de non-régression ; aucune ne doit contourner N1/S2, la garde RAM ou le contrôle de confidentialité.

| Extension | État v1.0.0 | Procédure |
|---|---|---|
| **MCP** GitHub, GitLab, Jira, Confluence | préparés, désactivés (N4 implémenté, témoin local testé) | jeton lecture seule dans `secrets/mcp-<id>.env`, `mcp enable <id> --authorize-n4` (ADR-0010, R7) |
| **IA cloud** | hors V1 (N3 réservé) | 7 étapes d'ADR-0013 : relais dédié sur le modèle N4, option du générateur désactivée par défaut, aucun repli automatique |
| **Nouveau modèle local** | — | téléchargement en fenêtre N2 sur décision, `models/registry.yaml`, `GATE_MODELS` (contrôlé par `config`), test des appels d'outils (mise à jour de `tools_incompatible`, R34), microtest (`models/benchmarks/microtest.ps1`) |
| **Nouvel agent** | — | `agents/definitions/<id>.yaml` + prompt, politique dans `config/agents/fallback.yaml`, régénération, `permissions check` |
| **Outils supplémentaires** (pip, compilateurs) | Python/Git seuls | nouvel épinglage dans `scripts/tools/install-tools.sh`, `tools install --confirm`, `lock.txt` ; ou image de projet enrichie après arbitrage R3 |
| **GPU Vega 8 (Vulkan)** | inapplicable (R26) | exigerait l'ICD Mesa « dzn » et le montage `/dev/dxg` |
| **OpenCode Desktop** | non utilisé (R9) | réévaluer si un mode « serveur distant uniquement » apparaît |
| **Repli automatique Web/TUI** | manuel assisté (R33) | possible si OpenCode expose un crochet pré-requête |
