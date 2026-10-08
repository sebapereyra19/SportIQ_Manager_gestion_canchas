-- ─────────────────────────────────────────────────────────────
--  011 · Precio personalizado (descuentos) + eventos con seña
--  Correr en Supabase → SQL Editor DESPUÉS de la 010. Se puede correr más de una vez.
--
--  · reservas.precio_personalizado: si tiene valor, es el TOTAL de esa reserva
--    (en vez de tarifa de la cancha × horas). Sirve para descuentos y precios de evento.
--  · turnos_fijos.precio_personalizado: el precio que se copia a cada repetición.
--  · reservas.tipo_evento: Cumpleaños / Fiesta / Torneo / Otro (null = reserva común).
--    La seña de un evento usa los mismos campos de seña de siempre.
-- ─────────────────────────────────────────────────────────────

alter table public.reservas
  add column if not exists precio_personalizado numeric(12,2) check (precio_personalizado >= 0),
  add column if not exists tipo_evento text;

alter table public.reservas drop constraint if exists reservas_tipo_evento_check;
alter table public.reservas add constraint reservas_tipo_evento_check
  check (tipo_evento is null or tipo_evento in ('Cumpleaños', 'Fiesta', 'Torneo', 'Otro'));

alter table public.turnos_fijos
  add column if not exists precio_personalizado numeric(12,2) check (precio_personalizado >= 0);

-- ══ 1) PRECIO: el personalizado manda; si no, tarifa × horas ══
create or replace function public.reservas_calcular_precio()
returns trigger
language plpgsql
as $$
begin
  if new.precio_personalizado is not null then
    new.precio := new.precio_personalizado;
  elsif tg_op = 'INSERT'
     or new.cancha_id is distinct from old.cancha_id
     or new.duracion  is distinct from old.duracion
     or old.precio_personalizado is not null then
    select c.precio_hora * new.duracion
      into new.precio
      from public.canchas c
     where c.id = new.cancha_id;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- El trigger original solo se disparaba al cambiar cancha o duración: ahora también el precio a mano
drop trigger if exists reservas_precio on public.reservas;
create trigger reservas_precio
  before insert or update of cancha_id, duracion, precio_personalizado on public.reservas
  for each row execute function public.reservas_calcular_precio();

-- ══ 2) LAS REPETICIONES DEL TURNO FIJO HEREDAN SU PRECIO ═════
create or replace function public.generar_turnos_fijos(
  p_hoy      date,
  p_hasta    date default null,
  p_turno_id uuid default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  t           record;
  d           date;
  primera     date;
  ultima      date;
  v_hasta     date := least(coalesce(p_hasta, p_hoy + 62), p_hoy + 366);
  creadas     int := 0;
  conflictos  jsonb := '[]'::jsonb;
begin
  if not public.es_empleado() then
    raise exception 'Sin permiso.' using errcode = '42501';
  end if;

  for t in
    select tf.*, c.nombre as cliente
      from turnos_fijos tf join clientes c on c.id = tf.cliente_id
     where tf.activo and (p_turno_id is null or tf.id = p_turno_id)
  loop
    primera := greatest(p_hoy, t.desde);
    primera := primera + ((t.dia_semana - extract(dow from primera)::int + 7) % 7);
    ultima  := least(v_hasta, coalesce(t.hasta, v_hasta));
    d := primera;
    while d <= ultima loop
      if not exists (select 1 from reservas where turno_fijo_id = t.id
                                             and fecha_turno_fijo >  d - 7
                                             and fecha_turno_fijo <= d) then
        begin
          insert into reservas (cancha_id, cliente_id, fecha, hora_inicio, duracion, origen, notas,
                                turno_fijo_id, fecha_turno_fijo, precio_personalizado)
          values (t.cancha_id, t.cliente_id, d, t.hora_inicio, t.duracion, 'Turno fijo', t.notas, t.id, d,
                  t.precio_personalizado);
          creadas := creadas + 1;
        exception
          when exclusion_violation then
            conflictos := conflictos || jsonb_build_object(
              'fecha', d, 'hora', to_char(t.hora_inicio, 'HH24:MI'), 'cancha', t.cancha_id, 'cliente', t.cliente);
          when unique_violation then null;
        end;
      end if;
      d := d + 7;
    end loop;
  end loop;

  return jsonb_build_object('creadas', creadas, 'conflictos', conflictos, 'hasta', v_hasta);
end;
$$;
grant execute on function public.generar_turnos_fijos(date, date, uuid) to authenticated;

-- ══ 3) EDITAR TURNO FIJO: ahora también el precio ════════════
-- p_precio = null → vuelve a la tarifa normal de la cancha.
-- El precio nuevo se aplica a las repeticiones pendientes (Confirmadas) desde p_desde.
drop function if exists public.editar_turno_fijo(uuid, text, uuid, int, time, int, text, date, date, date);

create or replace function public.editar_turno_fijo(
  p_id         uuid,
  p_cancha     text,
  p_cliente_id uuid,
  p_dia        int,
  p_hora       time,
  p_duracion   int,
  p_notas      text,
  p_desde      date,
  p_hoy        date,
  p_hasta      date default null,
  p_precio     numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t          public.turnos_fijos%rowtype;
  r          record;
  delta      int;
  v_desde    date := greatest(coalesce(p_desde, p_hoy), p_hoy);
  v_notas    text := nullif(trim(coalesce(p_notas, '')), '');
  movidas    int := 0;
  no_movidas jsonb := '[]'::jsonb;
  gen        jsonb;
begin
  if not public.es_empleado() then
    raise exception 'Sin permiso.' using errcode = '42501';
  end if;
  if p_dia not between 0 and 6 or p_duracion not between 1 and 5 or coalesce(p_precio, 0) < 0 then
    raise exception 'Datos inválidos.' using errcode = '22023';
  end if;

  select * into t from public.turnos_fijos where id = p_id and activo for update;
  if not found then
    raise exception 'El turno fijo no existe o ya fue dado de baja.' using errcode = 'P0002';
  end if;

  delta := ((p_dia - t.dia_semana) + 7) % 7;

  update public.turnos_fijos
     set cancha_id = p_cancha, cliente_id = p_cliente_id, dia_semana = p_dia,
         hora_inicio = p_hora, duracion = p_duracion, notas = v_notas,
         precio_personalizado = p_precio
   where id = p_id;

  perform set_config('app.editando_turno_fijo', 'on', true);

  for r in
    select * from public.reservas
     where turno_fijo_id = p_id and fecha_turno_fijo >= v_desde
     order by fecha_turno_fijo desc
  loop
    if delta <> 0 then
      update public.reservas set fecha_turno_fijo = r.fecha_turno_fijo + delta where id = r.id;
    end if;
    if r.estado = 'Confirmada' and r.fecha = r.fecha_turno_fijo then
      begin
        update public.reservas
           set cancha_id   = p_cancha,
               cliente_id  = p_cliente_id,
               fecha       = r.fecha + delta,
               hora_inicio = p_hora,
               duracion    = p_duracion,
               notas       = case when r.notas is not distinct from t.notas then v_notas else r.notas end
         where id = r.id;
        movidas := movidas + 1;
      exception when exclusion_violation then
        no_movidas := no_movidas || jsonb_build_object(
          'fecha', r.fecha + delta, 'hora', to_char(p_hora, 'HH24:MI'), 'cancha', p_cancha);
      end;
    end if;
  end loop;

  -- precio: a todas las repeticiones pendientes desde p_desde (aunque se hayan movido a mano)
  if p_precio is distinct from t.precio_personalizado then
    update public.reservas
       set precio_personalizado = p_precio
     where turno_fijo_id = p_id and fecha_turno_fijo >= v_desde and estado = 'Confirmada';
  end if;

  perform set_config('app.editando_turno_fijo', 'off', true);

  if p_precio is distinct from t.precio_personalizado then
    insert into actividad (usuario, email, accion, tabla, registro_id, detalle)
    values (usuario_actual(), lower(auth.jwt() ->> 'email'), 'Cambió precio de turno fijo', 'turnos_fijos', p_id::text,
            format('%s · %s → %s por turno (desde %s)',
                   (select nombre from clientes where id = p_cliente_id),
                   case when t.precio_personalizado is null then 'tarifa normal' else dinero(t.precio_personalizado) end,
                   case when p_precio is null then 'tarifa normal' else dinero(p_precio) end,
                   to_char(v_desde, 'DD/MM/YYYY')));
  end if;

  gen := public.generar_turnos_fijos(p_hoy, p_hasta, p_id);

  return jsonb_build_object(
    'movidas',    movidas,
    'no_movidas', no_movidas,
    'creadas',    coalesce((gen ->> 'creadas')::int, 0),
    'conflictos', coalesce(gen -> 'conflictos', '[]'::jsonb)
  );
end;
$$;
grant execute on function public.editar_turno_fijo(uuid, text, uuid, int, time, int, text, date, date, date, numeric) to authenticated;

select 'ok' as migracion_011;
