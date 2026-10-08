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

## Verificado contra el ambiente real (2026-10-08)
Supabase (proyecto H4U), n8n 2.43.1 en Docker detrás del túnel de Cloudflare, Gemini y
WhatsApp Cloud API (número de prueba). Se repite con:

```bash
./scripts/prueba_e2e.sh          # pide la contraseña de evaluador@h4u.demo; envía 5 WhatsApp reales
```

Hace las mismas llamadas que la app (REST de Supabase con la sesión del operador y el
webhook de triaje) y al final borra solo lo que creó. Resultado: **24/24**.

- [x] Sin sesión no se lee nada; la app toma la URL de n8n de `app_config`
- [x] Triaje con Gemini real: "Huele a gas…" → Gas, Alta, responsable del catálogo; sesión inválida → 401
- [x] Si el modelo principal responde 503 (saturado), contesta el de respaldo (`GEMINI_FALLBACK_MODEL`)
- [x] Alta con la sugerencia aplicada (`ai_suggestion.applied = true`) y aviso de posible duplicado
- [x] Las 3 reglas de la base de datos devuelven su mensaje en español
- [x] Comentario firmado con el correo de la sesión; firmar como otra persona → rechazado
- [x] Asignar → En seguimiento → "Responsable confirmó" → Atendido con nota → Descartado con motivo
- [x] Escalamientos (reloj adelantado 31 min por SQL): fila en rojo y alerta por WhatsApp,
      tanto "sin responsable" como "el responsable no ha confirmado"
- [x] 5 WhatsApp aceptados por Meta (3 asignaciones, 2 alertas) y recibidos en el teléfono;
      el aviso aparece en la línea de tiempo como evento de n8n
- [x] Si la incidencia se cierra antes de que salga el aviso de asignación, n8n lo omite
      ("La incidencia ya está atendido"): no se avisa por algo ya resuelto
- [x] Lovable (probado a mano en la vista previa): login, lista, alta con sugerencia de IA, detalle,
      asignación con WhatsApp y línea de tiempo. El sitio publicado contiene el mismo código
      (revisado en sus bundles)

## Limitaciones conocidas
- "Enviado" significa **aceptado por Meta**, no entregado: no está configurado el webhook de
  estados de WhatsApp (entregado / leído / fallido).
- El túnel rápido de Cloudflare es efímero; si cae, `./scripts/actualizar_tunel.sh` lo recupera
  y propaga la URL nueva (Vault y `app_config`) sin tocar el frontend.
