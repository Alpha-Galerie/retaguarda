-- =====================================================================
-- O que o cliente procura no site e de onde (bairro/zona) ele acessa.
--
-- Até aqui o site só registrava a visita (visitas_site). O que a pessoa
-- digitava na busca, qual categoria abria e qual produto olhava não ficava
-- em lugar nenhum — então o painel não tinha como responder "estão
-- procurando tabaco ou seda?" para orientar promoção.
--
-- 1) interesses_site: um registro por busca, categoria, subcategoria ou
--    produto aberto. O site grava com a chave anon (só INSERT); leitura é
--    do admin, igual visitas_site.
-- 2) visitas_site.cep: o CEP aproximado que o serviço de geolocalização
--    devolve para o IP. Não é o endereço da pessoa, mas o prefixo basta para
--    separar Zona Sul/Oeste/Leste/Norte/Centro da capital.
-- 3) painel_interesses(p_dias): agrega tudo isso em um JSON para a aba
--    Performance, incluindo os bairros reais tirados dos endereços de
--    entrega dos pedidos (essa é a fonte confiável de bairro).
-- =====================================================================

alter table public.visitas_site add column if not exists cep text;

create table if not exists public.interesses_site (
  id          bigserial primary key,
  ts          timestamptz not null default now(),
  sessao      text,
  tipo        text not null,
  termo       text,
  produto_id  bigint,
  resultados  integer,
  cidade      text,
  estado      text,
  cep         text,
  constraint interesses_tipo_ck check (tipo in ('busca','categoria','subcategoria','produto')),
  constraint interesses_termo_ck check (termo is null or char_length(termo) <= 80),
  constraint interesses_sessao_ck check (sessao is null or char_length(sessao) <= 40),
  constraint interesses_geo_ck check (
    coalesce(char_length(cidade),0) <= 80 and coalesce(char_length(estado),0) <= 80
    and coalesce(char_length(cep),0) <= 12)
);

create index if not exists interesses_site_ts_idx on public.interesses_site (ts);

alter table public.interesses_site enable row level security;

drop policy if exists interesses_anon_insert on public.interesses_site;
create policy interesses_anon_insert on public.interesses_site
  for insert to anon, authenticated with check (true);

drop policy if exists interesses_admin_all on public.interesses_site;
create policy interesses_admin_all on public.interesses_site
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.interesses_site from anon;
grant insert on public.interesses_site to anon, authenticated;
grant usage on sequence public.interesses_site_id_seq to anon, authenticated;

-- Tira acento e caixa para "Sêda", "SEDA" e "seda" contarem juntos.
create or replace function public.normalizar_termo(p text)
returns text language sql immutable set search_path = public, pg_catalog as $$
  select nullif(regexp_replace(trim(translate(lower(coalesce(p,'')),
    'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g'), '');
$$;

-- Agrupa uma busca ou um produto no "tipo de produto" que o dono da loja
-- usa para pensar promoção. A ordem importa: "kit de sedas" é Kit, e
-- marca de seda (Raw, Squadafum, Nowdays) conta como Seda.
create or replace function public.classificar_interesse(p text)
returns text language sql immutable set search_path = public, pg_catalog as $$
  select case
    when t is null                                                        then 'Outros'
    when t ~ '\mkit'                                                      then 'Kits'
    when t ~ '(arguil|narguil|essenc|rosh|carvao|queimador|mangueira|\mvaso|zomo|ziggy|oduman)' then 'Arguile / Essência'
    when t ~ '(charut|cigarrilh)'                                         then 'Charuto'
    when t ~ '(seda|papel|blunt|\mraw\M|squadafum|nowdays|smoking|bem bolado|\mpalha\M)' then 'Seda'
    when t ~ '(tabaco|fumo|palheir|cigarr|blend)'                         then 'Tabaco'
    when t ~ '(piteira|filtro|\mtips?\M)'                                 then 'Piteira / Filtro'
    when t ~ '(tritur|dichav|grinder)'                                    then 'Triturador'
    when t ~ '(bong|pipe|cachimbo|slick|bubbler|\mbowl)'                  then 'Bong / Pipe'
    when t ~ '(isqueir|macarico|clipper|zippo|\mbic\M)'                   then 'Isqueiro'
    when t ~ '(\mcbd|canab|hemp|\moleo)'                                  then 'CBD'
    when t ~ '(bebida|cervej|energet|\magua|red bull|destilad|\mgin\M|vodka|whisk|smirnoff|coca)' then 'Bebidas'
    when t ~ '(bandeja|case|\mbag\M|cinzeiro|bolador|tabaqueira)'         then 'Bandeja / Case / Cinzeiro'
    when t ~ '(incenso|esoter|cristal)'                                   then 'Incenso / Esotérico'
    when t ~ '(larica|doce|chocolate)'                                    then 'Laricas'
    else 'Outros'
  end
  from (select public.normalizar_termo(p) as t) z;
$$;

-- Zona aproximada pelo prefixo do CEP. Capital: 01xxx–05xxx e 08xxx.
create or replace function public.zona_por_cep(p_cep text)
returns text language sql immutable set search_path = public, pg_catalog as $$
  select case
    when d is null or length(d) < 5 then null
    when left(d,2) = '01' then 'SP Capital — Centro'
    when left(d,2) = '02' then 'SP Capital — Zona Norte'
    when left(d,2) = '03' then 'SP Capital — Zona Leste'
    when left(d,2) = '04' then 'SP Capital — Zona Sul'
    when left(d,2) = '05' then 'SP Capital — Zona Oeste'
    when left(d,3) between '080' and '084' then 'SP Capital — Zona Leste (extremo)'
    when left(d,3) in ('064','065') then 'Alphaville / Barueri / Santana de Parnaíba'
    when left(d,2) = '06' then 'Grande SP — Oeste (Osasco, Cotia, Itapevi...)'
    when left(d,2) = '07' then 'Grande SP — Norte (Guarulhos, Caieiras...)'
    when left(d,2) = '09' then 'Grande SP — ABC'
    when left(d,1) = '1' then 'Interior / litoral de SP'
    else 'Outros estados'
  end
  from (select nullif(regexp_replace(coalesce(p_cep,''), '\D', '', 'g'), '') as d) z;
$$;

create or replace function public.painel_interesses(p_dias integer default 30)
returns jsonb language plpgsql stable set search_path = public, pg_catalog
as $$
declare
  v_ini date := (now() at time zone 'America/Sao_Paulo')::date - (p_dias - 1);
  resultado jsonb;
begin
  if not public.is_admin() then
    raise exception 'acesso restrito';
  end if;

  with i as (
    select it.*, public.normalizar_termo(it.termo) as termo_n,
           pr.nome as produto_nome, pr.subcategoria, c.nome as categoria_nome
    from public.interesses_site it
    left join public.produtos pr on pr.id = it.produto_id
    left join public.categorias c on c.id = pr.categoria_id
    where (it.ts at time zone 'America/Sao_Paulo')::date >= v_ini
      and not public.visita_e_robo(it.cidade, null)
  ),
  buscas as (select * from i where tipo = 'busca' and termo_n is not null and length(termo_n) >= 2),
  -- Cada sinal vira um "tipo de produto". Busca pesa igual a abrir produto:
  -- os dois são a pessoa dizendo o que quer.
  sinais as (
    select public.classificar_interesse(termo_n) as grupo, sessao, 'busca' as fonte from buscas
    union all
    select public.classificar_interesse(coalesce(subcategoria,'') || ' ' || coalesce(categoria_nome,'') || ' ' || coalesce(produto_nome,'')),
           sessao, 'produto' from i where tipo = 'produto' and produto_id is not null
    union all
    select public.classificar_interesse(termo_n), sessao, 'categoria' from i
     where tipo in ('categoria','subcategoria') and termo_n is not null
  ),
  vendas as (
    select pi.produto_id, sum(pi.quantidade) as qtd
    from public.pedido_itens pi join public.pedidos p on p.id = pi.pedido_id
    where p.status in ('pago','enviado','entregue')
      and (p.criado_em at time zone 'America/Sao_Paulo')::date >= v_ini
    group by pi.produto_id
  ),
  vis as (
    select public.normalizar_cidade(cidade) as cidade, estado, cep
    from public.visitas_site
    where (ts at time zone 'America/Sao_Paulo')::date >= v_ini
      and not public.visita_e_robo(cidade, pais)
  ),
  -- Endereço de entrega é gravado como "Rua, nº, [compl], Bairro, Cidade, CEP".
  ped as (
    select a, status, total from (
      select string_to_array(cliente_endereco, ', ') as a, status, total
      from public.pedidos
      where cliente_endereco ~ '\d{5}-?\d{3}\s*$'
    ) z where array_length(a,1) >= 4
  )
  select jsonb_build_object(
    'periodo_dias', p_dias,
    'resumo', jsonb_build_object(
      'buscas',         (select count(*) from buscas),
      'sessoes_busca',  (select count(distinct sessao) from buscas),
      'sem_resultado',  (select count(*) from buscas where resultados = 0),
      'produtos_vistos',(select count(*) from i where tipo = 'produto'),
      'desde',          (select min(ts) from public.interesses_site)
    ),
    'por_tipo', (select coalesce(jsonb_agg(x order by (x->>'total')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('grupo', grupo, 'total', count(*),
          'buscas', count(*) filter (where fonte = 'busca'),
          'produtos', count(*) filter (where fonte = 'produto'),
          'categorias', count(*) filter (where fonte = 'categoria'),
          'pessoas', count(distinct sessao)) as x
        from sinais group by grupo) t),
    'buscas_top', (select coalesce(jsonb_agg(x order by (x->>'vezes')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('termo', termo_n, 'vezes', count(*),
          'pessoas', count(distinct sessao),
          'resultados', max(resultados),
          'grupo', public.classificar_interesse(termo_n)) as x
        from buscas group by termo_n order by count(*) desc limit 25) t),
    'buscas_sem_resultado', (select coalesce(jsonb_agg(x order by (x->>'vezes')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('termo', termo_n, 'vezes', count(*)) as x
        from buscas where resultados = 0 group by termo_n order by count(*) desc limit 15) t),
    'produtos_top', (select coalesce(jsonb_agg(x order by (x->>'vistas')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('produto_id', i.produto_id, 'nome', max(i.produto_nome),
          'vistas', count(*), 'pessoas', count(distinct i.sessao),
          'vendidos', coalesce(max(v.qtd), 0),
          'grupo', public.classificar_interesse(coalesce(max(i.subcategoria),'') || ' ' || coalesce(max(i.categoria_nome),'') || ' ' || coalesce(max(i.produto_nome),''))) as x
        from i left join vendas v on v.produto_id = i.produto_id
        where i.tipo = 'produto' and i.produto_id is not null
        group by i.produto_id order by count(*) desc limit 20) t),
    'zonas', (select coalesce(jsonb_agg(x order by (x->>'visitas')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('zona', zona, 'visitas', count(*)) as x
        from (select public.zona_por_cep(cep) as zona from vis) z
        where zona is not null group by zona) t),
    'visitas_com_cep', (select count(*) from vis where cep is not null and cep <> ''),
    'bairros_pedidos', (select coalesce(jsonb_agg(x order by (x->>'pedidos')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('bairro', bairro, 'cidade', cidade, 'zona', max(zona),
          'pedidos', count(*),
          'pagos', count(*) filter (where pago),
          'receita', coalesce(sum(total) filter (where pago), 0)) as x
        from (select initcap(trim(regexp_replace(a[array_length(a,1)-2], '[/.].*$', ''))) as bairro,
                     trim(a[array_length(a,1)-1]) as cidade,
                     public.zona_por_cep(a[array_length(a,1)]) as zona,
                     status in ('pago','enviado','entregue') as pago, total
              from ped) b
        group by bairro, cidade order by count(*) desc limit 20) t)
  ) into resultado;

  return resultado;
end $$;

revoke all on function public.painel_interesses(integer) from public, anon;
grant execute on function public.painel_interesses(integer) to authenticated, service_role;
