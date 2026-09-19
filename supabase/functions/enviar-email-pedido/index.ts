// =====================================================================
// enviar-email-pedido — avisa o cliente, por e-mail, que o pedido dele
// foi registrado, com os itens, o total e a chave Pix para pagamento.
//
// NÃO ESTÁ NO AR AINDA. Enquanto esta função não for publicada, o botão
// "Enviar e-mail" da retaguarda abre o aplicativo de e-mail do celular
// ou do computador com a mensagem já escrita, e basta apertar enviar.
// Publicada, o mesmo botão passa a mandar sozinho. O código da retaguarda
// tenta esta função primeiro e só cai no aplicativo se ela não responder,
// então publicar não exige mexer em mais nada.
//
// Para publicar (uma vez só):
//   1. Crie uma conta em resend.com e confirme o domínio alphagalerie.com
//   2. supabase secrets set RESEND_API_KEY=re_xxx
//      supabase secrets set EMAIL_REMETENTE="Alpha Galerie <pedidos@alphagalerie.com>"
//   3. supabase functions deploy enviar-email-pedido
//
// Por que o corpo do e-mail é montado aqui e não no navegador: quem chama
// manda só o número do pedido. Os valores, os itens e a chave Pix saem do
// banco, do lado do servidor. Assim ninguém consegue usar esta função para
// disparar um e-mail com o texto que quiser em nome da loja.
// =====================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const brl = (v: number) =>
  'R$ ' + Number(v || 0).toFixed(2).replace('.', ',').replace(/\B(?=(\d{3})+(?!\d))/g, '.')

const escapeHtml = (v: unknown) =>
  String(v ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;')

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const apiKey = Deno.env.get('RESEND_API_KEY')
    if (!apiKey) return json({ error: 'E-mail automático não configurado.' }, 501)

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const admin = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

    // Só o admin da retaguarda dispara e-mail em nome da loja.
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '')
    const { data: userData } = await admin.auth.getUser(token)
    const papel = (userData?.user?.app_metadata as Record<string, unknown> | undefined)?.role
    if (papel !== 'admin') return json({ error: 'Sem permissão.' }, 403)

    const { pedido_id } = await req.json()
    if (!pedido_id) return json({ error: 'pedido_id é obrigatório.' }, 400)

    const { data: pedido, error: erroPedido } = await admin
      .from('pedidos')
      .select('id, numero, cliente_nome, cliente_email, subtotal, frete, total, forma_pagamento, tipo_entrega, cliente_endereco')
      .eq('id', pedido_id)
      .single()
    if (erroPedido || !pedido) return json({ error: 'Pedido não encontrado.' }, 404)
    if (!pedido.cliente_email) return json({ error: 'Este pedido não tem e-mail do cliente.' }, 422)

    const { data: itens } = await admin
      .from('pedido_itens')
      .select('produto_nome, quantidade, preco_unitario, subtotal')
      .eq('pedido_id', pedido.id)

    const { data: cfg } = await admin
      .from('configuracoes')
      .select('chave, valor')
      .in('chave', ['loja_pix_chave', 'loja_telefone'])
    const conf: Record<string, string> = {}
    for (const linha of cfg || []) conf[linha.chave] = linha.valor

    const linhasItens = (itens || []).map((i) =>
      `<tr>
         <td style="padding:8px 0;border-bottom:1px solid #eee;">${escapeHtml(i.produto_nome)}</td>
         <td style="padding:8px 0;border-bottom:1px solid #eee;text-align:center;">${i.quantidade}x</td>
         <td style="padding:8px 0;border-bottom:1px solid #eee;text-align:right;">${brl(Number(i.subtotal))}</td>
       </tr>`).join('')

    const blocoPix = conf.loja_pix_chave
      ? `<p style="margin:24px 0 4px;font-size:14px;"><strong>Para pagar por Pix</strong></p>
         <p style="margin:0;font-size:14px;">Chave: <strong>${escapeHtml(conf.loja_pix_chave)}</strong><br>
         Valor: <strong>${brl(Number(pedido.total))}</strong></p>
         <p style="margin:8px 0 0;font-size:13px;color:#666;">Depois de pagar, envie o comprovante no WhatsApp${conf.loja_telefone ? ' ' + escapeHtml(conf.loja_telefone) : ''}.</p>`
      : ''

    const html = `<div style="font-family:Arial,Helvetica,sans-serif;color:#222;max-width:560px;">
      <h2 style="font-weight:normal;">Olá, ${escapeHtml(pedido.cliente_nome)}!</h2>
      <p style="font-size:14px;line-height:1.6;">Seu pedido <strong>#${escapeHtml(pedido.numero)}</strong> foi registrado na Alpha Galerie.</p>
      <table style="width:100%;border-collapse:collapse;font-size:14px;margin-top:16px;">${linhasItens}</table>
      <p style="font-size:14px;margin-top:16px;">
        Subtotal: ${brl(Number(pedido.subtotal))}<br>
        ${Number(pedido.frete) > 0 ? 'Frete: ' + brl(Number(pedido.frete)) + '<br>' : ''}
        <strong style="font-size:16px;">Total: ${brl(Number(pedido.total))}</strong>
      </p>
      ${pedido.tipo_entrega === 'retirada'
        ? '<p style="font-size:14px;">Retirada na loja.</p>'
        : (pedido.cliente_endereco ? `<p style="font-size:14px;">Entrega em: ${escapeHtml(pedido.cliente_endereco)}</p>` : '')}
      ${blocoPix}
      <p style="font-size:13px;color:#888;margin-top:28px;">Alpha Galerie · alphagalerie.com</p>
    </div>`

    const resp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: Deno.env.get('EMAIL_REMETENTE') || 'Alpha Galerie <onboarding@resend.dev>',
        to: [pedido.cliente_email],
        subject: `Pedido #${pedido.numero} registrado — Alpha Galerie`,
        html,
      }),
    })

    if (!resp.ok) {
      console.error('Resend recusou:', await resp.text())
      return json({ error: 'O serviço de e-mail recusou o envio.' }, 502)
    }

    return json({ ok: true, enviado_para: pedido.cliente_email })
  } catch (err) {
    console.error('Erro interno:', err)
    return json({ error: 'Erro interno do servidor.' }, 500)
  }
})
