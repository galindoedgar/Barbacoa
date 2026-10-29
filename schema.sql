-- Barbacoa a domicilio: esquema para Supabase
-- Pégalo completo en Supabase > SQL Editor > Run. Se puede correr más de una vez sin romper nada.

-- ============ Administradores ============
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.admins enable row level security;
-- sin políticas: nadie lee esta tabla directo, solo la función soy_admin()

create or replace function public.soy_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ============ Ajustes (una sola fila) ============
create table if not exists public.ajustes (
  id int primary key default 1 check (id = 1),
  negocio text not null default 'Barbacoa a domicilio',
  whatsapp text not null default '',
  dias int[] not null default '{0}',            -- 0 = domingo, 1 = lunes ... 6 = sábado
  inicio time not null default '08:00',
  fin time not null default '13:30',
  intervalo_min int not null default 30 check (intervalo_min between 10 and 120),
  anticipacion_min int not null default 60 check (anticipacion_min >= 0),
  dias_mostrados int not null default 2 check (dias_mostrados between 1 and 6),
  cupo_por_horario int not null default 5 check (cupo_por_horario >= 1),
  envio numeric(8,2) not null default 25 check (envio >= 0),
  minimo numeric(8,2) not null default 270 check (minimo >= 0),
  lealtad_cada int not null default 3 check (lealtad_cada >= 0),   -- 0 apaga el descuento
  lealtad_pct int not null default 10 check (lealtad_pct between 0 and 100),
  abierto boolean not null default true,
  ciudad text not null default 'Apodaca, Nuevo León',  -- se agrega a cada dirección para que Google Maps la ubique
  origen text not null default ''                       -- de dónde sales a repartir (vacío = tu ubicación al abrir la ruta)
);
insert into public.ajustes (id) values (1) on conflict (id) do nothing;

-- ============ Menú, colonias y horarios cerrados ============
create table if not exists public.productos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  descripcion text not null default '',
  precio numeric(8,2) not null check (precio >= 0),
  activo boolean not null default true,
  orden int not null default 0
);

create table if not exists public.colonias (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activa boolean not null default true
);

create table if not exists public.horarios_cerrados (
  fecha date not null,
  hora time not null,
  primary key (fecha, hora)
);

-- ============ Pedidos ============
create table if not exists public.pedidos (
  id uuid primary key default gen_random_uuid(),
  folio bigint generated always as identity,
  creado timestamptz not null default now(),
  fecha date not null,
  hora time not null,
  nombre text not null,
  telefono text not null,
  colonia text not null,
  direccion text not null,
  referencias text not null default '',
  lat double precision,   -- ubicación que el cliente compartió (opcional)
  lng double precision,
  pago text not null check (pago in ('Efectivo', 'Transferencia')),
  paga_con text not null default '',
  items jsonb not null,
  subtotal numeric(10,2) not null,
  envio numeric(8,2) not null,
  descuento_pct int not null default 0,
  descuento_monto numeric(10,2) not null default 0,
  total numeric(10,2) not null,
  estado text not null default 'nuevo'
    check (estado in ('nuevo', 'preparando', 'en_camino', 'entregado', 'cancelado'))
);
create index if not exists pedidos_horario_idx on public.pedidos (fecha, hora);
create index if not exists pedidos_telefono_idx on public.pedidos (telefono);

-- ============ Permisos (RLS) ============
alter table public.ajustes enable row level security;
alter table public.productos enable row level security;
alter table public.colonias enable row level security;
alter table public.horarios_cerrados enable row level security;
alter table public.pedidos enable row level security;

-- Cualquiera puede ver menú, colonias, ajustes y horarios cerrados. Solo tú los cambias.
drop policy if exists "ver ajustes" on public.ajustes;
create policy "ver ajustes" on public.ajustes for select to anon, authenticated using (true);
drop policy if exists "admin ajustes" on public.ajustes;
create policy "admin ajustes" on public.ajustes for all to authenticated
  using (public.soy_admin()) with check (public.soy_admin());

drop policy if exists "ver productos" on public.productos;
create policy "ver productos" on public.productos for select to anon, authenticated using (true);
drop policy if exists "admin productos" on public.productos;
create policy "admin productos" on public.productos for all to authenticated
  using (public.soy_admin()) with check (public.soy_admin());

drop policy if exists "ver colonias" on public.colonias;
create policy "ver colonias" on public.colonias for select to anon, authenticated using (true);
drop policy if exists "admin colonias" on public.colonias;
create policy "admin colonias" on public.colonias for all to authenticated
  using (public.soy_admin()) with check (public.soy_admin());

drop policy if exists "ver cerrados" on public.horarios_cerrados;
create policy "ver cerrados" on public.horarios_cerrados for select to anon, authenticated using (true);
drop policy if exists "admin cerrados" on public.horarios_cerrados;
create policy "admin cerrados" on public.horarios_cerrados for all to authenticated
  using (public.soy_admin()) with check (public.soy_admin());

-- Pedidos: los clientes NO leen ni escriben directo (solo con crear_pedido). Tú los ves y los cambias.
drop policy if exists "admin pedidos" on public.pedidos;
create policy "admin pedidos" on public.pedidos for all to authenticated
  using (public.soy_admin()) with check (public.soy_admin());

-- Avisos en vivo al panel
do $$
begin
  alter publication supabase_realtime add table public.pedidos;
exception when duplicate_object or undefined_object then
  null;
end $$;

-- ============ Funciones para los clientes ============

-- Cuántos pedidos lleva cada horario (sin datos personales)
create or replace function public.cupos_dia(p_fecha date)
returns table (hora time, usados int)
language sql stable security definer set search_path = public as $$
  select p.hora, count(*)::int
  from public.pedidos p
  where p.fecha = p_fecha and p.estado <> 'cancelado'
  group by p.hora;
$$;

-- Progreso de descuento por cliente frecuente, según el teléfono
-- Con lealtad_cada = 3: pedidos 1, 2 y 3 a precio normal, el 4 con descuento, y así en ciclos.
create or replace function public.mi_lealtad(p_tel text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  a public.ajustes;
  tel text;
  k int;
  r int;
begin
  select * into a from public.ajustes where id = 1;
  tel := right(regexp_replace(coalesce(p_tel, ''), '\D', '', 'g'), 10);
  if length(tel) <> 10 or a.lealtad_cada <= 0 or a.lealtad_pct <= 0 then
    return jsonb_build_object('pct', 0, 'faltan', null, 'cada', a.lealtad_cada, 'descuento', a.lealtad_pct);
  end if;
  select count(*) into k from public.pedidos where telefono = tel and estado <> 'cancelado';
  r := k % (a.lealtad_cada + 1);
  if r = a.lealtad_cada then
    return jsonb_build_object('pct', a.lealtad_pct, 'faltan', 0, 'cada', a.lealtad_cada, 'descuento', a.lealtad_pct);
  end if;
  return jsonb_build_object('pct', 0, 'faltan', a.lealtad_cada - r, 'cada', a.lealtad_cada, 'descuento', a.lealtad_pct);
end;
$$;

-- Crea el pedido. Todo se valida aquí: precios, horario, cupo y descuento.
-- Los dos candados evitan que dos clientes se queden con el mismo último lugar
-- o usen el mismo descuento a la vez.
create or replace function public.crear_pedido(
  p_fecha date,
  p_hora time,
  p_nombre text,
  p_telefono text,
  p_colonia text,
  p_direccion text,
  p_referencias text,
  p_pago text,
  p_paga_con text,
  p_items jsonb,
  p_lat double precision default null,
  p_lng double precision default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a public.ajustes;
  tel text;
  ahora timestamp;
  usados int;
  k int;
  pct int := 0;
  sub numeric := 0;
  monto_desc numeric := 0;
  tot numeric;
  it jsonb;
  prod public.productos;
  qty int;
  lineas jsonb := '[]'::jsonb;
  nuevo public.pedidos;
begin
  select * into a from public.ajustes where id = 1;
  if not a.abierto then
    raise exception 'pedidos_cerrados';
  end if;

  p_nombre := btrim(coalesce(p_nombre, ''));
  p_direccion := btrim(coalesce(p_direccion, ''));
  p_referencias := left(btrim(coalesce(p_referencias, '')), 300);
  p_paga_con := left(btrim(coalesce(p_paga_con, '')), 20);
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    p_lat := null;
    p_lng := null;
  end if;
  tel := right(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'), 10);

  if length(p_nombre) < 2 or length(p_nombre) > 80 then raise exception 'datos_invalidos'; end if;
  if length(p_direccion) < 3 or length(p_direccion) > 160 then raise exception 'datos_invalidos'; end if;
  if length(tel) <> 10 then raise exception 'telefono_invalido'; end if;
  if coalesce(p_pago, '') not in ('Efectivo', 'Transferencia') then raise exception 'datos_invalidos'; end if;
  if not exists (select 1 from public.colonias c where c.nombre = p_colonia and c.activa) then
    raise exception 'colonia_invalida';
  end if;

  -- Horario
  if p_fecha is null or p_hora is null then raise exception 'horario_invalido'; end if;
  ahora := now() at time zone 'America/Monterrey';
  if not (extract(dow from p_fecha)::int = any (a.dias)) then raise exception 'horario_invalido'; end if;
  if p_fecha > ahora::date + 28 then raise exception 'horario_invalido'; end if;
  if p_hora < a.inicio or p_hora > a.fin
     or ((extract(epoch from (p_hora - a.inicio)) / 60)::int % a.intervalo_min) <> 0 then
    raise exception 'horario_invalido';
  end if;
  if (p_fecha + p_hora) < ahora + make_interval(mins => a.anticipacion_min) then
    raise exception 'horario_pasado';
  end if;
  if exists (select 1 from public.horarios_cerrados h where h.fecha = p_fecha and h.hora = p_hora) then
    raise exception 'horario_lleno';
  end if;

  -- Productos: el precio sale de la base de datos, nunca del navegador
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 20 then
    raise exception 'pedido_vacio';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    qty := coalesce((it ->> 'cantidad')::int, 0);
    if qty < 1 or qty > 20 then raise exception 'datos_invalidos'; end if;
    select * into prod from public.productos where id = (it ->> 'id')::uuid and activo;
    if not found then raise exception 'producto_invalido'; end if;
    sub := sub + prod.precio * qty;
    lineas := lineas || jsonb_build_object(
      'id', prod.id, 'nombre', prod.nombre, 'precio', prod.precio, 'cantidad', qty);
  end loop;
  if sub < a.minimo then raise exception 'bajo_minimo'; end if;

  -- Candados: un horario y un teléfono a la vez
  perform pg_advisory_xact_lock(hashtext('horario:' || p_fecha::text || p_hora::text));
  perform pg_advisory_xact_lock(hashtext('telefono:' || tel));

  select count(*) into usados
  from public.pedidos where fecha = p_fecha and hora = p_hora and estado <> 'cancelado';
  if usados >= a.cupo_por_horario then raise exception 'horario_lleno'; end if;

  if (select count(*) from public.pedidos
      where telefono = tel and fecha = p_fecha and estado <> 'cancelado') >= 3 then
    raise exception 'demasiados_pedidos';
  end if;

  -- Descuento por cliente frecuente
  select count(*) into k from public.pedidos where telefono = tel and estado <> 'cancelado';
  if a.lealtad_cada > 0 and a.lealtad_pct > 0 and k % (a.lealtad_cada + 1) = a.lealtad_cada then
    pct := a.lealtad_pct;
  end if;
  monto_desc := round(sub * pct / 100.0, 2);
  tot := sub - monto_desc + a.envio;

  insert into public.pedidos (
    fecha, hora, nombre, telefono, colonia, direccion, referencias, lat, lng, pago, paga_con,
    items, subtotal, envio, descuento_pct, descuento_monto, total
  ) values (
    p_fecha, p_hora, p_nombre, tel, p_colonia, p_direccion, p_referencias, p_lat, p_lng, p_pago, p_paga_con,
    lineas, sub, a.envio, pct, monto_desc, tot
  ) returning * into nuevo;

  return jsonb_build_object(
    'folio', nuevo.folio, 'fecha', nuevo.fecha, 'hora', nuevo.hora,
    'subtotal', sub, 'envio', a.envio,
    'descuento_pct', pct, 'descuento_monto', monto_desc, 'total', tot
  );
end;
$$;

grant execute on function
  public.soy_admin(),
  public.cupos_dia(date),
  public.mi_lealtad(text),
  public.crear_pedido(date, time, text, text, text, text, text, text, text, jsonb, double precision, double precision)
to anon, authenticated;

-- ============ Datos de ejemplo (cámbialos desde el panel) ============
insert into public.productos (nombre, descripcion, precio, orden)
select v.nombre, v.descripcion, v.precio, v.orden
from (values
  ('Medio kilo de barbacoa', 'Con salsa roja y verde', 270, 1),
  ('Un kilo de barbacoa', 'Con salsa roja y verde', 520, 2),
  ('Paquete familiar', '1 kg de barbacoa, 1 litro de consomé, medio kilo de tortillas y salsas', 640, 3),
  ('Consomé extra, 1 litro', 'Con garbanzo y arroz', 60, 4),
  ('Tortillas de maíz, medio kilo', 'Calientes, en bolsa térmica', 30, 5)
) as v(nombre, descripcion, precio, orden)
where not exists (select 1 from public.productos);

insert into public.colonias (nombre) values
  ('Colonia ejemplo 1'), ('Colonia ejemplo 2'), ('Colonia ejemplo 3')
on conflict (nombre) do nothing;
