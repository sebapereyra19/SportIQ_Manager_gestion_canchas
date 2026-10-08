-- Dar de baja un turno fijo: las reservas futuras se ELIMINAN en vez de quedar
-- como "Cancelada" (ensuciaban el historial del cliente con decenas de canceladas).

create or replace function public.baja_turno_fijo(p_id uuid, p_hoy date)
returns int
language plpgsql
set search_path = public
as $$
declare n int;
begin
  if not public.es_empleado() then
    raise exception 'Sin permiso.' using errcode = '42501';
  end if;
  update turnos_fijos set activo = false, hasta = p_hoy where id = p_id and activo;
  delete from reservas
   where turno_fijo_id = p_id and fecha > p_hoy and estado = 'Confirmada';
  get diagnostics n = row_count;
  return n;
end;
$$;
grant execute on function public.baja_turno_fijo(uuid, date) to authenticated;

-- Limpia las canceladas que ya había dejado una baja anterior
delete from public.reservas
 where estado = 'Cancelada' and motivo_cancelacion = 'Baja del turno fijo';
