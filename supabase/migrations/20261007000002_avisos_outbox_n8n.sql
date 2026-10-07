-- =============================================================================
-- Avisos por WhatsApp vía n8n: patrón outbox.
--
-- 1. Un trigger escribe el aviso en notification_outbox con una dedupe_key única
--    (idempotencia: el mismo evento nunca genera dos avisos).
-- 2. Al insertarse, pg_net hace POST al webhook de n8n con solo el id del aviso.
--    Si n8n está caído o el túnel cambió de URL, el aviso queda 'pending' y el
--    barrido programado de n8n lo recoge: el webhook acelera, no es la fuente de verdad.
-- 3. n8n "reclama" el aviso con claim_notification() (bloqueo optimista), lo envía
--    y lo cierra con complete_notification().
--
-- La URL y el secreto del webhook viven en Supabase Vault, no en este archivo:
--   select vault.create_secret('<url>/webhook/h4u-aviso', 'n8n_webhook_url');
--   select vault.create_secret('<secreto>',               'n8n_webhook_secret');
-- =============================================================================

create extension if not exists pg_net;

create table public.notification_outbox (
  id           bigint generated always as identity primary key,
  incident_id  uuid not null references public.incidents (id) on delete cascade,
  kind         text not null check (kind in ('asignacion', 'sin_responsable', 'sin_confirmacion')),
  -- Responsable al que va el aviso; null = va al operador de guardia.
  assignee_id  uuid references public.assignees (id),
  dedupe_key   text not null unique,
  status       text not null default 'pending'
               check (status in ('pending', 'processing', 'sent', 'failed', 'skipped')),
  attempts     int not null default 0,
  last_error   text,
  locked_at    timestamptz,
  sent_at      timestamptz,
  created_at   timestamptz not null default now()
);

create index notification_outbox_pending_idx on public.notification_outbox (created_at)
  where status in ('pending', 'processing');

-- Solo service_role (n8n) toca la cola. RLS activo y sin políticas = nadie más.
alter table public.notification_outbox enable row level security;
revoke all on public.notification_outbox from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Encolar aviso al asignar o reasignar responsable
-- -----------------------------------------------------------------------------
create or replace function public.incidents_enqueue_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Los datos de ejemplo se cargan sin avisar a nadie.
  if current_setting('app.skip_notifications', true) = 'on' then
    return new;
  end if;

  if new.assignee_id is not null
     and (tg_op = 'INSERT' or new.assignee_id is distinct from old.assignee_id)
     and new.status not in ('atendido', 'descartado') then
    insert into public.notification_outbox (incident_id, kind, assignee_id, dedupe_key)
    values (new.id, 'asignacion', new.assignee_id,
            'asignacion:' || new.id || ':' || new.assignee_id || ':' || extract(epoch from new.assigned_at))
    on conflict (dedupe_key) do nothing;
  end if;
  return new;
end;
$$;

create trigger incidents_enqueue_assignment
  after insert or update of assignee_id on public.incidents
  for each row execute function public.incidents_enqueue_assignment();

-- -----------------------------------------------------------------------------
-- Disparar el webhook de n8n (best effort)
-- -----------------------------------------------------------------------------
create or replace function public.notification_outbox_dispatch()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'n8n_webhook_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'n8n_webhook_secret';

  if v_url is null or v_secret is null then
    return new;  -- sin configuración: lo recoge el barrido de n8n
  end if;

  perform net.http_post(
    url     := v_url,
    body    := jsonb_build_object('outbox_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-H4U-Secret', v_secret),
    timeout_milliseconds := 5000
  );
  return new;
exception when others then
  -- Un fallo al avisar nunca debe impedir guardar la incidencia.
  raise warning 'notification_outbox_dispatch: %', sqlerrm;
  return new;
end;
$$;

create trigger notification_outbox_dispatch
  after insert on public.notification_outbox
  for each row execute function public.notification_outbox_dispatch();

-- -----------------------------------------------------------------------------
-- RPC para n8n: reclamar un aviso y obtener SOLO los datos necesarios.
-- No incluye el contacto del huésped (reporter_name / reporter_contact).
-- -----------------------------------------------------------------------------
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
           'unit',           coalesce(i.unit, '-'),
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
    left join public.assignees a on a.id = v_row.assignee_id
   where i.id = v_row.incident_id;

  return v_result;
end;
$$;

create or replace function public.complete_notification(
  p_outbox_id bigint,
  p_status    text,
  p_error     text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.notification_outbox;
begin
  if p_status not in ('sent', 'failed', 'skipped') then
    raise exception 'Estado de aviso inválido: %', p_status;
  end if;

  update public.notification_outbox
     set status    = case when p_status = 'failed' and attempts < 5 then 'pending' else p_status end,
         last_error = p_error,
         sent_at   = case when p_status = 'sent' then now() end,
         locked_at = null
   where id = p_outbox_id
  returning * into v_row;

  if p_status = 'sent' then
    insert into public.incident_events (incident_id, type, detail, author)
    values (v_row.incident_id, 'aviso',
            case v_row.kind
              when 'asignacion'       then 'Aviso por WhatsApp enviado al responsable'
              when 'sin_responsable'  then 'Alerta al operador: sigue sin responsable'
              when 'sin_confirmacion' then 'Alerta al operador: el responsable no ha confirmado'
            end,
            'n8n');
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC para el barrido programado de n8n:
--   1. encola escalamientos por tiempo;
--   2. devuelve los avisos pendientes (incluidos los que el webhook no entregó).
-- -----------------------------------------------------------------------------
create or replace function public.enqueue_escalations(
  p_unassigned_minutes    int default 30,
  p_unacknowledged_minutes int default 30
)
returns table (outbox_id bigint)
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Reportada y sin responsable demasiado tiempo.
  insert into public.notification_outbox (incident_id, kind, dedupe_key)
  select i.id, 'sin_responsable', 'sin_responsable:' || i.id
    from public.incidents i
   where i.status = 'reportado'
     and i.assignee_id is null
     and i.created_at < now() - make_interval(mins => p_unassigned_minutes)
  on conflict (dedupe_key) do nothing;

  -- Asignada, pero el responsable no confirmó. Una alerta por cada asignación.
  insert into public.notification_outbox (incident_id, kind, assignee_id, dedupe_key)
  select i.id, 'sin_confirmacion', null,
         'sin_confirmacion:' || i.id || ':' || extract(epoch from i.assigned_at)
    from public.incidents i
   where i.status in ('reportado', 'en_seguimiento')
     and i.assignee_id is not null
     and i.acknowledged_at is null
     and i.assigned_at < now() - make_interval(mins => p_unacknowledged_minutes)
  on conflict (dedupe_key) do nothing;

  return query
    select o.id
      from public.notification_outbox o
     where o.attempts < 5
       and ((o.status = 'pending' and o.created_at < now() - interval '30 seconds')
            or (o.status = 'processing' and o.locked_at < now() - interval '5 minutes'))
     order by o.created_at
     limit 50;
end;
$$;

-- Las RPC de la cola son solo para n8n (service_role).
revoke execute on function public.claim_notification(bigint)                from public, anon, authenticated;
revoke execute on function public.complete_notification(bigint, text, text) from public, anon, authenticated;
revoke execute on function public.enqueue_escalations(int, int)             from public, anon, authenticated;
grant  execute on function public.claim_notification(bigint)                to service_role;
grant  execute on function public.complete_notification(bigint, text, text) to service_role;
grant  execute on function public.enqueue_escalations(int, int)             to service_role;

-- Funciones de trigger: no invocables vía RPC.
revoke execute on function public.incidents_enforce_rules()      from public, anon, authenticated;
revoke execute on function public.incidents_log_events()         from public, anon, authenticated;
revoke execute on function public.incidents_enqueue_assignment() from public, anon, authenticated;
revoke execute on function public.notification_outbox_dispatch() from public, anon, authenticated;
