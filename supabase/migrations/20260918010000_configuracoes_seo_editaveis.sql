-- =====================================================================
-- Textos de SEO editáveis pela retaguarda. Aplicada em 2026-09-18.
--
-- A tabela `configuracoes` já existia com leitura pública (a loja precisa
-- ler), mas a única policy de escrita era para service_role — ou seja, nem
-- o admin autenticado conseguia gravar. Sem isso, um painel de edição na
-- retaguarda não teria como salvar.
-- =====================================================================

drop policy if exists configuracoes_admin_escrita on public.configuracoes;
create policy configuracoes_admin_escrita on public.configuracoes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.configuracoes (chave, valor, descricao) values
  ('seo_titulo',
   'Alpha Galerie — Seda, Piteira, Tabaco e Narguilé em Alphaville/Barueri',
   'Título que aparece na aba do navegador e como link azul no Google (ideal até 60 caracteres).'),
  ('seo_descricao',
   'Tabacaria e headshop em Alphaville: seda, tabaco, piteira, narguilé, carvão, charutaria, acessórios e pet shop. Peça pelo site e receba em casa, ou retire na loja no Centro Comercial Alphaville.',
   'Texto que aparece embaixo do link no Google (ideal até 160 caracteres).'),
  ('seo_palavras',
   'seda, tabaco, piteira, narguilé, arguile, carvão, tabacaria, headshop, charutaria, acessórios, pet shop, peça no site, recebe em casa, Alphaville, Barueri, Santana de Parnaíba',
   'Termos pelos quais você quer ser encontrado. Separe por vírgula.'),
  ('seo_frase_loja',
   'Peça digital, receba em casa. Retirada na loja em Alphaville.',
   'Frase curta de destaque usada nos compartilhamentos e no cartão do site.')
on conflict (chave) do nothing;
