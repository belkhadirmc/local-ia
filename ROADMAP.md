# Feuille de route

Aucune de ces évolutions n'est engagée : chacune exige une décision, un ADR, une sauvegarde et des tests (voir `docs/guides/extensions.md`).

## v1.x (maintenance)
- Confirmer ou ajuster les affectations des agents (recommandations ADR-0014, R5) après usage réel.
- Tester une restauration `--production` sur un poste de test et BK3 vers un disque externe (R36).
- Ajuster `GATE_GROWTH_FACTOR` de la garde RAM à partir des mesures réelles (R31).
- Suivre les versions d'OpenCode (crochet pré-requête pour un repli automatique Web/TUI — R33 ; `subagent_depth` — R11 ;
  réduction du prompt système — R27) et d'Ollama (extraction des appels d'outils qwen-coder — R34).
- Réépingler squid (R16) et les outils Alpine (R35) lors des mises à jour.

## v2 (évolutions possibles)
- MCP réels en lecture seule (GitHub/GitLab/Jira/Confluence) sur jetons utilisateur (R7).
- IA cloud optionnelle par relais dédié N3, jamais par défaut (ADR-0013, R29).
- Accélération GPU si un pilote Vulkan/D3D12 exploitable devient disponible sans compromis (R26).
- Image de projet enrichie (outils de compilation) après arbitrage R3.
- Barrettes RAM identiques pour le dual channel complet (matériel, R23).
