# Journal des modifications

Format : [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) ; versions : SemVer.

## [1.0.0] — 2026-11-26

Première version livrée de Local-IA : infrastructure de développement multi-agent **100 % locale** sous Windows 11 / WSL2.

### Ajouté
- Socle Compose modulaire à double garde (profils + images épinglées par digest), profils performance A/B/C, réseau N1–N4,
  sécurité S1–S4, sauvegarde BK1–BK3 (ADR-0001, 0002).
- Ollama 0.40.18 (CPU, 7 modèles locaux, `OLLAMA_NO_CLOUD=1`) et benchmarks (ADR-0004 à 0006).
- OpenCode 2.3.2 Web/TUI sur 127.0.0.1:4096, sans route Internet (ADR-0007) ; 10 agents, permissions S2, refus techniques
  prioritaires, anti-chaînage, arrêt d'urgence, journal d'audit (ADR-0009, 0010) ; MCP N4 préparés et désactivés.
- VS Code : Continue (autocomplétion locale, relais 127.0.0.1:11435), Dev Containers isolés, profil de terminal (ADR-0011).
- Performances : profil B (16 vCPU, Ollama 8 threads, KV q8_0), `profile`, `monitor` (ADR-0012).
- IA cloud explicitement hors V1, contrôle permanent « V1 locale » (ADR-0013).
- Passerelle d'inférence : JSON strict, verrou unique, garde RAM avant/pendant, routes d'administration refusées (ADR-0014).
- Repli local contrôlé par tâche (`agent handoff`, `fallback`), délégation manuelle, Python/Git isolés (`tools`) (ADR-0014).
- Sauvegarde/restauration : `backup list|status|create|verify|delete`, `restore` (prévisualisation, témoins, production
  protégée), `maintenance status` ; documentation utilisateur et d'exploitation complète en français (ADR-0015).

### Sécurité
- Shell des agents sans mot de passe du serveur, 39 refus techniques, contrôle de confidentialité avant chaque push.

### Limites connues
- Voir `docs/decisions/0003-reserves-et-differes.md` (R1–R36) : aucune réserve bloquante ; risques résiduels R14, R15, R17, R22, R31 ;
  repli manuel assisté dans le Web/TUI (R33).
