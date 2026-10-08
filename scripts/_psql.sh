# shellcheck shell=bash
# Helper compartido: ejecuta psql contra SUPABASE_DB_URL. Se usa con `source`.
#
#   - Si hay psql local (apt install postgresql-client), lo usa.
#   - Si no, usa psql dentro de un contenedor postgres:17-alpine (requiere Docker).
#
# La cadena de conexión nunca va en la línea de comandos (visible con `ps`):
# con psql local se descompone en variables PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE;
# con Docker viaja como variable de entorno del contenedor.
#
# Requiere SUPABASE_DB_URL exportada antes de llamar a psql_run.

PSQL_IMAGE="${PSQL_IMAGE:-postgres:17-alpine}"

_psql_env_ready=false
_psql_export_env() {
  [[ "$_psql_env_ready" == true ]] && return
  local assignments
  # urllib.parse decodifica la contraseña si trae caracteres escapados (%40, etc.).
  assignments="$(python3 -I - <<'PY'
import os, shlex, urllib.parse as u
p = u.urlsplit(os.environ['SUPABASE_DB_URL'])
q = dict(u.parse_qsl(p.query))
env = {
    'PGHOST': p.hostname or '',
    'PGPORT': str(p.port or 5432),
    'PGUSER': u.unquote(p.username or ''),
    'PGPASSWORD': u.unquote(p.password or ''),
    'PGDATABASE': u.unquote(p.path.lstrip('/')) or 'postgres',
    'PGSSLMODE': q.get('sslmode', 'require'),
}
print('\n'.join(f'export {k}={shlex.quote(v)}' for k, v in env.items()))
PY
)"
  eval "$assignments"
  _psql_env_ready=true
}

# Uso igual que psql: psql_run -c "select 1"   |   psql_run --single-transaction < archivo.sql
psql_run() {
  : "${SUPABASE_DB_URL:?Falta SUPABASE_DB_URL}"
  if command -v psql >/dev/null 2>&1; then
    _psql_export_env
    psql -X -q -v ON_ERROR_STOP=1 "$@"
  elif docker info >/dev/null 2>&1; then
    docker run --rm -i -e SUPABASE_DB_URL "$PSQL_IMAGE" \
      sh -c 'exec psql "$SUPABASE_DB_URL" -X -q -v ON_ERROR_STOP=1 "$@"' psql "$@"
  else
    echo "No hay psql local ni Docker. Instala el cliente: sudo apt install postgresql-client" >&2
    return 1
  fi
}
