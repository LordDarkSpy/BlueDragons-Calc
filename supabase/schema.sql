-- =============================================================================
-- Blue Dragons — Calculadora e Gestão de Vendas
-- Rode este arquivo inteiro no Supabase: Dashboard → SQL Editor → New query.
-- Pode ser executado de novo sem perder dados (idempotente).
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net;
create extension if not exists pg_cron;

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

-- Imagens das parcerias: bucket privado, só administradores leem e enviam.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('parcerias', 'parcerias', false, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
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

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  -- Admin: marcado no cadastro OU com um dos cargos do servidor escolhidos no painel.
  select exists (select 1 from public.admins where user_id = auth.uid())
      or exists (select 1 from public.devs where discord_id = public._discord_id())
      or exists (
        select 1 from public.vendedores v, public.configuracoes c
        where c.id = 1 and v.ativo and v.discord_id = public._discord_id()
          and (v.admin or v.cargos && c.cargos_admin)
      );
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

-- Ações de impacto que o líder libera por cargo.
create or replace function public._permissoes_validas()
returns text[]
language sql immutable
as $$ select array['encerrar_parceria', 'registrar_pagamento', 'cancelar_venda', 'gerenciar_vendedores', 'gerenciar_produtos'] $$;

create or replace function public.tem_permissao(p_permissao text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select public.is_admin() and (
    public._e_lider()
    or exists (
      select 1 from public.vendedores v, public.configuracoes c
      where c.id = 1 and v.ativo and v.discord_id = public._discord_id()
        and v.cargos && coalesce(array(select jsonb_array_elements_text(coalesce(c.permissoes -> p_permissao, '[]'::jsonb))), '{}')
    ));
$$;

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
  update (nome, responsavel, observacoes, produtos, localizacao, img_localizacao, img_banner, img_cores, feita_por_id, feita_por_nome),
  delete on public.parcerias to authenticated;

alter table public.parceria_historico enable row level security;
revoke all on public.parceria_historico from anon, authenticated;
grant select on public.parceria_historico to authenticated;
drop policy if exists parceria_historico_admin on public.parceria_historico;
create policy parceria_historico_admin on public.parceria_historico for select to authenticated
  using (public.is_admin());

drop policy if exists parcerias_imagens_ler on storage.objects;
create policy parcerias_imagens_ler on storage.objects for select to authenticated
  using (bucket_id = 'parcerias' and public.is_admin());
drop policy if exists parcerias_imagens_enviar on storage.objects;
create policy parcerias_imagens_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'parcerias' and public.is_admin());
drop policy if exists parcerias_imagens_alterar on storage.objects;
create policy parcerias_imagens_alterar on storage.objects for update to authenticated
  using (bucket_id = 'parcerias' and public.is_admin()) with check (bucket_id = 'parcerias' and public.is_admin());
drop policy if exists parcerias_imagens_apagar on storage.objects;
create policy parcerias_imagens_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'parcerias' and public.is_admin());

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
create policy parcerias_admin on public.parcerias for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Vendedores: só o admin lê. Criação/edição via RPC salvar_vendedor.
grant select (id, nome, discord_id, admin, ativo, criado_em, nome_discord, no_servidor, nome_discord_em, cargos, avatar) on public.vendedores to authenticated;
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
  using (public.is_admin());
drop policy if exists vendas_admin_update on public.vendas;
drop policy if exists venda_itens_admin on public.venda_itens;
create policy venda_itens_admin on public.venda_itens for select to authenticated
  using (public.is_admin());

-- Pagamentos: só o admin lê. Registro somente pela função registrar_pagamento.
alter table public.pagamentos enable row level security;
revoke all on public.pagamentos from anon, authenticated;
grant select on public.pagamentos to authenticated;
drop policy if exists pagamentos_admin on public.pagamentos;
create policy pagamentos_admin on public.pagamentos for select to authenticated
  using (public.is_admin());

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
  -- Pelo site (usuário logado): fora a gestão (permissões e cargos de acesso), tudo é do DEV. (Jobs do banco não têm usuário.)
  if auth.uid() is not null and not public._e_dev()
     and (to_jsonb(new) - 'permissoes' - 'cargos_admin' - 'atualizado_em') is distinct from (to_jsonb(old) - 'permissoes' - 'cargos_admin' - 'atualizado_em') then
    raise exception 'Só o DEV pode alterar as configurações do Discord e do site.';
  end if;
  -- Gestão (líder): permissões e cargos que acessam o painel.
  if auth.uid() is not null and (new.permissoes is distinct from old.permissoes or new.cargos_admin is distinct from old.cargos_admin)
     and not public._e_lider() then
    raise exception 'Só o líder pode alterar a gestão de acessos e permissões.';
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
    'permissoes', (select coalesce(jsonb_object_agg(p, public.tem_permissao(p)), '{}'::jsonb) from unnest(public._permissoes_validas()) p)
  )
  from (select (public._vendedor_atual()).*) v;
$$;

-- Monta e envia (de forma assíncrona) o aviso de venda para o Discord.
create or replace function public._notificar_venda(p_venda_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare
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

  v_campos := jsonb_build_array(
    jsonb_build_object('name', 'Vendedor', 'value', v.vendedor_nome, 'inline', true),
    jsonb_build_object('name', 'Tipo de venda', 'value',
      case when v.com_parceria then 'Com parceria' else 'Pista' end, 'inline', true)
  );
  if v.com_parceria then
    v_campos := v_campos || jsonb_build_object('name', 'Parceria', 'value', coalesce(v.parceria_nome, '—'), 'inline', true);
  end if;
  if coalesce(v.cliente, '') <> '' then
    v_campos := v_campos || jsonb_build_object('name', 'Cliente', 'value', v.cliente, 'inline', true);
  end if;
  v_campos := v_campos || jsonb_build_array(
    jsonb_build_object('name', 'Itens', 'value', left(coalesce(v_itens, '—'), 1024)),
    jsonb_build_object('name', 'Total', 'value', '**' || public._formatar_valor(v.total) || '**', 'inline', true),
    jsonb_build_object('name', 'Comissão', 'value', public._formatar_valor(v.comissao), 'inline', true)
  );
  if coalesce(v.observacao, '') <> '' then
    v_campos := v_campos || jsonb_build_object('name', 'Observação', 'value', left(v.observacao, 1024));
  end if;

  v_corpo := jsonb_build_object(
    'username', c.nome_organizacao || ' — Vendas',
    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
    'embeds', jsonb_build_array(jsonb_build_object(
      'title', '🐉 Venda #' || v.numero,
      'color', 2001125,
      'fields', v_campos,
      'footer', jsonb_build_object('text', 'Calculadora ' || c.nome_organizacao),
      'timestamp', to_char(v.criado_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ))
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
           sum(i.quantidade)::int * p.craft_placa as craft_placa,
           sum(i.quantidade)::int * p.craft_material as craft_material,
           p.material_nome
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
  values (v_vendedor.id, coalesce(v_vendedor.nome_discord, v_vendedor.nome), v_parceria.id, v_parceria.nome, v_com,
          nullif(left(trim(coalesce(p_cliente, '')), 60), ''),
          v_total, v_comissao,
          nullif(left(trim(coalesce(p_observacao, '')), 300), ''))
  returning id, numero into v_id, v_numero;

  insert into public.venda_itens (venda_id, produto_id, produto_nome, icone, quantidade, preco_unitario, subtotal,
                                  comissao, craft_placa, craft_material, material_nome)
  select v_id, l.produto_id, l.nome, l.icone, l.quantidade, l.preco, l.quantidade * l.preco,
         l.comissao, l.craft_placa, l.craft_material, l.material_nome
  from jsonb_to_recordset(v_linhas) as l (produto_id uuid, nome text, icone text, quantidade int, preco numeric,
                                          comissao numeric, craft_placa int, craft_material int, material_nome text)
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

create or replace function public.salvar_vendedor(
  p_id uuid,
  p_nome text,
  p_discord_id text,
  p_ativo boolean,
  p_admin boolean
)
returns uuid
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_discord text := trim(coalesce(p_discord_id, ''));
  v_proprio boolean;
  v_admin_atual boolean;
begin
  if not public.tem_permissao('gerenciar_vendedores') then
    raise exception 'Você não tem permissão para gerenciar vendedores.';
  end if;
  -- Administrador manual = líder: só um líder pode dar ou tirar.
  select admin into v_admin_atual from public.vendedores where id = p_id;
  if coalesce(p_admin, false) is distinct from coalesce(v_admin_atual, false) and not public._e_lider() then
    raise exception 'Só o líder pode marcar ou desmarcar administrador manual.';
  end if;
  if v_discord !~ '^\d{17,20}$' then
    raise exception 'ID do Discord inválido: deve ter de 17 a 20 números.';
  end if;
  if exists (select 1 from public.vendedores where discord_id = v_discord and id is distinct from p_id) then
    raise exception 'Já existe um cadastro com este ID do Discord.';
  end if;

  if p_id is null then
    insert into public.vendedores (nome, discord_id, ativo, admin)
    values (trim(p_nome), v_discord, coalesce(p_ativo, true), coalesce(p_admin, false))
    returning id into v_id;
  else
    -- Ninguém tira o próprio acesso ao painel (evita ficar sem nenhum admin).
    -- (tirar o "Administrador" manual só é permitido se o cargo do servidor já der acesso).
    select discord_id = public._discord_id() into v_proprio from public.vendedores where id = p_id;
    if v_proprio and (p_ativo is false or v_discord <> public._discord_id()
        or (p_admin is false and not exists (
              select 1 from public.vendedores ve, public.configuracoes c
              where ve.id = p_id and c.id = 1 and ve.cargos && c.cargos_admin))) then
      raise exception 'Você não pode remover o seu próprio acesso de administrador.';
    end if;
    update public.vendedores
       set nome = trim(p_nome),
           discord_id = v_discord,
           ativo = coalesce(p_ativo, ativo),
           admin = coalesce(p_admin, admin)
     where id = p_id
     returning id into v_id;
    if v_id is null then
      raise exception 'Vendedor não encontrado.';
    end if;
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
  if tg_op = 'INSERT' then
    insert into public.parceria_historico (parceria_id, tipo, descricao, autor)
    values (new.id, 'criada', 'Parceria cadastrada' || coalesce(' por ' || new.feita_por_nome, '') || '.', public._nome_logado());
    return new;
  end if;
  if new.nome is distinct from old.nome then v_mudou := v_mudou || ('nome: ' || old.nome || ' → ' || new.nome); end if;
  if new.responsavel is distinct from old.responsavel then v_mudou := v_mudou || 'responsável'::text; end if;
  if new.observacoes is distinct from old.observacoes then v_mudou := v_mudou || 'observações'::text; end if;
  if new.produtos is distinct from old.produtos then v_mudou := v_mudou || 'produtos'::text; end if;
  if new.localizacao is distinct from old.localizacao then v_mudou := v_mudou || 'localização'::text; end if;
  if new.img_localizacao is distinct from old.img_localizacao then v_mudou := v_mudou || 'imagem da localização'::text; end if;
  if new.img_banner is distinct from old.img_banner then v_mudou := v_mudou || 'banner'::text; end if;
  if new.img_cores is distinct from old.img_cores then v_mudou := v_mudou || 'cores da organização'::text; end if;
  if new.feita_por_id is distinct from old.feita_por_id then v_mudou := v_mudou || ('feita por: ' || coalesce(new.feita_por_nome, '—')); end if;
  if array_length(v_mudou, 1) > 0 then
    insert into public.parceria_historico (parceria_id, tipo, descricao, autor)
    values (new.id, 'editada', 'Alterado: ' || array_to_string(v_mudou, ', ') || '.', public._nome_logado());
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
  if not public.is_admin() then raise exception 'Acesso negado.'; end if;
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
               sum(i.craft_placa) as craft_placa, sum(i.craft_material) as craft_material, max(i.material_nome) as material_nome
        from public.venda_itens i join v on v.id = i.venda_id
        left join public.produtos pr on pr.id = i.produto_id
        group by i.produto_nome
      ) x), '[]'::jsonb),
    'craft', coalesce((
      select jsonb_agg(x order by x.nome) from (
        select 'Placa' as nome, sum(i.craft_placa) as quantidade
        from public.venda_itens i join v on v.id = i.venda_id
        having sum(i.craft_placa) > 0
        union all
        select coalesce(i.material_nome, 'Material'), sum(i.craft_material)
        from public.venda_itens i join v on v.id = i.venda_id
        group by coalesce(i.material_nome, 'Material')
        having sum(i.craft_material) > 0
      ) x), '[]'::jsonb)
  );
$$;

create or replace function public.relatorio_periodo(p_inicio date, p_fim date)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Acesso negado.';
  end if;
  return public._relatorio(p_inicio, p_fim);
end;
$$;

create or replace function public._linhas_relatorio(p_lista jsonb, p_com_icone boolean default false)
returns text
language sql stable
as $$
  select coalesce(left(string_agg(
           (case when p_com_icone and e->>'icone' is not null then e->>'icone' || ' ' else '' end)
           || '**' || (e->>'nome') || '** — ' || public._formatar_valor((e->>'total')::numeric)
           || ' (' || (e->>'quantidade') || ')', E'\n' order by ord), 1024), '—')
  from jsonb_array_elements(p_lista) with ordinality as t (e, ord)
  where ord <= 15;
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

  perform net.http_post(url := v_url, body := jsonb_build_object(
    'username', c.nome_organizacao || ' — Relatórios',
    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
    'embeds', jsonb_build_array(jsonb_build_object(
      'title', '📊 Relatório semanal — ' || to_char(v_ini, 'DD/MM') || ' a ' || to_char(v_ini + 6, 'DD/MM/YYYY'),
      'color', 2001125,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Total vendido', 'value', '**' || public._formatar_valor((r->>'total')::numeric) || '**', 'inline', true),
        jsonb_build_object('name', 'Vendas', 'value', r->>'quantidade', 'inline', true),
        jsonb_build_object('name', 'Com parceria', 'value', public._formatar_valor((r->>'total_com_parceria')::numeric), 'inline', true),
        jsonb_build_object('name', 'Pista', 'value', public._formatar_valor((r->>'total_sem_parceria')::numeric), 'inline', true),
        jsonb_build_object('name', 'Comissões', 'value', public._formatar_valor((r->>'comissao')::numeric), 'inline', true),
        jsonb_build_object('name', '🏆 Vendedores', 'value', public._linhas_relatorio(r->'por_vendedor')),
        jsonb_build_object('name', '💰 Pagamento (' || round((r->>'percentual_comissao')::numeric * 100) || '%)', 'value', coalesce((
          select left(string_agg('**' || (e->>'nome') || '** — ' || public._formatar_valor((e->>'comissao')::numeric)
                   || case when (e->>'pendente')::numeric <= 0 then ' ✅ pago' else ' ⏳ pendente' end, E'\n' order by ord), 1024)
          from jsonb_array_elements(r->'por_vendedor') with ordinality as t (e, ord) where ord <= 20), '—')),
        jsonb_build_object('name', '🤝 Parcerias', 'value', public._linhas_relatorio(r->'por_parceria')),
        jsonb_build_object('name', '📦 Produtos', 'value', public._linhas_relatorio(r->'por_produto', true)),
        jsonb_build_object('name', '🔧 Craft usado', 'value', coalesce((
          select string_agg((e->>'nome') || ': **' || (e->>'quantidade') || '**', ' · ')
          from jsonb_array_elements(r->'craft') e), '—'))
      ),
      'footer', jsonb_build_object('text', 'Calculadora ' || c.nome_organizacao),
      'timestamp', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ))
  ));
  return r;
end;
$$;

create or replace function public.enviar_relatorio_discord(p_inicio date)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Acesso negado.';
  end if;
  return public._enviar_relatorio(p_inicio);
end;
$$;

-- Usado pelo agendamento: envia o relatório da semana anterior.
create or replace function public._relatorio_automatico()
returns void
language plpgsql volatile security definer
set search_path = public
as $$
begin
  if (select relatorio_automatico from public.configuracoes where id = 1) then
    perform public._enviar_relatorio(((now() at time zone 'America/Sao_Paulo')::date - 7));
  end if;
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

  -- Aviso no Discord (falha no envio não desfaz o pagamento).
  begin
    select * into c from public.configuracoes where id = 1;
    v_url := coalesce(nullif(c.webhook_relatorios, ''), nullif(c.webhook_vendas, ''));
    if v_url is not null then
      v_campos := jsonb_build_array(
        jsonb_build_object('name', 'Vendedor', 'value', v_nome, 'inline', true),
        jsonb_build_object('name', 'Semana', 'value', to_char(v_ini, 'DD/MM') || ' a ' || to_char(v_ini + 6, 'DD/MM/YYYY'), 'inline', true),
        jsonb_build_object('name', 'Valor pago', 'value', '**' || public._formatar_valor(v_valor) || '**', 'inline', true),
        jsonb_build_object('name', 'Pago por', 'value', v_quem, 'inline', true)
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

  return jsonb_build_object('id', v_id, 'valor', v_valor, 'semana_inicio', v_ini, 'notificado', v_url is not null);
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
    'servidor_id', (select discord_servidor_id from public.configuracoes where id = 1),
    'pendentes', (select count(*) from public.discord_pedidos)
  );
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
grant execute on function public.salvar_vendedor(uuid, text, text, boolean, boolean) to authenticated;
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

-- -----------------------------------------------------------------------------
-- Agendamento: relatório semanal toda segunda às 09:00 (horário de Brasília).
-- -----------------------------------------------------------------------------

select cron.unschedule(jobid) from cron.job where jobname = 'bluedragons-relatorio-semanal';
select cron.schedule('bluedragons-relatorio-semanal', '0 12 * * 1', 'select public._relatorio_automatico()');

-- Nomes do Discord: aplica as respostas anteriores e pede os nomes de novo a cada 10 minutos.
select cron.unschedule(jobid) from cron.job where jobname = 'bluedragons-nomes-discord';
select cron.schedule('bluedragons-nomes-discord', '*/10 * * * *', 'select public._discord_aplicar_nomes(); select public._discord_buscar_nomes(null);');
