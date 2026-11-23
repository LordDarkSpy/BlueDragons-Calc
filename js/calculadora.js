(function () {
  const { db, esc, formatarValor } = BD;
  const $ = (id) => document.getElementById(id);

  const els = {
    principal: $('principal'),
    listaItens: $('lista-itens'),
    resumoLista: $('resumo-lista'),
    resumoTipo: $('resumo-tipo'),
    total: $('total-valor'),
    radios: document.querySelectorAll('input[name="parceria"]'),
    campoParceria: $('campo-parceria'),
    selectParceria: $('select-parceria'),
    semParcerias: $('sem-parcerias'),
    observacao: $('observacao'),
    cliente: $('cliente'),
    registrar: $('registrar'),
    status: $('status'),
    campoCliente: $('campo-cliente'),
    modoVisualizacao: $('modo-visualizacao'),
    limpar: $('limpar'),
    vendedorNome: $('vendedor-nome'),
    trocarVendedor: $('trocar-vendedor'),
    minhaSemana: $('minha-semana'),
    modalVendedor: $('modal-vendedor'),
    erroVendedor: $('modal-vendedor-erro'),
    sucessoDetalhe: $('sucesso-detalhe'),
    sucessoCopiar: $('sucesso-copiar'),
    sucessoOk: $('sucesso-ok'),
  };

  if (!db) {
    BD.mostrarErroConfig(els.principal);
    els.principal.classList.add('largo');
    return;
  }

  let produtos = [];
  let parcerias = [];
  let sessao = null; // { id, nome, registra } do usuário logado
  let comParceria = false;
  let totalAtual = 0;
  let totalSucesso = 0;
  const quantidades = {};

  // ---------------------------------------------------------------- sessão (Discord)

  function definirSessao(nova) {
    sessao = nova;
    els.vendedorNome.textContent = nova ? nova.nome : "—";
    els.trocarVendedor.textContent = nova ? "Sair" : "Entrar";
    // Perfil que só visualiza: simula os valores, mas não registra.
    const registra = !nova || nova.registra;
    els.modoVisualizacao.hidden = registra;
    [els.registrar, els.observacao, els.observacao.previousElementSibling].forEach((el) => { el.hidden = !registra; });
    if (nova && nova.registra) atualizarMinhaSemana();
    else els.minhaSemana.hidden = true;
  }

  // Sem a permissão da calculadora: mostra só o aviso (e os links que o perfil pode abrir).
  function mostrarSemCalculadora(sem) {
    $('sem-calculadora').hidden = !sem;
    document.querySelectorAll('.coluna-principal, .coluna-lateral').forEach((el) => { el.hidden = sem; });
    els.principal.classList.toggle('largo', sem);
  }

  function mostrarErroVendedor(texto) {
    els.erroVendedor.textContent = texto;
    els.erroVendedor.hidden = !texto;
  }

  // Sem cadastro: formulário do pedido, aguardando aprovação (confere sozinho a cada 30 s) ou cadastro desativado.
  let timerAguardando = null;
  function abrirModalVendedor(perfil, editarPedido) {
    clearInterval(timerAguardando);
    timerAguardando = null;
    // Sessão anônima ainda sem código válido (sem ID do Discord): mostra o login de novo.
    const naoCadastrado = !!(perfil && !perfil.cadastrado && perfil.discord_id);
    $("login-codigo-bloco").hidden = true;
    $("login-entrar-bloco").hidden = naoCadastrado;
    $("login-nao-cadastrado").hidden = !naoCadastrado;
    $("modal-vendedor-titulo").textContent = naoCadastrado ? (perfil.desativado ? "Acesso desativado" : "Solicitar cadastro") : "Identifique-se";
    if (!naoCadastrado) return BD.abrirModal(els.modalVendedor, $("entrar-discord"));

    const pedido = perfil.solicitacao;
    const aguardando = !perfil.desativado && pedido && pedido.status === "pendente" && !editarPedido;
    const formulario = !perfil.desativado && !aguardando;
    $("login-desativado").hidden = !perfil.desativado;
    $("solicitar-aguardando").hidden = !aguardando;
    $("form-solicitar").hidden = !formulario;
    $("meu-discord-id").value = perfil.discord_id || "";
    if (aguardando) {
      $("solicitar-quando").textContent = pedido.criado_em ? ` em ${BD.dataHoraBR(pedido.criado_em)}` : "";
      timerAguardando = setInterval(() => { if (!document.hidden) verificarLogin(); }, 30000);
    }
    if (formulario) {
      const recusado = pedido && pedido.status === "recusada";
      $("solicitar-recusado").hidden = !recusado;
      $("solicitar-recusado").textContent = recusado ? `Seu pedido anterior foi recusado: ${pedido.motivo || "sem motivo informado"}. Você pode pedir de novo.` : "";
      if (!$("solicitar-nome").value) $("solicitar-nome").value = ((pedido && pedido.nome) || perfil.apelido || "").slice(0, 40);
      if (!$("solicitar-pagamento").value) $("solicitar-pagamento").value = (pedido && pedido.id_pagamento) || "";
      if (!$("solicitar-mensagem").value) $("solicitar-mensagem").value = (pedido && pedido.mensagem) || "";
      $("solicitar-enviar").textContent = pedido && pedido.status === "pendente" ? "💾 Salvar pedido" : "📨 Solicitar cadastro";
    }
    BD.abrirModal(els.modalVendedor, perfil.desativado ? $("copiar-discord-id") : aguardando ? $("tentar-novamente") : $("solicitar-nome"));
  }

  $("form-solicitar").addEventListener("submit", async (e) => {
    e.preventDefault();
    const nome = $("solicitar-nome").value.trim();
    const pagamento = $("solicitar-pagamento").value.trim();
    if (nome.length < 2) { mostrarErroVendedor("Informe o seu nome (2 letras ou mais)."); return $("solicitar-nome").focus(); }
    if (!pagamento) { mostrarErroVendedor("Informe o seu ID para pagamento."); return $("solicitar-pagamento").focus(); }
    const botao = $("solicitar-enviar");
    botao.disabled = true;
    const { error } = await db.rpc("solicitar_cadastro", {
      p_nome: nome, p_id_pagamento: pagamento, p_mensagem: $("solicitar-mensagem").value.trim() || null,
    });
    botao.disabled = false;
    if (error) return mostrarErroVendedor(BD.mensagemErro(error));
    mostrarErroVendedor("");
    BD.toast("Pedido de cadastro enviado.", "ok");
    verificarLogin();
  });
  $("solicitar-editar").addEventListener("click", () => abrirModalVendedor(perfilLogado, true));

  // ---------------------------------------------------------------- entrar com código (sem Discord)

  $("usar-codigo").addEventListener("click", () => {
    mostrarErroVendedor("");
    $("login-entrar-bloco").hidden = true;
    $("login-codigo-bloco").hidden = false;
    $("modal-vendedor-titulo").textContent = "Entrar com código";
    $("codigo-acesso").focus();
  });
  $("codigo-voltar").addEventListener("click", () => {
    mostrarErroVendedor("");
    $("login-codigo-bloco").hidden = true;
    $("login-entrar-bloco").hidden = false;
    $("modal-vendedor-titulo").textContent = "Identifique-se";
  });
  let entrandoComCodigo = false; // a sessão anônima é criada antes de conferir o código
  $("login-codigo-bloco").addEventListener("submit", async (e) => {
    e.preventDefault();
    const codigo = $("codigo-acesso").value.replace(/[^A-Za-z0-9]/g, "").toUpperCase();
    if (codigo.length !== 8) { mostrarErroVendedor("O código tem 8 letras e números (ex.: K7QM-3XPA)."); return $("codigo-acesso").focus(); }
    const botao = $("codigo-entrar");
    botao.disabled = true;
    botao.textContent = "⏳ Conferindo…";
    entrandoComCodigo = true;
    try {
      // O código precisa de uma sessão: cria uma anônima (se já houver uma, reaproveita).
      const { data: { session } } = await db.auth.getSession();
      if (!session) {
        const { error } = await db.auth.signInAnonymously();
        if (error) throw /anonymous/i.test(error.message) ? new Error("O acesso por código ainda não foi ativado no Supabase (login anônimo). Avise a liderança.") : error;
      }
      const { data, error } = await db.rpc("resgatar_codigo_acesso", { p_codigo: codigo });
      if (error) throw error;
      if (!data.ok) throw new Error(data.erro);
      $("codigo-acesso").value = "";
      mostrarErroVendedor("");
      BD.toast(`Bem-vindo(a), ${data.nome}!`, "ok");
      await verificarLogin();
    } catch (erro) {
      mostrarErroVendedor(BD.mensagemErro(erro));
    } finally {
      botao.disabled = false;
      botao.textContent = "Entrar com o código";
      entrandoComCodigo = false;
    }
  });

  async function verificarLogin() {
    let perfil;
    try {
      perfil = await BD.perfil();
    } catch (erro) {
      definirSessao(null);
      abrirModalVendedor(null);
      return mostrarErroVendedor(BD.mensagemErro(erro));
    }
    BD.ajustarLinksTopo(perfil);
    perfilLogado = perfil;
    if (perfil && perfil.cadastrado) {
      clearInterval(timerAguardando);
      mostrarSemCalculadora(!BD.pode(perfil, "ver_calculadora"));
      definirSessao({ id: perfil.id, nome: perfil.nome, registra: BD.pode(perfil, "registrar_venda") });
      mostrarErroVendedor("");
      BD.fecharModal(els.modalVendedor);
      // Sem ID para pagamento: pede para cadastrar (volta a pedir a cada entrada até preencher).
      if (!perfil.id_pagamento) pedirIdPagamento();
      else BD.novidades(perfil);
    } else {
      mostrarSemCalculadora(false);
      definirSessao(null);
      abrirModalVendedor(perfil);
    }
  }

  $("entrar-discord").addEventListener("click", async (e) => {
    e.target.disabled = true;
    e.target.textContent = "⏳ Abrindo o Discord…";
    try {
      await BD.entrarComDiscord();
    } catch (erro) {
      e.target.disabled = false;
      e.target.textContent = "Entrar com Discord";
      mostrarErroVendedor(BD.mensagemErro(erro));
    }
  });

  async function sair() {
    await BD.sair();
    definirSessao(null);
    abrirModalVendedor(null);
  }

  $("sair-nao-cadastrado").addEventListener("click", sair);

  // ---------------------------------------------------------------- ID para pagamento

  let perfilLogado = null;
  function pedirIdPagamento() {
    $("id-pagamento-valor").value = "";
    $("id-pagamento-erro").hidden = true;
    $("id-pagamento-salvar").disabled = false;
    BD.abrirModal($("modal-id-pagamento"), $("id-pagamento-valor"));
  }
  function fecharIdPagamento() {
    BD.fecharModal($("modal-id-pagamento"));
    if (perfilLogado) BD.novidades(perfilLogado); // as novidades aparecem depois
  }
  $("form-id-pagamento").addEventListener("submit", async (e) => {
    e.preventDefault();
    const valor = $("id-pagamento-valor").value.trim();
    const erro = $("id-pagamento-erro");
    if (!valor) { erro.textContent = "Informe o seu ID para pagamento."; erro.hidden = false; return $("id-pagamento-valor").focus(); }
    $("id-pagamento-salvar").disabled = true;
    const { error } = await db.rpc("salvar_meu_id_pagamento", { p_id_pagamento: valor });
    $("id-pagamento-salvar").disabled = false;
    if (error) { erro.textContent = BD.mensagemErro(error); erro.hidden = false; return; }
    if (perfilLogado) perfilLogado.id_pagamento = valor;
    BD.toast("ID para pagamento salvo.", "ok");
    fecharIdPagamento();
  });
  $("id-pagamento-depois").addEventListener("click", fecharIdPagamento);
  $("sair-sem-calculadora").addEventListener("click", () => { mostrarSemCalculadora(false); sair(); });
  $("tentar-novamente").addEventListener("click", verificarLogin);
  $("copiar-discord-id").addEventListener("click", (e) => {
    BD.copiar($("meu-discord-id").value).then(() => { e.target.textContent = "✅ ID copiado!"; });
  });
  els.trocarVendedor.addEventListener("click", () => (sessao ? sair() : abrirModalVendedor(null)));

  async function atualizarMinhaSemana() {
    if (!sessao) return;
    const { data, error } = await db.rpc("minha_semana");
    if (error) {
      if (/NAO_CADASTRADO|JWT/.test(error.message)) verificarLogin();
      return;
    }
    els.minhaSemana.textContent = `Sua semana: ${data.quantidade} venda${data.quantidade === 1 ? "" : "s"} · ${formatarValor(data.total)} · comissão ${formatarValor(data.comissao)}`;
    els.minhaSemana.hidden = false;
  }

  // ---------------------------------------------------------------- cálculo

  function precoAtual(produto) {
    return Number(comParceria ? produto.preco_com_parceria : produto.preco_sem_parceria);
  }

  function selecionados() {
    return produtos.filter((p) => (quantidades[p.id] || 0) > 0);
  }

  function atualizarResumo() {
    els.resumoTipo.textContent = comParceria
      ? `Parceria${els.selectParceria.value ? ' — ' + els.selectParceria.selectedOptions[0].textContent : ''}`
      : 'Pista';
    els.resumoTipo.classList.toggle('com-parceria', comParceria);

    const lista = selecionados();
    els.resumoLista.innerHTML = lista.length
      ? lista.map((p) => `<li><span>${esc(p.icone)} ${esc(p.nome)} x${quantidades[p.id]}</span><span>${formatarValor(precoAtual(p) * quantidades[p.id])}</span></li>`).join('')
      : '<li class="resumo-vazio">Nenhum item selecionado</li>';

    totalAtual = lista.reduce((soma, p) => soma + precoAtual(p) * quantidades[p.id], 0);
    els.total.textContent = formatarValor(totalAtual);
  }

  function atualizarLinha(produto) {
    const linha = $(`linha-${produto.id}`);
    if (!linha) return;
    const qtd = quantidades[produto.id] || 0;
    linha.querySelector('input').value = qtd;
    linha.querySelector('.item-preco').textContent = `${formatarValor(precoAtual(produto))} / unidade`;
    linha.querySelector('.item-subtotal').textContent = formatarValor(precoAtual(produto) * qtd);
    linha.classList.toggle('selecionado', qtd > 0);
  }

  function definirQuantidade(produto, qtd) {
    quantidades[produto.id] = Math.max(0, Math.min(99999, qtd || 0));
    atualizarLinha(produto);
    atualizarResumo();
  }

  function renderizarItens() {
    if (!produtos.length) {
      els.listaItens.innerHTML = '<h2>Itens</h2><p class="vazio">Nenhum produto cadastrado ainda. Cadastre os produtos no painel.</p>';
      return;
    }
    els.listaItens.innerHTML = '<h2>Itens</h2>';
    const categorias = new Set(produtos.map((p) => p.categoria || 'Geral'));
    let categoriaAtual = null;
    produtos.forEach((produto) => {
      quantidades[produto.id] = 0;
      const categoria = produto.categoria || 'Geral';
      if (categorias.size > 1 && categoria !== categoriaAtual) {
        categoriaAtual = categoria;
        const titulo = document.createElement('h3');
        titulo.className = 'categoria-titulo';
        titulo.textContent = categoria;
        els.listaItens.appendChild(titulo);
      }
      const craft = (produto.craft || []).map((m) => `${m.quantidade} ${m.material}`).join(' + ');
      const linha = document.createElement('div');
      linha.className = 'item-linha';
      linha.id = `linha-${produto.id}`;
      linha.innerHTML = `
        ${produto.serve_para
          ? `<button type="button" class="item-icone tem-dica" data-dica aria-label="Para que serve: ${esc(produto.nome)}" aria-expanded="false">${BD.iconeProduto(produto)}<span class="balao-dica" role="tooltip"><strong>Serve para:</strong> ${esc(produto.serve_para)}</span></button>`
          : `<span class="item-icone" aria-hidden="true">${BD.iconeProduto(produto)}</span>`}
        <div>
          <p class="item-nome">${esc(produto.nome)}</p>
          <p class="item-preco"></p>
          ${craft ? `<p class="item-craft">Craft: ${esc(craft)} / un.</p>` : ''}
        </div>
        <div class="item-qtd">
          <button type="button" class="passo-grande" data-passo="-10" aria-label="Diminuir 10">-10</button>
          <button type="button" class="passo-grande" data-passo="-5" aria-label="Diminuir 5">-5</button>
          <button type="button" data-passo="-1" aria-label="Diminuir 1">−</button>
          <input type="number" min="0" value="0" inputmode="numeric" aria-label="Quantidade de ${esc(produto.nome)}">
          <button type="button" data-passo="1" aria-label="Aumentar 1">+</button>
          <button type="button" class="passo-grande" data-passo="5" aria-label="Aumentar 5">+5</button>
          <button type="button" class="passo-grande" data-passo="10" aria-label="Aumentar 10">+10</button>
        </div>
        <div class="item-subtotal"></div>`;
      els.listaItens.appendChild(linha);

      linha.querySelectorAll('[data-passo]').forEach((botao) => {
        botao.addEventListener('click', () => definirQuantidade(produto, (quantidades[produto.id] || 0) + Number(botao.dataset.passo)));
      });
      const input = linha.querySelector('input');
      input.addEventListener('input', () => definirQuantidade(produto, parseInt(input.value, 10)));
      input.addEventListener('focus', () => input.select());
      atualizarLinha(produto);
    });
  }

  function renderizarParcerias() {
    els.selectParceria.innerHTML = '<option value="">Selecione o parceiro…</option>'
      + parcerias.map((p) => `<option value="${esc(p.id)}">${esc(p.nome)}</option>`).join('');
    els.semParcerias.hidden = parcerias.length > 0;
  }

  function limparTudo() {
    produtos.forEach((p) => { quantidades[p.id] = 0; atualizarLinha(p); });
    els.observacao.value = '';
    els.cliente.value = '';
    atualizarResumo();
  }

  // ---------------------------------------------------------------- eventos

  els.radios.forEach((radio) => {
    radio.addEventListener('change', () => {
      comParceria = document.querySelector('input[name="parceria"]:checked').value === 'com';
      // Na parceria, o parceiro é o cliente; na pista, o cliente é opcional.
      els.campoParceria.hidden = !comParceria;
      els.campoCliente.hidden = comParceria;
      els.selectParceria.classList.remove('invalido');
      produtos.forEach(atualizarLinha);
      atualizarResumo();
    });
  });

  els.selectParceria.addEventListener('change', () => {
    els.selectParceria.classList.remove('invalido');
    atualizarResumo();
  });

  els.limpar.addEventListener('click', limparTudo);

  function mostrarStatus(texto, tipo) {
    els.status.textContent = texto;
    els.status.className = `status ${tipo}`;
    els.status.hidden = !texto;
  }

  // Registrar: confere os dados e abre a confirmação; a venda só é gravada ao confirmar.
  els.registrar.addEventListener('click', () => {
    mostrarStatus('', '');
    if (!sessao) return abrirModalVendedor(null);
    if (!sessao.registra) return mostrarStatus('O seu perfil só visualiza a calculadora.', 'erro');
    if (!selecionados().length) return mostrarStatus('Adicione pelo menos um item antes de registrar.', 'erro');
    if (comParceria && !els.selectParceria.value) {
      els.selectParceria.classList.add('invalido');
      els.selectParceria.focus();
      return mostrarStatus('Selecione o parceiro (cliente da venda).', 'erro');
    }
    const cliente = comParceria ? els.selectParceria.selectedOptions[0].textContent : els.cliente.value.trim();
    $('confirmar-tipo').textContent = comParceria ? '🤝 Parceria' : '🛣️ Pista';
    $('confirmar-cliente').textContent = cliente || '— (não informado)';
    $('confirmar-itens').innerHTML = selecionados().map((p) => `<li><span>${BD.iconeProduto(p, 'chip-img')} ${esc(p.nome)} x${quantidades[p.id]}</span><span>${formatarValor(precoAtual(p) * quantidades[p.id])}</span></li>`).join('');
    $('confirmar-total').textContent = formatarValor(totalAtual);
    const obs = els.observacao.value.trim();
    $('confirmar-observacao').hidden = !obs;
    $('confirmar-observacao').textContent = obs ? '📝 ' + obs : '';
    $('confirmar-erro').hidden = true;
    $('confirmar-ok').disabled = false;
    $('confirmar-ok').textContent = '✅ Confirmar venda';
    modoConfirmacao(false);
    BD.abrirModal($('modal-confirmar'), $('confirmar-ok'));
  });

  // A mesma janela: antes de confirmar mostra "Confirmar venda"; depois vira "Venda registrada!" com o ✓.
  function modoConfirmacao(registrada) {
    $('modal-confirmar').classList.toggle('registrada', registrada);
    $('confirmar-icone').hidden = !registrada;
    $('confirmar-titulo').textContent = registrada ? 'Venda registrada!' : 'Confirmar venda';
    $('confirmar-texto').textContent = registrada ? 'Venda salva e enviada para o Discord.' : 'Confira os dados antes de registrar.';
    $('confirmar-botoes').hidden = registrada;
    $('sucesso-botoes').hidden = !registrada;
  }

  $('confirmar-voltar').addEventListener('click', () => BD.fecharModal($('modal-confirmar')));
  $('modal-confirmar').addEventListener('click', (e) => { if (e.target === $('modal-confirmar')) BD.fecharModal($('modal-confirmar')); });

  $('confirmar-ok').addEventListener('click', async () => {
    const botao = $('confirmar-ok');
    if (botao.disabled) return;
    const itens = selecionados().map((p) => ({ produto_id: p.id, quantidade: quantidades[p.id] }));
    const parceriaNome = comParceria ? els.selectParceria.selectedOptions[0].textContent : '';
    botao.disabled = true;
    botao.textContent = '⏳ Registrando…';
    const { data, error } = await db.rpc('registrar_venda', {
      p_itens: itens,
      p_parceria_id: comParceria ? els.selectParceria.value : null,
      p_cliente: comParceria ? null : (els.cliente.value.trim() || null),
      p_observacao: els.observacao.value.trim() || null,
    });
    botao.disabled = false;
    botao.textContent = '✅ Confirmar venda';

    if (error) {
      $('confirmar-erro').textContent = `Não foi possível registrar a venda: ${BD.mensagemErro(error)}`;
      $('confirmar-erro').hidden = false;
      if (/NAO_CADASTRADO|JWT/.test(error.message)) { BD.fecharModal($('modal-confirmar')); verificarLogin(); }
      if (/não está mais disponível/.test(error.message)) carregarCatalogo();
      return;
    }

    totalSucesso = Number(data.total);
    $('confirmar-total').textContent = formatarValor(totalSucesso);
    els.sucessoDetalhe.textContent = `Venda #${data.numero} · ${comParceria ? 'Parceria — ' + parceriaNome : 'Pista'} · sua comissão ${formatarValor(data.comissao)}`;
    els.sucessoCopiar.textContent = '📋 Copiar valor';
    limparTudo();
    atualizarMinhaSemana();
    modoConfirmacao(true);
    els.sucessoCopiar.focus();
  });

  els.sucessoOk.addEventListener('click', () => BD.fecharModal($('modal-confirmar')));
  els.sucessoCopiar.addEventListener('click', () => {
    BD.copiar(String(Math.round(totalSucesso))).then(() => { els.sucessoCopiar.textContent = '✅ Copiado!'; });
  });

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (!$('modal-confirmar').hidden) BD.fecharModal($('modal-confirmar'));
  });

  // ---------------------------------------------------------------- tabela de preços

  const linkTabela = $('link-tabela');
  const copiarLink = $('copiar-link');
  linkTabela.value = new URL('img/tabela_v1.png', location.href).href;
  linkTabela.addEventListener('focus', () => linkTabela.select());
  copiarLink.addEventListener('click', () => {
    BD.copiar(linkTabela.value)
      .then(() => { copiarLink.textContent = '✅ Link copiado!'; copiarLink.classList.add('copiado'); })
      .catch(() => { linkTabela.focus(); copiarLink.textContent = 'Selecionado — aperte Ctrl+C'; })
      .finally(() => setTimeout(() => {
        copiarLink.textContent = '📋 Copiar link da tabela';
        copiarLink.classList.remove('copiado');
      }, 2000));
  });

  // ---------------------------------------------------------------- início

  async function carregarCatalogo() {
    const [resProdutos, resParcerias] = await Promise.all([
      db.from('produtos').select('id, nome, icone, imagem, categoria, preco_com_parceria, preco_sem_parceria, craft, serve_para, ordem').eq('ativo', true).order('ordem').order('nome'),
      db.from('parcerias').select('id, nome').eq('ativo', true).order('nome'),
    ]);
    if (resProdutos.error) {
      els.listaItens.innerHTML = `<h2>Itens</h2><p class="status erro">Não foi possível carregar os itens: ${esc(BD.mensagemErro(resProdutos.error))}</p>`;
      return;
    }
    produtos = resProdutos.data;
    parcerias = resParcerias.data || [];
    renderizarItens();
    renderizarParcerias();
    atualizarResumo();
  }

  carregarCatalogo();
  const erroLogin = BD.erroDoLogin();
  verificarLogin().then(() => { if (erroLogin) mostrarErroVendedor('O Discord não completou o login: ' + erroLogin); });
  db.auth.onAuthStateChange((evento) => { if (evento === 'SIGNED_IN' && !sessao && !entrandoComCodigo) verificarLogin(); });
  // "Serve para": abre ao clicar na imagem (no computador também aparece ao passar o mouse).
  function fecharDicas(exceto) {
    document.querySelectorAll('[data-dica].aberto').forEach((b) => {
      if (b !== exceto) { b.classList.remove('aberto'); b.setAttribute('aria-expanded', 'false'); }
    });
  }
  document.addEventListener('click', (e) => {
    const botao = e.target.closest('[data-dica]');
    fecharDicas(botao);
    if (!botao) return;
    const aberto = botao.classList.toggle('aberto');
    botao.setAttribute('aria-expanded', String(aberto));
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') fecharDicas(null); });
})();
