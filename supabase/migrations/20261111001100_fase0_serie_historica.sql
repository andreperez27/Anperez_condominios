-- ============================================================================
-- MIGRATION 011 — FASE 0: SÉRIE HISTÓRICA DA PLANILHA-RESUMO
-- ============================================================================
-- A planilha-resumo cobre 05/2020 a 10/2026 (78 meses, sem lacuna) e é a
-- ÚNICA série longa disponível. Como não há lançamentos nesse período, ela
-- entra em tabela própria — agregada, sem virar lançamento.
--
-- Serve para tendência de longo prazo (saldo consolidado, composição de
-- despesas, evolução da cota) e para servir de semente do saldo inicial de
-- competências antigas, se um dia vierem a ser importadas.
--
-- As 21 LINHAS DE ANOTAÇÃO das colunas H/I/J (caderno à mão: "TOTAL FUNDO
-- RESERVA", "desc. IRRF", "gasto 4800.00") NÃO viram rubrica: entram em
-- `serie_historica_anotacoes`, preservando o texto original e a linha.
--
-- Documento de referência: docs\MODELO_DADOS.md §14
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SÉRIE HISTÓRICA
-- ----------------------------------------------------------------------------
create table if not exists public.serie_historica_resumo (
    id               uuid primary key default gen_random_uuid(),
    condominio_id    uuid not null references public.condominios(id) on delete cascade,
    ano              smallint not null,
    mes              smallint not null,
    -- 'conta' (bloco de créditos/débitos) | 'aplicacao_btg' (bloco de aporte/juros)
    bloco            text not null default 'conta',
    -- Rótulo como veio na planilha (ex.: 'CONTA CONDOMINIO', 'APLICAÇÃO BANCO EXEMPLO').
    rubrica_alias    text not null,
    rubrica_id       uuid references public.rubricas(id),
    fundo_id         uuid references public.fundos(id),
    saldo_anterior   numeric(14,2),
    creditos         numeric(14,2),
    debitos          numeric(14,2),
    saldo            numeric(14,2),
    fonte_id         uuid not null references public.fontes_importacao(id),
    linha_origem     integer not null,
    criado_em        timestamptz not null default now(),
    constraint serie_historica_unica unique (condominio_id, ano, mes, bloco, rubrica_alias),
    constraint serie_historica_bloco check (bloco in ('conta','aplicacao_btg'))
);

comment on table public.serie_historica_resumo is
    'Série histórica agregada da planilha-resumo (2020-2026). NÃO vira lançamento: '
    'não há documento nem linha por trás.';

create index if not exists ix_serie_historica_periodo
    on public.serie_historica_resumo (condominio_id, ano desc, mes desc);

-- ----------------------------------------------------------------------------
-- ANOTAÇÕES DA PLANILHA (caderno manuscrito)
-- ----------------------------------------------------------------------------
create table if not exists public.serie_historica_anotacoes (
    id             uuid primary key default gen_random_uuid(),
    condominio_id  uuid not null references public.condominios(id) on delete cascade,
    ano            smallint not null,
    mes            smallint not null,
    fonte_id       uuid not null references public.fontes_importacao(id),
    linha_origem   integer not null,
    coluna_origem  integer,
    texto          text not null,
    valor          numeric(14,2),
    criado_em      timestamptz not null default now(),
    constraint serie_anotacoes_unica unique (fonte_id, linha_origem, coluna_origem)
);

comment on table public.serie_historica_anotacoes is
    'Anotações manuscritas nas colunas H/I/J da planilha-resumo. Não são '
    'rubricas — são observações preservadas com a linha de origem.';

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.serie_historica_resumo     enable row level security;
alter table public.serie_historica_resumo     force  row level security;
alter table public.serie_historica_anotacoes enable row level security;
alter table public.serie_historica_anotacoes force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
revoke all on table public.serie_historica_resumo     from public, anon, authenticated;
revoke all on table public.serie_historica_anotacoes from public, anon, authenticated;

select public.fn_revogar_sequencias_publicas();
