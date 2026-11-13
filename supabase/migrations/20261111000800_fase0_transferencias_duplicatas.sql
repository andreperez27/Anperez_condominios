-- ============================================================================
-- MIGRATION 008 — FASE 0: TRANSFERÊNCIAS INTERNAS E DUPLICATAS
-- ============================================================================
-- TRANSFERÊNCIAS INTERNAS
-- -----------------------
-- O extrato registra transferências entre os fundos do próprio condomínio
-- (ex.: R$ 85.000,00 da CONTA CONDOMÍNIO para MANUTENÇÃO DE PINTURA).
-- Somado sem eliminar, o total do extrato parece maior que o balancete — foi
-- exatamente isso que gerou os 14 "DIVERGENTE" do app anterior.
--
-- As duas pontas ficam ligadas por `grupo_id`. O ESTADO mora em uma fonte
-- única: `transferencias_internas.status`. O lançamento apenas aponta para o
-- grupo — não tem coluna de estado. Assim "não é transferência" (sem grupo)
-- e "transferência ainda não revisada" (status = 'sugerida') nunca se
-- confundem.
--
-- DUPLICATAS
-- ----------
-- Duplicata NÃO é descartada. As duas linhas permanecem em `lancamentos` e o
-- par é marcado como candidato. Dois pagamentos iguais no mesmo dia podem ser
-- legítimos — por isso o critério `mesmo_valor_data_conta` existe e é
-- justamente o que exige decisão humana.
--
-- Documento de referência: docs\MODELO_DADOS.md §9 e §10
-- ============================================================================

-- ----------------------------------------------------------------------------
-- GRUPOS DE TRANSFERÊNCIA
-- ----------------------------------------------------------------------------
create table if not exists public.grupos_transferencia (
    id             uuid primary key default gen_random_uuid(),
    condominio_id  uuid not null references public.condominios(id) on delete cascade,
    competencia_id uuid not null references public.competencias(id),
    -- Identificador do grupo, ex.: 'TRF-2026-02-0007'.
    grupo_ref      text not null,
    criado_em      timestamptz not null default now(),
    constraint grupos_transferencia_unica unique (condominio_id, grupo_ref)
);

comment on table public.grupos_transferencia is
    'Agrupamento de uma transferência interna. Não guarda estado — o estado '
    'está em transferencias_internas.status.';

-- ----------------------------------------------------------------------------
-- TRANSFERÊNCIAS INTERNAS — fonte única de verdade do estado
-- ----------------------------------------------------------------------------
create table if not exists public.transferencias_internas (
    id                    uuid primary key default gen_random_uuid(),
    condominio_id         uuid not null references public.condominios(id) on delete cascade,
    competencia_id        uuid not null references public.competencias(id),
    grupo_id              uuid not null references public.grupos_transferencia(id) on delete cascade,
    fundo_origem_id       uuid not null references public.fundos(id),
    fundo_destino_id      uuid not null references public.fundos(id),
    valor                 numeric(14,2) not null check (valor > 0),
    lancamento_origem_id  uuid not null references public.lancamentos(id) on delete cascade,
    lancamento_destino_id uuid not null references public.lancamentos(id) on delete cascade,
    -- ÚNICA fonte de verdade do estado da transferência interna.
    status                public.status_transferencia not null default 'sugerida',
    -- 'prefixo' | 'codigo' | 'valor_data' | 'manual'
    regra                 text not null,
    confianca             numeric(4,3),
    justificativa         text,
    decidido_por          uuid references public.perfis(id),
    decidido_em           timestamptz,
    criado_em             timestamptz not null default now(),
    constraint transferencias_origem_unica  unique (lancamento_origem_id),
    constraint transferencias_destino_unica unique (lancamento_destino_id),
    constraint transferencias_fundos_distintos check (fundo_origem_id <> fundo_destino_id)
);

comment on table public.transferencias_internas is
    'Transferência interna entre fundos. status é a ÚNICA fonte de verdade do '
    'estado: só "confirmada" desconta do resultado líquido.';

create index if not exists ix_transferencias_pendentes
    on public.transferencias_internas (condominio_id) where status = 'sugerida';

-- Ligação do lançamento ao grupo (o lançamento não tem coluna de estado).
alter table public.lancamentos
    drop constraint if exists lancamentos_grupo_transferencia_fk;
alter table public.lancamentos
    add constraint lancamentos_grupo_transferencia_fk
    foreign key (grupo_transferencia_id)
    references public.grupos_transferencia(id) on delete set null;

-- ----------------------------------------------------------------------------
-- DUPLICATAS CANDIDATAS
-- ----------------------------------------------------------------------------
-- `tupla_comum` guarda a tupla SEMÂNTICA (sem o número da ocorrência) que
-- as duas linhas compartilham. A comparação de duplicatas usa SEMPRE a
-- tupla, nunca a chave_natural — que é justamente o que distingue as duas
-- linhas idênticas.
create table if not exists public.duplicatas_candidatas (
    id               uuid primary key default gen_random_uuid(),
    condominio_id    uuid not null references public.condominios(id) on delete cascade,
    chave_candidata  text not null,
    tupla_comum      text not null,
    criterio         public.criterio_duplicata not null,
    lancamento_a_id  uuid not null references public.lancamentos(id) on delete cascade,
    lancamento_b_id  uuid not null references public.lancamentos(id) on delete cascade,
    status           public.status_duplicata not null default 'pendente',
    pareceres        text,
    decidido_por     uuid references public.perfis(id),
    decidido_em      timestamptz,
    criado_em        timestamptz not null default now(),
    constraint duplicatas_par_unico unique (lancamento_a_id, lancamento_b_id),
    constraint duplicatas_linhas_distintas check (lancamento_a_id <> lancamento_b_id)
);

comment on table public.duplicatas_candidatas is
    'Pares de lançamentos candidatos a duplicata. As DUAS linhas continuam '
    'existindo — duplicata nunca é descartada automaticamente.';

create index if not exists ix_duplicatas_pendentes
    on public.duplicatas_candidatas (condominio_id) where status = 'pendente';

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.grupos_transferencia  enable row level security;
alter table public.grupos_transferencia  force  row level security;
alter table public.transferencias_internas enable row level security;
alter table public.transferencias_internas force  row level security;
alter table public.duplicatas_candidatas  enable row level security;
alter table public.duplicatas_candidatas  force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
revoke all on table public.grupos_transferencia   from public, anon, authenticated;
revoke all on table public.transferencias_internas from public, anon, authenticated;
revoke all on table public.duplicatas_candidatas   from public, anon, authenticated;

select public.fn_revogar_sequencias_publicas();
