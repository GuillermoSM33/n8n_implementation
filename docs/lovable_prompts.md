# Prompts de Lovable (adaptados al backend de este repo)

Antes del prompt 1: en Lovable → **Integrations → Supabase → conectar el proyecto `H4U`
existente**. Las tablas, reglas y datos de ejemplo ya están creados por
`supabase/migrations` y `supabase/seed.sql`: Lovable **no debe crear ni modificar tablas**.
Si Lovable propone una migración, rechazarla.

Después de cada prompt, probar en la vista previa antes de seguir.

---

## Prompt 1: login y lista de incidencias

```
Construye una app web en español para que un operador gestione incidencias de mantenimiento de
propiedades en Airbnb. Usa el proyecto de Supabase ya conectado.

IMPORTANTE: la base de datos ya existe y tiene reglas propias. NO crees, alteres ni borres
tablas, vistas, funciones ni políticas. NO generes migraciones. Solo lee y escribe datos con
supabase-js.

Autenticación: pantalla de login con correo y contraseña (Supabase Auth). Sin registro público.
Toda la app requiere sesión; la anon key sola no tiene permisos.

Esquema existente (solo lectura de estructura):
- properties(id, name, city, notes, active)
- assignees(id, name, role: anfitrion|gerente|tecnico|proveedor, phone, active)
- incidents(id, folio, property_id, unit, channel: whatsapp|airbnb|sms|llamada, reporter_name,
  reporter_contact, description, category: agua|electricidad|gas|climatizacion|cerraduras|
  electrodomesticos|limpieza|otro, priority: alta|media|baja,
  status: reportado|en_seguimiento|atendido|descartado, assignee_id, resolution_note,
  discard_reason, ai_suggestion, created_at, assigned_at, acknowledged_at, resolved_at, updated_at)
- incident_events(id, incident_id, type, detail, author, created_at)
- Vista incidents_with_attention: todas las columnas de incidents + property_name,
  assignee_name, requires_attention (boolean) y attention_reasons (text[]).

Pantalla principal "Incidencias": lee de la vista incidents_with_attention.
- Tabla: folio, propiedad, unidad, canal (con ícono), categoría, prioridad (badge: alta rojo,
  media ámbar, baja gris), estado, responsable, antigüedad ("hace 2 h").
- Si requires_attention es true: fila resaltada en rojo y un badge "Requiere atención" con
  attention_reasons en un tooltip. Por defecto, esas van primero.
- Filtros por estado, propiedad, prioridad y canal, y un buscador por folio o descripción.
- Contadores arriba: Reportadas, En seguimiento, Requieren atención, Atendidas hoy.
- Refrescar cada 30 segundos.
```

## Prompt 2: alta, detalle y catálogos

```
1. "Nueva incidencia": formulario con propiedad (select, obligatorio), unidad, canal
   (obligatorio), nombre y contacto del huésped, descripción (obligatoria), categoría y
   prioridad. No envíes folio, status ni fechas: los pone la base de datos.
   Antes de guardar, busca en incidents otra con la misma property_id y category y status
   reportado o en_seguimiento. Si existe, muestra "Posible duplicado: INC-00XX" con las
   opciones "Ver existente", "Agregar como comentario a la existente" o "Crear de todos modos".

2. "Detalle de incidencia":
   - Todos los datos. Selector de responsable (solo assignees activos) y de prioridad.
   - Botones de estado: "En seguimiento", "Atendido" (pide la nota de resolución en un modal y
     la guarda en resolution_note en el MISMO update que el status), "Descartar" (pide el
     motivo y lo guarda en discard_reason en el mismo update).
   - Botón "Responsable confirmó" visible si hay responsable y acknowledged_at está vacío:
     hace update de acknowledged_at = now(). Muestra "Confirmado hace X" cuando ya tiene valor.
   - Línea de tiempo con incident_events ordenada por fecha, con ícono por type
     (creado, comentario, cambio_estado, asignacion, cambio_prioridad, confirmacion, aviso).
     Los de type "aviso" son los WhatsApp que envió la automatización: muéstralos con ícono
     de WhatsApp.
   - Campo para agregar comentario: insert en incident_events con incident_id, type
     'comentario' y detail. No envíes author: lo pone la base de datos.
   - Si Supabase rechaza un cambio, muestra el campo "message" del error tal cual en un toast
     (la base de datos ya devuelve mensajes en español, por ejemplo "Asigna un responsable
     antes de pasar a En seguimiento").

3. Catálogos "Propiedades" y "Responsables": lista, alta, edición y activar/desactivar
   (nunca borrar). En responsables, el teléfono es opcional y va en formato 5219981234567
   (sin +, sin espacios); valida ese formato en el formulario.
```

## Prompt 3 (opcional): IA de triaje
Pendiente de decidir si se implementa como workflow de n8n con Gemini o como Edge Function.
La columna `incidents.ai_suggestion` ya existe para guardar la sugerencia original.
