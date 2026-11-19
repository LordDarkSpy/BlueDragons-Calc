# Calculadora e Gestão de Vendas — Blue Dragons

Site estático (HTML/CSS/JS puro) hospedado no GitHub Pages, com banco de dados no **Supabase**.

Substitui a planilha "VENDAS MERCADO OCULTO" (abas SERRA, PENDRIVE, PAGAMENTO e Base Valores e Craft):

- **Calculadora** (`index.html`): o vendedor entra com a conta do **Discord**, escolhe **Pista** ou **Parceria**, monta o pedido e registra a venda (com uma tela de confirmação antes de gravar). Na parceria, o **cliente é o próprio parceiro**; na pista, o cliente é opcional. Perfis "só visualizar" simulam os valores sem registrar.
- **Ranking** (`ranking.html`): pódio e lista dos vendedores por total vendido, com a foto do Discord. Qualquer vendedor cadastrado vê; a comissão não aparece.
- **Painel** (`admin.html`): relatório semanal (totais, ranking, **pagamento dos vendedores** com o ID para pagamento e **craft usado**), histórico de vendas (cancelamento e exportação CSV), cadastro de **usuários**, parcerias, produtos, gestão de **perfis** e configuração do Discord.
- **Perfis de acesso** (aba Gestão, só o líder altera): cada perfil escolhe as páginas (Calculadora, Registrar vendas, Ranking, Painel), as abas do painel e as ações (cadastrar/editar parcerias, encerrar, pagar, cancelar vendas, usuários, produtos). Cada usuário recebe um perfil no cadastro, e um perfil também pode vir de um **cargo do Discord**. Na primeira execução do `schema.sql`, os acessos antigos por cargo viram perfis e todos os cadastros recebem o perfil **Vendedor**.
- **Novidades**: ao entrar, cada usuário vê o que mudou desde a última visita (preços, produtos e parcerias). O 🔔 no topo reabre a lista dos últimos 30 dias.
- **Discord**: cada venda registrada gera um aviso no canal; o relatório da semana anterior sai no dia e horário escolhidos na aba Discord (padrão: segunda às 09:00, Brasília), com embeds, logo e as imagens dos produtos. O botão **🧪 Enviar relatório simulado** manda um exemplo com dados fictícios. Os pagamentos podem ir para um **webhook próprio**.
- **Fórum de parceiros**: com o ID de uma categoria configurado, o bot cria um fórum por produto vendido pelas parcerias (arma, munição…) e mantém um post por parceria, atualizado quando ela muda e apagado quando é encerrada.

### Regras herdadas da planilha

- **Produtos**: já vêm cadastrados os 5 pendrives (Fajuto, Comum, Incomum, Raro e Especial) e Serra, Chave de Fenda, Silenciador de Sinal e Algema, com preço de pista, preço de parceria e craft (placas + plástico/metal por unidade). Dá para editar tudo no painel.
- **Comissão (PAGAMENTO)**: 15% sobre *quantidade × preço de parceria*, inclusive nas vendas de pista, igual à fórmula da planilha. O percentual pode ser mudado em **Painel → Discord** e vale para as vendas seguintes. A comissão de cada venda fica gravada, então mudar o percentual não altera vendas antigas.
- **Craft**: cada venda soma os materiais usados, e o relatório semanal mostra o total de placas, plástico e metal.

## Estrutura

```
index.html           Calculadora de venda
admin.html           Painel administrativo
ranking.html         Ranking de vendedores (semana, semana passada, mês e geral)
js/ranking.js        Lógica do ranking
css/style.css        Estilos (tema azul)
js/config.js         URL e anon key do Supabase  ← editar
js/comum.js          Funções compartilhadas
js/calculadora.js    Lógica da calculadora
js/admin.js          Lógica do painel
supabase/schema.sql  Banco: tabelas, regras de acesso (RLS), funções e agendamento
img/logo.png         Logo (Pixellab, usada sem alterações)
img/tabela_v1.png    Tabela de preços enviada aos clientes
img/produtos/*.svg   Ícones dos produtos (desenhos próprios; dá para trocar no painel)
img/produtos/*.png   Os mesmos ícones em PNG (o Discord não mostra SVG nos embeds)
```

Ao trocar a tabela de preços, salve com um nome novo (`tabela_v2.png`) e atualize `index.html` e `js/calculadora.js`, para o Discord não mostrar a imagem antiga em cache.

## Configuração (uma vez só)

### 1. Criar o projeto no Supabase

1. Crie um projeto em <https://supabase.com/dashboard>.
2. Em **Database → Extensions**, confira se `pg_net` e `pg_cron` estão ativadas (o script tenta ativar sozinho).
3. Abra o **SQL Editor**, cole todo o conteúdo de `supabase/schema.sql` e clique em **Run**.
   O script pode ser executado de novo depois (por exemplo, após uma atualização) sem perder dados.

### 2. Login com o Discord

1. Em <https://discord.com/developers/applications>, crie uma aplicação. Em **OAuth2**, copie o *Client ID* e o *Client Secret* e adicione o redirect `https://SEU-PROJETO.supabase.co/auth/v1/callback`.
2. No Supabase, em **Authentication → Sign In / Providers**:
   - ative **Discord** e cole o Client ID e o Secret;
   - desative **Email** (ninguém entra por e-mail);
   - deixe *Allow new users to sign up* **ligado**: o primeiro login pelo Discord cria a conta. Quem não estiver cadastrado na tabela de vendedores entra, mas não vê nem registra nada.
3. Em **Authentication → URL Configuration**, coloque o endereço do site em *Site URL* e adicione `https://SEU-USUARIO.github.io/BlueDragons-Calc/**` em *Redirect URLs*.
4. Cadastre o primeiro administrador no **SQL Editor** (troque o nome e o ID do Discord):

   ```sql
   insert into public.vendedores (nome, discord_id, admin)
   values ('Seu nome', '123456789012345678', true);
   ```

   Para descobrir o ID: Discord → Configurações → Avançado → Modo desenvolvedor; depois clique com o botão direito no seu nome → **Copiar ID do usuário**. Os próximos cadastros são feitos pelo painel.

### 2.1 Nomes do servidor do Discord (bot)

O site mostra o nome que cada pessoa usa **no servidor** do Discord. Quem busca esses nomes é o próprio Supabase, usando a credencial de um bot: **nenhum programa fica rodando nem precisa de hospedagem** (o bot aparece sempre offline no servidor, isso é normal).

1. No [Developer Portal](https://discord.com/developers/applications), abra a mesma aplicação do login → **Bot** → **Reset Token** e copie o token.
2. Em **OAuth2 → URL Generator**, marque só o escopo `bot` (nenhuma permissão), abra o link gerado e adicione o bot ao servidor.
3. No painel do site, aba **🔔 Discord** → *Nomes do servidor*: confira o **ID do servidor**, cole o **token do bot** e clique em **Salvar token**. O token vai para o cofre do Supabase (Vault) e não aparece mais no site.
4. Na aba **Vendedores**, clique em **🔄 Atualizar nomes do Discord**. Depois disso os nomes se atualizam sozinhos a cada 10 minutos e sempre que alguém é cadastrado.

#### Acesso ao painel por cargo

Na aba **🔔 Discord** → *Acesso ao painel por cargo*, clique em **Carregar cargos do servidor**, marque os cargos que podem usar o painel e salve. Quem tiver um desses cargos (e estiver cadastrado e ativo em Vendedores) passa a ver o painel; ao perder o cargo no Discord, perde o acesso no próximo login ou em até 10 minutos. A opção *Administrador manual* do cadastro continua valendo para quem precisa de acesso sem o cargo.

Para trocar de servidor (por exemplo, sair do servidor de testes), use **🔁 Trocar de servidor** na aba Discord: o painel pede confirmação, troca o ID e mostra o link de convite do bot já apontando para o novo servidor (dá para abrir ou copiar e mandar para quem administra o servidor). Depois, atualize os nomes e escolha de novo os cargos dos perfis.

#### Fórum de parceiros

1. Em **Database → Extensions**, ative a extensão **http** (o fórum edita posts, e o `pg_net` não faz isso) e rode o `schema.sql` de novo.
2. Use o link de convite da aba Discord (ele já pede as permissões: Ver canais, Gerenciar canais, Enviar mensagens, Enviar mensagens em tópicos, Gerenciar tópicos, Inserir links e Ler histórico), ou dê essas permissões ao bot na categoria.
3. Crie uma categoria no servidor, copie o ID (botão direito → Copiar ID do canal), cole em **ID da categoria de parceiros**, salve e clique em **🔄 Sincronizar agora**. Depois disso, o fórum se atualiza sozinho a cada minuto e logo após salvar uma parceria.

As imagens das parcerias ficam no bucket privado e não vão para o fórum.

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

Abra `admin.html`, clique em **Entrar com Discord** e:

1. **Produtos** → confira os preços (os da tabela atual já vêm cadastrados).
2. **Gestão** → confira os perfis (Vendedor, Só calculadora, Só parcerias…) e ligue cargos do Discord a eles, se quiser.
3. **Usuários** → cadastre cada pessoa com o **ID do Discord** (é com ele que ela entra), o **ID para pagamento** e o **perfil**. Marque *Administrador manual / líder* só para quem gerencia tudo.
4. **Parcerias** → cadastre as organizações parceiras.
5. **Discord** → cole as URLs dos webhooks (Canal → Editar → Integrações → Webhooks → Novo webhook → Copiar URL), clique em **Testar** e salve.

## Segurança

- Os preços são recalculados **no banco** a cada venda; alterar o JavaScript no navegador não muda o valor registrado.
- O login é feito pelo Discord, e o banco reconhece a pessoa pelo ID do Discord que o próprio Supabase grava no login (não dá para se passar por outro vendedor). Desativar alguém no painel corta o acesso na hora.
- Um administrador não consegue tirar o próprio acesso, para o painel nunca ficar sem admin.
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
