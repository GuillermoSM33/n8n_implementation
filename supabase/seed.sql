-- =============================================================================
-- Datos de ejemplo para el demo. Los nombres son ficticios.
-- Los teléfonos van vacíos: pon en assignees.phone los números que verificaste
-- en el número de prueba de WhatsApp (máximo 5), en formato 5219981234567.
-- =============================================================================

-- Cargar sin encolar avisos de WhatsApp.
select set_config('app.skip_notifications', 'on', false);

insert into public.properties (name, city, notes) values
  ('Casa Coral',        'Cancún',          'Zona hotelera, 3 unidades'),
  ('Loft Centro',       'Mérida',          'Edificio con portero'),
  ('Villa Laguna',      'Bacalar',         'Acceso por camino de terracería'),
  ('Departamentos Sol', 'Playa del Carmen','8 unidades, administración en sitio');

insert into public.assignees (name, role) values
  ('Laura Méndez',          'anfitrion'),
  ('Carlos Ruiz',           'gerente'),
  ('Técnico Pedro Chan',    'tecnico'),
  ('Plomería Express',      'proveedor'),
  ('Climas del Caribe',     'proveedor');

insert into public.incidents
  (property_id, unit, channel, reporter_name, reporter_contact, description, category, priority, status,
   assignee_id, resolution_note, discard_reason, created_at)
select p.id, v.unit, v.channel, v.reporter_name, v.reporter_contact, v.description, v.category, v.priority,
       v.status, a.id, v.resolution_note, v.discard_reason, now() - v.age
from (values
  ('Casa Coral',        'Unidad 3', 'whatsapp', 'Ana G.',    '+52 998 000 0001', 'No sale agua caliente en la unidad 3',            'agua',              'media', 'reportado',      null,                 null, null, interval '45 minutes'),
  ('Loft Centro',       'Loft',     'airbnb',   'John D.',   'airbnb:thread-1',  'Huele a gas en la cocina',                         'gas',               'alta',  'en_seguimiento', 'Carlos Ruiz',        null, null, interval '20 minutes'),
  ('Villa Laguna',      'Casa',     'llamada',  'María P.',  '+52 983 000 0002', 'El aire acondicionado de la recámara no enfría',   'climatizacion',     'media', 'en_seguimiento', 'Climas del Caribe',  null, null, interval '3 hours'),
  ('Departamentos Sol', 'Depto 5',  'sms',      'Luis R.',   '+52 984 000 0003', 'La cerradura electrónica no abre con el código',  'cerraduras',        'alta',  'reportado',      null,                 null, null, interval '10 minutes'),
  ('Casa Coral',        'Unidad 1', 'airbnb',   'Emma S.',   'airbnb:thread-2',  'El refrigerador hace mucho ruido',                 'electrodomesticos', 'baja',  'atendido',       'Técnico Pedro Chan', 'Se niveló el refrigerador y se limpió el ventilador', null, interval '2 days'),
  ('Departamentos Sol', 'Depto 2',  'whatsapp', 'Pablo T.',  '+52 984 000 0004', 'Se fue la luz en la cocina',                       'electricidad',      'media', 'en_seguimiento', 'Técnico Pedro Chan', null, null, interval '30 hours'),
  ('Loft Centro',       'Loft',     'llamada',  'Sofía L.',  '+52 999 000 0005', 'Falta papel de baño',                              'limpieza',          'baja',  'descartado',     null,                 null, 'No es una falla de mantenimiento; se canalizó a limpieza', interval '1 day'),
  ('Villa Laguna',      'Casa',     'whatsapp', 'Diego M.',  '+52 983 000 0006', 'Gotea la llave del lavabo del baño principal',     'agua',              'baja',  'reportado',      null,                 null, null, interval '5 minutes')
) as v(property, unit, channel, reporter_name, reporter_contact, description, category, priority, status,
       assignee, resolution_note, discard_reason, age)
join public.properties p on p.name = v.property
left join public.assignees a on a.name = v.assignee
order by v.age desc;  -- folios en orden cronológico

-- El historial de los datos de ejemplo hereda la fecha simulada de cada incidencia.
update public.incident_events e
   set created_at = i.created_at
  from public.incidents i
 where e.incident_id = i.id;

-- assigned_at también la puso el trigger con now(); se alinea con la fecha simulada.
-- Las incidencias asignadas hace más de una hora ya fueron confirmadas por su responsable;
-- la de gas (20 min) queda sin confirmar para que el demo muestre el escalamiento.
alter table public.incidents disable trigger incidents_enforce_rules;
alter table public.incidents disable trigger incidents_log_events;
update public.incidents
   set assigned_at     = case when assignee_id is not null then created_at end,
       acknowledged_at = case when assignee_id is not null and created_at < now() - interval '1 hour'
                              then created_at + interval '10 minutes' end,
       resolved_at     = case when status = 'atendido' then created_at + interval '4 hours' end,
       updated_at      = case when status = 'atendido' then created_at + interval '4 hours' else created_at end;
alter table public.incidents enable trigger incidents_log_events;
alter table public.incidents enable trigger incidents_enforce_rules;

select set_config('app.skip_notifications', 'off', false);
