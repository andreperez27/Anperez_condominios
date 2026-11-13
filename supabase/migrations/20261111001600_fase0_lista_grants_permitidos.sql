-- ============================================================================
-- MIGRATION 016 — FASE 0: LISTA PERMITIDA DE GRANTS (fonte única de verdade)
-- ============================================================================
-- A lista do que `anon` e `authenticated` PODEM ter fica no banco, e não
-- dentro do arquivo de teste. Isso permite:
--   1. o teste de drift ser EXECUTADO NO REMOTO sem adaptação (ele lê a
--      lista do próprio banco);
--   2. a lista ser auditável por SQL;
--   3. o teste não depender de nenhuma migration de teste.
--
-- A tabela é de CONFIGURAÇÃO (não de dado de condomínio) e por isso é
-- versionada. Não contém nada sobre o condomínio.
--
-- Documento de referência: docs\SEGURANCA_RLS.md §3
-- ============================================================================

create table if not exists public.config_grants_permitidos (
    id              uuid primary key default gen_random_uuid(),
    schema_nome     text not null default 'public',
    objeto_nome     text not null,
    papel           text not null,
    privilegios     text not null,
    justificativa   text,
    criado_em       timestamptz not null default now(),
    constraint config_grants_permitidos_unico
        unique (schema_nome, objeto_nome, papel, privilegios),
    constraint config_grants_permitidos_papel
        check (papel in ('anon','authenticated','app_importador','app_owner'))
);

comment on table public.config_grants_permitidos is
    'Lista do que anon/authenticated PODEM ter. Fonte unica de verdade do '
    'teste de drift de grants (05_drift_grants.test.sql), que roda no local '
    'e no remoto sem adaptacao.';

-- ----------------------------------------------------------------------------
-- A LISTA PERMITIDA
-- ----------------------------------------------------------------------------
-- Só `authenticated` tem algo — e apenas SELECT em:
--   • 2 tabelas de CONFIGURACAO (o proprio perfil e a ordem de granularidade
--     da politica de visibilidade);
--   • 14 views AGREGADAS (que ja filtram o tenant por dentro).
--
-- `anon` nao tem NADA. Qualquer objeto novo com privilegio de anon é
-- falha de drift.
--
-- Nenhuma tabela de DETALHE entra aqui — essa ausência é o que o teste
-- verifica (T41).
--
-- A `config_grants_permitidos` NAO entra mais: ela e lida apenas pelo
-- drift (postgres). Ver migration 20261112001900_fase0_revoga_grants_permitidos.
insert into public.config_grants_permitidos (
    schema_nome, objeto_nome, papel, privilegios, justificativa
)
values
    -- Tabelas de configuracao
    ('public', 'granularidade_ordem', 'authenticated', 'SELECT',
     'Ordem de granularidade da politica de visibilidade (tabela tecnica).'),
    ('public', 'perfis', 'authenticated', 'SELECT',
     'O proprio perfil do usuario logado.'),

    -- Views agregadas
    ('public', 'v_cobertura_competencias',      'authenticated', 'SELECT', 'Status de competencia por fonte.'),
    ('public', 'v_conciliacao',                  'authenticated', 'SELECT', 'Conciliacao por fundo.'),
    ('public', 'v_contestacoes',                 'authenticated', 'SELECT', 'Contestacoes (filtra por papel dentro).'),
    ('public', 'v_duplicatas_candidatas',        'authenticated', 'SELECT', 'Duplicatas (filtra por papel dentro).'),
    ('public', 'v_importacao_resumo',            'authenticated', 'SELECT', 'Resumo agregado das importacoes.'),
    ('public', 'v_lancamentos_com_duplicata',    'authenticated', 'SELECT', 'Lancamentos marcados como duplicata.'),
    ('public', 'v_pendencias_resumo',            'authenticated', 'SELECT', 'CONTAGEM de pendencias (sem detalhe).'),
    ('public', 'v_resultado_bruto',              'authenticated', 'SELECT', 'Resultado bruto por competencia.'),
    ('public', 'v_resultado_liquido',            'authenticated', 'SELECT', 'Resultado liquido por competencia.'),
    ('public', 'v_resultado_liquido_por_fundo',  'authenticated', 'SELECT', 'Resultado liquido por fundo.'),
    ('public', 'v_resumo_competencia_fundo',     'authenticated', 'SELECT', 'Agregado por competencia e fundo.'),
    ('public', 'v_resumo_competencia_rubrica',   'authenticated', 'SELECT', 'Agregado por competencia e rubrica.'),
    ('public', 'v_serie_historica',              'authenticated', 'SELECT', 'Serie historica agregada.'),
    ('public', 'v_transferencias_internas',      'authenticated', 'SELECT', 'Transferencias internas (filtra por papel dentro).')
on conflict (schema_nome, objeto_nome, papel, privilegios) do nothing;

-- ----------------------------------------------------------------------------
-- RLS e GRANTS
-- ----------------------------------------------------------------------------
-- A tabela de configuração é lida pelo teste de drift (que roda como
-- postgres). NÃO é dado de condomínio.
-- Desde a migration 20261112001900_fase0_revoga_grants_permitidos,
-- `anon`/`authenticated` NÃO têm nenhum privilégio sobre ela.
alter table public.config_grants_permitidos enable row level security;
alter table public.config_grants_permitidos force  row level security;

drop policy if exists config_grants_permitidos_leitura on public.config_grants_permitidos;

revoke all on table public.config_grants_permitidos from public, anon, authenticated;

-- Revogação DINÂMICA das sequências: os ids usam gen_random_uuid(), que não
-- cria sequência — por isso nomes fixos quebrariam a migration.
select public.fn_revogar_sequencias_publicas();
