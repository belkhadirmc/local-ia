# ADR-0006 — Benchmarks des modèles (6.B.1)

Statut : appliqué le 2026-11-26. Affectations des agents **non modifiées**.

- **Suite reproductible** : `models/benchmarks/` — `suite.yaml` (paramètres, seuils, pondérations, rôles), `cases/*.json`
  (12 exercices, critères figés avant exécution, identiques pour les 7 modèles), `run-benchmarks.ps1` (autonome, API Ollama interne
  N1 via le conteneur, aucun port publié), `make-report.ps1` → `report.md`, `summary.csv`, `summary.json`. Bruts : `results/` (hors Git).
- **Validation** : exécutée pour code_gen, debug, qa (mutants), fim — Bash dans un bac à sable Docker éphémère (image Ollama épinglée
  existante, `--network none`, lecture seule, `cap_drop ALL`, `no-new-privileges`, uid 1000, 256 Mio, 64 pids, 1 CPU, 20 s) ; aucun code
  généré exécuté sur Windows. Statique pour devops (`docker compose config`), review, security, architecture, multifichier,
  instructions, documentation. Simulée pour tools (appels vérifiés, rien exécuté).
- **Performances** : profil B+N1+S2, CPU ; vitesse (1 froid + 3 chauds, médianes) ; contexte long 4096 puis 8192 (prompts réels de
  ≈ 3 000–3 400 et 6 400–7 400 tokens, aiguille) ; 8192 seulement si 4096 < 85 % RAM WSL2. Surveillance chaque seconde (RAM WSL2 hors
  cache, conteneur, RAM Windows disponible, CPU, swap) ; interruption sécurisée et déchargement aux seuils 95 % / swap > 2 Gio /
  Windows < 4 Gio ; SSD < 30 Gio bloquant.
- **Exécutions** : `20261125_212627` (4 modèles complets ; 3 interrompus après une mise en veille de Windows puis par le seuil RAM
  Windows) et `20261126_100232` (3 modèles relancés intégralement, notation fusionnée). Mise en veille désormais bloquée par le script
  (propre au processus).
- **Résultats** : 7/7 contextes 4096 et 8192 validés ; meilleurs scores globaux qwen3.5:4b (79,8) puis qwen3-coder:30b (62,5).
  Détail, classements par rôle et restitution mémoire : `models/benchmarks/report.md` ; synthèse par modèle : `models/registry.yaml`.
- **Conséquences** : réserves R5 et R6 mises à jour (ADR-0003). Le choix des affectations reste une décision distincte.
