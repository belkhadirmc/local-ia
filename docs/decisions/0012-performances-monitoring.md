# ADR-0012 — Optimisation des performances et supervision (12.B.1)

Statut : appliqué le 2026-11-26. 7 modèles, 10 agents, affectations, N1/S2, réflexion (qwen3.5 `none`, gpt-oss `low`),
1 inférence / 1 modèle chargé inchangés. Sauvegarde BK1 préalable : `backups/restore-points/12.B.1_20261126_184605`
(dépôt, `.env` sans secret, **`.wslconfig`**, `settings.json` VS Code).

## Audit matériel

| Élément | Constat |
|---|---|
| CPU | AMD Ryzen 7 5700U, 8 cœurs / 16 threads, base 1,8 GHz, L3 8 Mio, AVX2/FMA/F16C (pas d'AVX-512) |
| RAM | 37,9 Gio : 32 Gio (Hynix, canal A) + 8 Gio (Micron, canal B), DDR4-3200 — **asymétrique** : dual channel sur 16 Gio, le reste en simple canal (R23) |
| Alimentation | secteur, batterie 100 %, plan Windows « Utilisation normale » ; mode Lenovo non lisible |
| Températures, fréquences | non lisibles (WMI « non pris en charge » sans droits administrateur, R25) |
| GPU | Radeon Vega 8 intégrée (pilote 31.0.21912), 2 Gio partagés — voir Vulkan |
| WSL2 | 24 Gio, swap 8 Gio, `autoMemoryReclaim=gradual` ; vCPU 8 → **16** |

## Microtests (12 min d'inférence au total, plafond 15 min)

Prompt « speed » de 6.B.1 (≈ 40 tokens ; variante longue ≈ 850 tokens), température 0, seed 42, 128 tokens maximum,
réflexion désactivée pour qwen3.5. Outil : `models/benchmarks/microtest.ps1` (résultats bruts `runtime/bench/microtests.jsonl`).

| Configuration (qwen3.5:4b, contexte 4096) | Sortie t/s | Prompt t/s (≈ 850 tok) | TTFT court |
|---|---|---|---|
| 8 vCPU, auto = **4 threads**, KV f16 (avant) | 7,00 | 34,5 | 1,36 s |
| 8 vCPU, 8 threads | 7,06 / 6,8–8,2 | 44,8 | 1,04 s |
| 8 vCPU, 8 threads, num_batch 256 / 512 / 1024 | 8,19 / 6,78 / 7,89 | 44,6 / 44,8 / 45,8 | — |
| 8 vCPU, 8 threads, Flash Attention désactivée | 7,73 | 46,1 | — |
| 8 vCPU, 8 threads, KV q8_0 (4096 / 8192) | 7,34 / 7,48 | 45,2 / 43,5 | — |
| 12 vCPU, auto = 6 / 8 / 12 threads | 8,08 / 7,76 / 6,74 | 40,9 / 43,5 / 48,8 | — |
| 16 vCPU, auto = **8** / 16 threads | 8,20 / 5,65 | 45,9 / 52,2 | — |
| **Retenu : 16 vCPU, auto (8 threads), KV q8_0, FA auto** | **8,51** | 45,9 | **1,00 s** |

Confirmation **qwen3-coder:30b** (contexte 4096, réglages retenus) : **8,65 t/s** contre 8,11 en 6.B.1 (+7 %), TTFT 0,81 s
contre 1,14 s ; RAM WSL2 hors cache 18,65 Gio, swap 0 ; RAM Windows libre minimale 1,44 Gio pendant le chargement
(cache de pages, rendue en moins d'1 min, R24).

### Avant / après

| Mesure | Avant (8 vCPU, 4 threads, KV f16) | Après (profil B) | Gain |
|---|---|---|---|
| qwen3.5:4b — sortie | 7,00 t/s (6.B.1 : 7,42) | 8,51 t/s | **+22 %** (+15 % vs 6.B.1) |
| qwen3.5:4b — TTFT court | 1,36 s (6.B.1 : 1,21) | 1,00 s | **−26 %** |
| qwen3.5:4b — traitement du prompt (≈ 850 tok) | 34,5 t/s | 45,9 t/s | **+33 %** (TTFT 24,8 → 18,6 s) |
| qwen3.5:4b — contexte 8192 | — | 7,81 t/s, KV 136 Mio (f16 : 256 Mio) | KV −47 % |
| qwen3-coder:30b — sortie | 8,11 t/s (6.B.1) | 8,65 t/s | **+7 %** |
| qwen3-coder:30b — TTFT | 1,14 s | 0,81 s | **−29 %** |
| Premier message OpenCode (≈ 2 840 tokens) | ≈ 81 s de traitement à 35 t/s | ≈ 62 s à 46 t/s (estimation) | ≈ −24 % |

### Décisions

- **WSL2 16 vCPU** (RAM maintenue à 24 Gio) : Ollama choisit alors **8 threads** (cœurs physiques), l'optimum mesuré ;
  aucun `num_thread` à forcer (OpenCode ne peut pas le transmettre). 16 threads dégradent la génération (−30 %).
  La génération reste limitée par la bande passante mémoire (R23).
- **num_batch 512** (défaut) : écarts ≤ 2 %, dans le bruit.
- **Flash Attention auto** (déjà active) : la désactiver n'apporte rien.
- **Cache KV q8_0** (`OLLAMA_KV_CACHE_TYPE`) : vitesse inchangée, mémoire KV ÷ 2 (30B : 204 Mio à 4096) → marge RAM.
- **Contexte 8192 et keep_alive 5 min** conservés (16384 et une rétention plus longue aggravent R24).
- **Prompts OpenCode** : compactés (titres en ligne, aucune instruction ni protection retirée, contrôle mot à mot), −1,4 %
  seulement ; la part OpenCode (≈ 2 300 tokens) n'est pas réductible par une clé vérifiée (R27). Application vérifiée par
  `/api/agent` (prompt compact présent, règles `secrets/` présentes), permissions identiques (diff limité aux champs `system`).
- **Vulkan / Vega 8** : inapplicable sans installation (R26) ; `OLLAMA_VULKAN=0`.

## Administration

- **Profils A/B/C** (`profiles/performance/*.yaml`, schéma v2) : A économe (12 Gio, 8 vCPU, contexte 4096, modèles ≤ 9b),
  **B validé** (24 Gio, 16 vCPU, 8192, KV q8_0), C maximal (32 Gio, risque RAM Windows, non mesuré).
- `local-ai.ps1 profile list | show <id> | apply <id> --confirm` : sans `--confirm`, affiche seulement les écarts et l'effet ;
  refus si arrêt d'urgence ou modèle chargé ; BK1 (`.wslconfig`, `ollama.env`, `defaults.yaml`) ; redémarrage Docker/WSL2
  uniquement si `.wslconfig` change (séquence fiabilisée : arrêt, `wsl --shutdown`, attente, démarrage, 1 nouvel essai) ;
  vérification (vCPU, RAM WSL2, variables effectives d'Ollama) ; **rollback** automatique sinon. Testé réellement : un échec de
  vérification (bogue corrigé depuis) a déclenché le rollback, puis l'application a réussi en 50 s.
- `local-ai.ps1 monitor status | watch [s] [n]` (`scripts/monitor/monitor.ps1`, aucun service résident) : CPU, RAM Windows,
  RAM WSL2 hors cache / cache, swap, SSD, vCPU, modèle actif, débit disponible (référence `config/monitoring/throughput.yaml`),
  conteneurs, alertes selon `config/monitoring/thresholds.yaml` (ADR-0001). Historique `runtime/monitor/metrics-AAAAMMJJ.jsonl`,
  rétention 7 j ; audit 30 j ; état `runtime/state/monitor.json`. Niveau critique : journalisé et **blocage** des chargements
  lancés par local-ai (`continue on`) ; urgence : emergency-stop seulement proposé. Aucune suppression critique automatique.

## Tests manuels 11.B.1 réalisés par l'utilisateur (interface VS Code)

| Test | Résultat |
|---|---|
| Continue : autocomplétion et Tab dans l'éditeur | PASS |
| OpenCode TUI via le profil de terminal VS Code « OpenCode (local-ai) » | PASS |
| Projet Dev Container de démonstration, Ubuntu 24.04.5, utilisateur non-root (« Reopen in Container ») | PASS |
