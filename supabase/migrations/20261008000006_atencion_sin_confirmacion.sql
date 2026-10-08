-- "Requiere atención" también cuando el responsable no confirma en 30 min.
-- Antes, n8n mandaba la alerta "el responsable no ha confirmado" pero la fila no se
-- marcaba en rojo: el WhatsApp y la pantalla decían cosas distintas. Ahora la vista
-- usa la misma condición que enqueue_escalations (asignada, abierta, sin acknowledged_at).
-- Mismas columnas y en el mismo orden: create or replace conserva los permisos.

create or replace view public.incidents_with_attention
with (security_invoker = true)
as
select
  i.*,
  p.name as property_name,
  a.name as assignee_name,
  (
    (i.status = 'reportado' and i.assignee_id is null and i.created_at < now() - interval '30 minutes')
    or (i.status in ('reportado', 'en_seguimiento') and i.assignee_id is not null
        and i.acknowledged_at is null and i.assigned_at < now() - interval '30 minutes')
    or (i.priority = 'alta' and i.status not in ('atendido', 'descartado'))
    or (i.updated_at < now() - interval '24 hours' and i.status not in ('atendido', 'descartado'))
  ) as requires_attention,
  array_remove(array[
    case when i.status = 'reportado' and i.assignee_id is null
              and i.created_at < now() - interval '30 minutes'
         then 'Más de 30 min sin responsable' end,
    case when i.status in ('reportado', 'en_seguimiento') and i.assignee_id is not null
              and i.acknowledged_at is null and i.assigned_at < now() - interval '30 minutes'
         then 'El responsable no ha confirmado (más de 30 min)' end,
    case when i.priority = 'alta' and i.status not in ('atendido', 'descartado')
         then 'Prioridad alta abierta' end,
    case when i.updated_at < now() - interval '24 hours' and i.status not in ('atendido', 'descartado')
         then 'Más de 24 h sin movimiento' end
  ], null) as attention_reasons
from public.incidents i
join public.properties p on p.id = i.property_id
left join public.assignees a on a.id = i.assignee_id;
