-- =====================================================================
-- Endereço, contato e horário da loja editáveis pela retaguarda.
-- Aplicada em 2026-09-18.
--
-- Antes, esses dados estavam escritos à mão em dois lugares do site
-- (o rodapé em React e o schema JSON-LD do index.html). Trocar o endereço
-- exigia mexer em código. Agora vivem aqui, e tanto o rodapé quanto o
-- schema que o Google lê saem daqui.
--
-- Os horários ficam em campos separados de abre/fecha em vez de texto
-- livre porque o JSON-LD precisa de "11:00"/"21:00" exatos. Texto livre
-- não teria como virar schema válido de forma confiável.
-- =====================================================================

-- --------------------------------------------------------------------
-- Limpeza de segurança: a tabela `configuracoes` tem leitura liberada
-- para o papel anônimo (a loja precisa ler as chaves de SEO e as
-- subcategorias ocultas com a chave pública). A linha `senha_admin`
-- guardava uma senha em texto puro nessa mesma tabela — qualquer pessoa
-- com a chave pública, que está embutida no JavaScript da loja, conseguia
-- lê-la. A autenticação passou para o Supabase Auth e nada mais lê essa
-- chave, então ela é só exposição sem uso.
-- --------------------------------------------------------------------
delete from public.configuracoes where chave = 'senha_admin';

insert into public.configuracoes (chave, valor, descricao) values
  ('loja_endereco', 'Calçada Flôr de Lótus, 15',
   'Rua e número, como está no perfil do Google.'),
  ('loja_complemento', 'Centro Comercial Alphaville',
   'Complemento, galeria ou ponto de referência.'),
  ('loja_bairro', 'Alphaville',
   'Bairro.'),
  ('loja_cidade', 'Barueri',
   'Cidade.'),
  ('loja_uf', 'SP',
   'Estado, com duas letras.'),
  ('loja_cep', '06453-000',
   'CEP.'),
  ('loja_telefone', '(11) 94292-0076',
   'Telefone como aparece na tela. O link de ligação é montado a partir dele.'),
  ('loja_email', 'contato@alphagalerie.com.br',
   'E-mail de contato mostrado no rodapé.'),
  ('loja_instagram', 'alpha.galerie',
   'Arroba do Instagram, sem o @. O link é montado a partir dela.'),
  ('loja_hora_semana_abre', '11:00',
   'Horário de abertura de segunda a sábado.'),
  ('loja_hora_semana_fecha', '21:00',
   'Horário de fechamento de segunda a sábado.'),
  ('loja_hora_domingo_abre', '14:00',
   'Horário de abertura no domingo. Vazio = fechado.'),
  ('loja_hora_domingo_fecha', '19:00',
   'Horário de fechamento no domingo. Vazio = fechado.')
on conflict (chave) do nothing;
