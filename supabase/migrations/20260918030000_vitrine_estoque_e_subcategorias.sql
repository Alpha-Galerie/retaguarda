-- =====================================================================
-- Vitrine: produto sem estoque vai para o fim, e a barra de
-- subcategorias passa a ser agregada no banco. Aplicada em 2026-09-18.
--
-- Dois problemas que o dono viu na loja:
--
-- 1. Produto zerado aparecia misturado com o que tem em estoque. Como a
--    vitrine é paginada de 24 em 24 no servidor, ordenar no navegador não
--    resolveria: os zerados da página 1 continuariam na página 1.
--
-- 2. Em "Todos", a barra mostrava as 68 subcategorias de todas as
--    categorias ao mesmo tempo. A consulta ainda trazia uma linha por
--    produto para juntar no navegador — hoje são 574 linhas, e o
--    PostgREST corta em 1000, então isso ia quebrar sozinho em silêncio
--    conforme o catálogo crescesse.
-- =====================================================================

-- --------------------------------------------------------------------
-- 1. Marcador de "sem estoque"
--
-- O PostgREST ordena por coluna, não por expressão, então a condição
-- precisa estar materializada.
--
-- É coluna comum com trigger, e não GENERATED, de propósito: o PDV é
-- outra aplicação, fora deste repositório, e se ele mandar esta coluna
-- num insert a versão GENERATED devolveria erro e quebraria a venda. Com
-- trigger, o valor enviado é simplesmente corrigido.
-- --------------------------------------------------------------------
alter table public.produtos
  add column if not exists sem_estoque boolean not null default false;

comment on column public.produtos.sem_estoque is
  'Derivada de estoque pela trigger trg_produtos_sem_estoque. Não escreva nela: o valor é recalculado.';

create or replace function public.produtos_marcar_sem_estoque()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- Mesma regra que a loja usa para mostrar o selo "Esgotado":
  -- estoque nulo significa "não controlo estoque", não "acabou".
  new.sem_estoque := (new.estoque is not null and new.estoque = 0);
  return new;
end;
$$;

drop trigger if exists trg_produtos_sem_estoque on public.produtos;
-- Sem "of estoque": assim a trigger também corrige um update que mexa só
-- em sem_estoque, em vez de deixar o valor errado gravado.
create trigger trg_produtos_sem_estoque
  before insert or update on public.produtos
  for each row execute function public.produtos_marcar_sem_estoque();

update public.produtos
   set sem_estoque = (estoque is not null and estoque = 0)
 where sem_estoque is distinct from (estoque is not null and estoque = 0);

-- Índices na ordem exata em que a vitrine consulta.
create index if not exists idx_produtos_vitrine
  on public.produtos (sem_estoque, destaque desc, id)
  where ativo = true;

create index if not exists idx_produtos_vitrine_cat
  on public.produtos (categoria_id, sem_estoque, destaque desc, id)
  where ativo = true;

-- --------------------------------------------------------------------
-- 2. Subcategorias agregadas no banco
--
-- Devolve já ordenado pelo que interessa a quem está comprando: primeiro
-- as subcategorias com mais coisa disponível, e as que estão inteiramente
-- esgotadas no fim — a mesma regra dos produtos.
-- --------------------------------------------------------------------
create or replace function public.subcategorias_da_loja(p_categoria_id bigint default null)
returns table (subcategoria text, total bigint, com_estoque bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select p.subcategoria,
         count(*) as total,
         count(*) filter (where not p.sem_estoque) as com_estoque
    from public.produtos p
   where p.ativo
     and p.subcategoria is not null
     and btrim(p.subcategoria) <> ''
     and (p_categoria_id is null or p.categoria_id = p_categoria_id)
   group by p.subcategoria
   order by count(*) filter (where not p.sem_estoque) desc,
            count(*) desc,
            p.subcategoria;
$$;

grant execute on function public.subcategorias_da_loja(bigint) to anon, authenticated;
