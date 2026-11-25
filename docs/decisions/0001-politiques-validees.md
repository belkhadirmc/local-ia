# ADR-0001 — Politiques validées

Statut : validé (étapes 1 à 3.B.1).

| Domaine | Politique |
|---|---|
| SSD libre | alerte 45 Gio, critique 30 Gio, urgence 15 Gio |
| RAM WSL2 | alerte 85 %, critique 95 % |
| CPU | 95 % soutenu sur 5 min |
| RAM Windows | 4 Gio libres minimum |
| Swap | 2 Gio utilisés maximum |
| Rétention | métriques 7 jours, audit 30 jours |
| Sauvegardes locales | quota 10 Gio |
| Suppressions | aucune suppression critique automatique |
| Inférence | 1 inférence et 1 modèle chargé simultanément ; OLLAMA_NO_CLOUD=1 |
| Profils par défaut | B + N1 + S2 (+ BK1) |

Valeurs machine : `config/monitoring/thresholds.yaml`.
