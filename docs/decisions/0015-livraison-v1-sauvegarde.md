# ADR-0015 — Livraison Local-IA v1.0.0 : sauvegarde, restauration, maintenance et documentation

Statut : appliqué le 2026-11-26 (15.B.1). BK1 préalable : `backups/restore-points/15.B.1_20261126_220224`. Les 7 modèles, les 10
affectations initiales, les replis contrôlés, B/N1/S2, la garde RAM et toutes les données utilisateur sont conservés.

## Décisions

1. **Sauvegarde** (`scripts/backup/backup.ps1`, `local-ai.ps1 backup list|status|create|verify|delete`) :
   - BK1 configurations ; BK2 projets, sessions (`local-ai-opencode`), workspaces/caches, `local-ai-tools` ; BK3 = BK1 + BK2,
     modèles **seulement** sur stockage externe (`--external`, refus du disque système et du dépôt : aucune duplication locale).
   - Quota **global** de 10 Gio sur `backups/` (abaissable pour test, jamais relevable), contrôle d'espace (seuil d'alerte SSD 45 Gio),
     refus sans écriture ; **aucune suppression automatique** (`backup delete <id> --confirm` uniquement).
   - Cohérence : OpenCode et Dev Containers en pause pendant l'archivage des volumes ; refus si une inférence est en cours ;
     attente du rétablissement du contrôle de santé après reprise.
   - Intégrité : `manifest.json`, `SHA256SUMS.txt`, empreintes par fichier (`*.files.sha256`), lisibilité des archives ;
     vérification immédiate, suppression de toute sauvegarde partielle.
   - Secrets : `secrets/` et `%USERPROFILE%\.docker\config.json` exclus ; fichiers non suivis et réglages hôte analysés (motifs de
     secret → exclusion) ; fichiers suivis déjà soumis au contrôle de confidentialité avant chaque push.
   - Archivage dans des conteneurs sans réseau, lecture seule, uid 1000, `cap_drop: ALL` (busybox de l'image OpenCode épinglée).
2. **Restauration** (`local-ai.ps1 restore`) : vérification complète préalable (refus si non conforme) ; prévisualisation sans
   `--confirm` ; cibles **témoins** (dossier vide, volumes `<nom>-<suffixe>` neufs, étiquetés `restore-test`) ; contrôle d'identité
   fichier par fichier après extraction ; `--production` seulement services arrêtés, avec sauvegarde de sécurité préalable.
3. **Maintenance** (`maintenance status`) : lecture seule (Docker, sauvegardes, journaux, sentinelle, configuration) ; aucune purge.
4. **Documentation** française complète : README, guides (démarrage, utilisateur, agents, projets, administration, sécurité,
   maintenance, sauvegarde/restauration, dépannage, extensions), architecture, CHANGELOG, ROADMAP ; réserves R1–R36 classées.

## Résultats

| Élément | Résultat |
|---|---|
| BK1 (configurations) | ≈ 0,2 Mio, 1 archive, conforme |
| BK2 (projets, sessions, workspaces/caches, outils) | ≈ 25,5 Mio, 5 archives, conforme ; OpenCode mis en pause ≈ 10 s |
| Tests de restauration témoins (`tests/backup/run-backup-tests.ps1`) | **20/20 PASS** (configurations, projets, sessions SQLite intègres, outils, intégrité, corruption, quota, espace, BK3, cibles existantes, production protégée) |
| Non exécuté | restauration `--production` réelle, BK3 avec archivage externe des modèles (R36) |

Corrections documentaires de clôture : guide de démarrage obsolète remplacé, architecture mise à jour (passerelle, réseau
`local-ai-inference`, outils, volumes), commandes `backup/restore/maintenance` décrites comme implémentées, octet de contrôle parasite
retiré de la ligne R22, ligne R6 replacée dans le tableau des réserves, guide des agents renommé `agents-locaux.md` (évite la
confusion avec un fichier `AGENTS.md` d'instructions sous Windows, insensible à la casse).

## Critères de livraison v1.0.0

`config` sans échec ; services sains ; aucune réserve bloquante ; non-régressions passerelle, JSON, Continue, permissions, arrêt
d'urgence ; sauvegardes BK1/BK2 conformes et restaurations témoins réussies ; contrôle de confidentialité sans occurrence ; aucun
modèle chargé, Continue et MCP désactivés. Étiquette Git `v1.0.0` posée lorsque ces critères sont satisfaits.
