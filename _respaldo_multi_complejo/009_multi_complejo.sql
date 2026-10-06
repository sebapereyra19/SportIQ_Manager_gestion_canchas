-- ─────────────────────────────────────────────────────────────
--  009 · Multi-complejo (multi-tenant)
--
--  Un mismo Supabase atiende a varios complejos. Cada fila de cada tabla
--  pertenece a un complejo (columna complejo_id) y las políticas RLS hacen
--  que cada persona vea y toque SOLO los datos de su complejo.
--
--  · complejos       → un registro por cliente del sistema (nombre, slug, activo).
--                      El slug arma la URL pública: tusitio.com/<slug>
--  · super_admins    → quién administra la plataforma (alta de complejos).
--  · complejo_id     → en empleados, canchas, clientes, reservas, egresos,
--                      turnos_fijos, configuracion y actividad.
--                      Por defecto toma el complejo de quien está logueado,
--                      así el panel no necesita mandarlo en cada alta.
--  · Cada empleado pertenece a UN solo complejo (el email sigue siendo único).
--
--  Todo lo que ya existe pasa al primer complejo (abajo, "COMPLEJO INICIAL").
--
--  Correr UNA vez en Supabase → SQL Editor DESPUÉS de 001 a 008.
--  Todo corre en una transacción: si algo falla, no queda nada a medias.
-- ─────────────────────────────────────────────────────────────

begin;

-- ══ 1) COMPLEJOS Y SUPER ADMINS ═════════════════════════════
create table if not exists public.complejos (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null check (trim(nombre) <> ''),
  slug       text not null unique
             check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) between 3 and 40),
  activo     boolean not null default true,      -- false = suspendido: nadie entra al panel
  created_at timestamptz not null default now()
);

create table if not exists public.super_admins (
  email      text primary key check (email = lower(email)),
  created_at timestamptz not null default now()
);

alter table public.complejos    enable row level security;
alter table public.super_admins enable row level security;   -- sin políticas: solo lo leen las funciones

create or replace function public.es_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.super_admins
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- ══ 2) COMPLEJO INICIAL (los datos que ya existen) ═══════════
-- Cambiá nombre y slug si querés (también se pueden editar después desde admin.html).
insert into public.complejos (nombre, slug)
select 'Mi complejo', 'mi-complejo'
where not exists (select 1 from public.complejos);

-- ══ 3) COLUMNA complejo_id EN TODAS LAS TABLAS ══════════════
do $$
declare
  v_id  uuid := (select id from public.complejos order by created_at limit 1);
  t     text;
begin
  foreach t in array array['empleados', 'canchas', 'clientes', 'reservas', 'egresos',
                           'turnos_fijos', 'configuracion', 'actividad']
  loop
    execute format('alter table public.%I add column if not exists complejo_id uuid', t);
    execute format('update public.%I set complejo_id = %L where complejo_id is null', t, v_id);
    execute format('alter table public.%I alter column complejo_id set not null', t);
    begin
      execute format('alter table public.%I add constraint %I foreign key (complejo_id) '
                     'references public.complejos(id) on delete restrict', t, t || '_complejo_fk');
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ══ 4) ¿DE QUÉ COMPLEJO ES QUIEN ESTÁ LOGUEADO? ══════════════
-- null si no es empleado activo o si su complejo está suspendido.
create or replace function public.complejo_actual()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select e.complejo_id
    from public.empleados e
    join public.complejos c on c.id = e.complejo_id
   where e.email = lower(coalesce(auth.jwt() ->> 'email', ''))
     and e.activo
     and c.activo
   limit 1;
$$;

create or replace function public.es_empleado()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.complejo_actual() is not null;
$$;

create or replace function public.es_jefe()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.empleados e
      join public.complejos c on c.id = e.complejo_id
     where e.email = lower(coalesce(auth.jwt() ->> 'email', ''))
       and e.activo and e.rol = 'jefe' and c.activo
  );
$$;

-- El panel no necesita mandar complejo_id: lo completa la base.
-- (n8n / Edge Functions con service_role SÍ tienen que mandarlo.)
alter table public.empleados     alter column complejo_id set default public.complejo_actual();
alter table public.canchas       alter column complejo_id set default public.complejo_actual();
alter table public.clientes      alter column complejo_id set default public.complejo_actual();
alter table public.reservas      alter column complejo_id set default public.complejo_actual();
alter table public.egresos       alter column complejo_id set default public.complejo_actual();
alter table public.turnos_fijos  alter column complejo_id set default public.complejo_actual();
alter table public.configuracion alter column complejo_id set default public.complejo_actual();
alter table public.actividad     alter column complejo_id set default public.complejo_actual();

-- ══ 5) CLAVES: lo que era único pasa a ser único POR COMPLEJO ══
-- Primero se sueltan las referencias entre tablas (se vuelven a crear abajo).
do $$
declare r record;
begin
  for r in
    select conname, conrelid::regclass as tabla
      from pg_constraint
     where contype = 'f'
       and conrelid in ('public.reservas'::regclass, 'public.turnos_fijos'::regclass)
       and confrelid in ('public.canchas'::regclass, 'public.clientes'::regclass, 'public.turnos_fijos'::regclass)
  loop
    execute format('alter table %s drop constraint %I', r.tabla, r.conname);
  end loop;
end $$;

-- Canchas: el id ('F5-1') se repite entre complejos → clave (complejo_id, id)
alter table public.canchas drop constraint if exists canchas_pkey;
alter table public.canchas add constraint canchas_pkey primary key (complejo_id, id);

-- Clientes: el mismo teléfono puede ser cliente de dos complejos distintos
alter table public.clientes drop constraint if exists clientes_telefono_key;
alter table public.clientes add constraint clientes_complejo_telefono_key unique (complejo_id, telefono);
alter table public.clientes add constraint clientes_complejo_id_key unique (complejo_id, id);

alter table public.turnos_fijos add constraint turnos_fijos_complejo_id_key unique (complejo_id, id);

-- Una reserva / turno fijo solo puede apuntar a canchas, clientes y turnos de SU complejo
alter table public.reservas
  add constraint reservas_cancha_fk  foreign key (complejo_id, cancha_id)
      references public.canchas (complejo_id, id),
  add constraint reservas_cliente_fk foreign key (complejo_id, cliente_id)
      references public.clientes (complejo_id, id),
  add constraint reservas_turno_fijo_fk foreign key (complejo_id, turno_fijo_id)
      references public.turnos_fijos (complejo_id, id) on delete set null (turno_fijo_id);

alter table public.turnos_fijos
  add constraint turnos_fijos_cancha_fk  foreign key (complejo_id, cancha_id)
      references public.canchas (complejo_id, id),
  add constraint turnos_fijos_cliente_fk foreign key (complejo_id, cliente_id)
      references public.clientes (complejo_id, id);

-- Sin superposición: ahora es "misma cancha DEL MISMO complejo"
alter table public.reservas drop constraint if exists reservas_sin_superposicion;
alter table public.reservas add constraint reservas_sin_superposicion
  exclude using gist (complejo_id with =, cancha_id with =, rango with &&)
  where (estado in ('Confirmada', 'Asistida'));

alter table public.turnos_fijos drop constraint if exists turnos_fijos_sin_superposicion;
alter table public.turnos_fijos add constraint turnos_fijos_sin_superposicion
  exclude using gist (complejo_id with =, cancha_id with =, dia_semana with =, minutos with &&)
  where (activo);

-- Configuración: una fila por complejo (antes: una sola fila con id = 1)
alter table public.configuracion drop constraint if exists configuracion_pkey;
alter table public.configuracion drop constraint if exists configuracion_id_check;
alter table public.configuracion drop column if exists id;
alter table public.configuracion add constraint configuracion_pkey primary key (complejo_id);

-- Índices para que filtrar por complejo sea rápido
drop index if exists public.reservas_fecha_idx;
drop index if exists public.egresos_fecha_idx;
drop index if exists public.actividad_fecha_idx;
create index if not exists reservas_complejo_fecha_idx  on public.reservas  (complejo_id, fecha);
create index if not exists egresos_complejo_fecha_idx   on public.egresos   (complejo_id, fecha);
create index if not exists actividad_complejo_fecha_idx on public.actividad (complejo_id, creado_at desc);
create index if not exists empleados_complejo_idx       on public.empleados (complejo_id);
create index if not exists turnos_fijos_complejo_idx    on public.turnos_fijos (complejo_id);

-- ══ 6) SEGURIDAD (RLS): cada uno ve solo su complejo ════════
-- Se borran todas las políticas viejas de estas tablas y se crean de nuevo.
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

-- (select f()) hace que Postgres calcule la función una vez por consulta, no por fila.

-- complejos: cada empleado ve el suyo; los super admins ven y editan todos
create policy "ven su complejo" on public.complejos
  for select to authenticated
  using (id = (select public.complejo_actual()) or (select public.es_super_admin()));
create policy "super admins editan complejos" on public.complejos
  for update to authenticated
  using ((select public.es_super_admin())) with check ((select public.es_super_admin()));

-- empleados
create policy "empleado ve su propio registro" on public.empleados
  for select to authenticated
  using (email = lower(coalesce(auth.jwt() ->> 'email', '')));
create policy "jefes gestionan su equipo" on public.empleados
  for all to authenticated
  using      (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()))
  with check (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()));

-- canchas
create policy "empleados leen canchas" on public.canchas
  for select to authenticated using (complejo_id = (select public.complejo_actual()));
create policy "jefes crean canchas" on public.canchas
  for insert to authenticated
  with check (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()));
create policy "jefes editan canchas" on public.canchas
  for update to authenticated
  using      (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()))
  with check (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()));
create policy "jefes eliminan canchas" on public.canchas
  for delete to authenticated
  using (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()));

-- clientes
create policy "empleados gestionan clientes" on public.clientes
  for all to authenticated
  using      (complejo_id = (select public.complejo_actual()))
  with check (complejo_id = (select public.complejo_actual()));

-- reservas (eliminar: solo jefes)
create policy "empleados ven reservas" on public.reservas
  for select to authenticated using (complejo_id = (select public.complejo_actual()));
create policy "empleados crean reservas" on public.reservas
  for insert to authenticated with check (complejo_id = (select public.complejo_actual()));
create policy "empleados modifican reservas" on public.reservas
  for update to authenticated
  using      (complejo_id = (select public.complejo_actual()))
  with check (complejo_id = (select public.complejo_actual()));
create policy "jefes eliminan reservas" on public.reservas
  for delete to authenticated
  using (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()));

-- egresos (solo jefes)
create policy "jefes gestionan egresos" on public.egresos
  for all to authenticated
  using      (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()))
  with check (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()));

-- turnos fijos
create policy "empleados ven turnos fijos" on public.turnos_fijos
  for select to authenticated using (complejo_id = (select public.complejo_actual()));
create policy "empleados crean turnos fijos" on public.turnos_fijos
  for insert to authenticated with check (complejo_id = (select public.complejo_actual()));
create policy "empleados modifican turnos fijos" on public.turnos_fijos
  for update to authenticated
  using      (complejo_id = (select public.complejo_actual()))
  with check (complejo_id = (select public.complejo_actual()));

-- configuración (horarios)
create policy "empleados leen configuracion" on public.configuracion
  for select to authenticated using (complejo_id = (select public.complejo_actual()));
create policy "jefes editan configuracion" on public.configuracion
  for update to authenticated
  using      (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()))
  with check (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()));

-- actividad (solo jefes)
create policy "jefes ven actividad" on public.actividad
  for select to authenticated
  using (complejo_id = (select public.complejo_actual()) and (select public.es_jefe()));

-- ══ 7) FUNCIONES Y TRIGGERS AJUSTADOS AL COMPLEJO ═══════════

-- Tiene que quedar al menos un jefe activo EN CADA complejo
create or replace function public.empleados_exigir_un_jefe()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.empleados
                  where complejo_id = old.complejo_id and rol = 'jefe' and activo) then
    raise exception 'Tiene que quedar al menos un jefe activo.' using errcode = 'P0001';
  end if;
  return null;
end;
$$;

-- Precio = precio de la cancha de ESE complejo × duración
create or replace function public.reservas_calcular_precio()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT'
     or new.cancha_id is distinct from old.cancha_id
     or new.duracion  is distinct from old.duracion then
    select c.precio_hora * new.duracion
      into new.precio
      from public.canchas c
     where c.complejo_id = new.complejo_id and c.id = new.cancha_id;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- Historial: cada registro queda en el complejo de la fila que cambió
create or replace function public.registrar_actividad()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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

  elsif tg_table_name = 'configuracion' then
    if new.hora_apertura = old.hora_apertura and new.hora_cierre = old.hora_cierre then return null; end if;
    accion := 'Cambió horarios';
    detalle := format('%s a %s hs → %s a %s hs', old.hora_apertura, old.hora_cierre, new.hora_apertura, new.hora_cierre);
  else
    return null;
  end if;

  insert into actividad (complejo_id, usuario, email, accion, tabla, registro_id, detalle)
  values (r.complejo_id, usuario_actual(), lower(auth.jwt() ->> 'email'), accion, tg_table_name,
          case when tg_table_name = 'configuracion' then null
               else (to_jsonb(r) ->> case when tg_table_name = 'empleados' then 'email' else 'id' end) end,
          detalle);
  return null;
end;
$$;

create or replace function public.registrar_actividad_cancha()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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

  insert into actividad (complejo_id, usuario, email, accion, tabla, registro_id, detalle)
  values (r.complejo_id, usuario_actual(), lower(auth.jwt() ->> 'email'), accion, 'canchas', r.id, detalle);
  return null;
end;
$$;

-- Turnos fijos: solo los del complejo propio
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
  v_complejo  uuid := public.complejo_actual();
  v_hasta     date := least(coalesce(p_hasta, p_hoy + 62), p_hoy + 366);
  creadas     int := 0;
  conflictos  jsonb := '[]'::jsonb;
begin
  if v_complejo is null then
    raise exception 'Sin permiso.' using errcode = '42501';
  end if;

  for t in
    select tf.*, c.nombre as cliente
      from turnos_fijos tf join clientes c on c.id = tf.cliente_id
     where tf.complejo_id = v_complejo
       and tf.activo and (p_turno_id is null or tf.id = p_turno_id)
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
          insert into reservas (complejo_id, cancha_id, cliente_id, fecha, hora_inicio, duracion, origen, notas,
                                turno_fijo_id, fecha_turno_fijo)
          values (t.complejo_id, t.cancha_id, t.cliente_id, d, t.hora_inicio, t.duracion, 'Turno fijo', t.notas, t.id, d);
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

create or replace function public.baja_turno_fijo(p_id uuid, p_hoy date)
returns int
language plpgsql
set search_path = public
as $$
declare
  n int;
  v_complejo uuid := public.complejo_actual();
begin
  if v_complejo is null then
    raise exception 'Sin permiso.' using errcode = '42501';
  end if;
  update turnos_fijos set activo = false, hasta = p_hoy
   where id = p_id and complejo_id = v_complejo and activo;
  update reservas
     set estado = 'Cancelada', motivo_cancelacion = 'Baja del turno fijo'
   where turno_fijo_id = p_id and complejo_id = v_complejo and fecha > p_hoy and estado = 'Confirmada';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- security definer: por eso chequea a mano que el turno sea del complejo propio
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
  p_hasta      date default null
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
  v_complejo uuid := public.complejo_actual();
  v_desde    date := greatest(coalesce(p_desde, p_hoy), p_hoy);
  v_notas    text := nullif(trim(coalesce(p_notas, '')), '');
  movidas    int := 0;
  no_movidas jsonb := '[]'::jsonb;
  gen        jsonb;
begin
  if v_complejo is null then
    raise exception 'Sin permiso.' using errcode = '42501';
  end if;
  if p_dia not between 0 and 6 or p_duracion not between 1 and 5 then
    raise exception 'Datos inválidos.' using errcode = '22023';
  end if;

  select * into t from public.turnos_fijos
   where id = p_id and complejo_id = v_complejo and activo
   for update;
  if not found then
    raise exception 'El turno fijo no existe o ya fue dado de baja.' using errcode = 'P0002';
  end if;

  delta := ((p_dia - t.dia_semana) + 7) % 7;

  -- 1) el turno en sí (la cancha y el cliente tienen que ser del mismo complejo:
  --    lo garantizan las claves foráneas compuestas)
  update public.turnos_fijos
     set cancha_id = p_cancha, cliente_id = p_cliente_id, dia_semana = p_dia,
         hora_inicio = p_hora, duracion = p_duracion, notas = v_notas
   where id = p_id;

  perform set_config('app.editando_turno_fijo', 'on', true);

  for r in
    select * from public.reservas
     where turno_fijo_id = p_id and complejo_id = v_complejo and fecha_turno_fijo >= v_desde
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

  perform set_config('app.editando_turno_fijo', 'off', true);

  gen := public.generar_turnos_fijos(p_hoy, p_hasta, p_id);

  return jsonb_build_object(
    'movidas',    movidas,
    'no_movidas', no_movidas,
    'creadas',    coalesce((gen ->> 'creadas')::int, 0),
    'conflictos', coalesce(gen -> 'conflictos', '[]'::jsonb)
  );
end;
$$;

-- Canchas: ids y orden se numeran por complejo
create or replace function public.crear_cancha(p_tipo text, p_etiqueta text, p_precio numeric)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  n   int;
  nid text;
  v_complejo uuid := public.complejo_actual();
begin
  if v_complejo is null or not es_jefe() then raise exception 'Solo los jefes pueden crear canchas.'; end if;
  if p_tipo not in ('F5', 'F7') then raise exception 'Tipo de cancha inválido.'; end if;
  if coalesce(trim(p_etiqueta), '') = '' then raise exception 'Ingresá el nombre de la cancha.'; end if;
  if p_precio is null or p_precio < 0 then raise exception 'Precio inválido.'; end if;

  -- evita ids repetidos si dos jefes del mismo complejo crean a la vez
  perform pg_advisory_xact_lock(hashtext('canchas:' || v_complejo::text));
  select coalesce(max(substring(id from '-(\d+)$')::int), 0) + 1 into n
    from canchas where complejo_id = v_complejo and tipo = p_tipo;
  nid := p_tipo || '-' || n;

  insert into canchas (complejo_id, id, tipo, etiqueta, precio_hora, orden)
  values (v_complejo, nid, p_tipo, trim(p_etiqueta), p_precio,
          (select coalesce(max(orden), 0) + 1 from canchas where complejo_id = v_complejo));
  return jsonb_build_object('id', nid);
end;
$$;

create or replace function public.uso_cancha(p_id text, p_hoy date)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'reservas_total',   (select count(*) from reservas
                          where complejo_id = complejo_actual() and cancha_id = p_id),
    'reservas_futuras', (select count(*) from reservas
                          where complejo_id = complejo_actual() and cancha_id = p_id
                            and fecha >= p_hoy and estado = 'Confirmada'),
    'fijos_total',      (select count(*) from turnos_fijos
                          where complejo_id = complejo_actual() and cancha_id = p_id),
    'fijos_activos',    (select count(*) from turnos_fijos
                          where complejo_id = complejo_actual() and cancha_id = p_id and activo)
  );
$$;

create or replace function public.cambiar_estado_cancha(p_id text, p_activa boolean, p_hoy date)
returns jsonb
language plpgsql
set search_path = public
as $$
declare uso jsonb;
begin
  if not es_jefe() then raise exception 'Solo los jefes pueden modificar canchas.'; end if;
  if not p_activa then
    uso := uso_cancha(p_id, p_hoy);
    if (uso ->> 'reservas_futuras')::int > 0 or (uso ->> 'fijos_activos')::int > 0 then
      return jsonb_build_object('ok', false, 'uso', uso);
    end if;
  end if;
  update canchas set activa = p_activa where complejo_id = complejo_actual() and id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.eliminar_cancha(p_id text, p_hoy date, p_forzar boolean default false)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  uso jsonb;
  v_complejo uuid := public.complejo_actual();
begin
  if v_complejo is null or not es_jefe() then raise exception 'Solo los jefes pueden eliminar canchas.'; end if;
  uso := uso_cancha(p_id, p_hoy);

  if (uso ->> 'reservas_total')::int = 0 and (uso ->> 'fijos_total')::int = 0 then
    delete from canchas where complejo_id = v_complejo and id = p_id;
    return jsonb_build_object('ok', true, 'borrada', true);
  end if;

  if ((uso ->> 'reservas_futuras')::int > 0 or (uso ->> 'fijos_activos')::int > 0) and not p_forzar then
    return jsonb_build_object('ok', false, 'uso', uso);
  end if;

  update turnos_fijos set activo = false, hasta = p_hoy
   where complejo_id = v_complejo and cancha_id = p_id and activo;
  update reservas set estado = 'Cancelada', motivo_cancelacion = 'Cancha eliminada'
   where complejo_id = v_complejo and cancha_id = p_id and fecha >= p_hoy and estado = 'Confirmada';
  update canchas set activa = false, eliminada = true where complejo_id = v_complejo and id = p_id;
  return jsonb_build_object('ok', true, 'borrada', false);
end;
$$;

-- ══ 8) PERFIL DE QUIEN ENTRA AL PANEL ═══════════════════════
-- Una sola llamada al iniciar sesión: datos del empleado + su complejo.
create or replace function public.mi_perfil()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object(
              'email', e.email, 'nombre', e.nombre, 'rol', e.rol, 'activo', e.activo,
              'complejo_id', c.id, 'complejo_nombre', c.nombre, 'complejo_slug', c.slug,
              'complejo_activo', c.activo, 'super_admin', public.es_super_admin())
       from public.empleados e
       join public.complejos c on c.id = e.complejo_id
      where e.email = lower(coalesce(auth.jwt() ->> 'email', ''))),
    jsonb_build_object('email', null, 'super_admin', public.es_super_admin())
  );
$$;

-- ══ 9) DATOS PÚBLICOS DE UN COMPLEJO (para el sitio de reservas) ══
-- tusitio.com/<slug> → nombre, horarios y canchas activas con su precio.
-- No expone clientes, reservas ni caja.
create or replace function public.complejo_publico(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'id', c.id, 'nombre', c.nombre, 'slug', c.slug,
           'hora_apertura', coalesce(cf.hora_apertura, 9),
           'hora_cierre',   coalesce(cf.hora_cierre, 24),
           'canchas', coalesce((
              select jsonb_agg(jsonb_build_object('id', k.id, 'tipo', k.tipo, 'etiqueta', k.etiqueta,
                                                  'precio_hora', k.precio_hora) order by k.orden)
                from public.canchas k
               where k.complejo_id = c.id and k.activa and not k.eliminada), '[]'::jsonb))
    from public.complejos c
    left join public.configuracion cf on cf.complejo_id = c.id
   where c.slug = lower(trim(p_slug)) and c.activo;
$$;

-- ══ 10) ADMINISTRACIÓN DE LA PLATAFORMA (solo super admins) ══

-- Slugs que no se pueden usar porque chocan con rutas del sitio
create or replace function public.slug_reservado(p_slug text)
returns boolean
language sql
immutable
as $$
  select p_slug = any (array['admin', 'panel', 'api', 'app', 'login', 'www', 'public',
                             'static', 'assets', 'reservas', 'soporte', 'ayuda']);
$$;

create or replace function public.admin_listar_complejos()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.es_super_admin() then
    raise exception 'Solo para administradores de la plataforma.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'created_at') from (
      select jsonb_build_object(
        'id', c.id, 'nombre', c.nombre, 'slug', c.slug, 'activo', c.activo, 'created_at', c.created_at,
        'jefes', coalesce((select jsonb_agg(jsonb_build_object('email', e.email, 'nombre', e.nombre, 'activo', e.activo)
                                            order by e.email)
                             from empleados e where e.complejo_id = c.id and e.rol = 'jefe'), '[]'::jsonb),
        'empleados',      (select count(*) from empleados e where e.complejo_id = c.id and e.activo),
        'canchas',        (select count(*) from canchas k where k.complejo_id = c.id and k.activa and not k.eliminada),
        'reservas_30d',   (select count(*) from reservas r where r.complejo_id = c.id
                                                       and r.created_at >= now() - interval '30 days'),
        'ultimo_acceso',  (select max(e.ultimo_acceso) from empleados e where e.complejo_id = c.id)
      ) as x
      from complejos c
    ) s
  ), '[]'::jsonb);
end;
$$;

-- Crea el complejo con su configuración, sus canchas iniciales y su primer jefe.
-- El usuario de login del jefe lo crea la Edge Function "alta-complejo".
create or replace function public.admin_crear_complejo(
  p_nombre      text,
  p_slug        text,
  p_jefe_email  text,
  p_jefe_nombre text    default null,
  p_canchas_f5  int     default 0,
  p_precio_f5   numeric default 0,
  p_canchas_f7  int     default 0,
  p_precio_f7   numeric default 0,
  p_apertura    int     default 9,
  p_cierre      int     default 24
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id    uuid;
  v_slug  text := lower(trim(p_slug));
  v_email text := lower(trim(p_jefe_email));
  i       int;
  orden   int := 0;
begin
  if not public.es_super_admin() then
    raise exception 'Solo para administradores de la plataforma.' using errcode = '42501';
  end if;
  if coalesce(trim(p_nombre), '') = '' then raise exception 'Ingresá el nombre del complejo.'; end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(v_slug) not between 3 and 40 then
    raise exception 'La dirección solo puede tener minúsculas, números y guiones (3 a 40 caracteres).';
  end if;
  if public.slug_reservado(v_slug) then raise exception 'La dirección "%" está reservada, elegí otra.', v_slug; end if;
  if exists (select 1 from complejos where slug = v_slug) then
    raise exception 'Ya hay un complejo con la dirección "%".', v_slug;
  end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'El email del jefe no es válido.'; end if;
  if exists (select 1 from empleados where email = v_email) then
    raise exception 'El email % ya pertenece a otro complejo (cada persona puede estar en uno solo).', v_email;
  end if;
  if coalesce(p_canchas_f5, 0) not between 0 and 30 or coalesce(p_canchas_f7, 0) not between 0 and 30 then
    raise exception 'Cantidad de canchas inválida.';
  end if;

  insert into complejos (nombre, slug) values (trim(p_nombre), v_slug) returning id into v_id;
  insert into configuracion (complejo_id, hora_apertura, hora_cierre) values (v_id, p_apertura, p_cierre);

  for i in 1 .. coalesce(p_canchas_f5, 0) loop
    orden := orden + 1;
    insert into canchas (complejo_id, id, tipo, etiqueta, precio_hora, orden)
    values (v_id, 'F5-' || i, 'F5', 'Cancha ' || i, coalesce(p_precio_f5, 0), orden);
  end loop;
  for i in 1 .. coalesce(p_canchas_f7, 0) loop
    orden := orden + 1;
    insert into canchas (complejo_id, id, tipo, etiqueta, precio_hora, orden)
    values (v_id, 'F7-' || i, 'F7', 'Cancha ' || i, coalesce(p_precio_f7, 0), orden);
  end loop;

  insert into empleados (complejo_id, email, nombre, rol)
  values (v_id, v_email, nullif(trim(coalesce(p_jefe_nombre, '')), ''), 'jefe');

  return jsonb_build_object('id', v_id, 'slug', v_slug, 'jefe_email', v_email);
end;
$$;

-- Cambiar nombre, dirección o suspender / reactivar un complejo
create or replace function public.admin_editar_complejo(
  p_id     uuid,
  p_nombre text    default null,
  p_slug   text    default null,
  p_activo boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_slug text := lower(trim(p_slug));
begin
  if not public.es_super_admin() then
    raise exception 'Solo para administradores de la plataforma.' using errcode = '42501';
  end if;
  if p_slug is not null then
    if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(v_slug) not between 3 and 40 then
      raise exception 'La dirección solo puede tener minúsculas, números y guiones (3 a 40 caracteres).';
    end if;
    if public.slug_reservado(v_slug) then raise exception 'La dirección "%" está reservada, elegí otra.', v_slug; end if;
    if exists (select 1 from complejos where slug = v_slug and id <> p_id) then
      raise exception 'Ya hay un complejo con la dirección "%".', v_slug;
    end if;
  end if;
  if p_nombre is not null and trim(p_nombre) = '' then raise exception 'El nombre no puede quedar vacío.'; end if;

  update complejos
     set nombre = coalesce(trim(p_nombre), nombre),
         slug   = coalesce(v_slug, slug),
         activo = coalesce(p_activo, activo)
   where id = p_id;
  if not found then raise exception 'El complejo no existe.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ══ 11) PERMISOS DE LA API ══════════════════════════════════
grant select, update on public.complejos to authenticated;
grant select on public.complejos to service_role;
grant select, insert, update, delete on public.super_admins to service_role;

grant execute on function public.complejo_actual()  to authenticated;
grant execute on function public.es_super_admin()   to authenticated;
grant execute on function public.mi_perfil()        to authenticated;
grant execute on function public.complejo_publico(text) to anon, authenticated;

revoke execute on function public.admin_listar_complejos() from public, anon;
revoke execute on function public.admin_crear_complejo(text, text, text, text, int, numeric, int, numeric, int, int) from public, anon;
revoke execute on function public.admin_editar_complejo(uuid, text, text, boolean) from public, anon;
grant  execute on function public.admin_listar_complejos() to authenticated;
grant  execute on function public.admin_crear_complejo(text, text, text, text, int, numeric, int, numeric, int, int) to authenticated;
grant  execute on function public.admin_editar_complejo(uuid, text, text, boolean) to authenticated;

-- ══ 12) VOS COMO SUPER ADMIN ════════════════════════════════
-- Reemplazá por TU email de login y descomentá (o corrélo aparte después):
-- insert into public.super_admins (email) values (lower('tu-email@ejemplo.com')) on conflict do nothing;

commit;

-- Verificación
select c.nombre, c.slug,
       (select count(*) from public.empleados    e where e.complejo_id = c.id) as empleados,
       (select count(*) from public.canchas      k where k.complejo_id = c.id) as canchas,
       (select count(*) from public.reservas     r where r.complejo_id = c.id) as reservas,
       (select count(*) from public.super_admins) as super_admins
  from public.complejos c;
