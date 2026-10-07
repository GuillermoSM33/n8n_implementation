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

## Pendiente contra Supabase y Meta reales
- [ ] `pg_net` llega al webhook a través del túnel (ver `select * from net._http_response order by id desc limit 5;`)
- [ ] Un WhatsApp real llega al teléfono verificado
- [ ] Lovable: login, lista, alta con aviso de duplicado, detalle, errores de la base de datos en un toast
