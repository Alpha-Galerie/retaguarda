-- =====================================================================
-- PDV integrado ao estoque da retaguarda
--
-- Situação anterior:
--   * O PDV gravava as vendas com a chave pública, direto como "pago" e
--     sem produto_id. Desde o fechamento das permissões (2026-09-08) a
--     gravação falhava; antes disso, nenhuma venda do PDV baixava estoque
--     (a baixa só roda em UPDATE de status e precisa do produto_id).
--   * A baixa automática "travava" em zero: vender 3 com estoque 2 deixava
--     0, e um cancelamento depois devolvia 3 — o estoque ficava 1 a mais
--     do que o real, sem ninguém perceber.
--   * Produto com variações (sabores) tem estoque próprio que deveria ser a
--     soma das variações, mas a venda só baixava a variação: o total do
--     produto ia descolando a cada venda.
--   * Nenhuma movimentação ficava registrada: não havia como explicar por
--     que o estoque é o que é.
--
-- Esta migration:
--   1. is_pdv(): quem pode operar o PDV (admin, ou usuário com
--      app_metadata.role = 'pdv' / 'vendedor' / 'gerente');
--   2. estoque_movimentos: histórico de TODA mudança de estoque (venda,
--      estorno, entrada, contagem, ajuste manual), gravado por trigger —
--      não depende de quem mudou lembrar de registrar;
--   3. estoque do produto com variações = soma das variações ativas;
--   4. baixa sem travar em zero (estoque negativo = sinal de contagem
--      errada, aparece em vermelho na retaguarda);
--   5. pdv_comandas: comandas abertas no servidor, não só no navegador;
--   6. pdv_finalizar_venda(): grava venda + itens e marca como paga numa
--      transação só, passando pela mesma baixa de estoque do site;
--   7. estoque_lancar() e estoque_relatorio() para a aba Estoque.
-- =====================================================================

-- 1. Quem opera o PDV ------------------------------------------------------
create or replace function public.is_pdv()
returns boolean language sql stable
set search_path = public
as $$
  select public.is_admin()
      or coalesce((auth.jwt() -> 'app_metadata' ->> 'role') in ('pdv', 'vendedor', 'gerente'), false);
$$;
grant execute on function public.is_pdv() to anon, authenticated, service_role;

-- 2. Histórico de movimentação ---------------------------------------------
create table if not exists public.estoque_movimentos (
  id             bigint generated always as identity primary key,
  criado_em      timestamptz not null default now(),
  produto_id     bigint not null references public.produtos(id) on delete cascade,
  variacao_id    bigint references public.variacoes(id) on delete set null,
  quantidade     integer not null,          -- variação: negativo saiu, positivo entrou
  saldo_anterior integer,
  saldo          integer,
  motivo         text not null,             -- venda | estorno | entrada | contagem | ajuste | cadastro
  origem         text,                      -- site | pdv | retaguarda
  pedido_id      bigint references public.pedidos(id) on delete set null,
  usuario        text,
  observacao     text
);
create index if not exists idx_estoque_mov_produto on public.estoque_movimentos (produto_id, criado_em desc);
create index if not exists idx_estoque_mov_data    on public.estoque_movimentos (criado_em desc);
create index if not exists idx_estoque_mov_pedido  on public.estoque_movimentos (pedido_id);

alter table public.estoque_movimentos enable row level security;
drop policy if exists estoque_mov_admin_read on public.estoque_movimentos;
create policy estoque_mov_admin_read on public.estoque_movimentos
  for select to authenticated using (public.is_admin());
revoke all on public.estoque_movimentos from anon;
revoke insert, update, delete, truncate on public.estoque_movimentos from authenticated;
grant select on public.estoque_movimentos to authenticated;

-- Quem mudou o estoque informa o motivo em variáveis da transação
-- (app.estoque_*). Sem elas, a mudança conta como ajuste manual.
create or replace function public.estoque_registrar_movimento()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_old  integer;
  v_new  integer := NEW.estoque;
  v_prod bigint;
  v_var  bigint;
begin
  if TG_TABLE_NAME = 'variacoes' then
    v_prod := NEW.produto_id;
    v_var  := NEW.id;
  else
    v_prod := NEW.id;
    v_var  := null;
    -- Produto com variações: o estoque dele é a soma, derivada. O que
    -- conta (e fica no histórico) é o movimento de cada variação.
    if exists (select 1 from variacoes v where v.produto_id = NEW.id and v.ativo) then
      return NEW;
    end if;
  end if;

  if TG_OP = 'UPDATE' then
    v_old := OLD.estoque;
    if v_old is not distinct from v_new then
      return NEW;
    end if;
  elsif coalesce(v_new, 0) = 0 then
    return NEW;
  end if;

  begin
    insert into estoque_movimentos
      (produto_id, variacao_id, quantidade, saldo_anterior, saldo,
       motivo, origem, pedido_id, usuario, observacao)
    values
      (v_prod, v_var, coalesce(v_new, 0) - coalesce(v_old, 0), v_old, v_new,
       coalesce(nullif(current_setting('app.estoque_motivo', true), ''),
                case when TG_OP = 'INSERT' then 'cadastro' else 'ajuste' end),
       coalesce(nullif(current_setting('app.estoque_origem', true), ''), 'retaguarda'),
       nullif(current_setting('app.estoque_pedido', true), '')::bigint,
       coalesce(auth.jwt() ->> 'email', nullif(current_setting('app.estoque_usuario', true), '')),
       nullif(current_setting('app.estoque_obs', true), ''));
  exception when others then
    -- O histórico nunca pode travar uma venda ou um ajuste.
    raise warning 'estoque_movimentos: % [%]', sqlerrm, sqlstate;
  end;
  return NEW;
end;
$fn$;

drop trigger if exists trg_produtos_mov_estoque on public.produtos;
create trigger trg_produtos_mov_estoque
  after insert or update of estoque on public.produtos
  for each row execute function public.estoque_registrar_movimento();

drop trigger if exists trg_variacoes_mov_estoque on public.variacoes;
create trigger trg_variacoes_mov_estoque
  after insert or update of estoque on public.variacoes
  for each row execute function public.estoque_registrar_movimento();

-- 3. Produto com variações = soma das variações ativas ---------------------
create or replace function public.variacoes_sincronizar_estoque_produto()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_prod bigint := coalesce(NEW.produto_id, OLD.produto_id);
  v_soma integer;
begin
  select sum(estoque)::integer into v_soma
    from variacoes where produto_id = v_prod and ativo;
  if v_soma is not null then
    update produtos set estoque = v_soma
     where id = v_prod and estoque is distinct from v_soma;
  end if;
  if TG_OP = 'UPDATE' and OLD.produto_id is distinct from NEW.produto_id then
    select sum(estoque)::integer into v_soma
      from variacoes where produto_id = OLD.produto_id and ativo;
    if v_soma is not null then
      update produtos set estoque = v_soma
       where id = OLD.produto_id and estoque is distinct from v_soma;
    end if;
  end if;
  return null;
end;
$fn$;

drop trigger if exists trg_variacoes_sync_produto on public.variacoes;
create trigger trg_variacoes_sync_produto
  after insert or update of estoque, ativo, produto_id or delete on public.variacoes
  for each row execute function public.variacoes_sincronizar_estoque_produto();

-- Acerta quem já estiver descolado.
update produtos p
   set estoque = s.soma
  from (select produto_id, sum(estoque)::integer soma
          from variacoes where ativo group by produto_id) s
 where p.id = s.produto_id and p.estoque is distinct from s.soma;

-- 4. "Sem estoque" também para negativo -------------------------------------
create or replace function public.produtos_marcar_sem_estoque()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  new.sem_estoque := (new.estoque is not null and new.estoque <= 0);
  return new;
end;
$fn$;

-- Baixa/estorno sem travar em zero, informando o histórico.
create or replace function public.pedidos_movimentar_estoque()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  c_pagos      constant text[] := array['pago', 'enviado', 'entregue'];
  c_cancelados constant text[] := array['cancelado', 'recusado', 'reembolsado'];
  v_e_pago      boolean := coalesce(status_base(NEW.status) = any (c_pagos), false);
  v_e_cancelado boolean := coalesce(status_base(NEW.status) = any (c_cancelados), false);
  v_sinal integer;
begin
  if NEW.status is not distinct from OLD.status then
    return NEW;
  end if;
  if v_e_pago and not NEW.estoque_baixado then
    v_sinal := -1;
  elsif v_e_cancelado and NEW.estoque_baixado then
    v_sinal := 1;
  else
    return NEW;
  end if;

  begin
    perform set_config('app.estoque_motivo', case when v_sinal = -1 then 'venda' else 'estorno' end, true);
    perform set_config('app.estoque_origem', coalesce(NEW.origem, 'site'), true);
    perform set_config('app.estoque_pedido', NEW.id::text, true);
    perform set_config('app.estoque_obs', NEW.numero, true);

    update variacoes v
       set estoque = v.estoque + v_sinal * i.qtd
      from (select variacao_id, sum(quantidade)::integer as qtd from pedido_itens
             where pedido_id = NEW.id and variacao_id is not null group by variacao_id) i
     where v.id = i.variacao_id;

    update produtos p
       set estoque = p.estoque + v_sinal * i.qtd
      from (select produto_id, sum(quantidade)::integer as qtd from pedido_itens
             where pedido_id = NEW.id and variacao_id is null and produto_id is not null group by produto_id) i
     where p.id = i.produto_id and p.estoque is not null;

    NEW.estoque_baixado := (v_sinal = -1);
  exception when others then
    raise warning 'estoque: pedido % (% para %) nao movimentado: % [%]',
      NEW.id, OLD.status, NEW.status, sqlerrm, sqlstate;
  end;

  perform set_config('app.estoque_motivo', '', true);
  perform set_config('app.estoque_origem', '', true);
  perform set_config('app.estoque_pedido', '', true);
  perform set_config('app.estoque_obs', '', true);
  return NEW;
end;
$fn$;

-- 5. Comandas abertas no servidor ------------------------------------------
create table if not exists public.pdv_comandas (
  id             uuid primary key default gen_random_uuid(),
  nome           text not null,
  itens          jsonb not null default '[]'::jsonb,
  pagamentos     jsonb not null default '[]'::jsonb,
  desconto_tipo  text not null default 'valor',
  desconto_valor numeric not null default 0,
  taxa_percent   numeric not null default 0,
  tabela         text not null default 'vista',
  cliente_whatsapp text,
  status         text not null default 'aberta',   -- aberta | fechada | cancelada
  aberta_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  aberta_por     text,
  fechada_em     timestamptz,
  pedido_id      bigint references public.pedidos(id) on delete set null
);
create index if not exists idx_pdv_comandas_abertas on public.pdv_comandas (status, aberta_em);

alter table public.pdv_comandas enable row level security;
drop policy if exists pdv_comandas_operador on public.pdv_comandas;
create policy pdv_comandas_operador on public.pdv_comandas
  for all to authenticated using (public.is_pdv()) with check (public.is_pdv());
revoke all on public.pdv_comandas from anon;
grant select, insert, update, delete on public.pdv_comandas to authenticated;

-- O PDV precisa ler o catálogo (já é público) — nada a mudar.

-- 6. Finalizar venda do PDV ------------------------------------------------
-- p = { numero, comanda_id?, cliente_nome, cliente_whatsapp?, forma_pagamento,
--       subtotal, total, observacoes,
--       itens: [{ produto_id?, variacao_id?, nome, codigo?, qtd, preco }] }
-- `numero` é gerado pelo PDV uma vez por venda: se a internet cair depois de
-- gravar e o operador tentar de novo, a venda não duplica nem baixa 2 vezes.
create or replace function public.pdv_finalizar_venda(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_numero text  := nullif(trim(p ->> 'numero'), '');
  v_itens  jsonb := coalesce(p -> 'itens', '[]'::jsonb);
  v_id     bigint;
  v_baixou boolean;
  v_neg    jsonb;
  v_whats  text := regexp_replace(coalesce(p ->> 'cliente_whatsapp', ''), '\D', '', 'g');
begin
  if not is_pdv() then
    raise exception 'Sem permissão para registrar vendas no PDV' using errcode = '42501';
  end if;
  if v_numero is null then
    raise exception 'Número da venda obrigatório';
  end if;
  if jsonb_typeof(v_itens) <> 'array' or jsonb_array_length(v_itens) = 0 then
    raise exception 'Venda sem itens';
  end if;

  select id into v_id from pedidos where numero = v_numero;
  if found then
    return jsonb_build_object('id', v_id, 'numero', v_numero, 'duplicado', true, 'negativos', '[]'::jsonb);
  end if;

  insert into pedidos (numero, cliente_nome, cliente_whatsapp, subtotal, frete, total,
                       forma_pagamento, tipo_entrega, observacoes, status, origem)
  values (v_numero,
          coalesce(nullif(trim(p ->> 'cliente_nome'), ''), 'Balcão'),
          v_whats,
          round(coalesce((p ->> 'subtotal')::numeric, 0), 2),
          0,
          round(coalesce((p ->> 'total')::numeric, 0), 2),
          nullif(p ->> 'forma_pagamento', ''),
          'retirada',
          nullif(p ->> 'observacoes', ''),
          'novo',
          'pdv')
  returning id into v_id;

  insert into pedido_itens (pedido_id, produto_id, variacao_id, produto_nome, produto_codigo,
                            quantidade, preco_unitario, subtotal)
  select v_id,
         nullif(i ->> 'produto_id', '')::bigint,
         nullif(i ->> 'variacao_id', '')::bigint,
         coalesce(nullif(i ->> 'nome', ''), 'Item'),
         nullif(i ->> 'codigo', ''),
         (i ->> 'qtd')::integer,
         round((i ->> 'preco')::numeric, 2),
         round((i ->> 'qtd')::integer * (i ->> 'preco')::numeric, 2)
    from jsonb_array_elements(v_itens) i
   where coalesce((i ->> 'qtd')::integer, 0) > 0;

  -- Mesmo caminho do site: a troca para "pago" baixa o estoque e credita
  -- os pontos do Alpha Club (se informou WhatsApp).
  update pedidos set status = 'pago' where id = v_id
  returning estoque_baixado into v_baixou;

  if not coalesce(v_baixou, false) then
    -- A baixa falhou por algum motivo: desfaz tudo para não ficar venda
    -- registrada com estoque errado.
    raise exception 'Não foi possível baixar o estoque desta venda. Nada foi gravado — tente novamente.';
  end if;

  if nullif(p ->> 'comanda_id', '') is not null then
    update pdv_comandas
       set status = 'fechada', fechada_em = now(), atualizado_em = now(), pedido_id = v_id
     where id = (p ->> 'comanda_id')::uuid;
  end if;

  -- Avisa o operador do que ficou negativo (contagem errada na prateleira).
  select jsonb_agg(jsonb_build_object('nome', x.nome, 'estoque', x.estoque)) into v_neg
    from (
      select distinct pr.nome || coalesce(' · ' || va.nome, '') as nome,
             coalesce(va.estoque, pr.estoque) as estoque
        from pedido_itens it
        join produtos pr on pr.id = it.produto_id
        left join variacoes va on va.id = it.variacao_id
       where it.pedido_id = v_id
         and coalesce(va.estoque, pr.estoque) < 0
    ) x;

  return jsonb_build_object('id', v_id, 'numero', v_numero, 'duplicado', false,
                            'negativos', coalesce(v_neg, '[]'::jsonb));
end;
$fn$;
revoke all on function public.pdv_finalizar_venda(jsonb) from public, anon;
grant execute on function public.pdv_finalizar_venda(jsonb) to authenticated;

-- 7a. Entrada de mercadoria / contagem (aba Estoque da retaguarda) ----------
-- p = { motivo: 'entrada' | 'contagem' | 'ajuste', observacao?,
--       itens: [{ produto_id, variacao_id?, quantidade }] }
--   entrada  → soma a quantidade ao estoque atual
--   contagem → o estoque passa a ser exatamente a quantidade contada
create or replace function public.estoque_lancar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_motivo text := coalesce(nullif(p ->> 'motivo', ''), 'ajuste');
  v_item   jsonb;
  v_prod   bigint;
  v_var    bigint;
  v_qtd    integer;
  v_n      integer := 0;
begin
  if not is_admin() then
    raise exception 'Só a administração lança estoque' using errcode = '42501';
  end if;
  if v_motivo not in ('entrada', 'contagem', 'ajuste') then
    raise exception 'Motivo inválido: %', v_motivo;
  end if;

  perform set_config('app.estoque_motivo', v_motivo, true);
  perform set_config('app.estoque_origem', 'retaguarda', true);
  perform set_config('app.estoque_obs', coalesce(p ->> 'observacao', ''), true);

  for v_item in select * from jsonb_array_elements(coalesce(p -> 'itens', '[]'::jsonb)) loop
    v_prod := nullif(v_item ->> 'produto_id', '')::bigint;
    v_var  := nullif(v_item ->> 'variacao_id', '')::bigint;
    v_qtd  := (v_item ->> 'quantidade')::integer;
    continue when v_qtd is null or (v_prod is null and v_var is null);

    if v_var is not null then
      if v_motivo = 'contagem' then
        update variacoes set estoque = v_qtd where id = v_var;
      else
        update variacoes set estoque = estoque + v_qtd where id = v_var;
      end if;
    else
      if v_motivo = 'contagem' then
        update produtos set estoque = v_qtd where id = v_prod;
      else
        update produtos set estoque = coalesce(estoque, 0) + v_qtd where id = v_prod;
      end if;
    end if;
    v_n := v_n + 1;
  end loop;

  perform set_config('app.estoque_motivo', '', true);
  perform set_config('app.estoque_origem', '', true);
  perform set_config('app.estoque_obs', '', true);
  return jsonb_build_object('itens', v_n);
end;
$fn$;
revoke all on function public.estoque_lancar(jsonb) from public, anon;
grant execute on function public.estoque_lancar(jsonb) to authenticated;

-- 7b. Relatório de giro: estoque atual × vendas do período (site + PDV) -----
create or replace function public.estoque_relatorio(p_dias integer default 30)
returns table (
  produto_id     bigint,
  variacao_id    bigint,
  codigo         text,
  nome           text,
  variacao       text,
  categoria      text,
  subcategoria   text,
  ativo          boolean,
  preco          numeric,
  estoque        integer,
  vendidos_site  integer,
  vendidos_pdv   integer,
  ultima_venda   timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not is_admin() then
    raise exception 'Sem permissão' using errcode = '42501';
  end if;
  return query
  with vendas as (
    select it.produto_id, it.variacao_id,
           sum(case when pe.origem = 'pdv' or pe.numero like 'PDV%' then 0 else it.quantidade end)::integer as site,
           sum(case when pe.origem = 'pdv' or pe.numero like 'PDV%' then it.quantidade else 0 end)::integer as pdv,
           max(pe.criado_em) as ultima
      from pedido_itens it
      join pedidos pe on pe.id = it.pedido_id
     where it.produto_id is not null
       and pe.criado_em >= now() - make_interval(days => greatest(p_dias, 1))
       and status_base(pe.status) in ('pago', 'enviado', 'entregue')
     group by it.produto_id, it.variacao_id
  ),
  linhas as (
    -- produtos sem variação
    select pr.id as produto_id, null::bigint as variacao_id, pr.codigo, pr.nome,
           null::text as variacao, c.nome as categoria, pr.subcategoria, pr.ativo,
           coalesce(nullif(pr.preco_pix, 0), pr.preco) as preco, pr.estoque
      from produtos pr
      left join categorias c on c.id = pr.categoria_id
     where not exists (select 1 from variacoes v where v.produto_id = pr.id and v.ativo)
    union all
    -- cada variação ativa vira uma linha
    select pr.id, va.id, pr.codigo, pr.nome, va.nome, c.nome, pr.subcategoria, pr.ativo and va.ativo,
           coalesce(nullif(va.preco, 0), nullif(pr.preco_pix, 0), pr.preco), va.estoque
      from variacoes va
      join produtos pr on pr.id = va.produto_id
      left join categorias c on c.id = pr.categoria_id
     where va.ativo
  )
  select l.produto_id, l.variacao_id, l.codigo, l.nome, l.variacao, l.categoria, l.subcategoria,
         l.ativo, l.preco, l.estoque,
         coalesce(v.site, 0), coalesce(v.pdv, 0), v.ultima
    from linhas l
    left join vendas v
      on v.produto_id = l.produto_id
     and v.variacao_id is not distinct from l.variacao_id;
end;
$fn$;
revoke all on function public.estoque_relatorio(integer) from public, anon;
grant execute on function public.estoque_relatorio(integer) to authenticated;
