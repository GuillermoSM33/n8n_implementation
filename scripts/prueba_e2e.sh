#!/usr/bin/env bash
# Prueba de punta a punta contra el ambiente real (Supabase + n8n + Gemini + WhatsApp),
# con las mismas llamadas que hace la app. Ver scripts/prueba_e2e.py para el detalle.
#
# OJO: envía 5 WhatsApp reales (3 asignaciones a los responsables, 2 alertas al operador).
#
# Al terminar borra SOLO las incidencias que creó (y su historial y avisos, por cascada).
# Si la tabla queda vacía, reinicia el folio para que la siguiente sea INC-0001.
#
# Uso:
#   E2E_EMAIL=evaluador@h4u.demo ./scripts/prueba_e2e.sh    # pide la contraseña sin eco
#   ./scripts/prueba_e2e.sh --conservar                     # deja los datos para revisarlos en la app
set -euo pipefail
cd "$(dirname "$0")/.."

keep=false
case "${1:-}" in
  --conservar) keep=true ;;
  "") ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  *) echo "Opción desconocida: $1" >&2; exit 2 ;;
esac

env_get() { grep -E "^$1=" .env | cut -d= -f2- || true; }
export SUPABASE_DB_URL="${SUPABASE_DB_URL:-$(env_get SUPABASE_DB_URL)}"
export SB_URL="${SB_URL:-$(env_get H4U_SUPABASE_URL)}"
export SB_KEY="${SB_KEY:-$(env_get H4U_SUPABASE_ANON_KEY)}"
export N8N_URL="${N8N_URL:-$(env_get N8N_PUBLIC_URL)}"
export E2E_EMAIL="${E2E_EMAIL:-evaluador@h4u.demo}"
if [[ -z "${E2E_PASSWORD:-}" ]]; then
  read -rsp "Contraseña de $E2E_EMAIL: " E2E_PASSWORD; echo
fi
export E2E_PASSWORD

for v in SUPABASE_DB_URL SB_URL SB_KEY N8N_URL; do
  [[ -n "${!v}" ]] || { echo "Falta $v (revisa .env)" >&2; exit 1; }
done
source scripts/_psql.sh

export E2E_IDS_FILE; E2E_IDS_FILE="$(mktemp)"
cleanup() {
  if [[ "$keep" == false && -s "$E2E_IDS_FILE" ]]; then
    echo "→ Limpiando las incidencias de la prueba"
    ids="$(sed "s/.*/'&'/" "$E2E_IDS_FILE" | paste -sd,)"
    psql_run -At <<SQL
delete from public.incidents where id in ($ids);
select setval('public.incident_folio_seq', 1, false) where not exists (select 1 from public.incidents) \\g /dev/null
select '  ✓ quedan ' || count(*) || ' incidencias' from public.incidents;
SQL
  elif [[ "$keep" == true ]]; then
    echo "→ Datos conservados (--conservar). Para borrarlos, vuelve a correr sin la opción o bórralos a mano."
  fi
  rm -f "$E2E_IDS_FILE"
}
trap cleanup EXIT

python3 -I scripts/prueba_e2e.py
