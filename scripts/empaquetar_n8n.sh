#!/usr/bin/env bash
# Arma ~/h4u_n8n_gcp.tgz para migrar n8n a la VM (ver deploy/gcp/README.md):
#   - .env de la VM: solo lo que n8n necesita (sin SUPABASE_DB_URL) + N8N_HOST / N8N_PUBLIC_URL
#   - docker-compose(.gcp).yml, Caddyfile, instalar.sh y los workflows
#   - pg_dump de la base de n8n local (workflows, credenciales cifradas, historial)
# SENSIBLE: lleva N8N_ENCRYPTION_KEY. Permisos 600; bórralo con shred al terminar.
#
# Uso: ./scripts/empaquetar_n8n.sh 35-197-28-59.sslip.io
set -euo pipefail
cd "$(dirname "$0")/.."
host="${1:?Uso: $0 <host>, p. ej. 35-197-28-59.sslip.io}"
out="$HOME/h4u_n8n_gcp.tgz"
umask 077
work="$(mktemp -d "$HOME/.h4u_bundle.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/deploy/gcp" "$work/n8n"
cp docker-compose.yml docker-compose.gcp.yml "$work/"
cp deploy/gcp/Caddyfile deploy/gcp/instalar.sh "$work/deploy/gcp/"
cp -r n8n/workflows "$work/n8n/"
{
  grep -E '^(N8N_DB_PASSWORD|N8N_ENCRYPTION_KEY|H4U_SUPABASE_URL|H4U_SUPABASE_ANON_KEY|GEMINI_[A-Z_]+|H4U_OPERATOR_PHONE|H4U_UNASSIGNED_MINUTES|H4U_UNACKNOWLEDGED_MINUTES|WHATSAPP_[A-Z_]+)=' .env
  echo "N8N_HOST=$host"
  echo "N8N_PUBLIC_URL=https://$host/"
} > "$work/.env"

docker compose up -d postgres >/dev/null 2>&1
until docker compose exec -T postgres pg_isready -U n8n -d n8n >/dev/null 2>&1; do sleep 1; done
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$work/n8n.dump"

tar -C "$work" -czf "$out" .
chmod 600 "$out"
echo "✓ $out ($(du -h "$out" | cut -f1)). Variables: $(cut -d= -f1 "$work/.env" | paste -sd' ')"
