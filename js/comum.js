// Funções compartilhadas entre a calculadora e o painel.
(function () {
  const config = window.BD_CONFIG || {};
  const configurado = /^https:\/\/.+\.supabase\.co\/?$/.test(config.supabaseUrl || '')
    && config.supabaseAnonKey && !/^SUA-/.test(config.supabaseAnonKey);

  // Volta do login do Discord: guarda o que veio na URL antes de o Supabase limpá-la (vai para os logs de login).
  const retornoLogin = (() => {
    const p = new URLSearchParams(location.hash.slice(1));
    new URLSearchParams(location.search.slice(1)).forEach((v, k) => { if (!p.has(k)) p.set(k, v); });
    return p.get('access_token') || p.get('error') || p.get('error_description') ? p : null;
  })();

  const BD = {
    configurado,
    moeda: 'R$ ',
    db: configurado && window.supabase
      ? window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey)
      : null,

    formatarValor(valor) {
      return BD.moeda + Number(valor || 0).toLocaleString('pt-BR', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
    },

    esc(texto) {
      return String(texto ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    },

    // Mensagem legível a partir de um erro do Supabase.
    mensagemErro(erro) {
      if (!erro) return 'Erro desconhecido.';
      const msg = erro.message || String(erro);
      if (/Failed to fetch|NetworkError/i.test(msg)) return 'Sem conexão com o servidor. Verifique sua internet.';
      if (/NAO_CADASTRADO/.test(msg)) return 'Sua conta do Discord não está cadastrada ou foi desativada.';
      if (/JWT expired|Auth session missing/i.test(msg)) return 'Sua sessão expirou. Entre novamente com o Discord.';
      if (/permission denied|row-level security/i.test(msg)) return 'Você não tem permissão para esta ação.';
      return msg;
    },

    // Login com o Discord: sai do site e volta sempre para a calculadora (a home), já logado.
    // Depois de sair (ou com trocarConta), o Discord mostra a tela de autorização em vez de voltar direto
    // com a conta já aberta: nela, "Não é você?" deixa escolher outra conta do Discord.
    async entrarComDiscord(trocarConta) {
      const trocar = trocarConta || BD.lerSalvo('bluedragons-trocar-conta') === '1';
      const { error } = await BD.db.auth.signInWithOAuth({
        provider: 'discord',
        options: { redirectTo: new URL('./', location.href).href, ...(trocar ? { queryParams: { prompt: 'consent' } } : {}) },
      });
      if (error) throw error;
      BD.salvar('bluedragons-trocar-conta', '');
    },

    // Sai do site; o próximo login deixa escolher a conta do Discord.
    async sair() {
      BD.salvar('bluedragons-trocar-conta', '1');
      await BD.db.auth.signOut();
    },

    // { discord_id, cadastrado, id, nome, admin } do usuário logado, ou null sem login.
    async perfil() {
      const { data: { session } } = await BD.db.auth.getSession();
      if (!session) return null;
      // Atualiza nome e cargos do Discord de quem entrou (a resposta chega em 1-2 s).
      for (let i = 0; i < 3; i++) {
        const { data: at, error: erroAt } = await BD.db.rpc('atualizar_meu_discord');
        if (erroAt || !at || !at.pedido) break;
        await new Promise((r) => setTimeout(r, 1200));
      }
      const { data, error } = await BD.db.rpc('meu_perfil');
      if (error) throw error;
      const meta = session.user.user_metadata || {};
      data.apelido = meta.full_name || meta.name || meta.custom_claims?.global_name || '';
      return data;
    },

    // Logs de login: registra o que o Discord devolveu (a API do Discord é consultada com o token do login,
    // que não é guardado), o aparelho e, no banco, a conta gravada pelo Supabase. Nunca atrapalha o login.
    async _registrarRetornoLogin(p) {
      try {
        const mascarar = (email) => (email ? String(email).replace(/^(.{0,2})[^@]*/, '$1***') : email);
        const uaData = navigator.userAgentData;
        const dados = {
          versao: 1,
          pagina: location.origin + location.pathname,
          erro_url: p.get('error') || p.get('error_description')
            ? { error: p.get('error'), error_code: p.get('error_code'), error_description: p.get('error_description') }
            : null,
          retorno: { tem_access_token: !!p.get('access_token'), tem_provider_token: !!p.get('provider_token'),
                     token_type: p.get('token_type'), expires_in: p.get('expires_in'), parametros: [...p.keys()] },
          aparelho: {
            user_agent: navigator.userAgent,
            plataforma: (uaData && uaData.platform) || navigator.platform,
            celular: uaData ? uaData.mobile : /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent),
            idioma: navigator.language,
            tela: `${screen.width}x${screen.height}`,
            app_instalado: window.matchMedia('(display-mode: standalone)').matches,
            veio_de: document.referrer || null,
          },
        };
        const token = p.get('provider_token');
        if (token) {
          for (const [chave, url] of [['discord_users_me', 'https://discord.com/api/v10/users/@me'],
                                      ['discord_oauth2_me', 'https://discord.com/api/v10/oauth2/@me']]) {
            try {
              const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
              const corpo = await r.json().catch(() => null);
              if (corpo && corpo.email) corpo.email = mascarar(corpo.email);
              if (corpo && corpo.user && corpo.user.email) corpo.user.email = mascarar(corpo.user.email);
              dados[chave] = { status: r.status, corpo };
            } catch (e) {
              dados[chave] = { erro: String((e && e.message) || e) };
            }
          }
        }
        await BD.db.auth.getSession(); // espera o Supabase gravar a sessão que veio na URL
        await BD.db.rpc('registrar_login', { p_dados: dados });
      } catch (e) {
        console.warn('Log de login não registrado:', e);
      }
    },

    // Mostra a mensagem de erro que o Supabase devolve na URL quando o login falha.
    erroDoLogin() {
      const params = new URLSearchParams(location.hash.slice(1) || location.search.slice(1));
      const erro = params.get('error_description');
      if (erro) history.replaceState(null, '', location.pathname);
      return erro ? decodeURIComponent(erro.replace(/\+/g, ' ')) : '';
    },

    // O perfil pode isto? (o líder pode tudo; o banco confere de novo em cada ação)
    pode(perfil, permissao) {
      return !!(perfil && (perfil.lider || (perfil.permissoes || {})[permissao]));
    },

    // Esconde os links do topo que o perfil não pode abrir.
    ajustarLinksTopo(perfil) {
      document.querySelectorAll('[data-link-permissao]').forEach((a) => {
        a.hidden = !BD.pode(perfil, a.dataset.linkPermissao);
      });
    },

    // ---------------------------------------------------------------- novidades
    // Mostra, ao entrar, o que chegou desde a última visita (preços, produtos, parcerias, pagamentos e mensagens).
    async novidades(perfil, abrirTodas) {
      if (!perfil || !perfil.cadastrado) return;
      const botao = document.getElementById('botao-novidades');
      const { data, error } = await BD.db.rpc('minhas_novidades', { p_todas: !!abrirTodas });
      if (error || !data) return;
      if (botao) {
        botao.hidden = false;
        botao.querySelector('.contador').textContent = data.novas > 0 ? String(Math.min(data.novas, 99)) : '';
        botao.classList.toggle('tem-novas', data.novas > 0);
        if (!botao._ligado) {
          botao._ligado = true;
          botao.addEventListener('click', () => BD.novidades(perfil, true));
        }
      }
      if (!abrirTodas && !data.novas) return;
      BD._modalNovidades(data.itens || [], abrirTodas);
      if (data.novas > 0) {
        await BD.db.rpc('marcar_novidades_vistas');
        if (botao) { botao.querySelector('.contador').textContent = ''; botao.classList.remove('tem-novas'); }
      }
    },

    _modalNovidades(itens, todas) {
      let modal = document.getElementById('modal-novidades');
      if (!modal) {
        modal = document.createElement('div');
        modal.id = 'modal-novidades';
        modal.className = 'modal-fundo';
        modal.hidden = true;
        modal.innerHTML = `<div class="modal modal-largo cartao" role="dialog" aria-modal="true" aria-labelledby="novidades-titulo">
            <h2 id="novidades-titulo">🔔 Novidades</h2>
            <div id="novidades-lista"></div>
            <button type="button" class="botao-primario botao-bloco" data-fechar-novidades>Entendi</button>
          </div>`;
        document.body.appendChild(modal);
        modal.addEventListener('click', (e) => {
          if (e.target === modal || e.target.closest('[data-fechar-novidades]')) BD.fecharModal(modal);
        });
        document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) BD.fecharModal(modal); });
      }
      const ICONES = { preco: '💲', produto: '📦', parceria: '🤝', pagamento: '💸', mensagem: '📢' };
      const ROTULOS = { preco: 'Preço', produto: 'Produto', parceria: 'Parceria', pagamento: 'Pagamento', mensagem: 'Mensagem' };
      const origem = (n) => [ROTULOS[n.tipo] || '',
        n.tipo === 'mensagem' && n.autor ? 'de ' + n.autor : '',
        n.individual ? 'só para você' : n.cargo ? 'para o seu cargo' : ''].filter(Boolean).join(' ');
      modal.querySelector('#novidades-titulo').textContent = todas ? '🔔 Novidades dos últimos 30 dias' : '🔔 Novidades desde a sua última visita';
      modal.querySelector('#novidades-lista').innerHTML = itens.length
        ? `<ul class="lista-novidades">${itens.map((n) => `
            <li class="novidade-${BD.esc(n.tipo)}${n.nova ? ' nova' : ''}">
              <span class="novidade-icone" aria-hidden="true">${ICONES[n.tipo] || '🔔'}</span>
              <div>
                <strong>${BD.esc(n.titulo)}</strong>${n.nova && todas ? ' <span class="etiqueta pendente">nova</span>' : ''}
                ${n.descricao ? `<p>${BD.esc(n.descricao)}</p>` : ''}
                <span class="dica">${BD.esc(origem(n))} · ${BD.esc(BD.dataHoraBR(n.criado_em))}</span>
              </div>
            </li>`).join('')}</ul>`
        : '<p class="vazio">Nenhuma novidade nos últimos 30 dias.</p>';
      BD.abrirModal(modal, modal.querySelector('[data-fechar-novidades]'));
    },

    // Imagem do produto (se tiver) ou o emoji.
    iconeProduto(p, classe) {
      if (p.imagem) return `<img class="${classe || 'produto-img'}" src="${BD.esc(p.imagem)}" alt="" loading="lazy">`;
      return BD.esc(p.icone || '📦');
    },

    lerSalvo(chave) {
      try { return localStorage.getItem(chave) || ''; } catch (e) { return ''; }
    },

    salvar(chave, valor) {
      try {
        if (valor) localStorage.setItem(chave, valor);
        else localStorage.removeItem(chave);
      } catch (e) { /* sem localStorage: vale só nesta sessão */ }
    },

    copiar(texto) {
      if (navigator.clipboard && window.isSecureContext) {
        return navigator.clipboard.writeText(texto).catch(() => BD._copiarAntigo(texto));
      }
      return BD._copiarAntigo(texto);
    },

    _copiarAntigo(texto) {
      const area = document.createElement('textarea');
      area.value = texto;
      area.setAttribute('readonly', '');
      area.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
      document.body.appendChild(area);
      area.select();
      let ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(area);
      return ok ? Promise.resolve() : Promise.reject(new Error('Falha ao copiar'));
    },

    abrirModal(el, foco) {
      el.hidden = false;
      document.body.classList.add('modal-aberto');
      if (foco) setTimeout(() => foco.focus(), 30);
    },

    fecharModal(el) {
      el.hidden = true;
      if (!document.querySelector('.modal-fundo:not([hidden])')) document.body.classList.remove('modal-aberto');
    },

    toast(texto, tipo) {
      let el = document.getElementById('toast');
      if (!el) {
        el = document.createElement('div');
        el.id = 'toast';
        el.setAttribute('role', 'status');
        document.body.appendChild(el);
      }
      el.className = `toast ${tipo || ''}`;
      el.textContent = texto;
      el.hidden = false;
      clearTimeout(el._timer);
      el._timer = setTimeout(() => { el.hidden = true; }, 3500);
    },

    // Datas no formato AAAA-MM-DD, no fuso local do navegador.
    dataISO(data) {
      const d = new Date(data);
      return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    },

    inicioSemana(data) {
      const d = new Date(data);
      d.setHours(12, 0, 0, 0);
      d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); // segunda-feira
      return d;
    },

    somarDias(data, dias) {
      const d = new Date(data);
      d.setDate(d.getDate() + dias);
      return d;
    },

    dataBR(iso) {
      return String(iso).slice(0, 10).split('-').reverse().join('/');
    },

    dataHoraBR(iso) {
      return new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' });
    },

    mostrarErroConfig(container) {
      container.innerHTML = `
        <section class="cartao erro-config">
          <h2>⚙️ Configuração pendente</h2>
          <p>O site ainda não está conectado ao Supabase. Edite <code>js/config.js</code> com a
          <strong>Project URL</strong> e a <strong>anon public key</strong> do seu projeto
          (Supabase → Project Settings → API) e rode o arquivo <code>supabase/schema.sql</code> no SQL Editor.</p>
          <p>Veja o passo a passo no README do repositório.</p>
        </section>`;
    },
  };

  window.BD = BD;
  if (retornoLogin && BD.db) BD._registrarRetornoLogin(retornoLogin);
})();

// Banner do dragão: toca uma vez ao abrir (o dragão chega e pousa) e fica pousado.
// Clicar no banner repete. Com "reduzir movimento" ligado, mostra só o dragão pousado.
(function () {
  const banner = document.querySelector('.banner-dragao');
  const video = banner && banner.querySelector('video');
  if (!video) return;
  let reduzir = false;
  try { reduzir = window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) { /* navegador antigo */ }
  const tocar = () => {
    try {
      video.currentTime = 0;
      const p = video.play();
      if (p && p.catch) p.catch(() => { /* autoplay bloqueado: fica o pôster (dragão pousado) */ });
    } catch (e) { /* sem suporte a vídeo: fica o pôster */ }
  };
  if (!reduzir) tocar();
  banner.addEventListener('click', tocar);
})();
