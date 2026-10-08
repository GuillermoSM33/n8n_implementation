"""Prueba de punta a punta del MVP, haciendo las mismas llamadas que la app.

Corre contra Supabase, n8n, Gemini y WhatsApp reales: envía 5 WhatsApp de verdad
(3 asignaciones y 2 alertas) a los teléfonos de los responsables y del operador.
Se invoca desde scripts/prueba_e2e.sh, que toma la configuración de .env.

Para no esperar 30 minutos, los escalamientos se simulan adelantando el reloj por SQL
(created_at / assigned_at - 31 min) con la conexión de administración.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

SB, KEY, N8N = os.environ['SB_URL'], os.environ['SB_KEY'], os.environ['N8N_URL'].rstrip('/')
EMAIL, PW = os.environ['E2E_EMAIL'], os.environ['E2E_PASSWORD']
ok_count = fail_count = 0
created = []  # ids de las incidencias creadas por esta corrida


def http(method, url, body=None, headers=None, timeout=40):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, method=method, data=data,
                                 headers={'Content-Type': 'application/json', **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read().decode()
            return r.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        try:
            return e.code, json.loads(text)
        except ValueError:
            return e.code, text


def check(name, cond, detail=''):
    global ok_count, fail_count
    if cond:
        ok_count += 1
        print(f'  ✓ {name}')
    else:
        fail_count += 1
        print(f'  ✗ {name}  {detail}')


def sql(query):
    # Mismo camino que los scripts de bash: psql local o contenedor (scripts/_psql.sh).
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run(['bash', '-c', f'source "{here}/_psql.sh" && psql_run -At'],
                       input=query, text=True, capture_output=True)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()


def wait_notice(incident_id, kind, timeout=90):
    """Espera a que n8n procese el aviso (sent/failed/skipped) y devuelve 'estado (segundos)'."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = sql(f"""select status from public.notification_outbox
                      where incident_id = '{incident_id}' and kind = '{kind}' order by id desc limit 1""")
        if st in ('sent', 'failed', 'skipped'):
            return f'aviso de {kind}: {st} en {time.time() - t0:.1f} s'
        time.sleep(1)
    return f'aviso de {kind}: sin procesar tras {timeout} s'


def now_iso():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


print('1. Sesión y permisos')
st, auth = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'email': EMAIL, 'password': PW}, {'apikey': KEY})
check(f'login como {EMAIL}', st == 200 and isinstance(auth, dict) and 'access_token' in auth, st)
if fail_count:
    sys.exit(1)
H = {'apikey': KEY, 'Authorization': f"Bearer {auth['access_token']}"}
RET = {'Prefer': 'return=representation'}


def rest(method, path, body=None, extra=None):
    return http(method, f'{SB}/rest/v1/{path}', body, {**H, **(extra or {})})


def create(body):
    st, rows = rest('POST', 'incidents?select=id,folio', body, RET)
    if st != 201:
        raise RuntimeError(f'No se pudo crear la incidencia: {st} {rows}')
    created.append(rows[0]['id'])
    # Se guarda en cada alta: si la prueba se cae a la mitad, la limpieza sabe qué borrar.
    with open(os.environ['E2E_IDS_FILE'], 'w') as f:
        f.write('\n'.join(created))
    return rows[0]


st, anon = http('GET', f'{SB}/rest/v1/incidents?select=id', headers={'apikey': KEY})
check('sin sesión no se lee nada (RLS)', st in (401, 403) or anon == [], (st, anon))
props = {p['name']: p['id'] for p in rest('GET', 'properties?select=id,name&active=eq.true')[1]}
people = {a['name']: a['id'] for a in rest('GET', 'assignees?select=id,name&active=eq.true')[1]}
st, cfg = rest('GET', 'app_config?select=value&key=eq.n8n_url')
check('la app obtiene la URL de n8n de app_config', bool(cfg) and cfg[0]['value'].rstrip('/') == N8N, cfg)

print('2. Triaje con IA')
text = 'Huele a gas en la cocina, nos da miedo prender la estufa'
t0 = time.time()
st, sug = http('POST', f'{N8N}/webhook/h4u-triaje', {'text': text, 'property_id': props['Loft Centro']},
               {'Authorization': H['Authorization']}, timeout=60)
check(f'respuesta 200 en {time.time() - t0:.1f} s', st == 200, (st, sug))
if st != 200:
    sys.exit(1)
print(f"    → {sug['category']} · {sug['priority']} · {sug['assignee_name']} · confianza {sug['confidence']}"
      f" · {sug['model']} · reglas {sug['guards']}")
check('gas → prioridad alta', sug['priority'] == 'alta')
check('el responsable sugerido sale del catálogo', sug['assignee_id'] in people.values() or sug['assignee_id'] is None)
st, _ = http('POST', f'{N8N}/webhook/h4u-triaje', {'text': text, 'property_id': props['Loft Centro']},
             {'Authorization': 'Bearer token-invalido'})
check('sesión inválida → 401 (no se llama a Gemini)', st == 401, st)

print('3. Alta con la sugerencia aplicada y asignación (→ WhatsApp)')
inc1 = create({'property_id': props['Loft Centro'], 'channel': 'whatsapp', 'unit': 'Loft',
               'reporter_name': 'Huésped de prueba', 'description': text,
               'category': sug['category'], 'priority': sug['priority'],
               'assignee_id': sug['assignee_id'] or people['Carlos Ruiz'], 'ai_suggestion': {**sug, 'applied': True}})
check(f"{inc1['folio']} creada", True)
st, dup = rest('GET', f"incidents?select=folio&property_id=eq.{props['Loft Centro']}"
                      f"&category=eq.{sug['category']}&status=in.(reportado,en_seguimiento)")
check('posible duplicado detectado', any(d['folio'] == inc1['folio'] for d in dup or []), dup)

print('4. Reglas de la base de datos')
inc2 = create({'property_id': props['Casa Coral'], 'channel': 'llamada', 'unit': 'Unidad 3',
               'description': 'No sale agua caliente', 'category': 'agua'})
for values, expected, name in [
    ({'status': 'en_seguimiento'}, 'Asigna un responsable', 'sin responsable no pasa a En seguimiento'),
    ({'status': 'atendido'}, 'nota de resolución', 'sin nota no se marca Atendido'),
    ({'status': 'descartado'}, 'motivo', 'sin motivo no se descarta'),
]:
    st, e = rest('PATCH', f"incidents?id=eq.{inc2['id']}", values)
    check(name, st >= 400 and expected in str(e), (st, e))

print('5. Historial')
st, _ = rest('POST', 'incident_events', {'incident_id': inc2['id'], 'type': 'comentario',
                                         'detail': 'El huésped llamó otra vez'})
check('comentario guardado', st == 201, st)
st, ev = rest('GET', f"incident_events?select=author&incident_id=eq.{inc2['id']}&type=eq.comentario")
check(f'autor = {EMAIL} (lo pone la base, no la pantalla)', bool(ev) and ev[0]['author'] == EMAIL, ev)
st, _ = rest('POST', 'incident_events', {'incident_id': inc2['id'], 'type': 'comentario', 'detail': 'x',
                                         'author': 'otra.persona@ejemplo.com'})
check('no se puede firmar como otra persona', st >= 400, st)

print('6. Flujo completo: asignar (→ WhatsApp), seguimiento, confirmación y cierre')
st, _ = rest('PATCH', f"incidents?id=eq.{inc2['id']}", {'assignee_id': people['Plomería Express']})
check('asignada', st in (200, 204), st)
# Como un operador real: el aviso sale antes de cerrar. Si se cierra antes de que n8n lo
# procese, n8n lo omite a propósito ("La incidencia ya está atendido") y no se avisa a nadie.
print(f"    {wait_notice(inc2['id'], 'asignacion')}")
st, _ = rest('PATCH', f"incidents?id=eq.{inc2['id']}", {'status': 'en_seguimiento'})
check('ahora sí pasa a En seguimiento', st in (200, 204), st)
st, _ = rest('PATCH', f"incidents?id=eq.{inc1['id']}", {'acknowledged_at': now_iso()})
check('"Responsable confirmó"', st in (200, 204), st)
st, _ = rest('PATCH', f"incidents?id=eq.{inc2['id']}",
             {'status': 'atendido', 'resolution_note': 'Se cambió la resistencia del boiler'})
check('Atendido con nota', st in (200, 204), st)

print('7. Escalamientos (reloj adelantado 31 min por SQL)')
inc3 = create({'property_id': props['Villa Laguna'], 'channel': 'airbnb', 'priority': 'alta',
               'description': 'La puerta principal no cierra con llave', 'category': 'cerraduras'})
inc4 = create({'property_id': props['Departamentos Sol'], 'channel': 'sms', 'unit': 'Depto 2',
               'description': 'El minisplit gotea agua', 'category': 'climatizacion',
               'assignee_id': people['Climas del Caribe']})
sql(f"""update public.incidents set created_at  = now() - interval '31 minutes' where id = '{inc3['id']}';
        update public.incidents set assigned_at = now() - interval '31 minutes' where id = '{inc4['id']}';""")
st, att = rest('GET', f"incidents_with_attention?select=folio,attention_reasons&id=in.({inc3['id']},{inc4['id']})")
reasons = {a['folio']: a['attention_reasons'] for a in att or []}
check(f"{inc3['folio']} en rojo: sin responsable", 'Más de 30 min sin responsable' in reasons.get(inc3['folio'], []), reasons)
check(f"{inc4['folio']} en rojo: sin confirmación",
      any('no ha confirmado' in r for r in reasons.get(inc4['folio'], [])), reasons)

print('8. WhatsApp (asignación ×3, alerta ×2); el barrido corre cada minuto')
ids = ','.join(f"'{i}'" for i in created)
rows = []
deadline = time.time() + 150
while time.time() < deadline:
    out = sql(f"""select i.folio || '|' || o.kind || '|' || o.status || '|' || coalesce(left(o.last_error, 70), '')
                    from public.notification_outbox o join public.incidents i on i.id = o.incident_id
                   where o.incident_id in ({ids}) order by o.id""")
    rows = [r.split('|') for r in out.splitlines() if r]
    if len(rows) >= 5 and all(r[2] in ('sent', 'failed', 'skipped') for r in rows):
        break
    time.sleep(5)
for r in rows:
    print(f'    {r[0]} {r[1]:17} {r[2]:8} {r[3]}')
check('5 avisos aceptados por Meta', len(rows) == 5 and all(r[2] == 'sent' for r in rows))

print('9. Descarte y línea de tiempo')
st, _ = rest('PATCH', f"incidents?id=eq.{inc3['id']}",
             {'status': 'descartado', 'discard_reason': 'Duplicado de un reporte por teléfono'})
check('Descartado con motivo', st in (200, 204), st)
st, tl = rest('GET', f"incident_events?select=type,author&incident_id=eq.{inc2['id']}&order=id")
print(f"    {inc2['folio']}: " + ' → '.join(f"{t['type']}({t['author'].split('@')[0]})" for t in tl or []))
check('la línea de tiempo incluye el aviso de n8n', any(t['type'] == 'aviso' for t in tl or []))

print(f'\nResultado: {ok_count} OK, {fail_count} fallas')
sys.exit(1 if fail_count else 0)
