(function () {
  const { db, esc, formatarValor } = BD;
  const $ = (id) => document.getElementById(id);

  const CHAVE_SESSAO = 'bluedragons-sessao';

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
    formVendedor: $('form-vendedor'),
    selectVendedor: $('select-vendedor'),
    inputPin: $('input-pin'),
    erroVendedor: $('modal-vendedor-erro'),
    entrar: $('entrar'),
    cancelarVendedor: $('cancelar-vendedor'),
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
  let sessao = lerSessao(); // { token, id, nome }
  let comParceria = false;
  let totalAtual = 0;
  let totalSucesso = 0;
  const quantidades = {};

  // ---------------------------------------------------------------- sessão

  function lerSessao() {
    try { return JSON.parse(BD.lerSalvo(CHAVE_SESSAO)) || null; } catch (e) { return null; }
  }

  function definirSessao(nova) {
    sessao = nova;
    BD.salvar(CHAVE_SESSAO, nova ? JSON.stringify(nova) : '');
    els.vendedorNome.textContent = nova ? nova.nome : '—';
    els.trocarVendedor.textContent = nova ? 'Trocar' : 'Entrar';
    if (nova) atualizarMinhaSemana();
    else els.minhaSemana.hidden = true;
  }

  async function carregarVendedores() {
    const { data, error } = await db.rpc('listar_vendedores');
    if (error) {
      els.selectVendedor.innerHTML = '<option value="">Erro ao carregar</option>';
      mostrarErroVendedor(BD.mensagemErro(error));
      return;
    }
    els.selectVendedor.innerHTML = data.length
      ? '<option value="">Selecione seu nome…</option>' + data.map((v) => `<option value="${esc(v.id)}">${esc(v.nome)}</option>`).join('')
      : '<option value="">Nenhum vendedor cadastrado</option>';
    if (sessao) els.selectVendedor.value = sessao.id;
  }

  function mostrarErroVendedor(texto) {
    els.erroVendedor.textContent = texto;
    els.erroVendedor.hidden = !texto;
  }

  function abrirModalVendedor() {
    mostrarErroVendedor('');
    els.inputPin.value = '';
    els.cancelarVendedor.hidden = !sessao;
    carregarVendedores();
    BD.abrirModal(els.modalVendedor, els.selectVendedor);
  }

  els.formVendedor.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    const id = els.selectVendedor.value;
    const pin = els.inputPin.value.trim();
    if (!id) return mostrarErroVendedor('Selecione seu nome.');
    if (!/^\d{4,8}$/.test(pin)) return mostrarErroVendedor('O PIN tem de 4 a 8 números.');

    els.entrar.disabled = true;
    els.entrar.textContent = '⏳ Entrando…';
    const { data, error } = await db.rpc('entrar_vendedor', { p_vendedor_id: id, p_pin: pin });
    els.entrar.disabled = false;
    els.entrar.textContent = 'Entrar';

    if (error) return mostrarErroVendedor(BD.mensagemErro(error));
    if (!data.ok) {
      els.inputPin.value = '';
      els.inputPin.focus();
      return mostrarErroVendedor(data.erro);
    }
    if (sessao && sessao.token !== data.token) db.rpc('sair_vendedor', { p_token: sessao.token });
    definirSessao({ token: data.token, id: data.id, nome: data.nome });
    BD.fecharModal(els.modalVendedor);
  });

  els.inputPin.addEventListener('input', () => {
    els.inputPin.value = els.inputPin.value.replace(/\D/g, '');
  });

  els.trocarVendedor.addEventListener('click', abrirModalVendedor);
  els.cancelarVendedor.addEventListener('click', () => BD.fecharModal(els.modalVendedor));

  async function atualizarMinhaSemana() {
    if (!sessao) return;
    const { data, error } = await db.rpc('minha_semana', { p_token: sessao.token });
    if (error) {
      if (/SESSAO_INVALIDA/.test(error.message)) {
        definirSessao(null);
        abrirModalVendedor();
      }
      return;
    }
    els.minhaSemana.textContent = `Sua semana: ${data.quantidade} venda${data.quantidade === 1 ? '' : 's'} · ${formatarValor(data.total)} · comissão ${formatarValor(data.comissao)}`;
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
      const craft = [
        produto.craft_placa ? `${produto.craft_placa} placa${produto.craft_placa === 1 ? '' : 's'}` : '',
        produto.craft_material ? `${produto.craft_material} ${String(produto.material_nome || '').toLowerCase()}` : '',
      ].filter(Boolean).join(' + ');
      const linha = document.createElement('div');
      linha.className = 'item-linha';
      linha.id = `linha-${produto.id}`;
      linha.innerHTML = `
        <span class="item-icone" aria-hidden="true">${esc(produto.icone)}</span>
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
    if (!sessao) return abrirModalVendedor();
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
      p_token: sessao.token,
      p_itens: itens,
      p_parceria_id: comParceria ? els.selectParceria.value : null,
      p_cliente: els.cliente.value.trim() || null,
      p_observacao: els.observacao.value.trim() || null,
    });
    els.registrar.disabled = false;
    els.registrar.textContent = '📝 Registrar venda';

    if (error) {
      mostrarStatus(`Não foi possível registrar a venda: ${BD.mensagemErro(error)}`, 'erro');
      if (/SESSAO_INVALIDA/.test(error.message)) { definirSessao(null); abrirModalVendedor(); }
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
    else if (!els.modalVendedor.hidden && sessao) BD.fecharModal(els.modalVendedor);
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
      db.from('produtos').select('id, nome, icone, categoria, preco_com_parceria, preco_sem_parceria, craft_placa, craft_material, material_nome, ordem').eq('ativo', true).order('ordem').order('nome'),
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

  definirSessao(sessao);
  carregarCatalogo();
  if (!sessao) abrirModalVendedor();
})();
