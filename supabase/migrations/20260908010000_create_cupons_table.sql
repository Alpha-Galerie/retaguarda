-- =====================================================================
-- Cupons no banco. Aplicada em 2026-09-08 no projeto wxkwkfkidigeuupaajre.
--
-- Antes: a retaguarda gravava cupons em localStorage (só no navegador do
-- admin) e a loja tinha a própria lista fixa dentro do código-fonte. As
-- duas nunca conversaram — cupom criado na retaguarda dava "inválido ou
-- expirado" no checkout do cliente.
-- =====================================================================

create table if not exists public.cupons (
  id           bigserial primary key,
  codigo       text        not null unique,
  tipo         text        not null default 'pct' check (tipo in ('pct','fixo','frete')),
  valor        numeric     not null default 0,
  descricao    text,
  ativo        boolean     not null default true,
  validade     date,                        -- null = sem prazo
  valor_minimo numeric     not null default 0,
  limite_usos  integer,                     -- null = ilimitado
  usos         integer     not null default 0,
  criado_em    timestamptz not null default now()
);

create index if not exists cupons_codigo_idx on public.cupons (upper(trim(codigo)));

alter table public.cupons enable row level security;

-- Só o admin enxerga e edita a tabela inteira. A loja NÃO pode listar os
-- cupons: se pudesse, qualquer visitante leria todos os códigos (inclusive
-- o VIP20) direto pela chave pública.
drop policy if exists cupons_admin_all on public.cupons;
create policy cupons_admin_all on public.cupons
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.cupons from anon;
revoke all on sequence public.cupons_id_seq from anon;

-- A loja valida um código por vez através desta função, que roda como dona
-- da tabela. Devolve linha só quando o cupom existe, está ativo, dentro da
-- validade e do limite de usos — nunca expõe a lista.
create or replace function public.validar_cupom(p_codigo text, p_subtotal numeric default 0)
returns table (codigo text, tipo text, valor numeric, descricao text)
language sql stable security definer set search_path = public, pg_catalog
as $$
  select c.codigo, c.tipo, c.valor, c.descricao
  from public.cupons c
  where upper(trim(c.codigo)) = upper(trim(p_codigo))
    and c.ativo
    and (c.validade    is null or c.validade >= current_date)
    and (c.limite_usos is null or c.usos < c.limite_usos)
    and coalesce(p_subtotal, 0) >= coalesce(c.valor_minimo, 0)
  limit 1;
$$;

grant execute on function public.validar_cupom(text, numeric) to anon, authenticated, service_role;

-- Semeia com os cupons que a loja já tinha fixos no código, para que nada
-- que hoje funciona deixe de funcionar.
insert into public.cupons (codigo, tipo, valor, descricao) values
  ('ALPHA10',     'pct',  10, '10% de desconto'),
  ('ALPHA15',     'pct',  15, '15% de desconto'),
  ('VIP20',       'pct',  20, '20% de desconto VIP'),
  ('BEMVINDO',    'fixo', 15, 'R$ 15 de desconto'),
  ('FRETEGRATIS', 'frete', 0, 'Frete grátis'),
  ('5OFF',        'pct',   3, '3% de desconto')
on conflict (codigo) do nothing;
