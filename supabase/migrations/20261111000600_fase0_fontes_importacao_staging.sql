-- ============================================================================
-- MIGRATION 006 — FASE 0: FONTES DE IMPORTAÇÃO E STAGING
-- ============================================================================
-- A rastreabilidade começa aqui: toda fonte (arquivo) tem hash, layout
-- detectado e competência. O `unique (condominio_id, hash_sha256, layout)` é
-- a trava de idempotência de ARQUIVO — o mesmo conteúdo nunca vira duas
-- fontes.
--
-- O staging é a área de conferência. O importador escreve AQUI e em nenhum
-- outro lugar; a entrada em `lancamentos` passa pela RPC de aprovação.
--
-- Documento de referência: docs\MODELO_DADOS.md §8 e §15
-- ============================================================================

-- ----------------------------------------------------------------------------
-- FONTES (arquivos de origem)
-- ----------------------------------------------------------------------------
create table if not exists public.fontes_importacao (
    id               uuid primary key default gen_random_uuid(),
    condominio_id    uuid not null references public.condominios(id) on delete cascade,
    fonte            public.fonte_contabil not null,
    nome_arquivo     text not null,
    -- Caminho RELATIVO à pasta de dados de origem (que fica fora do Git).
    caminho_relativo text not null,
    -- Hash do arquivo INTEIRO. É a trava de idempotência de arquivo.
    hash_sha256      text not null,
    tamanho_bytes    bigint not null,
    -- Layout detectado pelo conteúdo (nunca pela extensão):
    -- 'extrato_v1' | 'extrato_v2' | 'extrato_v3' | 'balancete_v1'
    -- | 'caixa_local_v1' | 'planilha_resumo_v1' | ...
    layout           text not null,
    aba              text,
    pagina_inicio    integer,
    pagina_fim       integer,
    competencia_id    uuid references public.competencias(id),
    status           public.status_fonte_arquivo not null default 'detectado',
    mensagem         text,
    detectado_em     timestamptz not null default now(),
    constraint fontes_unica unique (condominio_id, hash_sha256, layout)
);

comment on table public.fontes_importacao is
    'Arquivos de origem. hash_sha256 + layout são a trava de idempotência de '
    'arquivo: o mesmo conteúdo nunca vira duas fontes.';

create index if not exists ix_fontes_competencia
    on public.fontes_importacao (condominio_id, competencia_id);
create index if not exists ix_fontes_status
    on public.fontes_importacao (status);

-- ----------------------------------------------------------------------------
-- IMPORTAÇÕES (execuções)
-- ----------------------------------------------------------------------------
create table if not exists public.importacoes (
    id                 uuid primary key default gen_random_uuid(),
    fonte_id           uuid not null references public.fontes_importacao(id) on delete cascade,
    iniciada_em        timestamptz not null default now(),
    concluida_em       timestamptz,
    status             public.status_importacao not null default 'em_andamento',
    linhas_lidas       integer not null default 0,
    linhas_novas       integer not null default 0,
    linhas_atualizadas integer not null default 0,
    linhas_rejeitadas  integer not null default 0,
    erro               text,
    executado_por      uuid references public.perfis(id)
);

create index if not exists ix_importacoes_fonte
    on public.importacoes (fonte_id, iniciada_em desc);

-- ----------------------------------------------------------------------------
-- STAGING: LANÇAMENTOS
-- ----------------------------------------------------------------------------
-- A coluna `numero_ocorrencia` distingue linhas IDÊNTICAS dentro do mesmo
-- arquivo. Sem ela, a 2ª linha repetida teria a mesma chave e seria
-- descartada em silêncio pelo unique — proibido pela regra de não descartar
-- duplicata.
create table if not exists public.staging_lancamentos (
    id                  uuid primary key default gen_random_uuid(),
    importacao_id       uuid not null references public.importacoes(id) on delete cascade,
    fonte_id            uuid not null references public.fontes_importacao(id) on delete cascade,
    condominio_id       uuid not null references public.condominios(id) on delete cascade,
    competencia_ano     smallint not null,
    competencia_mes     smallint not null,
    linha_origem        integer not null,
    aba                 text,
    pagina              integer,
    -- A linha BRUTA, para conferência sem reabrir o arquivo.
    texto_origem        text not null,
    data_lancamento     date,
    data_vencimento     date,
    codigo_conta        text,
    descricao_conta     text,
    historico           text,
    documento           text,
    valor               numeric(14,2),
    tipo_movimento      public.tipo_movimento,
    unidade_numero      text,
    fundo_sugerido_id   uuid references public.fundos(id),
    rubrica_sugerida_id uuid references public.rubricas(id),
    confianca           numeric(4,3),
    chave_natural       text not null,
    -- Nº da ocorrência da linha idêntica dentro do arquivo.
    numero_ocorrencia   integer not null default 1,
    status              public.status_staging not null default 'novo',
    mensagem            text,
    aprovado_em         timestamptz,
    aprovado_por        uuid references public.perfis(id),
    criado_em           timestamptz not null default now(),
    constraint staging_chave_unica unique (importacao_id, chave_natural),
    constraint staging_posicao_unica unique (importacao_id, fonte_id, linha_origem, numero_ocorrencia)
);

comment on table public.staging_lancamentos is
    'Área de conferência. O importador escreve aqui e em nenhum outro lugar; '
    'a entrada em lancamentos passa pela RPC de aprovação.';

create index if not exists ix_staging_importacao
    on public.staging_lancamentos (importacao_id, status);
create index if not exists ix_staging_pendentes
    on public.staging_lancamentos (condominio_id, status)
    where status in ('novo','duplicado_candidato','conflito');

-- ----------------------------------------------------------------------------
-- STAGING: TRANSFERÊNCIAS SUGERIDAS
-- ----------------------------------------------------------------------------
create table if not exists public.staging_transacoes (
    id                    uuid primary key default gen_random_uuid(),
    importacao_id         uuid not null references public.importacoes(id) on delete cascade,
    fonte_id              uuid not null references public.fontes_importacao(id) on delete cascade,
    condominio_id         uuid not null references public.condominios(id) on delete cascade,
    competencia_ano       smallint not null,
    competencia_mes       smallint not null,
    grupo_ref_sugerido    text not null,
    fundo_origem_id       uuid references public.fundos(id),
    fundo_destino_id      uuid references public.fundos(id),
    valor                 numeric(14,2),
    linha_origem_origem   integer,
    linha_origem_destino  integer,
    regra                 text not null,
    confianca             numeric(4,3),
    status                public.status_transferencia not null default 'sugerida',
    criado_em             timestamptz not null default now()
);

create index if not exists ix_staging_transacoes_importacao
    on public.staging_transacoes (importacao_id);

-- ----------------------------------------------------------------------------
-- STAGING: DUPLICATAS CANDIDATAS
-- ----------------------------------------------------------------------------
-- A comparação usa a TUPLA semântica (sem a ocorrência) — nunca a
-- chave_natural, que é justamente o que distingue as duas linhas.
create table if not exists public.staging_duplicatas (
    id                uuid primary key default gen_random_uuid(),
    importacao_id     uuid not null references public.importacoes(id) on delete cascade,
    condominio_id     uuid not null references public.condominios(id) on delete cascade,
    chave_candidata   text not null,
    tupla_comum       text not null,
    criterio          public.criterio_duplicata not null,
    staging_a_id      uuid not null references public.staging_lancamentos(id) on delete cascade,
    staging_b_id      uuid not null references public.staging_lancamentos(id) on delete cascade,
    status            public.status_duplicata not null default 'pendente',
    criado_em         timestamptz not null default now(),
    constraint staging_duplicatas_par unique (staging_a_id, staging_b_id),
    constraint staging_duplicatas_distintas check (staging_a_id <> staging_b_id)
);

create index if not exists ix_staging_duplicatas_importacao
    on public.staging_duplicatas (importacao_id);

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.fontes_importacao   enable row level security;
alter table public.fontes_importacao   force  row level security;
alter table public.importacoes         enable row level security;
alter table public.importacoes         force  row level security;
alter table public.staging_lancamentos enable row level security;
alter table public.staging_lancamentos force  row level security;
alter table public.staging_transacoes  enable row level security;
alter table public.staging_transacoes  force  row level security;
alter table public.staging_duplicatas   enable row level security;
alter table public.staging_duplicatas   force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
-- Nenhum grant para authenticated/anon em tabela alguma.
-- O role `app_importador` (criado na migration 012) é o ÚNICO que pode
-- escrever no staging — e só no staging.
revoke all on table public.fontes_importacao   from public, anon, authenticated;
revoke all on table public.importacoes         from public, anon, authenticated;
revoke all on table public.staging_lancamentos from public, anon, authenticated;
revoke all on table public.staging_transacoes  from public, anon, authenticated;
revoke all on table public.staging_duplicatas   from public, anon, authenticated;

select public.fn_revogar_sequencias_publicas();
