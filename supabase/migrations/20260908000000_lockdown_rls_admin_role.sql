-- =====================================================================
-- Fecha os buracos de segurança abertos para a chave anon (pública).
-- Aplicada em 2026-09-08 no projeto wxkwkfkidigeuupaajre.
--
-- Situação anterior:
--   * produtos e categorias com RLS DESLIGADA -> qualquer um com a chave
--     anon (que está no HTML da loja) podia alterar ou apagar o catálogo;
--   * pedidos/pedido_itens com policies "*_all" USING(true) para o role
--     public -> qualquer um podia LER (nome, telefone, endereço),
--     ALTERAR e APAGAR pedidos;
--   * leads_whatsapp e visitas_site legíveis por anon.
--
-- Essas aberturas existiam porque a retaguarda usava a chave anon (a
-- "senha" era só JavaScript). A retaguarda passa a autenticar de verdade,
-- então o acesso administrativo vai para o role authenticated + claim de
-- admin, e o anon fica só com o que a loja e o PDV precisam:
--   SELECT  em produtos, categorias, variacoes, configuracoes
--   SELECT  em pedidos apenas nas colunas id e status (tela de sucesso)
--   INSERT  em pedidos, pedido_itens, clientes, leads_whatsapp, visitas_site
-- =====================================================================

-- 1. Quem é admin. Baseado em app_metadata, que o próprio usuário não
-- consegue alterar: não basta estar autenticado.
create or replace function public.is_admin()
returns boolean language sql stable as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false)
      or auth.role() = 'service_role';
$$;
grant execute on function public.is_admin() to anon, authenticated, service_role;

update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb) || '{"role":"admin"}'::jsonb
 where email = 'alphagalerie@gmail.com';

-- 2. produtos — catálogo público para leitura, escrita só do admin
alter table public.produtos enable row level security;
drop policy if exists produtos_public_read on public.produtos;
create policy produtos_public_read on public.produtos
  for select to anon, authenticated using (true);
drop policy if exists produtos_admin_write on public.produtos;
create policy produtos_admin_write on public.produtos
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 3. categorias — as policies já existiam, mas a RLS nunca foi ligada
alter table public.categorias enable row level security;
drop policy if exists categorias_auth_write on public.categorias;
drop policy if exists categorias_admin_write on public.categorias;
create policy categorias_admin_write on public.categorias
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 4. variacoes — só tinha leitura pública; a retaguarda não conseguia gravar
drop policy if exists variacoes_admin_write on public.variacoes;
create policy variacoes_admin_write on public.variacoes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 5. pedidos — fim do "qualquer um lê, altera e apaga"
drop policy if exists pedidos_select_all  on public.pedidos;
drop policy if exists pedidos_insert_all  on public.pedidos;
drop policy if exists pedidos_update_all  on public.pedidos;
drop policy if exists pedidos_delete_all  on public.pedidos;
drop policy if exists allow_anon_select_orders on public.pedidos;
drop policy if exists pedidos_admin_all on public.pedidos;
create policy pedidos_admin_all on public.pedidos
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- A loja consulta o status do pedido logo após o checkout. A policy libera
-- a linha, mas o GRANT limita as COLUNAS: nome, telefone, e-mail e endereço
-- deixam de ser legíveis pela chave pública.
drop policy if exists pedidos_anon_status on public.pedidos;
create policy pedidos_anon_status on public.pedidos for select to anon using (true);
revoke select on public.pedidos from anon;
grant select (id, status) on public.pedidos to anon;

-- 6. pedido_itens — anon só insere (checkout)
drop policy if exists pedido_itens_select_all on public.pedido_itens;
drop policy if exists pedido_itens_insert_all on public.pedido_itens;
drop policy if exists pedido_itens_update_all on public.pedido_itens;
drop policy if exists pedido_itens_delete_all on public.pedido_itens;
drop policy if exists allow_anon_select_order_items on public.pedido_itens;
drop policy if exists pedido_itens_admin_all on public.pedido_itens;
create policy pedido_itens_admin_all on public.pedido_itens
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke select, update, delete on public.pedido_itens from anon;

-- 7. clientes — cadastro entra pelo checkout, leitura só do admin
drop policy if exists clientes_admin_leitura on public.clientes;
drop policy if exists clientes_admin_all on public.clientes;
create policy clientes_admin_all on public.clientes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke select, update, delete on public.clientes from anon;

-- 8. leads_whatsapp — anon lia e alterava a base de leads
drop policy if exists allow_select_leads on public.leads_whatsapp;
drop policy if exists allow_update_leads on public.leads_whatsapp;
drop policy if exists leads_admin_all on public.leads_whatsapp;
create policy leads_admin_all on public.leads_whatsapp
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke select, update, delete on public.leads_whatsapp from anon;

-- 9. visitas_site — registro entra por anon, relatório é do admin
drop policy if exists allow_select_visitas on public.visitas_site;
drop policy if exists visitas_admin_all on public.visitas_site;
create policy visitas_admin_all on public.visitas_site
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke select, update, delete on public.visitas_site from anon;
