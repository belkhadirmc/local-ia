# Sauvegarde et restauration

| Profil | Contenu | Taille mesurée (v1.0.0) |
|---|---|---|
| **BK1** configurations | fichiers suivis du dépôt, `.env` (sans secret), `.wslconfig`, `daemon.json`, `settings-store.json` de Docker | ≈ 0,2 Mio |
| **BK2** données | `projects/<id>/.devcontainer`, volumes `local-ai-opencode` (sessions), `local-ai-workspace-*`, `local-ai-cache-*`, `local-ai-tools` | ≈ 25,5 Mio |
| **BK3** complet | BK1 + BK2 ; modèles (`local-ai-ollama`, ≈ 57 Go) **uniquement** vers un stockage externe (`--external`) | — |

Jamais sauvegardés : `secrets/` (à conserver par vos propres moyens, hors dépôt), `%USERPROFILE%\.docker\config.json` (identifiants de
registre possibles), `runtime/`, et tout fichier non suivi présentant un motif de secret. Les modèles ne sont **jamais dupliqués
localement** (refus si `--external` est sur le disque système ou sous le dépôt) : ils sont re-téléchargeables depuis le registre épinglé.

## Commandes

```powershell
.\local-ai.ps1 backup status                       # utilisation / quota 10 Gio, dernière sauvegarde par profil
.\local-ai.ps1 backup create BK1                   # ou BK2, BK3 [--external E:\sauvegardes]
.\local-ai.ps1 backup list
.\local-ai.ps1 backup verify <id|chemin>           # empreintes SHA256, manifeste, lisibilité des archives
.\local-ai.ps1 backup delete <id> --confirm        # suppression MANUELLE uniquement
.\local-ai.ps1 restore <id> --target-dir D:\temoin                 # PRÉVISUALISATION (rien n'est écrit)
.\local-ai.ps1 restore <id> --target-dir D:\temoin --confirm       # fichiers dans un dossier vide
.\local-ai.ps1 restore <id> --volume-suffix essai --confirm        # volumes restaurés sous <nom>-essai (aucun écrasement)
.\local-ai.ps1 restore <id> --item vol-local-ai-opencode --production --confirm   # remplacement réel (services arrêtés)
```

## Garanties

- **Contrôle préalable** : quota global de 10 Gio pour tout `backups/` (abaissable pour test via `LOCAL_AI_BACKUP_QUOTA_GIB`, jamais
  relevable) et espace disque (seuil d'alerte SSD 45 Gio) ; refus sans rien écrire, aucune suppression automatique.
- **Cohérence** : OpenCode et les Dev Containers sont mis en **pause** pendant l'archivage des volumes ; refus si une inférence est en cours.
- **Intégrité** : `manifest.json` (éléments, sources, tailles, empreintes, exclusions), `SHA256SUMS.txt`, empreintes **par fichier**
  (`*.files.sha256`) ; vérification immédiate après création ; une sauvegarde partielle est supprimée.
- **Restauration** : toujours précédée d'une vérification complète ; prévisualisation sans `--confirm` ; cibles témoins vides ou
  volumes nouveaux uniquement ; contrôle d'identité fichier par fichier après extraction. Mode `--production` : services arrêtés
  obligatoires et **sauvegarde de sécurité** automatique de l'état remplacé.

## Tests v1.0.0 (cibles témoins, `tests/backup/run-backup-tests.ps1`) : 20/20 PASS

Vérification BK1/BK2, prévisualisation sans écriture, configurations restaurées identiques au dépôt, absence de secrets, refus d'une
cible non vide, 4 volumes restaurés identiques, configuration des projets, **sessions restaurées intègres** (SQLite `integrity_check`
ok, 5 sessions, lu par le Python du volume d'outils restauré), outils restaurés (Python 3.14.10, Git 2.54.1, 34 paquets), refus d'un
volume existant, refus de la production avec services actifs, **corruption** d'un octet détectée et restauration refusée, **refus de
quota**, quota non relevable, refus d'espace, BK3 : refus du disque système et d'un stockage absent, aucune sauvegarde partielle.

Non testé : restauration `--production` réelle (même code d'extraction que les témoins ; non exécutée pour préserver les données)
et BK3 avec stockage externe (aucun support externe disponible) — réserve R36.
