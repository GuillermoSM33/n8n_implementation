-- Configuración pública de la app que cambia sin redeploy del frontend.
-- Caso principal: la URL de n8n (túnel temporal de Cloudflare) cambia cada vez que el
-- túnel se reinicia; el frontend la lee de aquí en vez de tenerla en el código.
-- Solo valores NO secretos: cualquier operador con sesión puede leerlos.
-- Se actualiza con scripts/actualizar_tunel.sh.

create table public.app_config (
  key         text primary key,
  value       text not null,
  updated_at  timestamptz not null default now()
);

alter table public.app_config enable row level security;

revoke all on public.app_config from anon, authenticated;
grant select on public.app_config to authenticated;

create policy "operadores leen la configuración"
  on public.app_config for select to authenticated using (true);

insert into public.app_config (key, value) values ('n8n_url', 'http://localhost:5678');
