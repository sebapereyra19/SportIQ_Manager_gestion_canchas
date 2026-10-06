-- ─────────────────────────────────────────────────────────────
--  Volver a UN solo complejo (revierte 009_multi_complejo.sql)
--
--  Deja la base exactamente como estaba después de 008:
--  · Conserva los datos del complejo inicial ("Mi complejo").
--  · Borra los datos de cualquier otro complejo creado desde admin.html.
--  · Quita complejo_id de todas las tablas, las tablas complejos y
--    super_admins, y las funciones de multi-complejo (mi_perfil,
--    complejo_actual, complejo_publico, admin_*, etc.).
--  · Restaura claves, índices, políticas RLS y funciones de 008.
--
--  Correr UNA vez en Supabase → SQL Editor. Corre en una transacción.
-- ─────────────────────────────────────────────────────────────

begin;

-- ══ 1) DATOS DE LOS OTROS COMPLEJOS (se conserva el primero) ══
do $$
declare v_principal uuid := (select id from public.complejos order by created_at limit 1);
begin
  alter table public.empleados disable trigger empleados_un_jefe;   -- su único jefe se va con el complejo
  delete from public.actividad     where complejo_id <> v_principal;
  delete from public.reservas      where complejo_id <> v_principal;
  delete from public.turnos_fijos  where complejo_id <> v_principal;
  delete from public.egresos       where complejo_id <> v_principal;
  delete from public.clientes      where complejo_id <> v_principal;
  delete from public.configuracion where complejo_id <> v_principal;
  delete from public.canchas       where complejo_id <> v_principal;
  delete from public.empleados     where complejo_id <> v_principal;
  alter table public.empleados enable trigger empleados_un_jefe;
end $$;

-- ══ 2) POLÍTICAS (se recrean las de 008 más abajo) ══════════
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
     where schemaname = 'public'
       and tablename in ('empleados', 'canchas', 'clientes', 'reservas', 'egresos',
                         'turnos_fijos', 'configuracion', 'actividad', 'complejos')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- ══ 3) FUNCIONES QUE SOLO EXISTÍAN PARA MULTI-COMPLEJO ══════
-- (complejo_actual() se borra después de sacar las columnas que la usan como default)
drop function if exists public.admin_crear_complejo(text, text, text, text, integer, numeric, integer, numeric, integer, integer);
drop function if exists public.admin_editar_complejo(uuid, text, text, boolean);
drop function if exists public.admin_listar_complejos();
drop function if exists public.complejo_publico(text);
drop function if exists public.es_super_admin();
drop function if exists public.mi_perfil();
drop function if exists public.slug_reservado(text);

-- ══ 4) COLUMNA complejo_id (arrastra sus claves e índices) ══
alter table public.reservas      drop column if exists complejo_id cascade;
alter table public.turnos_fijos  drop column if exists complejo_id cascade;
alter table public.egresos       drop column if exists complejo_id cascade;
alter table public.actividad     drop column if exists complejo_id cascade;
alter table public.clientes      drop column if exists complejo_id cascade;
alter table public.canchas       drop column if exists complejo_id cascade;
alter table public.configuracion drop column if exists complejo_id cascade;
alter table public.empleados     drop column if exists complejo_id cascade;

drop function if exists public.complejo_actual();
drop table if exists public.complejos;
drop table if exists public.super_admins;

-- ══ 5) CONFIGURACIÓN: vuelve a ser una sola fila con id = 1 ══
alter table public.configuracion add column if not exists id integer not null default 1;
alter table public.configuracion add constraint configuracion_id_check check (id = 1);

-- ══ 6) CLAVES E ÍNDICES DE 008 ══════════════════════════════
alter table public.canchas drop constraint if exists canchas_pkey;
ALTER TABLE ONLY public.canchas ADD CONSTRAINT canchas_pkey PRIMARY KEY (id);
alter table public.clientes drop constraint if exists clientes_telefono_key;
ALTER TABLE ONLY public.clientes ADD CONSTRAINT clientes_telefono_key UNIQUE (telefono);
alter table public.configuracion drop constraint if exists configuracion_pkey;
ALTER TABLE ONLY public.configuracion ADD CONSTRAINT configuracion_pkey PRIMARY KEY (id);
alter table public.reservas drop constraint if exists reservas_sin_superposicion;
ALTER TABLE ONLY public.reservas ADD CONSTRAINT reservas_sin_superposicion EXCLUDE USING gist (cancha_id WITH =, rango WITH &&) WHERE ((estado = ANY (ARRAY['Confirmada'::text, 'Asistida'::text])));
alter table public.turnos_fijos drop constraint if exists turnos_fijos_sin_superposicion;
ALTER TABLE ONLY public.turnos_fijos ADD CONSTRAINT turnos_fijos_sin_superposicion EXCLUDE USING gist (cancha_id WITH =, dia_semana WITH =, minutos WITH &&) WHERE (activo);
alter table public.reservas drop constraint if exists reservas_cancha_id_fkey;
ALTER TABLE ONLY public.reservas ADD CONSTRAINT reservas_cancha_id_fkey FOREIGN KEY (cancha_id) REFERENCES public.canchas(id);
alter table public.reservas drop constraint if exists reservas_cliente_id_fkey;
ALTER TABLE ONLY public.reservas ADD CONSTRAINT reservas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clientes(id);
alter table public.reservas drop constraint if exists reservas_turno_fijo_id_fkey;
ALTER TABLE ONLY public.reservas ADD CONSTRAINT reservas_turno_fijo_id_fkey FOREIGN KEY (turno_fijo_id) REFERENCES public.turnos_fijos(id) ON DELETE SET NULL;
alter table public.turnos_fijos drop constraint if exists turnos_fijos_cancha_id_fkey;
ALTER TABLE ONLY public.turnos_fijos ADD CONSTRAINT turnos_fijos_cancha_id_fkey FOREIGN KEY (cancha_id) REFERENCES public.canchas(id);
alter table public.turnos_fijos drop constraint if exists turnos_fijos_cliente_id_fkey;
ALTER TABLE ONLY public.turnos_fijos ADD CONSTRAINT turnos_fijos_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clientes(id);
CREATE INDEX actividad_fecha_idx ON public.actividad USING btree (creado_at DESC);
CREATE INDEX egresos_fecha_idx ON public.egresos USING btree (fecha);
CREATE INDEX reservas_fecha_idx ON public.reservas USING btree (fecha);

-- ══ 7) FUNCIONES COMO EN 008 ═══════════════════════════════
CREATE OR REPLACE FUNCTION public.baja_turno_fijo(p_id uuid, p_hoy date) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare n int;
begin
  if not public.es_empleado() then
    raise exception 'Sin permiso.' using errcode = '42501';
  end if;
  update turnos_fijos set activo = false, hasta = p_hoy where id = p_id and activo;
  update reservas
     set estado = 'Cancelada', motivo_cancelacion = 'Baja del turno fijo'
   where turno_fijo_id = p_id and fecha > p_hoy and estado = 'Confirmada';
  get diagnostics n = row_count;
  return n;
end;
$$;

CREATE OR REPLACE FUNCTION public.cambiar_estado_cancha(p_id text, p_activa boolean, p_hoy date) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare uso jsonb;
begin
  if not es_jefe() then raise exception 'Solo los jefes pueden modificar canchas.'; end if;
  if not p_activa then
    uso := uso_cancha(p_id, p_hoy);
    if (uso ->> 'reservas_futuras')::int > 0 or (uso ->> 'fijos_activos')::int > 0 then
      return jsonb_build_object('ok', false, 'uso', uso);
    end if;
  end if;
  update canchas set activa = p_activa where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

CREATE OR REPLACE FUNCTION public.crear_cancha(p_tipo text, p_etiqueta text, p_precio numeric) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$
declare
  n   int;
  nid text;
begin
  if not es_jefe() then raise exception 'Solo los jefes pueden crear canchas.'; end if;
  if p_tipo not in ('F5', 'F7') then raise exception 'Tipo de cancha inválido.'; end if;
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
$_$;

CREATE OR REPLACE FUNCTION public.editar_turno_fijo(p_id uuid, p_cancha text, p_cliente_id uuid, p_dia integer, p_hora time without time zone, p_duracion integer, p_notas text, p_desde date, p_hoy date, p_hasta date DEFAULT NULL::date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
  if p_dia not between 0 and 6 or p_duracion not between 1 and 5 then
    raise exception 'Datos inválidos.' using errcode = '22023';
  end if;

  select * into t from public.turnos_fijos where id = p_id and activo for update;
  if not found then
    raise exception 'El turno fijo no existe o ya fue dado de baja.' using errcode = 'P0002';
  end if;

  -- cuántos días se corre cada repetición (siempre hacia adelante, 0 a 6)
  delta := ((p_dia - t.dia_semana) + 7) % 7;

  -- 1) el turno en sí (si pisa otro turno fijo activo, falla con 23P01)
  update public.turnos_fijos
     set cancha_id = p_cancha, cliente_id = p_cliente_id, dia_semana = p_dia,
         hora_inicio = p_hora, duracion = p_duracion, notas = v_notas
   where id = p_id;

  perform set_config('app.editando_turno_fijo', 'on', true);

  -- 2) las repeticiones ya cargadas desde v_desde
  for r in
    select * from public.reservas
     where turno_fijo_id = p_id and fecha_turno_fijo >= v_desde
     order by fecha_turno_fijo desc
  loop
    -- la "semana" de la repetición se corre al nuevo día (así no se duplica)
    if delta <> 0 then
      update public.reservas set fecha_turno_fijo = r.fecha_turno_fijo + delta where id = r.id;
    end if;
    -- solo se mueven las pendientes que no se editaron a mano
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

  perform set_config('app.editando_turno_fijo', 'off', true);

  -- 3) completar semanas que falten con el horario nuevo
  gen := public.generar_turnos_fijos(p_hoy, p_hasta, p_id);

  return jsonb_build_object(
    'movidas',    movidas,
    'no_movidas', no_movidas,
    'creadas',    coalesce((gen ->> 'creadas')::int, 0),
    'conflictos', coalesce(gen -> 'conflictos', '[]'::jsonb)
  );
end;
$$;

CREATE OR REPLACE FUNCTION public.eliminar_cancha(p_id text, p_hoy date, p_forzar boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare uso jsonb;
begin
  if not es_jefe() then raise exception 'Solo los jefes pueden eliminar canchas.'; end if;
  uso := uso_cancha(p_id, p_hoy);

  if (uso ->> 'reservas_total')::int = 0 and (uso ->> 'fijos_total')::int = 0 then
    delete from canchas where id = p_id;
    return jsonb_build_object('ok', true, 'borrada', true);
  end if;

  if ((uso ->> 'reservas_futuras')::int > 0 or (uso ->> 'fijos_activos')::int > 0) and not p_forzar then
    return jsonb_build_object('ok', false, 'uso', uso);
  end if;

  update turnos_fijos set activo = false, hasta = p_hoy where cancha_id = p_id and activo;
  update reservas set estado = 'Cancelada', motivo_cancelacion = 'Cancha eliminada'
   where cancha_id = p_id and fecha >= p_hoy and estado = 'Confirmada';
  update canchas set activa = false, eliminada = true where id = p_id;
  return jsonb_build_object('ok', true, 'borrada', false);
end;
$$;

CREATE OR REPLACE FUNCTION public.empleados_exigir_un_jefe() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if not exists (select 1 from public.empleados where rol = 'jefe' and activo) then
    raise exception 'Tiene que quedar al menos un jefe activo.' using errcode = 'P0001';
  end if;
  return null;
end;
$$;

CREATE OR REPLACE FUNCTION public.es_empleado() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.empleados
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
      and activo
  );
$$;

CREATE OR REPLACE FUNCTION public.es_jefe() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.empleados
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
      and activo
      and rol = 'jefe'
  );
$$;

CREATE OR REPLACE FUNCTION public.generar_turnos_fijos(p_hoy date, p_hasta date DEFAULT NULL::date, p_turno_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
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
      -- una repetición por semana: si ya hay una en los 6 días anteriores (por ej. del
      -- horario viejo, antes de editarlo) esa semana ya está cubierta
      if not exists (select 1 from reservas where turno_fijo_id = t.id
                                             and fecha_turno_fijo >  d - 7
                                             and fecha_turno_fijo <= d) then
        begin
          insert into reservas (cancha_id, cliente_id, fecha, hora_inicio, duracion, origen, notas,
                                turno_fijo_id, fecha_turno_fijo)
          values (t.cancha_id, t.cliente_id, d, t.hora_inicio, t.duracion, 'Turno fijo', t.notas, t.id, d);
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

CREATE OR REPLACE FUNCTION public.registrar_actividad() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  r       record;
  accion  text;
  detalle text;
  cliente text;
  dias    text[] := array['Domingo','Lunes','Martes','Miércoles','Jueves','Viernes','Sábado'];
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;

  if tg_table_name = 'reservas' then
    -- al editar un turno fijo se mueven muchas fechas: queda un solo registro "Editó turno fijo"
    if coalesce(current_setting('app.editando_turno_fijo', true), '') = 'on' then return null; end if;
    -- las repeticiones de turnos fijos se generan solas: no ensuciamos el historial
    if tg_op = 'INSERT' and new.turno_fijo_id is not null then return null; end if;
    select nombre into cliente from clientes where id = r.cliente_id;
    detalle := format('%s · %s %s hs · %s', r.cancha_id, to_char(r.fecha, 'DD/MM/YYYY'),
                      to_char(r.hora_inicio, 'HH24:MI'), coalesce(cliente, '—'));
    if tg_op = 'INSERT' then
      accion := 'Creó reserva';
      if new.estado_sena = 'Recibida' and new.sena > 0 then
        detalle := detalle || format(' · seña %s %s', dinero(new.sena), lower(new.tipo_sena));
      end if;
    elsif tg_op = 'DELETE' then
      accion := 'Eliminó reserva';
    elsif new.estado is distinct from old.estado and new.estado = 'Cancelada' then
      if new.motivo_cancelacion = 'Baja del turno fijo' then return null; end if;  -- ya queda "Dio de baja turno fijo"
      accion := 'Canceló reserva';
      if new.estado_sena = 'Devuelta' then detalle := detalle || ' · seña devuelta';
      elsif new.estado_sena = 'Recibida' then detalle := detalle || ' · seña retenida ' || dinero(new.sena); end if;
      if coalesce(new.motivo_cancelacion, '') <> '' then detalle := detalle || ' · ' || new.motivo_cancelacion; end if;
    elsif new.estado is distinct from old.estado and new.estado = 'No vino' then
      accion := 'Marcó que no vino';
    elsif new.estado is distinct from old.estado and new.estado = 'Asistida' then
      accion := 'Confirmó asistencia';
      if new.pago_restante > 0 then
        detalle := detalle || format(' · cobró %s %s', dinero(new.pago_restante), lower(coalesce(new.tipo_pago_restante, '')));
      end if;
    elsif new.estado_sena = 'Recibida' and old.estado_sena is distinct from 'Recibida' then
      accion := 'Registró seña';
      detalle := detalle || format(' · %s %s', dinero(new.sena), lower(new.tipo_sena));
    else
      accion := 'Editó reserva';
      -- qué cambió (horario, cancha o cliente)
      if (new.fecha, new.hora_inicio, new.cancha_id, new.duracion) is distinct from (old.fecha, old.hora_inicio, old.cancha_id, old.duracion) then
        detalle := detalle || format(' · antes: %s %s %s hs%s', old.cancha_id, to_char(old.fecha, 'DD/MM'),
                                     to_char(old.hora_inicio, 'HH24:MI'),
                                     case when new.duracion <> old.duracion then format(' (%s h)', old.duracion) else '' end);
      elsif new.cliente_id is distinct from old.cliente_id then
        detalle := detalle || ' · antes: ' || coalesce((select nombre from clientes where id = old.cliente_id), '—');
      elsif (new.sena, new.tipo_sena, new.estado_sena) is distinct from (old.sena, old.tipo_sena, old.estado_sena) then
        detalle := detalle || format(' · seña: %s %s (%s)', dinero(new.sena), lower(new.tipo_sena), lower(new.estado_sena));
      end if;
    end if;

  elsif tg_table_name = 'egresos' then
    detalle := format('%s · %s · %s', r.categoria, dinero(r.monto), coalesce(nullif(r.descripcion, ''), lower(r.forma_pago)));
    accion := case tg_op when 'INSERT' then 'Registró egreso' when 'DELETE' then 'Eliminó egreso' else 'Editó egreso' end;

  elsif tg_table_name = 'turnos_fijos' then
    select nombre into cliente from clientes where id = r.cliente_id;
    detalle := format('%s %s hs · %s · %s', dias[r.dia_semana + 1], to_char(r.hora_inicio, 'HH24:MI'), r.cancha_id, coalesce(cliente, '—'));
    if tg_op = 'INSERT' then accion := 'Creó turno fijo';
    elsif tg_op = 'UPDATE' and old.activo and not new.activo then accion := 'Dio de baja turno fijo';
    elsif tg_op = 'UPDATE' and (new.cancha_id, new.cliente_id, new.dia_semana, new.hora_inicio, new.duracion, coalesce(new.notas, ''))
                       is distinct from (old.cancha_id, old.cliente_id, old.dia_semana, old.hora_inicio, old.duracion, coalesce(old.notas, '')) then
      accion := 'Editó turno fijo';
      declare cliente_ant text; begin
        select nombre into cliente_ant from clientes where id = old.cliente_id;
        detalle := format('%s %s hs · %s · %s → %s', dias[old.dia_semana + 1], to_char(old.hora_inicio, 'HH24:MI'),
                          old.cancha_id, coalesce(cliente_ant, '—'), detalle);
      end;
    elsif tg_op = 'UPDATE' then return null;
    else accion := 'Eliminó turno fijo'; end if;

  elsif tg_table_name = 'empleados' then
    detalle := format('%s (%s)', r.email, r.rol);
    if tg_op = 'INSERT' then accion := 'Dio de alta a una persona';
    elsif tg_op = 'DELETE' then accion := 'Eliminó a una persona';
    elsif new.activo is distinct from old.activo then
      accion := case when new.activo then 'Reactivó a una persona' else 'Dio de baja a una persona' end;
    elsif new.rol is distinct from old.rol then
      accion := 'Cambió el rol'; detalle := format('%s: %s → %s', r.email, old.rol, new.rol);
    elsif new.nombre is distinct from old.nombre then
      accion := 'Cambió el nombre'; detalle := format('%s: %s', r.email, coalesce(new.nombre, '—'));
    else
      return null;   -- ej.: solo se actualizó el último acceso
    end if;

  elsif tg_table_name = 'canchas' then
    if new.precio_hora is not distinct from old.precio_hora then return null; end if;
    accion := 'Cambió precio';
    detalle := format('%s %s: %s → %s por hora', r.tipo, r.etiqueta, dinero(old.precio_hora), dinero(new.precio_hora));

  elsif tg_table_name = 'configuracion' then
    if new.hora_apertura = old.hora_apertura and new.hora_cierre = old.hora_cierre then return null; end if;
    accion := 'Cambió horarios';
    detalle := format('%s a %s hs → %s a %s hs', old.hora_apertura, old.hora_cierre, new.hora_apertura, new.hora_cierre);
  else
    return null;
  end if;

  insert into actividad (usuario, email, accion, tabla, registro_id, detalle)
  values (usuario_actual(), lower(auth.jwt() ->> 'email'), accion, tg_table_name,
          case when tg_table_name in ('configuracion') then null else (to_jsonb(r) ->> case when tg_table_name = 'empleados' then 'email' else 'id' end) end,
          detalle);
  return null;
end;
$$;

CREATE OR REPLACE FUNCTION public.registrar_actividad_cancha() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  accion  text;
  detalle text;
  r       record;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  detalle := format('%s %s (%s)', r.tipo, r.etiqueta, r.id);

  if tg_op = 'INSERT' then
    accion := 'Creó cancha';
    detalle := detalle || ' · ' || dinero(r.precio_hora) || ' por hora';
  elsif tg_op = 'DELETE' then
    accion := 'Eliminó cancha';
  elsif new.eliminada and not old.eliminada then
    accion := 'Eliminó cancha';
    detalle := detalle || ' · con historial, se conserva en la caja';
  elsif new.activa is distinct from old.activa then
    accion := case when new.activa then 'Reactivó cancha' else 'Desactivó cancha' end;
  elsif new.precio_hora is distinct from old.precio_hora then
    accion := 'Cambió precio';
    detalle := format('%s %s: %s → %s por hora', new.tipo, new.etiqueta, dinero(old.precio_hora), dinero(new.precio_hora));
  elsif (new.etiqueta, new.tipo) is distinct from (old.etiqueta, old.tipo) then
    accion := 'Editó cancha';
    detalle := format('%s %s → %s %s (%s)', old.tipo, old.etiqueta, new.tipo, new.etiqueta, new.id);
  else
    return null;
  end if;

  insert into actividad (usuario, email, accion, tabla, registro_id, detalle)
  values (usuario_actual(), lower(auth.jwt() ->> 'email'), accion, 'canchas', r.id, detalle);
  return null;
end;
$$;

CREATE OR REPLACE FUNCTION public.reservas_calcular_precio() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if tg_op = 'INSERT'
     or new.cancha_id is distinct from old.cancha_id
     or new.duracion  is distinct from old.duracion then
    select c.precio_hora * new.duracion
      into new.precio
      from public.canchas c
     where c.id = new.cancha_id;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

CREATE OR REPLACE FUNCTION public.uso_cancha(p_id text, p_hoy date) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select jsonb_build_object(
    'reservas_total',   (select count(*) from reservas where cancha_id = p_id),
    'reservas_futuras', (select count(*) from reservas
                          where cancha_id = p_id and fecha >= p_hoy and estado = 'Confirmada'),
    'fijos_total',      (select count(*) from turnos_fijos where cancha_id = p_id),
    'fijos_activos',    (select count(*) from turnos_fijos where cancha_id = p_id and activo)
  );
$$;

-- ══ 8) POLÍTICAS RLS COMO EN 008 ════════════════════════════
CREATE POLICY "empleado ve su propio registro" ON public.empleados FOR SELECT TO authenticated USING ((email = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))));

CREATE POLICY "empleados crean reservas" ON public.reservas FOR INSERT TO authenticated WITH CHECK (public.es_empleado());

CREATE POLICY "empleados crean turnos fijos" ON public.turnos_fijos FOR INSERT TO authenticated WITH CHECK (public.es_empleado());

CREATE POLICY "empleados gestionan clientes" ON public.clientes TO authenticated USING (public.es_empleado()) WITH CHECK (public.es_empleado());

CREATE POLICY "empleados gestionan turnos fijos" ON public.turnos_fijos FOR SELECT TO authenticated USING (public.es_empleado());

CREATE POLICY "empleados leen canchas" ON public.canchas FOR SELECT TO authenticated USING (public.es_empleado());

CREATE POLICY "empleados leen configuracion" ON public.configuracion FOR SELECT TO authenticated USING (public.es_empleado());

CREATE POLICY "empleados modifican reservas" ON public.reservas FOR UPDATE TO authenticated USING (public.es_empleado()) WITH CHECK (public.es_empleado());

CREATE POLICY "empleados modifican turnos fijos" ON public.turnos_fijos FOR UPDATE TO authenticated USING (public.es_empleado()) WITH CHECK (public.es_empleado());

CREATE POLICY "empleados ven reservas" ON public.reservas FOR SELECT TO authenticated USING (public.es_empleado());

CREATE POLICY "jefes crean canchas" ON public.canchas FOR INSERT TO authenticated WITH CHECK (public.es_jefe());

CREATE POLICY "jefes editan canchas" ON public.canchas FOR UPDATE TO authenticated USING (public.es_jefe()) WITH CHECK (public.es_jefe());

CREATE POLICY "jefes editan configuracion" ON public.configuracion FOR UPDATE TO authenticated USING (public.es_jefe()) WITH CHECK (public.es_jefe());

CREATE POLICY "jefes eliminan canchas" ON public.canchas FOR DELETE TO authenticated USING (public.es_jefe());

CREATE POLICY "jefes eliminan reservas" ON public.reservas FOR DELETE TO authenticated USING (public.es_jefe());

CREATE POLICY "jefes gestionan egresos" ON public.egresos TO authenticated USING (public.es_jefe()) WITH CHECK (public.es_jefe());

CREATE POLICY "jefes modifican empleados" ON public.empleados TO authenticated USING (public.es_jefe()) WITH CHECK (public.es_jefe());

CREATE POLICY "jefes ven actividad" ON public.actividad FOR SELECT TO authenticated USING (public.es_jefe());

CREATE POLICY "jefes ven empleados" ON public.empleados FOR SELECT TO authenticated USING (public.es_jefe());

-- ══ 9) PERMISOS ═══════════════════════════════════════════
commit;
