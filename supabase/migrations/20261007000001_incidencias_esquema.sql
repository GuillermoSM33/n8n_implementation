-- =============================================================================
-- Incidencias de mantenimiento: esquema base y reglas de negocio.
--
-- Las reglas viven en la base de datos (triggers), no solo en el frontend:
-- cualquier cliente (Lovable, n8n, SQL directo) obtiene el mismo comportamiento.
-- =============================================================================

-- Quién hace el cambio: el correo del operador autenticado, o 'sistema'
-- cuando escribe n8n (service_role) o un trigger sin sesión de usuario.
create or replace function public.current_actor()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(nullif(auth.jwt() ->> 'email', ''), 'sistema');
$$;

-- -----------------------------------------------------------------------------
-- Catálogos
-- -----------------------------------------------------------------------------
create table public.properties (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  city        text,
  notes       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.assignees (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  role        text not null check (role in ('anfitrion', 'gerente', 'tecnico', 'proveedor')),
  -- Formato E.164 sin '+', como lo espera la WhatsApp Cloud API (ej. 5219981234567).
  phone       text check (phone ~ '^[1-9][0-9]{7,14}$'),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Incidencias
-- -----------------------------------------------------------------------------
create sequence public.incident_folio_seq;

create table public.incidents (
  id                uuid primary key default gen_random_uuid(),
  folio             text not null unique
                    default 'INC-' || lpad(nextval('public.incident_folio_seq')::text, 4, '0'),
  property_id       uuid not null references public.properties (id),
  unit              text,
  channel           text not null check (channel in ('whatsapp', 'airbnb', 'sms', 'llamada')),
  reporter_name     text,
  reporter_contact  text,
  description       text not null check (length(trim(description)) > 0),
  category          text not null default 'otro'
                    check (category in ('agua', 'electricidad', 'gas', 'climatizacion', 'cerraduras',
                                        'electrodomesticos', 'limpieza', 'otro')),
  priority          text not null default 'media' check (priority in ('alta', 'media', 'baja')),
  status            text not null default 'reportado'
                    check (status in ('reportado', 'en_seguimiento', 'atendido', 'descartado')),
  assignee_id       uuid references public.assignees (id),
  resolution_note   text,
  discard_reason    text,
  ai_suggestion     jsonb,
  created_at        timestamptz not null default now(),
  assigned_at       timestamptz,
  -- El responsable confirmó que recibió el aviso. Se reinicia en cada reasignación.
  acknowledged_at   timestamptz,
  resolved_at       timestamptz,
  updated_at        timestamptz not null default now()
);

alter sequence public.incident_folio_seq owned by public.incidents.folio;

create index incidents_status_idx      on public.incidents (status);
create index incidents_property_idx    on public.incidents (property_id, category) where status in ('reportado', 'en_seguimiento');
create index incidents_assignee_idx    on public.incidents (assignee_id);

-- -----------------------------------------------------------------------------
-- Historial (línea de tiempo)
-- -----------------------------------------------------------------------------
create table public.incident_events (
  id           bigint generated always as identity primary key,
  incident_id  uuid not null references public.incidents (id) on delete cascade,
  type         text not null check (type in ('creado', 'comentario', 'cambio_estado', 'asignacion',
                                             'cambio_prioridad', 'confirmacion', 'aviso')),
  detail       text,
  author       text not null default public.current_actor(),
  created_at   timestamptz not null default now()
);

create index incident_events_incident_idx on public.incident_events (incident_id, created_at);

-- -----------------------------------------------------------------------------
-- Regla 1-4: transiciones válidas y marcas de tiempo
-- -----------------------------------------------------------------------------
create or replace function public.incidents_enforce_rules()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'en_seguimiento' and new.assignee_id is null then
    raise exception 'Asigna un responsable antes de pasar a En seguimiento'
      using errcode = 'check_violation';
  end if;

  if new.status = 'atendido' and coalesce(trim(new.resolution_note), '') = '' then
    raise exception 'Escribe la nota de resolución antes de marcar como Atendido'
      using errcode = 'check_violation';
  end if;

  if new.status = 'descartado' and coalesce(trim(new.discard_reason), '') = '' then
    raise exception 'Escribe el motivo antes de marcar como Descartado'
      using errcode = 'check_violation';
  end if;

  if tg_op = 'INSERT' then
    new.assigned_at     := case when new.assignee_id is not null then now() end;
    new.acknowledged_at := null;
    new.resolved_at     := case when new.status = 'atendido' then now() end;
  else
    if new.assignee_id is distinct from old.assignee_id then
      new.assigned_at     := case when new.assignee_id is null then null else now() end;
      new.acknowledged_at := null;
    end if;
    if new.status = 'atendido' and old.status <> 'atendido' then
      new.resolved_at := now();
    elsif new.status <> 'atendido' then
      new.resolved_at := null;
    end if;
  end if;

  if new.acknowledged_at is not null and new.assignee_id is null then
    raise exception 'No se puede confirmar una incidencia sin responsable'
      using errcode = 'check_violation';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger incidents_enforce_rules
  before insert or update on public.incidents
  for each row execute function public.incidents_enforce_rules();

-- -----------------------------------------------------------------------------
-- Regla 5: historial automático
-- -----------------------------------------------------------------------------

create or replace function public.incidents_log_events()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor text := public.current_actor();
  v_old_name text;
  v_new_name text;
begin
  if tg_op = 'INSERT' then
    insert into public.incident_events (incident_id, type, detail, author)
    values (new.id, 'creado', 'Reportada por ' || new.channel, v_actor);
    if new.assignee_id is not null then
      select name into v_new_name from public.assignees where id = new.assignee_id;
      insert into public.incident_events (incident_id, type, detail, author)
      values (new.id, 'asignacion', 'Sin responsable → ' || v_new_name, v_actor);
    end if;
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.incident_events (incident_id, type, detail, author)
    values (new.id, 'cambio_estado', old.status || ' → ' || new.status, v_actor);
  end if;

  if new.priority is distinct from old.priority then
    insert into public.incident_events (incident_id, type, detail, author)
    values (new.id, 'cambio_prioridad', old.priority || ' → ' || new.priority, v_actor);
  end if;

  if new.assignee_id is distinct from old.assignee_id then
    select name into v_old_name from public.assignees where id = old.assignee_id;
    select name into v_new_name from public.assignees where id = new.assignee_id;
    insert into public.incident_events (incident_id, type, detail, author)
    values (new.id, 'asignacion',
            coalesce(v_old_name, 'Sin responsable') || ' → ' || coalesce(v_new_name, 'Sin responsable'),
            v_actor);
  end if;

  if new.acknowledged_at is not null and old.acknowledged_at is null then
    insert into public.incident_events (incident_id, type, detail, author)
    values (new.id, 'confirmacion', 'El responsable confirmó que recibió el aviso', v_actor);
  end if;

  return new;
end;
$$;

create trigger incidents_log_events
  after insert or update on public.incidents
  for each row execute function public.incidents_log_events();

-- -----------------------------------------------------------------------------
-- "Requiere atención": la regla vive en un solo lugar
-- -----------------------------------------------------------------------------
create or replace view public.incidents_with_attention
with (security_invoker = true)
as
select
  i.*,
  p.name as property_name,
  a.name as assignee_name,
  (
    (i.status = 'reportado' and i.assignee_id is null and i.created_at < now() - interval '30 minutes')
    or (i.priority = 'alta' and i.status not in ('atendido', 'descartado'))
    or (i.updated_at < now() - interval '24 hours' and i.status not in ('atendido', 'descartado'))
  ) as requires_attention,
  array_remove(array[
    case when i.status = 'reportado' and i.assignee_id is null
              and i.created_at < now() - interval '30 minutes'
         then 'Más de 30 min sin responsable' end,
    case when i.priority = 'alta' and i.status not in ('atendido', 'descartado')
         then 'Prioridad alta abierta' end,
    case when i.updated_at < now() - interval '24 hours' and i.status not in ('atendido', 'descartado')
         then 'Más de 24 h sin movimiento' end
  ], null) as attention_reasons
from public.incidents i
join public.properties p on p.id = i.property_id
left join public.assignees a on a.id = i.assignee_id;

-- -----------------------------------------------------------------------------
-- Seguridad: solo operadores autenticados. Nada para el rol anónimo.
-- (Independiente de la opción "Automatically expose new tables" del proyecto.)
-- -----------------------------------------------------------------------------
alter table public.properties      enable row level security;
alter table public.assignees       enable row level security;
alter table public.incidents       enable row level security;
alter table public.incident_events enable row level security;

revoke all on public.properties, public.assignees, public.incidents, public.incident_events,
              public.incidents_with_attention
  from anon;

grant select, insert, update on public.properties, public.assignees, public.incidents to authenticated;
grant select, insert on public.incident_events to authenticated;
grant select on public.incidents_with_attention to authenticated;
grant usage on sequence public.incident_folio_seq to authenticated;

create policy "operadores leen propiedades"      on public.properties for select to authenticated using (true);
create policy "operadores crean propiedades"     on public.properties for insert to authenticated with check (true);
create policy "operadores editan propiedades"    on public.properties for update to authenticated using (true) with check (true);

create policy "operadores leen responsables"     on public.assignees for select to authenticated using (true);
create policy "operadores crean responsables"    on public.assignees for insert to authenticated with check (true);
create policy "operadores editan responsables"   on public.assignees for update to authenticated using (true) with check (true);

create policy "operadores leen incidencias"      on public.incidents for select to authenticated using (true);
create policy "operadores crean incidencias"     on public.incidents for insert to authenticated with check (true);
create policy "operadores editan incidencias"    on public.incidents for update to authenticated using (true) with check (true);

create policy "operadores leen historial"        on public.incident_events for select to authenticated using (true);
-- Desde el frontend solo se agregan comentarios; el resto lo escriben los triggers.
create policy "operadores comentan"              on public.incident_events for insert to authenticated
  with check (type = 'comentario' and author = public.current_actor());
