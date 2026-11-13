-- ============================================================================
-- MIGRATION 004 — FASE 0: COMPETÊNCIAS E STATUS POR FONTE
-- ============================================================================
-- A competência é o objeto do "período" na prestação de contas: é o que se
-- fecha, o que se concilia e o que se presta contas.
--
-- O status é POR FONTE: uma competência pode ter extrato importado e ainda
-- não ter balancete. "sem_fonte" é uma lacuna sinalizada — nunca um mês
-- vazio.
--
-- Documento de referência: docs\MODELO_DADOS.md §5
-- ============================================================================

create table if not exists public.competencias (
    id           uuid primary key default gen_random_uuid(),
    condominio_id uuid not null references public.condominios(id) on delete cascade,
    ano          smallint not null,
    mes          smallint not null,
    data_inicio  date not null,
    data_fim     date not null,
    fechada_em   timestamptz,
    fechada_por  uuid references public.perfis(id),
    criado_em    timestamptz not null default now(),
    constraint competencias_ano check (ano between 2000 and 2100),
    constraint competencias_mes check (mes between 1 and 12),
    constraint competencias_periodo check (data_fim >= data_inicio),
    constraint competencias_unica unique (condominio_id, ano, mes)
);

comment on table public.competencias is
    'Competência (período) contábil. É o objeto fechado na prestação de contas.';

create index if not exists ix_competencias_condominio_periodo
    on public.competencias (condominio_id, ano desc, mes desc);

-- ----------------------------------------------------------------------------
-- STATUS POR FONTE
-- ----------------------------------------------------------------------------
-- Semântica:
--   sem_fonte  = a competência existe mas não há documento daquela fonte.
--                Aparece como PENDÊNCIA no painel, não como zero.
--   importado = o arquivo foi lido, passou pela conferência e foi aprovado.
--   conciliado = há conciliação da competência sem divergência em nenhum fundo.
--   fechado    = competência formalmente encerrada pelo auditor.
create table if not exists public.status_competencia (
    id             uuid primary key default gen_random_uuid(),
    competencia_id uuid not null references public.competencias(id) on delete cascade,
    fonte          public.fonte_contabil not null,
    status         public.status_fonte not null default 'sem_fonte',
    observacao     text,
    atualizado_em  timestamptz not null default now(),
    atualizado_por uuid references public.perfis(id),
    constraint status_competencia_unica unique (competencia_id, fonte)
);

comment on table public.status_competencia is
    'Status da competência POR FONTE. sem_fonte é lacuna sinalizada (pendência), '
    'não mês vazio.';

create index if not exists ix_status_competencia_fonte
    on public.status_competencia (fonte, status);

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.competencias      enable row level security;
alter table public.competencias      force  row level security;
alter table public.status_competencia enable row level security;
alter table public.status_competencia force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
revoke all on table public.competencias      from public, anon, authenticated;
revoke all on table public.status_competencia from public, anon, authenticated;
select public.fn_revogar_sequencias_publicas();
