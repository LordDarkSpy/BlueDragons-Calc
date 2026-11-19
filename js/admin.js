(function () {
  const { db, esc, formatarValor } = BD;
  const $ = (id) => document.getElementById(id);

  if (!db) {
    BD.mostrarErroConfig($('principal'));
    return;
  }

  const cache = { vendedores: [], parcerias: [], produtos: [], perfis: [] };
  let semanaInicio = BD.inicioSemana(new Date());
  let relatorioAtual = null;
  let meuDiscordId = null;
  let meuPerfil = {};
  // O líder pode tudo; os outros, o que o perfil deles libera (o banco confere de novo em cada ação).
  const pode = (permissao) => BD.pode(meuPerfil, permissao);
  // Tudo o que um perfil pode liberar (mesma lista de _permissoes_validas no banco).
  const PERMISSOES = [
    { grupo: 'Páginas', itens: [
      { id: 'ver_calculadora', nome: '🧮 Calculadora (ver e simular)' },
      { id: 'registrar_venda', nome: '📝 Registrar vendas (vendedor)' },
      { id: 'ver_ranking', nome: '🏆 Ranking' },
      { id: 'ver_vendas', nome: '🧾 Vendas (página de vendas)' },
      { id: 'ver_painel', nome: '⚙️ Painel (entrar)' },
    ] },
    { grupo: 'Abas do painel', dica: 'Só valem com "Painel" marcado.', itens: [
      { id: 'ver_relatorio', nome: '📊 Relatório semanal' },
      { id: 'ver_usuarios', nome: '👤 Usuários' },
      { id: 'ver_parcerias', nome: '🤝 Parcerias' },
      { id: 'ver_produtos', nome: '📦 Produtos' },
      { id: 'ver_gestao', nome: '🛡️ Gestão (só ver)' },
    ] },
    { grupo: 'Ações', itens: [
      { id: 'editar_parcerias', nome: 'Cadastrar e editar parcerias' },
      { id: 'encerrar_parceria', nome: 'Encerrar / reativar parcerias' },
      { id: 'registrar_pagamento', nome: 'Registrar pagamentos' },
      { id: 'cancelar_venda', nome: 'Cancelar / reativar vendas' },
      { id: 'gerenciar_vendedores', nome: 'Cadastrar e editar usuários' },
      { id: 'gerenciar_produtos', nome: 'Cadastrar e editar produtos e preços' },
      { id: 'enviar_notificacoes', nome: '📢 Enviar notificações (aba Gestão)' },
    ] },
  ];
  // Permissão que cada aba exige (a do Discord é só do DEV).
  const ABA_PERMISSAO = { relatorio: 'ver_relatorio', vendedores: 'ver_usuarios', parcerias: 'ver_parcerias', produtos: 'ver_produtos', gestao: 'ver_gestao' };

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
    meuPerfil = perfil;
    BD.ajustarLinksTopo(perfil);
    if (!perfil.admin) {
      $("sem-permissao-id").value = perfil.discord_id || "";
      $("sem-permissao").hidden = false;
      return;
    }
    $("app").hidden = false;
    iniciarPainel();
    BD.novidades(perfil);
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
    vendedores: carregarVendedores,
    parcerias: carregarParcerias,
    produtos: carregarProdutos,
    config: carregarConfig,
    gestao: carregarGestao,
  };
  // Pode abrir a aba? (Discord e opções gerais: só o DEV, definido no banco)
  const podeAba = (nome) => (nome === 'config' ? !!meuPerfil.dev : pode(ABA_PERMISSAO[nome]));
  const abasLiberadas = () => Object.keys(carregadores).filter(podeAba);

  function abrirAba(nome) {
    if (!podeAba(nome)) nome = abasLiberadas()[0];
    if (!nome) return;
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
    // Mostra só o que a pessoa pode usar.
    document.querySelectorAll('[data-aba]').forEach((b) => { b.hidden = !podeAba(b.dataset.aba); });
    $('sem-abas').hidden = abasLiberadas().length > 0;
    document.querySelector('[data-novo="vendedor"]').hidden = !pode('gerenciar_vendedores');
    document.querySelector('[data-novo="produto"]').hidden = !pode('gerenciar_produtos');
    document.querySelector('[data-novo="parceria"]').hidden = !pode('editar_parcerias');
    $('relatorio-discord').hidden = !pode('ver_relatorio');
    await Promise.all([carregarListasBase(), carregarConfig()]);
    const salva = BD.lerSalvo('bluedragons-aba');
    abrirAba(carregadores[salva] ? salva : abasLiberadas()[0]);
  }

  async function carregarListasBase() {
    const [ve, pa, pr, pf] = await Promise.all([
      db.from('vendedores').select('id, nome, discord_id, admin, ativo, criado_em, nome_discord, no_servidor, nome_discord_em, cargos, avatar, id_pagamento, perfil_id').order('nome'),
      db.from('parcerias').select('*').order('nome'),
      db.from('produtos').select('*').order('ordem').order('nome'),
      db.from('perfis').select('*').order('ordem').order('nome'),
    ]);
    cache.vendedores = ve.data || [];
    cache.parcerias = pa.data || [];
    cache.produtos = pr.data || [];
    cache.perfis = pf.data || [];
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
          <td class="acao">${s.pendente > 0 && x.vendedor_id && pode('registrar_pagamento') ? `<button type="button" class="botao-sucesso botao-pequeno" data-pagar="${i}">💸 Pagar</button>` : ''}</td>
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
    pagamentoAtual.id_pagamento = x.id_pagamento || '';
    $('pagamento-id').textContent = x.id_pagamento || 'não cadastrado';
    $('pagamento-id').classList.toggle('sem-id', !x.id_pagamento);
    $('pagamento-copiar-id').hidden = !x.id_pagamento;
    $('pagamento-copiar-id').textContent = '📋 Copiar ID';
    $('pagamento-copiar').textContent = '📋 Copiar valor';
    $('pagamento-copiar').classList.remove('copiado');
    $('pagamento-observacao').value = '';
    $('pagamento-erro').hidden = true;
    $('pagamento-registrar').disabled = false;
    BD.abrirModal($('modal-pagamento'), $('pagamento-copiar'));
  });

  $('pagamento-copiar-id').addEventListener('click', () => {
    if (!pagamentoAtual || !pagamentoAtual.id_pagamento) return;
    BD.copiar(pagamentoAtual.id_pagamento)
      .then(() => { $('pagamento-copiar-id').textContent = '✅ ID copiado!'; })
      .catch(() => { $('pagamento-copiar-id').textContent = 'Anote o ID acima'; });
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
      ['Produto', 'Quantidade', 'Total', 'Craft usado'], ...r.por_produto.map((x) => [x.nome, x.quantidade, x.total, (x.craft || []).map((m) => `${m.quantidade} ${m.nome}`).join(' · ')]), [],
      ['Craft', 'Quantidade'], ...(r.craft || []).map((x) => [x.nome, x.quantidade]),
    ];
    baixarCSV(`relatorio-${r.inicio}.csv`, linhas);
  });

  // ================================================================ modal de edição genérico

  let aoSalvar = null;

  function campoHTML(c) {
    const id = `campo-${c.nome}`;
    const valor = c.valor ?? '';
    if (c.tipo === 'craft') {
      return `<div class="largura-total">
        <span class="rotulo">${esc(c.rotulo)}</span>
        <div id="${id}" class="editor-craft"></div>
        <button type="button" class="botao botao-pequeno" data-craft-adicionar>+ Adicionar material</button>
        <datalist id="lista-materiais">${(c.sugestoes || []).map((n) => `<option value="${esc(n)}"></option>`).join('')}</datalist>
        ${c.dica ? `<p class="dica">${esc(c.dica)}</p>` : ''}</div>`;
    }
    if (c.tipo === 'checkbox') {
      return `<label class="checkbox largura-total"><input id="${id}" type="checkbox" ${valor ? 'checked' : ''}> ${esc(c.rotulo)}</label>`;
    }
    if (c.tipo === 'select') {
      return `<div class="${c.largo ? 'largura-total' : ''}">
        <label class="rotulo" for="${id}">${esc(c.rotulo)} ${c.obrigatorio ? '<span class="obrigatorio">*</span>' : ''}</label>
        <select id="${id}" ${c.desativado ? 'disabled' : ''}>${c.opcoes.map((o) => `<option value="${esc(o.valor)}" ${String(o.valor) === String(valor) ? 'selected' : ''}>${esc(o.texto)}</option>`).join('')}</select>
        ${c.dica ? `<p class="dica">${esc(c.dica)}</p>` : ''}</div>`;
    }
    const entrada = c.tipo === 'textarea'
      ? `<textarea id="${id}" maxlength="${c.max || 300}" rows="3">${esc(valor)}</textarea>`
      : `<input id="${id}" type="${c.tipo || 'text'}" value="${esc(valor)}" ${c.sugestoes ? `list="lista-${c.nome}"` : ''} ${c.max ? `maxlength="${c.max}"` : ''} ${c.min !== undefined ? `min="${c.min}"` : ''} ${c.placeholder ? `placeholder="${esc(c.placeholder)}"` : ''} ${c.inputmode ? `inputmode="${c.inputmode}"` : ''} autocomplete="off">`;
    return `<div class="${c.largo ? 'largura-total' : ''}">
      <label class="rotulo" for="${id}">${esc(c.rotulo)} ${c.obrigatorio ? '<span class="obrigatorio">*</span>' : ''}</label>
      ${entrada}${c.sugestoes ? `<datalist id="lista-${c.nome}">${c.sugestoes.map((n) => `<option value="${esc(n)}"></option>`).join('')}</datalist>` : ''}${c.dica ? `<p class="dica">${esc(c.dica)}</p>` : ''}</div>`;
  }

  // ---- editor de craft: uma linha por material (escolher um existente ou digitar novo) + quantidade
  function adicionarLinhaCraft(caixa, m) {
    const linha = document.createElement('div');
    linha.className = 'linha-craft';
    linha.innerHTML = `<input type="text" class="craft-material" list="lista-materiais" maxlength="30" placeholder="Material (ex.: Ferro)" value="${esc((m && m.material) || '')}" autocomplete="off" aria-label="Material">
      <input type="number" class="craft-quantidade" min="1" max="9999" step="1" value="${esc(String((m && m.quantidade) || 1))}" aria-label="Quantidade por unidade">
      <button type="button" class="botao-perigo botao-pequeno" data-craft-remover aria-label="Remover material">×</button>`;
    caixa.appendChild(linha);
    return linha;
  }

  function lerCraft(caixa) {
    const conhecidos = materiaisConhecidos();
    const lista = [];
    caixa.querySelectorAll('.linha-craft').forEach((l) => {
      let material = l.querySelector('.craft-material').value.replace(/\s+/g, ' ').trim();
      if (!material) return;
      const qtd = Number(l.querySelector('.craft-quantidade').value);
      if (!Number.isInteger(qtd) || qtd < 1 || qtd > 9999) throw new Error(`A quantidade de "${material}" deve ser um número inteiro de 1 a 9999.`);
      const igual = conhecidos.find((x) => semAcento(x) === semAcento(material));
      if (igual) material = igual; // mantém a mesma escrita
      const ja = lista.find((x) => semAcento(x.material) === semAcento(material));
      if (ja) ja.quantidade += qtd; else lista.push({ material, quantidade: qtd });
    });
    return lista;
  }

  function materiaisConhecidos() {
    const mapa = new Map();
    cache.produtos.forEach((p) => (p.craft || []).forEach((m) => { const k = semAcento(m.material); if (!mapa.has(k)) mapa.set(k, m.material); }));
    return [...mapa.values()].sort((a, b) => a.localeCompare(b, 'pt-BR'));
  }

  function categoriasConhecidas() {
    const mapa = new Map();
    cache.produtos.forEach((p) => { const k = semAcento(p.categoria); if (p.categoria && !mapa.has(k)) mapa.set(k, p.categoria); });
    return [...mapa.values()].sort((a, b) => a.localeCompare(b, 'pt-BR'));
  }

  function textoCraft(lista) {
    return (lista || []).map((m) => `${m.quantidade} ${m.material}`).join(' · ');
  }

  $('edicao-campos').addEventListener('click', (e) => {
    if (e.target.closest('[data-craft-adicionar]')) {
      const caixa = $('edicao-campos').querySelector('.editor-craft');
      adicionarLinhaCraft(caixa).querySelector('input').focus();
      return;
    }
    const remover = e.target.closest('[data-craft-remover]');
    if (remover) remover.closest('.linha-craft').remove();
  });

  function abrirEdicao(titulo, campos, salvar) {
    $('edicao-titulo').textContent = titulo;
    $('edicao-campos').innerHTML = `<div class="grade-form">${campos.map(campoHTML).join('')}</div>`;
    $('edicao-erro').hidden = true;
    aoSalvar = async () => {
      const valores = {};
      campos.forEach((c) => {
        const el = $(`campo-${c.nome}`);
        valores[c.nome] = c.tipo === 'craft' ? lerCraft(el) : c.tipo === 'checkbox' ? el.checked : el.value.trim();
      });
      const faltando = campos.find((c) => c.obrigatorio && valores[c.nome] === '');
      if (faltando) throw new Error(`Preencha o campo "${faltando.rotulo}".`);
      await salvar(valores);
    };
    campos.filter((c) => c.tipo === 'craft').forEach((c) => {
      const lista = (c.valor || []).length ? c.valor : [{ material: '', quantidade: 1 }];
      lista.forEach((m) => adicionarLinhaCraft($(`campo-${c.nome}`), m));
    });
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
      container.innerHTML = '<p class="vazio">Nenhum usuário cadastrado. Clique em "+ Novo usuário".</p>';
      return;
    }
    container.innerHTML = `<table>
      <thead><tr><th>Nome no Discord</th><th>ID do Discord</th><th>ID para pagamento</th><th>Perfil</th><th>Status</th><th></th></tr></thead>
      <tbody>${cache.vendedores.map((v) => `
        <tr>
          <td><strong>${esc(nomeVendedor(v))}</strong>${v.nome_discord && v.nome_discord !== v.nome ? `<div class="dica">cadastro: ${esc(v.nome)}</div>` : ''}${!v.nome_discord ? '<div class="dica">nome do servidor ainda não buscado</div>' : ''}</td>
          <td><code>${esc(v.discord_id)}</code>${v.discord_id === meuDiscordId ? ' <span class="dica">(você)</span>' : ''}</td>
          <td>${v.id_pagamento ? `<code>${esc(v.id_pagamento)}</code>` : '<span class="dica">—</span>'}</td>
          <td>${perfisDoUsuario(v)}</td>
          <td>${etiquetaAtivo(v.ativo)}${v.no_servidor === false ? ' <span class="etiqueta inativo">Fora do servidor</span>' : ''}</td>
          <td class="acoes">${pode('gerenciar_vendedores') ? `<button type="button" class="botao botao-pequeno" data-editar-vendedor="${esc(v.id)}">Editar</button>` : ''}</td>
        </tr>`).join('')}
      </tbody></table>`;
  }

  // Perfis que um perfil pode dar: o líder dá qualquer um; os outros, só perfis com permissões que eles têm.
  function perfisQuePossoDar(atualId) {
    return cache.perfis.filter((p) => meuPerfil.lider || p.id === atualId || (p.permissoes || []).every((x) => pode(x)));
  }

  function editarVendedor(v) {
    const novo = !v;
    const padrao = cache.perfis.find((p) => semAcento(p.nome) === 'vendedor') || cache.perfis[0];
    v = v || { ativo: true, admin: false, perfil_id: padrao ? padrao.id : '' };
    const proprio = !novo && v.discord_id === meuDiscordId;
    abrirEdicao(novo ? "Novo usuário" : `Editar ${nomeVendedor(v)}`, [
      { nome: "nome", rotulo: "Nome (reserva)", valor: v.nome, obrigatorio: true, max: 40, largo: true,
        dica: "O site mostra o nome que a pessoa usa no servidor do Discord. Este nome só aparece enquanto o do Discord não for encontrado." },
      { nome: "discord_id", rotulo: "ID do Discord", valor: v.discord_id, obrigatorio: true, max: 20, inputmode: "numeric",
        dica: "É com ele que a pessoa entra no site. Discord: Configurações → Avançado → Modo desenvolvedor; botão direito no nome → Copiar ID do usuário." },
      { nome: "id_pagamento", rotulo: "ID para pagamento", valor: v.id_pagamento, max: 40,
        dica: "ID usado para receber a comissão. Aparece para quem for pagar, logo acima do valor." },
      { nome: "perfil_id", rotulo: "Perfil", tipo: "select", valor: v.perfil_id || '', largo: true, desativado: proprio && !meuPerfil.lider,
        opcoes: [{ valor: '', texto: '— sem perfil (só pelos cargos do Discord) —' },
          ...perfisQuePossoDar(v.perfil_id).map((p) => ({ valor: p.id, texto: p.nome }))],
        dica: proprio && !meuPerfil.lider ? "Você não pode mudar o seu próprio perfil." : "Define o que a pessoa vê e faz. Vendedor = calculadora + registrar vendas + ranking." },
      { nome: "ativo", rotulo: "Ativo (pode entrar no site)", tipo: "checkbox", valor: v.ativo },
      ...(meuPerfil.lider ? [{ nome: "admin", rotulo: "Administrador manual / líder (acessa tudo e gerencia os perfis)", tipo: "checkbox", valor: v.admin }] : []),
    ], async (val) => {
      if (!meuPerfil.lider) val.admin = !!v.admin; // só o líder mexe nisso
      if (val.nome.length < 2) throw new Error("O nome precisa ter pelo menos 2 letras.");
      if (!/^\d{17,20}$/.test(val.discord_id)) throw new Error("ID do Discord inválido: deve ter de 17 a 20 números.");
      const id = falhou(await db.rpc("salvar_vendedor", {
        p_id: novo ? null : v.id, p_nome: val.nome, p_discord_id: val.discord_id, p_ativo: val.ativo, p_admin: val.admin,
        p_perfil_id: val.perfil_id || null, p_id_pagamento: val.id_pagamento || null,
      }));
      await carregarVendedores();
      sincronizarNomes(id, true);
    });
  }

  // Cargos do servidor (para mostrar nomes e ligar aos perfis).
  let cargosServidor = [];

  async function carregarCargos() {
    const rc = await db.from('discord_cargos').select('id, nome, cor, posicao').order('posicao', { ascending: false });
    cargosServidor = rc.data || [];
  }

  // Perfil do cadastro + perfis que vêm dos cargos do Discord.
  function perfisDoUsuario(v) {
    const doCadastro = cache.perfis.find((p) => p.id === v.perfil_id);
    const porCargo = cache.perfis.filter((p) => p.id !== v.perfil_id && (p.cargos || []).some((c) => (v.cargos || []).includes(c)));
    const partes = [];
    if (v.admin) partes.push('<span class="etiqueta parceria">👑 Líder</span>');
    if (doCadastro) partes.push(`<span class="etiqueta">${esc(doCadastro.nome)}</span>`);
    porCargo.forEach((p) => partes.push(`<span class="etiqueta">${esc(p.nome)}</span>`));
    if (!partes.length) return '<span class="dica">sem perfil</span>';
    return partes.join(' ') + (porCargo.length ? `<div class="dica">pelo cargo: ${esc(porCargo.map((p) => p.nome).join(', '))}</div>` : '');
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

  const IMAGENS_PARCERIA = {
    img_localizacao: { arquivo: 'localizacao', titulo: 'Localização' },
    img_banner: { arquivo: 'tabela', titulo: 'Tabela de preços' },
    img_cores: { arquivo: 'cores', titulo: 'Cores da organização (carro / uniforme)' },
  };
  const TIPOS_IMAGEM = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/gif': 'gif' };
  const urlsAssinadas = {}; // caminho no Storage -> { url, expira }

  // Links temporários (1 h) para as imagens do bucket privado.
  async function urlsImagens(caminhos) {
    const agora = Date.now();
    const faltam = [...new Set(caminhos.filter(Boolean))].filter((c) => !urlsAssinadas[c] || urlsAssinadas[c].expira < agora);
    if (faltam.length) {
      const { data } = await db.storage.from('parcerias').createSignedUrls(faltam, 3600);
      (data || []).forEach((x) => { if (x.signedUrl && !x.error) urlsAssinadas[x.path] = { url: x.signedUrl, expira: agora + 50 * 60 * 1000 }; });
    }
    return (c) => (c && urlsAssinadas[c] ? urlsAssinadas[c].url : '');
  }

  function chipsProdutos(lista) {
    if (!(lista || []).length) return '<span class="dica">—</span>';
    return `<div class="chips">${lista.map((n) => `<span class="chip">${esc(n)}</span>`).join('')}</div>`;
  }

  // Todos os produtos já usados nas parcerias (grafia padrão), em ordem alfabética.
  function produtosConhecidos() {
    const mapa = new Map();
    cache.parcerias.forEach((p) => (p.produtos || []).forEach((n) => { const k = semAcento(n); if (!mapa.has(k)) mapa.set(k, n); }));
    return [...mapa.values()].sort((a, b) => a.localeCompare(b, 'pt-BR'));
  }

  const semAcento = (t) => String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

  function parceriasFiltradas() {
    const busca = semAcento($('parcerias-busca').value.trim());
    const produto = $('parcerias-produto').value;
    const status = $('parcerias-status').value;
    return cache.parcerias.filter((p) => {
      if (status === 'ativa' && !p.ativo) return false;
      if (status === 'encerrada' && p.ativo) return false;
      if (produto && !(p.produtos || []).some((n) => semAcento(n) === semAcento(produto))) return false;
      if (!busca) return true;
      // todas as palavras digitadas precisam aparecer (em qualquer ordem)
      const texto = semAcento(`${p.nome} ${p.responsavel || ''} ${p.feita_por_nome || ''} ${(p.produtos || []).join(' ')} ${p.observacoes || ''}`);
      return busca.split(/\s+/).every((palavra) => texto.includes(palavra));
    });
  }

  let semanaParcerias = {};

  async function carregarParcerias() {
    const container = $('parcerias-tabela');
    await carregarListasBase();
    const filtroProduto = $('parcerias-produto');
    const escolhido = filtroProduto.value;
    filtroProduto.innerHTML = '<option value="">Todos os produtos</option>'
      + produtosConhecidos().map((n) => `<option value="${esc(n)}">${esc(n)}</option>`).join('');
    filtroProduto.value = escolhido;
    if (filtroProduto.value !== escolhido) filtroProduto.value = '';
    // Total vendido por parceria na semana atual.
    const ini = BD.inicioSemana(new Date());
    const { data: sem } = await db.rpc('vendas_por_parceria', { p_inicio: BD.dataISO(ini), p_fim: BD.dataISO(BD.somarDias(ini, 6)) });
    semanaParcerias = Object.fromEntries((sem || []).map((x) => [x.parceria_id, x]));
    await renderizarParcerias();
  }

  async function renderizarParcerias() {
    const container = $('parcerias-tabela');
    $('parcerias-limpar').hidden = !$('parcerias-busca').value;
    if (!cache.parcerias.length) {
      $('parcerias-contagem').textContent = '';
      container.innerHTML = `<p class="vazio">Nenhuma parceria cadastrada.${pode('editar_parcerias') ? ' Clique em "+ Nova parceria".' : ''}</p>`;
      return;
    }
    const lista = parceriasFiltradas();
    const filtrando = $('parcerias-busca').value.trim() || $('parcerias-produto').value || $('parcerias-status').value;
    $('parcerias-contagem').textContent = filtrando
      ? `${lista.length} de ${cache.parcerias.length} parceria${cache.parcerias.length === 1 ? '' : 's'}`
      : `${cache.parcerias.length} parceria${cache.parcerias.length === 1 ? '' : 's'} · ${cache.parcerias.filter((p) => p.ativo).length} ativa${cache.parcerias.filter((p) => p.ativo).length === 1 ? '' : 's'}`;
    if (!lista.length) {
      container.innerHTML = '<p class="vazio">Nenhuma parceria encontrada com esse filtro.</p>';
      return;
    }
    container.innerHTML = `<table class="tabela-parcerias">
      <thead><tr><th>Parceria</th><th>Produtos</th><th>Feita por</th><th class="num">Semana</th><th>Status</th><th></th></tr></thead>
      <tbody>${lista.map((p) => {
        const sem = semanaParcerias[p.id];
        return `<tr class="${p.ativo ? '' : 'encerrada'}">
          <td>
            <div class="parceria-nome">
              <div><strong>${esc(p.nome)}</strong>${p.responsavel ? `<div class="dica">${esc(p.responsavel)}</div>` : ''}</div>
            </div>
          </td>
          <td>${chipsProdutos(p.produtos)}</td>
          <td>${esc(p.feita_por_nome || '—')}</td>
          <td class="num">${sem ? `${formatarValor(sem.total)}<div class="dica">${sem.quantidade} venda(s)</div>` : '—'}</td>
          <td>${p.ativo ? '<span class="etiqueta ativo">Ativa</span>' : `<span class="etiqueta inativo">Encerrada</span>${p.encerrada_em ? `<div class="dica">${esc(BD.dataBR(p.encerrada_em))}</div>` : ''}`}</td>
          <td class="acoes">
            <button type="button" class="botao-primario botao-pequeno" data-ver-parceria="${esc(p.id)}">👁️ Visualizar</button>
            ${pode('editar_parcerias') ? `<button type="button" class="botao botao-pequeno" data-editar-parceria="${esc(p.id)}">Editar</button>` : ''}
          </td>
        </tr>`;
      }).join('')}
      </tbody></table>`;
  }

  ['parcerias-busca', 'parcerias-produto', 'parcerias-status'].forEach((id) => $(id).addEventListener('input', renderizarParcerias));
  $('parcerias-limpar').addEventListener('click', () => { $('parcerias-busca').value = ''; renderizarParcerias(); $('parcerias-busca').focus(); });
  $('parcerias-busca').addEventListener('keydown', (e) => { if (e.key === 'Escape' && e.target.value) { e.stopPropagation(); e.target.value = ''; renderizarParcerias(); } });

  // ---------------------------------------------------------------- notificar alteração
  // Depois de mexer em produto ou parceria, o banco guarda o aviso como pendente e aqui a pessoa decide.
  let pendentesNotificar = [];

  async function perguntarNotificacao() {
    const { data, error } = await db.rpc('novidades_pendentes');
    if (error || !Array.isArray(data) || !data.length) return;
    pendentesNotificar = data;
    $('notificar-lista').innerHTML = data.map((n) => `
      <li class="novidade-${esc(n.tipo)}"><span class="novidade-icone" aria-hidden="true">${({ preco: '💲', produto: '📦', parceria: '🤝' })[n.tipo] || '🔔'}</span>
        <div><strong>${esc(n.titulo)}</strong>${n.descricao ? `<p>${esc(n.descricao)}</p>` : ''}</div></li>`).join('');
    $('notificar-mensagem').value = '';
    $('notificar-erro').hidden = true;
    $('notificar-sim').disabled = $('notificar-nao').disabled = false;
    BD.abrirModal($('modal-notificar'), $('notificar-sim'));
  }

  async function decidirNotificacao(notificar) {
    $('notificar-sim').disabled = $('notificar-nao').disabled = true;
    const { error } = await db.rpc('decidir_novidades', {
      p_ids: pendentesNotificar.map((n) => n.id), p_notificar: notificar, p_mensagem: $('notificar-mensagem').value.trim() || null,
    });
    if (error) {
      $('notificar-erro').textContent = BD.mensagemErro(error);
      $('notificar-erro').hidden = false;
      $('notificar-sim').disabled = $('notificar-nao').disabled = false;
      return;
    }
    BD.fecharModal($('modal-notificar'));
    if (notificar) BD.toast('Notificação enviada para todos.', 'ok');
  }

  $('notificar-sim').addEventListener('click', () => decidirNotificacao(true));
  $('notificar-nao').addEventListener('click', () => decidirNotificacao(false));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('modal-notificar').hidden && !$('notificar-nao').disabled) decidirNotificacao(false); });

  // Emojis dos produtos no Discord: atualiza logo depois de mudar um produto (sem travar a tela).
  function atualizarEmojis() {
    db.rpc('emojis_atualizar').then(() => {}, () => {});
  }

  // Fórum de parceiros no Discord: atualiza logo depois de mudar uma parceria (sem travar a tela).
  function atualizarForum() {
    db.rpc('forum_atualizar').then(() => {}, () => {});
  }

  // ---------------------------------------------------------------- cadastro

  let parceriaEditando = null;
  const imagensEscolhidas = {}; // campo -> File | 'remover'

  function montarCampoImagem(el, campo, url) {
    const info = IMAGENS_PARCERIA[campo];
    const atual = parceriaEditando && parceriaEditando[campo];
    el.innerHTML = `<span class="rotulo">${el.querySelector('.rotulo').innerHTML}</span>
      <div class="previa-imagem area-colar" tabindex="0" role="button" data-colar="${campo}"
           aria-label="${esc(info.titulo)}: clique aqui e cole um print com Ctrl+V, ou arraste uma imagem">
        ${atual && url(atual) ? `<img src="${esc(url(atual))}" alt="${esc(info.titulo)}">` : '<span class="dica">📋 Clique aqui e cole o print (Ctrl+V)<br>ou arraste a imagem</span>'}
      </div>
      <input type="file" accept="image/png,image/jpeg,image/webp,image/gif" data-imagem="${campo}">
      ${atual ? `<label class="checkbox"><input type="checkbox" data-remover="${campo}"> Remover imagem</label>` : ''}`;
  }

  // Guarda a imagem escolhida (arquivo, print colado ou arrastado) e mostra a prévia.
  function aplicarImagem(campo, f) {
    if (!f) return;
    if (!TIPOS_IMAGEM[f.type]) { BD.toast('Isso não é uma imagem PNG, JPG, WEBP ou GIF.', 'erro'); return; }
    imagensEscolhidas[campo] = f;
    const area = document.querySelector(`#form-parceria [data-colar="${campo}"]`);
    try { area.innerHTML = `<img src="${URL.createObjectURL(f)}" alt="">`; } catch (e) { area.innerHTML = '<span class="dica">✅ Imagem pronta para salvar</span>'; }
    area.classList.add('nova');
    const remover = document.querySelector(`#form-parceria [data-remover="${campo}"]`);
    if (remover) remover.checked = false;
  }

  function imagemDaAreaDeTransferencia(dados) {
    const itens = [...((dados && dados.items) || [])];
    const item = itens.find((i) => i.kind === 'file' && TIPOS_IMAGEM[i.type]);
    if (item) return item.getAsFile();
    return [...((dados && dados.files) || [])].find((f) => TIPOS_IMAGEM[f.type]) || null;
  }

  let ultimaAreaImagem = null;
  $('form-parceria').addEventListener('focusin', (e) => {
    const area = e.target.closest('[data-colar]');
    if (area) ultimaAreaImagem = area.dataset.colar;
  });
  $('form-parceria').addEventListener('click', (e) => {
    const area = e.target.closest('[data-colar]');
    if (area) { area.focus(); ultimaAreaImagem = area.dataset.colar; }
  });
  // Colar (Ctrl+V): vai para o quadro selecionado; sem quadro selecionado, para o primeiro vazio.
  document.addEventListener('paste', (e) => {
    if ($('modal-parceria').hidden) return;
    const f = imagemDaAreaDeTransferencia(e.clipboardData);
    if (!f) return; // texto: deixa colar normalmente nos campos
    e.preventDefault();
    const alvo = document.activeElement && document.activeElement.closest && document.activeElement.closest('[data-colar]');
    let campo = alvo ? alvo.dataset.colar : ultimaAreaImagem;
    if (!campo) campo = Object.keys(IMAGENS_PARCERIA).find((c) => !imagensEscolhidas[c] && !(parceriaEditando && parceriaEditando[c])) || 'img_localizacao';
    aplicarImagem(campo, f);
    BD.toast(`Print colado em "${IMAGENS_PARCERIA[campo].titulo}".`, 'ok');
  });
  $('form-parceria').addEventListener('dragover', (e) => { if (e.target.closest('[data-colar]')) { e.preventDefault(); e.target.closest('[data-colar]').classList.add('arrastando'); } });
  $('form-parceria').addEventListener('dragleave', (e) => { const a = e.target.closest('[data-colar]'); if (a) a.classList.remove('arrastando'); });
  $('form-parceria').addEventListener('drop', (e) => {
    const area = e.target.closest('[data-colar]');
    if (!area) return;
    e.preventDefault();
    area.classList.remove('arrastando');
    aplicarImagem(area.dataset.colar, imagemDaAreaDeTransferencia(e.dataTransfer));
  });

  // ---------------------------------------------------------------- produtos da organização (tags)

  let produtosEscolhidos = [];

  function desenharProdutos() {
    const caixa = $('parceria-produtos');
    caixa.querySelector('.tags').innerHTML = produtosEscolhidos.map((n, i) =>
      `<span class="chip tag">${esc(n)} <button type="button" data-tirar-produto="${i}" aria-label="Remover ${esc(n)}">×</button></span>`).join('');
  }

  function sugestoesProduto() {
    const entrada = $('parceria-produto-novo');
    const termo = semAcento(entrada.value.trim());
    const ja = new Set(produtosEscolhidos.map(semAcento));
    const lista = produtosConhecidos().filter((n) => !ja.has(semAcento(n)) && (!termo || semAcento(n).includes(termo))).slice(0, 8);
    const caixa = $('parceria-produto-sugestoes');
    const existeIgual = produtosConhecidos().some((n) => semAcento(n) === termo);
    caixa.innerHTML = lista.map((n) => `<button type="button" class="sugestao" data-sugestao="${esc(n)}">${esc(n)}</button>`).join('')
      + (termo && !existeIgual ? `<button type="button" class="sugestao nova" data-sugestao="${esc(entrada.value.trim())}">+ Adicionar "${esc(entrada.value.trim())}" (novo)</button>` : '');
    caixa.hidden = !caixa.innerHTML;
  }

  function adicionarProduto(texto) {
    let n = String(texto || '').replace(/\s+/g, ' ').trim();
    if (!n) return;
    if (n.length > 40) { BD.toast('O nome do produto pode ter no máximo 40 caracteres.', 'erro'); return; }
    // Se já existe em outra parceria, usa exatamente a mesma escrita.
    const igual = produtosConhecidos().find((x) => semAcento(x) === semAcento(n));
    if (igual) n = igual;
    if (!produtosEscolhidos.some((x) => semAcento(x) === semAcento(n))) produtosEscolhidos.push(n);
    $('parceria-produto-novo').value = '';
    desenharProdutos();
    sugestoesProduto();
    $('parceria-produto-novo').focus();
  }

  async function editarParceria(p) {
    parceriaEditando = p || null;
    Object.keys(imagensEscolhidas).forEach((k) => delete imagensEscolhidas[k]);
    $('parceria-titulo').textContent = p ? `Editar ${p.nome}` : 'Nova parceria';
    $('parceria-nome').value = p ? p.nome : '';
    $('parceria-responsavel').value = (p && p.responsavel) || '';
    $('parceria-observacoes').value = (p && p.observacoes) || '';
    const meuId = (cache.vendedores.find((v) => v.discord_id === meuDiscordId) || {}).id || '';
    $('parceria-feita-por').innerHTML = '<option value="">—</option>'
      + cache.vendedores.map((v) => `<option value="${esc(v.id)}">${esc(nomeVendedor(v))}${v.ativo ? '' : ' (inativo)'}</option>`).join('');
    $('parceria-feita-por').value = p ? (p.feita_por_id || '') : meuId;
    produtosEscolhidos = [...((p && p.produtos) || [])];
    $('parceria-produtos').innerHTML = `<div class="tags"></div>
      <div class="entrada-produto">
        <input id="parceria-produto-novo" type="text" maxlength="40" autocomplete="off" placeholder="Digite o produto e aperte Enter">
        <button type="button" class="botao botao-pequeno" id="parceria-produto-adicionar">Adicionar</button>
      </div>
      <div id="parceria-produto-sugestoes" class="sugestoes" hidden></div>`;
    desenharProdutos();
    ultimaAreaImagem = null;
    const url = await urlsImagens(p ? [p.img_localizacao, p.img_banner, p.img_cores] : []);
    document.querySelectorAll('#form-parceria .campo-imagem').forEach((el) => montarCampoImagem(el, el.dataset.campo, url));
    // Encerrar / reativar: só ao editar e só para quem tem a permissão.
    const situacao = $('parceria-situacao');
    situacao.hidden = !(p && pode('encerrar_parceria'));
    situacao.innerHTML = situacao.hidden ? '' : p.ativo
      ? `<p class="dica">Encerrar tira a parceria da calculadora. O cadastro e o histórico ficam guardados.</p>
         <button type="button" class="botao-perigo botao-bloco" data-encerrar-parceria="${esc(p.id)}">⛔ Encerrar parceria</button>`
      : `<p class="perfil-encerrada">Encerrada em ${esc(p.encerrada_em ? BD.dataHoraBR(p.encerrada_em) : '—')}${p.encerrada_por ? ' por ' + esc(p.encerrada_por) : ''}.<br>Motivo: ${esc(p.encerrada_motivo || '—')}</p>
         <button type="button" class="botao botao-bloco" data-reativar-parceria="${esc(p.id)}">✅ Reativar parceria</button>`;
    $('parceria-erro').hidden = true;
    $('parceria-salvar').disabled = false;
    BD.abrirModal($('modal-parceria'), $('parceria-nome'));
  }

  $('parceria-produtos').addEventListener('input', (e) => { if (e.target.id === 'parceria-produto-novo') sugestoesProduto(); });
  $('parceria-produtos').addEventListener('focusin', (e) => { if (e.target.id === 'parceria-produto-novo') sugestoesProduto(); });
  $('parceria-produtos').addEventListener('keydown', (e) => {
    if (e.target.id !== 'parceria-produto-novo') return;
    if (e.key === 'Enter' || e.key === ',') { e.preventDefault(); adicionarProduto(e.target.value); }
    if (e.key === 'Backspace' && !e.target.value && produtosEscolhidos.length) { produtosEscolhidos.pop(); desenharProdutos(); sugestoesProduto(); }
  });
  $('parceria-produtos').addEventListener('click', (e) => {
    const sug = e.target.closest('[data-sugestao]');
    if (sug) return adicionarProduto(sug.dataset.sugestao);
    if (e.target.id === 'parceria-produto-adicionar') return adicionarProduto($('parceria-produto-novo').value);
    const tirar = e.target.closest('[data-tirar-produto]');
    if (tirar) { produtosEscolhidos.splice(Number(tirar.dataset.tirarProduto), 1); desenharProdutos(); sugestoesProduto(); }
  });

  $('form-parceria').addEventListener('change', (e) => {
    const arquivo = e.target.closest('[data-imagem]');
    if (arquivo) {
      const f = arquivo.files[0];
      if (f) aplicarImagem(arquivo.dataset.imagem, f); else delete imagensEscolhidas[arquivo.dataset.imagem];
      return;
    }
    const remover = e.target.closest('[data-remover]');
    if (remover) {
      if (remover.checked) imagensEscolhidas[remover.dataset.remover] = 'remover';
      else delete imagensEscolhidas[remover.dataset.remover];
    }
  });

  $('form-parceria').addEventListener('submit', async (e) => {
    e.preventDefault();
    const erro = $('parceria-erro');
    const botao = $('parceria-salvar');
    erro.hidden = true;
    try {
      const nome = $('parceria-nome').value.trim();
      if (!nome) throw new Error('Preencha o nome da parceria.');
      for (const [campo, f] of Object.entries(imagensEscolhidas)) {
        if (f === 'remover') continue;
        if (!TIPOS_IMAGEM[f.type]) throw new Error(`${IMAGENS_PARCERIA[campo].titulo}: use uma imagem PNG, JPG, WEBP ou GIF.`);
        if (f.size > 5 * 1024 * 1024) throw new Error(`${IMAGENS_PARCERIA[campo].titulo}: a imagem pode ter no máximo 5 MB.`);
      }
      botao.disabled = true;
      const dados = {
        nome,
        responsavel: $('parceria-responsavel').value.trim() || null,
        observacoes: $('parceria-observacoes').value.trim() || null,
        feita_por_id: $('parceria-feita-por').value || null,
        produtos: (() => { const sobra = $('parceria-produto-novo').value.trim(); if (sobra) adicionarProduto(sobra); return produtosEscolhidos.slice(); })(),
      };
      let id = parceriaEditando && parceriaEditando.id;
      if (id) falhou(await db.from('parcerias').update(dados).eq('id', id));
      else id = falhou(await db.from('parcerias').insert(dados).select('id').single()).id;

      // Imagens: envia as novas, depois grava os caminhos e apaga as antigas.
      const imagens = {};
      const apagar = [];
      for (const [campo, f] of Object.entries(imagensEscolhidas)) {
        const antiga = parceriaEditando && parceriaEditando[campo];
        if (f === 'remover') {
          imagens[campo] = null;
        } else {
          const caminho = `${id}/${IMAGENS_PARCERIA[campo].arquivo}-${Date.now()}.${TIPOS_IMAGEM[f.type]}`;
          const { error } = await db.storage.from('parcerias').upload(caminho, f, { contentType: f.type, upsert: false });
          if (error) throw new Error(`Não consegui enviar "${IMAGENS_PARCERIA[campo].titulo}": ${BD.mensagemErro(error)}`);
          imagens[campo] = caminho;
        }
        if (antiga) apagar.push(antiga);
      }
      if (Object.keys(imagens).length) falhou(await db.from('parcerias').update(imagens).eq('id', id));
      if (apagar.length) await db.storage.from('parcerias').remove(apagar);

      BD.fecharModal($('modal-parceria'));
      BD.toast('Parceria salva.', 'ok');
      atualizarForum();
      perguntarNotificacao();
      await carregarParcerias();
    } catch (err) {
      erro.textContent = BD.mensagemErro(err);
      erro.hidden = false;
      botao.disabled = false;
      if (parceriaEditando === null) carregarParcerias(); // pode ter criado antes de falhar uma imagem
    }
  });

  $('parceria-cancelar').addEventListener('click', () => BD.fecharModal($('modal-parceria')));

  // ---------------------------------------------------------------- encerrar / reativar

  let encerrando = null;

  function abrirEncerrar(p) {
    encerrando = p;
    $('encerrar-nome').textContent = p.nome;
    $('encerrar-motivo').value = '';
    $('encerrar-erro').hidden = true;
    $('encerrar-confirmar').disabled = false;
    BD.abrirModal($('modal-encerrar'), $('encerrar-motivo'));
  }

  $('form-encerrar').addEventListener('submit', async (e) => {
    e.preventDefault();
    const motivo = $('encerrar-motivo').value.trim();
    const erro = $('encerrar-erro');
    if (motivo.length < 3) {
      erro.textContent = 'Informe o motivo do encerramento.';
      erro.hidden = false;
      $('encerrar-motivo').focus();
      return;
    }
    $('encerrar-confirmar').disabled = true;
    const { error } = await db.rpc('encerrar_parceria', { p_id: encerrando.id, p_motivo: motivo });
    if (error) {
      erro.textContent = BD.mensagemErro(error);
      erro.hidden = false;
      $('encerrar-confirmar').disabled = false;
      return;
    }
    BD.fecharModal($('modal-encerrar'));
    BD.fecharModal($('modal-parceria'));
    BD.toast('Parceria encerrada.', 'ok');
    atualizarForum();
    perguntarNotificacao();
    await carregarParcerias();
    if (!$('modal-perfil').hidden) verParceria(encerrando.id);
  });

  $('encerrar-cancelar').addEventListener('click', () => BD.fecharModal($('modal-encerrar')));

  async function reativarParceria(p) {
    const { error } = await db.rpc('reativar_parceria', { p_id: p.id });
    if (!error) BD.fecharModal($('modal-parceria'));
    BD.toast(error ? BD.mensagemErro(error) : 'Parceria reativada.', error ? 'erro' : 'ok');
    if (!error) { atualizarForum(); perguntarNotificacao(); }
    await carregarParcerias();
    if (!$('modal-perfil').hidden) verParceria(p.id);
  }

  // ---------------------------------------------------------------- perfil

  const ROTULO_HISTORICO = { criada: '🤝 Criada', editada: '✏️ Editada', encerrada: '⛔ Encerrada', reativada: '✅ Reativada' };

  async function verParceria(id) {
    const p = cache.parcerias.find((x) => x.id === id);
    if (!p) return;
    const conteudo = $('perfil-conteudo');
    conteudo.innerHTML = '<p class="carregando">Carregando…</p>';
    BD.abrirModal($('modal-perfil'), $('perfil-fechar'));
    const [{ data: perfil, error }, url] = await Promise.all([
      db.rpc('perfil_parceria', { p_id: id }),
      urlsImagens([p.img_banner, p.img_localizacao, p.img_cores]),
    ]);
    if (error) {
      conteudo.innerHTML = `<p class="status erro">${esc(BD.mensagemErro(error))}</p>`;
      return;
    }
    const imagem = (campo) => (p[campo] && url(p[campo])
      ? `<button type="button" class="perfil-imagem" data-ampliar="${esc(url(p[campo]))}" data-titulo="${esc(IMAGENS_PARCERIA[campo].titulo)}">
           <img src="${esc(url(p[campo]))}" alt="${esc(IMAGENS_PARCERIA[campo].titulo)}"><span>${esc(IMAGENS_PARCERIA[campo].titulo)}</span></button>`
      : '');
    const vendas = perfil.vendas || [];
    const historico = perfil.historico || [];
    conteudo.innerHTML = `
      <div class="perfil-cabecalho perfil-cabecalho-grande">
        <h2 id="perfil-nome">${esc(p.nome)}</h2>
        ${p.ativo ? '<span class="etiqueta ativo">Ativa</span>' : '<span class="etiqueta inativo">Encerrada</span>'}
      </div>
      ${p.ativo ? '' : `<div class="perfil-encerrada"><strong>Encerrada em ${esc(p.encerrada_em ? BD.dataHoraBR(p.encerrada_em) : '—')}</strong>
        ${p.encerrada_por ? ` por ${esc(p.encerrada_por)}` : ''}<p>Motivo: ${esc(p.encerrada_motivo || '—')}</p></div>`}
      <div class="perfil-acoes">
        ${pode('editar_parcerias') ? `<button type="button" class="botao botao-pequeno" data-editar-parceria="${esc(p.id)}">✏️ Editar</button>` : ''}
        ${pode('encerrar_parceria') ? (p.ativo
          ? `<button type="button" class="botao-perigo botao-pequeno" data-encerrar-parceria="${esc(p.id)}">⛔ Encerrar</button>`
          : `<button type="button" class="botao botao-pequeno" data-reativar-parceria="${esc(p.id)}">✅ Reativar</button>`) : ''}
      </div>
      <dl class="perfil-dados">
        <div><dt>Quem fez a parceria</dt><dd>${esc(p.feita_por_nome || '—')}</dd></div>
        <div><dt>Responsável / contato</dt><dd>${esc(p.responsavel || '—')}</dd></div>
        <div><dt>Cadastrada em</dt><dd>${esc(BD.dataHoraBR(p.criado_em))}</dd></div>
        <div class="largura-total"><dt>Produtos que vendem</dt><dd>${chipsProdutos(p.produtos)}</dd></div>
        ${p.observacoes ? `<div class="largura-total"><dt>Observações</dt><dd>${esc(p.observacoes)}</dd></div>` : ''}
      </dl>
      ${imagem('img_banner') || imagem('img_localizacao') || imagem('img_cores') ? `<div class="perfil-imagens">${imagem('img_banner')}${imagem('img_localizacao')}${imagem('img_cores')}</div>` : ''}
      <div class="kpis perfil-kpis">
        <div class="kpi"><span>Total comprado</span><strong>${formatarValor(perfil.total)}</strong></div>
        <div class="kpi"><span>Vendas</span><strong>${perfil.quantidade}</strong></div>
        <div class="kpi"><span>Primeira venda</span><strong class="kpi-data">${perfil.primeira_venda ? esc(BD.dataBR(perfil.primeira_venda)) : '—'}</strong></div>
        <div class="kpi"><span>Última venda</span><strong class="kpi-data">${perfil.ultima_venda ? esc(BD.dataBR(perfil.ultima_venda)) : '—'}</strong></div>
      </div>
      ${(perfil.por_produto || []).length ? `<h3>📦 O que mais compra</h3>${chipsQuantidade(perfil.por_produto)}` : ''}
      <h3>🧾 Histórico de vendas</h3>
      ${vendas.length ? `<div class="tabela-wrap"><table>
        <thead><tr><th>#</th><th>Data</th><th>Vendedor</th><th>Itens</th><th class="num">Total</th></tr></thead>
        <tbody>${vendas.map((v) => `<tr class="${v.cancelada ? 'cancelada' : ''}">
          <td>${v.numero}</td><td>${esc(BD.dataHoraBR(v.criado_em))}</td><td>${esc(v.vendedor_nome)}</td>
          <td class="dica">${esc(v.itens || '')}</td><td class="num">${formatarValor(v.total)}${v.cancelada ? ' <span class="etiqueta inativo">cancelada</span>' : ''}</td></tr>`).join('')}
        </tbody></table></div>` : '<p class="vazio">Nenhuma venda para esta parceria ainda.</p>'}
      <h3>🕓 Histórico da parceria</h3>
      <ol class="linha-tempo">${historico.map((h) => `
        <li class="evento-${esc(h.tipo)}"><strong>${ROTULO_HISTORICO[h.tipo] || esc(h.tipo)}</strong>
          <span class="dica">${esc(BD.dataHoraBR(h.criado_em))}${h.autor ? ' · ' + esc(h.autor) : ''}</span>
          ${h.descricao ? `<p>${esc(h.descricao)}</p>` : ''}</li>`).join('') || '<li class="dica">Sem registros.</li>'}</ol>`;
  }

  function chipsQuantidade(lista) {
    return `<div class="chips">${lista.map((x) => `<span class="chip">${BD.iconeProduto(x, 'chip-img')} ${esc(x.nome)} <strong>×${Number(x.quantidade).toLocaleString('pt-BR')}</strong></span>`).join('')}</div>`;
  }

  $('perfil-fechar').addEventListener('click', () => BD.fecharModal($('modal-perfil')));

  // Ver imagem grande.
  function ampliarImagem(src, titulo) {
    $('imagem-grande').src = src;
    $('imagem-grande').alt = titulo || '';
    $('imagem-titulo').textContent = titulo || '';
    BD.abrirModal($('modal-imagem'), $('imagem-fechar'));
  }
  $('imagem-fechar').addEventListener('click', () => BD.fecharModal($('modal-imagem')));
  $('modal-imagem').addEventListener('click', (e) => { if (e.target === $('modal-imagem')) BD.fecharModal($('modal-imagem')); });

  // Botões da tabela e do perfil.
  function acoesParceria(e) {
    const alvo = e.target.closest('[data-ver-parceria],[data-editar-parceria],[data-encerrar-parceria],[data-reativar-parceria],[data-ampliar]');
    if (!alvo) return;
    if (alvo.dataset.ampliar) return ampliarImagem(alvo.dataset.ampliar, alvo.dataset.titulo);
    const id = alvo.dataset.verParceria || alvo.dataset.editarParceria || alvo.dataset.encerrarParceria || alvo.dataset.reativarParceria;
    const p = cache.parcerias.find((x) => x.id === id);
    if (!p) return;
    if (alvo.dataset.verParceria) return verParceria(id);
    if (alvo.dataset.editarParceria) { BD.fecharModal($('modal-perfil')); return editarParceria(p); }
    if (alvo.dataset.encerrarParceria) return abrirEncerrar(p);
    if (alvo.dataset.reativarParceria) return reativarParceria(p);
  }
  $('parcerias-tabela').addEventListener('click', acoesParceria);
  $('parceria-situacao').addEventListener('click', acoesParceria);
  $('perfil-conteudo').addEventListener('click', acoesParceria);

  // Esc fecha a janela de cima.
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    const topo = ['modal-imagem', 'modal-encerrar', 'modal-parceria', 'modal-perfil'].find((id) => !$(id).hidden);
    if (topo) BD.fecharModal($(topo));
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
      <thead><tr><th>Ordem</th><th>Produto</th><th>Descrição</th><th>Categoria</th><th class="num">Parceria</th><th class="num">Pista</th><th>Craft / un.</th><th>Status</th><th></th></tr></thead>
      <tbody>${cache.produtos.map((p) => `
        <tr>
          <td>${p.ordem}</td>
          <td><span class="produto-tabela-icone">${BD.iconeProduto(p, 'produto-img-pequena')}</span> <strong>${esc(p.nome)}</strong></td>
          <td class="coluna-descricao">${p.serve_para ? esc(p.serve_para) : '<span class="dica">—</span>'}</td>
          <td>${esc(p.categoria)}</td>
          <td class="num">${formatarValor(p.preco_com_parceria)}</td>
          <td class="num">${formatarValor(p.preco_sem_parceria)}</td>
          <td class="dica">${esc(textoCraft(p.craft)) || '—'}</td>
          <td>${etiquetaAtivo(p.ativo)}</td>
          <td class="acoes">${pode('gerenciar_produtos') ? `
            <button type="button" class="botao botao-pequeno" data-editar-produto="${esc(p.id)}">Editar</button>
            <button type="button" class="botao-perigo botao-pequeno" data-excluir-produto="${esc(p.id)}">Excluir</button>` : ''}
          </td>
        </tr>`).join('')}
      </tbody></table>`;
  }

  function editarProduto(p) {
    const novo = !p;
    p = p || { icone: '📦', categoria: '', craft: [], ativo: true, ordem: (cache.produtos.length + 1) * 10 };
    abrirEdicao(novo ? 'Novo produto' : `Editar ${p.nome}`, [
      { nome: 'icone', rotulo: 'Ícone (emoji)', valor: p.icone, max: 8, dica: 'Usado no Discord e quando não há imagem.' },
      { nome: 'imagem', rotulo: 'Imagem', valor: p.imagem, max: 300, placeholder: 'img/produtos/serra.svg ou https://…', dica: 'Caminho no site ou link de uma imagem. Deixe vazio para usar o emoji.' },
      { nome: 'nome', rotulo: 'Nome', valor: p.nome, obrigatorio: true, max: 60 },
      { nome: 'categoria', rotulo: 'Categoria', valor: p.categoria, max: 30, placeholder: 'Escolha ou digite uma nova', sugestoes: categoriasConhecidas(),
        dica: 'Clique para ver as que já existem, ou digite uma nova.' },
      { nome: 'preco_sem_parceria', rotulo: 'Preço pista', tipo: 'number', min: 0, valor: p.preco_sem_parceria, obrigatorio: true },
      { nome: 'preco_com_parceria', rotulo: 'Preço parceria', tipo: 'number', min: 0, valor: p.preco_com_parceria, obrigatorio: true },
      { nome: 'ordem', rotulo: 'Ordem na lista', tipo: 'number', valor: p.ordem, dica: 'Menor aparece primeiro.' },
      { nome: 'craft', rotulo: 'Craft: materiais usados por unidade', tipo: 'craft', valor: p.craft, sugestoes: materiaisConhecidos(),
        dica: 'Ex.: 1 Ferro, 1 Plástico, 1 Vidro. Escolha um material da lista ou digite um novo.' },
      { nome: 'serve_para', rotulo: 'Descrição (serve para)', tipo: 'textarea', valor: p.serve_para, max: 300, largo: true,
        dica: 'Aparece na lista de produtos e na calculadora ao passar o mouse ou clicar na imagem do produto.' },
      { nome: 'ativo', rotulo: 'Ativo (aparece na calculadora)', tipo: 'checkbox', valor: p.ativo },
    ], async (val) => {
      const com = Number(val.preco_com_parceria);
      const sem = Number(val.preco_sem_parceria);
      if (!(com >= 0) || !(sem >= 0)) throw new Error('Os preços devem ser números maiores ou iguais a zero.');
      // categoria existente: mesma escrita
      const categoria = val.categoria.replace(/\s+/g, ' ').trim();
      const catIgual = categoriasConhecidas().find((x) => semAcento(x) === semAcento(categoria));
      const dados = {
        icone: val.icone || '📦', imagem: val.imagem || null, nome: val.nome, categoria: catIgual || categoria || 'Geral',
        preco_com_parceria: com, preco_sem_parceria: sem,
        craft: val.craft,
        serve_para: val.serve_para || null,
        ordem: parseInt(val.ordem, 10) || 0, ativo: val.ativo,
      };
      falhou(novo ? await db.from('produtos').insert(dados) : await db.from('produtos').update(dados).eq('id', p.id));
      carregarProdutos();
      atualizarEmojis();
      setTimeout(perguntarNotificacao, 0); // depois que o formulário fecha
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
    if (!error) { atualizarEmojis(); perguntarNotificacao(); }
  });

  document.querySelectorAll('[data-novo]').forEach((b) => b.addEventListener('click', () => {
    ({ vendedor: editarVendedor, parceria: editarParceria, produto: editarProduto })[b.dataset.novo]();
  }));

  // ================================================================ gestão: perfis (só o líder altera)

  let perfisOriginais = [];
  let novoPerfilSeq = 0;

  function corCargo(c) {
    return c.cor ? '#' + c.cor.toString(16).padStart(6, '0') : 'var(--texto-suave)';
  }

  function cartaoPerfil(p) {
    const usuarios = cache.vendedores.filter((v) => v.perfil_id === p.id).length;
    const marcadas = new Set(p.permissoes || []);
    const cargos = new Set(p.cargos || []);
    return `<fieldset class="perfil-card" data-perfil="${esc(p.id)}">
      <div class="perfil-topo">
        <input class="perfil-nome" type="text" maxlength="40" value="${esc(p.nome || '')}" placeholder="Nome do perfil" aria-label="Nome do perfil">
        <span class="dica">${usuarios} usuário${usuarios === 1 ? '' : 's'}</span>
        <button type="button" class="botao-perigo botao-pequeno" data-remover-perfil aria-label="Excluir perfil">Excluir</button>
      </div>
      <div class="perfil-grupos">${PERMISSOES.map((g) => `
        <div class="perfil-grupo">
          <strong>${esc(g.grupo)}</strong>${g.dica ? `<span class="dica">${esc(g.dica)}</span>` : ''}
          ${g.itens.map((i) => `<label class="checkbox"><input type="checkbox" data-permissao="${i.id}" ${marcadas.has(i.id) ? 'checked' : ''}> ${esc(i.nome)}</label>`).join('')}
        </div>`).join('')}
      </div>
      <details class="perfil-cargos" ${cargos.size ? 'open' : ''}>
        <summary>Cargos do Discord que dão este perfil <span class="dica">(${cargos.size} marcado${cargos.size === 1 ? '' : 's'})</span></summary>
        ${cargosServidor.length ? `<div class="lista-cargos">${cargosServidor.map((c) => `
          <label class="checkbox cargo-opcao"><input type="checkbox" data-cargo="${esc(c.id)}" ${cargos.has(c.id) ? 'checked' : ''}>
            <span class="cargo-cor" style="background:${corCargo(c)}"></span> ${esc(c.nome)}</label>`).join('')}</div>`
          : '<p class="dica">Nenhum cargo carregado. Clique em "Carregar cargos do servidor".</p>'}
      </details>
    </fieldset>`;
  }

  async function carregarGestao() {
    const el = $('perfis-lista');
    el.innerHTML = '<p class="carregando">Carregando…</p>';
    await Promise.all([carregarCargos(), carregarListasBase()]);
    perfisOriginais = JSON.parse(JSON.stringify(cache.perfis));
    el.innerHTML = cache.perfis.length ? cache.perfis.map(cartaoPerfil).join('') : '<p class="vazio">Nenhum perfil ainda. Clique em "+ Novo perfil".</p>';
    // Quem só vê a gestão (sem ser líder) não altera nada.
    const leitura = !meuPerfil.lider;
    $('gestao-somente-leitura').hidden = !leitura;
    $('aba-gestao').querySelectorAll('input, select, textarea').forEach((i) => { if (!i.closest('#form-notificacao')) i.disabled = leitura; });
    prepararNotificacao();
    ['permissoes-salvar', 'perfil-novo', 'cfg-carregar-cargos', 'cfg-simulado'].forEach((id) => { $(id).hidden = leitura; });
    el.querySelectorAll('[data-remover-perfil]').forEach((btn) => { btn.hidden = leitura; });
  }

  // ---------------------------------------------------------------- enviar notificação (geral, cargo ou usuário)
  function prepararNotificacao() {
    const form = $('form-notificacao');
    form.hidden = !pode('enviar_notificacoes');
    if (form.hidden) return;
    const cargo = $('notif-cargo').value;
    const usuario = $('notif-usuario').value;
    $('notif-cargo').innerHTML = cargosServidor.length
      ? cargosServidor.map((c) => `<option value="${esc(c.id)}">${esc(c.nome)}</option>`).join('')
      : '<option value="">Nenhum cargo carregado</option>';
    $('notif-usuario').innerHTML = cache.vendedores.filter((v) => v.ativo)
      .map((v) => ({ id: v.id, nome: v.nome_discord || v.nome }))
      .sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR'))
      .map((v) => `<option value="${esc(v.id)}">${esc(v.nome)}</option>`).join('');
    if (cargo) $('notif-cargo').value = cargo;
    if (usuario) $('notif-usuario').value = usuario;
    mostrarAlvoNotificacao();
  }

  function mostrarAlvoNotificacao() {
    const alvo = $('notif-alvo').value;
    $('notif-cargo-campo').hidden = alvo !== 'cargo';
    $('notif-usuario-campo').hidden = alvo !== 'usuario';
  }
  $('notif-alvo').addEventListener('change', mostrarAlvoNotificacao);

  $('form-notificacao').addEventListener('submit', async (e) => {
    e.preventDefault();
    const erro = $('notif-erro');
    const falha = (msg) => { erro.textContent = msg; erro.hidden = false; };
    erro.hidden = true;
    const alvo = $('notif-alvo').value;
    const destino = alvo === 'cargo' ? $('notif-cargo').value : alvo === 'usuario' ? $('notif-usuario').value : null;
    const titulo = $('notif-titulo').value.trim();
    if (titulo.length < 3) { $('notif-titulo').focus(); return falha('Escreva um título (3 letras ou mais).'); }
    if (alvo !== 'todos' && !destino) return falha(alvo === 'cargo' ? 'Escolha um cargo (carregue os cargos do servidor).' : 'Escolha um usuário.');
    const opcao = (sel) => sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].textContent : '';
    const para = alvo === 'todos' ? 'todos os usuários' : alvo === 'cargo' ? `quem tem o cargo "${opcao($('notif-cargo'))}"` : opcao($('notif-usuario'));
    if (!confirm(`Enviar a notificação "${titulo}" para ${para}?`)) return;
    $('notif-enviar').disabled = true;
    const { data, error } = await db.rpc('enviar_notificacao', {
      p_alvo: alvo, p_destino: destino, p_titulo: titulo, p_mensagem: $('notif-mensagem').value.trim() || null,
    });
    $('notif-enviar').disabled = false;
    if (error) return falha(BD.mensagemErro(error));
    $('notif-titulo').value = '';
    $('notif-mensagem').value = '';
    BD.toast(`Notificação enviada para ${para}${alvo === 'cargo' ? ` (${data} usuário${data === 1 ? '' : 's'} hoje)` : ''}.`, 'ok');
  });

  $('perfil-novo').addEventListener('click', () => {
    const el = $('perfis-lista');
    if (el.querySelector('.vazio')) el.innerHTML = '';
    el.insertAdjacentHTML('beforeend', cartaoPerfil({ id: `novo-${++novoPerfilSeq}`, nome: '', permissoes: ['ver_calculadora'], cargos: [] }));
    el.lastElementChild.querySelector('.perfil-nome').focus();
  });

  $('perfis-lista').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-remover-perfil]');
    if (!btn) return;
    const card = btn.closest('[data-perfil]');
    const id = card.dataset.perfil;
    const usuarios = cache.vendedores.filter((v) => v.perfil_id === id).length;
    if (usuarios && !confirm(`${usuarios} usuário(s) usam este perfil e ficarão sem perfil (só com o que os cargos derem). Excluir mesmo? (só vale ao salvar)`)) return;
    card.remove();
  });

  function lerPerfis() {
    return [...document.querySelectorAll('#perfis-lista [data-perfil]')].map((card) => ({
      id: card.dataset.perfil,
      nome: card.querySelector('.perfil-nome').value.replace(/\s+/g, ' ').trim(),
      permissoes: [...card.querySelectorAll('[data-permissao]:checked')].map((i) => i.dataset.permissao),
      cargos: [...card.querySelectorAll('[data-cargo]:checked')].map((i) => i.dataset.cargo),
    }));
  }

  $('permissoes-salvar').addEventListener('click', async () => {
    const pct = Number($('cfg-comissao').value);
    if (!(pct >= 0 && pct <= 100)) return BD.toast('A comissão deve ficar entre 0 e 100%.', 'erro');
    const perfis = lerPerfis();
    const semNome = perfis.find((p) => p.nome.length < 2);
    if (semNome) return BD.toast('Dê um nome (2 letras ou mais) a cada perfil.', 'erro');
    const nomes = perfis.map((p) => semAcento(p.nome));
    if (nomes.some((n, i) => nomes.indexOf(n) !== i)) return BD.toast('Há dois perfis com o mesmo nome.', 'erro');

    const botao = $('permissoes-salvar');
    botao.disabled = true;
    try {
      const mesmo = (x, y) => JSON.stringify([...(x || [])].sort()) === JSON.stringify([...(y || [])].sort());
      // Apagados, alterados e novos.
      const ficam = new Set(perfis.map((p) => p.id));
      for (const p of perfisOriginais.filter((o) => !ficam.has(o.id))) {
        falhou(await db.from('perfis').delete().eq('id', p.id));
      }
      for (const [i, p] of perfis.entries()) {
        const dados = { nome: p.nome, permissoes: p.permissoes, cargos: p.cargos, ordem: (i + 1) * 10 };
        if (p.id.startsWith('novo-')) {
          falhou(await db.from('perfis').insert(dados));
        } else {
          const o = perfisOriginais.find((x) => x.id === p.id);
          if (!o || o.nome !== p.nome || !mesmo(o.permissoes, p.permissoes) || !mesmo(o.cargos, p.cargos) || o.ordem !== dados.ordem) {
            falhou(await db.from('perfis').update(dados).eq('id', p.id));
          }
        }
      }
      falhou(await db.from('configuracoes').update({
        nome_organizacao: $('cfg-nome').value.trim() || 'Blue Dragons',
        moeda: $('cfg-moeda').value || 'R$ ',
        percentual_comissao: pct / 100,
        relatorio_automatico: $('cfg-automatico').checked,
        relatorio_dia: Number($('cfg-relatorio-dia').value),
        relatorio_hora: $('cfg-relatorio-hora').value || '09:00',
        atualizado_em: new Date().toISOString(),
      }).eq('id', 1));
      BD.moeda = $('cfg-moeda').value || 'R$ ';
      BD.toast('Gestão salva.', 'ok');
    } catch (erro) {
      BD.toast(BD.mensagemErro(erro), 'erro');
    } finally {
      botao.disabled = false;
      carregarGestao();
    }
  });

  $('cfg-carregar-cargos').addEventListener('click', async () => {
    await sincronizarNomes(null, false);
    carregarGestao();
  });

  // ================================================================ configurações / Discord (só DEV)

  const REGEX_WEBHOOK = /^https:\/\/(canary\.|ptb\.)?(discord|discordapp)\.com\/api\/webhooks\/\d+\/[\w-]+$/;
  // O bot entra como Administrador do servidor (cobre nomes, cargos e o fórum de parceiros).
  const PERMISSOES_BOT = '8';
  let configAtual = {};
  let statusBot = {};

  function linkConvite(servidor) {
    if (!statusBot.app_id) return '';
    return `https://discord.com/oauth2/authorize?client_id=${statusBot.app_id}&scope=bot&permissions=${PERMISSOES_BOT}`
      + (servidor ? `&guild_id=${servidor}&disable_guild_select=true` : '');
  }

  async function carregarConfig() {
    const { data, error } = await db.from('configuracoes').select('*').eq('id', 1).single();
    if (error) return BD.toast(BD.mensagemErro(error), 'erro');
    configAtual = data;
    $('cfg-webhook-vendas').value = data.webhook_vendas || '';
    $('cfg-webhook-relatorios').value = data.webhook_relatorios || '';
    $('cfg-webhook-pagamentos').value = data.webhook_pagamentos || '';
    $('cfg-notificar').checked = data.notificar_vendas;
    $('cfg-automatico').checked = data.relatorio_automatico;
    $('cfg-relatorio-dia').value = String(data.relatorio_dia || 1);
    $('cfg-relatorio-hora').value = String(data.relatorio_hora || '09:00').slice(0, 5);
    $('cfg-site-url').value = data.site_url || '';
    $('cfg-categoria').value = data.discord_categoria_parceiros || '';
    $('cfg-nome').value = data.nome_organizacao;
    $('cfg-moeda').value = data.moeda;
    $('cfg-comissao').value = Math.round(Number(data.percentual_comissao) * 1000) / 10;
    $('cfg-servidor').value = data.discord_servidor_id || '';
    if (meuPerfil.dev) { atualizarStatusBot().then(carregarAparenciaBot); atualizarStatusForum(); }
    BD.moeda = data.moeda || BD.moeda;
  }

  $('form-config').addEventListener('submit', async (e) => {
    e.preventDefault();
    const vendas = $('cfg-webhook-vendas').value.trim();
    const relatorios = $('cfg-webhook-relatorios').value.trim();
    const pagamentos = $('cfg-webhook-pagamentos').value.trim();
    for (const url of [vendas, relatorios, pagamentos]) {
      if (url && !REGEX_WEBHOOK.test(url)) return BD.toast('URL de webhook do Discord inválida.', 'erro');
    }
    const categoria = $('cfg-categoria').value.trim();
    if (categoria && !/^\d{17,20}$/.test(categoria)) return BD.toast('ID da categoria inválido: deve ter de 17 a 20 números.', 'erro');
    let site = $('cfg-site-url').value.trim() || 'https://lorddarkspy.github.io/BlueDragons-Calc/';
    if (!/^https:\/\//.test(site)) return BD.toast('O endereço do site precisa começar com https://', 'erro');
    if (!site.endsWith('/')) site += '/';
    const botao = $('cfg-salvar');
    botao.disabled = true;
    const { error } = await db.from('configuracoes').update({
      webhook_vendas: vendas || null,
      webhook_relatorios: relatorios || null,
      webhook_pagamentos: pagamentos || null,
      notificar_vendas: $('cfg-notificar').checked,
      site_url: site,
      discord_categoria_parceiros: categoria || null,
      atualizado_em: new Date().toISOString(),
    }).eq('id', 1);
    botao.disabled = false;
    BD.toast(error ? BD.mensagemErro(error) : 'Configurações salvas.', error ? 'erro' : 'ok');
    if (!error) {
      const mudouCategoria = (categoria || null) !== (configAtual.discord_categoria_parceiros || null);
      await carregarConfig();
      if (mudouCategoria && categoria) sincronizarForum();
    }
  });

  async function atualizarStatusBot() {
    const { data, error } = await db.rpc('discord_status');
    const el = $('cfg-bot-status');
    if (error) { el.textContent = BD.mensagemErro(error); return; }
    statusBot = data || {};
    el.textContent = data.bot_configurado ? '✅ Token do bot salvo. Para trocar, cole um novo token.' : '⚠️ Nenhum token salvo ainda.';
    const link = linkConvite(configAtual.discord_servidor_id);
    $('cfg-convite').hidden = !link;
    $('cfg-convite-link').href = link || '#';
  }

  // ---------------------------------------------------------------- aparência do bot no servidor

  let fotoBot = null; // data:image/… escolhida e ainda não aplicada

  function mostrarAparenciaBot(a) {
    $('bot-foto').src = a.foto_servidor || a.foto_padrao;
    $('bot-nome').value = a.apelido || '';
    $('bot-nome').placeholder = a.usuario || 'Nome do bot';
    $('bot-status').textContent = `Aparece como ${a.apelido || a.usuario}` + (a.foto_servidor ? ' · foto própria do servidor' : ' · foto padrão do bot');
  }

  async function carregarAparenciaBot() {
    if (!configAtual.discord_servidor_id || !statusBot.bot_configurado) {
      $('bot-status').textContent = 'Salve o token do bot e configure o servidor primeiro.';
      return;
    }
    const { data, error } = await db.rpc('bot_aparencia');
    if (error) { $('bot-status').textContent = '⚠️ ' + BD.mensagemErro(error); return; }
    mostrarAparenciaBot(data);
  }

  // Recorta em quadrado e reduz para 512×512 (o Discord aceita até 10 MB, mas a imagem passa pelo banco).
  function prepararFotoBot(arquivo) {
    return new Promise((ok, erro) => {
      if (arquivo.type === 'image/gif' && arquivo.size <= 1000000) {
        const r = new FileReader();
        r.onload = () => ok(r.result); // GIF pequeno vai como está, para manter a animação
        r.onerror = () => erro(new Error('Não deu para ler a imagem.'));
        r.readAsDataURL(arquivo);
        return;
      }
      const img = new Image();
      const url = URL.createObjectURL(arquivo);
      img.onload = () => {
        URL.revokeObjectURL(url);
        const lado = Math.min(img.naturalWidth, img.naturalHeight);
        const c = document.createElement('canvas');
        c.width = c.height = Math.min(512, lado);
        c.getContext('2d').drawImage(img, (img.naturalWidth - lado) / 2, (img.naturalHeight - lado) / 2, lado, lado, 0, 0, c.width, c.height);
        let dados = c.toDataURL('image/png');
        if (dados.length > 1300000) dados = c.toDataURL('image/jpeg', 0.9);
        ok(dados);
      };
      img.onerror = () => { URL.revokeObjectURL(url); erro(new Error('Não deu para abrir a imagem.')); };
      img.src = url;
    });
  }

  $('bot-foto-arquivo').addEventListener('change', async (e) => {
    const arquivo = e.target.files[0];
    fotoBot = null;
    if (!arquivo) return;
    try {
      fotoBot = await prepararFotoBot(arquivo);
      $('bot-foto').src = fotoBot;
      $('bot-foto-remover').checked = false;
      $('bot-status').textContent = 'Prévia da foto nova. Clique em Aplicar no servidor.';
    } catch (err) {
      e.target.value = '';
      BD.toast(err.message, 'erro');
    }
  });

  $('bot-foto-remover').addEventListener('change', (e) => {
    if (e.target.checked) { fotoBot = null; $('bot-foto-arquivo').value = ''; }
  });

  $('bot-aplicar').addEventListener('click', async () => {
    const botao = $('bot-aplicar');
    botao.disabled = true;
    const { data, error } = await db.rpc('bot_aparencia_salvar', {
      p_nome: $('bot-nome').value.trim(),
      p_foto: fotoBot,
      p_remover_foto: $('bot-foto-remover').checked,
    });
    botao.disabled = false;
    if (error) return BD.toast(BD.mensagemErro(error), 'erro');
    fotoBot = null;
    $('bot-foto-arquivo').value = '';
    $('bot-foto-remover').checked = false;
    mostrarAparenciaBot(data);
    BD.toast('Aparência do bot atualizada no servidor.', 'ok');
  });

  $('cfg-convite-copiar').addEventListener('click', () => {
    const link = linkConvite(configAtual.discord_servidor_id);
    if (link) BD.copiar(link).then(() => BD.toast('Convite do bot copiado.', 'ok'));
  });

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

  $('cfg-simulado').addEventListener('click', async () => {
    const botao = $('cfg-simulado');
    botao.disabled = true;
    const { error } = await db.rpc('enviar_relatorio_simulado');
    botao.disabled = false;
    BD.toast(error ? BD.mensagemErro(error) : '🧪 Relatório simulado enviado. Confira o canal de relatórios no Discord.', error ? 'erro' : 'ok');
  });

  // ---------------------------------------------------------------- fórum de parceiros

  function mostrarStatusForum(s) {
    const el = $('cfg-forum-status');
    const lista = $('cfg-forum-lista');
    if (!s || !s.ativo) {
      el.textContent = configAtual.discord_categoria_parceiros ? '⚠️ Salve o token do bot para ativar.' : 'Desligado (sem categoria).';
      lista.innerHTML = '';
      return;
    }
    if (s.ocupado) { el.textContent = '⏳ Já está sincronizando, tente em instantes.'; return; }
    const foruns = s.foruns || [];
    el.textContent = s.erro
      ? `⚠️ ${s.erro}`
      : `✅ ${foruns.length} fórum(ns), ${foruns.reduce((n, x) => n + Number(x.posts), 0)} post(s)`
        + (s.faltam ? ` · ${s.faltam} para publicar` : '')
        + (s.ok_em ? ` · última sincronização ${BD.dataHoraBR(s.ok_em)}` : '');
    lista.innerHTML = foruns.map((x) => `<span class="chip"># ${esc(x.nome)} <strong>${esc(String(x.posts))}</strong></span>`).join('');
    if (s.emojis !== undefined) {
      el.textContent += ` · 😀 ${s.emojis} emoji(s) de produto` + (s.emojis_faltam ? ` (${s.emojis_faltam} para criar)` : '');
      if (s.erro_emoji) el.textContent += ` · ⚠️ ${s.erro_emoji}`;
    }
  }

  async function atualizarStatusForum() {
    const { data, error } = await db.rpc('forum_status');
    if (error) { $('cfg-forum-status').textContent = BD.mensagemErro(error); return; }
    mostrarStatusForum(data);
  }

  async function sincronizarForum() {
    const botao = $('cfg-forum-sincronizar');
    botao.disabled = true;
    $('cfg-forum-status').textContent = '⏳ Sincronizando com o Discord…';
    const { data, error } = await db.rpc('forum_sincronizar_agora');
    botao.disabled = false;
    if (error) { $('cfg-forum-status').textContent = BD.mensagemErro(error); return; }
    mostrarStatusForum(data);
    if (data && data.ativo && !data.erro && data.faltam) BD.toast('Parte dos posts fica para o próximo minuto (o Discord limita as chamadas).', 'ok');
  }

  $('cfg-forum-sincronizar').addEventListener('click', () => {
    if (($('cfg-categoria').value.trim() || null) !== (configAtual.discord_categoria_parceiros || null)) {
      return BD.toast('Salve as configurações antes (a categoria mudou).', 'erro');
    }
    sincronizarForum();
  });

  // ---------------------------------------------------------------- trocar de servidor (com confirmação)

  function fecharModalServidor() { BD.fecharModal($('modal-servidor')); }

  $('cfg-trocar-servidor').addEventListener('click', () => {
    $('servidor-atual').textContent = configAtual.discord_servidor_id || 'nenhum';
    $('servidor-novo').value = '';
    $('servidor-confirmo').checked = false;
    $('servidor-erro').hidden = true;
    $('servidor-confirmar').disabled = false;
    $('servidor-passo-1').hidden = false;
    $('servidor-passo-2').hidden = true;
    BD.abrirModal($('modal-servidor'), $('servidor-novo'));
  });

  $('form-servidor').addEventListener('submit', async (e) => {
    e.preventDefault();
    const erro = $('servidor-erro');
    const novoId = $('servidor-novo').value.trim();
    const falha = (msg) => { erro.textContent = msg; erro.hidden = false; };
    if (!/^\d{17,20}$/.test(novoId)) return falha('ID do servidor inválido: deve ter de 17 a 20 números.');
    if (novoId === configAtual.discord_servidor_id) return falha('Esse já é o servidor atual.');
    if (!$('servidor-confirmo').checked) return falha('Marque "Entendi e quero trocar de servidor" para confirmar.');
    $('servidor-confirmar').disabled = true;
    const { error } = await db.from('configuracoes').update({ discord_servidor_id: novoId, atualizado_em: new Date().toISOString() }).eq('id', 1);
    if (error) { $('servidor-confirmar').disabled = false; return falha(BD.mensagemErro(error)); }
    await carregarConfig();
    await atualizarStatusBot();
    const link = linkConvite(novoId);
    $('servidor-convite').hidden = !link;
    $('servidor-convite').href = link || '#';
    $('servidor-convite-copiar').hidden = !link;
    $('servidor-sem-token').hidden = !!link;
    $('servidor-passo-1').hidden = true;
    $('servidor-passo-2').hidden = false;
    BD.toast('Servidor do Discord trocado.', 'ok');
  });

  $('servidor-convite-copiar').addEventListener('click', () => {
    const link = linkConvite(configAtual.discord_servidor_id);
    if (link) BD.copiar(link).then(() => { $('servidor-convite-copiar').textContent = '✅ Convite copiado!'; });
  });
  $('modal-servidor').addEventListener('click', (e) => {
    if (e.target === $('modal-servidor') || e.target.closest('[data-fechar-servidor]')) fecharModalServidor();
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('modal-servidor').hidden) fecharModalServidor(); });

  // ================================================================ início

  db.auth.onAuthStateChange((evento) => {
    if (evento === 'SIGNED_OUT') { painelIniciado = false; verificarAcesso(); }
  });
  verificarAcesso();
})();
