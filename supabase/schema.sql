-- =============================================================================
-- Blue Dragons — Calculadora e Gestão de Vendas
-- Rode este arquivo inteiro no Supabase: Dashboard → SQL Editor → New query.
-- Pode ser executado de novo sem perder dados (idempotente).
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net;
create extension if not exists pg_cron;
-- Chamadas síncronas à API do Discord (fórum de parceiros: o pg_net não faz PATCH).
do $$
begin
  create extension if not exists http with schema extensions;
exception when others then
  raise warning 'Extensão http indisponível (Database → Extensions → http): o fórum de parceiros não vai funcionar. %', sqlerrm;
end $$;

-- -----------------------------------------------------------------------------
-- Tabelas
-- -----------------------------------------------------------------------------

-- Usuários do Supabase Auth que podem acessar o painel administrativo.
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  criado_em timestamptz not null default now()
);

create table if not exists public.produtos (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(trim(nome)) between 1 and 60),
  icone text not null default '📦',
  preco_com_parceria numeric(12, 2) not null default 0 check (preco_com_parceria >= 0),
  preco_sem_parceria numeric(12, 2) not null default 0 check (preco_sem_parceria >= 0),
  categoria text not null default 'Geral',
  -- Materiais de craft por unidade (aba "Base Valores e Craft" da planilha).
  craft_placa int not null default 0 check (craft_placa >= 0),
  craft_material int not null default 0 check (craft_material >= 0),
  material_nome text not null default 'Plástico',
  ordem int not null default 0,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create table if not exists public.parcerias (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(trim(nome)) between 1 and 60),
  responsavel text,
  observacoes text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

-- Vendedores e administradores. O login é feito com o Discord: a pessoa é
-- reconhecida pelo ID do Discord cadastrado aqui.
create table if not exists public.vendedores (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(trim(nome)) between 2 and 40),
  discord_id text not null check (discord_id ~ '^\d{17,20}$'),
  admin boolean not null default false,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

-- Migração da versão com PIN (o login agora é pelo Discord).
alter table public.vendedores add column if not exists admin boolean not null default false;
alter table public.vendedores drop column if exists pin_hash;
alter table public.vendedores drop column if exists tentativas_falhas;
alter table public.vendedores drop column if exists bloqueado_ate;
alter table public.vendedores alter column discord_id set not null;
create unique index if not exists vendedores_discord_id_idx on public.vendedores (discord_id);
-- Nome que a pessoa usa no servidor do Discord (preenchido pelo bot, ver "Nomes do Discord").
alter table public.vendedores add column if not exists nome_discord text;
alter table public.vendedores add column if not exists no_servidor boolean;
alter table public.vendedores add column if not exists nome_discord_em timestamptz;
-- IDs dos cargos que a pessoa tem no servidor (também preenchido pelo bot).
alter table public.vendedores add column if not exists cargos text[] not null default '{}';
-- Foto do Discord (do servidor, se tiver; senão a da conta). Usada no ranking.
alter table public.vendedores add column if not exists avatar text;

-- Imagem do produto na calculadora (caminho no site ou URL). Sem imagem, usa o ícone (emoji).
alter table public.produtos add column if not exists imagem text;
drop function if exists public.listar_vendedores();
drop function if exists public.entrar_vendedor(uuid, text);
drop function if exists public.sair_vendedor(text);
drop function if exists public.registrar_venda(text, jsonb, uuid, text, text);
drop function if exists public.registrar_venda(text, jsonb, uuid, text);
drop function if exists public.minha_semana(text);
drop function if exists public.salvar_vendedor(uuid, text, text, boolean, text);
drop function if exists public._vendedor_da_sessao(text);
drop table if exists public.vendedor_sessoes;

create table if not exists public.vendas (
  id uuid primary key default gen_random_uuid(),
  numero bigint generated always as identity,
  criado_em timestamptz not null default now(),
  vendedor_id uuid not null references public.vendedores (id) on delete restrict,
  vendedor_nome text not null,
  parceria_id uuid references public.parcerias (id) on delete set null,
  parceria_nome text,
  com_parceria boolean not null default false,
  cliente text,
  total numeric(12, 2) not null check (total >= 0),
  comissao numeric(12, 2) not null default 0,
  observacao text,
  cancelada boolean not null default false,
  cancelada_em timestamptz
);

create index if not exists vendas_criado_em_idx on public.vendas (criado_em);

-- Cancelamento exige justificativa (função cancelar_venda).
alter table public.vendas add column if not exists cancelada_motivo text;
alter table public.vendas add column if not exists cancelada_por text;
create index if not exists vendas_vendedor_idx on public.vendas (vendedor_id);

create table if not exists public.venda_itens (
  id bigint generated always as identity primary key,
  venda_id uuid not null references public.vendas (id) on delete cascade,
  produto_id uuid references public.produtos (id) on delete set null,
  produto_nome text not null,
  icone text,
  quantidade int not null check (quantidade > 0),
  preco_unitario numeric(12, 2) not null,
  subtotal numeric(12, 2) not null,
  comissao numeric(12, 2) not null default 0,
  craft_placa int not null default 0,
  craft_material int not null default 0,
  material_nome text
);

create index if not exists venda_itens_venda_idx on public.venda_itens (venda_id);

-- Configuração única (linha id = 1): webhooks do Discord e opções gerais.
create table if not exists public.configuracoes (
  id int primary key default 1 check (id = 1),
  nome_organizacao text not null default 'Blue Dragons',
  moeda text not null default 'R$ ',
  webhook_vendas text,
  webhook_relatorios text,
  notificar_vendas boolean not null default true,
  relatorio_automatico boolean not null default true,
  -- Pagamento do vendedor: % sobre (quantidade × preço de parceria), como na aba PAGAMENTO.
  percentual_comissao numeric(5, 4) not null default 0.15 check (percentual_comissao between 0 and 1),
  atualizado_em timestamptz not null default now()
);

-- Servidor do Discord de onde vêm os nomes dos vendedores.
alter table public.configuracoes add column if not exists discord_servidor_id text
  check (discord_servidor_id is null or discord_servidor_id ~ '^\d{17,20}$');

insert into public.configuracoes (id, discord_servidor_id) values (1, '1549634672877633588') on conflict (id) do nothing;
update public.configuracoes set discord_servidor_id = '1549634672877633588' where id = 1 and discord_servidor_id is null;

-- Cargos do servidor que dão acesso ao painel administrativo.
alter table public.configuracoes add column if not exists cargos_admin text[] not null default '{}';

-- Permissões das ações de impacto, por cargo do servidor: {"encerrar_parceria": ["<id do cargo>", ...], ...}.
-- O líder (administrador manual) tem todas e é quem gerencia esta lista.
alter table public.configuracoes add column if not exists permissoes jsonb not null default '{}'
  check (jsonb_typeof(permissoes) = 'object');

-- Pedidos feitos ao Discord (pg_net responde de forma assíncrona).
create table if not exists public.discord_pedidos (
  request_id bigint primary key,
  vendedor_id uuid references public.vendedores (id) on delete cascade,
  tipo text not null default 'membro',
  criado_em timestamptz not null default now()
);
alter table public.discord_pedidos add column if not exists tipo text not null default 'membro';
alter table public.discord_pedidos alter column vendedor_id drop not null;

-- Cargos do servidor configurado (lista usada no painel para escolher quem é admin).
create table if not exists public.discord_cargos (
  id text primary key,
  nome text not null,
  cor int not null default 0,
  posicao int not null default 0,
  atualizado_em timestamptz not null default now()
);

-- DEV: administrador do site (Discord e opções gerais). Só é definido direto no banco
-- (SQL Editor do Supabase); o site não consegue ler nem alterar esta tabela:
--   insert into public.devs (discord_id) values ('<ID do Discord>');
create table if not exists public.devs (
  discord_id text primary key check (discord_id ~ '^\d{17,20}$'),
  criado_em timestamptz not null default now()
);
alter table public.devs enable row level security;
revoke all on public.devs from anon, authenticated;

-- Cadastro completo das parcerias.
-- produtos: o que a organização parceira vende (texto, com a grafia padronizada entre as parcerias).
-- A primeira versão guardava produtos do nosso catálogo (uuid[]); troca pelo formato novo.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'parcerias' and column_name = 'produtos' and udt_name = '_uuid') then
    alter table public.parcerias drop column produtos;
  end if;
end $$;
alter table public.parcerias add column if not exists produtos text[] not null default '{}';
alter table public.parcerias add column if not exists localizacao text check (localizacao is null or length(localizacao) <= 200);
alter table public.parcerias add column if not exists img_localizacao text;  -- caminhos no Storage (bucket "parcerias")
alter table public.parcerias add column if not exists img_banner text;
alter table public.parcerias add column if not exists img_cores text;        -- cores da organização: carro / uniforme (opcional)
alter table public.parcerias add column if not exists feita_por_id uuid references public.vendedores (id) on delete set null;
alter table public.parcerias add column if not exists feita_por_nome text;
alter table public.parcerias add column if not exists encerrada_em timestamptz;
alter table public.parcerias add column if not exists encerrada_motivo text;
alter table public.parcerias add column if not exists encerrada_por text;

-- Histórico de cada parceria (criação, edições, encerramento, reativação).
create table if not exists public.parceria_historico (
  id bigint generated always as identity primary key,
  parceria_id uuid not null references public.parcerias (id) on delete cascade,
  tipo text not null check (tipo in ('criada', 'editada', 'encerrada', 'reativada')),
  descricao text,
  autor text,
  criado_em timestamptz not null default now()
);
create index if not exists parceria_historico_idx on public.parceria_historico (parceria_id, criado_em);

-- Parcerias cadastradas antes do histórico existir ganham o registro de criação (com a data original).
insert into public.parceria_historico (parceria_id, tipo, descricao, criado_em)
select p.id, 'criada', 'Parceria cadastrada.', p.criado_em from public.parcerias p
where not exists (select 1 from public.parceria_historico h where h.parceria_id = p.id);

-- Imagens das parcerias: abrem por link direto (para aparecerem no fórum do Discord), mas ninguém
-- consegue listar o bucket; só quem acessa o painel vê a lista e só quem edita parcerias envia.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('parcerias', 'parcerias', true, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Pagamentos das comissões semanais aos vendedores.
-- Pode haver mais de um por semana (ex.: uma venda entrou depois do pagamento
-- e a diferença foi paga em seguida).
create table if not exists public.pagamentos (
  id uuid primary key default gen_random_uuid(),
  vendedor_id uuid not null references public.vendedores (id) on delete restrict,
  vendedor_nome text not null,
  semana_inicio date not null check (extract(isodow from semana_inicio) = 1),
  valor numeric(12, 2) not null check (valor > 0),
  observacao text check (observacao is null or length(observacao) <= 300),
  pago_por_discord text,
  pago_por_nome text,
  pago_em timestamptz not null default now()
);
create index if not exists pagamentos_semana_idx on public.pagamentos (semana_inicio, vendedor_id);

-- Usuários: ID usado para receber o pagamento das comissões e última vez que viu as novidades.
alter table public.vendedores add column if not exists id_pagamento text check (id_pagamento is null or length(id_pagamento) <= 40);
alter table public.vendedores add column if not exists novidades_vistas_em timestamptz;

-- Perfis de acesso (Vendedor, Só calculadora, Só parcerias…). O líder cria e edita na aba Gestão.
-- permissoes: o que o perfil pode ver e fazer (ver _permissoes_validas).
-- cargos: cargos do Discord que dão este perfil automaticamente (além do perfil do cadastro).
create table if not exists public.perfis (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(btrim(nome)) between 2 and 40),
  permissoes text[] not null default '{}',
  cargos text[] not null default '{}',
  ordem int not null default 0,
  criado_em timestamptz not null default now()
);
create unique index if not exists perfis_nome_idx on public.perfis (lower(nome));
alter table public.vendedores add column if not exists perfil_id uuid references public.perfis (id) on delete set null;

-- Novidades mostradas ao entrar no site (preços, produtos e parcerias).
create table if not exists public.novidades (
  id bigint generated always as identity primary key,
  tipo text not null check (tipo in ('preco', 'produto', 'parceria')),
  titulo text not null,
  descricao text,
  criado_em timestamptz not null default now()
);
create index if not exists novidades_criado_em_idx on public.novidades (criado_em);
-- publicada = false: aviso automático (produto/parceria) esperando quem fez a alteração decidir se notifica.
-- para_vendedor / para_cargo: só aquele usuário / só quem tem aquele cargo do Discord (os dois vazios = todos).
alter table public.novidades add column if not exists publicada boolean not null default true;
alter table public.novidades add column if not exists autor_uid uuid;
alter table public.novidades add column if not exists autor text;
alter table public.novidades add column if not exists ref text;
alter table public.novidades add column if not exists para_vendedor uuid references public.vendedores (id) on delete cascade;
alter table public.novidades add column if not exists para_cargo text;
alter table public.novidades drop constraint if exists novidades_tipo_check;
alter table public.novidades add constraint novidades_tipo_check
  check (tipo in ('preco', 'produto', 'parceria', 'pagamento', 'mensagem'));
create index if not exists novidades_pendentes_idx on public.novidades (autor_uid) where not publicada;

-- Discord: webhook só para os pagamentos, horário do relatório, endereço do site (imagens) e
-- categoria onde o bot mantém os fóruns de parceiros.
alter table public.configuracoes add column if not exists webhook_pagamentos text;
alter table public.configuracoes add column if not exists relatorio_dia int not null default 1 check (relatorio_dia between 1 and 7); -- 1 = segunda
alter table public.configuracoes add column if not exists relatorio_hora time not null default '09:00';
alter table public.configuracoes add column if not exists relatorio_ultima_semana date;
alter table public.configuracoes add column if not exists site_url text not null default 'https://lorddarkspy.github.io/BlueDragons-Calc/'
  check (site_url ~ '^https://');
-- Endereço do projeto Supabase (link público das imagens das parcerias no Discord).
alter table public.configuracoes add column if not exists supabase_url text not null default 'https://smvggtvarsinaqlflrqt.supabase.co'
  check (supabase_url ~ '^https://');
alter table public.configuracoes add column if not exists discord_categoria_parceiros text
  check (discord_categoria_parceiros is null or discord_categoria_parceiros ~ '^\d{17,20}$');

-- Fórum de parceiros: um fórum por produto vendido (arma, munição…) e um post por parceria.
create table if not exists public.discord_foruns (
  chave text primary key,          -- nome do produto normalizado (sem acento, minúsculo)
  nome text not null,
  canal_id text,
  atualizado_em timestamptz not null default now()
);
create table if not exists public.discord_posts (
  parceria_id uuid not null,
  chave text not null,
  thread_id text not null,
  nome text,
  hash text,
  atualizado_em timestamptz not null default now(),
  primary key (parceria_id, chave)
);
-- Estado da sincronização (última leitura dos canais, último erro…).
create table if not exists public.discord_estado (
  chave text primary key,
  valor text,
  em timestamptz not null default now()
);

-- Produtos iniciais (tabela de preços do Mercado Oculto). Só entram se a tabela estiver vazia.
insert into public.produtos (nome, icone, categoria, preco_com_parceria, preco_sem_parceria, craft_placa, craft_material, material_nome, ordem)
select * from (values
  ('Pendrive Fajuto',      '💾', 'Pendrives',   3000,  3600, 14, 14, 'Plástico', 10),
  ('Pendrive Comum',       '💾', 'Pendrives',   4200,  4800, 20, 20, 'Plástico', 20),
  ('Pendrive Incomum',     '💚', 'Pendrives',   6600,  7200, 24, 24, 'Plástico', 30),
  ('Pendrive Raro',        '❤️', 'Pendrives',  14400, 17280, 28, 28, 'Plástico', 40),
  ('Pendrive Especial',    '🖤', 'Pendrives',  30000, 31200, 34, 34, 'Plástico', 50),
  ('Serra',                '🪚', 'Ferramentas', 4800,  5400, 10, 10, 'Metal',    60),
  ('Chave de Fenda',       '🪛', 'Ferramentas', 3000,  3500,  8,  8, 'Metal',    70),
  ('Silenciador de Sinal', '📡', 'Ferramentas',10000, 11500, 15, 20, 'Metal',    80),
  ('Algema',               '⛓️', 'Ferramentas', 3600,  4200, 30, 30, 'Metal',    90)
) as p (nome, icone, categoria, preco_com_parceria, preco_sem_parceria, craft_placa, craft_material, material_nome, ordem)
where not exists (select 1 from public.produtos);

-- Craft em lista: [{"material": "Ferro", "quantidade": 1}, ...] por unidade do produto.
alter table public.produtos add column if not exists craft jsonb not null default '[]'
  check (jsonb_typeof(craft) = 'array');
alter table public.venda_itens add column if not exists craft jsonb not null default '[]';  -- total usado na linha

-- Para que serve o produto (aparece ao passar o mouse ou clicar na imagem, na calculadora).
alter table public.produtos add column if not exists serve_para text check (serve_para is null or length(serve_para) <= 300);

-- Converte o formato antigo (placas + um material) e zera as colunas antigas (roda uma vez só).
update public.produtos p set
  craft = coalesce((
    select jsonb_agg(jsonb_build_object('material', m.material, 'quantidade', m.quantidade) order by m.ord)
    from (values (1, 'Placa', p.craft_placa), (2, coalesce(nullif(btrim(p.material_nome), ''), 'Material'), p.craft_material)) as m (ord, material, quantidade)
    where m.quantidade > 0), '[]'::jsonb),
  craft_placa = 0, craft_material = 0
where p.craft = '[]'::jsonb and (p.craft_placa > 0 or p.craft_material > 0);

-- Imagens próprias dos produtos iniciais (só preenche se ainda estiver vazio).
update public.produtos p set imagem = 'img/produtos/' || i.arquivo
from (values
  ('Pendrive Fajuto', 'pendrive-fajuto.svg'), ('Pendrive Comum', 'pendrive-comum.svg'),
  ('Pendrive Incomum', 'pendrive-incomum.svg'), ('Pendrive Raro', 'pendrive-raro.svg'),
  ('Pendrive Especial', 'pendrive-especial.svg'), ('Serra', 'serra.svg'),
  ('Chave de Fenda', 'chave-de-fenda.svg'), ('Silenciador de Sinal', 'silenciador-de-sinal.svg'),
  ('Algema', 'algema.svg')
) as i (nome, arquivo)
where p.nome = i.nome and p.imagem is null;

-- -----------------------------------------------------------------------------
-- Permissões e RLS
-- -----------------------------------------------------------------------------

-- ID do Discord do usuário logado. Vem de auth.identities, que é preenchida pelo
-- próprio Supabase no login (os metadados do usuário não são usados porque o
-- usuário consegue editá-los).
create or replace function public._discord_id()
returns text
language sql stable security definer
set search_path = public
as $$
  select provider_id from auth.identities
  where user_id = auth.uid() and provider = 'discord'
  limit 1;
$$;

-- Cadastro (ativo) do usuário logado, ou nulo se ele não estiver cadastrado.
create or replace function public._vendedor_atual()
returns public.vendedores
language sql stable security definer
set search_path = public
as $$
  select * from public.vendedores
  where ativo and discord_id = public._discord_id();
$$;

create or replace function public._e_dev()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.devs where discord_id = public._discord_id());
$$;

-- Líder: administrador manual (marcado no cadastro), da tabela admins ou DEV. Tem todas as permissões.
create or replace function public._e_lider()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select public._e_dev()
      or exists (select 1 from public.admins where user_id = auth.uid())
      or exists (select 1 from public.vendedores v where v.ativo and v.admin and v.discord_id = public._discord_id());
$$;

-- Tudo o que um perfil pode liberar: páginas, abas do painel e ações.
create or replace function public._permissoes_validas()
returns text[]
language sql immutable
as $$ select array[
  'ver_ranking', 'ver_calculadora', 'registrar_venda', 'ver_painel',
  'ver_relatorio', 'ver_vendas', 'ver_usuarios', 'ver_parcerias', 'ver_produtos', 'ver_gestao',
  'editar_parcerias', 'encerrar_parceria', 'registrar_pagamento', 'cancelar_venda', 'gerenciar_vendedores', 'gerenciar_produtos', 'enviar_notificacoes'] $$;

-- Permissões do usuário logado: o líder tem todas; os outros, as do perfil do cadastro
-- somadas às dos perfis ligados a cargos que a pessoa tem no Discord.
create or replace function public._minhas_permissoes()
returns text[]
language sql stable security definer
set search_path = public
as $$
  select case when public._e_lider() then public._permissoes_validas()
  else coalesce((
    select array_agg(distinct x)
    from public.vendedores v
    join public.perfis pf on pf.id = v.perfil_id or pf.cargos && v.cargos
    cross join unnest(pf.permissoes) x
    where v.ativo and v.discord_id = public._discord_id()
  ), '{}') end;
$$;

create or replace function public.tem_permissao(p_permissao text)
returns boolean
language sql stable security definer
set search_path = public
as $$ select p_permissao = any (public._minhas_permissoes()); $$;

-- Acesso ao painel (admin.html).
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$ select public.tem_permissao('ver_painel'); $$;

-- Perfis: limpa o nome, aceita só permissões conhecidas e IDs de cargo válidos.
create or replace function public._perfil_antes()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  new.nome := regexp_replace(btrim(coalesce(new.nome, '')), '\s+', ' ', 'g');
  new.permissoes := coalesce(array(select distinct x from unnest(coalesce(new.permissoes, '{}')) x
                                   where x = any (public._permissoes_validas()) order by 1), '{}');
  new.cargos := coalesce(array(select distinct x from unnest(coalesce(new.cargos, '{}')) x where x ~ '^\d{17,20}$' order by 1), '{}');
  return new;
end;
$$;
drop trigger if exists perfil_antes on public.perfis;
create trigger perfil_antes before insert or update on public.perfis
  for each row execute function public._perfil_antes();

-- Migração (uma vez só): cria os perfis iniciais a partir do acesso por cargo e das permissões antigas.
do $$
declare
  c public.configuracoes;
  v_vendedor uuid;
  v_cargo text;
  v_perms text[];
  v_nome text;
begin
  if exists (select 1 from public.perfis) then return; end if;
  insert into public.perfis (nome, permissoes, ordem)
  values ('Vendedor', array['ver_ranking', 'ver_calculadora', 'registrar_venda'], 10) returning id into v_vendedor;
  insert into public.perfis (nome, permissoes, ordem) values ('Só calculadora (visualizar)', array['ver_calculadora'], 20);
  insert into public.perfis (nome, permissoes, ordem) values ('Só parcerias (visualizar)', array['ver_painel', 'ver_parcerias'], 30);
  select * into c from public.configuracoes where id = 1;
  for v_cargo in
    select distinct x from (
      select unnest(coalesce(c.cargos_admin, '{}')) as x
      union select jsonb_array_elements_text(e.value) from jsonb_each(coalesce(c.permissoes, '{}'::jsonb)) e
    ) s where x ~ '^\d{17,20}$'
  loop
    v_perms := array['ver_ranking', 'ver_calculadora', 'registrar_venda'];
    if v_cargo = any (coalesce(c.cargos_admin, '{}')) then
      v_perms := v_perms || array['ver_painel', 'ver_relatorio', 'ver_vendas', 'ver_usuarios', 'ver_parcerias', 'ver_produtos', 'editar_parcerias'];
    end if;
    v_perms := v_perms || coalesce(array(select e.key from jsonb_each(coalesce(c.permissoes, '{}'::jsonb)) e where e.value ? v_cargo), '{}');
    v_nome := btrim(coalesce((select nome from public.discord_cargos where id = v_cargo), ''));
    if length(v_nome) < 2 then v_nome := 'Cargo ' || coalesce(nullif(v_nome, ''), right(v_cargo, 6)); end if;
    v_nome := left(v_nome, 40);
    if exists (select 1 from public.perfis where lower(nome) = lower(v_nome)) then
      v_nome := left(v_nome, 32) || ' ' || right(v_cargo, 6);
    end if;
    insert into public.perfis (nome, permissoes, cargos, ordem) values (v_nome, v_perms, array[v_cargo], 100);
  end loop;
  update public.vendedores set perfil_id = v_vendedor where perfil_id is null;
end $$;

-- Produtos: categoria e materiais do craft reaproveitam a grafia já usada (ignorando maiúsculas),
-- tiram espaços sobrando e juntam materiais repetidos.
create or replace function public._produto_antes()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  e jsonb;
  v_mat text;
  v_qtd int;
  v_padrao text;
  v_lista jsonb := '[]'::jsonb;
  v_idx int;
begin
  new.serve_para := nullif(btrim(coalesce(new.serve_para, '')), '');
  new.categoria := regexp_replace(btrim(coalesce(new.categoria, '')), '\s+', ' ', 'g');
  if new.categoria = '' then new.categoria := 'Geral'; end if;
  if length(new.categoria) > 30 then raise exception 'A categoria pode ter no máximo 30 caracteres.'; end if;
  select categoria into v_padrao from public.produtos where id <> new.id and lower(categoria) = lower(new.categoria) limit 1;
  new.categoria := coalesce(v_padrao, new.categoria);

  if jsonb_typeof(coalesce(new.craft, '[]'::jsonb)) <> 'array' then raise exception 'Craft inválido.'; end if;
  for e in select * from jsonb_array_elements(coalesce(new.craft, '[]'::jsonb)) loop
    v_mat := regexp_replace(btrim(coalesce(e->>'material', '')), '\s+', ' ', 'g');
    continue when v_mat = '';
    if length(v_mat) > 30 then raise exception 'Nome de material muito longo (máximo 30 caracteres).'; end if;
    begin
      v_qtd := (e->>'quantidade')::int;
    exception when others then
      raise exception 'Quantidade inválida para o material %.', v_mat;
    end;
    if v_qtd is null or v_qtd < 1 or v_qtd > 9999 then raise exception 'A quantidade de % deve ser de 1 a 9999.', v_mat; end if;
    v_padrao := null;
    select m->>'material' into v_padrao
    from public.produtos p2, jsonb_array_elements(p2.craft) m
    where p2.id <> new.id and lower(m->>'material') = lower(v_mat) limit 1;
    v_mat := coalesce(v_padrao, v_mat);
    -- junta o mesmo material repetido
    v_idx := null;
    select (ord - 1)::int into v_idx from jsonb_array_elements(v_lista) with ordinality as x (m, ord)
    where lower(m->>'material') = lower(v_mat);
    if v_idx is null then
      v_lista := v_lista || jsonb_build_array(jsonb_build_object('material', v_mat, 'quantidade', v_qtd));
    else
      v_lista := jsonb_set(v_lista, array[v_idx::text, 'quantidade'], to_jsonb(((v_lista->v_idx->>'quantidade')::int + v_qtd)));
    end if;
  end loop;
  if jsonb_array_length(v_lista) > 15 then raise exception 'Use no máximo 15 materiais no craft.'; end if;
  new.craft := v_lista;
  return new;
end;
$$;
drop trigger if exists produto_antes on public.produtos;
create trigger produto_antes before insert or update on public.produtos
  for each row execute function public._produto_antes();

alter table public.admins enable row level security;
alter table public.produtos enable row level security;
alter table public.parcerias enable row level security;
alter table public.vendedores enable row level security;
alter table public.vendas enable row level security;
alter table public.venda_itens enable row level security;
alter table public.configuracoes enable row level security;

-- Recomeça as permissões do zero para os papéis usados pelo site.
revoke all on public.admins, public.produtos, public.parcerias, public.vendedores,
  public.vendas, public.venda_itens, public.configuracoes
  from anon, authenticated;

-- Produtos e parcerias: leitura pública dos ativos; admin gerencia tudo.
-- Visitantes só veem nome/status das parcerias (o resto do cadastro é interno).
grant select on public.produtos to anon, authenticated;
grant select (id, nome, ativo) on public.parcerias to anon;
grant select on public.parcerias to authenticated;
grant insert, update, delete on public.produtos to authenticated;
-- Ativar/encerrar só pelas funções encerrar_parceria / reativar_parceria (que exigem motivo e registram histórico).
grant insert (nome, responsavel, observacoes, produtos, localizacao, img_localizacao, img_banner, img_cores, feita_por_id, feita_por_nome),
  update (nome, responsavel, observacoes, produtos, localizacao, img_localizacao, img_banner, img_cores, feita_por_id, feita_por_nome)
  on public.parcerias to authenticated;
revoke delete on public.parcerias from authenticated;

alter table public.parceria_historico enable row level security;
revoke all on public.parceria_historico from anon, authenticated;
grant select on public.parceria_historico to authenticated;
drop policy if exists parceria_historico_admin on public.parceria_historico;
create policy parceria_historico_admin on public.parceria_historico for select to authenticated
  using (public.tem_permissao('ver_parcerias'));

drop policy if exists parcerias_imagens_ler on storage.objects;
create policy parcerias_imagens_ler on storage.objects for select to authenticated
  using (bucket_id = 'parcerias' and public.is_admin());
drop policy if exists parcerias_imagens_enviar on storage.objects;
create policy parcerias_imagens_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'parcerias' and public.tem_permissao('editar_parcerias'));
drop policy if exists parcerias_imagens_alterar on storage.objects;
create policy parcerias_imagens_alterar on storage.objects for update to authenticated
  using (bucket_id = 'parcerias' and public.tem_permissao('editar_parcerias'))
  with check (bucket_id = 'parcerias' and public.tem_permissao('editar_parcerias'));
drop policy if exists parcerias_imagens_apagar on storage.objects;
create policy parcerias_imagens_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'parcerias' and public.tem_permissao('editar_parcerias'));

-- Perfis: quem acessa o painel lê (para o cadastro de usuários); só o líder cria, altera e apaga.
alter table public.perfis enable row level security;
revoke all on public.perfis from anon, authenticated;
grant select, insert, update, delete on public.perfis to authenticated;
drop policy if exists perfis_leitura on public.perfis;
create policy perfis_leitura on public.perfis for select to authenticated using (public.is_admin());
drop policy if exists perfis_lider on public.perfis;
create policy perfis_lider on public.perfis for all to authenticated
  using (public._e_lider()) with check (public._e_lider());

-- Novidades, fóruns e estado do Discord: só pelas funções.
alter table public.novidades enable row level security;
revoke all on public.novidades from anon, authenticated;
alter table public.discord_foruns enable row level security;
revoke all on public.discord_foruns from anon, authenticated;
alter table public.discord_posts enable row level security;
revoke all on public.discord_posts from anon, authenticated;
alter table public.discord_estado enable row level security;
revoke all on public.discord_estado from anon, authenticated;

drop policy if exists produtos_leitura on public.produtos;
create policy produtos_leitura on public.produtos for select
  using (ativo or public.is_admin());
drop policy if exists produtos_admin on public.produtos;
create policy produtos_admin on public.produtos for all to authenticated
  using (public.tem_permissao('gerenciar_produtos')) with check (public.tem_permissao('gerenciar_produtos'));

drop policy if exists parcerias_leitura on public.parcerias;
create policy parcerias_leitura on public.parcerias for select
  using (ativo or public.is_admin());
drop policy if exists parcerias_admin on public.parcerias;
drop policy if exists parcerias_editar on public.parcerias;
create policy parcerias_editar on public.parcerias for insert to authenticated
  with check (public.tem_permissao('editar_parcerias'));
drop policy if exists parcerias_alterar on public.parcerias;
create policy parcerias_alterar on public.parcerias for update to authenticated
  using (public.tem_permissao('editar_parcerias')) with check (public.tem_permissao('editar_parcerias'));

-- Usuários: só quem acessa o painel lê. Criação/edição via RPC salvar_vendedor.
grant select (id, nome, discord_id, admin, ativo, criado_em, nome_discord, no_servidor, nome_discord_em, cargos, avatar, id_pagamento, perfil_id) on public.vendedores to authenticated;
alter table public.discord_pedidos enable row level security;
revoke all on public.discord_pedidos from anon, authenticated;
alter table public.discord_cargos enable row level security;
revoke all on public.discord_cargos from anon, authenticated;
grant select on public.discord_cargos to authenticated;
drop policy if exists discord_cargos_admin on public.discord_cargos;
create policy discord_cargos_admin on public.discord_cargos for select to authenticated
  using (public.is_admin());
drop policy if exists vendedores_admin on public.vendedores;
create policy vendedores_admin on public.vendedores for select to authenticated
  using (public.is_admin());

-- Vendas: só o admin lê. Registro pela função registrar_venda; cancelamento só pela
-- função cancelar_venda (exige justificativa e a permissão "cancelar_venda").
grant select on public.vendas, public.venda_itens to authenticated;
drop policy if exists vendas_admin_leitura on public.vendas;
create policy vendas_admin_leitura on public.vendas for select to authenticated
  using (public.tem_permissao('ver_vendas'));
drop policy if exists vendas_admin_update on public.vendas;
drop policy if exists venda_itens_admin on public.venda_itens;
create policy venda_itens_admin on public.venda_itens for select to authenticated
  using (public.tem_permissao('ver_vendas'));

-- Pagamentos: quem vê o relatório lê. Registro somente pela função registrar_pagamento.
alter table public.pagamentos enable row level security;
revoke all on public.pagamentos from anon, authenticated;
grant select on public.pagamentos to authenticated;
drop policy if exists pagamentos_admin on public.pagamentos;
create policy pagamentos_admin on public.pagamentos for select to authenticated
  using (public.tem_permissao('ver_relatorio'));

-- Configurações: os admins leem; só o líder altera (Discord, cargos de acesso e permissões).
grant select, update on public.configuracoes to authenticated;
drop policy if exists configuracoes_admin on public.configuracoes;
create policy configuracoes_admin on public.configuracoes for select to authenticated
  using (public.is_admin());
drop policy if exists configuracoes_lider on public.configuracoes;
create policy configuracoes_lider on public.configuracoes for update to authenticated
  using (public._e_lider()) with check (public._e_lider());

create or replace function public._configuracoes_antes()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  -- Pelo site (usuário logado): fora a gestão (permissões, cargos de acesso, nome, moeda e comissão), tudo é do DEV. (Jobs do banco não têm usuário.)
  if auth.uid() is not null and not public._e_dev()
     and (to_jsonb(new) - 'permissoes' - 'cargos_admin' - 'nome_organizacao' - 'moeda' - 'percentual_comissao' - 'atualizado_em')
       is distinct from (to_jsonb(old) - 'permissoes' - 'cargos_admin' - 'nome_organizacao' - 'moeda' - 'percentual_comissao' - 'atualizado_em') then
    raise exception 'Só o DEV pode alterar as configurações do Discord e do site.';
  end if;
  -- Gestão (líder): permissões, cargos que acessam o painel, nome da organização, moeda e comissão.
  if auth.uid() is not null and (new.permissoes is distinct from old.permissoes or new.cargos_admin is distinct from old.cargos_admin
       or new.nome_organizacao is distinct from old.nome_organizacao or new.moeda is distinct from old.moeda
       or new.percentual_comissao is distinct from old.percentual_comissao)
     and not public._e_lider() then
    raise exception 'Só o líder pode alterar a gestão de acessos e permissões.';
  end if;

  -- Troca de servidor: recomeça do zero. Apaga as vendas (ranking e relatórios saem delas), os pagamentos,
  -- as notificações (🔔), os webhooks e tudo do Discord antigo. Ficam produtos, parcerias, usuários e perfis.
  if new.discord_servidor_id is distinct from old.discord_servidor_id then
    truncate public.venda_itens, public.vendas, public.pagamentos, public.novidades restart identity;
    new.webhook_vendas := null;
    new.webhook_relatorios := null;
    new.webhook_pagamentos := null;
    delete from public.discord_cargos where true;
    delete from public.discord_foruns where true;
    delete from public.discord_posts where true;
    delete from public.discord_estado where true;
    delete from public.discord_pedidos where true;
    update public.vendedores set cargos = '{}', nome_discord_em = null where true;
    if new.discord_categoria_parceiros is not distinct from old.discord_categoria_parceiros then
      new.discord_categoria_parceiros := null;
    end if;
  end if;
  -- Trocou a categoria do fórum: os fóruns e posts antigos ficam para trás.
  if new.discord_categoria_parceiros is distinct from old.discord_categoria_parceiros then
    delete from public.discord_foruns where true;
    delete from public.discord_posts where true;
    delete from public.discord_estado where true;
  end if;

  -- Novo dia/horário do relatório: se ainda não passou nesta semana, envia nesta semana.
  if new.relatorio_dia is distinct from old.relatorio_dia or new.relatorio_hora is distinct from old.relatorio_hora then
    new.relatorio_ultima_semana := public._semana_do_relatorio(new.relatorio_dia, new.relatorio_hora);
  end if;
  return new;
end;
$$;
drop trigger if exists configuracoes_antes on public.configuracoes;
create trigger configuracoes_antes before update on public.configuracoes
  for each row execute function public._configuracoes_antes();

-- Admins: cada um enxerga a própria linha (o site usa isso para saber se é admin).
grant select on public.admins to authenticated;
drop policy if exists admins_proprio on public.admins;
create policy admins_proprio on public.admins for select to authenticated
  using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Funções auxiliares
-- -----------------------------------------------------------------------------

create or replace function public._formatar_valor(p_valor numeric)
returns text
language sql stable
as $$
  select coalesce((select moeda from public.configuracoes where id = 1), 'R$ ')
    || replace(to_char(round(coalesce(p_valor, 0)), 'FM999G999G999G990'), ',', '.');
$$;

-- Segunda-feira (fuso de Brasília) da semana que contém a data.
create or replace function public._inicio_semana(p_data date)
returns date
language sql immutable
as $$ select date_trunc('week', p_data)::date; $$;

-- Semana a marcar como "já enviada" para um dia/horário: a atual se o horário desta semana já passou.
create or replace function public._semana_do_relatorio(p_dia int, p_hora time)
returns date
language sql stable
as $$
  select case when (public._inicio_semana((now() at time zone 'America/Sao_Paulo')::date) + (p_dia - 1)) + p_hora
                   <= (now() at time zone 'America/Sao_Paulo')
              then public._inicio_semana((now() at time zone 'America/Sao_Paulo')::date) end;
$$;
update public.configuracoes set relatorio_ultima_semana = public._semana_do_relatorio(relatorio_dia, relatorio_hora)
where id = 1 and relatorio_ultima_semana is null;

-- Endereço completo de uma imagem do site para o Discord (que não mostra SVG: usa o PNG de mesmo nome).
create or replace function public._url_imagem(p_imagem text)
returns text
language sql stable
as $$
  select case
    when coalesce(btrim(p_imagem), '') = '' then null
    when p_imagem ~ '^https://' then p_imagem
    else rtrim((select site_url from public.configuracoes where id = 1), '/') || '/'
         || regexp_replace(regexp_replace(p_imagem, '^(\./|/)+', ''), '\.svg$', '.png')
  end;
$$;

-- Nome de produto normalizado (sem acento, minúsculo, hífens) para agrupar os fóruns.
create or replace function public._chave_produto(p_nome text)
returns text
language sql immutable
as $$
  select trim(both '-' from regexp_replace(lower(translate(coalesce(p_nome, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '[^a-z0-9]+', '-', 'g'));
$$;

-- Vendedor logado; erro NAO_CADASTRADO se o Discord dele não estiver cadastrado.
create or replace function public._exigir_vendedor()
returns public.vendedores
language plpgsql stable security definer
set search_path = public
as $$
declare
  v public.vendedores := public._vendedor_atual();
begin
  if v.id is null then
    raise exception 'NAO_CADASTRADO' using hint = 'Peça a um administrador para cadastrar seu ID do Discord.';
  end if;
  return v;
end;
$$;

-- -----------------------------------------------------------------------------
-- Calculadora (usuário logado com o Discord)
-- -----------------------------------------------------------------------------

-- Quem é o usuário logado: usado pelo site logo após o login.
create or replace function public.meu_perfil()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_build_object(
    'discord_id', public._discord_id(),
    'cadastrado', v.id is not null,
    'id', v.id,
    'nome', coalesce(v.nome_discord, v.nome),
    'admin', public.is_admin(),
    'admin_manual', coalesce(v.admin, false),
    'lider', public._e_lider(),
    'dev', public._e_dev(),
    'perfil', (select nome from public.perfis where id = v.perfil_id),
    'id_pagamento', v.id_pagamento,
    'permissoes', (select coalesce(jsonb_object_agg(p, p = any (m.lista)), '{}'::jsonb)
                   from unnest(public._permissoes_validas()) p, (select public._minhas_permissoes() as lista) m)
  )
  from (select (public._vendedor_atual()).*) v;
$$;

-- Novidades (preços, produtos e parcerias) desde a última vez que o usuário viu.
-- p_todas: as últimas 30 dos últimos 30 dias, marcando quais são novas.
-- A notificação é para este usuário? (publicada e para todos, para ele ou para um cargo que ele tem)
create or replace function public._novidade_para_mim(n public.novidades, v public.vendedores)
returns boolean
language sql stable
as $$
  select n.publicada and (
       (n.para_vendedor is null and n.para_cargo is null)
    or n.para_vendedor = v.id
    or n.para_cargo = any (coalesce(v.cargos, '{}')));
$$;

create or replace function public.minhas_novidades(p_todas boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  v public.vendedores := public._vendedor_atual();
  v_desde timestamptz;
begin
  if v.id is null then return jsonb_build_object('novas', 0, 'itens', '[]'::jsonb); end if;
  v_desde := coalesce(v.novidades_vistas_em, greatest(v.criado_em, now() - interval '7 days'));
  return jsonb_build_object(
    'novas', (select count(*) from public.novidades n where n.criado_em > v_desde and public._novidade_para_mim(n, v)),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object('tipo', n.tipo, 'titulo', n.titulo, 'descricao', n.descricao, 'autor', n.autor,
                                          'individual', n.para_vendedor is not null, 'cargo', n.para_cargo is not null,
                                          'criado_em', n.criado_em, 'nova', n.criado_em > v_desde) order by n.criado_em desc, n.id desc)
      from (select * from public.novidades n
            where n.criado_em > case when p_todas then now() - interval '30 days' else v_desde end
              and public._novidade_para_mim(n, v)
            order by n.criado_em desc, n.id desc limit 30) n), '[]'::jsonb));
end;
$$;

-- O próprio usuário cadastra (ou corrige) o ID em que recebe as comissões.
create or replace function public.salvar_meu_id_pagamento(p_id_pagamento text)
returns text
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v public.vendedores := public._exigir_vendedor();
  v_pag text := regexp_replace(btrim(coalesce(p_id_pagamento, '')), '\s+', ' ', 'g');
begin
  if v_pag = '' then raise exception 'Informe o ID para pagamento.'; end if;
  if length(v_pag) > 40 then raise exception 'O ID para pagamento pode ter no máximo 40 caracteres.'; end if;
  update public.vendedores set id_pagamento = v_pag where id = v.id;
  return v_pag;
end;
$$;

create or replace function public.marcar_novidades_vistas()
returns void
language sql volatile security definer
set search_path = public
as $$
  update public.vendedores set novidades_vistas_em = now() where id = (public._vendedor_atual()).id;
$$;

-- Aviso automático de produto/parceria: fica pendente (não aparece para ninguém) até quem fez a alteração
-- escolher "Notificar" ou "Não notificar" no painel. Jobs e SQL Editor (sem usuário) não geram aviso.
-- A mesma alteração salva em partes (dados e depois imagens) vira um aviso só (bd.ref = produto:<id> / parceria:<id>).
create or replace function public._novidade(p_tipo text, p_titulo text, p_descricao text)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_ref text := nullif(current_setting('bd.ref', true), '');
  v_titulo text := left(p_titulo, 120);
  a public.novidades;
begin
  if auth.uid() is null then return; end if;
  if v_ref is not null then
    select * into a from public.novidades
    where not publicada and ref = v_ref and autor_uid = auth.uid() and criado_em > now() - interval '30 minutes'
    order by id desc limit 1;
    if a.id is not null and v_titulo like '%atualizad%' then
      if a.titulo = v_titulo then
        update public.novidades set descricao = left(concat_ws(' · ', a.descricao, p_descricao), 500) where id = a.id;
        return;
      elsif a.titulo ~ '^(Nova|Novo) ' then
        return; -- acabou de ser cadastrado: os detalhes salvos em seguida já fazem parte do cadastro
      end if;
    end if;
  end if;
  insert into public.novidades (tipo, titulo, descricao, publicada, autor_uid, autor, ref)
  values (p_tipo, v_titulo, left(p_descricao, 500), false, auth.uid(), public._nome_logado(), v_ref);
end;
$$;

-- Avisos que eu gerei e ainda esperam a decisão (o painel pergunta logo depois de salvar).
create or replace function public.novidades_pendentes()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'titulo', titulo, 'descricao', descricao) order by id), '[]'::jsonb)
  from public.novidades
  where not publicada and autor_uid = auth.uid() and criado_em > now() - interval '1 day';
$$;

-- Notificar (todos passam a ver, com a mensagem opcional) ou descartar os avisos pendentes.
create or replace function public.decidir_novidades(p_ids bigint[], p_notificar boolean, p_mensagem text default null)
returns int
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_msg text := nullif(btrim(coalesce(p_mensagem, '')), '');
  n int;
begin
  if auth.uid() is null then raise exception 'Entre com o Discord.'; end if;
  if length(v_msg) > 300 then raise exception 'A mensagem pode ter no máximo 300 caracteres.'; end if;
  if p_notificar then
    update public.novidades
    set publicada = true, criado_em = now(), descricao = left(concat_ws(' · ', descricao, v_msg), 500)
    where id = any (coalesce(p_ids, '{}')) and not publicada and autor_uid = auth.uid();
  else
    delete from public.novidades where id = any (coalesce(p_ids, '{}')) and not publicada and autor_uid = auth.uid();
  end if;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Mensagem manual (aba Gestão): para todos, para um cargo do Discord ou para um usuário.
create or replace function public.enviar_notificacao(p_alvo text, p_destino text, p_titulo text, p_mensagem text)
returns int
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_titulo text := regexp_replace(btrim(coalesce(p_titulo, '')), '\s+', ' ', 'g');
  v_msg text := nullif(btrim(coalesce(p_mensagem, '')), '');
  v_vend uuid;
  v_cargo text;
  v_qtd int;
begin
  if not public.tem_permissao('enviar_notificacoes') then raise exception 'Você não tem permissão para enviar notificações.'; end if;
  if length(v_titulo) < 3 then raise exception 'Escreva um título (3 letras ou mais).'; end if;
  if length(v_titulo) > 120 then raise exception 'O título pode ter no máximo 120 caracteres.'; end if;
  if length(v_msg) > 500 then raise exception 'A mensagem pode ter no máximo 500 caracteres.'; end if;
  if p_alvo = 'usuario' then
    select id into v_vend from public.vendedores where id::text = p_destino and ativo;
    if v_vend is null then raise exception 'Escolha um usuário ativo.'; end if;
    v_qtd := 1;
  elsif p_alvo = 'cargo' then
    if coalesce(p_destino, '') !~ '^\d{17,20}$' then raise exception 'Escolha um cargo.'; end if;
    v_cargo := p_destino;
    select count(*) into v_qtd from public.vendedores where ativo and v_cargo = any (cargos);
  elsif p_alvo = 'todos' then
    select count(*) into v_qtd from public.vendedores where ativo;
  else
    raise exception 'Escolha para quem enviar.';
  end if;
  insert into public.novidades (tipo, titulo, descricao, publicada, autor_uid, autor, para_vendedor, para_cargo)
  values ('mensagem', v_titulo, v_msg, true, auth.uid(), public._nome_logado(), v_vend, v_cargo);
  return v_qtd;
end;
$$;

-- Avisos automáticos quando um produto ou preço muda pelo site (migrações e jobs do banco não avisam).
create or replace function public._produto_novidade()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_mudou text[] := '{}';
begin
  if auth.uid() is null then return null; end if;
  perform set_config('bd.ref', 'produto:' || coalesce(new.id, old.id)::text, true);
  if tg_op = 'INSERT' then
    if new.ativo then
      perform public._novidade('produto', 'Novo produto: ' || new.nome,
        'Pista ' || public._formatar_valor(new.preco_sem_parceria) || ' · Parceria ' || public._formatar_valor(new.preco_com_parceria));
    end if;
    return null;
  end if;
  if tg_op = 'DELETE' then
    if old.ativo then perform public._novidade('produto', 'Produto removido: ' || old.nome, null); end if;
    return null;
  end if;
  if old.ativo and not new.ativo then
    perform public._novidade('produto', 'Produto retirado da calculadora: ' || new.nome, null);
    return null;
  end if;
  if new.ativo and not old.ativo then
    perform public._novidade('produto', 'Produto de volta: ' || new.nome,
      'Pista ' || public._formatar_valor(new.preco_sem_parceria) || ' · Parceria ' || public._formatar_valor(new.preco_com_parceria));
    return null;
  end if;
  if not new.ativo then return null; end if;
  if new.preco_sem_parceria is distinct from old.preco_sem_parceria or new.preco_com_parceria is distinct from old.preco_com_parceria then
    perform public._novidade('preco', 'Preço atualizado: ' || new.nome,
      concat_ws(' · ',
        case when new.preco_sem_parceria is distinct from old.preco_sem_parceria
          then 'Pista ' || public._formatar_valor(old.preco_sem_parceria) || ' → ' || public._formatar_valor(new.preco_sem_parceria) end,
        case when new.preco_com_parceria is distinct from old.preco_com_parceria
          then 'Parceria ' || public._formatar_valor(old.preco_com_parceria) || ' → ' || public._formatar_valor(new.preco_com_parceria) end));
  end if;
  if new.nome is distinct from old.nome then v_mudou := v_mudou || ('nome (antes: ' || old.nome || ')'); end if;
  if new.serve_para is distinct from old.serve_para then v_mudou := v_mudou || 'descrição'::text; end if;
  if new.craft is distinct from old.craft then v_mudou := v_mudou || 'craft'::text; end if;
  if new.categoria is distinct from old.categoria then v_mudou := v_mudou || ('categoria: ' || new.categoria); end if;
  if new.imagem is distinct from old.imagem or new.icone is distinct from old.icone then v_mudou := v_mudou || 'imagem'::text; end if;
  if array_length(v_mudou, 1) > 0 then
    perform public._novidade('produto', 'Produto atualizado: ' || new.nome, 'Alterado: ' || array_to_string(v_mudou, ', ') || '.');
  end if;
  return null;
end;
$$;
drop trigger if exists produto_novidade on public.produtos;
create trigger produto_novidade after insert or update or delete on public.produtos
  for each row execute function public._produto_novidade();

-- Monta e envia (de forma assíncrona) o aviso de venda para o Discord.
create or replace function public._notificar_venda(p_venda_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_itens_embeds jsonb;
  c public.configuracoes;
  v public.vendas;
  v_discord text;
  v_itens text;
  v_campos jsonb;
  v_corpo jsonb;
begin
  select * into c from public.configuracoes where id = 1;
  if not c.notificar_vendas or coalesce(c.webhook_vendas, '') = '' then
    return;
  end if;

  select * into v from public.vendas where id = p_venda_id;
  select discord_id into v_discord from public.vendedores where id = v.vendedor_id;

  select string_agg(coalesce(icone || ' ', '') || '**' || produto_nome || '** x' || quantidade
                    || ' — ' || public._formatar_valor(subtotal), E'\n' order by id)
    into v_itens
    from public.venda_itens where venda_id = v.id;

  -- Um bloco por item com a imagem do produto (até 9; o resto vai junto no último).
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'color', case when v.com_parceria then 3447003 else 2001125 end,
           'author', jsonb_build_object(
             'name', left(x.quantidade || 'x ' || x.produto_nome || ' — ' || public._formatar_valor(x.subtotal), 256),
             'icon_url', public._url_imagem(x.imagem)),
           'description', case when x.ord = 9 and x.total_itens > 9
             then '+ ' || (x.total_itens - 9) || ' item(ns) — ver a venda no site' end)) order by x.ord), '[]'::jsonb)
    into v_itens_embeds
    from (select i.quantidade, i.produto_nome, i.subtotal, coalesce(pr.imagem, '') as imagem,
                 row_number() over (order by i.id) as ord, count(*) over () as total_itens
          from public.venda_itens i left join public.produtos pr on pr.id = i.produto_id
          where i.venda_id = v.id) x
    where x.ord <= 9;

  v_campos := jsonb_build_array(
    jsonb_build_object('name', '👤 Vendedor', 'value', v.vendedor_nome, 'inline', true),
    jsonb_build_object('name', '🏷️ Tipo de venda', 'value',
      case when v.com_parceria then '🤝 Parceria' else '🛣️ Pista' end, 'inline', true)
  );
  if coalesce(v.cliente, v.parceria_nome, '') <> '' then
    v_campos := v_campos || jsonb_build_object('name', case when v.com_parceria then '🤝 Cliente (parceiro)' else '🧍 Cliente' end,
      'value', coalesce(v.cliente, v.parceria_nome), 'inline', true);
  end if;
  v_campos := v_campos || jsonb_build_array(
    jsonb_build_object('name', 'Total', 'value', '**' || public._formatar_valor(v.total) || '**', 'inline', true),
    jsonb_build_object('name', 'Comissão', 'value', public._formatar_valor(v.comissao), 'inline', true)
  );
  if coalesce(v.observacao, '') <> '' then
    v_campos := v_campos || jsonb_build_object('name', 'Observação', 'value', left(v.observacao, 1024));
  end if;

  v_corpo := jsonb_build_object(
    'username', c.nome_organizacao || ' — Vendas',
    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
    'embeds', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'title', '🐉 Venda #' || v.numero,
      'color', case when v.com_parceria then 3447003 else 2001125 end,
      'fields', v_campos,
      'thumbnail', jsonb_build_object('url', public._url_imagem('img/logo.png')),
      'footer', jsonb_build_object('text', 'Calculadora ' || c.nome_organizacao, 'icon_url', public._url_imagem('img/logo.png')),
      'timestamp', to_char(v.criado_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ))) || v_itens_embeds
  );

  -- Marca o vendedor (em spoiler, discreto) se ele tiver ID do Discord.
  if v_discord is not null then
    v_corpo := v_corpo || jsonb_build_object(
      'content', '||<@' || v_discord || '>||',
      'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb, 'users', jsonb_build_array(v_discord))
    );
  end if;

  perform net.http_post(url := c.webhook_vendas, body := v_corpo);
exception when others then
  -- Falha no Discord nunca deve impedir o registro da venda.
  raise warning 'Falha ao notificar venda %: %', p_venda_id, sqlerrm;
end;
$$;

-- Registra a venda em nome do usuário logado. Preços, comissão e craft são sempre
-- calculados aqui, a partir da tabela produtos, para que ninguém consiga alterar
-- valores pelo navegador.
-- p_itens: [{ "produto_id": "uuid", "quantidade": 3 }, ...]
create or replace function public.registrar_venda(
  p_itens jsonb,
  p_parceria_id uuid default null,
  p_cliente text default null,
  p_observacao text default null
)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_vendedor public.vendedores;
  v_parceria public.parcerias;
  v_com boolean := p_parceria_id is not null;
  v_pct numeric := coalesce((select percentual_comissao from public.configuracoes where id = 1), 0.15);
  v_id uuid;
  v_numero bigint;
  v_total numeric(12, 2);
  v_comissao numeric(12, 2);
  v_linhas jsonb;
  v_esperados int;
begin
  v_vendedor := public._exigir_vendedor();
  if not public.tem_permissao('registrar_venda') then
    raise exception 'Seu perfil não registra vendas (só visualiza a calculadora).';
  end if;

  if v_com then
    select * into v_parceria from public.parcerias where id = p_parceria_id and ativo;
    if not found then
      raise exception 'Parceria não encontrada ou inativa.';
    end if;
  end if;

  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then
    raise exception 'Lista de itens inválida.';
  end if;

  select coalesce(jsonb_agg(x), '[]'::jsonb),
         coalesce(sum(x.quantidade * x.preco), 0),
         coalesce(sum(x.comissao), 0)
    into v_linhas, v_total, v_comissao
  from (
    select p.id as produto_id, p.nome, p.icone, sum(i.quantidade)::int as quantidade,
           case when v_com then p.preco_com_parceria else p.preco_sem_parceria end as preco,
           round(sum(i.quantidade) * p.preco_com_parceria * v_pct, 2) as comissao,
           p.craft as craft_un
    from jsonb_to_recordset(p_itens) as i (produto_id uuid, quantidade int)
    join public.produtos p on p.id = i.produto_id and p.ativo
    where i.quantidade > 0
    group by p.id
  ) x;

  select count(distinct i.produto_id) into v_esperados
  from jsonb_to_recordset(p_itens) as i (produto_id uuid, quantidade int)
  where i.quantidade > 0;

  if v_esperados = 0 then
    raise exception 'Adicione pelo menos um item.';
  end if;
  if jsonb_array_length(v_linhas) <> v_esperados then
    raise exception 'Algum produto da venda não está mais disponível. Recarregue a página.';
  end if;

  insert into public.vendas (vendedor_id, vendedor_nome, parceria_id, parceria_nome, com_parceria, cliente, total, comissao, observacao)
  -- Na parceria, o cliente é o próprio parceiro; na pista, o cliente é opcional.
  values (v_vendedor.id, coalesce(v_vendedor.nome_discord, v_vendedor.nome), v_parceria.id, v_parceria.nome, v_com,
          case when v_com then v_parceria.nome else nullif(left(trim(coalesce(p_cliente, '')), 60), '') end,
          v_total, v_comissao,
          nullif(left(trim(coalesce(p_observacao, '')), 300), ''))
  returning id, numero into v_id, v_numero;

  insert into public.venda_itens (venda_id, produto_id, produto_nome, icone, quantidade, preco_unitario, subtotal, comissao, craft)
  select v_id, l.produto_id, l.nome, l.icone, l.quantidade, l.preco, l.quantidade * l.preco, l.comissao,
         coalesce((select jsonb_agg(jsonb_build_object('material', e->>'material', 'quantidade', (e->>'quantidade')::int * l.quantidade))
                   from jsonb_array_elements(coalesce(l.craft_un, '[]'::jsonb)) e), '[]'::jsonb)
  from jsonb_to_recordset(v_linhas) as l (produto_id uuid, nome text, icone text, quantidade int, preco numeric,
                                          comissao numeric, craft_un jsonb)
  order by l.nome;

  perform public._notificar_venda(v_id);

  return jsonb_build_object('id', v_id, 'numero', v_numero, 'total', v_total, 'comissao', v_comissao);
end;
$$;

-- Ranking de vendedores do período (datas no fuso de Brasília; p_inicio nulo = desde o começo).
-- Qualquer vendedor cadastrado pode ver. Não mostra comissão.
create or replace function public.ranking_vendedores(p_inicio date, p_fim date)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_eu uuid := (public._vendedor_atual()).id;
  v_ini timestamptz := coalesce(p_inicio, date '2000-01-01')::timestamp at time zone 'America/Sao_Paulo';
  v_fim timestamptz := (coalesce(p_fim, (now() at time zone 'America/Sao_Paulo')::date) + 1)::timestamp at time zone 'America/Sao_Paulo';
begin
  if v_eu is null and not public.is_admin() then
    raise exception 'NAO_CADASTRADO' using hint = 'Peça a um administrador para cadastrar seu ID do Discord.';
  end if;
  if not public.tem_permissao('ver_ranking') then
    raise exception 'Seu perfil não tem acesso ao ranking.';
  end if;
  return coalesce((
    select jsonb_agg(x order by x.posicao, x.nome)
    from (
      select rank() over (order by sum(ve.total) desc) as posicao,
             coalesce(max(vd.nome_discord), max(vd.nome), max(ve.vendedor_nome)) as nome,
             max(vd.avatar) as avatar,
             count(*) as vendas,
             coalesce(sum(it.qtd), 0) as itens,
             sum(ve.total) as total,
             ve.vendedor_id = v_eu as eu
      from public.vendas ve
      left join public.vendedores vd on vd.id = ve.vendedor_id
      left join lateral (select sum(i.quantidade) as qtd from public.venda_itens i where i.venda_id = ve.id) it on true
      where not ve.cancelada and ve.criado_em >= v_ini and ve.criado_em < v_fim
      group by ve.vendedor_id
    ) x), '[]'::jsonb);
end;
$$;

-- Resumo da semana atual do próprio vendedor (mostrado na calculadora).
create or replace function public.minha_semana()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_vendedor public.vendedores;
  v_inicio timestamptz := (public._inicio_semana((now() at time zone 'America/Sao_Paulo')::date))::timestamp at time zone 'America/Sao_Paulo';
  v_res jsonb;
begin
  v_vendedor := public._exigir_vendedor();
  select jsonb_build_object('quantidade', count(*), 'total', coalesce(sum(total), 0), 'comissao', coalesce(sum(comissao), 0))
    into v_res
    from public.vendas
   where vendedor_id = v_vendedor.id and not cancelada and criado_em >= v_inicio;
  return v_res;
end;
$$;


-- -----------------------------------------------------------------------------
-- Painel administrativo (papel authenticated + admin)
-- -----------------------------------------------------------------------------

drop function if exists public.salvar_vendedor(uuid, text, text, boolean, boolean);
create or replace function public.salvar_vendedor(
  p_id uuid,
  p_nome text,
  p_discord_id text,
  p_ativo boolean,
  p_admin boolean,
  p_perfil_id uuid default null,
  p_id_pagamento text default null
)
returns uuid
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_discord text := trim(coalesce(p_discord_id, ''));
  v_pag text := nullif(btrim(coalesce(p_id_pagamento, '')), '');
  v_atual public.vendedores;
  v_proprio boolean := false;
  v_perms_perfil text[];
begin
  if not public.tem_permissao('gerenciar_vendedores') then
    raise exception 'Você não tem permissão para gerenciar usuários.';
  end if;
  if p_id is not null then
    select * into v_atual from public.vendedores where id = p_id;
    if v_atual.id is null then raise exception 'Usuário não encontrado.'; end if;
    v_proprio := v_atual.discord_id = public._discord_id();
  end if;
  -- Administrador manual = líder: só um líder pode dar ou tirar.
  if coalesce(p_admin, false) is distinct from coalesce(v_atual.admin, false) and not public._e_lider() then
    raise exception 'Só o líder pode marcar ou desmarcar administrador manual.';
  end if;
  if v_discord !~ '^\d{17,20}$' then
    raise exception 'ID do Discord inválido: deve ter de 17 a 20 números.';
  end if;
  if length(v_pag) > 40 then
    raise exception 'O ID para pagamento pode ter no máximo 40 caracteres.';
  end if;
  if exists (select 1 from public.vendedores where discord_id = v_discord and id is distinct from p_id) then
    raise exception 'Já existe um cadastro com este ID do Discord.';
  end if;
  if p_perfil_id is not null and not exists (select 1 from public.perfis where id = p_perfil_id) then
    raise exception 'Perfil não encontrado.';
  end if;
  -- Perfil: quem não é líder não muda o próprio perfil e só dá perfis com permissões que ele mesmo tem.
  if p_perfil_id is distinct from v_atual.perfil_id and not public._e_lider() then
    if v_proprio then
      raise exception 'Você não pode mudar o seu próprio perfil.';
    end if;
    select permissoes into v_perms_perfil from public.perfis where id = p_perfil_id;
    if not (coalesce(v_perms_perfil, '{}') <@ public._minhas_permissoes()) then
      raise exception 'Este perfil tem permissões que você não tem. Peça ao líder.';
    end if;
  end if;

  if p_id is null then
    insert into public.vendedores (nome, discord_id, ativo, admin, perfil_id, id_pagamento)
    values (trim(p_nome), v_discord, coalesce(p_ativo, true), coalesce(p_admin, false), p_perfil_id, v_pag)
    returning id into v_id;
  else
    -- Ninguém tira o próprio acesso (evita o painel ficar sem líder).
    if v_proprio and (p_ativo is false or v_discord <> public._discord_id()
        or (v_atual.admin and p_admin is false and not public._e_dev())) then
      raise exception 'Você não pode remover o seu próprio acesso.';
    end if;
    update public.vendedores
       set nome = trim(p_nome),
           discord_id = v_discord,
           ativo = coalesce(p_ativo, ativo),
           admin = coalesce(p_admin, admin),
           perfil_id = p_perfil_id,
           id_pagamento = v_pag
     where id = p_id
     returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- Cancelar venda: exige justificativa, guarda quem cancelou e quando.
create or replace function public.cancelar_venda(p_id uuid, p_motivo text)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_motivo text := btrim(coalesce(p_motivo, ''));
begin
  if not public.tem_permissao('cancelar_venda') then raise exception 'Você não tem permissão para cancelar vendas.'; end if;
  if length(v_motivo) < 3 then raise exception 'Informe a justificativa do cancelamento.'; end if;
  if length(v_motivo) > 300 then raise exception 'A justificativa pode ter no máximo 300 caracteres.'; end if;
  update public.vendas set cancelada = true, cancelada_em = now(), cancelada_motivo = v_motivo, cancelada_por = public._nome_logado()
  where id = p_id and not cancelada;
  if not found then raise exception 'Venda não encontrada ou já cancelada.'; end if;
end;
$$;

create or replace function public.reativar_venda(p_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not public.tem_permissao('cancelar_venda') then raise exception 'Você não tem permissão para reativar vendas.'; end if;
  update public.vendas set cancelada = false, cancelada_em = null, cancelada_motivo = null, cancelada_por = null
  where id = p_id and cancelada;
  if not found then raise exception 'Venda não encontrada ou não está cancelada.'; end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Parcerias: histórico, encerramento com motivo e perfil
-- -----------------------------------------------------------------------------

-- Nome de quem está logado (para o histórico).
create or replace function public._nome_logado()
returns text
language sql stable security definer
set search_path = public
as $$
  select coalesce((select coalesce(v.nome_discord, v.nome) from public.vendedores v
                   where v.discord_id = public._discord_id() limit 1), 'Administrador');
$$;

-- Valida o cadastro e registra criação/edição no histórico.
create or replace function public._parceria_antes()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_prod text;
  v_padrao text;
  v_lista text[];
begin
  new.nome := btrim(new.nome);
  new.responsavel := nullif(btrim(coalesce(new.responsavel, '')), '');
  new.observacoes := nullif(btrim(coalesce(new.observacoes, '')), '');
  new.localizacao := nullif(btrim(coalesce(new.localizacao, '')), '');
  if length(coalesce(new.observacoes, '')) > 500 then
    raise exception 'As observações podem ter no máximo 500 caracteres.';
  end if;
  -- Imagens: só caminhos dentro da pasta da própria parceria no bucket.
  if (new.img_localizacao is not null and new.img_localizacao !~ ('^' || new.id::text || '/[a-z0-9_.-]{1,80}$'))
     or (new.img_banner is not null and new.img_banner !~ ('^' || new.id::text || '/[a-z0-9_.-]{1,80}$'))
     or (new.img_cores is not null and new.img_cores !~ ('^' || new.id::text || '/[a-z0-9_.-]{1,80}$')) then
    raise exception 'Imagem inválida.';
  end if;
  -- Produtos da organização: limpa espaços, tira repetidos e usa a mesma grafia
  -- de outra parceria quando o produto já existe (ignorando maiúsculas).
  v_lista := '{}';
  foreach v_prod in array coalesce(new.produtos, '{}') loop
    v_prod := regexp_replace(btrim(coalesce(v_prod, '')), '\s+', ' ', 'g');
    continue when v_prod = '';
    if length(v_prod) > 40 then raise exception 'Nome de produto muito longo (máximo 40 caracteres).'; end if;
    v_padrao := null;
    select e into v_padrao from public.parcerias p2, unnest(p2.produtos) e
    where p2.id <> new.id and lower(e) = lower(v_prod) limit 1;
    v_prod := coalesce(v_padrao, v_prod);
    if not exists (select 1 from unnest(v_lista) x where lower(x) = lower(v_prod)) then
      v_lista := v_lista || v_prod;
    end if;
  end loop;
  if coalesce(array_length(v_lista, 1), 0) > 20 then raise exception 'Informe no máximo 20 produtos.'; end if;
  new.produtos := v_lista;
  if new.feita_por_id is not null then
    select coalesce(nome_discord, nome) into new.feita_por_nome from public.vendedores where id = new.feita_por_id;
  end if;
  return new;
end;
$$;

create or replace function public._parceria_depois()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_mudou text[] := '{}';
begin
  perform set_config('bd.ref', 'parceria:' || new.id::text, true);
  if tg_op = 'INSERT' then
    insert into public.parceria_historico (parceria_id, tipo, descricao, autor)
    values (new.id, 'criada', 'Parceria cadastrada' || coalesce(' por ' || new.feita_por_nome, '') || '.', public._nome_logado());
    if new.ativo then
      perform public._novidade('parceria', 'Nova parceria: ' || new.nome,
        case when cardinality(new.produtos) > 0 then 'Vende: ' || array_to_string(new.produtos, ', ') end);
    end if;
    return new;
  end if;
  if new.ativo is distinct from old.ativo then
    perform public._novidade('parceria', case when new.ativo then 'Parceria reativada: ' else 'Parceria encerrada: ' end || new.nome,
      case when not new.ativo and new.encerrada_motivo is not null then 'Motivo: ' || new.encerrada_motivo end);
  end if;
  if new.nome is distinct from old.nome then v_mudou := v_mudou || ('nome: ' || old.nome || ' → ' || new.nome); end if;
  if new.responsavel is distinct from old.responsavel then v_mudou := v_mudou || 'responsável'::text; end if;
  if new.observacoes is distinct from old.observacoes then v_mudou := v_mudou || 'observações'::text; end if;
  if new.produtos is distinct from old.produtos then v_mudou := v_mudou || 'produtos'::text; end if;
  if new.localizacao is distinct from old.localizacao then v_mudou := v_mudou || 'localização'::text; end if;
  if new.img_localizacao is distinct from old.img_localizacao then v_mudou := v_mudou || 'imagem da localização'::text; end if;
  if new.img_banner is distinct from old.img_banner then v_mudou := v_mudou || 'tabela de preços'::text; end if;
  if new.img_cores is distinct from old.img_cores then v_mudou := v_mudou || 'cores da organização'::text; end if;
  if new.feita_por_id is distinct from old.feita_por_id then v_mudou := v_mudou || ('feita por: ' || coalesce(new.feita_por_nome, '—')); end if;
  if array_length(v_mudou, 1) > 0 then
    insert into public.parceria_historico (parceria_id, tipo, descricao, autor)
    values (new.id, 'editada', 'Alterado: ' || array_to_string(v_mudou, ', ') || '.', public._nome_logado());
    if new.ativo and old.ativo then
      perform public._novidade('parceria', 'Parceria atualizada: ' || new.nome,
        concat_ws(' · ', 'Alterado: ' || array_to_string(v_mudou, ', ') || '.',
          case when new.produtos is distinct from old.produtos then 'Vende: ' || coalesce(nullif(array_to_string(new.produtos, ', '), ''), '—') end));
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists parceria_antes on public.parcerias;
create trigger parceria_antes before insert or update on public.parcerias
  for each row execute function public._parceria_antes();
drop trigger if exists parceria_depois on public.parcerias;
create trigger parceria_depois after insert or update on public.parcerias
  for each row execute function public._parceria_depois();

-- Encerrar exige um motivo, que fica no cadastro e no histórico.
create or replace function public.encerrar_parceria(p_id uuid, p_motivo text)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_motivo text := btrim(coalesce(p_motivo, ''));
  v_quem text := public._nome_logado();
begin
  if not public.tem_permissao('encerrar_parceria') then raise exception 'Você não tem permissão para encerrar parcerias.'; end if;
  if length(v_motivo) < 3 then raise exception 'Informe o motivo do encerramento.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter no máximo 500 caracteres.'; end if;
  update public.parcerias set ativo = false, encerrada_em = now(), encerrada_motivo = v_motivo, encerrada_por = v_quem
  where id = p_id and ativo;
  if not found then raise exception 'Parceria não encontrada ou já encerrada.'; end if;
  insert into public.parceria_historico (parceria_id, tipo, descricao, autor)
  values (p_id, 'encerrada', 'Motivo: ' || v_motivo, v_quem);
end;
$$;

create or replace function public.reativar_parceria(p_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not public.tem_permissao('encerrar_parceria') then raise exception 'Você não tem permissão para reativar parcerias.'; end if;
  update public.parcerias set ativo = true, encerrada_em = null, encerrada_motivo = null, encerrada_por = null
  where id = p_id and not ativo;
  if not found then raise exception 'Parceria não encontrada ou já ativa.'; end if;
  insert into public.parceria_historico (parceria_id, tipo, descricao, autor)
  values (p_id, 'reativada', 'Parceria reativada.', public._nome_logado());
end;
$$;

-- Tudo para a tela de perfil: números de vendas, últimas vendas, produtos e histórico.
create or replace function public.perfil_parceria(p_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  r jsonb;
begin
  if not public.tem_permissao('ver_parcerias') then raise exception 'Acesso negado.'; end if;
  if not exists (select 1 from public.parcerias where id = p_id) then raise exception 'Parceria não encontrada.'; end if;
  select jsonb_build_object(
    'total', coalesce(sum(v.total), 0),
    'quantidade', count(*),
    'primeira_venda', min(v.criado_em),
    'ultima_venda', max(v.criado_em)
  ) into r
  from public.vendas v where v.parceria_id = p_id and not v.cancelada;

  r := r || jsonb_build_object(
    'por_produto', coalesce((
      select jsonb_agg(x order by x.total desc) from (
        select i.produto_nome as nome, max(i.icone) as icone, max(pr.imagem) as imagem,
               sum(i.quantidade) as quantidade, sum(i.subtotal) as total
        from public.venda_itens i join public.vendas v on v.id = i.venda_id
        left join public.produtos pr on pr.id = i.produto_id
        where v.parceria_id = p_id and not v.cancelada
        group by i.produto_nome) x), '[]'::jsonb),
    'vendas', coalesce((
      select jsonb_agg(x order by x.criado_em desc) from (
        select v.numero, v.criado_em, v.vendedor_nome, v.total, v.cancelada,
               (select string_agg(i.produto_nome || ' x' || i.quantidade, ', ' order by i.id) from public.venda_itens i where i.venda_id = v.id) as itens
        from public.vendas v where v.parceria_id = p_id
        order by v.criado_em desc limit 30) x), '[]'::jsonb),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object('tipo', h.tipo, 'descricao', h.descricao, 'autor', h.autor, 'criado_em', h.criado_em) order by h.criado_em desc, h.id desc)
      from public.parceria_historico h where h.parceria_id = p_id), '[]'::jsonb)
  );
  return r;
end;
$$;

-- Relatório de um período (por padrão, a semana de segunda a domingo).
create or replace function public._relatorio(p_inicio date, p_fim date)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  with periodo as (
    select (p_inicio::timestamp at time zone 'America/Sao_Paulo') as ini,
           ((p_fim + 1)::timestamp at time zone 'America/Sao_Paulo') as fim
  ),
  v as (
    select ve.* from public.vendas ve, periodo
    where not ve.cancelada and ve.criado_em >= periodo.ini and ve.criado_em < periodo.fim
  ),
  -- materiais usados em cada item vendido
  ic as (
    select i.produto_nome, m.material, m.quantidade
    from public.venda_itens i join v on v.id = i.venda_id
    cross join lateral (
      select e->>'material' as material, (e->>'quantidade')::int as quantidade from jsonb_array_elements(i.craft) e
      union all select 'Placa', i.craft_placa where i.craft_placa > 0
      union all select coalesce(i.material_nome, 'Material'), i.craft_material where i.craft_material > 0
    ) m
  )
  select jsonb_build_object(
    'inicio', p_inicio,
    'fim', p_fim,
    'quantidade', (select count(*) from v),
    'total', (select coalesce(sum(total), 0) from v),
    'total_com_parceria', (select coalesce(sum(total), 0) from v where com_parceria),
    'total_sem_parceria', (select coalesce(sum(total), 0) from v where not com_parceria),
    'comissao', (select coalesce(sum(comissao), 0) from v),
    'percentual_comissao', (select percentual_comissao from public.configuracoes where id = 1),
    'por_vendedor', coalesce((
      select jsonb_agg(x order by x.total desc) from (
        select s.*, coalesce(pg.pago, 0) as pago, greatest(s.comissao - coalesce(pg.pago, 0), 0) as pendente,
               pg.pago_em, pg.pago_por
        from (
          select v.vendedor_id, coalesce(max(vd.nome_discord), max(vd.nome), max(v.vendedor_nome)) as nome,
                 max(vd.avatar) as avatar, max(vd.id_pagamento) as id_pagamento, max(vd.discord_id) as discord_id,
                 count(*) as quantidade, sum(v.total) as total, sum(v.comissao) as comissao
          from v left join public.vendedores vd on vd.id = v.vendedor_id
          group by v.vendedor_id
        ) s
        left join lateral (
          select sum(p.valor) as pago, max(p.pago_em) as pago_em,
                 (array_agg(p.pago_por_nome order by p.pago_em desc))[1] as pago_por
          from public.pagamentos p
          where p.vendedor_id = s.vendedor_id and p.semana_inicio = public._inicio_semana(p_inicio)
        ) pg on true
      ) x), '[]'::jsonb),
    'por_parceria', coalesce((
      select jsonb_agg(x order by x.total desc) from (
        select coalesce(parceria_nome, 'Pista (sem parceria)') as nome, count(*) as quantidade, sum(total) as total
        from v group by coalesce(parceria_nome, 'Pista (sem parceria)')
      ) x), '[]'::jsonb),
    'por_produto', coalesce((
      select jsonb_agg(x order by x.total desc) from (
        select i.produto_nome as nome, max(i.icone) as icone, max(pr.imagem) as imagem,
               sum(i.quantidade) as quantidade, sum(i.subtotal) as total,
               coalesce((select jsonb_agg(jsonb_build_object('nome', c.material, 'quantidade', c.qtd) order by c.material)
                         from (select ic.material, sum(ic.quantidade) as qtd from ic where ic.produto_nome = i.produto_nome
                               group by ic.material) c), '[]'::jsonb) as craft
        from public.venda_itens i join v on v.id = i.venda_id
        left join public.produtos pr on pr.id = i.produto_id
        group by i.produto_nome
      ) x), '[]'::jsonb),
    'craft', coalesce((
      select jsonb_agg(x order by x.nome) from (
        select ic.material as nome, sum(ic.quantidade) as quantidade from ic group by ic.material having sum(ic.quantidade) > 0
      ) x), '[]'::jsonb)
  );
$$;

create or replace function public.relatorio_periodo(p_inicio date, p_fim date)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.tem_permissao('ver_relatorio') then
    raise exception 'Acesso negado.';
  end if;
  return public._relatorio(p_inicio, p_fim);
end;
$$;

-- Opções dos filtros da página Vendas (quem vê vendas pode não acessar o painel).
create or replace function public.vendas_filtros()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.tem_permissao('ver_vendas') then
    raise exception 'Seu perfil não tem acesso às vendas.';
  end if;
  return jsonb_build_object(
    'vendedores', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nome', x.nome) order by lower(x.nome))
                            from (select vd.id, coalesce(vd.nome_discord, vd.nome) as nome from public.vendedores vd
                                  where vd.ativo or exists (select 1 from public.vendas v where v.vendedor_id = vd.id)) x), '[]'::jsonb),
    'parcerias', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'ativo', p.ativo) order by lower(p.nome))
                           from public.parcerias p), '[]'::jsonb));
end;
$$;

-- Total vendido por parceria no período (coluna "Semana" da aba Parcerias).
create or replace function public.vendas_por_parceria(p_inicio date, p_fim date)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.tem_permissao('ver_parcerias') then
    raise exception 'Acesso negado.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('parceria_id', parceria_id, 'quantidade', qtd, 'total', total))
    from (select parceria_id, count(*) as qtd, sum(total) as total from public.vendas
          where not cancelada and parceria_id is not null
            and criado_em >= (p_inicio::timestamp at time zone 'America/Sao_Paulo')
            and criado_em < ((p_fim + 1)::timestamp at time zone 'America/Sao_Paulo')
          group by parceria_id) x), '[]'::jsonb);
end;
$$;

drop function if exists public._linhas_relatorio(jsonb, boolean);

-- Peças do visual do relatório no Discord.
create or replace function public._campo(p_nome text, p_valor text, p_inline boolean default true)
returns jsonb
language sql immutable
as $$ select jsonb_build_object('name', left(p_nome, 256), 'value', left(coalesce(nullif(p_valor, ''), '—'), 1024), 'inline', p_inline); $$;

create or replace function public._barra(p_valor numeric, p_max numeric)
returns text
language sql immutable
as $$
  select repeat('▰', n) || repeat('▱', 10 - n)
  from (select least(10, greatest(1, coalesce(round(10 * coalesce(p_valor, 0) / nullif(p_max, 0))::int, 1))) as n) x;
$$;

create or replace function public._medalha(p_pos bigint)
returns text
language sql immutable
as $$ select case p_pos when 1 then '🥇' when 2 then '🥈' when 3 then '🥉' else '`' || p_pos || 'º`' end; $$;

-- Número inteiro com ponto no milhar (para as tabelas do relatório).
create or replace function public._num(p_valor numeric)
returns text
language sql immutable
as $$ select replace(to_char(round(coalesce(p_valor, 0)), 'FM999G999G999G990'), ',', '.'); $$;

-- Uma linha de tabela: textos à esquerda e números à direita, com largura fixa.
create or replace function public._col(p_texto text, p_largura int, p_direita boolean default false)
returns text
language sql immutable
as $$
  select case when p_direita then lpad(left(coalesce(p_texto, ''), p_largura), p_largura)
              else rpad(left(coalesce(p_texto, ''), p_largura), p_largura) end;
$$;

-- Monta a mensagem do relatório: um único embed, com tabelas no estilo da planilha.
-- r: resultado de _relatorio (+ total_anterior, opcional).
create or replace function public._corpo_relatorio(r jsonb, p_simulado boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  c public.configuracoes;
  v_ini date := (r->>'inicio')::date;
  v_fim date := (r->>'fim')::date;
  v_logo text := public._url_imagem('img/logo.png');
  v_qtd numeric := coalesce((r->>'quantidade')::numeric, 0);
  v_total numeric := coalesce((r->>'total')::numeric, 0);
  v_anterior numeric := (r->>'total_anterior')::numeric;
  v_pct numeric := round(coalesce((r->>'percentual_comissao')::numeric, 0) * 100, 1);
  v_moeda text := btrim((select moeda from public.configuracoes where id = 1));
  v_itens numeric;
  v_txt text;
  v_var text := '';
  v_tab text := '';
  v_linhas text;
begin
  select * into c from public.configuracoes where id = 1;
  select coalesce(sum((e->>'quantidade')::numeric), 0) into v_itens from jsonb_array_elements(coalesce(r->'por_produto', '[]')) e;
  if v_anterior is not null and v_anterior > 0 then
    v_var := ' · ' || case when v_total >= v_anterior then '📈 +' else '📉 ' end
             || round((v_total - v_anterior) / v_anterior * 100) || '% vs. semana anterior';
  end if;

  -- RESUMO (todas as tabelas têm no máximo 37 caracteres por linha, para não quebrar no Discord)
  v_tab := 'RESUMO' || E'\n'
    || public._col('Total vendido', 23) || public._col(public._num(v_total), 14, true) || E'\n'
    || public._col('Vendas', 23) || public._col(v_qtd::text, 14, true) || E'\n'
    || public._col('Itens vendidos', 23) || public._col(public._num(v_itens), 14, true) || E'\n'
    || public._col('Com parceria', 23) || public._col(public._num((r->>'total_com_parceria')::numeric), 14, true) || E'\n'
    || public._col('Pista', 23) || public._col(public._num((r->>'total_sem_parceria')::numeric), 14, true) || E'\n'
    || public._col('Comissões (' || v_pct || '%)', 23) || public._col(public._num((r->>'comissao')::numeric), 14, true);

  if jsonb_array_length(coalesce(r->'por_vendedor', '[]')) > 0 then
    -- VENDEDORES: 13 + 5 + 10 + 9 = 37
    select string_agg(public._col(ord || '.' || (e->>'nome'), 13) || public._col(e->>'quantidade', 5, true)
                      || public._col(public._num((e->>'total')::numeric), 10, true)
                      || public._col(public._num((e->>'comissao')::numeric), 9, true),
                      E'\n' order by ord)
      into v_linhas
      from jsonb_array_elements(r->'por_vendedor') with ordinality t (e, ord) where ord <= 12;
    v_tab := v_tab || E'\n\n'
      || public._col('VENDEDOR', 13) || public._col('VEND', 5, true) || public._col('TOTAL', 10, true) || public._col('COMISSÃO', 9, true) || E'\n'
      || repeat('-', 37) || E'\n' || v_linhas || E'\n' || repeat('-', 37) || E'\n'
      || public._col('TOTAL', 13) || public._col(v_qtd::text, 5, true) || public._col(public._num(v_total), 10, true)
      || public._col(public._num((r->>'comissao')::numeric), 9, true);

    -- PAGAMENTO (quem tem comissão, com o ID para pagamento): 13 + 13 + 11 = 37
    select string_agg(public._col(e->>'nome', 13) || public._col(coalesce(nullif(e->>'id_pagamento', ''), '-'), 13)
                      || public._col(case when (e->>'pendente')::numeric <= 0 then 'PAGO' else public._num((e->>'pendente')::numeric) end, 11, true),
                      E'\n' order by ord)
      into v_linhas
      from jsonb_array_elements(r->'por_vendedor') with ordinality t (e, ord)
      where (e->>'comissao')::numeric > 0 and ord <= 12;
    if v_linhas is not null then
      v_tab := v_tab || E'\n\n'
        || public._col('PAGAMENTO', 13) || public._col('ID PGTO', 13) || public._col('A PAGAR', 11, true) || E'\n'
        || repeat('-', 37) || E'\n' || v_linhas;
    end if;

    -- PARCERIAS: 20 + 5 + 12 = 37
    select string_agg(public._col(e->>'nome', 20) || public._col(e->>'quantidade', 5, true)
                      || public._col(public._num((e->>'total')::numeric), 12, true), E'\n' order by ord)
      into v_linhas
      from jsonb_array_elements(r->'por_parceria') with ordinality t (e, ord) where ord <= 8;
    if v_linhas is not null then
      v_tab := v_tab || E'\n\n'
        || public._col('CLIENTE/PARCERIA', 20) || public._col('VEND', 5, true) || public._col('TOTAL', 12, true) || E'\n'
        || repeat('-', 37) || E'\n' || v_linhas;
    end if;

    -- PRODUTOS: 20 + 5 + 12 = 37
    select string_agg(public._col(e->>'nome', 20) || public._col(public._num((e->>'quantidade')::numeric), 5, true)
                      || public._col(public._num((e->>'total')::numeric), 12, true), E'\n' order by ord)
      into v_linhas
      from jsonb_array_elements(r->'por_produto') with ordinality t (e, ord) where ord <= 10;
    if v_linhas is not null then
      v_tab := v_tab || E'\n\n'
        || public._col('PRODUTO', 20) || public._col('QTD', 5, true) || public._col('TOTAL', 12, true) || E'\n'
        || repeat('-', 37) || E'\n' || v_linhas;
    end if;

    -- CRAFT: 25 + 12 = 37
    select string_agg(public._col(e->>'nome', 25) || public._col(public._num((e->>'quantidade')::numeric), 12, true), E'\n' order by ord)
      into v_linhas
      from jsonb_array_elements(coalesce(r->'craft', '[]')) with ordinality t (e, ord) where ord <= 15;
    if v_linhas is not null then
      v_tab := v_tab || E'\n\n'
        || public._col('CRAFT USADO', 25) || public._col('QTD', 12, true) || E'\n'
        || repeat('-', 37) || E'\n' || v_linhas;
    end if;
  else
    v_tab := v_tab || E'\n\n' || 'Nenhuma venda registrada nesta semana.';
  end if;

  v_txt := '**Semana de ' || to_char(v_ini, 'DD/MM') || ' a ' || to_char(v_fim, 'DD/MM/YYYY') || '**' || v_var
           || E'\n' || 'Valores em ' || coalesce(nullif(v_moeda, ''), 'R$') || E'\n'
           || '```' || E'\n' || left(v_tab, 3800) || E'\n' || '```';

  return jsonb_strip_nulls(jsonb_build_object(
    'username', c.nome_organizacao || ' — Relatórios',
    'avatar_url', v_logo,
    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
    'content', case when p_simulado then '🧪 **Simulação do relatório semanal** — dados fictícios, só para aprovar o visual.' end,
    'embeds', jsonb_build_array(jsonb_build_object(
      'author', jsonb_build_object('name', c.nome_organizacao, 'icon_url', v_logo),
      'title', '📊 Relatório semanal' || case when p_simulado then ' (simulação)' else '' end,
      'description', v_txt,
      'color', 2001125,
      'footer', jsonb_build_object('text', 'Calculadora ' || c.nome_organizacao, 'icon_url', v_logo),
      'timestamp', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))));
end;
$$;

-- Envia o relatório da semana que começa em p_inicio para o webhook de relatórios.
create or replace function public._enviar_relatorio(p_inicio date)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  c public.configuracoes;
  v_ini date := public._inicio_semana(p_inicio);
  r jsonb;
  v_url text;
begin
  select * into c from public.configuracoes where id = 1;
  v_url := coalesce(nullif(c.webhook_relatorios, ''), nullif(c.webhook_vendas, ''));
  if v_url is null then
    raise exception 'Nenhum webhook do Discord configurado.';
  end if;
  r := public._relatorio(v_ini, v_ini + 6);
  r := r || jsonb_build_object('total_anterior', (public._relatorio(v_ini - 7, v_ini - 1))->'total');
  perform net.http_post(url := v_url, body := public._corpo_relatorio(r, false));
  return r;
end;
$$;

create or replace function public.enviar_relatorio_discord(p_inicio date)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not public.tem_permissao('ver_relatorio') then
    raise exception 'Acesso negado.';
  end if;
  return public._enviar_relatorio(p_inicio);
end;
$$;

-- Envia um relatório com dados fictícios (produtos reais, números inventados) para aprovar o visual.
create or replace function public.enviar_relatorio_simulado()
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare
  c public.configuracoes;
  v_url text;
  v_ini date := public._inicio_semana((now() at time zone 'America/Sao_Paulo')::date) - 7;
  v_prod jsonb;
  v_total numeric;
  v_pct numeric;
  v_vend jsonb;
  r jsonb;
begin
  -- (sem usuário = SQL Editor do Supabase; pelo site, só DEV ou líder)
  if auth.uid() is not null and not (public._e_dev() or public._e_lider()) then
    raise exception 'Só o DEV ou o líder podem enviar a simulação.';
  end if;
  select * into c from public.configuracoes where id = 1;
  v_url := coalesce(nullif(c.webhook_relatorios, ''), nullif(c.webhook_vendas, ''));
  if v_url is null then
    raise exception 'Configure o webhook de relatórios na aba Discord.';
  end if;
  v_pct := c.percentual_comissao;

  select coalesce(jsonb_agg(jsonb_build_object(
           'nome', p.nome, 'icone', p.icone, 'imagem', p.imagem, 'quantidade', p.q, 'total', p.q * p.preco_sem_parceria,
           'craft', coalesce((select jsonb_agg(jsonb_build_object('nome', m->>'material', 'quantidade', (m->>'quantidade')::int * p.q))
                              from jsonb_array_elements(p.craft) m), '[]'::jsonb))
         order by p.q * p.preco_sem_parceria desc), '[]'::jsonb)
    into v_prod
    from (select pr.*, (array[14, 11, 9, 7, 6, 4, 3, 2, 2, 1])[row_number() over (order by pr.ordem, pr.nome)] as q
          from public.produtos pr where pr.ativo order by pr.ordem, pr.nome limit 10) p;
  select coalesce(sum((e->>'total')::numeric), 0) into v_total from jsonb_array_elements(v_prod) e;

  v_vend := jsonb_build_array(
    jsonb_build_object('nome', 'Vendedor Exemplo 1', 'quantidade', 9, 'total', round(v_total * 0.38), 'comissao', round(v_total * 0.38 * v_pct * 0.9), 'pago', round(v_total * 0.38 * v_pct * 0.9), 'pendente', 0, 'id_pagamento', '10234'),
    jsonb_build_object('nome', 'Vendedor Exemplo 2', 'quantidade', 7, 'total', round(v_total * 0.27), 'comissao', round(v_total * 0.27 * v_pct * 0.9), 'pago', 0, 'pendente', round(v_total * 0.27 * v_pct * 0.9), 'id_pagamento', '20871'),
    jsonb_build_object('nome', 'Vendedor Exemplo 3', 'quantidade', 5, 'total', round(v_total * 0.2), 'comissao', round(v_total * 0.2 * v_pct * 0.9), 'pago', round(v_total * 0.1 * v_pct), 'pendente', round(v_total * 0.2 * v_pct * 0.9) - round(v_total * 0.1 * v_pct), 'id_pagamento', '33310'),
    jsonb_build_object('nome', 'Vendedor Exemplo 4', 'quantidade', 3, 'total', v_total - round(v_total * 0.38) - round(v_total * 0.27) - round(v_total * 0.2), 'comissao', round((v_total * 0.15) * v_pct * 0.9), 'pago', 0, 'pendente', round((v_total * 0.15) * v_pct * 0.9)));

  r := jsonb_build_object(
    'inicio', v_ini, 'fim', v_ini + 6,
    'quantidade', 24, 'total', v_total, 'total_anterior', round(v_total * 0.86),
    'total_com_parceria', round(v_total * 0.62), 'total_sem_parceria', v_total - round(v_total * 0.62),
    'comissao', round(v_total * v_pct * 0.9), 'percentual_comissao', v_pct,
    'por_vendedor', v_vend,
    'por_parceria', jsonb_build_array(
      jsonb_build_object('nome', 'Organização Alfa', 'quantidade', 8, 'total', round(v_total * 0.34)),
      jsonb_build_object('nome', 'Organização Beta', 'quantidade', 5, 'total', round(v_total * 0.28)),
      jsonb_build_object('nome', 'Pista (sem parceria)', 'quantidade', 11, 'total', v_total - round(v_total * 0.62))),
    'por_produto', v_prod,
    'craft', coalesce((select jsonb_agg(jsonb_build_object('nome', nome, 'quantidade', q) order by nome)
                       from (select m->>'nome' as nome, sum((m->>'quantidade')::int) as q
                             from jsonb_array_elements(v_prod) e, jsonb_array_elements(e->'craft') m group by 1) s), '[]'::jsonb));

  perform net.http_post(url := v_url, body := public._corpo_relatorio(r, true));
end;
$$;

-- Usado pelo agendamento (a cada 5 minutos): envia o relatório da semana anterior
-- no dia e horário escolhidos (horário de Brasília), uma vez por semana.
create or replace function public._relatorio_automatico()
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare
  c public.configuracoes;
  v_agora timestamp := now() at time zone 'America/Sao_Paulo';
  v_semana date := public._inicio_semana((now() at time zone 'America/Sao_Paulo')::date);
begin
  select * into c from public.configuracoes where id = 1;
  if not c.relatorio_automatico then return; end if;
  if extract(isodow from v_agora) <> c.relatorio_dia or v_agora::time < c.relatorio_hora then return; end if;
  if c.relatorio_ultima_semana is not distinct from v_semana then return; end if;
  update public.configuracoes set relatorio_ultima_semana = v_semana where id = 1;
  perform public._enviar_relatorio(v_semana - 7);
end;
$$;

-- Testa o webhook informado (botão "Testar" nas configurações).
create or replace function public.testar_webhook(p_url text)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not public._e_dev() then
    raise exception 'Só o DEV pode configurar o Discord.';
  end if;
  if p_url !~ '^https://(canary\.|ptb\.)?(discord|discordapp)\.com/api/webhooks/' then
    raise exception 'URL de webhook do Discord inválida.';
  end if;
  perform net.http_post(url := p_url, body := jsonb_build_object(
    'username', (select nome_organizacao from public.configuracoes where id = 1) || ' — Teste',
    'content', '✅ Webhook configurado com sucesso na calculadora.'
  ));
end;
$$;

-- Registra o pagamento da comissão de um vendedor numa semana e avisa no Discord.
-- O valor é calculado aqui (o que ainda falta pagar), nunca vem do navegador.
create or replace function public.registrar_pagamento(p_vendedor_id uuid, p_semana_inicio date, p_observacao text default null)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  c public.configuracoes;
  vd public.vendedores;
  eu public.vendedores;
  v_ini date := public._inicio_semana(p_semana_inicio);
  v_comissao numeric;
  v_pago numeric;
  v_valor numeric;
  v_obs text := nullif(btrim(coalesce(p_observacao, '')), '');
  v_nome text;
  v_quem text;
  v_url text;
  v_id uuid;
  v_campos jsonb;
begin
  if not public.tem_permissao('registrar_pagamento') then
    raise exception 'Você não tem permissão para registrar pagamentos.';
  end if;
  if v_ini is null then
    raise exception 'Semana inválida.';
  end if;
  if length(v_obs) > 300 then
    raise exception 'A observação pode ter no máximo 300 caracteres.';
  end if;
  select * into vd from public.vendedores where id = p_vendedor_id;
  if vd.id is null then
    raise exception 'Vendedor não encontrado.';
  end if;

  -- Evita pagamento em dobro com dois cliques (ou dois admins) ao mesmo tempo.
  perform pg_advisory_xact_lock(hashtext('pagamento:' || p_vendedor_id::text || ':' || v_ini::text));

  select coalesce(sum(ve.comissao), 0) into v_comissao
  from public.vendas ve
  where ve.vendedor_id = p_vendedor_id and not ve.cancelada
    and ve.criado_em >= (v_ini::timestamp at time zone 'America/Sao_Paulo')
    and ve.criado_em < ((v_ini + 7)::timestamp at time zone 'America/Sao_Paulo');
  select coalesce(sum(valor), 0) into v_pago
  from public.pagamentos where vendedor_id = p_vendedor_id and semana_inicio = v_ini;

  v_valor := v_comissao - v_pago;
  if v_valor <= 0 then
    raise exception 'Não há valor pendente para este vendedor nesta semana.';
  end if;

  eu := public._vendedor_atual();
  v_nome := coalesce(vd.nome_discord, vd.nome);
  v_quem := coalesce(eu.nome_discord, eu.nome, 'Administrador');

  insert into public.pagamentos (vendedor_id, vendedor_nome, semana_inicio, valor, observacao, pago_por_discord, pago_por_nome)
  values (vd.id, v_nome, v_ini, v_valor, v_obs, public._discord_id(), v_quem)
  returning id into v_id;

  -- Notificação (🔔) só para quem recebeu.
  insert into public.novidades (tipo, titulo, descricao, publicada, autor_uid, autor, para_vendedor)
  values ('pagamento', 'Pagamento recebido: ' || public._formatar_valor(v_valor),
    concat_ws(' · ', 'Comissão da semana ' || to_char(v_ini, 'DD/MM') || ' a ' || to_char(v_ini + 6, 'DD/MM/YYYY'),
      'Pago por ' || v_quem, v_obs),
    true, auth.uid(), v_quem, vd.id);

  -- Aviso no Discord (falha no envio não desfaz o pagamento).
  begin
    select * into c from public.configuracoes where id = 1;
    v_url := coalesce(nullif(c.webhook_pagamentos, ''), nullif(c.webhook_relatorios, ''), nullif(c.webhook_vendas, ''));
    if v_url is not null then
      v_campos := jsonb_build_array(
        jsonb_build_object('name', '👤 Vendedor', 'value', v_nome, 'inline', true),
        jsonb_build_object('name', '🗓️ Semana', 'value', to_char(v_ini, 'DD/MM') || ' a ' || to_char(v_ini + 6, 'DD/MM/YYYY'), 'inline', true),
        jsonb_build_object('name', '💰 Valor pago', 'value', '**' || public._formatar_valor(v_valor) || '**', 'inline', true),
        jsonb_build_object('name', '🆔 ID para pagamento', 'value', coalesce('`' || nullif(vd.id_pagamento, '') || '`', '—'), 'inline', true),
        jsonb_build_object('name', '✍️ Pago por', 'value', v_quem, 'inline', true)
      );
      if v_pago > 0 then
        v_campos := v_campos || jsonb_build_object('name', 'Total pago na semana', 'value',
          public._formatar_valor(v_comissao) || ' (já tinha ' || public._formatar_valor(v_pago) || ')', 'inline', true);
      end if;
      if v_obs is not null then
        v_campos := v_campos || jsonb_build_object('name', 'Observação', 'value', v_obs);
      end if;
      perform net.http_post(url := v_url, body := jsonb_build_object(
        'username', c.nome_organizacao || ' — Pagamentos',
        'avatar_url', public._url_imagem('img/logo.png'),
        'content', '||<@' || vd.discord_id || '>||',
        'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb, 'users', jsonb_build_array(vd.discord_id)),
        'embeds', jsonb_build_array(jsonb_build_object(
          'title', '💸 Pagamento registrado',
          'color', 3066993,
          'fields', v_campos,
          'footer', jsonb_build_object('text', 'Calculadora ' || c.nome_organizacao),
          'timestamp', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ))
      ));
    end if;
  exception when others then
    raise warning 'Falha ao avisar pagamento %: %', v_id, sqlerrm;
  end;

  return jsonb_build_object('id', v_id, 'valor', v_valor, 'semana_inicio', v_ini, 'notificado', v_url is not null, 'id_pagamento', vd.id_pagamento);
end;
$$;

-- -----------------------------------------------------------------------------
-- Nomes do Discord (bot)
-- O "bot" é só uma credencial: nenhum programa fica rodando. O próprio banco
-- consulta a API do Discord (pg_net) para saber o nome de cada vendedor no
-- servidor configurado. O token do bot fica no Vault do Supabase.
-- -----------------------------------------------------------------------------

create or replace function public._token_bot()
returns text
language sql stable security definer
set search_path = public
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'discord_bot_token' limit 1;
$$;

-- Grava (ou troca) o token do bot no Vault. O token nunca é devolvido ao site.
create or replace function public.salvar_token_bot(p_token text)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_token text := trim(coalesce(p_token, ''));
  v_id uuid;
begin
  if not public._e_dev() then
    raise exception 'Só o DEV pode configurar o Discord.';
  end if;
  v_token := regexp_replace(v_token, '^Bot\s+', '', 'i');
  if v_token !~ '^[A-Za-z0-9_.\-]{50,100}$' then
    raise exception 'Token do bot inválido. Copie em Developer Portal → Bot → Reset Token.';
  end if;
  select id into v_id from vault.secrets where name = 'discord_bot_token';
  if v_id is null then
    perform vault.create_secret(v_token, 'discord_bot_token', 'Token do bot do Discord (nomes dos vendedores)');
  else
    perform vault.update_secret(v_id, v_token);
  end if;
end;
$$;

create or replace function public.discord_status()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Acesso negado.';
  end if;
  return jsonb_build_object(
    'bot_configurado', public._token_bot() is not null,
    'app_id', public._bot_app_id(),
    'servidor_id', (select discord_servidor_id from public.configuracoes where id = 1),
    'pendentes', (select count(*) from public.discord_pedidos)
  );
end;
$$;

-- ID da aplicação do bot (é a primeira parte do token, em base64). Usado no link de convite.
create or replace function public._bot_app_id()
returns text
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_parte text := split_part(coalesce(public._token_bot(), ''), '.', 1);
  v_id text;
begin
  if v_parte = '' then return null; end if;
  v_parte := translate(v_parte, '-_', '+/');
  v_parte := v_parte || repeat('=', (4 - length(v_parte) % 4) % 4);
  v_id := convert_from(decode(v_parte, 'base64'), 'UTF8');
  return case when v_id ~ '^\d{17,20}$' then v_id end;
exception when others then
  return null;
end;
$$;

-- Pede ao Discord os dados de um vendedor (ou de todos os ativos, se p_vendedor_id for nulo).
create or replace function public._discord_buscar_nomes(p_vendedor_id uuid)
returns int
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_token text := public._token_bot();
  v_servidor text := (select discord_servidor_id from public.configuracoes where id = 1);
  v record;
  v_req bigint;
  v_qtd int := 0;
begin
  if v_token is null or v_servidor is null then
    return 0;
  end if;
  delete from public.discord_pedidos where criado_em < now() - interval '1 hour';
  for v in
    select id, discord_id from public.vendedores
    where (p_vendedor_id is null and ativo) or id = p_vendedor_id
  loop
    v_req := net.http_get(
      url := 'https://discord.com/api/v10/guilds/' || v_servidor || '/members/' || v.discord_id,
      headers := jsonb_build_object('Authorization', 'Bot ' || v_token, 'User-Agent', 'BlueDragonsCalc (supabase, 1.0)')
    );
    insert into public.discord_pedidos (request_id, vendedor_id) values (v_req, v.id);
    v_qtd := v_qtd + 1;
  end loop;
  -- Na atualização geral, busca também a lista de cargos do servidor.
  if p_vendedor_id is null then
    v_req := net.http_get(
      url := 'https://discord.com/api/v10/guilds/' || v_servidor || '/roles',
      headers := jsonb_build_object('Authorization', 'Bot ' || v_token, 'User-Agent', 'BlueDragonsCalc (supabase, 1.0)')
    );
    insert into public.discord_pedidos (request_id, tipo) values (v_req, 'cargos');
  end if;
  return v_qtd;
end;
$$;

-- Lê as respostas que já chegaram e atualiza os nomes.
create or replace function public._discord_aplicar_nomes()
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  r record;
  v_corpo jsonb;
  v_nome text;
  v_atualizados int := 0;
  v_fora int := 0;
  v_erro text;
begin
  for r in
    select p.request_id, p.vendedor_id, p.tipo, h.status_code, h.content, h.error_msg, h.timed_out
    from public.discord_pedidos p
    join net._http_response h on h.id = p.request_id
  loop
    begin
      v_corpo := r.content::jsonb;
    exception when others then
      v_corpo := null;
    end;

    if r.tipo = 'cargos' and r.status_code = 200 and jsonb_typeof(v_corpo) = 'array' then
      -- Lista de cargos do servidor (sem @everyone e sem cargos de bots/integrações).
      delete from public.discord_cargos where true; -- o Supabase recusa DELETE sem WHERE
      insert into public.discord_cargos (id, nome, cor, posicao)
      select c->>'id', left(c->>'name', 100), coalesce((c->>'color')::int, 0), coalesce((c->>'position')::int, 0)
      from jsonb_array_elements(v_corpo) c
      where c->>'id' <> (select discord_servidor_id from public.configuracoes where id = 1)
        and not coalesce((c->>'managed')::boolean, false);
    elsif r.status_code = 200 and v_corpo is not null then
      v_nome := coalesce(nullif(v_corpo->>'nick', ''), nullif(v_corpo->'user'->>'global_name', ''), v_corpo->'user'->>'username');
      update public.vendedores
         set nome_discord = left(v_nome, 40), no_servidor = true, nome_discord_em = now(),
             cargos = coalesce(array(select jsonb_array_elements_text(v_corpo->'roles')), '{}'),
             avatar = case
               when coalesce(v_corpo->>'avatar', '') ~ '^[a-z0-9_]+$' then
                 'https://cdn.discordapp.com/guilds/' || (select discord_servidor_id from public.configuracoes where id = 1)
                 || '/users/' || (v_corpo->'user'->>'id') || '/avatars/' || (v_corpo->>'avatar') || '.png?size=128'
               when coalesce(v_corpo->'user'->>'avatar', '') ~ '^[a-z0-9_]+$' then
                 'https://cdn.discordapp.com/avatars/' || (v_corpo->'user'->>'id') || '/' || (v_corpo->'user'->>'avatar') || '.png?size=128'
             end
       where id = r.vendedor_id;
      v_atualizados := v_atualizados + 1;
    elsif r.status_code = 404 and (v_corpo->>'code') = '10007' then
      -- Unknown Member: a pessoa não está no servidor (perde os cargos).
      update public.vendedores set no_servidor = false, cargos = '{}', nome_discord_em = now() where id = r.vendedor_id;
      v_fora := v_fora + 1;
    else
      v_erro := case
        when r.status_code = 401 then 'Token do bot inválido. Gere um novo e salve de novo.'
        when (v_corpo->>'code') = '10004' or r.status_code = 403 then 'O bot não está no servidor configurado. Convide o bot para o servidor.'
        when r.status_code = 429 then 'O Discord limitou as consultas. Tente de novo em alguns minutos.'
        when r.timed_out then 'O Discord não respondeu a tempo.'
        else 'Erro do Discord: ' || coalesce(r.status_code::text, '') || ' ' || coalesce(left(v_corpo->>'message', 120), r.error_msg, '')
      end;
    end if;
    delete from public.discord_pedidos where request_id = r.request_id;
  end loop;

  return jsonb_build_object('atualizados', v_atualizados, 'fora_do_servidor', v_fora, 'erro', v_erro,
                            'pendentes', (select count(*) from public.discord_pedidos));
end;
$$;

create or replace function public.discord_buscar_nomes(p_vendedor_id uuid default null)
returns int
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Acesso negado.';
  end if;
  if public._token_bot() is null then
    raise exception 'Configure o token do bot na aba Discord.';
  end if;
  if (select discord_servidor_id from public.configuracoes where id = 1) is null then
    raise exception 'Configure o ID do servidor na aba Discord.';
  end if;
  return public._discord_buscar_nomes(p_vendedor_id);
end;
$$;

-- Chamado pelo site logo após o login: atualiza nome e cargos de quem entrou
-- (no máximo uma consulta a cada 2 minutos por pessoa). O site chama duas vezes:
-- a primeira pede ao Discord, a segunda (1-2 s depois) aplica a resposta.
create or replace function public.atualizar_meu_discord()
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v public.vendedores := public._vendedor_atual();
  v_pendente boolean;
begin
  if v.id is null then
    return jsonb_build_object('pedido', false);
  end if;
  perform public._discord_aplicar_nomes();
  v := public._vendedor_atual(); -- recarrega: a resposta pode ter acabado de ser aplicada
  if v.id is null then
    return jsonb_build_object('pedido', false);
  end if;
  select exists (select 1 from public.discord_pedidos where vendedor_id = v.id) into v_pendente;
  if v_pendente then
    return jsonb_build_object('pedido', true);
  end if;
  if v.nome_discord_em is not null and v.nome_discord_em > now() - interval '2 minutes' then
    return jsonb_build_object('pedido', false);
  end if;
  return jsonb_build_object('pedido', public._discord_buscar_nomes(v.id) > 0);
end;
$$;

create or replace function public.discord_aplicar_nomes()
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Acesso negado.';
  end if;
  return public._discord_aplicar_nomes();
end;
$$;

-- -----------------------------------------------------------------------------
-- Fórum de parceiros no Discord
-- Dentro da categoria configurada, o bot mantém um fórum para cada produto que as
-- parcerias vendem (arma, munição…) e um post por parceria em cada fórum.
-- O post é atualizado quando a parceria muda e apagado quando ela é encerrada
-- (ou deixa de vender o produto). Roda a cada minuto e logo após salvar uma parceria.
-- -----------------------------------------------------------------------------

-- Uma chamada à API do Discord (síncrona, com a extensão http).
-- (criada sem checar o corpo: se a extensão http ainda não estiver ativa, o resto do script roda igual)
set check_function_bodies = off;
create or replace function public._discord_api(p_metodo text, p_caminho text, p_corpo jsonb default null)
returns table (status int, corpo jsonb)
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  v_resp extensions.http_response;
  v_corpo jsonb;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '5000');
  v_resp := extensions.http((
    p_metodo,
    'https://discord.com/api/v10' || p_caminho,
    array[extensions.http_header('Authorization', 'Bot ' || public._token_bot()),
          extensions.http_header('User-Agent', 'BlueDragonsCalc (supabase, 1.0)')],
    'application/json',
    case when p_corpo is null then null else p_corpo::text end
  )::extensions.http_request);
  begin
    v_corpo := nullif(v_resp.content, '')::jsonb;
  exception when others then
    v_corpo := jsonb_build_object('message', left(v_resp.content, 200));
  end;
  return query select v_resp.status, v_corpo;
end;
$$;
reset check_function_bodies;

-- Parcerias ativas × produtos que vendem (o que deve existir no fórum).
create or replace function public._forum_desejado()
returns table (parceria_id uuid, chave text, produto text)
language sql stable
as $$
  select p.id, public._chave_produto(x), min(x)
  from public.parcerias p, unnest(p.produtos) x
  where p.ativo and public._chave_produto(x) <> ''
  group by p.id, public._chave_produto(x);
$$;

-- Link público de uma imagem de parceria (caminho no bucket "parcerias").
create or replace function public._url_imagem_parceria(p_caminho text)
returns text
language sql stable
as $$
  select case when coalesce(p_caminho, '') = '' then null
    else rtrim((select supabase_url from public.configuracoes where id = 1), '/') || '/storage/v1/object/public/parcerias/' || p_caminho end;
$$;

-- Conteúdo do post de uma parceria, com as imagens cadastradas (e o hash, para só editar quando algo mudar).
create or replace function public._forum_post(p public.parcerias)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  c public.configuracoes;
  v_org text;
  v_link text;
  v_embed jsonb;
  v_embeds jsonb;
  v_img text;
begin
  select * into c from public.configuracoes where id = 1;
  v_org := c.nome_organizacao;
  v_link := c.site_url;  -- mesmo link em todos os embeds: o Discord junta as imagens numa galeria
  -- Topo: só o nome, grande. A tabela de preços aparece como imagem do post (embaixo das informações).
  v_embed := jsonb_strip_nulls(jsonb_build_object(
    'url', v_link,
    'image', case when p.img_banner is not null then jsonb_build_object('url', public._url_imagem_parceria(p.img_banner)) end,
    'description', '# ' || p.nome || coalesce(E'
' || p.observacoes, ''),
    'color', 3447003,
    'fields', jsonb_build_array(
      public._campo('📦 Vende', coalesce(nullif(array_to_string(p.produtos, ' · '), ''), '—'), false),
      public._campo('📞 Responsável / contato', p.responsavel),
      public._campo('✍️ Parceria feita por', p.feita_por_nome),
      public._campo('📅 Parceira desde', to_char(p.criado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY'))),
    'footer', jsonb_build_object('text', 'Atualizado automaticamente pela calculadora ' || v_org)));
  v_embeds := jsonb_build_array(v_embed);
  -- Tabela de preços (acima), localização e cores da organização formam a galeria do post.
  foreach v_img in array array[p.img_localizacao, p.img_cores] loop
    continue when v_img is null;
    v_embeds := v_embeds || jsonb_build_array(jsonb_build_object('url', v_link, 'image', jsonb_build_object('url', public._url_imagem_parceria(v_img))));
  end loop;
  return jsonb_build_object('nome', left(p.nome, 100), 'embeds', v_embeds, 'hash', md5(left(p.nome, 100) || v_embeds::text));
end;
$$;

create or replace function public._forum_erro(p_status int, p_corpo jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_msg text := case
    when p_status = 401 then 'Token do bot inválido. Salve um token novo.'
    when p_status = 403 or (p_corpo->>'code') in ('50001', '50013') then
      'O bot não tem permissão no servidor. Ele precisa ser Administrador: abra o link de convite da aba Discord e autorize de novo.'
    when p_status = 429 then 'O Discord limitou as chamadas. Continua sozinho no próximo minuto.'
    when p_status = 0 then coalesce(p_corpo->>'message', 'Erro.')
    else 'Erro do Discord: ' || coalesce(p_status::text, '') || ' ' || coalesce(left(p_corpo->>'message', 150), '')
  end;
begin
  insert into public.discord_estado (chave, valor, em) values ('erro', v_msg, now())
  on conflict (chave) do update set valor = excluded.valor, em = excluded.em;
  return jsonb_build_object('ativo', true, 'erro', v_msg);
end;
$$;

create or replace function public._forum_sincronizar(p_limite int default 25, p_forcar boolean default false)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  c public.configuracoes;
  v_srv text;
  v_cat text;
  r record;
  s int;
  b jsonb;
  v_feitos int := 0;
begin
  select * into c from public.configuracoes where id = 1;
  v_srv := c.discord_servidor_id;
  v_cat := c.discord_categoria_parceiros;
  if public._token_bot() is null or v_srv is null or v_cat is null then
    return jsonb_build_object('ativo', false);
  end if;
  if not exists (select 1 from pg_extension where extname = 'http') then
    return public._forum_erro(0, jsonb_build_object('message', 'Ative a extensão "http" no Supabase (Database → Extensions) e rode o schema.sql de novo.'));
  end if;
  -- Só uma sincronização por vez (cron e botão ao mesmo tempo duplicariam posts).
  if not pg_try_advisory_xact_lock(hashtext('bluedragons-forum')) then
    return jsonb_build_object('ativo', true, 'ocupado', true);
  end if;
  -- Depois de um erro, o agendamento espera 5 minutos (o botão tenta na hora).
  if not p_forcar and exists (select 1 from public.discord_estado where chave = 'erro' and em > now() - interval '5 minutes') then
    return jsonb_build_object('ativo', true, 'erro', (select valor from public.discord_estado where chave = 'erro'));
  end if;

  -- 1. Canais do servidor: confere a categoria e esquece os fóruns apagados. Só adota fóruns que o próprio bot
  --    criou (marcados no tópico); canais criados à mão na categoria nunca são alterados.
  select x.status, x.corpo into s, b from public._discord_api('GET', '/guilds/' || v_srv || '/channels') x;
  v_feitos := v_feitos + 1;
  if s <> 200 or jsonb_typeof(b) <> 'array' then return public._forum_erro(s, b); end if;
  if not exists (select 1 from jsonb_array_elements(b) e where e->>'id' = v_cat and (e->>'type')::int = 4) then
    return public._forum_erro(0, jsonb_build_object('message', 'A categoria ' || v_cat || ' não existe neste servidor (ou o bot não a enxerga).'));
  end if;
  delete from public.discord_foruns f
  where f.canal_id is not null and not exists (
    select 1 from jsonb_array_elements(b) e where e->>'id' = f.canal_id and e->>'parent_id' = v_cat);
  insert into public.discord_foruns (chave, nome, canal_id)
  select distinct on (public._chave_produto(e->>'name')) public._chave_produto(e->>'name'), e->>'name', e->>'id'
  from jsonb_array_elements(b) e
  where (e->>'type')::int = 15 and e->>'parent_id' = v_cat and public._chave_produto(e->>'name') <> ''
    and coalesce(e->>'topic', '') like '%Atualizado automaticamente pela calculadora.%'
  order by public._chave_produto(e->>'name'), (e->>'position')::int
  on conflict (chave) do update set canal_id = excluded.canal_id, nome = excluded.nome, atualizado_em = now()
    where public.discord_foruns.canal_id is null;
  delete from public.discord_posts p where not exists (select 1 from public.discord_foruns f where f.chave = p.chave);

  -- 2. Cria os fóruns que faltam (um por produto vendido).
  for r in
    select d.chave, min(d.produto) as produto
    from public._forum_desejado() d left join public.discord_foruns f on f.chave = d.chave
    where f.canal_id is null group by d.chave order by d.chave
  loop
    exit when v_feitos >= p_limite;
    select x.status, x.corpo into s, b from public._discord_api('POST', '/guilds/' || v_srv || '/channels', jsonb_build_object(
      'name', left(lower(regexp_replace(btrim(r.produto), '\s+', '-', 'g')), 100),
      'type', 15,
      'parent_id', v_cat,
      'topic', 'Parceiros que vendem ' || r.produto || '. Atualizado automaticamente pela calculadora.')) x;
    v_feitos := v_feitos + 1;
    if s not in (200, 201) then return public._forum_erro(s, b); end if;
    insert into public.discord_foruns (chave, nome, canal_id) values (r.chave, b->>'name', b->>'id')
    on conflict (chave) do update set canal_id = excluded.canal_id, nome = excluded.nome, atualizado_em = now();
  end loop;

  -- 3. Apaga os posts que não devem mais existir (parceria encerrada ou que parou de vender o produto).
  for r in
    select p.* from public.discord_posts p
    where not exists (select 1 from public._forum_desejado() d where d.parceria_id = p.parceria_id and d.chave = p.chave)
  loop
    exit when v_feitos >= p_limite;
    select x.status, x.corpo into s, b from public._discord_api('DELETE', '/channels/' || r.thread_id) x;
    v_feitos := v_feitos + 1;
    if s not in (200, 204, 404) then return public._forum_erro(s, b); end if;
    delete from public.discord_posts where parceria_id = r.parceria_id and chave = r.chave;
  end loop;

  -- 4. Cria os posts novos e atualiza os que mudaram.
  for r in
    select d.parceria_id, d.chave, f.canal_id, p.thread_id, p.hash, p.nome as nome_post, public._forum_post(pa) as post
    from public._forum_desejado() d
    join public.discord_foruns f on f.chave = d.chave and f.canal_id is not null
    join public.parcerias pa on pa.id = d.parceria_id
    left join public.discord_posts p on p.parceria_id = d.parceria_id and p.chave = d.chave
    order by pa.nome, d.chave
  loop
    continue when r.thread_id is not null and r.hash = r.post->>'hash';
    exit when v_feitos >= p_limite;
    if r.thread_id is null then
      select x.status, x.corpo into s, b from public._discord_api('POST', '/channels/' || r.canal_id || '/threads', jsonb_build_object(
        'name', r.post->>'nome',
        'auto_archive_duration', 10080,
        'message', jsonb_build_object('embeds', r.post->'embeds', 'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb)))) x;
      v_feitos := v_feitos + 1;
      if s not in (200, 201) then return public._forum_erro(s, b); end if;
      insert into public.discord_posts (parceria_id, chave, thread_id, nome, hash)
      values (r.parceria_id, r.chave, b->>'id', r.post->>'nome', r.post->>'hash')
      on conflict (parceria_id, chave) do update set thread_id = excluded.thread_id, nome = excluded.nome, hash = excluded.hash, atualizado_em = now();
    else
      -- Nome do post (e desarquiva, para poder editar).
      if r.nome_post is distinct from r.post->>'nome' then
        select x.status, x.corpo into s, b from public._discord_api('PATCH', '/channels/' || r.thread_id,
          jsonb_build_object('name', r.post->>'nome', 'archived', false)) x;
        v_feitos := v_feitos + 1;
        if s = 404 then delete from public.discord_posts where parceria_id = r.parceria_id and chave = r.chave; continue; end if;
        if s <> 200 then return public._forum_erro(s, b); end if;
      end if;
      -- A primeira mensagem do post tem o mesmo ID do post.
      select x.status, x.corpo into s, b from public._discord_api('PATCH', '/channels/' || r.thread_id || '/messages/' || r.thread_id,
        jsonb_build_object('embeds', r.post->'embeds')) x;
      v_feitos := v_feitos + 1;
      if s = 400 and (b->>'code') = '50083' then -- post arquivado: desarquiva e tenta de novo
        perform public._discord_api('PATCH', '/channels/' || r.thread_id, jsonb_build_object('archived', false));
        select x.status, x.corpo into s, b from public._discord_api('PATCH', '/channels/' || r.thread_id || '/messages/' || r.thread_id,
          jsonb_build_object('embeds', r.post->'embeds')) x;
        v_feitos := v_feitos + 2;
      end if;
      if s = 404 then -- apagado à mão: recria na próxima rodada
        delete from public.discord_posts where parceria_id = r.parceria_id and chave = r.chave;
        continue;
      end if;
      if s <> 200 then return public._forum_erro(s, b); end if;
      update public.discord_posts set hash = r.post->>'hash', nome = r.post->>'nome', atualizado_em = now()
      where parceria_id = r.parceria_id and chave = r.chave;
    end if;
  end loop;

  delete from public.discord_estado where chave = 'erro';
  insert into public.discord_estado (chave, valor, em) values ('ok', null, now())
  on conflict (chave) do update set em = excluded.em;
  return public._forum_resumo();
end;
$$;

create or replace function public._forum_resumo()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ativo', (select discord_categoria_parceiros is not null from public.configuracoes where id = 1) and public._token_bot() is not null,
    'erro', (select valor from public.discord_estado where chave = 'erro'),
    'erro_em', (select em from public.discord_estado where chave = 'erro'),
    'ok_em', (select em from public.discord_estado where chave = 'ok'),
    'foruns', coalesce((select jsonb_agg(jsonb_build_object('nome', f.nome, 'posts', (select count(*) from public.discord_posts p where p.chave = f.chave)) order by f.nome)
                        from public.discord_foruns f where f.canal_id is not null), '[]'::jsonb),
    'faltam', (select count(*) from public._forum_desejado() d
               where not exists (select 1 from public.discord_posts p where p.parceria_id = d.parceria_id and p.chave = d.chave)));
$$;

-- Botão "Sincronizar agora" (DEV) e atualização logo após salvar uma parceria.
create or replace function public.forum_sincronizar_agora()
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not public._e_dev() then raise exception 'Só o DEV pode configurar o Discord.'; end if;
  return public._forum_sincronizar(10, true);
end;
$$;

create or replace function public.forum_atualizar()
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not (public.tem_permissao('editar_parcerias') or public.tem_permissao('encerrar_parceria')) then
    raise exception 'Acesso negado.';
  end if;
  return public._forum_sincronizar(5, false);
exception when others then
  return jsonb_build_object('erro', sqlerrm);
end;
$$;

create or replace function public.forum_status()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public._e_dev() then raise exception 'Só o DEV pode configurar o Discord.'; end if;
  return public._forum_resumo();
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissões de execução das funções
-- -----------------------------------------------------------------------------

revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public._e_lider() to authenticated;
grant execute on function public.tem_permissao(text) to authenticated;
grant execute on function public.meu_perfil() to authenticated;
grant execute on function public.registrar_venda(jsonb, uuid, text, text) to authenticated;
grant execute on function public.minha_semana() to authenticated;
grant execute on function public.ranking_vendedores(date, date) to authenticated;
grant execute on function public.salvar_vendedor(uuid, text, text, boolean, boolean, uuid, text) to authenticated;
grant execute on function public.relatorio_periodo(date, date) to authenticated;
grant execute on function public.enviar_relatorio_discord(date) to authenticated;
grant execute on function public.registrar_pagamento(uuid, date, text) to authenticated;
grant execute on function public.encerrar_parceria(uuid, text) to authenticated;
grant execute on function public.cancelar_venda(uuid, text) to authenticated;
grant execute on function public.reativar_venda(uuid) to authenticated;
grant execute on function public.reativar_parceria(uuid) to authenticated;
grant execute on function public.perfil_parceria(uuid) to authenticated;
grant execute on function public.testar_webhook(text) to authenticated;
grant execute on function public.salvar_token_bot(text) to authenticated;
grant execute on function public.discord_status() to authenticated;
grant execute on function public.discord_buscar_nomes(uuid) to authenticated;
grant execute on function public.discord_aplicar_nomes() to authenticated;
grant execute on function public.atualizar_meu_discord() to authenticated;
grant execute on function public.minhas_novidades(boolean) to authenticated;
grant execute on function public.marcar_novidades_vistas() to authenticated;
grant execute on function public.novidades_pendentes() to authenticated;
grant execute on function public.decidir_novidades(bigint[], boolean, text) to authenticated;
grant execute on function public.enviar_notificacao(text, text, text, text) to authenticated;
revoke execute on function public._novidade(text, text, text) from public, anon, authenticated;
grant execute on function public.salvar_meu_id_pagamento(text) to authenticated;
grant execute on function public.vendas_por_parceria(date, date) to authenticated;
grant execute on function public.vendas_filtros() to authenticated;
grant execute on function public.enviar_relatorio_simulado() to authenticated;
grant execute on function public.forum_sincronizar_agora() to authenticated;
grant execute on function public.forum_atualizar() to authenticated;
grant execute on function public.forum_status() to authenticated;

-- -----------------------------------------------------------------------------
-- Agendamentos
-- -----------------------------------------------------------------------------

-- Relatório semanal: confere a cada 5 minutos se chegou o dia e o horário escolhidos na aba Discord.
select cron.unschedule(jobid) from cron.job where jobname = 'bluedragons-relatorio-semanal';
select cron.schedule('bluedragons-relatorio-semanal', '*/5 * * * *', 'select public._relatorio_automatico()');

-- Nomes do Discord: aplica as respostas anteriores e pede os nomes de novo a cada 10 minutos.
select cron.unschedule(jobid) from cron.job where jobname = 'bluedragons-nomes-discord';
select cron.schedule('bluedragons-nomes-discord', '*/10 * * * *', 'select public._discord_aplicar_nomes(); select public._discord_buscar_nomes(null);');

-- Fórum de parceiros: confere e atualiza a cada minuto (sem categoria configurada, não faz nada).
select cron.unschedule(jobid) from cron.job where jobname = 'bluedragons-forum-parceiros';
select cron.schedule('bluedragons-forum-parceiros', '* * * * *', 'select public._forum_sincronizar()');

-- Novidades com mais de 90 dias saem da lista.
select cron.unschedule(jobid) from cron.job where jobname = 'bluedragons-limpar-novidades';
select cron.schedule('bluedragons-limpar-novidades', '30 7 * * *', $$delete from public.novidades where criado_em < now() - interval '90 days' or (not publicada and criado_em < now() - interval '1 day')$$);
