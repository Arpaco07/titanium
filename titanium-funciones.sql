-- ============================================================================
-- TITANIUM · Funciones para Portal del socio y Control de acceso
-- Ejecutar en Supabase → SQL Editor → New query → pegar todo → Run
-- Seguro de correr varias veces (usa create or replace).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. consultar_socio(codigo, pin)
--    La usa el PORTAL DEL SOCIO. El socio entra con su código + PIN y ve su
--    paquete, días/visitas/horas restantes. Corre como "definer" para poder
--    leer aunque el socio NO tenga sesión, pero solo devuelve datos si el PIN
--    es correcto (así nadie ve datos ajenos con solo adivinar un código).
-- ----------------------------------------------------------------------------
create or replace function public.consultar_socio(p_codigo text, p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_socio  public.socios;
  v_memb   public.membresias;
  v_plan   public.planes;
begin
  select * into v_socio from public.socios
    where upper(codigo) = upper(trim(p_codigo)) limit 1;
  if not found then
    return json_build_object('ok', false, 'error', 'Socio no encontrado');
  end if;

  if v_socio.pin is null or v_socio.pin <> trim(p_pin) then
    return json_build_object('ok', false, 'error', 'PIN incorrecto');
  end if;

  select * into v_memb from public.membresias
    where socio_id = v_socio.id and estatus = 'activa'
    order by fecha_fin desc nulls last, creado_en desc limit 1;
  if v_memb.id is not null then
    select * into v_plan from public.planes where id = v_memb.plan_id;
  end if;

  return json_build_object(
    'ok', true,
    'codigo', v_socio.codigo,
    'nombre', v_socio.nombre_completo,
    'estatus', v_socio.estatus,
    'tiene_membresia', (v_memb.id is not null),
    'plan', v_plan.nombre,
    'plan_tipo', v_plan.tipo,
    'fecha_fin', v_memb.fecha_fin,
    'dias_restantes', case when v_memb.fecha_fin is not null
                           then (v_memb.fecha_fin - current_date) else null end,
    'visitas_restantes', v_memb.visitas_restantes,
    'horas_restantes', v_memb.horas_restantes
  );
end;
$$;

grant execute on function public.consultar_socio(text, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. validar_acceso(identificador, tipo)
--    La usa la PANTALLA DE ACCESO en recepción (staff con sesión). Recibe el
--    código del QR o un PIN, valida la membresía activa, decide permitir o
--    bloquear, registra el acceso y descuenta 1 visita si el plan es por
--    visitas. Devuelve todo lo necesario para mostrar en pantalla.
--    Solo authenticated (la opera recepción logueada).
-- ----------------------------------------------------------------------------
create or replace function public.validar_acceso(p_identificador text, p_tipo text default 'entrada')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_socio     public.socios;
  v_memb      public.membresias;
  v_plan      public.planes;
  v_permitido boolean := false;
  v_motivo    text := null;
  v_metodo    text := 'qr';
  v_tipo      text := coalesce(nullif(trim(p_tipo),''), 'entrada');
  v_id        text := trim(p_identificador);
begin
  -- Buscar por código (QR); si no, por PIN
  select * into v_socio from public.socios where upper(codigo) = upper(v_id) limit 1;
  if not found then
    select * into v_socio from public.socios where pin = v_id limit 1;
    v_metodo := 'pin';
  end if;
  if not found then
    return json_build_object('permitido', false, 'motivo', 'No identificado');
  end if;

  if v_socio.estatus <> 'activo' then
    v_motivo := 'Socio inactivo';
  else
    select * into v_memb from public.membresias
      where socio_id = v_socio.id and estatus = 'activa'
      order by fecha_fin desc nulls last, creado_en desc limit 1;

    if v_memb.id is null then
      v_motivo := 'Sin membresía activa';
    else
      select * into v_plan from public.planes where id = v_memb.plan_id;
      if v_memb.fecha_fin is not null and v_memb.fecha_fin < current_date then
        v_motivo := 'Membresía vencida';
      elsif v_plan.tipo = 'visitas' and coalesce(v_memb.visitas_restantes,0) <= 0 then
        v_motivo := 'Sin visitas disponibles';
      elsif v_plan.tipo = 'horas' and coalesce(v_memb.horas_restantes,0) <= 0 then
        v_motivo := 'Sin horas disponibles';
      else
        v_permitido := true;
      end if;
    end if;
  end if;

  -- Registrar el intento de acceso (permitido o bloqueado)
  insert into public.accesos(socio_id, membresia_id, tipo, metodo, resultado, motivo_bloqueo)
  values (v_socio.id, v_memb.id, v_tipo, v_metodo,
          case when v_permitido then 'permitido' else 'bloqueado' end, v_motivo);

  -- Descontar 1 visita si entra y el plan es por visitas
  if v_permitido and v_tipo = 'entrada' and v_plan.tipo = 'visitas' then
    update public.membresias set visitas_restantes = visitas_restantes - 1 where id = v_memb.id;
    v_memb.visitas_restantes := v_memb.visitas_restantes - 1;
  end if;

  return json_build_object(
    'permitido', v_permitido,
    'motivo', v_motivo,
    'tipo', v_tipo,
    'nombre', v_socio.nombre_completo,
    'codigo', v_socio.codigo,
    'plan', v_plan.nombre,
    'dias_restantes', case when v_memb.fecha_fin is not null
                           then (v_memb.fecha_fin - current_date) else null end,
    'visitas_restantes', v_memb.visitas_restantes,
    'horas_restantes', v_memb.horas_restantes
  );
end;
$$;

grant execute on function public.validar_acceso(text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. aforo_actual()  → cuántos socios están DENTRO ahora mismo (hoy)
--    Cuenta entradas permitidas menos salidas de hoy.
-- ----------------------------------------------------------------------------
create or replace function public.aforo_actual()
returns integer
language sql
security definer
set search_path = public
as $$
  select greatest(0,
    count(*) filter (where tipo='entrada' and resultado='permitido')
  - count(*) filter (where tipo='salida'))::int
  from public.accesos
  where momento::date = current_date;
$$;

grant execute on function public.aforo_actual() to authenticated;

-- ============================================================================
-- FIN. 3 funciones creadas.
-- ============================================================================
