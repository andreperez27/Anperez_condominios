-- ============================================================================
-- BOOTSTRAP REMOTO — O QUE O `postgres` PODE FAZER
-- ============================================================================
-- Para o banco HOSPEDADO (https://aejuoiwxzzsxmhhizwau.supabase.co).
--
-- ⚠️ ESTE NÃO É O BOOTSTRAP LOCAL.
--    O bootstrap local (00-zerar_privilegios_padrao.sql) roda como
--    `supabase_admin` e faz coisas que o `postgres` hospedado NÃO PODE:
--      1. zerar os default privileges do papel `supabase_admin`;
--      2. conceder no schema `auth`.
--    No hospedado, `supabase_admin` não é acessível por senha.
--
-- COMO USAR
-- ---------
--   Dashboard > SQL Editor > cole este arquivo > Run
--   (ou: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 01-zerar_privilegios_remoto.sql)
--
-- ⚠️ RODE UMA VEZ, e só depois de `supabase db push`.
-- ============================================================================


-- ============================================================================
-- 1. DEFAULT PRIVILEGES DO PRÓPRIO `postgres`
-- ============================================================================
-- O `postgres` PODE alterar os próprios default privileges. Assim, qualquer
-- tabela/função/sequência criada DEPOIS por ele nasce sem privilégio de
-- `anon`/`authenticated`.
--
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
-- É a isso que o teste de drift (T46) confere.
--
-- O `postgres` NÃO PODE alterar os default privileges do `supabase_admin`
-- (o papel é de outro usuário). Os defaults dele são RISCO RESIDUAL ACEITO
-- (decisão de 12/11/2026): o `supabase_admin` não cria nenhum dos nossos
-- objetos — as migrations rodam como `postgres` — e o T42 da bateria de
-- drift continua conferindo os GRANTS REAIS de tudo em `public`. O T46, no
-- remoto, avalia só os defaults de quem cria os nossos objetos: passe
-- `-v escopo_t46=postgres` (ver o cabeçalho do teste de drift).
alter default privileges for role postgres
    revoke all on tables    from anon, authenticated;
alter default privileges for role postgres
    revoke all on functions  from anon, authenticated;
alter default privileges for role postgres
    revoke all on sequences from anon, authenticated;

alter default privileges for role postgres in schema public
    revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public
    revoke all on functions  from anon, authenticated;
alter default privileges for role postgres in schema public
    revoke all on sequences from anon, authenticated;


-- ============================================================================
-- 2. PRIVILÉGIOS DO app_owner NO SCHEMA public
-- ============================================================================
-- O `app_owner` é o owner das funções e views privilegiadas (SECURITY
-- DEFINER, com BYPASSRLS). Ele precisa de CREATE no schema public para
-- poder RECEBER a propriedade dos objetos, e precisa ser membro do
-- `postgres` para que o `postgres` possa fazer o `alter ... owner to`.
grant usage, create on schema public to app_owner;
grant app_owner to postgres;


-- ============================================================================
-- 3. SCHEMA `auth` — ESPERE ESTE PASSO FALHAR
-- ============================================================================
-- O schema `auth` pertence ao `supabase_admin`. O `postgres` hospedado
-- geralmente NÃO pode conceder nele, e o erro esperado é:
--
--     ERROR: permission denied for schema auth
--
-- ⚠️ **ISSO NÃO É BLOQUEIO.** As funções de produção NÃO chamam
--    `auth.uid()` — todas usam `public.fn_usuario_atual()`, que lê o GUC
--    de sessão (`request.jwt.claim.sub` / `request.jwt.claims`) direto,
--    sem resolver o schema `auth`.
--
--    O `auth.uid()` é usado apenas nas POLICIES, que rodam com os
--    privilégios do usuário `authenticated` — que tem USAGE no schema
--    `auth` por padrão no Supabase.
--
--    O único uso de `auth.users` é o helper de TESTE
--    `test_criar_usuario()`, que NÃO EXISTE no remoto (os usuários são
--    criados pela interface do Supabase).
--
--    => Se este passo falhar, tudo bem. Comente as duas linhas e siga.
--    => Para conferir o estado depois:
--       select has_schema_privilege('app_owner', 'auth', 'usage');
--
-- grant usage on schema auth to app_owner;


-- ============================================================================
-- 4. LEITURA DE auth.users (OPCIONAL, SÓ PARA OS HELPERS DE TESTE)
-- ============================================================================
-- O `app_owner` é o owner de `test_criar_usuario()` (helper de teste que
-- cria usuários com senha fixa). No remoto, os usuários são reais e
-- criados pela interface — logo, esta linha é OPCIONAL.
--
-- Se o passo 3 falhou, esta linha também falha (depende do mesmo
-- privilégio no schema auth).
--
-- grant select on auth.users to app_owner;


-- ============================================================================
-- 5. SCHEMA extensions (pgcrypto / pgtap)
-- ============================================================================
-- O `app_owner` usa `digest()` do pgcrypto no corpo das funções
-- privilegiadas. Sem USAGE no schema, o corpo falha com
-- "permission denied for schema extensions".
grant usage on schema extensions to app_owner;
grant execute on all functions in schema extensions to app_owner;


-- ============================================================================
-- 6. CONFERÊNCIA EM pg_default_acl
-- ============================================================================
-- Mostra o estado APÓS os revokes. A leitura usa as TRÊS categorias decididas
-- (ver docs/DEPLOY_REMOTO.md):
--
--   1. LIMPO — `postgres` (e `app_owner`) no schema `public` (ou na forma
--      global). É o que este bootstrap controla. Se aparecer `anon=` ou
--      `authenticated=`, qualquer objeto novo criado por ele nasceria
--      exposto — o ajuste é refazer este arquivo.
--
--   2. RISCO RESIDUAL ACEITO — defaults do `supabase_admin`. O `postgres`
--      NÃO PODE alterar os default privileges de outro papel (só o dono
--      pode). Mas o `supabase_admin` não cria NENHUM dos nossos objetos:
--      as migrations rodam como `postgres`. Os grants reais (o que importa)
--      são conferidos pelo T42 da bateria de drift. Ajustá-los exigiria o
--      Dashboard — e foi decidido aceitá-los.
--
--   3. SCHEMA INTERNO DA PLATAFORMA — defaults dentro de `storage`,
--      `graphql`, `graphql_public`, `supabase_functions` etc. São da
--      plataforma Supabase, valem só para objetos dela e NÃO devemos
--      alterar.
--
-- O que NÃO pode restar em nenhuma categoria: default privilege do
-- `postgres`/`app_owner` em `public` ou global concedendo acesso a
-- `anon`/`authenticated`.
select
    pg_get_userbyid(d.defaclrole)                     as papel,
    coalesce(n.nspname, '(todos os schemas)')          as schema_nome,
    case d.defaclobjtype
         when 'r' then 'tabela'
         when 'f' then 'funcao'
         when 'S' then 'sequencia'
         when 'T' then 'tipo'
         when 'n' then 'schema'
         else d.defaclobjtype
    end                                                as tipo,
    array_to_string(d.defaclacl, ', ')                as acl,
    case
        when (pg_get_userbyid(d.defaclrole) in ('postgres', 'app_owner'))
         and (d.defaclnamespace = 0
           or d.defaclnamespace = 'public'::regnamespace)
         and (d.defaclacl::text like '%anon=%'
           or d.defaclacl::text like '%authenticated=%')
        then '⚠️  CONCEDE ACESSO A ANON/AUTHENTICATED — refazer o bootstrap'
        when d.defaclnamespace <> 0
         and d.defaclnamespace <> 'public'::regnamespace
        then 'schema interno da plataforma (nao alterar)'
        when pg_get_userbyid(d.defaclrole) = 'supabase_admin'
        then 'risco residual aceito (nao cria nossos objetos; T42 confere os grants reais)'
        else 'ok'
    end                                                as situacao
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
order by 1, 2, 4;


-- ============================================================================
-- 7. VERIFICAÇÃO FINAL
-- ============================================================================
-- confere se o app_owner foi criado com BYPASSRLS
select
    rolname,
    rolbypassrls,
    rolcanlogin,
    rolsuper
from pg_roles
where rolname in ('app_owner', 'app_importador', 'postgres', 'anon', 'authenticated')
order by rolname;

-- confere os default privileges (T46 do teste de drift)
-- ⚠️ Sem filtro de schema: a forma sem `in schema public` vale para TODOS os
-- schemas (defaclnamespace = 0).
select
    pg_get_userbyid(d.defaclrole) as papel,
    coalesce(n.nspname, '(todos os schemas)') as schema_nome,
    case d.defaclobjtype
         when 'r' then 'tabela'
         when 'f' then 'funcao'
         when 'S' then 'sequencia'
         else d.defaclobjtype
    end as tipo,
    array_to_string(d.defaclacl, ', ') as acl
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
order by 1, 2, 4;

-- confere que nenhuma tabela de DETALHE tem privilegio para anon/authenticated
select
    table_name,
    grantee,
    string_agg(privilege_type, ',' order by privilege_type) as privs
from information_schema.table_privileges
where table_schema = 'public'
  and grantee in ('anon', 'authenticated')
  and table_name in (
      'membros','convites','unidades',
      'competencias','status_competencia','fundos','rubricas',
      'rubrica_aliases','contas_origem','config_visibilidade',
      'fontes_importacao','importacoes','staging_lancamentos',
      'staging_transacoes','staging_duplicatas','lancamentos',
      'lancamento_rubrica','grupos_transferencia','transferencias_internas',
      'duplicatas_candidatas','conciliacoes','conciliacao_detalhe',
      'documentos','anexos','pendencias','pendencia_anotacoes',
      'contestacoes','auditoria_log','acesso_log','config_retencao_acesso',
      'serie_historica_resumo','serie_historica_anotacoes'
  )
group by 1, 2
order by 2, 1;
-- (o resultado esperado é VAZIO)
