-- =====================================================================
-- Status de pedido editáveis pela retaguarda.
-- Aplicada em 2026-10-06.
--
-- Os status eram seis botões fixos no index.html. A loja precisava de
-- "Aguardando coleta" (pedido pago esperando a coleta da Pex ao meio-dia)
-- e de poder criar, editar e excluir status sem mexer em código.
--
-- Cada status diz como ele CONTA para o resto do sistema (`conta_como`):
-- faturamento, pontos do Alpha Club, cupom devolvido no cancelamento.
-- "Aguardando coleta" conta como pago — gera os pontos e entra no
-- faturamento como qualquer pedido pago. `status_base()` faz essa conta e
-- as funções do banco que olhavam a lista fixa passam a usá-la.
--
-- Status do sistema (os que o site e o Mercado Pago gravam) podem mudar de
-- nome, cor e ordem, mas não podem ser excluídos nem mudar o `conta_como`.
-- Status com pedidos não pode ser excluído: mude os pedidos antes.
-- =====================================================================

create table if not exists public.pedido_status (
  slug text primary key check (slug ~ '^[a-z0-9_]{2,40}$'),
  nome text not null check (length(trim(nome)) between 1 and 40),
  cor text not null default '#c9a961' check (cor ~ '^#[0-9a-fA-F]{6}$'),
  conta_como text not null check (conta_como in ('novo', 'aguardando_pagamento', 'pago', 'enviado', 'entregue', 'cancelado')),
  ordem integer not null default 100,
  sistema boolean not null default false,
  criado_em timestamptz not null default now()
);

insert into public.pedido_status (slug, nome, cor, conta_como, ordem, sistema) values
  ('novo',                 'Novo',              '#60a5fa', 'novo',                 10, true),
  ('pendente',             'Pendente (site)',   '#f59e0b', 'aguardando_pagamento', 15, true),
  ('aguardando_pagamento', 'Aguard. pagamento', '#f59e0b', 'aguardando_pagamento', 20, true),
  ('nao_pago',             'Não pago',          '#ef4444', 'aguardando_pagamento', 25, true),
  ('pago',                 'Pago',              '#fbbf24', 'pago',                 30, true),
  ('aguardando_coleta',    'Aguardando coleta', '#c9a961', 'pago',                 35, false),
  ('enviado',              'Enviado',           '#4ade80', 'enviado',              40, true),
  ('entregue',             'Entregue',          '#888888', 'entregue',             50, true),
  ('cancelado',            'Cancelado',         '#ef4444', 'cancelado',            60, true),
  ('recusado',             'Recusado (cartão)', '#ef4444', 'cancelado',            65, true),
  ('reembolsado',          'Reembolsado',       '#ef4444', 'cancelado',            70, true)
on conflict (slug) do nothing;

-- Proteções que valem mesmo fora da retaguarda.
create or replace function public.pedido_status_protege()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  if tg_op = 'INSERT' then
    new.sistema := false;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.sistema then
      raise exception 'O status "%" é usado pelo site e não pode ser excluído.', old.nome;
    end if;
    if exists (select 1 from pedidos where status = old.slug) then
      raise exception 'Há pedidos com o status "%". Mude esses pedidos de status antes de excluir.', old.nome;
    end if;
    return old;
  end if;

  if new.slug <> old.slug then
    raise exception 'O código do status não muda. Crie um status novo.';
  end if;
  if old.sistema and (new.conta_como <> old.conta_como or not new.sistema) then
    raise exception 'O status "%" é usado pelo site: só o nome, a cor e a ordem podem mudar.', old.nome;
  end if;
  if not old.sistema then
    new.sistema := false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pedido_status_protege on public.pedido_status;
create trigger trg_pedido_status_protege
  before insert or update or delete on public.pedido_status
  for each row execute function public.pedido_status_protege();

alter table public.pedido_status enable row level security;

drop policy if exists pedido_status_ler on public.pedido_status;
create policy pedido_status_ler on public.pedido_status
  for select to anon, authenticated using (true);

drop policy if exists pedido_status_admin on public.pedido_status;
create policy pedido_status_admin on public.pedido_status
  for all to authenticated using (is_admin()) with check (is_admin());

revoke all on public.pedido_status from anon;
grant select on public.pedido_status to anon;
grant select, insert, update, delete on public.pedido_status to authenticated;

-- Como o status conta para o sistema. Status desconhecido conta como ele mesmo.
create or replace function public.status_base(p_status text)
returns text
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select coalesce((select conta_como from pedido_status where slug = p_status), p_status);
$$;

grant execute on function public.status_base(text) to anon, authenticated;

-- As funções que olhavam a lista fixa passam a usar status_base().
-- Troca só os trechos, confere que cada troca aconteceu e é idempotente.
do $$
declare
  v_def text;
  v_novo text;
  v_fn regprocedure;
  v_troca record;
begin
  for v_troca in
    select * from (values
      ('public.clube_ao_mudar_status()', 'coalesce(OLD.status = ANY (c_pagos), false)', 'coalesce(status_base(OLD.status) = ANY (c_pagos), false)', 1),
      ('public.clube_ao_mudar_status()', 'coalesce(NEW.status = ANY (c_pagos), false)', 'coalesce(status_base(NEW.status) = ANY (c_pagos), false)', 1),
      ('public.clube_ao_mudar_status()', 'coalesce(OLD.status = ANY (c_cancelados), false)', 'coalesce(status_base(OLD.status) = ANY (c_cancelados), false)', 1),
      ('public.clube_ao_mudar_status()', 'coalesce(NEW.status = ANY (c_cancelados), false)', 'coalesce(status_base(NEW.status) = ANY (c_cancelados), false)', 1),
      ('public.clube_ao_mudar_status()', 'AND p.status = ANY (c_pagos)', 'AND status_base(p.status) = ANY (c_pagos)', 1),
      ('public.painel_visitas(integer)', 'and p.status in (''pago'',''enviado'',''entregue'')', 'and status_base(p.status) in (''pago'',''enviado'',''entregue'')', 2),
      ('public.clube_admin_painel(integer)', 'AND status NOT IN (''cancelado'', ''recusado'', ''reembolsado'')', 'AND status_base(status) NOT IN (''cancelado'', ''recusado'', ''reembolsado'')', 1)
    ) as t(fn, de, para, vezes)
  loop
    v_fn := v_troca.fn::regprocedure;
    v_def := pg_get_functiondef(v_fn);
    if position(v_troca.para in v_def) > 0 then
      continue; -- já trocado
    end if;
    v_novo := replace(v_def, v_troca.de, v_troca.para);
    if length(v_novo) - length(v_def) <> v_troca.vezes * (length(v_troca.para) - length(v_troca.de)) then
      raise exception 'status_base: trecho não encontrado % vez(es) em %: %', v_troca.vezes, v_troca.fn, v_troca.de;
    end if;
    execute v_novo;
  end loop;
end;
$$;
