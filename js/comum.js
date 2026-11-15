// Funções compartilhadas entre a calculadora e o painel.
(function () {
  const config = window.BD_CONFIG || {};
  const configurado = /^https:\/\/.+\.supabase\.co\/?$/.test(config.supabaseUrl || '')
    && config.supabaseAnonKey && !/^SUA-/.test(config.supabaseAnonKey);

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

    // Login com o Discord: sai do site e volta para a mesma página já logado.
    async entrarComDiscord() {
      const { error } = await BD.db.auth.signInWithOAuth({
        provider: 'discord',
        options: { redirectTo: location.origin + location.pathname },
      });
      if (error) throw error;
    },

    // { discord_id, cadastrado, id, nome, admin } do usuário logado, ou null sem login.
    async perfil() {
      const { data: { session } } = await BD.db.auth.getSession();
      if (!session) return null;
      const { data, error } = await BD.db.rpc('meu_perfil');
      if (error) throw error;
      const meta = session.user.user_metadata || {};
      data.apelido = meta.full_name || meta.name || meta.custom_claims?.global_name || '';
      return data;
    },

    // Mostra a mensagem de erro que o Supabase devolve na URL quando o login falha.
    erroDoLogin() {
      const params = new URLSearchParams(location.hash.slice(1) || location.search.slice(1));
      const erro = params.get('error_description');
      if (erro) history.replaceState(null, '', location.pathname);
      return erro ? decodeURIComponent(erro.replace(/\+/g, ' ')) : '';
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
})();
