-- painel_interesses descartava todo registro sem cidade: visita_e_robo(NULL, NULL)
-- devolve NULL (NULL IN (...)), e "not NULL" tira a linha do WHERE. Busca de
-- quem bloqueia a geolocalização ou voltou numa aba já aberta sumia do painel.
-- Sem cidade não é sinal de robô: só descarta quando a função diz que é.
do $$
declare v_def text;
begin
  select pg_get_functiondef('public.painel_interesses(integer)'::regprocedure) into v_def;
  v_def := replace(v_def,
    'and not public.visita_e_robo(it.cidade, null)',
    'and not coalesce(public.visita_e_robo(it.cidade, null), false)');
  execute v_def;
end $$;
