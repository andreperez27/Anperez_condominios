-- ============================================================================
-- MIGRATION 002 — FASE 0: CONDOMÍNIO, PESSOAS E PAPÉIS
-- ============================================================================
-- O condomínio é a unidade central do modelo. Tudo que é financeiro ou pessoal
-- é escopado por `condominio_id` — mesmo que hoje exista um só condomínio.
--
-- Documento de referência: docs\MODELO_DADOS.md §4
--
-- RLS: ligada e forçada em todas as tabelas. As policies vêm na migration de
-- papéis (012), porque precisam dos helpers. Aqui deixamos as tabelas já
-- trancadas: sem policy, o default do Postgres é "negar tudo".
--
-- NOTA SOBRE SEQUÊNCIAS: os `id` usam `gen_random_uuid()`, que NÃO cria
-- sequência. Por isso a revogação de sequência é feita de forma DINÂMICA
-- (bloco DO), e não com nomes fixos — que quebrariam a migration.
--
-- ----------------------------------------------------------------------------
-- ROLES DE APLICAÇÃO
-- ----------------------------------------------------------------------------
-- app_owner: dono das funções e views privilegiadas. Sem login, com BYPASSRLS.
--   ⚠️ O Supabase local PERMITE criar role com BYPASSRLS — verificado em
--   11/11/2026: `create role app_owner nologin bypassrls;` → CREATE ROLE.
--   Se um ambiente não permitir, o plano B (documentado no diário) é usar o
--   postgres como dono.
--
-- app_importador: role do script Python de importação. Só escreve em
--   staging_* — nunca em lancamentos.
--
-- ⚠️ IDEMPOTÊNCIA: o roteiro de implantação pede que o role `app_owner` seja
-- criado ANTES do `db push` (para testar se o ambiente permite BYPASSRLS).
-- Se ele já existir, esta migration NÃO pode falhar — e precisa GARANTIR
-- que ele ficou com BYPASSRLS, senão as funções privilegiadas passam a
-- depender das policies (que é justamente o que o modelo evita).
do $$
declare
    v_existe boolean;
    v_bypass boolean;
begin
    -- app_owner
    select exists (select 1 from pg_roles where rolname = 'app_owner'),
           coalesce((select rolbypassrls from pg_roles where rolname = 'app_owner'), false)
      into v_existe, v_bypass;

    if not v_existe then
        create role app_owner nologin bypassrls;
    elsif not v_bypass then
        -- Já existia SEM bypassrls (criado manualmente no teste do roteiro):
        -- garante o atributo. Se o ambiente não permitir, a mensagem diz
        -- exatamente o que fazer (plano B).
        begin
            alter role app_owner bypassrls;
        exception when insufficient_privilege then
            raise exception
                'O role app_owner existe mas NAO tem BYPASSRLS, e este ambiente '
                'nao permite alterar o atributo. Use o PLANO B: o postgres como '
                'dono das funcoes privilegiadas (docs\DEPLOY_REMOTO.md 3.1).';
        end;
    end if;

    -- app_importador
    if not exists (select 1 from pg_roles where rolname = 'app_importador') then
        create role app_importador nologin;
    end if;
end
$$;

comment on role app_owner is
    'Dono das funções e views privilegiadas. Sem login, com BYPASSRLS. '
    'Exige filtro de tenant manual em cada função/view.';

comment on role app_importador is
    'Role do script de importação. Só escreve em staging_* — nunca em lancamentos.';

-- O papel `postgres` (que executa as migrations) NÃO é superuser no Supabase
-- local, e o Postgres exige que quem altera a propriedade de um objeto seja
-- MEMBRO do papel de destino ("must be able to SET ROLE").
-- Verificado em 11/11/2026: sem esta linha, `alter function ... owner to
-- app_owner` falha com SQLSTATE 42501.
--
-- Sem risco de escalonamento: `postgres` já tem BYPASSRLS, e `app_owner`
-- também — a adesão não concede nada que o postgres não tivesse.
grant app_owner to postgres;

-- O `postgres` também precisa poder assumir o app_importador: é assim que
-- a bateria de testes exercita o comportamento do importador (set role
-- app_importador). Sem risco de escalonamento — o postgres já tem
-- BYPASSRLS e privilégio total no schema public.
grant app_importador to postgres;

-- Para RECEBER a propriedade de um objeto, o papel de destino precisa de
-- CREATE no schema que o contém. Sem esta linha, `alter function ... owner
-- to app_owner` falha com "permission denied for schema public".
-- Verificado em 11/11/2026.
grant usage, create on schema public to app_owner;

-- ----------------------------------------------------------------------------
-- CONDOMÍNIOS
-- ----------------------------------------------------------------------------
create table if not exists public.condominios (
    id            uuid primary key default gen_random_uuid(),
    nome          text not null,
    cnpj          text,
    endereco      text,
    cidade        text,
    uf            char(2),
    ativo         boolean not null default true,
    criado_em     timestamptz not null default now(),
    atualizado_em timestamptz not null default now(),
    constraint condominios_cnpj_formato
        check (cnpj is null or cnpj ~ '^[0-9]{2}\.[0-9]{3}\.[0-9]{3}/[0-9]{4}-[0-9]{2}$')
);

comment on table public.condominios is
    'Unidade central do modelo. Tudo que é financeiro ou pessoal é escopado por condominio_id.';

create unique index if not exists uq_condominios_cnpj
    on public.condominios (cnpj) where cnpj is not null;

-- ----------------------------------------------------------------------------
-- PERFIS (extensão de auth.users)
-- ----------------------------------------------------------------------------
-- Perfil NÃO carrega condomínio nem papel — isso é da tabela de membros.
create table if not exists public.perfis (
    id          uuid primary key references auth.users(id) on delete cascade,
    nome        text not null,
    email       text not null,
    criado_em   timestamptz not null default now()
);

comment on table public.perfis is
    'Dados de apresentação do usuário. O condomínio e o papel ficam em membros.';

create unique index if not exists uq_perfis_email on public.perfis (lower(email));

-- ----------------------------------------------------------------------------
-- MEMBROS (condomínio × pessoa × papel)
-- ----------------------------------------------------------------------------
-- Uma pessoa pode ter papéis diferentes em condomínios diferentes. O papel é
-- SEMPRE avaliado no condomínio da linha que está sendo lida.
create table if not exists public.membros (
    id            uuid primary key default gen_random_uuid(),
    condominio_id uuid not null references public.condominios(id) on delete cascade,
    perfil_id     uuid not null references public.perfis(id) on delete cascade,
    papel         public.papel_membro not null,
    -- Propósito declarado do acesso. Auditorado; base da minimização LGPD.
    finalidade   text,
    ativo         boolean not null default true,
    convidado_em  timestamptz,
    aceitou_em    timestamptz,
    criado_em     timestamptz not null default now(),
    constraint membros_unico_por_papel
        unique (condominio_id, perfil_id, papel)
);

comment on table public.membros is
    'Papel do usuário NO CONDOMÍNIO. A separação leitor/auditor acontece aqui, '
    'não em privilégio de banco: todos os autenticados são o role authenticated.';

create index if not exists ix_membros_perfil
    on public.membros (perfil_id) where ativo;
create index if not exists ix_membros_condominio
    on public.membros (condominio_id, papel) where ativo;

-- ----------------------------------------------------------------------------
-- CONVITES
-- ----------------------------------------------------------------------------
-- Guardamos só o HASH do token: o token em claro nunca entra no banco.
create table if not exists public.convites (
    id            uuid primary key default gen_random_uuid(),
    condominio_id uuid not null references public.condominios(id) on delete cascade,
    email         text not null,
    papel         public.papel_membro not null,
    token_hash    text not null unique,
    expira_em     timestamptz not null,
    aceito_em     timestamptz,
    criado_em     timestamptz not null default now()
);

create index if not exists ix_convites_condominio
    on public.convites (condominio_id, email);

-- ----------------------------------------------------------------------------
-- RLS — trancadas desde já
-- ----------------------------------------------------------------------------
-- As policies são criadas na migration 012 (papéis), junto com os helpers.
-- Sem policy, o Postgres nega tudo — que é o estado seguro entre migrations.
alter table public.condominios     enable row level security;
alter table public.condominios     force  row level security;
alter table public.perfis          enable row level security;
alter table public.perfis          force  row level security;
alter table public.membros         enable row level security;
alter table public.membros         force  row level security;
alter table public.convites        enable row level security;
alter table public.convites        force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS — revogação tripla (public + anon + authenticated)
-- ----------------------------------------------------------------------------
-- Convenção do Anperez Money: no Supabase, o ambiente mantém execute/select
-- para anon/authenticated via default privileges. Revogar só de `public` não
-- basta — foi testado e não funcionou. Por isso o revoke é triplo, e o grant
-- é feito explicitamente depois.
revoke all on table public.condominios from public, anon, authenticated;
revoke all on table public.perfis      from public, anon, authenticated;
revoke all on table public.membros     from public, anon, authenticated;
revoke all on table public.convites    from public, anon, authenticated;

-- Revogação DINÂMICA de sequências: os ids usam gen_random_uuid(), mas
-- qualquer sequência criada no schema public no futuro também é revogada.
do $$
declare
    r record;
begin
    for r in
        select c.relname
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relkind = 'S'
    loop
        execute format('revoke all on sequence public.%I from public, anon, authenticated', r.relname);
    end loop;
end;
$$;

-- O usuário enxerga o próprio perfil; a lista de condomínios vem por helper.
grant select on public.perfis to authenticated;
