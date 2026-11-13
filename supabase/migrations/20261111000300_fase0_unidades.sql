-- ============================================================================
-- MIGRATION 003 — FASE 0: UNIDADES
-- ============================================================================
-- A unidade (apartamento) é entidade, não coluna de texto: o app precisa de
-- espelho de boleto, cobertura das 72 unidades e análise de consumo por
-- unidade.
--
-- `numero` é TEXT, não integer: o extrato usa `UN.000033` (6 dígitos com zero
-- à esquerda) e a planilha-resumo usa `000013`. O mesmo imóvel aparece com
-- zeros diferentes; guardar como texto normalizado (sem zeros) resolve, mas o
-- texto original também fica disponível.
--
-- Documento de referência: docs\MODELO_DADOS.md §4.5
-- ============================================================================

create table if not exists public.unidades (
    id            uuid primary key default gen_random_uuid(),
    condominio_id uuid not null references public.condominios(id) on delete cascade,
    -- '11'..'184'. Texto para preservar a forma original e não confundir
    -- '11' com '011'.
    numero        text not null,
    andar         smallint,
    posicao       smallint,
    -- Descrição livre. HOJE ESTÁ VAZIA: não há nome de morador em nenhuma
    -- fonte contábil. A chave de privacidade é o par (unidade, situação
    -- financeira), não o nome.
    descricao     text,
    ativa         boolean not null default true,
    criado_em     timestamptz not null default now(),
    constraint unidades_numero_formato
        check (numero ~ '^[0-9]{1,4}$')
);

comment on table public.unidades is
    'Unidades do condomínio. numero é texto (o extrato usa zero à esquerda). '
    'descricao fica vazia: não há nome de morador em nenhuma fonte contábil.';

create unique index if not exists uq_unidades_condominio_numero
    on public.unidades (condominio_id, numero);

create index if not exists ix_unidades_andar
    on public.unidades (condominio_id, andar, posicao);

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.unidades enable row level security;
alter table public.unidades force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
revoke all on table public.unidades from public, anon, authenticated;
select public.fn_revogar_sequencias_publicas();

-- Sem grant para authenticated: o leitor não tem acesso a tabela alguma de
-- detalhe. O caminho de leitura de unidades é a função fn_lancamentos /
-- fn_resumo, que verifica o papel por condomínio.
