# Benchmarks (6.B.1)

Suite reproductible : `suite.yaml` (paramètres, seuils, pondérations, rôles) et `cases/*.json` (critères figés avant exécution).

```powershell
.\run-benchmarks.ps1                                   # 7 modèles du registre (plusieurs heures en CPU)
.\run-benchmarks.ps1 -Models qwen2.5-coder:1.5b -Quick # essai à blanc
.\run-benchmarks.ps1 -Models <tag> -MergeFrom .\results\<horodatage>   # relance partielle, notation fusionnée
.\make-report.ps1                                      # summary.json (+ report-notes.md) -> report.md
```

Résultats : `report.md`, `summary.csv`, `summary.json`. Bruts (réponses, échantillons 1 s) : `results/` (non versionné).
Décision : `docs/decisions/0006-benchmarks.md`.
