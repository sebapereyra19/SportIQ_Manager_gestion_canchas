-- ════════════════════════════════════════════════════════════
-- 010 — Roles visibles: Admin (jefe) y Staff (empleado)
-- Solo cambia los mensajes de error que ve el usuario.
-- Los valores de la columna empleados.rol siguen siendo 'jefe' / 'empleado'.
-- ════════════════════════════════════════════════════════════
do $$
declare f record; def text;
begin
  for f in
    select p.oid from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('crear_cancha', 'cambiar_estado_cancha', 'eliminar_cancha', 'empleados_exigir_un_jefe')
  loop
    def := pg_get_functiondef(f.oid);
    def := replace(def, 'Solo los jefes pueden', 'Solo un Admin puede');
    def := replace(def, 'Tiene que quedar al menos un jefe activo.', 'Tiene que quedar al menos un Admin activo.');
    execute def;
  end loop;
end $$;
