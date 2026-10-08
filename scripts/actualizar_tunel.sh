#!/usr/bin/env bash
# Reinicia el túnel rápido de Cloudflare y propaga la URL nueva a todo lo que la usa:
#   - .env                     N8N_PUBLIC_URL (lo que muestra el editor de n8n)
#   - Supabase Vault           n8n_webhook_url (a dónde pg_net manda los avisos)
#   - Supabase app_config      n8n_url (de donde el frontend toma la URL del triaje)
# El frontend NO necesita commit: lee la URL de app_config al abrir "Nueva incidencia".
#
# Los túneles de trycloudflare.com son efímeros: Cloudflare puede darlos de baja en
# cualquier momento ("Tunnel not found"). Este script es la recuperación de un paso.
#
# Uso:
#   ./scripts/actualizar_tunel.sh          # reinicia el túnel y propaga la URL nueva
#   ./scripts/actualizar_tunel.sh --solo-propagar   # no reinicia; propaga la URL actual
#   ./scripts/actualizar_tunel.sh --url https://n8n.ejemplo.com   # URL fija (n8n en la nube)
set -euo pipefail
cd "$(dirname "$0")/.."

restart=true
url=""
case "${1:-}" in
  --solo-propagar) restart=false ;;
  --url)
    restart=false
    url="${2:?Falta la URL después de --url}"
    url="${url%/}"
    [[ "$url" == https://* ]] || { echo "La URL debe ser https://" >&2; exit 2; } ;;
  "") ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  *) echo "Opción desconocida: $1" >&2; exit 2 ;;
esac

SUPABASE_DB_URL="${SUPABASE_DB_URL:-$(grep -E '^SUPABASE_DB_URL=' .env | cut -d= -f2- || true)}"
[[ -n "$SUPABASE_DB_URL" ]] || { echo "Falta SUPABASE_DB_URL en .env" >&2; exit 1; }
export SUPABASE_DB_URL
source scripts/_psql.sh

tunnel_url() {
  # || true: mientras el túnel no publica su URL, grep no encuentra nada (no es error).
  { docker compose logs tunnel --since "$1" 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' || true; } | tail -1
}

if [[ "$restart" == true ]]; then
  echo "→ Reiniciando el túnel"
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker compose --profile tunnel up -d --force-recreate tunnel >/dev/null 2>&1
  url=""
  for _ in $(seq 1 30); do
    url="$(tunnel_url "$since")"
    [[ -n "$url" ]] && break
    sleep 2
  done
elif [[ -z "$url" ]]; then
  url="$(tunnel_url 24h)"
fi
[[ -n "$url" ]] || { echo "No encontré la URL del túnel en los logs" >&2; exit 1; }
echo "  URL: $url"

# El túnel tarda unos segundos en ser alcanzable. Sin el secreto, el webhook responde 403:
# eso confirma túnel + n8n + workflow publicado.
echo "→ Esperando a que n8n responda en $url"
code=000
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/webhook/h4u-aviso" --max-time 10 || true)"
  [[ "$code" == 403 ]] && break
  sleep 3
done
if [[ "$code" != 403 ]]; then
  echo "  El webhook respondió $code (esperaba 403). Revisa: docker compose logs tunnel n8n" >&2
  exit 1
fi
echo "  ✓ n8n alcanzable (webhook protegido: 403 sin secreto)"

echo "→ Actualizando .env"
if grep -qE '^N8N_PUBLIC_URL=' .env; then
  sed -i "s#^N8N_PUBLIC_URL=.*#N8N_PUBLIC_URL=$url/#" .env
else
  echo "N8N_PUBLIC_URL=$url/" >> .env
fi

echo "→ Actualizando Vault y app_config en Supabase"
psql_run -At -v url="$url" <<'SQL'
begin;
select vault.update_secret(
  (select id from vault.secrets where name = 'n8n_webhook_url'),
  :'url' || '/webhook/h4u-aviso');
insert into public.app_config (key, value, updated_at) values ('n8n_url', :'url', now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
commit;
select '  ✓ Vault: ' || decrypted_secret from vault.decrypted_secrets where name = 'n8n_webhook_url';
select '  ✓ app_config: ' || value from public.app_config where key = 'n8n_url';
SQL

echo "Listo. Los avisos y el triaje ya usan $url"
