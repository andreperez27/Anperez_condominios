-- ============================================================================
-- MIGRATION 007 — FASE 0: LANÇAMENTOS E CLASSIFICAÇÃO
-- ============================================================================
-- A tabela central. Todo dado importado guarda arquivo de origem, hash,
-- aba ou página e linha — SEM EXCEÇÃO (requisito de auditoria).
--
-- `hash_arquivo`, `arquivo_nome`, `linha_origem` são desnormalizados de
-- propósito: a auditoria precisa ser respondida com UMA query só, mesmo que
-- a fonte seja removida do disco.
--
-- Documento de referência: docs\MODELO_DADOS.md §8.3 e §8.4
-- ============================================================================

-- ----------------------------------------------------------------------------
-- LANÇAMENTOS
-- ----------------------------------------------------------------------------
create table if not exists public.lancamentos (
    id                uuid primary key default gen_random_uuid(),
    condominio_id     uuid not null references public.condominios(id) on delete cascade,
    competencia_id    uuid not null references public.competencias(id),
    fundo_id          uuid not null references public.fundos(id),
    unidade_id        uuid references public.unidades(id),

    data_lancamento   date not null,
    data_vencimento   date,
    data_documento    date,

    -- Valor sempre POSITIVO. O sinal vem do tipo_movimento.
    valor             numeric(14,2) not null check (valor >= 0),
    tipo_movimento    public.tipo_movimento not null,

    historico         text not null,
    documento         text,
    codigo_conta      text not null,
    descricao_conta   text not null,
    referencia_extraida text,

    -- ===== RASTREABILIDADE (sempre preenchido) =====
    fonte_id          uuid not null references public.fontes_importacao(id),
    hash_arquivo      text not null,
    arquivo_nome      text not null,
    aba               text,
    pagina            integer,
    linha_origem      integer not null,
    coluna_origem     integer,
    texto_origem      text,

    -- ===== CLASSIFICAÇÃO =====
    status_classificacao public.status_classificacao not null default 'sugerida',
    origem_classificacao public.origem_classificacao not null default 'importacao',

    -- ===== TRANSFERÊNCIA INTERNA =====
    -- O ESTADO NÃO mora aqui. A única fonte de verdade é
    -- transferencias_internas.status. O lançamento apenas aponta para o grupo.
    grupo_transferencia_id uuid,

    status            public.status_lancamento not null default 'ativo',
    -- sha256(tupla_semantica + '#' + numero_ocorrencia).
    chave_natural     text not null,
    -- Nº da ocorrência da linha idêntica dentro do arquivo.
    numero_ocorrencia integer not null default 1,
    estornado_por_lancamento_id uuid references public.lancamentos(id),

    criado_em         timestamptz not null default now(),
    criado_por        uuid references public.perfis(id),
    atualizado_em     timestamptz not null default now(),
    constraint lancamentos_chave_unica unique (condominio_id, chave_natural),
    constraint lancamentos_posicao_unica unique (condominio_id, fonte_id, linha_origem, numero_ocorrencia),
    constraint lancamentos_valor_nao_negativo check (valor >= 0)
);

comment on table public.lancamentos is
    'Lançamento contábil. Rastreabilidade completa (fonte, hash, arquivo, '
    'aba/página, linha) e chave idempotente com número da ocorrência.';

create index if not exists ix_lancamentos_comp_fundo
    on public.lancamentos (condominio_id, competencia_id, fundo_id);
create index if not exists ix_lancamentos_unidade
    on public.lancamentos (unidade_id, competencia_id);
create index if not exists ix_lancamentos_data
    on public.lancamentos (condominio_id, data_lancamento);
create index if not exists ix_lancamentos_classificacao
    on public.lancamentos (condominio_id) where status_classificacao = 'sugerida';
create index if not exists ix_lancamentos_grupo_transferencia
    on public.lancamentos (grupo_transferencia_id) where grupo_transferencia_id is not null;
create index if not exists ix_lancamentos_origem
    on public.lancamentos (fonte_id, linha_origem, numero_ocorrencia);

-- ----------------------------------------------------------------------------
-- CLASSIFICAÇÃO POR LANÇAMENTO
-- ----------------------------------------------------------------------------
-- 1:1 com o lançamento, mas em tabela separada porque o histórico de decisão
-- (quem, quando, de qual rubrica veio) é o que uma auditoria exige.
--
-- ⚠️ A mesma conta pode receber naturezas diferentes (caso Fornecedor Exemplo:
-- conta 1647 com pintura e com área comum), por isso a classificação é
-- por lançamento e não só por código de conta.
create table if not exists public.lancamento_rubrica (
    lancamento_id  uuid primary key references public.lancamentos(id) on delete cascade,
    rubrica_id     uuid not null references public.rubricas(id),
    fundo_id       uuid not null references public.fundos(id),
    status         public.status_classificacao not null default 'sugerida',
    origem         public.origem_classificacao not null default 'conta',
    confianca      numeric(4,3),
    justificativa  text,
    decidido_por   uuid references public.perfis(id),
    decidido_em    timestamptz,
    criado_em      timestamptz not null default now()
);

comment on table public.lancamento_rubrica is
    'Classificação do lançamento. status sugere/confirmada; é a ÚNICA fonte de '
    'verdade do estado de classificação.';

create index if not exists ix_lancamento_rubrica_pendente
    on public.lancamento_rubrica (status) where status = 'sugerida';

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.lancamentos       enable row level security;
alter table public.lancamentos       force  row level security;
alter table public.lancamento_rubrica enable row level security;
alter table public.lancamento_rubrica force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
-- NENHUM grant para authenticated/anon. O leitor não tem SELECT direto em
-- tabela de detalhe — o caminho é fn_lancamentos / fn_resumo, que verificam
-- o papel por condomínio.
revoke all on table public.lancamentos       from public, anon, authenticated;
revoke all on table public.lancamento_rubrica from public, anon, authenticated;
select public.fn_revogar_sequencias_publicas();
