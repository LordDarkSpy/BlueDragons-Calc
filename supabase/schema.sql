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

-- Pedidos feitos ao Discord (pg_net responde de forma assíncrona).
create table if not exists public.discord_pedidos (
  request_id bigint primary key,
  vendedor_id uuid not null references public.vendedores (id) on delete cascade,
  criado_em timestamptz not null default now()
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
  select exists (select 1 from public.admins where user_id = auth.uid())
      or coalesce((public._vendedor_atual()).admin, false);
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
grant select on public.produtos, public.parcerias to anon, authenticated;
grant insert, update, delete on public.produtos, public.parcerias to authenticated;

drop policy if exists produtos_leitura on public.produtos;
create policy produtos_leitura on public.produtos for select
  using (ativo or public.is_admin());
drop policy if exists produtos_admin on public.produtos;
create policy produtos_admin on public.produtos for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists parcerias_leitura on public.parcerias;
create policy parcerias_leitura on public.parcerias for select
  using (ativo or public.is_admin());
drop policy if exists parcerias_admin on public.parcerias;
create policy parcerias_admin on public.parcerias for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Vendedores: só o admin lê. Criação/edição via RPC salvar_vendedor.
grant select (id, nome, discord_id, admin, ativo, criado_em, nome_discord, no_servidor, nome_discord_em) on public.vendedores to authenticated;
alter table public.discord_pedidos enable row level security;
revoke all on public.discord_pedidos from anon, authenticated;
drop policy if exists vendedores_admin on public.vendedores;
create policy vendedores_admin on public.vendedores for select to authenticated
  using (public.is_admin());

-- Vendas: só o admin lê e cancela. Registro somente pela função registrar_venda.
grant select on public.vendas, public.venda_itens to authenticated;
grant update (cancelada, cancelada_em) on public.vendas to authenticated;
drop policy if exists vendas_admin_leitura on public.vendas;
create policy vendas_admin_leitura on public.vendas for select to authenticated
  using (public.is_admin());
drop policy if exists vendas_admin_update on public.vendas;
create policy vendas_admin_update on public.vendas for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists venda_itens_admin on public.venda_itens;
create policy venda_itens_admin on public.venda_itens for select to authenticated
  using (public.is_admin());

-- Configurações: só o admin.
grant select, update on public.configuracoes to authenticated;
drop policy if exists configuracoes_admin on public.configuracoes;
create policy configuracoes_admin on public.configuracoes for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

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
    'admin', public.is_admin()
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
begin
  if not public.is_admin() then
    raise exception 'Acesso negado.';
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
    select discord_id = public._discord_id() into v_proprio from public.vendedores where id = p_id;
    if v_proprio and (p_admin is false or p_ativo is false or v_discord <> public._discord_id()) then
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
        select coalesce(max(vd.nome_discord), max(vd.nome), max(v.vendedor_nome)) as nome,
               count(*) as quantidade, sum(v.total) as total, sum(v.comissao) as comissao
        from v left join public.vendedores vd on vd.id = v.vendedor_id
        group by v.vendedor_id
      ) x), '[]'::jsonb),
    'por_parceria', coalesce((
      select jsonb_agg(x order by x.total desc) from (
        select coalesce(parceria_nome, 'Pista (sem parceria)') as nome, count(*) as quantidade, sum(total) as total
        from v group by coalesce(parceria_nome, 'Pista (sem parceria)')
      ) x), '[]'::jsonb),
    'por_produto', coalesce((
      select jsonb_agg(x order by x.total desc) from (
        select i.produto_nome as nome, max(i.icone) as icone, sum(i.quantidade) as quantidade, sum(i.subtotal) as total,
               sum(i.craft_placa) as craft_placa, sum(i.craft_material) as craft_material, max(i.material_nome) as material_nome
        from public.venda_itens i join v on v.id = i.venda_id
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
        jsonb_build_object('name', 'Ticket médio', 'value',
          public._formatar_valor(case when (r->>'quantidade')::int > 0 then (r->>'total')::numeric / (r->>'quantidade')::int else 0 end), 'inline', true),
        jsonb_build_object('name', 'Com parceria', 'value', public._formatar_valor((r->>'total_com_parceria')::numeric), 'inline', true),
        jsonb_build_object('name', 'Pista', 'value', public._formatar_valor((r->>'total_sem_parceria')::numeric), 'inline', true),
        jsonb_build_object('name', 'Comissões', 'value', public._formatar_valor((r->>'comissao')::numeric), 'inline', true),
        jsonb_build_object('name', '🏆 Vendedores', 'value', public._linhas_relatorio(r->'por_vendedor')),
        jsonb_build_object('name', '💰 Pagamento (' || round((r->>'percentual_comissao')::numeric * 100) || '%)', 'value', coalesce((
          select left(string_agg('**' || (e->>'nome') || '** — ' || public._formatar_valor((e->>'comissao')::numeric), E'\n' order by ord), 1024)
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
  if not public.is_admin() then
    raise exception 'Acesso negado.';
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
  if not public.is_admin() then
    raise exception 'Acesso negado.';
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
    select p.request_id, p.vendedor_id, h.status_code, h.content, h.error_msg, h.timed_out
    from public.discord_pedidos p
    join net._http_response h on h.id = p.request_id
  loop
    begin
      v_corpo := r.content::jsonb;
    exception when others then
      v_corpo := null;
    end;

    if r.status_code = 200 and v_corpo is not null then
      v_nome := coalesce(nullif(v_corpo->>'nick', ''), nullif(v_corpo->'user'->>'global_name', ''), v_corpo->'user'->>'username');
      update public.vendedores
         set nome_discord = left(v_nome, 40), no_servidor = true, nome_discord_em = now()
       where id = r.vendedor_id;
      v_atualizados := v_atualizados + 1;
    elsif r.status_code = 404 and (v_corpo->>'code') = '10007' then
      -- Unknown Member: a pessoa não está no servidor.
      update public.vendedores set no_servidor = false, nome_discord_em = now() where id = r.vendedor_id;
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
grant execute on function public.meu_perfil() to authenticated;
grant execute on function public.registrar_venda(jsonb, uuid, text, text) to authenticated;
grant execute on function public.minha_semana() to authenticated;
grant execute on function public.salvar_vendedor(uuid, text, text, boolean, boolean) to authenticated;
grant execute on function public.relatorio_periodo(date, date) to authenticated;
grant execute on function public.enviar_relatorio_discord(date) to authenticated;
grant execute on function public.testar_webhook(text) to authenticated;
grant execute on function public.salvar_token_bot(text) to authenticated;
grant execute on function public.discord_status() to authenticated;
grant execute on function public.discord_buscar_nomes(uuid) to authenticated;
grant execute on function public.discord_aplicar_nomes() to authenticated;

-- -----------------------------------------------------------------------------
-- Agendamento: relatório semanal toda segunda às 09:00 (horário de Brasília).
-- -----------------------------------------------------------------------------

select cron.unschedule(jobid) from cron.job where jobname = 'bluedragons-relatorio-semanal';
select cron.schedule('bluedragons-relatorio-semanal', '0 12 * * 1', 'select public._relatorio_automatico()');

-- Nomes do Discord: aplica as respostas anteriores e pede os nomes de novo a cada 10 minutos.
select cron.unschedule(jobid) from cron.job where jobname = 'bluedragons-nomes-discord';
select cron.schedule('bluedragons-nomes-discord', '*/10 * * * *', 'select public._discord_aplicar_nomes(); select public._discord_buscar_nomes(null);');
