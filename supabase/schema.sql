-- CARTOON CC: esquema inicial para Supabase
-- Ejecutar en Supabase SQL Editor después de crear el proyecto.
-- No almacene claves secretas ni códigos de tarjetas en el frontend público.

create extension if not exists pgcrypto;

create type public.app_role as enum ('customer', 'admin');
create type public.order_status as enum ('pending', 'paid', 'fulfilled', 'cancelled', 'refunded');
create type public.gift_card_status as enum ('available', 'reserved', 'sold', 'disabled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  role public.app_role not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null default '',
  face_value numeric(12,2) not null check (face_value > 0),
  price numeric(12,2) not null check (price >= 0),
  currency text not null default 'USD' check (currency in ('USD','DOP')),
  image_url text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  status public.order_status not null default 'pending',
  subtotal numeric(12,2) not null check (subtotal >= 0),
  currency text not null default 'USD' check (currency in ('USD','DOP')),
  payment_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  face_value numeric(12,2) not null check (face_value > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  quantity integer not null check (quantity > 0),
  created_at timestamptz not null default now()
);

-- Los códigos se guardan aquí y nunca se exponen mediante consultas públicas.
-- Entregarlos únicamente desde una función de servidor tras confirmar el pago.
create table public.gift_cards (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete set null,
  order_item_id uuid references public.order_items(id) on delete set null,
  code_secret text not null,
  status public.gift_card_status not null default 'available',
  assigned_to uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  sold_at timestamptz
);

create table public.payment_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  provider text not null,
  provider_reference text unique,
  amount numeric(12,2) not null check (amount >= 0),
  currency text not null default 'USD',
  confirmed_at timestamptz,
  created_at timestamptz not null default now()
);

create index orders_user_id_created_at_idx on public.orders(user_id, created_at desc);
create index order_items_order_id_idx on public.order_items(order_id);
create index gift_cards_assigned_to_idx on public.gift_cards(assigned_to);
create index gift_cards_product_status_idx on public.gift_cards(product_id, status);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_updated_at before update on public.profiles
for each row execute function public.set_updated_at();
create trigger products_updated_at before update on public.products
for each row execute function public.set_updated_at();
create trigger orders_updated_at before update on public.orders
for each row execute function public.set_updated_at();

-- Crear perfil automáticamente al registrarse.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = '' as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'display_name', ''));
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Comprobación de administrador para políticas RLS.
create or replace function public.is_admin()
returns boolean language sql stable security definer
set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin'
  );
$$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.gift_cards enable row level security;
alter table public.payment_events enable row level security;

-- Perfiles: cada cliente ve/edita únicamente datos básicos propios.
create policy "profile_select_own_or_admin" on public.profiles
for select to authenticated
using (id = (select auth.uid()) or public.is_admin());

create policy "profile_update_own_or_admin" on public.profiles
for update to authenticated
using (id = (select auth.uid()) or public.is_admin())
with check ((id = (select auth.uid()) and role = 'customer') or public.is_admin());

-- Productos activos visibles al público; administración exclusiva de admins.
create policy "products_read_active" on public.products
for select to anon, authenticated
using (active = true or public.is_admin());

create policy "products_admin_insert" on public.products
for insert to authenticated with check (public.is_admin());
create policy "products_admin_update" on public.products
for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "products_admin_delete" on public.products
for delete to authenticated using (public.is_admin());

-- Los clientes solo consultan sus propios pedidos. La creación/cambio de estado
-- se debe realizar mediante backend confiable para evitar manipular importes o pagos.
create policy "orders_read_own_or_admin" on public.orders
for select to authenticated
using (user_id = (select auth.uid()) or public.is_admin());

create policy "order_items_read_own_or_admin" on public.order_items
for select to authenticated
using (
  public.is_admin() or exists (
    select 1 from public.orders o
    where o.id = order_items.order_id and o.user_id = (select auth.uid())
  )
);

-- Los códigos y eventos de pago no se consultan directamente desde el navegador.
create policy "gift_cards_admin_only" on public.gift_cards
for all to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy "payment_events_admin_only" on public.payment_events
for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- IMPORTANTE:
-- 1) Después de crear tu cuenta, asigna el primer admin desde SQL Editor:
--    update public.profiles set role = 'admin' where email = 'TU_CORREO';
-- 2) No expongas SUPABASE_SERVICE_ROLE_KEY en GitHub ni en el navegador.
-- 3) Los pedidos, importes, confirmación de pagos y entrega de códigos deben
--    pasar por funciones de servidor con validación y comprobación del proveedor.
