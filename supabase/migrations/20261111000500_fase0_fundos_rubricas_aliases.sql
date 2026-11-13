-- ============================================================================
-- MIGRATION 005 — FASE 0: FUNDOS, RUBRICAS, ALIASES E CONTAS DE ORIGEM
-- ============================================================================
-- Fundos: entidade própria, com o prefixo do código de conta. O prefixo já
-- identifica o fundo (1xxxx = CONTA CONDOMÍNIO, 2xxxx = BENFEITORIAS,
-- 3xxxx = FUNDO DE RESERVA, 15xxx = PINTURA, 19xxx = SALÃO).
--
-- ⚠️ ATENÇÃO: `1`, `10`, `15` e `19` começam igual. Por isso o prefixo é só
-- heurística de FALLBACK para códigos novos — a fonte de verdade é o
-- mapeamento explícito em `contas_origem`.
--
-- Rubricas: taxonomia canônica do condomínio. As três fontes (extrato,
-- planilha-resumo, balancete) têm taxonomias diferentes; `rubrica_aliases` é
-- a ponte, com `contexto` para resolver o caso "mesmo alias, sentidos
-- diferentes" (CONSUMO DE AGUA = receita 1052 e despesa 1642).
--
-- Documento de referência: docs\MODELO_DADOS.md §6 e §7
-- ============================================================================

-- ----------------------------------------------------------------------------
-- FUNDOS (recurso)
-- ----------------------------------------------------------------------------
create table if not exists public.fundos (
    id             uuid primary key default gen_random_uuid(),
    condominio_id  uuid not null references public.condominios(id) on delete cascade,
    codigo         text not null,
    nome           text not null,
    natureza       public.natureza_fundo not null,
    -- '1' | '15' | '19' | '2' | '3' | '10' — heurística de fallback.
    prefixo_conta  text,
    ativo          boolean not null default true,
    criado_em      timestamptz not null default now(),
    constraint fundos_unico unique (condominio_id, codigo)
);

comment on table public.fundos is
    'Fundo/recurso do condomínio. prefixo_conta é heurística de fallback; a '
    'verdade é o mapeamento explícito em contas_origem.';

-- ----------------------------------------------------------------------------
-- RUBRICAS (taxonomia canônica)
-- ----------------------------------------------------------------------------
create table if not exists public.rubricas (
    id                 uuid primary key default gen_random_uuid(),
    condominio_id      uuid not null references public.condominios(id) on delete cascade,
    codigo             text not null,
    nome               text not null,
    natureza           public.natureza_rubrica not null,
    fundo_padrao       uuid references public.fundos(id),
    unidade_de_medida  text,
    ativo              boolean not null default true,
    criado_em          timestamptz not null default now(),
    constraint rubricas_unica unique (condominio_id, codigo)
);

comment on table public.rubricas is
    'Taxonomia canônica do condomínio. Os rótulos das fontes externas são '
    'mapeados via rubrica_aliases.';

-- ----------------------------------------------------------------------------
-- ALIASES (a ponte entre as três taxonomias)
-- ----------------------------------------------------------------------------
-- `contexto` desambigua quando o mesmo rótulo designa coisas diferentes na
-- mesma fonte: 'CONSUMO DE AGUA' no extrato é receita (1052) e despesa (1642).
create table if not exists public.rubrica_aliases (
    id          uuid primary key default gen_random_uuid(),
    rubrica_id  uuid not null references public.rubricas(id) on delete cascade,
    fonte       public.fonte_alias not null,
    -- Texto EXATO como aparece na fonte.
    alias       text not null,
    contexto    text,
    prioridade  smallint not null default 100,
    ativo       boolean not null default true,
    criado_em   timestamptz not null default now()
);

comment on table public.rubrica_aliases is
    'Alias do rótulo de origem (extrato/planilha-resumo/balancete) para uma '
    'rubrica canônica. contexto desambigua o mesmo alias com sentidos '
    'diferentes.';

create index if not exists ix_rubrica_aliases_busca
    on public.rubrica_aliases (fonte, alias) where ativo;

-- ⚠️ Constraint única NECESSÁRIA: sem ela, rodar o seed duas vezes duplica
-- os aliases (o `on conflict do nothing` do seed não evita isso, porque
-- não existe conflito a detectar sem a constraint). Verificado em
-- 11/11/2026: o seed duplicou 55 aliases → 110.
create unique index if not exists uq_rubrica_aliases
    on public.rubrica_aliases (rubrica_id, fonte, alias, coalesce(contexto, ''));

-- ----------------------------------------------------------------------------
-- CONTAS DE ORIGEM (catálogo do código contábil da administradora)
-- ----------------------------------------------------------------------------
-- O código do extrato (1002, 1642, 1723...) identifica rubrica E fundo.
-- Este catálogo é a fonte de verdade; o prefixo é só fallback.
create table if not exists public.contas_origem (
    id                uuid primary key default gen_random_uuid(),
    condominio_id     uuid not null references public.condominios(id) on delete cascade,
    codigo            text not null,
    descricao_origem  text not null,
    fundo_id          uuid not null references public.fundos(id),
    rubrica_id        uuid references public.rubricas(id),
    -- NULL em rubrica_id = conta sem rubrica (vira pendência de classificação).
    status            public.status_classificacao not null default 'sugerida',
    origem_sugestao   text,
    justificativa     text,
    decidido_por      uuid references public.perfis(id),
    decidido_em       timestamptz,
    criado_em         timestamptz not null default now(),
    constraint contas_origem_unica unique (condominio_id, codigo)
);

comment on table public.contas_origem is
    'Catálogo do código contábil da administradora → rubrica + fundo. '
    'É a fonte de verdade (o prefixo do código é só fallback).';

create index if not exists ix_contas_origem_sem_rubrica
    on public.contas_origem (condominio_id) where rubrica_id is null;

-- ----------------------------------------------------------------------------
-- ORDEM DE GRANULARIDADE (usada pela política de visibilidade)
-- ----------------------------------------------------------------------------
-- fundo < rubrica < unidade. A comparação "pediu mais do que pode?" é
-- numérica, não uma lista de casos.
create table if not exists public.granularidade_ordem (
    granularidade text primary key,
    rank          smallint not null unique
);

comment on table public.granularidade_ordem is
    'Ordem de finura da granularidade: fundo(1) < rubrica(2) < unidade(3).';

-- ----------------------------------------------------------------------------
-- POLÍTICA DE VISIBILIDADE (por condomínio e papel)
-- ----------------------------------------------------------------------------
-- A granularidade permitida NÃO é fixada no código das funções: vem daqui.
-- Liberar o nominal por unidade no futuro = UPDATE de uma linha.
create table if not exists public.config_visibilidade (
    condominio_id           uuid not null references public.condominios(id) on delete cascade,
    papel                   public.papel_membro not null,
    granularidade_max       text not null references public.granularidade_ordem(granularidade),
    -- Limiar mínimo de agregação: suprime agregados apoiados em MENOS unidades
    -- que isso (proteção contra small-cell / reidentificação).
    limiar_minimo_unidades  integer not null default 5 check (limiar_minimo_unidades >= 0),
    bloqueia_unidade        boolean not null default true,
    atualizado_em           timestamptz not null default now(),
    atualizado_por          uuid references public.perfis(id),
    primary key (condominio_id, papel)
);

comment on table public.config_visibilidade is
    'Política de visibilidade por condomínio e papel. UPDATE de uma linha '
    'libera (ou restringe) a granularidade nominal sem tocar em schema.';

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.fundos           enable row level security;
alter table public.fundos           force  row level security;
alter table public.rubricas         enable row level security;
alter table public.rubricas         force  row level security;
alter table public.rubrica_aliases  enable row level security;
alter table public.rubrica_aliases  force  row level security;
alter table public.contas_origem    enable row level security;
alter table public.contas_origem    force  row level security;
alter table public.granularidade_ordem enable row level security;
alter table public.granularidade_ordem force  row level security;
alter table public.config_visibilidade enable row level security;
alter table public.config_visibilidade force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
revoke all on table public.fundos              from public, anon, authenticated;
revoke all on table public.rubricas            from public, anon, authenticated;
revoke all on table public.rubrica_aliases     from public, anon, authenticated;
revoke all on table public.contas_origem       from public, anon, authenticated;
revoke all on table public.granularidade_ordem from public, anon, authenticated;
revoke all on table public.config_visibilidade from public, anon, authenticated;


-- A tabela de ordem de granularidade é só referência técnica (sem dado de
-- condomínio). Leitura liberada para authenticated; a aplicação já valida
-- o valor contra ela.
grant select on public.granularidade_ordem to authenticated;

-- Revogação dinâmica das sequências do schema public.
select public.fn_revogar_sequencias_publicas();
