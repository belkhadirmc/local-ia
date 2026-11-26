# Benchmarks local-ai — 6.B.1

Exécution `20261126_100232` · profil B+N1+S2 · CPU uniquement · RAM WSL2 23,47 Gio (base 1,38 Gio) · RAM Windows disponible au départ 22,1 Gio · SSD 118,37 → 118,18 Gio.

Modèles repris de l'exécution `20261125_212627` (complets, non relancés) : qwen2.5-coder:1.5b, qwen3.5:4b-q4_K_M, qwen2.5-coder:7b, qwen3.5:9b-q4_K_M. Les autres ont été relancés dans `20261126_100232` après une mise en veille de Windows et des interruptions de sécurité.

Protocole : `suite.yaml` et `cases/*.json` (critères figés avant exécution, mêmes exercices pour tous). Une requête et un modèle à la fois, température 0, graine 42.
Validation : **exécutée** (code_gen, debug, qa, fim — Bash dans un bac à sable Docker sans réseau, lecture seule, sans capacités), **statique** (critères regex/structure, devops analysé par `docker compose config`), **simulée** (tools : appels d'outils vérifiés, aucun outil exécuté).

## Synthèse

| Modèle | Score /100 | Code | Raison. | Instr. | Outils | Vitesse | Mémoire | Sortie tok/s | 1er token chaud | Chargement froid | Entrée tok/s 4096 / 8192 | Pic RAM WSL2 4096 / 8192 | Contexte 4096 | Contexte 8192 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| qwen3.5:4b-q4_K_M | **79,8** | 83 | 86 | 100 | 100 | 44 | 73 | 7,4 | 1,21 s | 7,7 s | 33,3 / 30,0 | 6,5 Gio (27,6 %) / 6,5 Gio (27,5 %) | validé | validé |
| qwen3-coder:30b | **62,5** | 78 | 100 | 94 | 0 | 44 | 2 | 8,1 | 1,14 s | 33,1 s | 23,6 / 17,9 | 19,5 Gio (83,1 %) / 19,9 Gio (84,6 %) | validé | validé |
| qwen2.5-coder:14b | **61,8** | 78 | 94 | 100 | 0 | 15 | 44 | 2,6 | 3,32 s | 21,2 s | 8,5 / 7,3 | 11,8 Gio (50,4 %) / 12,6 Gio (53,9 %) | validé | validé |
| gpt-oss:20b | **61,8** | 50 | 98 | 100 | 100 | 28 | 30 | 6,2 | 3,89 s | 21,3 s | 22,9 / 21,1 | 14,5 Gio (61,6 %) / 14,5 Gio (61,8 %) | validé | validé |
| qwen3.5:9b-q4_K_M | **60,2** | 45 | 88 | 100 | 100 | 21 | 56 | 3,2 | 2,45 s | 14,5 s | 17,9 / 17,7 | 9,6 Gio (40,7 %) / 9,5 Gio (40,5 %) | validé | validé |
| qwen2.5-coder:7b | **59,9** | 64 | 89 | 92 | 0 | 30 | 72 | 5,1 | 1,61 s | 10,7 s | 17,7 / 16,2 | 6,5 Gio (27,7 %) / 6,8 Gio (28,9 %) | validé | validé |
| qwen2.5-coder:1.5b | **49,9** | 31 | 39 | 83 | 0 | 92 | 94 | 21,5 | 0,29 s | 1,6 s | 83,5 / 68,9 | 2,5 Gio (10,7 %) / 3,0 Gio (12,6 %) | validé | validé |

Pondération : code 40, raisonnement 15, vitesse 15, mémoire 10, outils 10, instructions 10. Catégorie non réalisée = exclue et poids renormalisés.
Normalisation : vitesse = 0,5 × min(1, sortie/20 tok/s) + 0,2 × min(1, 1 s / 1er token chaud) + 0,3 × min(1, 30 s / 1er token à 4096) ; mémoire = 1 − (pic RAM WSL2 hors cache à 4096 − base) / (85 % RAM WSL2 − base).

## Détail par exercice (0–100)

| Modèle | code_gen | debug | qa | fim | devops | review | security | architecture | multifile | instructions | documentation | tools | aiguille 4096 | aiguille 8192 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| qwen2.5-coder:1.5b | 10 | 0 | 0 | 100 | 45 | 17 | 67 | 78 | 75 | 67 | 100 | 0 | 0 | 0 |
| qwen3.5:4b-q4_K_M | 80 | 60 | 100 | n.s. | 91 | 83 | 67 | 89 | 75 | 100 | 100 | 100 | 100 | 100 |
| qwen2.5-coder:7b | 80 | 40 | 0 | 100 | 100 | 100 | 83 | 78 | 75 | 83 | 100 | 0 | 100 | 100 |
| qwen3.5:9b-q4_K_M | 100 | 0 | 0 | n.s. | 82 | 67 | 100 | 89 | 75 | 100 | 100 | 100 | 100 | 100 |
| qwen2.5-coder:14b | 90 | 0 | 100 | 100 | 100 | 83 | 100 | 78 | 100 | 100 | 100 | 0 | 100 | 100 |
| gpt-oss:20b | 100 | 0 | 0 | n.s. | 100 | 100 | 100 | 89 | 100 | 100 | 100 | 100 | 100 | 100 |
| qwen3-coder:30b | 100 | 40 | 100 | n.s. | 73 | 100 | 100 | 100 | 100 | 100 | 88 | 0 | 100 | 100 |

n.s. = capacité absente (insert/FIM) ; n.r. = non réalisé ; err = erreur ou délai.

## Recommandations par rôle (affectations NON modifiées)

| Rôle | Principal | Alternatives |
|---|---|---|
| Architecte | **qwen3-coder:30b** (84,7) | gpt-oss:20b (81,8), qwen3.5:4b-q4_K_M (80,2) |
| Reviewer | **qwen3-coder:30b** (93,8) | gpt-oss:20b (92,8), qwen2.5-coder:7b (84,7) |
| Sécurité | **gpt-oss:20b** (92,8) | qwen3-coder:30b (91,1), qwen2.5-coder:14b (87,3) |
| Développeur | **qwen3.5:4b-q4_K_M** (76,6) | gpt-oss:20b (72,8), qwen3.5:9b-q4_K_M (68,3) |
| DevOps | **gpt-oss:20b** (89,1) | qwen3.5:9b-q4_K_M (80,8), qwen3.5:4b-q4_K_M (78,9) |
| Debugger | **qwen3.5:4b-q4_K_M** (62,8) | qwen3-coder:30b (61,8), qwen2.5-coder:7b (51,0) |
| QA | **qwen3-coder:30b** (88,2) | qwen3.5:4b-q4_K_M (84,8), qwen2.5-coder:14b (80,9) |
| Documentaliste | **qwen2.5-coder:1.5b** (92,1) | qwen3.5:4b-q4_K_M (87,7), gpt-oss:20b (84,4) |
| Assistant | **qwen3.5:4b-q4_K_M** (80,4) | qwen2.5-coder:1.5b (72,1), qwen3.5:9b-q4_K_M (71,8) |
| Autocomplétion (Continue) | **qwen2.5-coder:1.5b** (97,1) | qwen2.5-coder:7b (76,2), qwen2.5-coder:14b (68,8) |

## Restitution mémoire après déchargement (cache non vidé)

| Modèle | Windows dispo avant | min pendant | +10 s après déchargement | RAM WSL2 +10 s |
|---|---|---|---|---|
| qwen2.5-coder:1.5b | 23,69 Gio | 23,3 Gio | 23,07 Gio | 1,26 Gio |
| qwen3.5:4b-q4_K_M | 23,53 Gio | 16,29 Gio | 18,71 Gio | 1,37 Gio |
| qwen2.5-coder:7b | 18,7 Gio | 11,14 Gio | 14,81 Gio | 1,19 Gio |
| qwen3.5:9b-q4_K_M | 14,8 Gio | 4,42 Gio | 7,02 Gio | 0,92 Gio |
| qwen2.5-coder:14b | 22,08 Gio | 5,35 Gio | 8,51 Gio | 1,09 Gio |
| gpt-oss:20b | 8,6 Gio | 4,42 Gio | 7,94 Gio | 0,87 Gio |
| qwen3-coder:30b | 8 Gio | 4,35 Gio | 10,69 Gio | 0,79 Gio |

Après la dernière série, au repos :

| t (s) | Windows dispo | RAM WSL2 hors cache | RAM conteneur (anon) |
|---|---|---|---|
| 0 | 10,75 Gio | 0,89 Gio | 0,01 Gio |
| 60 | 21,87 Gio | 0,79 Gio | 0,01 Gio |
| 180 | 26,04 Gio | 0,75 Gio | 0,01 Gio |
| 300 | 26,26 Gio | 0,97 Gio | 0,01 Gio |

## Incidents

- 4 modèle(s) repris de l'exécution 20261125_212627 (non relancés) : qwen2.5-coder:1.5b, qwen3.5:4b-q4_K_M, qwen2.5-coder:7b, qwen3.5:9b-q4_K_M

## Constats (lecture des résultats bruts)

- **Exécution `20261125_212627`** : mise en veille de Windows (23:28 → 09:30) pendant le contexte long de qwen2.5-coder:14b (délai dépassé) ; après réveil, interruption sécurisée (RAM Windows disponible < 4 Gio) de gpt-oss:20b (contexte long) et qwen3-coder:30b (vitesse). Ces 3 modèles ont été relancés intégralement ; le script bloque désormais la mise en veille pendant l'exécution (propre au processus, aucun réglage système).
- **RAM Windows disponible** : minimum 4,35–4,42 Gio pendant qwen3.5:9b, gpt-oss:20b et qwen3-coder:30b, soit juste au-dessus du seuil d'interruption (4 Gio). Cause : le cache de pages de WSL2 (lecture des fichiers modèles), non compté dans la RAM WSL2 « hors cache » mais retenu par la VM ; il est rendu à Windows en 1 à 3 min au repos (voir restitution). Cache non vidé, conformément à la consigne.
- **qwen3-coder:30b à 8192** : validé, pic 84,6 % de RAM WSL2 hors cache (seuil d'alerte 85 %) ; marge quasi nulle, aucun autre modèle ni charge concurrente possible.
- **Appels d'outils qwen3-coder:30b = 0** : le modèle produit le bon appel (`<function=run_tests>…`) mais sans balise ouvrante `<tool_call>` ; Ollama 0.40.18 ne l'extrait donc pas en `tool_calls`. Inutilisable tel quel par un agent via l'API (critère inchangé). qwen2.5-coder (1.5b à 14b) écrit l'appel en JSON dans le texte : même verdict.
- **Échecs exécutés notables** : gpt-oss:20b debug (lit l'en-tête sur stdin au lieu du fichier) et qa (test faux : `clamp -5 -10 -3` attendu à -3) ; debug est l'exercice le plus discriminant (meilleur résultat 60 %).
- **Exercice documentation saturé** (6/7 modèles à 100 %) : le classement Documentaliste est alors dominé par la vitesse, d'où qwen2.5-coder:1.5b en tête malgré des instructions à 67 %. À interpréter avec prudence.
- **Notation fusionnée** : la mémoire est normalisée sur la base de l'exécution `20261126_100232` (1,38 Gio) ; écart < 0,5 point pour les modèles repris.

## Limites

- Une seule passe qualité par exercice (température 0) : écarts de quelques points non significatifs.
- Code exécuté en Bash uniquement (seuls bash/perl/awk sont disponibles dans l'image existante) ; Python évalué statiquement.
- Contexte long : prompts synthétiques (aiguille dans un module généré) ; vitesses médianes sur 2 exécutions par contexte, 3 répétitions pour la vitesse courte.
- Résultats bruts (réponses, échantillons 1 s) : `results/<horodatage>/` (non versionné).
