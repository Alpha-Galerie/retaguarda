-- =====================================================================
-- Filtro por marca na vitrine. Aplicada em 2026-09-18.
--
-- Dentro de uma subcategoria as marcas ficavam misturadas: em Essências
-- convivem ADALYA (20), ZIGGY (19), NAY (13) e mais quatro marcas, e quem
-- queria uma delas tinha que garimpar 60 produtos.
--
-- As marcas devolvidas são as do recorte que o cliente está vendo — não o
-- catálogo inteiro. No total a loja tem 132 marcas só em Headshop, mas
-- dentro de uma subcategoria o normal são 2 a 8, o que cabe numa fileira
-- de botões como a das subcategorias.
-- =====================================================================

create or replace function public.marcas_da_loja(
  p_categoria_id bigint default null,
  p_subcategoria text default null
)
returns table (marca text, total bigint, com_estoque bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select btrim(p.marca) as marca,
         count(*) as total,
         count(*) filter (where not p.sem_estoque) as com_estoque
    from public.produtos p
   where p.ativo
     and nullif(btrim(p.marca), '') is not null
     and (p_categoria_id is null or p.categoria_id = p_categoria_id)
     and (p_subcategoria is null or p.subcategoria ilike p_subcategoria)
   group by btrim(p.marca)
   -- Mesma regra dos produtos e das subcategorias: primeiro o que dá para
   -- comprar hoje, esgotado por último.
   order by count(*) filter (where not p.sem_estoque) desc,
            count(*) desc,
            btrim(p.marca);
$$;

grant execute on function public.marcas_da_loja(bigint, text) to anon, authenticated;

create index if not exists idx_produtos_marca
  on public.produtos (categoria_id, subcategoria, marca)
  where ativo = true;
