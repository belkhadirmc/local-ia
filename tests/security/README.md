# Tests de sécurité

Réalisés et documentés dans les ADR (7.B.1, 10.B.1, 11.B.1, 14.B.1) : non-root, `cap_drop ALL`, `no-new-privileges`,
racine en lecture seule, absence de socket Docker, absence de route Internet, ports 127.0.0.1 uniquement, permissions
(`local-ai.ps1 permissions check`), passerelle (`tests/gate/`). Vérification statique permanente : `local-ai.ps1 config`.
