#!/bin/sh
# Shell des commandes d'agent OpenCode (14.B.1, R14) : le mot de passe du serveur n'est PAS transmis aux commandes.
# Limite connue : /proc/1/environ reste lisible par le même uid (refus techniques « environ », « /proc/ » + validation humaine).
unset OPENCODE_PASSWORD
# 14.B.2 (R30) : Python et Git isolés (volume local-ai-tools, lecture seule) disponibles pour les commandes d'agent
export PATH="/opt/local-ai-tools/bin:$PATH"
exec /bin/sh "$@"
