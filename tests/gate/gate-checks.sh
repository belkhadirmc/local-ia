#!/bin/sh
# Contrôles de la passerelle SANS inférence (14.B.1) — exécuté dans l'espace réseau d'OpenCode (docker exec local-ai-opencode-1 sh).
# Chaque ligne : attendu / obtenu / libellé.
G=http://ollama:11434
req() { # méthode chemin [corps] -> code HTTP
  if [ -n "$3" ]; then printf '%s' "$3" > /tmp/b.json; wget -q -S -O /tmp/r.out --header 'Content-Type: application/json' --post-file /tmp/b.json "$G$2" 2>&1 | grep -o 'HTTP/1.[01] [0-9]*' | tail -1 | cut -d' ' -f2
  else wget -q -S -O /tmp/r.out "$G$2" 2>&1 | grep -o 'HTTP/1.[01] [0-9]*' | tail -1 | cut -d' ' -f2; fi
}
chk() { got=$(req "$2" "$3" "$4"); [ "$got" = "$1" ] && r=PASS || r=FAIL; echo "$r attendu=$1 obtenu=${got:-erreur} $5"; }
chk 200 GET /api/version '' 'lecture version'
chk 200 GET /api/tags '' 'lecture modèles'
chk 200 GET /api/ps '' 'lecture modèles chargés'
chk 403 POST /api/pull '{"model":"x"}' 'téléchargement refusé'
chk 403 POST /api/delete '{"model":"qwen3.5:4b-q4_K_M"}' 'suppression refusée'
chk 403 POST /api/create '{"model":"x"}' 'création refusée'
chk 403 POST /api/copy '{"source":"a","destination":"b"}' 'copie refusée'
chk 403 POST /api/chat '{"model":"llama3:8b","messages":[]}' 'modèle hors registre'
chk 403 POST /v1/chat/completions '{"model":"gpt-4o","messages":[]}' 'modèle cloud refusé (OpenAI)'
chk 400 POST /api/chat '{"model":"qwen3.5:4b-q4_K_M","model":"gpt-oss:20b","messages":[]}' 'clé model dupliquée'
chk 400 POST /api/chat '{"model":"qwen3.5:4b-q4_K_M",}' 'JSON invalide'
chk 403 POST /api/chat '{"prompt":"\"model\":\"qwen3.5:4b-q4_K_M\""}' 'modèle seulement dans une chaîne'
chk 200 POST /api/show '{"model":"qwen3.5:4b-q4_K_M"}' 'métadonnées modèle autorisé'
chk 200 POST /api/generate '{"model":"qwen3.5:4b-q4_K_M","keep_alive":0}' 'déchargement sans inférence'
# Isolement : le moteur n'est plus joignable directement
if wget -q -T 3 -O /dev/null http://ollama-engine:11434/api/version 2>/dev/null; then echo 'FAIL moteur ollama-engine joignable depuis OpenCode'; else echo 'PASS moteur Ollama injoignable directement (réseau local-ai-inference)'; fi
