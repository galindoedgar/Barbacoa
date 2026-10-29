# Barbacoa a domicilio: puesta en línea

Archivos: `index.html` (clientes), `admin.html` (tu panel), `config.js` (tus llaves), `schema.sql` (base de datos).

## 1. Base de datos
1. En Supabase abre **SQL Editor**, pega todo `schema.sql` y presiona **Run**. Se puede correr otra vez sin problema.

## 2. Tu usuario
2. **Authentication > Users > Add user**: tu correo y una contraseña. Marca "Auto Confirm User".
3. **Authentication > Sign In / Providers**: apaga "Allow new users to sign up" para que nadie más pueda crearse cuenta.
4. En **SQL Editor** corre esto con tu correo (esto te da permiso de administrador):
   ```sql
   insert into public.admins (user_id) select id from auth.users where email = 'TU-CORREO';
   ```

## 3. Conectar las páginas
5. **Project Settings > API**: copia la *Project URL* y la llave *anon public* y pégalas en `config.js`.

## 4. Subirlo
6. Sube la carpeta completa como sitio estático (Cloudflare Pages, Netlify o Vercel Pro; sin comando de build, la carpeta raíz es la publicada).
7. Clientes: `tusitio.com`. Tu panel: `tusitio.com/admin.html`.

## 5. Primer uso
8. Entra al panel, pestaña **Ajustes** y llena: WhatsApp, tu domicilio (punto de salida de las rutas), ciudad, productos, colonias, cupo por horario y descuento.
9. Prueba haciendo un pedido tú mismo desde `index.html` y míralo aparecer en el panel.

## Cómo funciona
- El cupo y el descuento los decide la base de datos al guardar el pedido, no el navegador, así dos clientes no se quedan con el mismo último lugar.
- Descuento: con "cada 3 pedidos" y 10%, el cliente paga normal sus pedidos 1, 2 y 3, el 4 lleva 10%, y el ciclo se repite. Se identifica por teléfono. Los pedidos cancelados no cuentan.
- Ruta en Google Maps: cada horario tiene un botón que abre la ruta con todas las paradas pendientes, saliendo de tu domicilio. Las paradas van ordenadas por colonia; si quieres otro orden, lo cambias dentro de Maps. Una ruta admite hasta 10 paradas, si hay más se divide en dos botones.
- La dirección sale del texto que escribe el cliente más la colonia y la ciudad. Si alguna no la ubica Maps, ábrela con "Ver en Maps" para corregirla.
