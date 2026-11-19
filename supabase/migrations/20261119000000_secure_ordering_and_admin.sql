-- CARTOON CC: secure browser permissions and atomic order creation.
-- Requires supabase/schema.sql to have been applied first.
-- Keep service_role keys on trusted servers only.

create policy "products_read_active_anon"
on public.products for select to anon
using (active = true);

drop policy if exists "orders_admin_update" on public.orders;
create policy "orders_admin_update"
on public.orders for update to authenticated
using (private.is_admin())
with check (private.is_admin());

revoke all on table public.profiles, public.products, public.orders,
  public.order_items, public.gift_cards, public.payment_events
from public, anon, authenticated;

grant select, update on table public.profiles to authenticated;
grant select on table public.products to anon, authenticated;
grant insert, update, delete on table public.products to authenticated;
grant select on table public.orders, public.order_items to authenticated;
grant update on table public.orders to authenticated;
grant select, insert, update, delete on table public.gift_cards to authenticated;
grant select on table public.payment_events to authenticated;

create or replace function public.create_order(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_item jsonb;
  v_product public.products%rowtype;
  v_product_id uuid;
  v_quantity integer;
  v_currency text := null;
  v_subtotal numeric(12,2) := 0;
  v_order_id uuid;
begin
  if v_user_id is null then
    raise exception 'Debes iniciar sesión para crear un pedido.';
  end if;
  if p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array'
     or pg_catalog.jsonb_array_length(p_items) < 1
     or pg_catalog.jsonb_array_length(p_items) > 25 then
    raise exception 'El carrito no es válido.';
  end if;

  for v_item in select value from pg_catalog.jsonb_array_elements(p_items)
  loop
    if pg_catalog.jsonb_typeof(v_item) <> 'object'
       or coalesce(v_item->>'product_id','') !~* '^[0-9a-f-]{36}$'
       or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]?$' then
      raise exception 'Hay un artículo inválido en el carrito.';
    end if;
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;
    if v_quantity > 10 then
      raise exception 'Máximo 10 unidades por producto.';
    end if;

    select * into v_product
    from public.products
    where id = v_product_id and active = true
    for share;
    if not found then
      raise exception 'Uno de los productos ya no está disponible.';
    end if;

    if v_currency is null then
      v_currency := v_product.currency;
    elsif v_currency <> v_product.currency then
      raise exception 'Separa los productos con monedas diferentes en pedidos distintos.';
    end if;
    v_subtotal := v_subtotal + (v_product.price * v_quantity);
  end loop;

  insert into public.orders(user_id, status, subtotal, currency)
  values(v_user_id, 'pending', v_subtotal, v_currency)
  returning id into v_order_id;

  for v_item in select value from pg_catalog.jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;
    select * into v_product
    from public.products
    where id = v_product_id and active = true;
    insert into public.order_items(order_id, product_id, product_name, face_value, unit_price, quantity)
    values(v_order_id, v_product.id, v_product.name, v_product.face_value, v_product.price, v_quantity);
  end loop;

  return pg_catalog.jsonb_build_object(
    'id', v_order_id,
    'status', 'pending',
    'subtotal', v_subtotal,
    'currency', v_currency
  );
end;
$$;

revoke all on function public.create_order(jsonb) from public, anon, authenticated;
grant execute on function public.create_order(jsonb) to authenticated;
