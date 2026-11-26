# Démarrage rapide — Local-IA v1.0.0

## Prérequis (état validé)

- Windows 11, Docker Desktop (WSL2) démarré, PowerShell 5.1, VS Code (Continue 2.0.0, Dev Containers 0.481.0 épinglées).
- Profil **B** appliqué : WSL2 24 Gio / 16 vCPU / swap 8 Gio (`.\local-ai.ps1 profile show B`).
- Volumes externes présents : `local-ai-ollama` (7 modèles), `local-ai-opencode` (sessions), `local-ai-tools` (Python/Git).
- Mot de passe Web/API local : `secrets/opencode.env` (non versionné, jamais sauvegardé en clair).

## Premier lancement

```powershell
cd C:\dev\local-ai
.\local-ai.ps1 config            # 18 contrôles statiques : tout doit être PASS (1 DIFFÉRÉ attendu : affectations)
.\local-ai.ps1 start opencode    # sentinelle RAM + Ollama + passerelle d'inférence + OpenCode (aucun téléchargement)
.\local-ai.ps1 status            # état en lecture seule
.\local-ai.ps1 monitor status    # RAM Windows/WSL2, SSD, modèle actif, alertes
```

Accès : **Web** `http://127.0.0.1:4096` (utilisateur `opencode`) ou **TUI** `.\local-ai.ps1 tui` (aussi : profil de terminal VS Code
« OpenCode (local-ai) »). Le premier message d'une session est lent à froid (≈ 1 à 2 min sur CPU), les suivants ≈ 10 s.

## Premier travail sur un projet

```powershell
.\local-ai.ps1 project create monprojet      # volumes dédiés, réseau interne, Dev Container non-root
.\local-ai.ps1 project open monprojet        # partage CE projet (seul) avec OpenCode
.\local-ai.ps1 agent handoff developer "Ajoute une fonction … dans src/app.py"   # tâche avec repli local contrôlé
```

Dans VS Code : ouvrir `C:\dev\local-ai\projects\monprojet`, puis « Dev Containers: Reopen in Container ».

## Arrêt

```powershell
.\local-ai.ps1 project stop monprojet
.\local-ai.ps1 stop opencode ; .\local-ai.ps1 stop ollama     # rien n'est supprimé
.\local-ai.ps1 emergency-stop                                 # en cas de doute : tout est interrompu, aucune donnée supprimée
```

Suite : [utilisateur](utilisateur.md), [agents](agents-locaux.md), [administration](administration.md), [dépannage](depannage.md).
