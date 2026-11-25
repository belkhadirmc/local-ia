# ADR-0005 — Téléchargement et validation des modèles (5.B.1)

Statut : appliqué le 2026-11-25.

- **Vérification préalable** : 7 manifestes officiels lus sur `registry.ollama.ai` (digest = sha256 du manifeste, tailles des couches) ;
  total 52,98 Gio ≤ budget 58 Gio ; SSD libre prévu après téléchargement ≥ réserve 30 Gio. Aucun remplacement de tag.
- **Fenêtre N2** : Ollama permanent arrêté ; conteneur temporaire (même image épinglée, uid 1000, `cap_drop ALL`, Seccomp,
  `no-new-privileges`, racine en lecture seule, CPU, `OLLAMA_NO_CLOUD=1`, aucun port, seul le volume `local-ai-ollama`) sur un réseau
  temporaire dédié non interne ; téléchargements séquentiels avec contrôle d'espace avant chaque modèle ; conteneur et réseau
  temporaires supprimés ; Ollama permanent redémarré en N1 (`local-ai-core`).
- **Intégrité** : digest du manifeste officiel = sha256 de l'entrée `manifests-v2` (7/7) ; blobs nommés par leur sha256 et tailles
  conformes, sauf le blob de configuration de `qwen3-coder:30b` (539 o déclarés, 542 o réels, contenu conforme à son digest).
- **Tests hors ligne (N1)** : contexte 2048, `num_predict` 64, température 0, `keep_alive 0`, délai borné, surveillance RAM/swap
  (interruption à 95 % ou swap > 2 Gio) — 7/7 PASS ; RAM WSL2 maximale 18,53 Gio (78,9 %) ; swap 0,01 Gio ; aucun modèle chargé ensuite.
- **Administration** : `local-ai.ps1 model list|show` (lecture seule) ; `pull`/`rm` non implémentés.
- Détails par modèle : `models/registry.yaml`.