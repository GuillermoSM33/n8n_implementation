-- =============================================================================
-- Triaje con IA (Gemini en n8n): contexto que n8n necesita para sugerir.
--
-- n8n llama esta función CON EL TOKEN DEL OPERADOR (no con service_role):
-- si el token no es válido, Supabase responde 401 y n8n no llama a Gemini.
-- Así el webhook público de triaje queda protegido sin poner secretos en Lovable.
-- =============================================================================

create or replace function public.triage_context(p_property_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'property', (
      select jsonb_build_object('id', p.id, 'name', p.name, 'city', p.city)
        from public.properties p
       where p.id = p_property_id
    ),
    'assignees', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'role', a.role) order by a.name)
        from public.assignees a
       where a.active
    ), '[]'::jsonb),
    -- Incidencias abiertas de la misma propiedad, para que el modelo detecte duplicados.
    'open_incidents', coalesce((
      select jsonb_agg(jsonb_build_object('folio', i.folio, 'category', i.category,
                                          'description', left(i.description, 200))
                       order by i.created_at desc)
        from public.incidents i
       where i.property_id = p_property_id
         and i.status in ('reportado', 'en_seguimiento')
    ), '[]'::jsonb)
  );
$$;

revoke execute on function public.triage_context(uuid) from public, anon;
grant  execute on function public.triage_context(uuid) to authenticated;
