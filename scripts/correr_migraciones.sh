#!/usr/bin/env bash
# Aplica supabase/migrations/*.sql al proyecto de Supabase, en orden y una sola vez.
#
# Guardas:
#   - Registro en supabase_migrations.schema_migrations (el mismo formato que usa
#     la CLI de Supabase): una migración ya aplicada nunca se vuelve a correr.
#   - Cada migración corre en UNA transacción junto con su registro: si falla
#     cualquier sentencia, no queda nada a medias.
#   - Si un archivo ya aplicado cambió (md5 distinto), se detiene sin tocar nada:
#     las migraciones aplicadas no se editan; el cambio va en una migración nueva.
#   - Bloqueo advisory: dos ejecuciones simultáneas no aplican la misma migración.
#   - El seed solo corre con --seed y solo si la tabla properties está vacía.
#
# Conexión: SUPABASE_DB_URL en .env (no se sube a git) o se pide sin eco.
# Usa el "Session pooler" (IPv4) de Supabase → botón Connect → Session pooler:
#   postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres
#
# Uso:
#   ./scripts/correr_migraciones.sh            # aplica las pendientes
#   ./scripts/correr_migraciones.sh --estado   # solo muestra qué está aplicado y qué falta
#   ./scripts/correr_migraciones.sh --seed     # aplica pendientes y carga datos de ejemplo
set -euo pipefail
cd "$(dirname "$0")/.."

MIGRATIONS_DIR=supabase/migrations
SEED_FILE=supabase/seed.sql
PSQL_IMAGE=postgres:17-alpine
LOCK_KEY=72684801   # constante arbitraria para pg_advisory_xact_lock

mode=apply
seed=false
for arg in "$@"; do
  case "$arg" in
    --estado) mode=status ;;
    --seed)   seed=true ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "${SUPABASE_DB_URL:-}" && -f .env ]]; then
  SUPABASE_DB_URL="$(grep -E '^SUPABASE_DB_URL=' .env | cut -d= -f2- || true)"
fi
if [[ -z "${SUPABASE_DB_URL:-}" ]]; then
  read -rsp "Cadena de conexión (Session pooler) de Supabase: " SUPABASE_DB_URL; echo
fi
export SUPABASE_DB_URL

# psql desde contenedor: no hace falta instalar el cliente. La URL viaja como
# variable de entorno (no aparece en la lista de procesos) y el SQL por stdin.
psql_run() {
  docker run --rm -i -e SUPABASE_DB_URL "$PSQL_IMAGE" \
    sh -c 'exec psql "$SUPABASE_DB_URL" -X -q -v ON_ERROR_STOP=1 "$@"' psql "$@"
}

psql_run -c "
  set client_min_messages = warning;
  create schema if not exists supabase_migrations;
  create table if not exists supabase_migrations.schema_migrations (
    version    text primary key,
    statements text[],
    name       text
  );" >/dev/null

# version|md5 de lo ya aplicado.
declare -A applied
while IFS='|' read -r version hash; do
  [[ -n "$version" ]] && applied["$version"]="$hash"
done < <(psql_run -At -c "
  select version, md5(coalesce(array_to_string(statements, ''), ''))
    from supabase_migrations.schema_migrations")

pending=()
errors=0
for file in "$MIGRATIONS_DIR"/*.sql; do
  base="$(basename "$file" .sql)"
  version="${base%%_*}"
  name="${base#*_}"
  hash="$(md5sum "$file" | cut -d' ' -f1)"

  if [[ -n "${applied[$version]:-}" ]]; then
    if [[ "${applied[$version]}" == "$hash" ]]; then
      printf '  ✓ %s  %s\n' "$version" "$name"
    else
      printf '  ✗ %s  %s  CAMBIÓ después de aplicarse\n' "$version" "$name"
      errors=$((errors + 1))
    fi
  else
    printf '  · %s  %s  pendiente\n' "$version" "$name"
    pending+=("$file")
  fi
done

if (( errors > 0 )); then
  echo "Hay migraciones aplicadas que se modificaron. No se aplicó nada." >&2
  echo "Revierte el cambio en el archivo y pon la corrección en una migración nueva." >&2
  exit 1
fi

[[ "$mode" == status ]] && exit 0

for file in "${pending[@]}"; do
  base="$(basename "$file" .sql)"
  version="${base%%_*}"
  name="${base#*_}"
  # Delimitador dollar-quote que no aparece en el archivo.
  tag="h4u_$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  if grep -q "\$$tag\$" "$file"; then echo "Colisión de delimitador, reintenta." >&2; exit 1; fi

  echo "→ Aplicando $version $name"
  {
    echo "select pg_advisory_xact_lock($LOCK_KEY);"
    echo "do \$g\$ begin
            if exists (select 1 from supabase_migrations.schema_migrations where version = '$version') then
              raise exception 'La migración % ya la aplicó otra ejecución', '$version';
            end if;
          end \$g\$;"
    cat "$file"
    echo
    printf "insert into supabase_migrations.schema_migrations (version, name, statements)\n"
    printf "values ('%s', '%s', array[\$%s\$" "$version" "$name" "$tag"
    cat "$file"
    printf "\$%s\$]);\n" "$tag"
  } | psql_run --single-transaction >/dev/null
  echo "  ✓ $version aplicada"
done
(( ${#pending[@]} == 0 )) && echo "Sin migraciones pendientes."

if [[ "$seed" == true ]]; then
  count="$(psql_run -At -c "select count(*) from public.properties")"
  if [[ "$count" != "0" ]]; then
    echo "Seed omitido: properties ya tiene $count registros (no se duplican datos)."
  else
    echo "→ Cargando datos de ejemplo"
    psql_run --single-transaction < "$SEED_FILE" >/dev/null
    echo "  ✓ seed cargado"
  fi
fi
