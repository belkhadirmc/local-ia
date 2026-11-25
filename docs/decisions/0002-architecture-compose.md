# ADR-0002 — Compose modulaire

Include pour le socle, modèles inactifs pour les services (profil Compose + image obligatoire),
surcharges explicites pour tout réseau non interne. Les ancres YAML ne traversant pas `include`,
la base de sécurité est recopiée dans chaque service (`compose/templates/service-security-baseline.yaml`).
