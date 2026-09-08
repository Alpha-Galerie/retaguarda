-- Fixa o search_path das funções SECURITY DEFINER / usadas em policies.
-- Sem isso, quem controla o search_path da sessão pode fazer a função
-- resolver um objeto diferente do esperado.
alter function public.is_admin() set search_path = public, pg_catalog;
alter function public.create_order_with_items(text, text, text, text, text, text, text, text, numeric, numeric, jsonb)
  set search_path = public, pg_catalog;
alter function public.atualizar_timestamp()          set search_path = public, pg_catalog;
alter function public.generate_produtos_search_doc() set search_path = public, pg_catalog;
alter function public.update_produtos_search_doc()   set search_path = public, pg_catalog;

-- produtos_new: tabela vazia, sem nenhuma referência na loja, no PDV nem na
-- retaguarda. Era resto de uma migração antiga.
drop table if exists public.produtos_new;
