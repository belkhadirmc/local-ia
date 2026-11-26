# Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| `start` refuse : arrêt d'urgence actif | `runtime/state/emergency.json` présent | `.\local-ai.ps1 emergency-stop clear` puis `start opencode` |
| Docker Desktop reste « starting » après un changement WSL2 | redémarrage lancé avant l'arrêt effectif de WSL | `docker desktop stop`, `wsl --shutdown`, attendre, `docker desktop start` (séquence de `profile apply`) |
| Session OpenCode : « RAM Windows insuffisante … REPLI PROPOSÉ » | modèle ≥ 14B non garanti par la garde RAM | fermer des applications, ou choisir le modèle proposé pour la session, ou `agent handoff` |
| « outils incompatibles : qwen… » | modèle sans appels d'outils exploitables | modèle proposé (repli) ; `fallback check <agent>` |
| « seuils RAM non garantis (sentinelle arrêtée) » | mesure Windows absente/périmée | `.\local-ai.ps1 stop ollama` puis `start opencode` (relance la sentinelle) ; `maintenance status` |
| Réponse « inférence interrompue : RAM sous le seuil » | RAM Windows < 4 Gio pendant 3 s | libérer la RAM ; relancer **manuellement** (aucun rejeu automatique) |
| Premier message très lent | chargement + traitement CPU du prompt (≈ 2 800 tokens) | attendre (1–2 min à froid) ; ensuite ≈ 10 s |
| Continue : 409 | inférence OpenCode en cours (verrou unique) | normal ; réessayer après |
| `local-ai.ps1 tui` : bibliothèque OpenTUI non chargée | `/tmp` noexec | utiliser `local-ai.ps1 tui` (TMPDIR=/tui-tmp), pas `docker exec` direct |
| OpenCode « unhealthy » quelques secondes après une sauvegarde | contrôle de santé pendant la pause | se rétablit seul (attente intégrée à `backup create`) |
| `config` FAIL « opencode.json NON À JOUR » | définitions/prompts/fallback modifiés | `.\config\opencode\generate-config.ps1` puis recréer OpenCode (`stop opencode` / `start opencode`) |
| `backup create` : quota dépassé | `backups/` > 10 Gio | `backup list`, puis `backup delete <id> --confirm` (manuel) |
| Accents altérés dans des sorties | PowerShell 5.1 (page de code console) | sans effet sur les fichiers ; les scripts forcent l'UTF-8 là où c'est nécessaire |

Diagnostic : `status`, `config`, `monitor status`, `maintenance status`, `docker logs local-ai-ollama-gate-1`,
`docker logs local-ai-opencode-1`, `runtime/logs/audit.jsonl`, `runtime/logs/fallback.jsonl`.

Pièges PowerShell 5.1 connus (scripts) : guillemets doubles altérés dans les arguments natifs (corps JSON passés en base64),
BOM ajouté aux flux natifs, alias `H`/`R` (`Get-History`/`Invoke-History`), fichiers `.ps1` avec accents enregistrés avec BOM.
