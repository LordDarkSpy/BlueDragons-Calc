# Calculadora e Gestão de Vendas — Blue Dragons

Site estático (HTML/CSS/JS puro) hospedado no GitHub Pages, com banco de dados no **Supabase**.

Substitui a planilha "VENDAS MERCADO OCULTO" (abas SERRA, PENDRIVE, PAGAMENTO e Base Valores e Craft):

- **Calculadora** (`index.html`): o vendedor entra com nome + PIN, escolhe **Pista** ou **Parceria**, informa o cliente, monta o pedido e registra a venda. Mostra também a tabela de preços com o link para copiar e enviar.
- **Painel** (`admin.html`): relatório semanal (totais, ranking, **pagamento dos vendedores** e **craft usado**), histórico de vendas (cancelamento e exportação CSV), cadastro de vendedores, parcerias, produtos e configuração do Discord.
- **Discord**: cada venda registrada gera um aviso no canal, e toda segunda-feira às 09:00 (horário de Brasília) sai o relatório da semana anterior. Também dá para enviar o relatório pelo painel quando quiser.

### Regras herdadas da planilha

- **Produtos**: já vêm cadastrados os 5 pendrives (Fajuto, Comum, Incomum, Raro e Especial) e Serra, Chave de Fenda, Silenciador de Sinal e Algema, com preço de pista, preço de parceria e craft (placas + plástico/metal por unidade). Dá para editar tudo no painel.
- **Comissão (PAGAMENTO)**: 15% sobre *quantidade × preço de parceria*, inclusive nas vendas de pista, igual à fórmula da planilha. O percentual pode ser mudado em **Painel → Discord** e vale para as vendas seguintes. A comissão de cada venda fica gravada, então mudar o percentual não altera vendas antigas.
- **Craft**: cada venda soma os materiais usados, e o relatório semanal mostra o total de placas, plástico e metal.

## Estrutura

```
index.html           Calculadora de venda
admin.html           Painel administrativo
css/style.css        Estilos (tema azul)
js/config.js         URL e anon key do Supabase  ← editar
js/comum.js          Funções compartilhadas
js/calculadora.js    Lógica da calculadora
js/admin.js          Lógica do painel
supabase/schema.sql  Banco: tabelas, regras de acesso (RLS), funções e agendamento
img/logo.png         Logo (Pixellab, usada sem alterações)
img/tabela_v1.png    Tabela de preços enviada aos clientes
```

Ao trocar a tabela de preços, salve com um nome novo (`tabela_v2.png`) e atualize `index.html` e `js/calculadora.js`, para o Discord não mostrar a imagem antiga em cache.

## Configuração (uma vez só)

### 1. Criar o projeto no Supabase

1. Crie um projeto em <https://supabase.com/dashboard>.
2. Em **Database → Extensions**, confira se `pg_net` e `pg_cron` estão ativadas (o script tenta ativar sozinho).
3. Abra o **SQL Editor**, cole todo o conteúdo de `supabase/schema.sql` e clique em **Run**.
   O script pode ser executado de novo depois (por exemplo, após uma atualização) sem perder dados.

### 2. Criar o administrador

1. Em **Authentication → Users → Add user → Create new user**, crie seu usuário com e-mail e senha (marque *Auto Confirm User*).
2. No **SQL Editor**, rode (trocando o e-mail):

   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'seu-email@exemplo.com';
   ```

3. Recomendado: em **Authentication → Sign In / Providers**, desative *Allow new users to sign up*, para ninguém criar conta sozinho.

### 3. Conectar o site

Em **Project Settings → API**, copie a *Project URL* e a *anon public key* para `js/config.js`:

```js
window.BD_CONFIG = {
  supabaseUrl: 'https://abcdefgh.supabase.co',
  supabaseAnonKey: 'eyJhbGciOi...',
};
```

A anon key é pública por natureza; quem protege os dados são as regras do `schema.sql`. **Nunca** coloque a `service_role` key no site.

### 4. Primeiro acesso ao painel

Abra `admin.html`, entre com o usuário admin e:

1. **Produtos** → confira os preços (os da tabela atual já vêm cadastrados).
2. **Vendedores** → cadastre cada vendedor com um PIN de 4 a 8 números (e o ID do Discord, se quiser que ele seja marcado nos avisos).
3. **Parcerias** → cadastre as organizações parceiras.
4. **Discord** → cole as URLs dos webhooks (Canal → Editar → Integrações → Webhooks → Novo webhook → Copiar URL), clique em **Testar** e salve.

## Segurança

- Os preços são recalculados **no banco** a cada venda; alterar o JavaScript no navegador não muda o valor registrado.
- O PIN é guardado criptografado (bcrypt). Após 5 tentativas erradas, o vendedor fica bloqueado por 15 minutos. Trocar o PIN no painel desbloqueia e encerra as sessões abertas.
- As URLs dos webhooks ficam só no banco, e quem envia as mensagens ao Discord é o próprio Supabase (`pg_net`).
- Vendas não são apagadas: o admin pode **cancelar** (sai dos relatórios) e reativar.

## Publicar no GitHub Pages

Publicado a partir da branch `main` (pasta raiz) em
<https://lorddarkspy.github.io/BlueDragons-Calc/>. Cada `git push` atualiza o site em cerca de um minuto.
Ao alterar um `.js` ou `.css`, aumente o `?v=` no HTML para evitar cache antigo.

## Testar localmente

```
python -m http.server 8000
```

e acesse `http://localhost:8000`.
