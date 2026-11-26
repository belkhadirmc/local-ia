# Guide — projets, VS Code, Continue et OpenCode

## Projet Dev Container

```powershell
.\local-ai.ps1 project create monprojet   # volumes local-ai-workspace-monprojet / local-ai-cache-monprojet, réseau interne
.\local-ai.ps1 project open monprojet     # démarre le Dev Container et partage CE projet (seul) avec OpenCode
.\local-ai.ps1 project list
.\local-ai.ps1 project stop monprojet     # arrête le conteneur ; plus aucun projet partagé avec OpenCode
```

Dans VS Code : ouvrir le dossier `C:\dev\local-ai\projects\monprojet`, puis la commande « Dev Containers: Reopen in Container ».
Le code est dans le volume `local-ai-workspace-monprojet` (`/workspaces/monprojet`), pas sur le disque Windows.
Le conteneur n'a pas d'accès Internet. Python 3.14 et Git 2.54 isolés y sont disponibles (volume `local-ai-tools` en lecture seule,
dans le PATH) pour les projets créés depuis la v1.0.0 ; le projet `demo` antérieur garde sa configuration (recréer sa configuration
Dev Container pour en bénéficier). Toute autre dépendance : image de projet enrichie après arbitrage R3.

Sauvegarde : `backup create BK2` (configuration du projet + workspace + cache) ; restauration témoin : `restore <id> --volume-suffix essai --confirm`.

## Autocomplétion (Continue)

```powershell
.\local-ai.ps1 continue install   # une fois : configuration locale, télémétrie et indexation coupées
.\local-ai.ps1 continue on        # relais 127.0.0.1:11435 (refusé si OpenCode infère)
.\local-ai.ps1 continue off       # arrêt du relais, modèle déchargé
```

Extensions épinglées (Continue 2.0.0, Dev Containers 0.481.0, mises à jour automatiques désactivées). Puis, dans VS Code, barre d'état « Continue » → *Enable Tab Autocomplete*. Pendant une inférence OpenCode, l'autocomplétion est
suspendue (réponse 409), sans déchargement du modèle d'OpenCode.

## OpenCode depuis VS Code

- Terminal : menu du terminal intégré → profil **« OpenCode (local-ai) »** (équivaut à `.\local-ai.ps1 tui`). Le TUI utilise le tmpfs
  exécutable dédié `/tui-tmp` (`TMPDIR`), `/tmp` restant noexec (11.B.2). Validé manuellement dans VS Code.
- Web : `http://127.0.0.1:4096` (utilisateur `opencode`, mot de passe dans `secrets/opencode.env`), par exemple via « Simple Browser: Show ».
