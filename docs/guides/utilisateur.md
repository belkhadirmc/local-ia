# Guide utilisateur

## Principes

- **Tout est local** (V1) : 7 modèles Ollama sur CPU, aucun cloud, aucun MCP actif, aucune sortie Internet des conteneurs (profil N1).
- **Une inférence et un modèle à la fois** : une seconde demande attend son tour (passerelle d'inférence) ; l'autocomplétion Continue est
  suspendue (409) pendant une inférence OpenCode.
- **Supervisé** (profil S2) : lecture libre ; modifications et commandes soumises à votre validation ; refus techniques prioritaires.

## Travailler avec OpenCode

| Accès | Usage |
|---|---|
| Web `http://127.0.0.1:4096` | sessions, sélection de l'agent et du modèle de session, validations |
| TUI `.\local-ai.ps1 tui` (ou profil de terminal VS Code) | même serveur, dans le terminal |
| `.\local-ai.ps1 agent handoff <agent> "<consigne>"` | tâche lancée avec **repli local contrôlé** et vérification du modèle |

L'agent par défaut est **Assistant** (qwen3.5:4b). Choisir l'agent selon la tâche ([agents](agents-locaux.md)). Valider chaque demande de
modification ou de commande en lisant la commande exacte ; refuser toute commande opaque (risque résiduel R14/R15).

### Repli local contrôlé

Les affectations initiales sont conservées (ex. développeur sur qwen3-coder:30b). Quand le modèle initial n'est pas utilisable
(RAM insuffisante, ou modèle sans appels d'outils exploitables), `agent handoff` choisit **avant exécution** le premier modèle
admissible de sa chaîne (9B puis 4B ; sécurité : 9B **sur confirmation** `--accept-fallback`) pour **cette tâche uniquement**.
Dans le Web/TUI, la passerelle refuse la requête avec la **proposition** de repli : sélectionner ce modèle pour la session.
`.\local-ai.ps1 fallback check all` montre la décision du moment ; journal : `runtime/logs/fallback.jsonl`.

### Délégation

Désactivée en automatique (instable sur CPU) : un agent termine sa réponse par « Transfert -> <agent> : <consigne> » ;
lancez-la avec `agent handoff`.

## Autocomplétion (Continue)

```powershell
.\local-ai.ps1 continue on     # relais 127.0.0.1:11435, qwen2.5-coder:1.5b (refusé si OpenCode infère)
.\local-ai.ps1 continue off    # arrêt du relais, modèle déchargé
```

Puis barre d'état « Continue » → *Enable Tab Autocomplete*. Utiliser Continue dans les fenêtres **locales** (R19).

## Projets et outils

- Projets Dev Containers isolés : [projects](projects.md). Seul le projet **ouvert** est visible d'OpenCode.
- Python 3.14 et Git 2.54 isolés sont disponibles pour les agents et les nouveaux Dev Containers (`tools status`) ;
  aucune installation de paquet (pas de réseau, pas de pip).

## Bon usage de la RAM

Les modèles ≥ 14B ne sont admis que si la RAM Windows libre projetée reste ≥ 4 Gio : fermer navigateur et applications lourdes avant
une tâche gpt-oss:20b ou qwen3-coder:30b. `monitor status` affiche la RAM et le débit attendu.
