#!/bin/sh
# Installation de Python et Git ISOLÉS (14.B.2, R30) dans le volume local-ai-tools, sans construction d'image (R3 non sollicité).
# Exécuté UNE fois dans un conteneur temporaire de l'image OpenCode épinglée (Alpine 3.24, mêmes clés apk), seule fenêtre réseau.
# Arbre autonome /opt/local-ai-tools/root (musl compris) + enveloppes bin/ qui invoquent explicitement le chargeur musl du volume :
# utilisables dans OpenCode (Alpine) et dans les Dev Containers (Ubuntu). Versions épinglées ; inventaire et sommes dans lock.txt.
set -eu
PY="python3=3.14.10-r2"; GIT="git=2.54.1-r0"
T=/opt/local-ai-tools; R=$T/root
rm -rf "$R" "$T/bin"; mkdir -p "$R" "$T/bin"
apk add -q --root "$R" --initdb --keys-dir /etc/apk/keys --repositories-file /etc/apk/repositories --no-cache --no-scripts "$PY" "$GIT"
LD=$(ls "$R"/lib/ld-musl-*.so.1 | head -1); LD=${LD#"$R"}
cat > "$T/bin/python3" <<EOF
#!/bin/sh
# Python isolé local-ai (volume local-ai-tools, lecture seule). Aucune dépendance externe installable (pas de réseau, pas de pip).
R=$R
exec env PYTHONHOME="\$R/usr" PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 "\$R$LD" --library-path "\$R/lib:\$R/usr/lib" "\$R/usr/bin/python3" "\$@"
EOF
cat > "$T/bin/git" <<EOF
#!/bin/sh
# Git isolé local-ai (volume local-ai-tools, lecture seule) : configuration système ignorée, pas de pager, aucun réseau (N1).
R=$R
exec env GIT_EXEC_PATH="\$R/usr/libexec/git-core" GIT_TEMPLATE_DIR="\$R/usr/share/git-core/templates" GIT_CONFIG_NOSYSTEM=1 GIT_PAGER=cat GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0 "\$R$LD" --library-path "\$R/lib:\$R/usr/lib" "\$R/usr/bin/git" "\$@"
EOF
ln -sf python3 "$T/bin/python"
chmod 0755 "$T/bin/python3" "$T/bin/git"
# Inventaire épinglé : paquet-version et somme de contrôle (base apk du volume)
awk -F: '/^P:/{p=$2} /^V:/{v=$2} /^C:/{c=$2} /^$/{if(p!="")print p"-"v" "c; p=""}' "$R/lib/apk/db/installed" | sort > "$T/lock.txt"
chown -R 0:0 "$T"; chmod -R a+rX,go-w "$T"
echo "installé : $(wc -l < "$T/lock.txt") paquets"
