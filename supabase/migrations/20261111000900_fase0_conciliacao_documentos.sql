-- ============================================================================
-- MIGRATION 009 — FASE 0: CONCILIAÇÃO, DOCUMENTOS E ANEXOS
-- ============================================================================
-- CONCILIAÇÃO — por fundo e por competência
-- -----------------------------------------
-- A comparação é: linha do balancete do fundo F × extrato do fundo F.
-- A versão anterior comparava a linha CONTA CONDOMÍNIO do balancete contra o
-- TOTAL do extrato, o que produzia 14 "DIVERGENTE" falsos. As diferenças
-- apuradas eram exatamente a soma dos outros fundos — dinheiro que se moveu
-- dentro do condomínio, não dinheiro que sumiu.
--
-- A conciliação NUNCA altera lançamento. Ela calcula, grava o resultado e
-- cria pendência. Reclassificar é ato separado, com rastro.
--
-- ANEXOS
-- ------
-- Comprovantes escaneados do caixa local. Bloqueados por padrão para o
-- leitor; liberados um a um pelo auditor (`liberado_para_leitor`).
--
-- Documento de referência: docs\MODELO_DADOS.md §11 e §12
-- ============================================================================

-- ----------------------------------------------------------------------------
-- CONCILIAÇÕES
-- ----------------------------------------------------------------------------
create table if not exists public.conciliacoes (
    id                      uuid primary key default gen_random_uuid(),
    condominio_id           uuid not null references public.condominios(id) on delete cascade,
    competencia_id          uuid not null references public.competencias(id),
    fundo_id                uuid not null references public.fundos(id),
    status                  public.status_conciliacao not null,
    saldo_inicial_extrato   numeric(14,2),
    creditos_extrato        numeric(14,2),
    debitos_extrato         numeric(14,2),
    saldo_final_extrato     numeric(14,2),
    saldo_inicial_balancete numeric(14,2),
    creditos_balancete      numeric(14,2),
    debitos_balancete       numeric(14,2),
    saldo_final_balancete   numeric(14,2),
    diferenca_creditos      numeric(14,2),
    diferenca_debitos       numeric(14,2),
    diferenca_saldo_final   numeric(14,2),
    observacao              text,
    conciliado_em           timestamptz,
    conciliado_por          uuid references public.perfis(id),
    criado_em               timestamptz not null default now(),
    constraint conciliacoes_unica unique (competencia_id, fundo_id)
);

comment on table public.conciliacoes is
    'Conciliação extrato × balancete POR FUNDO e POR COMPETÊNCIA. Nunca altera '
    'lançamento — apenas calcula e cria pendência.';

create index if not exists ix_conciliacoes_status
    on public.conciliacoes (condominio_id, status);

-- ----------------------------------------------------------------------------
-- DETALHE DA CONCILIAÇÃO (linha a linha)
-- ----------------------------------------------------------------------------
-- Permite dizer "a divergência de 2026-10 são 2 transferências de R$
-- 85.000,00 e R$ 99.060,00", e não só um número.
create table if not exists public.conciliacao_detalhe (
    id             uuid primary key default gen_random_uuid(),
    conciliacao_id uuid not null references public.conciliacoes(id) on delete cascade,
    rubrica_id     uuid references public.rubricas(id),
    -- Rótulo como veio da fonte (sem normalização), para rastreabilidade.
    alias_origem   text not null,
    fundo_id       uuid references public.fundos(id),
    -- 'extrato' | 'balancete'
    lado           text not null,
    valor          numeric(14,2) not null,
    observacao     text,
    criado_em      timestamptz not null default now(),
    constraint conciliacao_detalhe_lado check (lado in ('extrato','balancete'))
);

create index if not exists ix_conciliacao_detalhe_conciliacao
    on public.conciliacao_detalhe (conciliacao_id, lado);

-- ----------------------------------------------------------------------------
-- DOCUMENTOS
-- ----------------------------------------------------------------------------
create table if not exists public.documentos (
    id             uuid primary key default gen_random_uuid(),
    condominio_id  uuid not null references public.condominios(id) on delete cascade,
    tipo           public.tipo_documento not null,
    titulo         text not null,
    numero         text,
    fornecedor     text,
    cnpj           text,
    data_documento date,
    valor          numeric(14,2),
    competencia_id uuid references public.competencias(id),
    lancamento_id  uuid references public.lancamentos(id),
    fonte_id       uuid references public.fontes_importacao(id),
    hash_sha256    text,
    -- Caminho no bucket privado do Supabase Storage.
    caminho        text,
    criado_em      timestamptz not null default now()
);

create index if not exists ix_documentos_lancamento
    on public.documentos (lancamento_id) where lancamento_id is not null;
create index if not exists ix_documentos_competencia
    on public.documentos (condominio_id, competencia_id);

-- ----------------------------------------------------------------------------
-- ANEXOS (comprovantes escaneados)
-- ----------------------------------------------------------------------------
-- Regra de acesso: bloqueado por padrão para o leitor. O auditor libera
-- ANEXO POR ANEXO, e a liberação é auditada.
create table if not exists public.anexos (
    id              uuid primary key default gen_random_uuid(),
    condominio_id   uuid not null references public.condominios(id) on delete cascade,
    documento_id    uuid references public.documentos(id) on delete cascade,
    lancamento_id   uuid references public.lancamentos(id) on delete cascade,
    fonte_id        uuid not null references public.fontes_importacao(id),
    pagina          integer not null,
    rotulo          text,
    hash_sha256     text not null,
    caminho         text not null,
    status          public.status_anexo not null default 'sugerido',
    -- ===== LIBERAÇÃO PARA O LEITOR (padrão: bloqueado) =====
    liberado_para_leitor boolean not null default false,
    liberado_em           timestamptz,
    liberado_por           uuid references public.perfis(id),
    criado_em         timestamptz not null default now()
);

comment on table public.anexos is
    'Comprovantes escaneados. Bloqueados por padrão para o leitor; liberados '
    'um a um pelo auditor (liberado_para_leitor).';

create index if not exists ix_anexos_lancamento
    on public.anexos (lancamento_id) where lancamento_id is not null;
create index if not exists ix_anexos_por_condominio
    on public.anexos (condominio_id, criado_em desc);

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.conciliacoes       enable row level security;
alter table public.conciliacoes       force  row level security;
alter table public.conciliacao_detalhe enable row level security;
alter table public.conciliacao_detalhe force  row level security;
alter table public.documentos         enable row level security;
alter table public.documentos         force  row level security;
alter table public.anexos             enable row level security;
alter table public.anexos             force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
revoke all on table public.conciliacoes       from public, anon, authenticated;
revoke all on table public.conciliacao_detalhe from public, anon, authenticated;
revoke all on table public.documentos         from public, anon, authenticated;
revoke all on table public.anexos             from public, anon, authenticated;

select public.fn_revogar_sequencias_publicas();
