#!/usr/bin/env bash
# Corre DENTRO de la VM, en la carpeta donde se descomprimió el paquete.
# 1. Levanta Postgres.  2. Si la base de n8n está vacía y hay n8n.dump, lo restaura
# (workflows, credenciales cifradas, historial).  3. Levanta n8n y Caddy.
# Requiere el mismo N8N_ENCRYPTION_KEY con el que se cifró el dump (va en .env).
set -euo pipefail
cd "$(dirname "$0")/../.."
C="docker compose -f docker-compose.yml -f docker-compose.gcp.yml"

$C up -d postgres
until $C exec -T postgres pg_isready -U n8n -d n8n >/dev/null 2>&1; do sleep 2; done

tables="$($C exec -T postgres psql -U n8n -d n8n -Atc "select count(*) from information_schema.tables where table_schema='public'")"
if [[ "$tables" == "0" && -f n8n.dump ]]; then
  echo "→ Restaurando la base de n8n"
  $C exec -T postgres pg_restore -U n8n -d n8n --no-owner --exit-on-error < n8n.dump
  shred -u n8n.dump
  echo "  ✓ restaurada (y n8n.dump borrado)"
else
  echo "· La base de n8n ya tiene datos ($tables tablas): no se restaura nada"
fi

$C up -d
echo "→ Esperando HTTPS en https://${N8N_HOST:-$(grep -E '^N8N_HOST=' .env | cut -d= -f2-)}"
