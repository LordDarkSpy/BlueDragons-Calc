// Página de vendas (fora do painel). Quem pode abrir: perfis com "Vendas";
// cancelar/reativar: perfis com "Cancelar / reativar vendas". O banco confere as duas.
(function () {
  const { db, esc, formatarValor } = BD;
  const $ = (id) => document.getElementById(id);

  if (!db) {
    BD.mostrarErroConfig($('principal'));
    return;
  }

  let perfil = null;
  let vendas = [];
  let produtos = [];
  let carregando = 0;
  const pode = (permissao) => BD.pode(perfil, permissao);

  // ---------------------------------------------------------------- login

  function mostrarLogin(texto, erro) {
    $('vendas-app').hidden = true;
    $('vendas-login').hidden = false;
    $('vendas-login-texto').textContent = texto;
    $('vendas-login-erro').hidden = !erro;
    $('vendas-login-erro').textContent = erro || '';
  }

  $('vendas-entrar').addEventListener('click', async (e) => {
    const botao = e.currentTarget;
    const { data: { session } } = await db.auth.getSession();
    if (session) await db.auth.signOut(); // "entrar com outra conta"
    botao.disabled = true;
    botao.textContent = '⏳ Abrindo o Discord…';
    try {
      await BD.entrarComDiscord();
    } catch (erro) {
      botao.disabled = false;
      botao.textContent = 'Entrar com Discord';
      mostrarLogin('Entre com a sua conta do Discord para ver as vendas.', BD.mensagemErro(erro));
    }
  });

  async function iniciar() {
    const erroLogin = BD.erroDoLogin();
    try {
      perfil = await BD.perfil();
    } catch (erro) {
      return mostrarLogin('Entre com a sua conta do Discord para ver as vendas.', BD.mensagemErro(erro));
    }
    if (!perfil) return mostrarLogin('Entre com a sua conta do Discord para ver as vendas.', erroLogin && 'O Discord não completou o login: ' + erroLogin);
    BD.ajustarLinksTopo(perfil);
    $('vendas-entrar').textContent = 'Entrar com outra conta';
    if (!perfil.cadastrado && !perfil.lider) {
      return mostrarLogin(`Sua conta do Discord ainda não está cadastrada (ID ${perfil.discord_id || '—'}). Peça para a liderança liberar seu acesso.`);
    }
    if (!pode('ver_vendas')) {
      return mostrarLogin('O seu perfil não tem acesso às vendas. Peça à liderança para ajustar o seu perfil.');
    }
    $('usuario-vendas').textContent = perfil.nome || perfil.apelido || '';
    $('usuario-vendas').hidden = false;
    $('vendas-login').hidden = true;
    $('vendas-app').hidden = false;
    await carregarBase();
    carregarVendas();
    BD.novidades(perfil);
  }

  // ---------------------------------------------------------------- filtros

  async function carregarBase() {
    const [filtros, prod, cfg] = await Promise.all([
      db.rpc('vendas_filtros'),
      db.from('produtos').select('id, nome, icone, imagem'),
      db.from('configuracoes').select('moeda').eq('id', 1).maybeSingle(),
    ]);
    if (cfg.data && cfg.data.moeda) BD.moeda = cfg.data.moeda;
    produtos = prod.data || [];
    const f = filtros.data || { vendedores: [], parcerias: [] };
    $('vendas-vendedor').innerHTML = '<option value="">Todos</option>'
      + f.vendedores.map((v) => `<option value="${esc(v.id)}">${esc(v.nome)}</option>`).join('');
    $('vendas-parceria').innerHTML = '<option value="">Todas</option><option value="sem">Pista (sem parceria)</option>'
      + f.parcerias.map((p) => `<option value="${esc(p.id)}">${esc(p.nome)}${p.ativo ? '' : ' (encerrada)'}</option>`).join('');
  }

  $('vendas-de').value = BD.dataISO(BD.inicioSemana(new Date()));
  $('vendas-ate').value = BD.dataISO(new Date());
  ['vendas-de', 'vendas-ate', 'vendas-vendedor', 'vendas-parceria', 'vendas-canceladas']
    .forEach((id) => $(id).addEventListener('change', carregarVendas));

  // Produto do catálogo para mostrar a imagem certa (pelo id; se foi apagado, pelo nome).
  function produtoDoItem(i) {
    return produtos.find((p) => p.id === i.produto_id)
      || produtos.find((p) => p.nome === i.produto_nome)
      || { icone: i.icone };
  }

  // ---------------------------------------------------------------- lista

  async function carregarVendas() {
    const container = $('vendas-tabela');
    container.innerHTML = '<p class="carregando">Carregando…</p>';
    const de = $('vendas-de').value;
    const ate = $('vendas-ate').value;

    let consulta = db.from('vendas')
      .select('id, numero, criado_em, vendedor_id, vendedor_nome, parceria_id, parceria_nome, com_parceria, cliente, total, comissao, observacao, cancelada, cancelada_em, cancelada_motivo, cancelada_por, venda_itens(produto_id, produto_nome, icone, quantidade, preco_unitario, subtotal)')
      .order('criado_em', { ascending: false })
      .limit(1000);
    if (de) consulta = consulta.gte('criado_em', new Date(`${de}T00:00:00`).toISOString());
    if (ate) consulta = consulta.lt('criado_em', new Date(`${BD.dataISO(BD.somarDias(`${ate}T12:00:00`, 1))}T00:00:00`).toISOString());
    if ($('vendas-vendedor').value) consulta = consulta.eq('vendedor_id', $('vendas-vendedor').value);
    const parceria = $('vendas-parceria').value;
    if (parceria === 'sem') consulta = consulta.eq('com_parceria', false);
    else if (parceria) consulta = consulta.eq('parceria_id', parceria);
    if (!$('vendas-canceladas').checked) consulta = consulta.eq('cancelada', false);

    const minha = ++carregando;
    const { data, error } = await consulta;
    if (minha !== carregando) return; // o filtro mudou enquanto carregava
    if (error) {
      container.innerHTML = `<p class="status erro">${esc(BD.mensagemErro(error))}</p>`;
      return;
    }
    vendas = data;

    const validas = data.filter((v) => !v.cancelada);
    const soma = validas.reduce((s, v) => s + Number(v.total), 0);
    $('vendas-resumo').textContent = `${validas.length} venda${validas.length === 1 ? '' : 's'} · ${formatarValor(soma)}`;

    if (!data.length) {
      container.innerHTML = '<p class="vazio">Nenhuma venda encontrada no período.</p>';
      return;
    }
    const acoes = pode('cancelar_venda');
    container.innerHTML = `<table>
      <thead><tr><th>#</th><th>Data</th><th>Vendedor</th><th>Cliente</th><th>Tipo</th><th>Itens</th><th class="num">Total</th><th class="num">Comissão</th>${acoes ? '<th></th>' : ''}</tr></thead>
      <tbody>${data.map((v) => `
        <tr class="${v.cancelada ? 'cancelada' : ''}">
          <td>${v.numero}</td>
          <td style="white-space:nowrap">${BD.dataHoraBR(v.criado_em)}</td>
          <td>${esc(v.vendedor_nome)}</td>
          <td>${esc(v.cliente || (v.com_parceria ? v.parceria_nome : '') || '—')}</td>
          <td>${v.com_parceria ? '<span class="etiqueta parceria">Parceria</span>' : '<span class="etiqueta">Pista</span>'}</td>
          <td><ul class="itens-venda">${v.venda_itens.map((i) => `<li>${BD.iconeProduto(produtoDoItem(i), 'chip-img')} ${esc(i.produto_nome)} x${i.quantidade}</li>`).join('')}</ul>
            ${v.cancelada && v.cancelada_motivo ? `<div class="motivo-cancelamento">⛔ Cancelada${v.cancelada_por ? ' por ' + esc(v.cancelada_por) : ''}${v.cancelada_em ? ' em ' + esc(BD.dataHoraBR(v.cancelada_em)) : ''}: ${esc(v.cancelada_motivo)}</div>` : ''}
            ${v.observacao ? `<div class="dica">📝 ${esc(v.observacao)}</div>` : ''}</td>
          <td class="num"><strong>${formatarValor(v.total)}</strong></td>
          <td class="num">${formatarValor(v.comissao)}</td>
          ${acoes ? `<td class="acoes">${v.cancelada
            ? `<button type="button" class="botao botao-pequeno" data-reativar="${esc(v.id)}">Reativar</button>`
            : `<button type="button" class="botao-perigo botao-pequeno" data-cancelar="${esc(v.id)}">Cancelar</button>`}</td>` : ''}
        </tr>`).join('')}
      </tbody></table>`;
  }

  // ---------------------------------------------------------------- cancelar / reativar

  $('vendas-tabela').addEventListener('click', async (e) => {
    const botao = e.target.closest('[data-cancelar], [data-reativar]');
    if (!botao) return;
    if (botao.dataset.cancelar) return abrirCancelarVenda(botao.dataset.cancelar);
    botao.disabled = true;
    const { error } = await db.rpc('reativar_venda', { p_id: botao.dataset.reativar });
    BD.toast(error ? BD.mensagemErro(error) : 'Venda reativada.', error ? 'erro' : 'ok');
    carregarVendas();
  });

  let vendaCancelando = null;
  function abrirCancelarVenda(id) {
    const v = vendas.find((x) => x.id === id);
    vendaCancelando = id;
    $('cancelar-venda-info').textContent = v ? `Venda #${v.numero} · ${v.vendedor_nome} · ${formatarValor(v.total)}` : '';
    $('cancelar-venda-motivo').value = '';
    $('cancelar-venda-erro').hidden = true;
    $('cancelar-venda-confirmar').disabled = false;
    BD.abrirModal($('modal-cancelar-venda'), $('cancelar-venda-motivo'));
  }

  $('form-cancelar-venda').addEventListener('submit', async (e) => {
    e.preventDefault();
    const motivo = $('cancelar-venda-motivo').value.trim();
    const erro = $('cancelar-venda-erro');
    if (motivo.length < 3) {
      erro.textContent = 'Informe a justificativa do cancelamento.';
      erro.hidden = false;
      $('cancelar-venda-motivo').focus();
      return;
    }
    $('cancelar-venda-confirmar').disabled = true;
    const { error } = await db.rpc('cancelar_venda', { p_id: vendaCancelando, p_motivo: motivo });
    if (error) {
      erro.textContent = BD.mensagemErro(error);
      erro.hidden = false;
      $('cancelar-venda-confirmar').disabled = false;
      return;
    }
    BD.fecharModal($('modal-cancelar-venda'));
    BD.toast('Venda cancelada.', 'ok');
    carregarVendas();
  });
  $('cancelar-venda-voltar').addEventListener('click', () => BD.fecharModal($('modal-cancelar-venda')));
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !$('modal-cancelar-venda').hidden) BD.fecharModal($('modal-cancelar-venda'));
  });

  // ---------------------------------------------------------------- CSV

  function baixarCSV(nome, linhas) {
    const csv = linhas.map((l) => l.map((c) => {
      const t = String(c ?? '');
      return /[";\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
    }).join(';')).join('\r\n');
    const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = nome;
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  }

  $('vendas-csv').addEventListener('click', () => {
    const linhas = [['Número', 'Data', 'Vendedor', 'Cliente', 'Parceria', 'Produto', 'Quantidade', 'Preço unitário', 'Subtotal', 'Total da venda', 'Comissão da venda', 'Observação', 'Cancelada', 'Justificativa do cancelamento']];
    vendas.forEach((v) => v.venda_itens.forEach((i) => linhas.push([
      v.numero, BD.dataHoraBR(v.criado_em), v.vendedor_nome, v.cliente || (v.com_parceria ? v.parceria_nome : '') || '', v.com_parceria ? v.parceria_nome : 'Pista',
      i.produto_nome, i.quantidade, i.preco_unitario, i.subtotal, v.total, v.comissao, v.observacao || '', v.cancelada ? 'Sim' : 'Não', v.cancelada_motivo || '',
    ])));
    baixarCSV(`vendas-${$('vendas-de').value || 'inicio'}-a-${$('vendas-ate').value || 'hoje'}.csv`, linhas);
  });

  iniciar();
})();
