-- Segunda camada: além das policies, tirar do role anon os privilégios de
-- escrita que ele não usa. Se um dia alguém criar uma policy permissiva por
-- engano, o GRANT ainda barra.

revoke insert, update, delete, truncate, references on public.produtos      from anon;
grant  select on public.produtos to anon;
revoke insert, update, delete, truncate, references on public.categorias    from anon;
grant  select on public.categorias to anon;
revoke insert, update, delete, truncate, references on public.variacoes     from anon;
grant  select on public.variacoes to anon;
revoke insert, update, delete, truncate, references on public.configuracoes from anon;
grant  select on public.configuracoes to anon;

revoke all on public.admin_config from anon;
revoke update, delete, truncate on public.pedidos from anon;

-- alphamode_leads: a checagem de duplicidade precisa só do whatsapp.
-- Antes, a chave pública lia nome, instagram e todas as respostas do lead.
revoke select, update, delete, truncate on public.alphamode_leads from anon;
grant  select (id, whatsapp) on public.alphamode_leads to anon;
