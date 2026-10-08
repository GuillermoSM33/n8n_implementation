-- Corrige claim_notification:
--   1. Las alertas de escalamiento (sin_confirmacion, sin_responsable) se encolan sin
--      assignee_id, así que el nombre del responsable salía nulo ("sin asignar") aunque
--      la incidencia sí tuviera uno. Ahora, si el aviso no trae responsable, se usa el
--      actual de la incidencia. Los avisos de asignación siguen usando el de la fila
--      (es a quien se le debe avisar, aunque luego se reasigne).
--   2. unit ya no se rellena con '-': el formato lo decide quien arma el mensaje.
-- create or replace conserva los permisos (solo service_role).

create or replace function public.claim_notification(p_outbox_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.notification_outbox;
  v_result jsonb;
begin
  update public.notification_outbox o
     set status = 'processing', attempts = o.attempts + 1, locked_at = now()
   where o.id = p_outbox_id
     and o.attempts < 5
     and (o.status = 'pending'
          or (o.status = 'processing' and o.locked_at < now() - interval '5 minutes'))
  returning o.* into v_row;

  if not found then
    -- Ya enviado, en proceso por otra ejecución, o agotó reintentos.
    return jsonb_build_object('claimed', false, 'outbox_id', p_outbox_id);
  end if;

  select jsonb_build_object(
           'claimed',        true,
           'outbox_id',      v_row.id,
           'kind',           v_row.kind,
           'folio',          i.folio,
           'incident_id',    i.id,
           'property',       p.name,
           'unit',           i.unit,
           'category',       i.category,
           'priority',       i.priority,
           'status',         i.status,
           'description',    left(i.description, 300),
           'assignee_name',  a.name,
           'assignee_phone', a.phone,
           'assignee_active', a.active,
           'still_assigned', (v_row.assignee_id is null or i.assignee_id = v_row.assignee_id)
         )
    into v_result
    from public.incidents i
    join public.properties p on p.id = i.property_id
    left join public.assignees a on a.id = coalesce(v_row.assignee_id, i.assignee_id)
   where i.id = v_row.incident_id;

  return v_result;
end;
$$;
