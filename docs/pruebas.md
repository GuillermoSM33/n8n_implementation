# Pruebas

## Lo que ya se probó (2026-10-07, en local)
Entorno: Postgres 17 con las migraciones y el seed, PostgREST como sustituto de la API REST
de Supabase, n8n 2.43.1 con los workflows del repo, y un mock de la WhatsApp Cloud API.
Supabase real aporta `auth`, `vault` y `pg_net`; en local se sustituyeron por equivalentes
mínimos.

**Reglas de negocio (base de datos)**
- [x] En seguimiento sin responsable → `Asigna un responsable antes de pasar a En seguimiento`
- [x] Atendido sin nota → `Escribe la nota de resolución antes de marcar como Atendido`
- [x] El historial registra estado y asignación con el correo del operador como autor
- [x] Un comentario con `author` ajeno es rechazado por RLS; sin `author` toma el del JWT
- [x] Reasignar reinicia `acknowledged_at`
- [x] `anon` no puede leer incidencias; `authenticated` no puede leer la cola ni llamar sus RPC

**Automatización (n8n)**
- [x] Webhook sin `X-H4U-Secret` → 403
- [x] Asignación → WhatsApp al responsable con la plantilla y 6 parámetros → `sent` + evento "aviso" en el historial
- [x] El mismo webhook dos veces → un solo mensaje (idempotencia)
- [x] Meta rechaza (número no verificado) → vuelve a `pending` y el barrido lo reintenta
- [x] Responsable sin teléfono → `skipped` con el motivo
- [x] Asignada y sin confirmar > 30 min → el barrido encola y envía la alerta al operador

**Triaje con IA (n8n + mock de Gemini)**
- [x] Respuesta normal → sugerencia con responsable del catálogo y duplicado detectado (INC abierta de la misma propiedad)
- [x] "Huele a gas" con prioridad media del modelo → la guarda la sube a alta y lo reporta en `guards`
- [x] Prompt injection / responsable inventado / folio inexistente → responsable null, duplicado null, baja confianza
- [x] Respuesta no JSON → 502; Gemini caído (tras reintento) → 502
- [x] Token inválido o ausente → 401 sin llamar a Gemini; sin propiedad → 400; propiedad inexistente → 404
- [x] CORS: preflight 204 con `Access-Control-Allow-Origin` para el dominio de Lovable

**Scripts**
- [x] `correr_migraciones.sh`: aplica desde cero; segunda corrida no hace nada; migración nueva se aplica sola;
  migración aplicada y editada → se detiene sin aplicar nada; migración que falla a la mitad no deja rastro;
  `--seed` con datos existentes se omite
- [x] `n8n-bootstrap.sh`: crea credenciales de relleno, importa y publica 4 workflows; segunda corrida no pisa credenciales

## Pendiente contra Supabase y Meta reales
- [ ] `pg_net` llega al webhook a través del túnel (ver `select * from net._http_response order by id desc limit 5;`)
- [ ] Un WhatsApp real llega al teléfono verificado
- [ ] Gemini real con `GEMINI_MODEL=gemini-2.5-flash` (confirmar que el modelo está disponible para la API key)
- [ ] Lovable: login, lista, alta con aviso de duplicado, detalle, errores de la base de datos en un toast
