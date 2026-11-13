-- ============================================================================
-- MIGRATION 002b — FASE 0: HELPERS DE REVOGAÇÃO DE PRIVILÉGIOS
-- ============================================================================
-- Convenções do projeto:
--
--   1. REVOGAÇÃO TRIPLA. No Supabase, o ambiente mantém `execute`/`select`
--      para `anon`/`authenticated` via *default privileges*. Revogar só de
--      `public` NÃO basta — foi testado no Anperez Money (migration 36b) e
--      não funcionou. O padrão é revogar de `public` + `anon` + `authenticated`.
--
--   2. REVOGAÇÃO DINÂMICA. Os `id` usam `gen_random_uuid()`, que não cria
--      sequência — listar `public.<tabela>_id_seq` quebraria a migration.
--      Estes helpers varrem o catálogo e revogam o que existir.
--
--   3. PRIVILÉGIOS DE OBJETOS FUTUROS. Os *default privileges* do papel que
--      executa as migrations dão, por padrão, privilégio a `anon` e
--      `authenticated` em tudo que for criado depois. Se não forem revogados,
--      qualquer tabela/função/view nova nasce com acesso liberado — e a
--      garantia do leitor se quebra silenciosamente.
--
--      Os default privileges que importam são os do papel `postgres` (que
--      executa as migrations) E os do papel `supabase_admin` (owner padrão de
--      parte dos objetos do schema public no Supabase). Revogar o do
--      `supabase_admin` exige rodar como `supabase_admin` — ver nota no
--      final desta migration.
--
-- Documento de referência: docs\SEGURANCA_RLS.md §3
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fn_revogar_tabelas_publicas — revoga tudo em tabelas/views do schema public
-- ----------------------------------------------------------------------------
create or replace function public.fn_revogar_tabelas_publicas()
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    r record;
begin
    for r in
        select c.relname
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relkind in ('r', 'p', 'v', 'm', 'f')
    loop
        execute format('revoke all on table public.%I from public, anon, authenticated', r.relname);
    end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_revogar_sequencias_publicas — revoga tudo em sequências do schema public
-- ----------------------------------------------------------------------------
create or replace function public.fn_revogar_sequencias_publicas()
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    r record;
begin
    for r in
        select c.relname
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relkind = 'S'
    loop
        execute format('revoke all on sequence public.%I from public, anon, authenticated', r.relname);
    end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_revogar_funcoes_publicas — revoga EXECUTE de todas as funções public
-- ----------------------------------------------------------------------------
-- Cuidado: no Postgres, funções novas nascem com EXECUTE para PUBLIC.
-- Revogar aqui garante que nenhuma função fique chamável por `anon` ou
-- `authenticated` sem um GRANT explícito posterior.
create or replace function public.fn_revogar_funcoes_publicas()
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    r record;
begin
    for r in
        select p.oid::regprocedure::text as assinatura
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
    loop
        execute format('revoke all on function %s from public, anon, authenticated', r.assinatura);
    end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_revogar_objetos_futuros — neutraliza os default privileges
-- ----------------------------------------------------------------------------
-- Impede que um objeto criado DEPOIS (tabela, função ou sequência) herde
-- privilégio de `anon`/`authenticated`. É a rede de segurança para o caso
-- de alguém criar uma tabela nova sem revoke.
--
-- ⚠️ LIMITAÇÃO CONHECIDA E TESTADA: cada papel só pode alterar os próprios
-- default privileges. O papel `postgres` (que executa as migrations) não
-- consegue alterar os default privileges do `supabase_admin` — o erro é
-- "permission denied to change default privileges".
--
-- No ambiente local, os default privileges do `supabase_admin` são
-- alterados uma vez, fora das migrations, rodando como `supabase_admin`
-- (superuser). Ver a seção "DEFAULT PRIVILEGES DO supabase_admin" no final.
--
-- Esta função trata o que é possível a partir do papel executor: registra
-- o que foi feito, para que o teste de drift de grants possa detectar a
-- diferença.
create or replace function public.fn_revogar_objetos_futuros()
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_papel text := current_user;
begin
    -- Objetos criados pelo papel executor: sem privilégio para anon/authenticated.
    execute format(
        'alter default privileges for role %I in schema public revoke all on tables from anon, authenticated',
        v_papel);
    execute format(
        'alter default privileges for role %I in schema public revoke all on functions from anon, authenticated',
        v_papel);
    execute format(
        'alter default privileges for role %I in schema public revoke all on sequences from anon, authenticated',
        v_papel);
end;
$$;

-- ----------------------------------------------------------------------------
-- Grants dos próprios helpers
-- ----------------------------------------------------------------------------
-- Os helpers são de manutenção: rodam pelo papel executor das migrations.
-- Não podem ser chamados por `anon` nem por `authenticated`.
revoke all on function public.fn_revogar_tabelas_publicas()   from public, anon, authenticated;
revoke all on function public.fn_revogar_sequencias_publicas() from public, anon, authenticated;
revoke all on function public.fn_revogar_funcoes_publicas()   from public, anon, authenticated;
revoke all on function public.fn_revogar_objetos_futuros()     from public, anon, authenticated;

grant execute on function public.fn_revogar_tabelas_publicas()   to postgres;
grant execute on function public.fn_revogar_sequencias_publicas() to postgres;
grant execute on function public.fn_revogar_funcoes_publicas()   to postgres;
grant execute on function public.fn_revogar_objetos_futuros()     to postgres;

-- ============================================================================
-- DEFAULT PRIVILEGES DO supabase_admin
-- ============================================================================
-- No Supabase local, os default privileges que dão acesso a anon/
-- authenticated pertencem ao papel `supabase_admin`, NÃO ao `postgres`.
-- Revogar os do `postgres` não basta: objetos criados pelo `supabase_admin`
-- continuariam herdando acesso.
--
-- Como `postgres` NÃO é superuser no Supabase local (só o `supabase_admin`
-- é), o revoke dos default privileges do `supabase_admin` precisa rodar
-- como `supabase_admin`. Não é possível fazer isso de dentro de uma
-- migration executada pelo `postgres`.
--
-- SOLUÇÃO ADOTADA: o revoke é executado pelo script de bootstrap
-- (supabase/bootstrap/00-zerar_privilegios_padrao.sql), que roda uma vez
-- por container, ANTES das migrations. O comando é:
--
--   docker exec -i <container> psql -U supabase_admin -d postgres < \
--       supabase/bootstrap/00-zerar_privilegios_padrao.sql
--
-- O teste de drift (supabase/tests/grants_publicos.test.sql) verifica o
-- estado final e falha o build se a lista de default privileges divergir.
--
-- Verificação (executada com sucesso em 11/11/2026):
--   select defaclrole::regrole, defaclobjtype, defaclacl
--     from pg_default_acl where defaclnamespace = 'public'::regnamespace;
--   → apenas postgres e service_role, em ambos os papéis.
-- ============================================================================
