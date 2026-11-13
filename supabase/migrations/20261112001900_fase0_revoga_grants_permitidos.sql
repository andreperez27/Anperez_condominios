-- ============================================================================
-- MIGRATION 019 — FASE 0: config_grants_permitidos — REVOKE DO authenticated
-- ============================================================================
-- A tabela `config_grants_permitidos` é DADO DE CONFIGURAÇÃO, lida pelo teste
-- de drift (T42) que roda como `postgres`. O `authenticated` NÃO precisa de
-- nenhum acesso a ela — a transparência para o auditor não depende de
-- privilégio (o teste roda no remoto com `psql`/`postgres`).
--
-- Antes (migration 016): `authenticated` tinha SELECT (política + GRANT).
-- Depois desta migration: `authenticated` NÃO tem privilégio nenhum.
-- A lista permitida é atualizada junto (a linha dela mesma é removida) —
-- sem isso, o T42 reportaria "FALTA o privilegio" (drift falso-positivo).
-- ============================================================================

revoke all on table public.config_grants_permitidos from public, anon, authenticated;

drop policy if exists config_grants_permitidos_leitura on public.config_grants_permitidos;

delete from public.config_grants_permitidos
 where schema_nome = 'public'
   and objeto_nome = 'config_grants_permitidos'
   and papel       = 'authenticated'
   and privilegios = 'SELECT';

comment on table public.config_grants_permitidos is
    'Lista do que anon/authenticated PODEM ter. Fonte unica de verdade do '
    'teste de drift de grants (05_drift_grants.test.sql), que roda como '
    'postgres. SEM privilegio para anon/authenticated desde 12/11/2026.';
