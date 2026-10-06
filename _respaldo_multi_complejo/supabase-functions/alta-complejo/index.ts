// ─────────────────────────────────────────────────────────────
//  Edge Function: alta-complejo
//  La usa admin.html (solo super admins de la plataforma).
//
//  accion = "crear"    → crea el complejo (nombre, dirección/slug, horarios,
//                        canchas iniciales) con su primer jefe, y el usuario
//                        de login del jefe con una contraseña temporal.
//  accion = "resetear" → contraseña temporal nueva para cualquier persona de
//                        cualquier complejo (crea el usuario si le faltaba).
//
//  La parte de base de datos la hace admin_crear_complejo() (migración 009)
//  en una sola transacción, con la sesión del super admin.
//  Crear usuarios de login necesita la service_role key → solo en el servidor.
// ─────────────────────────────────────────────────────────────
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

// Contraseña temporal fácil de dictar (sin 0/O, 1/l/I)
function passwordTemporal(largo = 10) {
  const abc = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(largo));
  return Array.from(bytes, b => abc[b % abc.length]).join('');
}

const entero = (v: unknown, def = 0) => Number.isFinite(Number(v)) ? Math.trunc(Number(v)) : def;

async function manejar(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST')    return json({ error: 'Método no permitido.' }, 405);

  const url     = Deno.env.get('SUPABASE_URL')!;
  // La anon key también viene en el header "apikey" que manda el navegador
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '';
  const srvKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!url || !anonKey || !srvKey) {
    return json({ error: 'A la función le faltan las claves de Supabase (SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY).' }, 500);
  }
  const authHeader = req.headers.get('Authorization') ?? '';

  // 1) Quien llama tiene que ser super admin (se verifica con SU sesión)
  const comoUsuario = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: esAdmin, error: errAdmin } = await comoUsuario.rpc('es_super_admin');
  if (errAdmin || !esAdmin) return json({ error: 'Solo un administrador de la plataforma puede hacer esto.' }, 403);

  // 2) Datos
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: 'Datos inválidos.' }, 400); }
  const accion = body.accion === 'resetear' ? 'resetear' : 'crear';
  const email  = String(body.jefe_email ?? body.email ?? '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: 'El email no es válido.' }, 400);

  const admin = createClient(url, srvKey, { auth: { persistSession: false, autoRefreshToken: false } });

  // 3) Base de datos
  let complejo: unknown = null;
  if (accion === 'crear') {
    const { data, error } = await comoUsuario.rpc('admin_crear_complejo', {
      p_nombre:      String(body.nombre ?? '').trim(),
      p_slug:        String(body.slug ?? '').trim().toLowerCase(),
      p_jefe_email:  email,
      p_jefe_nombre: String(body.jefe_nombre ?? '').trim() || null,
      p_canchas_f5:  entero(body.canchas_f5),
      p_precio_f5:   Number(body.precio_f5) || 0,
      p_canchas_f7:  entero(body.canchas_f7),
      p_precio_f7:   Number(body.precio_f7) || 0,
      p_apertura:    entero(body.apertura, 9),
      p_cierre:      entero(body.cierre, 24),
    });
    if (error) return json({ error: error.message }, 400);
    complejo = data;
  } else {
    const { data: emp, error } = await admin.from('empleados').select('email').eq('email', email).maybeSingle();
    if (error) return json({ error: 'No se pudo verificar la persona: ' + error.message }, 500);
    if (!emp)  return json({ error: 'Ese email no pertenece a ningún complejo.' }, 404);
  }

  // 4) Usuario de login (si no existe se crea; "resetear" le pone una contraseña nueva)
  const { data: idExistente, error: errBuscar } = await admin.rpc('id_usuario_por_email', { p_email: email });
  if (errBuscar) return json({ error: 'No se pudo verificar el usuario: ' + errBuscar.message, complejo }, 500);

  const password = passwordTemporal();
  let creado = false;
  if (!idExistente) {
    const { error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (error) {
      return json({
        error: (accion === 'crear' ? 'El complejo se creó, pero no se pudo crear el usuario del jefe: ' : 'No se pudo crear el usuario: ')
          + error.message + '. Probá "Nueva contraseña" desde la lista.',
        complejo,
      }, 500);
    }
    creado = true;
  } else if (accion === 'resetear') {
    const { error } = await admin.auth.admin.updateUserById(idExistente, { password });
    if (error) return json({ error: 'No se pudo cambiar la contraseña: ' + error.message }, 500);
  }

  return json({
    ok: true,
    complejo,
    email,
    creado,
    // Solo se devuelve si se generó una contraseña nueva
    password: creado || accion === 'resetear' ? password : null,
  });
}

// Cualquier error inesperado vuelve como mensaje legible (y queda en Logs)
Deno.serve(async (req) => {
  try {
    return await manejar(req);
  } catch (e) {
    console.error(e);
    return json({ error: 'Error interno de la función: ' + ((e as Error)?.message ?? String(e)) }, 500);
  }
});
