(function () {
  const { db, esc, formatarValor } = BD;
  const $ = (id) => document.getElementById(id);

  if (!db) {
    BD.mostrarErroConfig($('principal'));
    return;
  }

  const cache = { vendedores: [], parcerias: [], produtos: [], vendas: [] };
  let semanaInicio = BD.inicioSemana(new Date());
  let relatorioAtual = null;
  let meuDiscordId = null;

  // ================================================================ autenticação

  async function verificarAcesso() {
    const { data: { session } } = await db.auth.getSession();
    $("form-login").hidden = true;
    $("sem-permissao").hidden = true;
    $("app").hidden = true;
    $("sair").hidden = !session;
    $("usuario-admin").hidden = !session;

    if (!session) {
      $("form-login").hidden = false;
      return;
    }

    let perfil;
    try {
      perfil = await BD.perfil();
    } catch (erro) {
      $("form-login").hidden = false;
      $("login-erro").hidden = false;
      $("login-erro").textContent = BD.mensagemErro(erro);
      return;
    }
    $("usuario-admin").textContent = perfil.nome || perfil.apelido || session.user.email || "";
    meuDiscordId = perfil.discord_id;
    if (!perfil.admin) {
      $("sem-permissao-id").value = perfil.discord_id || "";
      $("sem-permissao").hidden = false;
      return;
    }
    $("app").hidden = false;
    iniciarPainel();
  }

  $("login-entrar").addEventListener("click", async () => {
    const botao = $("login-entrar");
    botao.disabled = true;
    botao.textContent = "⏳ Abrindo o Discord…";
    try {
      await BD.entrarComDiscord();
    } catch (erro) {
      botao.disabled = false;
      botao.textContent = "Entrar com Discord";
      $("login-erro").hidden = false;
      $("login-erro").textContent = BD.mensagemErro(erro);
    }
  });

  async function sair() {
    await db.auth.signOut();
    painelIniciado = false;
    verificarAcesso();
  }
  $('sair').addEventListener('click', sair);
  $('sair-sem-permissao').addEventListener('click', sair);

  // ================================================================ abas

  const carregadores = {
    relatorio: carregarRelatorio,
    vendas: carregarVendas,
    vendedores: carregarVendedores,
    parcerias: carregarParcerias,
    produtos: carregarProdutos,
    config: carregarConfig,
  };

  function abrirAba(nome) {
    document.querySelectorAll('[data-aba]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.aba === nome)));
    Object.keys(carregadores).forEach((aba) => { $(`aba-${aba}`).hidden = aba !== nome; });
    BD.salvar('bluedragons-aba', nome);
    carregadores[nome]();
  }

  document.querySelectorAll('[data-aba]').forEach((b) => b.addEventListener('click', () => abrirAba(b.dataset.aba)));

  let painelIniciado = false;
  async function iniciarPainel() {
    if (painelIniciado) return;
    painelIniciado = true;
    await Promise.all([carregarListasBase(), carregarConfig()]);
    const salva = BD.lerSalvo('bluedragons-aba');
    abrirAba(carregadores[salva] ? salva : 'relatorio');
  }

  async function carregarListasBase() {
    const [ve, pa, pr] = await Promise.all([
      db.from('vendedores').select('id, nome, discord_id, admin, ativo, criado_em, nome_discord, no_servidor, nome_discord_em, cargos').order('nome'),
      db.from('parcerias').select('*').order('nome'),
      db.from('produtos').select('*').order('ordem').order('nome'),
    ]);
    cache.vendedores = ve.data || [];
    cache.parcerias = pa.data || [];
    cache.produtos = pr.data || [];
    $('vendas-vendedor').innerHTML = '<option value="">Todos</option>'
      + cache.vendedores.map((v) => `<option value="${esc(v.id)}">${esc(nomeVendedor(v))}</option>`).join('');
    $('vendas-parceria').innerHTML = '<option value="">Todas</option><option value="sem">Pista (sem parceria)</option>'
      + cache.parcerias.map((p) => `<option value="${esc(p.id)}">${esc(p.nome)}</option>`).join('');
  }

  function erroNaTabela(container, erro) {
    container.innerHTML = `<p class="status erro">${esc(BD.mensagemErro(erro))}</p>`;
  }

  function etiquetaAtivo(ativo) {
    return ativo ? '<span class="etiqueta ativo">Ativo</span>' : '<span class="etiqueta inativo">Inativo</span>';
  }

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

  // ================================================================ relatório semanal

  function tabelaRanking(lista, comIcone) {
    if (!lista.length) return '<p class="vazio">Sem vendas no período.</p>';
    const maior = Math.max(...lista.map((x) => Number(x.total)), 1);
    return `<table>
      <thead><tr><th>Nome</th><th class="num">Qtd.</th><th class="num">Total</th></tr></thead>
      <tbody>${lista.map((x) => `
        <tr>
          <td>${comIcone ? `<span class="rel-produto"><span class="produto-tabela-icone">${BD.iconeProduto(x, 'produto-img-pequena')}</span>${esc(x.nome)}</span>` : esc(x.nome)}
            <div class="barra-progresso"><span style="width:${(Number(x.total) / maior) * 100}%"></span></div></td>
          <td class="num">${Number(x.quantidade).toLocaleString('pt-BR')}</td>
          <td class="num">${formatarValor(x.total)}</td>
        </tr>`).join('')}
      </tbody></table>`;
  }

  async function carregarRelatorio() {
    const fim = BD.somarDias(semanaInicio, 6);
    $('semana-titulo').textContent = `${BD.dataBR(BD.dataISO(semanaInicio))} a ${BD.dataBR(BD.dataISO(fim))}`;
    $('semana-proxima').disabled = semanaInicio >= BD.inicioSemana(new Date());
    ['vendedores', 'parcerias', 'produtos', 'craft'].forEach((t) => { $(`rel-${t}`).innerHTML = '<p class="carregando">Carregando…</p>'; });

    const anterior = BD.somarDias(semanaInicio, -7);
    const [atual, passada] = await Promise.all([
      db.rpc('relatorio_periodo', { p_inicio: BD.dataISO(semanaInicio), p_fim: BD.dataISO(fim) }),
      db.rpc('relatorio_periodo', { p_inicio: BD.dataISO(anterior), p_fim: BD.dataISO(BD.somarDias(anterior, 6)) }),
    ]);
    if (atual.error) {
      ['vendedores', 'parcerias', 'produtos', 'craft'].forEach((t) => erroNaTabela($(`rel-${t}`), atual.error));
      return;
    }
    const r = atual.data;
    relatorioAtual = r;
    const total = Number(r.total);
    $('kpi-total').textContent = formatarValor(total);
    $('kpi-quantidade').textContent = r.quantidade;
    $('kpi-com').textContent = formatarValor(r.total_com_parceria);
    $('kpi-sem').textContent = formatarValor(r.total_sem_parceria);

    const totalPassado = passada.data ? Number(passada.data.total) : 0;
    if (totalPassado > 0) {
      const variacao = ((total - totalPassado) / totalPassado) * 100;
      $('kpi-variacao').textContent = `${variacao >= 0 ? '▲' : '▼'} ${Math.abs(variacao).toFixed(0)}% vs. semana anterior`;
      $('kpi-variacao').style.color = variacao >= 0 ? 'var(--verde)' : 'var(--vermelho)';
    } else {
      $('kpi-variacao').textContent = '';
    }

    const pct = Math.round(Number(r.percentual_comissao || 0) * 1000) / 10;
    $('kpi-comissao').textContent = formatarValor(r.comissao);
    $('kpi-pct').textContent = `${pct}% por vendedor`;

    renderizarPagamentos(r);
    $('rel-parcerias').innerHTML = tabelaRanking(r.por_parceria);
    $('rel-produtos').innerHTML = tabelaRanking(r.por_produto, true);
    $('rel-craft').innerHTML = (r.craft || []).length
      ? `<table><thead><tr><th>Material</th><th class="num">Quantidade</th></tr></thead>
          <tbody>${r.craft.map((x) => `<tr><td>${esc(x.nome)}</td><td class="num"><strong>${Number(x.quantidade).toLocaleString('pt-BR')}</strong></td></tr>`).join('')}</tbody></table>`
      : '<p class="vazio">Nenhum material usado no período.</p>';
  }

  function dataHoraBR(iso) {
    return new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
  }

  function situacaoPagamento(x) {
    const comissao = Number(x.comissao) || 0;
    const pago = Number(x.pago) || 0;
    const pendente = Number(x.pendente) || 0;
    if (comissao <= 0) return { html: '<span class="etiqueta sem-valor">Sem comissão</span>', pendente: 0 };
    const info = x.pago_em ? `<span class="pagamento-info">${esc(dataHoraBR(x.pago_em))}${x.pago_por ? ' · ' + esc(x.pago_por) : ''}</span>` : '';
    if (pendente <= 0) return { html: `<span class="etiqueta pago">✅ Pago</span>${info}`, pendente: 0 };
    if (pago > 0) {
      return { html: `<span class="etiqueta pendente">⏳ Falta ${esc(formatarValor(pendente))}</span><span class="pagamento-info">Já pago ${esc(formatarValor(pago))}</span>`, pendente };
    }
    return { html: '<span class="etiqueta pendente">⏳ Pendente</span>', pendente };
  }

  function renderizarPagamentos(r) {
    const lista = r.por_vendedor || [];
    if (!lista.length) {
      $('rel-pagos').textContent = '';
      $('rel-vendedores').innerHTML = '<p class="vazio">Sem vendas no período.</p>';
      return;
    }
    const pagos = lista.filter((x) => Number(x.comissao) > 0 && Number(x.pendente) <= 0).length;
    const comComissao = lista.filter((x) => Number(x.comissao) > 0).length;
    const totalPendente = lista.reduce((s, x) => s + (Number(x.pendente) || 0), 0);
    $('rel-pagos').textContent = `${pagos} de ${comComissao} pago${comComissao === 1 ? '' : 's'}`
      + (totalPendente > 0 ? ` · falta pagar ${formatarValor(totalPendente)}` : '');

    $('rel-vendedores').innerHTML = `<table class="tabela-pagamentos">
      <thead><tr><th>Vendedor</th><th class="num">Vendas</th><th class="num">Total vendido</th><th class="num">Pagamento</th><th>Situação</th><th class="acao"></th></tr></thead>
      <tbody>${lista.map((x, i) => {
        const s = situacaoPagamento(x);
        return `<tr>
          <td><strong>${esc(x.nome)}</strong></td>
          <td class="num">${x.quantidade}</td>
          <td class="num">${formatarValor(x.total)}</td>
          <td class="num"><strong>${formatarValor(x.comissao)}</strong></td>
          <td>${s.html}</td>
          <td class="acao">${s.pendente > 0 && x.vendedor_id ? `<button type="button" class="botao-sucesso botao-pequeno" data-pagar="${i}">💸 Pagar</button>` : ''}</td>
        </tr>`;
      }).join('')}
      </tbody>
      <tfoot><tr><th>Total</th><th class="num">${r.quantidade}</th><th class="num">${formatarValor(r.total)}</th><th class="num">${formatarValor(r.comissao)}</th><th colspan="2"></th></tr></tfoot>
    </table>`;
  }

  // ---------------------------------------------------------------- pagamento

  let pagamentoAtual = null;

  $('rel-vendedores').addEventListener('click', (e) => {
    const botao = e.target.closest('[data-pagar]');
    if (!botao || !relatorioAtual) return;
    const x = relatorioAtual.por_vendedor[Number(botao.dataset.pagar)];
    if (!x) return;
    pagamentoAtual = { vendedor_id: x.vendedor_id, semana: relatorioAtual.inicio, valor: Number(x.pendente) };
    $('pagamento-vendedor').textContent = x.nome;
    $('pagamento-semana').textContent = `Semana de ${BD.dataBR(relatorioAtual.inicio)} a ${BD.dataBR(relatorioAtual.fim)}`;
    $('pagamento-valor').textContent = formatarValor(x.pendente);
    $('pagamento-ja-pago').textContent = Number(x.pago) > 0
      ? `Comissão ${formatarValor(x.comissao)} · já pago ${formatarValor(x.pago)}` : `${x.quantidade} venda${x.quantidade === 1 ? '' : 's'} · ${formatarValor(x.total)} vendido`;
    $('pagamento-copiar').textContent = '📋 Copiar valor';
    $('pagamento-copiar').classList.remove('copiado');
    $('pagamento-observacao').value = '';
    $('pagamento-erro').hidden = true;
    $('pagamento-registrar').disabled = false;
    BD.abrirModal($('modal-pagamento'), $('pagamento-copiar'));
  });

  $('pagamento-copiar').addEventListener('click', () => {
    if (!pagamentoAtual) return;
    BD.copiar(String(Math.round(pagamentoAtual.valor)))
      .then(() => { $('pagamento-copiar').textContent = '✅ Valor copiado!'; $('pagamento-copiar').classList.add('copiado'); })
      .catch(() => { $('pagamento-copiar').textContent = 'Não consegui copiar — anote o valor acima'; });
  });

  $('form-pagamento').addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!pagamentoAtual) return;
    const botao = $('pagamento-registrar');
    botao.disabled = true;
    $('pagamento-erro').hidden = true;
    const { data, error } = await db.rpc('registrar_pagamento', {
      p_vendedor_id: pagamentoAtual.vendedor_id,
      p_semana_inicio: pagamentoAtual.semana,
      p_observacao: $('pagamento-observacao').value.trim() || null,
    });
    if (error) {
      botao.disabled = false;
      $('pagamento-erro').textContent = BD.mensagemErro(error);
      $('pagamento-erro').hidden = false;
      carregarRelatorio(); // o valor pode ter mudado (outro admin pagou, venda cancelada…)
      return;
    }
    BD.fecharModal($('modal-pagamento'));
    pagamentoAtual = null;
    BD.toast(`💸 Pagamento de ${formatarValor(data.valor)} registrado${data.notificado ? ' e avisado no Discord' : ''}.`, 'ok');
    carregarRelatorio();
  });

  $('pagamento-cancelar').addEventListener('click', () => BD.fecharModal($('modal-pagamento')));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('modal-pagamento').hidden) BD.fecharModal($('modal-pagamento')); });

  $('semana-anterior').addEventListener('click', () => { semanaInicio = BD.somarDias(semanaInicio, -7); carregarRelatorio(); });
  $('semana-proxima').addEventListener('click', () => { semanaInicio = BD.somarDias(semanaInicio, 7); carregarRelatorio(); });
  $('semana-atual').addEventListener('click', () => { semanaInicio = BD.inicioSemana(new Date()); carregarRelatorio(); });

  $('relatorio-discord').addEventListener('click', async () => {
    const botao = $('relatorio-discord');
    botao.disabled = true;
    const { error } = await db.rpc('enviar_relatorio_discord', { p_inicio: BD.dataISO(semanaInicio) });
    botao.disabled = false;
    BD.toast(error ? BD.mensagemErro(error) : '📤 Relatório enviado para o Discord!', error ? 'erro' : 'ok');
  });

  $('relatorio-csv').addEventListener('click', () => {
    if (!relatorioAtual) return;
    const r = relatorioAtual;
    const linhas = [
      [`Relatório semanal ${BD.dataBR(r.inicio)} a ${BD.dataBR(r.fim)}`],
      ['Total vendido', r.total], ['Vendas', r.quantidade],
      ['Com parceria', r.total_com_parceria], ['Pista', r.total_sem_parceria], ['Comissões', r.comissao], [],
      ['Vendedor', 'Vendas', 'Total', 'Pagamento', 'Já pago', 'Situação'],
      ...r.por_vendedor.map((x) => [x.nome, x.quantidade, x.total, x.comissao, x.pago || 0,
        Number(x.comissao) <= 0 ? 'Sem comissão' : Number(x.pendente) <= 0 ? 'Pago' : 'Pendente']), [],
      ['Parceria', 'Vendas', 'Total'], ...r.por_parceria.map((x) => [x.nome, x.quantidade, x.total]), [],
      ['Produto', 'Quantidade', 'Total', 'Placas', 'Material'], ...r.por_produto.map((x) => [x.nome, x.quantidade, x.total, x.craft_placa, `${x.craft_material} ${x.material_nome || ''}`]), [],
      ['Craft', 'Quantidade'], ...(r.craft || []).map((x) => [x.nome, x.quantidade]),
    ];
    baixarCSV(`relatorio-${r.inicio}.csv`, linhas);
  });

  // ================================================================ vendas

  $('vendas-de').value = BD.dataISO(BD.inicioSemana(new Date()));
  $('vendas-ate').value = BD.dataISO(new Date());
  ['vendas-de', 'vendas-ate', 'vendas-vendedor', 'vendas-parceria', 'vendas-canceladas']
    .forEach((id) => $(id).addEventListener('change', carregarVendas));

  async function carregarVendas() {
    const container = $('vendas-tabela');
    container.innerHTML = '<p class="carregando">Carregando…</p>';
    const de = $('vendas-de').value;
    const ate = $('vendas-ate').value;

    let consulta = db.from('vendas')
      .select('id, numero, criado_em, vendedor_id, vendedor_nome, parceria_id, parceria_nome, com_parceria, cliente, total, comissao, observacao, cancelada, venda_itens(produto_nome, icone, quantidade, preco_unitario, subtotal)')
      .order('criado_em', { ascending: false })
      .limit(1000);
    if (de) consulta = consulta.gte('criado_em', new Date(`${de}T00:00:00`).toISOString());
    if (ate) consulta = consulta.lt('criado_em', new Date(`${BD.dataISO(BD.somarDias(`${ate}T12:00:00`, 1))}T00:00:00`).toISOString());
    if ($('vendas-vendedor').value) consulta = consulta.eq('vendedor_id', $('vendas-vendedor').value);
    const parceria = $('vendas-parceria').value;
    if (parceria === 'sem') consulta = consulta.eq('com_parceria', false);
    else if (parceria) consulta = consulta.eq('parceria_id', parceria);
    if (!$('vendas-canceladas').checked) consulta = consulta.eq('cancelada', false);

    const { data, error } = await consulta;
    if (error) return erroNaTabela(container, error);
    cache.vendas = data;

    const validas = data.filter((v) => !v.cancelada);
    const soma = validas.reduce((s, v) => s + Number(v.total), 0);
    $('vendas-resumo').textContent = `${validas.length} venda${validas.length === 1 ? '' : 's'} · ${formatarValor(soma)}`;

    if (!data.length) {
      container.innerHTML = '<p class="vazio">Nenhuma venda encontrada no período.</p>';
      return;
    }
    container.innerHTML = `<table>
      <thead><tr><th>#</th><th>Data</th><th>Vendedor</th><th>Cliente</th><th>Tipo</th><th>Itens</th><th class="num">Total</th><th class="num">Comissão</th><th></th></tr></thead>
      <tbody>${data.map((v) => `
        <tr class="${v.cancelada ? 'cancelada' : ''}">
          <td>${v.numero}</td>
          <td style="white-space:nowrap">${BD.dataHoraBR(v.criado_em)}</td>
          <td>${esc(v.vendedor_nome)}</td>
          <td>${esc(v.cliente || '—')}</td>
          <td>${v.com_parceria ? `<span class="etiqueta parceria">${esc(v.parceria_nome || 'Parceria')}</span>` : '<span class="etiqueta">Pista</span>'}</td>
          <td><ul class="itens-venda">${v.venda_itens.map((i) => `<li>${esc(i.icone || '')} ${esc(i.produto_nome)} x${i.quantidade}</li>`).join('')}</ul>
            ${v.observacao ? `<div class="dica">📝 ${esc(v.observacao)}</div>` : ''}</td>
          <td class="num"><strong>${formatarValor(v.total)}</strong></td>
          <td class="num">${formatarValor(v.comissao)}</td>
          <td class="acoes">${v.cancelada
            ? `<button type="button" class="botao botao-pequeno" data-reativar="${esc(v.id)}">Reativar</button>`
            : `<button type="button" class="botao-perigo botao-pequeno" data-cancelar="${esc(v.id)}">Cancelar</button>`}</td>
        </tr>`).join('')}
      </tbody></table>`;
  }

  $('vendas-tabela').addEventListener('click', async (e) => {
    const botao = e.target.closest('[data-cancelar], [data-reativar]');
    if (!botao) return;
    const cancelar = !!botao.dataset.cancelar;
    const id = botao.dataset.cancelar || botao.dataset.reativar;
    if (cancelar && !confirm('Cancelar esta venda? Ela deixará de contar nos relatórios.')) return;
    botao.disabled = true;
    const { error } = await db.from('vendas')
      .update({ cancelada: cancelar, cancelada_em: cancelar ? new Date().toISOString() : null })
      .eq('id', id);
    if (error) BD.toast(BD.mensagemErro(error), 'erro');
    else BD.toast(cancelar ? 'Venda cancelada.' : 'Venda reativada.', 'ok');
    carregarVendas();
  });

  $('vendas-csv').addEventListener('click', () => {
    const linhas = [['Número', 'Data', 'Vendedor', 'Cliente', 'Parceria', 'Produto', 'Quantidade', 'Preço unitário', 'Subtotal', 'Total da venda', 'Comissão da venda', 'Observação', 'Cancelada']];
    cache.vendas.forEach((v) => v.venda_itens.forEach((i) => linhas.push([
      v.numero, BD.dataHoraBR(v.criado_em), v.vendedor_nome, v.cliente || '', v.com_parceria ? v.parceria_nome : 'Pista',
      i.produto_nome, i.quantidade, i.preco_unitario, i.subtotal, v.total, v.comissao, v.observacao || '', v.cancelada ? 'Sim' : 'Não',
    ])));
    baixarCSV(`vendas-${$('vendas-de').value || 'inicio'}-a-${$('vendas-ate').value || 'hoje'}.csv`, linhas);
  });

  // ================================================================ modal de edição genérico

  let aoSalvar = null;

  function campoHTML(c) {
    const id = `campo-${c.nome}`;
    const valor = c.valor ?? '';
    if (c.tipo === 'checkbox') {
      return `<label class="checkbox largura-total"><input id="${id}" type="checkbox" ${valor ? 'checked' : ''}> ${esc(c.rotulo)}</label>`;
    }
    const entrada = c.tipo === 'textarea'
      ? `<textarea id="${id}" maxlength="${c.max || 300}" rows="3">${esc(valor)}</textarea>`
      : `<input id="${id}" type="${c.tipo || 'text'}" value="${esc(valor)}" ${c.max ? `maxlength="${c.max}"` : ''} ${c.min !== undefined ? `min="${c.min}"` : ''} ${c.placeholder ? `placeholder="${esc(c.placeholder)}"` : ''} ${c.inputmode ? `inputmode="${c.inputmode}"` : ''} autocomplete="off">`;
    return `<div class="${c.largo ? 'largura-total' : ''}">
      <label class="rotulo" for="${id}">${esc(c.rotulo)} ${c.obrigatorio ? '<span class="obrigatorio">*</span>' : ''}</label>
      ${entrada}${c.dica ? `<p class="dica">${esc(c.dica)}</p>` : ''}</div>`;
  }

  function abrirEdicao(titulo, campos, salvar) {
    $('edicao-titulo').textContent = titulo;
    $('edicao-campos').innerHTML = `<div class="grade-form">${campos.map(campoHTML).join('')}</div>`;
    $('edicao-erro').hidden = true;
    aoSalvar = async () => {
      const valores = {};
      campos.forEach((c) => {
        const el = $(`campo-${c.nome}`);
        valores[c.nome] = c.tipo === 'checkbox' ? el.checked : el.value.trim();
      });
      const faltando = campos.find((c) => c.obrigatorio && valores[c.nome] === '');
      if (faltando) throw new Error(`Preencha o campo "${faltando.rotulo}".`);
      await salvar(valores);
    };
    const primeiro = $('edicao-campos').querySelector('input, textarea');
    BD.abrirModal($('modal-edicao'), primeiro);
  }

  $('form-edicao').addEventListener('submit', async (e) => {
    e.preventDefault();
    const botao = $('edicao-salvar');
    botao.disabled = true;
    try {
      await aoSalvar();
      BD.fecharModal($('modal-edicao'));
      BD.toast('Salvo com sucesso.', 'ok');
    } catch (erro) {
      $('edicao-erro').textContent = BD.mensagemErro(erro);
      $('edicao-erro').hidden = false;
    } finally {
      botao.disabled = false;
    }
  });

  $('edicao-cancelar').addEventListener('click', () => BD.fecharModal($('modal-edicao')));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('modal-edicao').hidden) BD.fecharModal($('modal-edicao')); });

  function falhou(resultado) {
    if (resultado.error) throw resultado.error;
    return resultado.data;
  }

  // ================================================================ vendedores

  async function carregarVendedores() {
    const container = $('vendedores-tabela');
    await Promise.all([carregarListasBase(), carregarCargos()]);
    if (!cache.vendedores.length) {
      container.innerHTML = '<p class="vazio">Nenhum vendedor cadastrado. Clique em "+ Novo vendedor".</p>';
      return;
    }
    container.innerHTML = `<table>
      <thead><tr><th>Nome no Discord</th><th>ID do Discord</th><th>Acesso</th><th>Status</th><th></th></tr></thead>
      <tbody>${cache.vendedores.map((v) => `
        <tr>
          <td><strong>${esc(nomeVendedor(v))}</strong>${v.nome_discord && v.nome_discord !== v.nome ? `<div class="dica">cadastro: ${esc(v.nome)}</div>` : ''}${!v.nome_discord ? '<div class="dica">nome do servidor ainda não buscado</div>' : ''}</td>
          <td><code>${esc(v.discord_id)}</code>${v.discord_id === meuDiscordId ? ' <span class="dica">(você)</span>' : ''}</td>
          <td>${acessoVendedor(v)}</td>
          <td>${etiquetaAtivo(v.ativo)}${v.no_servidor === false ? ' <span class="etiqueta inativo">Fora do servidor</span>' : ''}</td>
          <td class="acoes"><button type="button" class="botao botao-pequeno" data-editar-vendedor="${esc(v.id)}">Editar</button></td>
        </tr>`).join('')}
      </tbody></table>`;
  }

  function editarVendedor(v) {
    const novo = !v;
    v = v || { ativo: true, admin: false };
    abrirEdicao(novo ? "Novo vendedor" : `Editar ${v.nome}`, [
      { nome: "nome", rotulo: "Nome (reserva)", valor: v.nome, obrigatorio: true, max: 40, largo: true,
        dica: "O site mostra o nome que a pessoa usa no servidor do Discord. Este nome só aparece enquanto o do Discord não for encontrado." },
      { nome: "discord_id", rotulo: "ID do Discord", valor: v.discord_id, obrigatorio: true, max: 20, inputmode: "numeric", largo: true,
        dica: "É com ele que a pessoa entra no site. No Discord: Configurações → Avançado → Modo desenvolvedor; depois clique com o botão direito no nome → Copiar ID do usuário." },
      { nome: "ativo", rotulo: "Ativo (pode entrar e registrar vendas)", tipo: "checkbox", valor: v.ativo },
      { nome: "admin", rotulo: "Administrador manual (acessa o painel mesmo sem cargo)", tipo: "checkbox", valor: v.admin,
        dica: "Quem tem um dos cargos escolhidos na aba Discord já acessa o painel sem marcar esta opção." },
    ], async (val) => {
      if (val.nome.length < 2) throw new Error("O nome precisa ter pelo menos 2 letras.");
      if (!/^\d{17,20}$/.test(val.discord_id)) throw new Error("ID do Discord inválido: deve ter de 17 a 20 números.");
      const id = falhou(await db.rpc("salvar_vendedor", {
        p_id: novo ? null : v.id, p_nome: val.nome, p_discord_id: val.discord_id, p_ativo: val.ativo, p_admin: val.admin,
      }));
      await carregarVendedores();
      sincronizarNomes(id, true);
    });
  }

  // Cargos do servidor (para mostrar nomes) e cargos que dão acesso ao painel.
  let cargosServidor = [];
  let cargosAdmin = [];

  async function carregarCargos() {
    const [rc, rcfg] = await Promise.all([
      db.from('discord_cargos').select('id, nome, cor, posicao').order('posicao', { ascending: false }),
      db.from('configuracoes').select('cargos_admin').eq('id', 1).single(),
    ]);
    cargosServidor = rc.data || [];
    cargosAdmin = (rcfg.data && rcfg.data.cargos_admin) || [];
  }

  function acessoVendedor(v) {
    const porCargo = (v.cargos || []).filter((id) => cargosAdmin.includes(id))
      .map((id) => (cargosServidor.find((c) => c.id === id) || { nome: 'cargo ' + id }).nome);
    if (porCargo.length) return `<span class="etiqueta">Administrador</span><div class="dica">pelo cargo ${esc(porCargo.join(', '))}${v.admin ? ' e manual' : ''}</div>`;
    if (v.admin) return '<span class="etiqueta">Administrador</span><div class="dica">manual</div>';
    return 'Vendedor';
  }

  function nomeVendedor(v) {
    return v.nome_discord || v.nome;
  }

  const esperar = (ms) => new Promise((r) => setTimeout(r, ms));

  // Pede os nomes ao Discord (pelo banco) e aplica as respostas, que chegam em 1 ou 2 segundos.
  async function sincronizarNomes(vendedorId, silencioso) {
    const botao = $('sincronizar-nomes');
    const pedido = await db.rpc('discord_buscar_nomes', { p_vendedor_id: vendedorId || null });
    if (pedido.error) {
      if (!silencioso) BD.toast(BD.mensagemErro(pedido.error), 'erro');
      return;
    }
    botao.disabled = true;
    botao.textContent = '⏳ Buscando no Discord…';
    const total = { atualizados: 0, fora_do_servidor: 0, erro: null };
    for (let tentativa = 0; tentativa < 4; tentativa++) {
      await esperar(1500);
      const { data, error } = await db.rpc('discord_aplicar_nomes');
      if (error) { total.erro = BD.mensagemErro(error); break; }
      total.atualizados += data.atualizados;
      total.fora_do_servidor += data.fora_do_servidor;
      total.erro = data.erro || total.erro;
      if (!data.pendentes) break;
    }
    botao.disabled = false;
    botao.textContent = '🔄 Atualizar nomes do Discord';
    await carregarVendedores();
    if (total.erro) return BD.toast(total.erro, 'erro');
    if (total.fora_do_servidor) return BD.toast(`${total.atualizados} nome(s) atualizado(s). ${total.fora_do_servidor} pessoa(s) fora do servidor.`, 'erro');
    if (!silencioso || total.atualizados) BD.toast(`${total.atualizados} nome(s) atualizado(s) a partir do Discord.`, 'ok');
  }

  $('sincronizar-nomes').addEventListener('click', () => sincronizarNomes(null, false));

  $('vendedores-tabela').addEventListener('click', (e) => {
    const botao = e.target.closest('[data-editar-vendedor]');
    if (botao) editarVendedor(cache.vendedores.find((v) => v.id === botao.dataset.editarVendedor));
  });

  // ================================================================ parcerias

  async function carregarParcerias() {
    const container = $('parcerias-tabela');
    await carregarListasBase();
    if (!cache.parcerias.length) {
      container.innerHTML = '<p class="vazio">Nenhuma parceria cadastrada. Clique em "+ Nova parceria".</p>';
      return;
    }
    // Total vendido por parceria na semana atual.
    const ini = BD.inicioSemana(new Date());
    const { data: rel } = await db.rpc('relatorio_periodo', { p_inicio: BD.dataISO(ini), p_fim: BD.dataISO(BD.somarDias(ini, 6)) });
    const porNome = Object.fromEntries(((rel && rel.por_parceria) || []).map((x) => [x.nome, x]));

    container.innerHTML = `<table>
      <thead><tr><th>Parceria</th><th>Responsável</th><th>Observações</th><th class="num">Semana</th><th>Status</th><th></th></tr></thead>
      <tbody>${cache.parcerias.map((p) => `
        <tr>
          <td><strong>${esc(p.nome)}</strong></td>
          <td>${esc(p.responsavel || '—')}</td>
          <td class="dica">${esc(p.observacoes || '')}</td>
          <td class="num">${porNome[p.nome] ? `${formatarValor(porNome[p.nome].total)}<div class="dica">${porNome[p.nome].quantidade} venda(s)</div>` : '—'}</td>
          <td>${etiquetaAtivo(p.ativo)}</td>
          <td class="acoes">
            <button type="button" class="botao botao-pequeno" data-editar-parceria="${esc(p.id)}">Editar</button>
            <button type="button" class="botao-perigo botao-pequeno" data-excluir-parceria="${esc(p.id)}">Excluir</button>
          </td>
        </tr>`).join('')}
      </tbody></table>`;
  }

  function editarParceria(p) {
    const novo = !p;
    p = p || { ativo: true };
    abrirEdicao(novo ? 'Nova parceria' : `Editar ${p.nome}`, [
      { nome: 'nome', rotulo: 'Nome da parceria', valor: p.nome, obrigatorio: true, max: 60, largo: true },
      { nome: 'responsavel', rotulo: 'Responsável / contato', valor: p.responsavel, max: 60, largo: true },
      { nome: 'observacoes', rotulo: 'Observações', tipo: 'textarea', valor: p.observacoes, max: 300, largo: true },
      { nome: 'ativo', rotulo: 'Ativa (aparece na calculadora)', tipo: 'checkbox', valor: p.ativo },
    ], async (val) => {
      const dados = { nome: val.nome, responsavel: val.responsavel || null, observacoes: val.observacoes || null, ativo: val.ativo };
      falhou(novo ? await db.from('parcerias').insert(dados) : await db.from('parcerias').update(dados).eq('id', p.id));
      carregarParcerias();
    });
  }

  $('parcerias-tabela').addEventListener('click', async (e) => {
    const editar = e.target.closest('[data-editar-parceria]');
    if (editar) return editarParceria(cache.parcerias.find((p) => p.id === editar.dataset.editarParceria));
    const excluir = e.target.closest('[data-excluir-parceria]');
    if (!excluir) return;
    const p = cache.parcerias.find((x) => x.id === excluir.dataset.excluirParceria);
    if (!confirm(`Excluir a parceria "${p.nome}"? As vendas antigas continuam com o nome registrado. Para só esconder, use "Editar" e desmarque "Ativa".`)) return;
    const { error } = await db.from('parcerias').delete().eq('id', p.id);
    BD.toast(error ? BD.mensagemErro(error) : 'Parceria excluída.', error ? 'erro' : 'ok');
    carregarParcerias();
  });

  // ================================================================ produtos

  async function carregarProdutos() {
    const container = $('produtos-tabela');
    await carregarListasBase();
    if (!cache.produtos.length) {
      container.innerHTML = '<p class="vazio">Nenhum produto cadastrado. Clique em "+ Novo produto".</p>';
      return;
    }
    container.innerHTML = `<table>
      <thead><tr><th>Ordem</th><th>Produto</th><th>Categoria</th><th class="num">Parceria</th><th class="num">Pista</th><th>Craft / un.</th><th>Status</th><th></th></tr></thead>
      <tbody>${cache.produtos.map((p) => `
        <tr>
          <td>${p.ordem}</td>
          <td><span class="produto-tabela-icone">${BD.iconeProduto(p, 'produto-img-pequena')}</span> <strong>${esc(p.nome)}</strong></td>
          <td>${esc(p.categoria)}</td>
          <td class="num">${formatarValor(p.preco_com_parceria)}</td>
          <td class="num">${formatarValor(p.preco_sem_parceria)}</td>
          <td class="dica">${p.craft_placa} placa · ${p.craft_material} ${esc(String(p.material_nome).toLowerCase())}</td>
          <td>${etiquetaAtivo(p.ativo)}</td>
          <td class="acoes">
            <button type="button" class="botao botao-pequeno" data-editar-produto="${esc(p.id)}">Editar</button>
            <button type="button" class="botao-perigo botao-pequeno" data-excluir-produto="${esc(p.id)}">Excluir</button>
          </td>
        </tr>`).join('')}
      </tbody></table>`;
  }

  function editarProduto(p) {
    const novo = !p;
    p = p || { icone: '📦', categoria: 'Geral', craft_placa: 0, craft_material: 0, material_nome: 'Metal', ativo: true, ordem: (cache.produtos.length + 1) * 10 };
    abrirEdicao(novo ? 'Novo produto' : `Editar ${p.nome}`, [
      { nome: 'icone', rotulo: 'Ícone (emoji)', valor: p.icone, max: 8, dica: 'Usado no Discord e quando não há imagem.' },
      { nome: 'imagem', rotulo: 'Imagem', valor: p.imagem, max: 300, placeholder: 'img/produtos/serra.svg ou https://…', dica: 'Caminho no site ou link de uma imagem. Deixe vazio para usar o emoji.' },
      { nome: 'nome', rotulo: 'Nome', valor: p.nome, obrigatorio: true, max: 60 },
      { nome: 'categoria', rotulo: 'Categoria', valor: p.categoria, max: 30, placeholder: 'Ex.: Pendrives, Ferramentas' },
      { nome: 'ordem', rotulo: 'Ordem na lista', tipo: 'number', valor: p.ordem, dica: 'Menor aparece primeiro.' },
      { nome: 'preco_com_parceria', rotulo: 'Preço parceria', tipo: 'number', min: 0, valor: p.preco_com_parceria, obrigatorio: true },
      { nome: 'preco_sem_parceria', rotulo: 'Preço pista', tipo: 'number', min: 0, valor: p.preco_sem_parceria, obrigatorio: true },
      { nome: 'craft_placa', rotulo: 'Craft: placas por unidade', tipo: 'number', min: 0, valor: p.craft_placa },
      { nome: 'craft_material', rotulo: 'Craft: material por unidade', tipo: 'number', min: 0, valor: p.craft_material },
      { nome: 'material_nome', rotulo: 'Nome do material', valor: p.material_nome, max: 20, placeholder: 'Plástico, Metal…' },
      { nome: 'ativo', rotulo: 'Ativo (aparece na calculadora)', tipo: 'checkbox', valor: p.ativo },
    ], async (val) => {
      const com = Number(val.preco_com_parceria);
      const sem = Number(val.preco_sem_parceria);
      if (!(com >= 0) || !(sem >= 0)) throw new Error('Os preços devem ser números maiores ou iguais a zero.');
      const placa = parseInt(val.craft_placa || '0', 10);
      const material = parseInt(val.craft_material || '0', 10);
      if (!(placa >= 0) || !(material >= 0)) throw new Error('As quantidades de craft devem ser números inteiros maiores ou iguais a zero.');
      const dados = {
        icone: val.icone || '📦', imagem: val.imagem || null, nome: val.nome, categoria: val.categoria || 'Geral',
        preco_com_parceria: com, preco_sem_parceria: sem,
        craft_placa: placa, craft_material: material, material_nome: val.material_nome || 'Material',
        ordem: parseInt(val.ordem, 10) || 0, ativo: val.ativo,
      };
      falhou(novo ? await db.from('produtos').insert(dados) : await db.from('produtos').update(dados).eq('id', p.id));
      carregarProdutos();
    });
  }

  $('produtos-tabela').addEventListener('click', async (e) => {
    const editar = e.target.closest('[data-editar-produto]');
    if (editar) return editarProduto(cache.produtos.find((p) => p.id === editar.dataset.editarProduto));
    const excluir = e.target.closest('[data-excluir-produto]');
    if (!excluir) return;
    const p = cache.produtos.find((x) => x.id === excluir.dataset.excluirProduto);
    if (!confirm(`Excluir o produto "${p.nome}"? As vendas antigas continuam com o nome registrado. Para só esconder, use "Editar" e desmarque "Ativo".`)) return;
    const { error } = await db.from('produtos').delete().eq('id', p.id);
    BD.toast(error ? BD.mensagemErro(error) : 'Produto excluído.', error ? 'erro' : 'ok');
    carregarProdutos();
  });

  document.querySelectorAll('[data-novo]').forEach((b) => b.addEventListener('click', () => {
    ({ vendedor: editarVendedor, parceria: editarParceria, produto: editarProduto })[b.dataset.novo]();
  }));

  // ================================================================ configurações / Discord

  const REGEX_WEBHOOK = /^https:\/\/(canary\.|ptb\.)?(discord|discordapp)\.com\/api\/webhooks\/\d+\/[\w-]+$/;

  async function carregarConfig() {
    const { data, error } = await db.from('configuracoes').select('*').eq('id', 1).single();
    if (error) return BD.toast(BD.mensagemErro(error), 'erro');
    $('cfg-webhook-vendas').value = data.webhook_vendas || '';
    $('cfg-webhook-relatorios').value = data.webhook_relatorios || '';
    $('cfg-notificar').checked = data.notificar_vendas;
    $('cfg-automatico').checked = data.relatorio_automatico;
    $('cfg-nome').value = data.nome_organizacao;
    $('cfg-moeda').value = data.moeda;
    $('cfg-comissao').value = Math.round(Number(data.percentual_comissao) * 1000) / 10;
    $('cfg-servidor').value = data.discord_servidor_id || '';
    atualizarStatusBot();
    renderizarCargos();
    BD.moeda = data.moeda || BD.moeda;
  }

  $('form-config').addEventListener('submit', async (e) => {
    e.preventDefault();
    const vendas = $('cfg-webhook-vendas').value.trim();
    const relatorios = $('cfg-webhook-relatorios').value.trim();
    for (const url of [vendas, relatorios]) {
      if (url && !REGEX_WEBHOOK.test(url)) return BD.toast('URL de webhook do Discord inválida.', 'erro');
    }
    const servidor = $('cfg-servidor').value.trim();
    if (servidor && !/^\d{17,20}$/.test(servidor)) return BD.toast('ID do servidor inválido: deve ter de 17 a 20 números.', 'erro');
    const pct = Number($('cfg-comissao').value);
    if (!(pct >= 0 && pct <= 100)) return BD.toast('A comissão deve ficar entre 0 e 100%.', 'erro');
    const botao = $('cfg-salvar');
    botao.disabled = true;
    const { error } = await db.from('configuracoes').update({
      percentual_comissao: pct / 100,
      discord_servidor_id: servidor || null,
      cargos_admin: [...document.querySelectorAll('#cfg-cargos input:checked')].map((i) => i.value),
      webhook_vendas: vendas || null,
      webhook_relatorios: relatorios || null,
      notificar_vendas: $('cfg-notificar').checked,
      relatorio_automatico: $('cfg-automatico').checked,
      nome_organizacao: $('cfg-nome').value.trim() || 'Blue Dragons',
      moeda: $('cfg-moeda').value || 'R$ ',
      atualizado_em: new Date().toISOString(),
    }).eq('id', 1);
    botao.disabled = false;
    BD.toast(error ? BD.mensagemErro(error) : 'Configurações salvas.', error ? 'erro' : 'ok');
    if (!error) BD.moeda = $('cfg-moeda').value || 'R$ ';
  });

  async function renderizarCargos() {
    await carregarCargos();
    const el = $('cfg-cargos');
    if (!cargosServidor.length) {
      el.innerHTML = '<p class="dica">Nenhum cargo carregado ainda. Salve o token do bot e clique em "Carregar cargos do servidor".</p>';
      return;
    }
    el.innerHTML = cargosServidor.map((c) => {
      const cor = c.cor ? '#' + c.cor.toString(16).padStart(6, '0') : 'var(--texto-suave)';
      return `<label class="checkbox cargo-opcao"><input type="checkbox" value="${esc(c.id)}" ${cargosAdmin.includes(c.id) ? 'checked' : ''}>
        <span class="cargo-cor" style="background:${cor}"></span> ${esc(c.nome)}</label>`;
    }).join('');
  }

  $('cfg-carregar-cargos').addEventListener('click', async () => {
    await sincronizarNomes(null, false);
    renderizarCargos();
  });

  async function atualizarStatusBot() {
    const { data, error } = await db.rpc('discord_status');
    const el = $('cfg-bot-status');
    if (error) { el.textContent = BD.mensagemErro(error); return; }
    el.textContent = data.bot_configurado ? '✅ Token do bot salvo. Para trocar, cole um novo token.' : '⚠️ Nenhum token salvo ainda.';
  }

  $('cfg-salvar-token').addEventListener('click', async () => {
    const campo = $('cfg-token');
    const token = campo.value.trim();
    if (!token) return BD.toast('Cole o token do bot.', 'erro');
    const botao = $('cfg-salvar-token');
    botao.disabled = true;
    const { error } = await db.rpc('salvar_token_bot', { p_token: token });
    botao.disabled = false;
    if (error) return BD.toast(BD.mensagemErro(error), 'erro');
    campo.value = '';
    BD.toast('Token salvo no cofre do Supabase.', 'ok');
    atualizarStatusBot();
  });

  document.querySelectorAll('[data-testar]').forEach((b) => b.addEventListener('click', async () => {
    const url = $(b.dataset.testar).value.trim();
    if (!REGEX_WEBHOOK.test(url)) return BD.toast('Cole uma URL de webhook do Discord válida.', 'erro');
    b.disabled = true;
    const { error } = await db.rpc('testar_webhook', { p_url: url });
    b.disabled = false;
    BD.toast(error ? BD.mensagemErro(error) : 'Mensagem de teste enviada. Confira o canal no Discord.', error ? 'erro' : 'ok');
  }));

  // ================================================================ início

  db.auth.onAuthStateChange((evento) => {
    if (evento === 'SIGNED_OUT') { painelIniciado = false; verificarAcesso(); }
  });
  verificarAcesso();
})();
