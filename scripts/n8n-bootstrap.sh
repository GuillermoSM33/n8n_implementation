#!/usr/bin/env bash
# Importa los workflows de n8n/workflows y los publica.
#
# Las credenciales se crean SOLO si no existen, con valores de relleno
# ("REEMPLAZAR"): los secretos reales se capturan después en la UI de n8n
# (Overview → Credentials). Volver a correr el script nunca pisa un secreto.
#
# Uso: ./scripts/n8n-bootstrap.sh   (con `docker compose up -d` ya corriendo)
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE=n8n
n8n_exec() { docker compose exec -T "$SERVICE" "$@"; }

supabase_url="$(grep -E '^H4U_SUPABASE_URL=' .env | cut -d= -f2-)"

ensure_credential() {
  local id="$1" name="$2" type="$3" data="$4"
  if n8n_exec sh -c "n8n export:credentials --id=$id --output=/tmp/c.json >/dev/null 2>&1; rc=\$?; rm -f /tmp/c.json; exit \$rc"; then
    echo "· Credencial ya existe: $name"
    return
  fi
  echo "+ Creando credencial de relleno: $name"
  printf '[{"id":"%s","name":"%s","type":"%s","data":%s}]' "$id" "$name" "$type" "$data" \
    | n8n_exec sh -c 'cat > /tmp/c.json && n8n import:credentials --input=/tmp/c.json >/dev/null; rc=$?; rm -f /tmp/c.json; exit $rc'
}

ensure_credential H4uSupabaseSrv01 "H4U · Supabase service_role" supabaseApi \
  "{\"host\":\"${supabase_url}\",\"serviceRole\":\"REEMPLAZAR\"}"
ensure_credential H4uWebhookSecr01 "H4U · Secreto del webhook" httpHeaderAuth \
  '{"name":"X-H4U-Secret","value":"REEMPLAZAR"}'
ensure_credential H4uWhatsAppTok01 "H4U · Token WhatsApp Cloud API" httpHeaderAuth \
  '{"name":"Authorization","value":"Bearer REEMPLAZAR"}'

echo "+ Importando workflows"
n8n_exec n8n import:workflow --separate --input=/workflows >/dev/null

for id in H4uProcesarAviso H4uWebhookAviso0 H4uBarridoAvisos; do
  n8n_exec n8n publish:workflow --id="$id" >/dev/null
  echo "· Publicado: $id"
done

echo "+ Reiniciando n8n para activar los workflows"
docker compose restart "$SERVICE" >/dev/null
echo "Listo. Abre http://localhost:5678 y reemplaza los valores REEMPLAZAR de las 3 credenciales."
