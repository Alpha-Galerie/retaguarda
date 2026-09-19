-- =====================================================================
-- Chave Pix da loja editável pela retaguarda.
-- Aplicada em 2026-09-19.
--
-- A chave Pix estava escrita à mão dentro do index.html da retaguarda,
-- num painel que só a exibia. O pedido manual precisa dela de verdade:
-- é com ela que o "copia e cola" enviado ao cliente é montado. Chave
-- errada significa dinheiro caindo na conta de outra pessoa, então ela
-- passa a viver aqui, num lugar só, editável sem mexer em código.
--
-- Nome e cidade do recebedor entram junto porque o padrão do Banco
-- Central (BR Code / EMV) exige os dois dentro do payload. Sem eles o
-- app do banco recusa o código ou mostra o recebedor em branco.
--
-- Observação de segurança: a tabela `configuracoes` tem leitura liberada
-- para o papel anônimo. Uma chave Pix é, por definição, um dado público
-- de recebimento — é o que se imprime no balcão — então isso não expõe
-- nada que o cliente já não veja ao pagar.
-- =====================================================================

insert into public.configuracoes (chave, valor, descricao) values
  ('loja_pix_chave', '11942920076',
   'Chave Pix que recebe os pedidos manuais. CPF/CNPJ só com números, ou telefone, e-mail ou chave aleatória.'),
  ('loja_pix_nome', 'ALPHA GALERIE',
   'Nome do recebedor como aparece no app do banco do cliente. Até 25 caracteres, sem acento.'),
  ('loja_pix_cidade', 'BARUERI',
   'Cidade do recebedor exigida pelo padrão do Banco Central. Até 15 caracteres, sem acento.')
on conflict (chave) do nothing;
