# CARTOON CC

Tienda de tarjetas de regalo con frontend estático y Supabase Auth/Postgres.

## Archivos principales

- `index.html`: catálogo público, filtro y carrito.
- `cuenta.html`: registro, inicio de sesión, perfil e historial.
- `admin-demo.html`: panel privado para productos, pedidos e inventario.
- `supabase/schema.sql`: esquema inicial.
- `supabase/migrations/20261119000000_secure_ordering_and_admin.sql`: permisos mínimos y creación atómica de pedidos.

## Puesta en marcha

1. Aplica `supabase/schema.sql` si todavía no existe el esquema.
2. Aplica la migración de `supabase/migrations` en el proyecto conectado.
3. En Supabase Auth, configura las URL de redirección de tu dominio GitHub Pages y el correo de confirmación.
4. Crea una cuenta desde `cuenta.html`.
5. Asigna el rol de administrador solo al correo del propietario desde SQL Editor:

```sql
update public.profiles
set role = 'admin'
where lower(email) = lower('TU_CORREO_DE_PROPIETARIO');
```

6. Entra a `admin-demo.html`, crea los productos con sus precios definitivos y carga códigos de inventario legítimos que tengas autorización para distribuir.

## Seguridad y estado actual

- La clave publishable del navegador no es secreta; RLS limita el acceso.
- Nunca agregues una service-role key al frontend o al repositorio.
- Los pedidos se crean como `pending`; el servidor calcula precios usando productos activos.
- El panel permite marcar un pedido pagado solo después de verificar manualmente el pago externo.
- No hay pasarela de pago conectada ni entrega automática de códigos todavía.
- No se han inventado precios ni productos reales: el catálogo permanece vacío hasta que el administrador los cree.
