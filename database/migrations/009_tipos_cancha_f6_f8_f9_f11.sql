-- ════════════════════════════════════════════════════════════
-- 009 — Más tipos de cancha: Fútbol 6, 8, 9 y 11
-- Tipos válidos: F5, F6, F7, F8, F9, F11 (antes solo F5 y F7).
-- Los ids nuevos siguen el mismo formato: 'F6-1', 'F11-2', ...
-- Nota: no confundir con _respaldo_multi_complejo/009 (descartada).
-- ════════════════════════════════════════════════════════════

-- 1) Restricción de la tabla
alter table public.canchas drop constraint if exists canchas_tipo_check;
alter table public.canchas add constraint canchas_tipo_check
  check (tipo in ('F5', 'F6', 'F7', 'F8', 'F9', 'F11'));

-- 2) crear_cancha (igual a la 008, con la lista nueva)
create or replace function public.crear_cancha(p_tipo text, p_etiqueta text, p_precio numeric)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  n   int;
  nid text;
begin
  if not es_jefe() then raise exception 'Solo los jefes pueden crear canchas.'; end if;
  if p_tipo not in ('F5', 'F6', 'F7', 'F8', 'F9', 'F11') then raise exception 'Tipo de cancha inválido.'; end if;
  if coalesce(trim(p_etiqueta), '') = '' then raise exception 'Ingresá el nombre de la cancha.'; end if;
  if p_precio is null or p_precio < 0 then raise exception 'Precio inválido.'; end if;

  lock table public.canchas in share row exclusive mode;   -- evita ids repetidos si dos jefes crean a la vez
  select coalesce(max(substring(id from '-(\d+)$')::int), 0) + 1 into n
    from canchas where tipo = p_tipo;
  nid := p_tipo || '-' || n;

  insert into canchas (id, tipo, etiqueta, precio_hora, orden)
  values (nid, p_tipo, trim(p_etiqueta), p_precio, (select coalesce(max(orden), 0) + 1 from canchas));
  return jsonb_build_object('id', nid);
end;
$$;
grant execute on function public.crear_cancha(text, text, numeric) to authenticated;
