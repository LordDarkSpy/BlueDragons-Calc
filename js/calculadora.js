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
    copiar: $('copiar'),
    limpar: $('limpar'),
    vendedorNome: $('vendedor-nome'),
    trocarVendedor: $('trocar-vendedor'),
    minhaSemana: $('minha-semana'),
    modalVendedor: $('modal-vendedor'),
    erroVendedor: $('modal-vendedor-erro'),
    modalSucesso: $('modal-sucesso'),
    sucessoTotal: $('sucesso-total'),
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
  let sessao = null; // { id, nome } do vendedor logado
  let comParceria = false;
  let totalAtual = 0;
  let totalSucesso = 0;
  const quantidades = {};

  // ---------------------------------------------------------------- sessão (Discord)

  function definirSessao(nova) {
    sessao = nova;
    els.vendedorNome.textContent = nova ? nova.nome : "—";
    els.trocarVendedor.textContent = nova ? "Sair" : "Entrar";
    if (nova) atualizarMinhaSemana();
    else els.minhaSemana.hidden = true;
  }

  function mostrarErroVendedor(texto) {
    els.erroVendedor.textContent = texto;
    els.erroVendedor.hidden = !texto;
  }

  function abrirModalVendedor(perfil) {
    const naoCadastrado = !!(perfil && !perfil.cadastrado);
    $("login-entrar-bloco").hidden = naoCadastrado;
    $("login-nao-cadastrado").hidden = !naoCadastrado;
    if (naoCadastrado) $("meu-discord-id").value = perfil.discord_id || "";
    BD.abrirModal(els.modalVendedor, naoCadastrado ? $("copiar-discord-id") : $("entrar-discord"));
  }

  async function verificarLogin() {
    let perfil;
    try {
      perfil = await BD.perfil();
    } catch (erro) {
      definirSessao(null);
      abrirModalVendedor(null);
      return mostrarErroVendedor(BD.mensagemErro(erro));
    }
    if (perfil && perfil.cadastrado) {
      definirSessao({ id: perfil.id, nome: perfil.nome });
      mostrarErroVendedor("");
      BD.fecharModal(els.modalVendedor);
    } else {
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
    await db.auth.signOut();
    definirSessao(null);
    abrirModalVendedor(null);
  }

  $("sair-nao-cadastrado").addEventListener("click", sair);
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
        <span class="item-icone" aria-hidden="true">${BD.iconeProduto(produto)}</span>
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
    els.selectParceria.innerHTML = '<option value="">Selecione a parceria…</option>'
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
      els.campoParceria.hidden = !comParceria;
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

  els.copiar.addEventListener('click', () => {
    BD.copiar(String(Math.round(totalAtual))).then(() => {
      els.copiar.textContent = '✅ Copiado!';
      els.copiar.classList.add('copiado');
      setTimeout(() => {
        els.copiar.textContent = '📋 Copiar valor total';
        els.copiar.classList.remove('copiado');
      }, 1500);
    });
  });

  function mostrarStatus(texto, tipo) {
    els.status.textContent = texto;
    els.status.className = `status ${tipo}`;
    els.status.hidden = !texto;
  }

  els.registrar.addEventListener('click', async () => {
    mostrarStatus('', '');
    if (!sessao) return abrirModalVendedor(null);
    if (totalAtual <= 0 && !selecionados().length) return mostrarStatus('Adicione pelo menos um item antes de registrar.', 'erro');
    if (comParceria && !els.selectParceria.value) {
      els.selectParceria.classList.add('invalido');
      els.selectParceria.focus();
      return mostrarStatus('Selecione a parceria.', 'erro');
    }

    const itens = selecionados().map((p) => ({ produto_id: p.id, quantidade: quantidades[p.id] }));
    const parceriaNome = comParceria ? els.selectParceria.selectedOptions[0].textContent : '';

    els.registrar.disabled = true;
    els.registrar.textContent = '⏳ Registrando…';
    const { data, error } = await db.rpc('registrar_venda', {
      p_itens: itens,
      p_parceria_id: comParceria ? els.selectParceria.value : null,
      p_cliente: els.cliente.value.trim() || null,
      p_observacao: els.observacao.value.trim() || null,
    });
    els.registrar.disabled = false;
    els.registrar.textContent = '📝 Registrar venda';

    if (error) {
      mostrarStatus(`Não foi possível registrar a venda: ${BD.mensagemErro(error)}`, 'erro');
      if (/NAO_CADASTRADO|JWT/.test(error.message)) verificarLogin();
      if (/não está mais disponível/.test(error.message)) carregarCatalogo();
      return;
    }

    totalSucesso = Number(data.total);
    els.sucessoTotal.textContent = formatarValor(totalSucesso);
    els.sucessoDetalhe.textContent = `Venda #${data.numero} · ${comParceria ? 'Parceria — ' + parceriaNome : 'Pista'} · sua comissão ${formatarValor(data.comissao)}`;
    els.sucessoCopiar.textContent = '📋 Copiar valor';
    limparTudo();
    atualizarMinhaSemana();
    BD.abrirModal(els.modalSucesso, els.sucessoOk);
  });

  els.sucessoOk.addEventListener('click', () => BD.fecharModal(els.modalSucesso));
  els.modalSucesso.addEventListener('click', (e) => { if (e.target === els.modalSucesso) BD.fecharModal(els.modalSucesso); });
  els.sucessoCopiar.addEventListener('click', () => {
    BD.copiar(String(Math.round(totalSucesso))).then(() => { els.sucessoCopiar.textContent = '✅ Copiado!'; });
  });

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (!els.modalSucesso.hidden) BD.fecharModal(els.modalSucesso);
    
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
      db.from('produtos').select('id, nome, icone, imagem, categoria, preco_com_parceria, preco_sem_parceria, craft, ordem').eq('ativo', true).order('ordem').order('nome'),
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
  db.auth.onAuthStateChange((evento) => { if (evento === 'SIGNED_IN' && !sessao) verificarLogin(); });
})();
