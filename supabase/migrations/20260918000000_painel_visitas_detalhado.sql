-- =====================================================================
-- Painel de visitas detalhado. Aplicada em 2026-09-18.
--
-- Dois problemas resolvidos aqui:
--
-- 1) O painel buscava as linhas cruas de visitas_site sem ORDER BY e sem
--    paginar. O PostgREST corta em 1000 linhas, então voltavam as 1000 MAIS
--    ANTIGAS: tudo a partir de 15/06/2026 ficava invisível e o painel
--    mostrava "0 hoje / 0 este mês" mesmo com 218 visitas no mês. Agora a
--    agregação é feita no banco e devolve um JSON pequeno.
--
-- 2) Os dados vinham crus demais. Esta função já entrega recorte por dia,
--    dia da semana, hora, região, cidade, dispositivo e origem, com a
--    conversão (visitas -> pedidos) calculada junto.
--
-- Datas e horas são convertidas para America/Sao_Paulo. A coluna `data` era
-- gravada com a data UTC pelo navegador, o que jogava toda visita após as
-- 21h para o dia seguinte; por isso tudo aqui deriva de `ts`.
-- =====================================================================

alter table public.visitas_site add column if not exists dispositivo text;
alter table public.visitas_site add column if not exists origem      text;

create index if not exists visitas_site_ts_idx on public.visitas_site (ts);

-- Tira acento e uniformiza caixa, para "Sao Paulo" e "São Paulo" não
-- aparecerem como duas cidades diferentes.
create or replace function public.normalizar_cidade(p text)
returns text language sql immutable set search_path = public, pg_catalog as $$
  select nullif(initcap(trim(translate(lower(coalesce(p,'')),
    'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'))), '');
$$;

-- Data centers de nuvem = rastreador, não cliente. Aparecem como Ashburn
-- (AWS), Santa Clara (Google), Quincy e Boydton (Azure), etc.
create or replace function public.visita_e_robo(p_cidade text, p_pais text)
returns boolean language sql immutable set search_path = public, pg_catalog as $$
  select public.normalizar_cidade(p_cidade) in
           ('Ashburn','Santa Clara','Quincy','Boydton','Council Bluffs',
            'The Dalles','Boardman','Columbus','Des Moines','Mountain View')
      or (p_pais is not null and p_pais <> 'Brazil');
$$;

create or replace function public.painel_visitas(p_dias integer default 30)
returns jsonb language plpgsql stable set search_path = public, pg_catalog
as $$
declare
  v_ini date := (current_date at time zone 'America/Sao_Paulo')::date - (p_dias - 1);
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  resultado jsonb;
begin
  if not public.is_admin() then
    raise exception 'acesso restrito';
  end if;

  with v as (
    select (ts at time zone 'America/Sao_Paulo')::date            as dia,
           extract(hour from ts at time zone 'America/Sao_Paulo')::int as hora,
           extract(isodow from ts at time zone 'America/Sao_Paulo')::int as dow,
           public.normalizar_cidade(cidade)                        as cidade,
           estado, pais, dispositivo, origem,
           public.visita_e_robo(cidade, pais)                      as robo
    from public.visitas_site
    where (ts at time zone 'America/Sao_Paulo')::date >= v_ini
  ),
  reais as (select * from v where not robo),
  p as (
    select (criado_em at time zone 'America/Sao_Paulo')::date as dia,
           extract(isodow from criado_em at time zone 'America/Sao_Paulo')::int as dow,
           total, status
    from public.pedidos
    where (criado_em at time zone 'America/Sao_Paulo')::date >= v_ini
  ),
  dias as (select generate_series(v_ini, v_hoje, interval '1 day')::date as dia)
  select jsonb_build_object(
    'periodo_dias', p_dias,
    'inicio', v_ini,
    'fim', v_hoje,
    'resumo', (select jsonb_build_object(
        'hoje',        count(*) filter (where dia = v_hoje),
        'ontem',       count(*) filter (where dia = v_hoje - 1),
        'periodo',     count(*),
        'media_dia',   round(count(*)::numeric / greatest(p_dias,1), 1),
        'robos',       (select count(*) from v where robo),
        'total_geral', (select count(*) from public.visitas_site)
      ) from reais),
    'por_dia', (select coalesce(jsonb_agg(x order by x->>'dia'), '[]'::jsonb) from (
        select jsonb_build_object(
          'dia', d.dia,
          'visitas', (select count(*) from reais r where r.dia = d.dia),
          'robos',   (select count(*) from v where v.robo and v.dia = d.dia),
          'pedidos', (select count(*) from p where p.dia = d.dia),
          'receita', (select coalesce(sum(total),0) from p where p.dia = d.dia
                        and p.status in ('pago','enviado','entregue'))
        ) as x from dias d) t),
    'por_dia_semana', (select coalesce(jsonb_agg(x order by (x->>'dow')::int), '[]'::jsonb) from (
        select jsonb_build_object(
          'dow', d,
          'nome', case d when 1 then 'Segunda' when 2 then 'Terça' when 3 then 'Quarta'
                         when 4 then 'Quinta' when 5 then 'Sexta' when 6 then 'Sábado'
                         else 'Domingo' end,
          'visitas', (select count(*) from reais r where r.dow = d),
          'pedidos', (select count(*) from p where p.dow = d),
          'receita', (select coalesce(sum(total),0) from p where p.dow = d
                        and p.status in ('pago','enviado','entregue'))
        ) as x from generate_series(1,7) d) t),
    'por_hora', (select coalesce(jsonb_agg(x order by (x->>'hora')::int), '[]'::jsonb) from (
        select jsonb_build_object('hora', h,
          'visitas', (select count(*) from reais r where r.hora = h)) as x
        from generate_series(0,23) h) t),
    'por_regiao', (select coalesce(jsonb_agg(x order by (x->>'visitas')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('regiao', regiao, 'visitas', count(*)) as x
        from (select case
                when cidade in ('Barueri','Santana De Parnaiba','Osasco','Carapicuiba',
                                'Jandira','Itapevi','Cotia','Pirapora Do Bom Jesus')
                     then 'Alphaville e região'
                when cidade = 'Sao Paulo' then 'Capital (São Paulo)'
                when cidade is null then 'Não identificada'
                when estado in ('Sao Paulo','São Paulo','SP') then 'Interior / outras de SP'
                else 'Outros estados'
              end as regiao
         from reais) z group by regiao) t),
    'por_cidade', (select coalesce(jsonb_agg(x order by (x->>'visitas')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('cidade', cidade, 'uf', max(estado), 'visitas', count(*)) as x
        from reais where cidade is not null group by cidade
        order by count(*) desc limit 12) t),
    'por_dispositivo', (select coalesce(jsonb_agg(x order by (x->>'visitas')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('dispositivo', coalesce(dispositivo,'Ainda não coletado'),
          'visitas', count(*)) as x from reais group by dispositivo) t),
    'por_origem', (select coalesce(jsonb_agg(x order by (x->>'visitas')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('origem', coalesce(origem,'Ainda não coletado'),
          'visitas', count(*)) as x from reais group by origem order by count(*) desc limit 10) t)
  ) into resultado;

  return resultado;
end $$;

revoke all on function public.painel_visitas(integer) from public, anon;
grant execute on function public.painel_visitas(integer) to authenticated, service_role;
