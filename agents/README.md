# Agents

- `definitions/*.yaml` : 10 définitions indépendantes d'OpenCode (rôle, modèle `model.ref` → `models/registry.yaml`, permissions S2, outils, délégations).
- `prompts/*.md` : mission, expertise, méthode, limites, qualité, livrables, collaboration ; `prompts/_common.md` (règles S2 communes) est ajouté à chaque agent OpenCode.
- `tools/catalog.yaml` : catalogue des outils et de leur niveau de risque.
- `assignments.initial.yaml` : affectations initiales (référence de `local-ai.ps1 agent reset`).

Génération OpenCode : `config/opencode/generate-config.ps1` → 9 agents sélectionnables (Assistant par défaut), plus une variante cachée
`<agent>-delegue` par cible de délégation (même modèle, mêmes permissions, **aucune délégation** : profondeur 1 imposée).
L'autocomplétion (Continue) reste hors OpenCode (étape 11). Détails : `docs/decisions/0009-finalisation-agents.md`.
