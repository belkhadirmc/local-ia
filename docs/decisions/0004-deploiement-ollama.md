# ADR-0004 — Déploiement d'Ollama (4.B.1)

Statut : appliqué le 2026-11-25.

- **Image** : `ollama/ollama:0.40.18`, manifeste linux/amd64 `sha256:4e0d5daa6c5cd91e27011977031466844c5ea4ba2393b35e78068835edec040b`
  (index multi-plateforme `sha256:1cabd20e…13ec`), vérifié sur Docker Hub avant téléchargement. Taille locale ≈ 5,09 Go (bibliothèques GPU incluses, non utilisées).
- **Profil** : B + N1 + S2 ; CPU uniquement (`OLLAMA_VULKAN=0`, `NVIDIA_VISIBLE_DEVICES=void`, aucun périphérique).
- **Sécurité** : UID/GID 1000, `cap_drop: ALL`, Seccomp par défaut (mode filtre), `no-new-privileges`, racine en lecture seule,
  `/tmp` en tmpfs, aucun socket Docker, aucun GPU, aucun montage Windows. Seule exception : `ollama-init` (root, `network_mode: none`,
  `CAP_CHOWN` seul) pour attribuer `/models` à 1000:1000.
- **Réseau** : `local-ai-core` interne uniquement ; aucun port publié ; pas de route par défaut ; sortie vers 192.0.2.1 bloquée.
- **Exploitation** : `restart: "no"` ; logs `local` 10m/5/compress ; healthcheck `ollama list` ; `local-ai.ps1 start|stop`
  (validation préalable, `--pull never`, aucune suppression).
- **Données** : volume externe `local-ai-ollama` (labels `local-ai.volume=critical`, `local-ai.module=ollama`), vide (aucun modèle).- **Validation 4.B.2** : `local-ai.ps1 stop` puis `start` (même conteneur, healthy), recréation forcée du conteneur avec
  persistance d'un fichier témoin dans `local-ai-ollama` (témoin supprimé ensuite) ; protections et profil B+N1+S2 inchangés ;
  aucun modèle. Le volume contient uniquement les répertoires vides créés par Ollama (`blobs`, `manifests`, `manifests-v2`).

## Dépôt Git

- Identité du dépôt : adresse noreply GitHub (`git config --local user.email`), configuration globale inchangée.
- Historique 3.B.1 à 4.B.1 réécrit en 4.B.2 (adresses auteur/committer uniquement ; arbres, messages et dates identiques).
  Sauvegarde de l'historique d'origine : `backups/config/git_history_4.B.2_*.bundle` (+ `.sha256`), non versionnée.
- Remote : `origin` = `https://github.com/belkhadirmc/local-ia.git` (branche `main` uniquement).
