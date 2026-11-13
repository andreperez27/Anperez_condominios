-- ============================================================================
-- BOOTSTRAP — ZERA OS PRIVILÉGIOS PADRÃO DO SCHEMA public
-- ============================================================================
-- Este script roda UMA VEZ por container, ANTES das migrations.
--
-- POR QUE EXISTE
-- --------------
-- No Supabase local existem DOIS conjuntos de default privileges relevantes:
--
--   1. do papel `postgres`       → é o papel que executa as migrations;
--   2. do papel `supabase_admin` → é o owner padrão de parte dos objetos do
--                                  schema public, e é superuser.
--
-- Ambos concedem, por padrão, privilégio a `anon` e `authenticated` em
-- qualquer tabela, função e sequência criados DEPOIS. Sem revogar, uma
-- tabela nova criada por engano nasceria com SELECT liberado para o leitor —
-- quebrando a garantia de acesso de forma silenciosa.
--
-- POR QUE PRECISA RODAR FORA DAS MIGRATIONS
-- -----------------------------------------
-- No Postgres, cada papel só pode alterar os PRÓPRIOS default privileges.
-- O papel `postgres` NÃO é superuser no Supabase local (só o `supabase_admin`
-- é), então ele recebe:
--
--   ERROR: permission denied to change default privileges
--
-- ao tentar revogar os default privileges do `supabase_admin`.
--
-- Verificado em 11/11/2026: rodando como `supabase_admin`, o revoke funciona.
--
-- COMO EXECUTAR
-- --------------
--   docker exec -i supabase_db_Anperez_Condominios psql -U supabase_admin -d postgres \
--       < supabase\bootstrap\00-zerar_privilegios_padrao.sql
--
-- O script de bootstrap do projeto (supabase/bootstrap/README.md) faz isso
-- automaticamente e registra o resultado no diário de bordo.
--
-- Idempotente: pode rodar quantas vezes for preciso.
-- ============================================================================

\echo '=== zerando default privileges (supabase_admin) ==='

-- ⚠️ POR QUE AS DUAS FORMAS
-- ----------------------
-- O Postgres guarda os default privileges em DUAS entradas independentes:
-- uma GLOBAL (sem cláusula de schema) e uma POR SCHEMA (`in schema public`).
-- As duas são aplicadas a um objeto novo. Por isso é preciso revogar nas
-- DUAS formas:
--
--   • SEM `in schema public` → vale para TODOS os schemas (é o default do
--     role). Sem isso, um objeto criado fora do `public` herdaria o acesso.
--   • COM `in schema public` → limpa a entrada que o Supabase já deixou
--     gravada no schema `public` (que existe desde a criação do projeto).
--
-- Revogar só a global NÃO limpa a entrada por schema — e vice-versa.
alter default privileges for role supabase_admin revoke all on tables    from anon, authenticated;
alter default privileges for role supabase_admin revoke all on functions  from anon, authenticated;
alter default privileges for role supabase_admin revoke all on sequences from anon, authenticated;

alter default privileges for role supabase_admin in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role supabase_admin in schema public revoke all on functions  from anon, authenticated;
alter default privileges for role supabase_admin in schema public revoke all on sequences from anon, authenticated;

alter default privileges for role postgres revoke all on tables    from anon, authenticated;
alter default privileges for role postgres revoke all on functions  from anon, authenticated;
alter default privileges for role postgres revoke all on sequences from anon, authenticated;

alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions  from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;

-- ============================================================================
-- ACESSO DO app_owner AO SCHEMA auth
-- ============================================================================
-- O `app_owner` é o owner das funções SECURITY DEFINER — é ELE quem executa
-- o corpo delas, inclusive o `auth.uid()`. Sem USAGE no schema `auth`, o
-- `auth.uid()` falha com "permission denied for schema auth" (verificado em
-- 11/11/2026).
--
-- O schema `auth` pertence ao `supabase_admin`, e o `postgres` NÃO pode
-- conceder nele ("no privileges were granted for auth"). Por isso o grant
-- é feito aqui, que roda como `supabase_admin`.
grant usage on schema auth to app_owner;
grant execute on function auth.uid() to app_owner;

-- Os helpers de TESTE (supabase/tests/00_preparacao.test.sql) são
-- SECURITY DEFINER com owner = app_owner, e precisam ler `auth.users` para
-- mapear e-mail → id. O schema auth pertence ao supabase_admin, então o
-- grant é feito aqui (que roda como supabase_admin).
grant select on auth.users to app_owner;

-- O schema `extensions` guarda o pgcrypto e o pgtap. Sem USAGE, o
-- `authenticated` não consegue executar as funções do pgTAP nos testes
-- (o `set local role authenticated` remove o acesso implícito).
grant usage on schema extensions to authenticated;
grant execute on all functions in schema extensions to authenticated;

-- O app_importador também precisa de USAGE no schema extensions: é o
-- papel usado no bloco de testes que verifica o comportamento do
-- importador (set role app_importador).
grant usage on schema extensions to app_importador;

-- O app_owner (owner das funções privilegiadas) também precisa de USAGE
-- e EXECUTE no schema extensions: as funções usam digest() do pgcrypto
-- (verificado em 12/11/2026: "permission denied for schema extensions").
grant usage on schema extensions to app_owner;
grant execute on all functions in schema extensions to app_owner;

-- O app_owner é o owner dos helpers de TESTE (supabase/tests/), que criam
-- fixtures: condomínio B com fundos, competência, fonte de importação e
-- lançamentos. Sem estes privilégios o corpo falha com "permission denied
-- for table fundos" (verificado em 12/11/2026).
grant insert, update on public.fundos to app_owner;
grant insert, update on public.rubricas to app_owner;
grant insert, update on public.competencias to app_owner;
grant insert, update on public.fontes_importacao to app_owner;
grant insert, update on public.importacoes to app_owner;
grant insert, update on public.membros to app_owner;
grant insert, update on public.perfis to app_owner;
grant insert, update on public.lancamentos to app_owner;
grant insert, update on public.lancamento_rubrica to app_owner;
grant insert, update on public.duplicatas_candidatas to app_owner;
grant insert, update on public.grupos_transferencia to app_owner;
grant insert, update on public.transferencias_internas to app_owner;
grant insert, update on public.anexos to app_owner;
grant insert, update on public.acesso_log to app_owner;
grant insert, update on public.auditoria_log to app_owner;
grant select on public.fundos, public.rubricas, public.competencias,
                public.fontes_importacao, public.importacoes, public.membros,
                public.perfis, public.unidades, public.lancamentos,
                public.lancamento_rubrica, public.duplicatas_candidatas,
                public.grupos_transferencia, public.transferencias_internas,
                public.anexos, public.acesso_log, public.auditoria_log
to app_owner;

\echo '=== estado final dos default privileges ==='
-- ⚠️ Sem filtro de schema: a forma sem `in schema public` vale para todos os
-- schemas (defaclnamespace = 0). O esperado é que NENHUMA linha tenha
-- `anon=` ou `authenticated=` no ACL.
select pg_get_userbyid(d.defaclrole) as papel,
       coalesce(n.nspname, '(todos os schemas)') as schema_nome,
       case d.defaclobjtype
            when 'r' then 'tabela'
            when 'f' then 'funcao'
            when 'S' then 'sequencia'
            else d.defaclobjtype
       end as tipo,
       array_to_string(d.defaclacl, ', ') as acl,
       case
            when d.defaclnamespace <> 0
             and d.defaclnamespace <> 'public'::regnamespace
            then 'fora do escopo (schema do Supabase)'
            when d.defaclacl::text like '%anon=%'
              or d.defaclacl::text like '%authenticated=%'
            then 'CONCEDE ACESSO A ANON/AUTHENTICATED'
            else 'ok'
       end as situacao
  from pg_default_acl d
  left join pg_namespace n on n.oid = d.defaclnamespace
 order by 1, 2, 4;

\echo '=== fim ==='
