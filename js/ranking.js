(function () {
  const { db, esc, formatarValor } = BD;
  const $ = (id) => document.getElementById(id);

  if (!db) {
    BD.mostrarErroConfig($('principal'));
    return;
  }

  const MEDALHAS = ['🥇', '🥈', '🥉'];
  let carregando = 0;

  // ---------------------------------------------------------------- períodos

  function periodo(tipo) {
    const hoje = new Date();
    if (tipo === 'geral') return { inicio: null, fim: null, texto: 'Todas as vendas registradas' };
    if (tipo === 'mes') {
      const ini = new Date(hoje.getFullYear(), hoje.getMonth(), 1, 12);
      const fim = new Date(hoje.getFullYear(), hoje.getMonth() + 1, 0, 12);
      const nome = ini.toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' });
      return { inicio: BD.dataISO(ini), fim: BD.dataISO(fim), texto: nome.charAt(0).toUpperCase() + nome.slice(1) };
    }
    let ini = BD.inicioSemana(hoje);
    if (tipo === 'anterior') ini = BD.somarDias(ini, -7);
    const fim = BD.somarDias(ini, 6);
    return { inicio: BD.dataISO(ini), fim: BD.dataISO(fim), texto: `${BD.dataBR(BD.dataISO(ini))} a ${BD.dataBR(BD.dataISO(fim))}` };
  }

  // ---------------------------------------------------------------- render

  function avatar(v, classe) {
    const inicial = esc((v.nome || '?').trim().charAt(0).toUpperCase());
    if (v.avatar && /^https:\/\/cdn\.discordapp\.com\//.test(v.avatar)) {
      return `<img class="${classe}" src="${esc(v.avatar)}" alt="" loading="lazy" referrerpolicy="no-referrer">`;
    }
    return `<span class="${classe} avatar-inicial" aria-hidden="true">${inicial}</span>`;
  }

  function renderizar(lista) {
    const podio = $('ranking-podio');
    const tabela = $('ranking-lista');
    if (!lista.length) {
      podio.innerHTML = '';
      tabela.innerHTML = '<p class="vazio">Nenhuma venda neste período ainda. Que tal ser o primeiro? 🐉</p>';
      return;
    }

    // Pódio: 2º, 1º, 3º (o 1º no meio, mais alto).
    const top = lista.slice(0, 3);
    const ordem = top.length >= 2 ? [top[1], top[0], top[2]].filter(Boolean) : top;
    podio.innerHTML = ordem.map((v) => `
      <div class="podio-lugar lugar-${v.posicao <= 3 ? v.posicao : 3}${v.eu ? ' eu' : ''}">
        <div class="podio-medalha" aria-hidden="true">${MEDALHAS[v.posicao - 1] || ''}</div>
        ${avatar(v, 'podio-avatar')}
        <p class="podio-nome">${esc(v.nome)}${v.eu ? ' <span class="dica">(você)</span>' : ''}</p>
        <p class="podio-total">${formatarValor(v.total)}</p>
        <p class="dica">${v.vendas} venda${v.vendas === 1 ? '' : 's'} · ${v.itens} ite${v.itens === 1 ? 'm' : 'ns'}</p>
        <div class="podio-base">${v.posicao}º</div>
      </div>`).join('');

    const lider = Number(lista[0].total) || 1;
    tabela.innerHTML = `<table class="tabela-ranking">
      <thead><tr><th>#</th><th>Vendedor</th><th class="num">Vendas</th><th class="num">Itens</th><th class="num">Total vendido</th></tr></thead>
      <tbody>${lista.map((v) => `
        <tr class="${v.eu ? 'linha-eu' : ''}">
          <td class="posicao">${MEDALHAS[v.posicao - 1] || v.posicao + 'º'}</td>
          <td>
            <div class="ranking-vendedor">
              ${avatar(v, 'ranking-avatar')}
              <div>
                <strong>${esc(v.nome)}</strong>${v.eu ? ' <span class="etiqueta parceria">você</span>' : ''}
                <div class="ranking-barra" aria-hidden="true"><span style="width:${Math.max(3, Math.round((Number(v.total) / lider) * 100))}%"></span></div>
              </div>
            </div>
          </td>
          <td class="num">${v.vendas}</td>
          <td class="num">${v.itens}</td>
          <td class="num"><strong>${formatarValor(v.total)}</strong></td>
        </tr>`).join('')}
      </tbody></table>`;

    const eu = lista.find((v) => v.eu);
    if (eu && eu.posicao > 3) {
      tabela.insertAdjacentHTML('afterbegin', `<p class="minha-semana">Você está em <strong>${eu.posicao}º lugar</strong> com ${formatarValor(eu.total)}.</p>`);
    }
  }

  async function carregar() {
    const tipo = document.querySelector('input[name="periodo"]:checked').value;
    const p = periodo(tipo);
    $('ranking-periodo').textContent = p.texto;
    $('ranking-lista').innerHTML = '<p class="carregando">Carregando…</p>';
    const minha = ++carregando;
    const { data, error } = await db.rpc('ranking_vendedores', { p_inicio: p.inicio, p_fim: p.fim });
    if (minha !== carregando) return; // o usuário já trocou de período
    if (error) {
      $('ranking-podio').innerHTML = '';
      $('ranking-lista').innerHTML = `<p class="status erro">${esc(BD.mensagemErro(error))}</p>`;
      return;
    }
    renderizar(data || []);
  }

  document.querySelectorAll('input[name="periodo"]').forEach((r) => r.addEventListener('change', carregar));

  // ---------------------------------------------------------------- login

  function mostrarLogin(texto, erro) {
    $('ranking-app').hidden = true;
    $('ranking-login').hidden = false;
    $('ranking-login-texto').textContent = texto;
    $('ranking-login-erro').hidden = !erro;
    $('ranking-login-erro').textContent = erro || '';
  }

  $('ranking-entrar').addEventListener('click', async (e) => {
    const botao = e.currentTarget;
    const { data: { session } } = await db.auth.getSession();
    if (session) await BD.sair(); // "entrar com outra conta"
    botao.disabled = true;
    botao.textContent = '⏳ Abrindo o Discord…';
    try {
      await BD.entrarComDiscord();
    } catch (erro) {
      botao.disabled = false;
      botao.textContent = 'Entrar com Discord';
      mostrarLogin('Entre com a sua conta do Discord para ver o ranking.', BD.mensagemErro(erro));
    }
  });

  async function iniciar() {
    const erroLogin = BD.erroDoLogin();
    let perfil;
    try {
      perfil = await BD.perfil();
    } catch (erro) {
      return mostrarLogin('Entre com a sua conta do Discord para ver o ranking.', BD.mensagemErro(erro));
    }
    if (!perfil) return mostrarLogin('Entre com a sua conta do Discord para ver o ranking.', erroLogin && 'O Discord não completou o login: ' + erroLogin);
    if (!perfil.cadastrado && !perfil.admin) {
      $('ranking-entrar').textContent = 'Entrar com outra conta';
      return mostrarLogin(perfil.solicitacao && perfil.solicitacao.status === 'pendente' ? 'Seu pedido de cadastro está aguardando a aprovação da liderança.' : 'Sua conta do Discord ainda não tem cadastro. Peça o acesso na calculadora (página inicial).');
    }
    BD.ajustarLinksTopo(perfil);
    if (!BD.pode(perfil, 'ver_ranking')) {
      $('ranking-entrar').textContent = 'Entrar com outra conta';
      return mostrarLogin('O seu perfil não tem acesso ao ranking. Peça à liderança para ajustar o seu perfil.');
    }
    $('ranking-login').hidden = true;
    $('ranking-app').hidden = false;
    carregar();
    BD.novidades(perfil);
  }

  iniciar();
})();
