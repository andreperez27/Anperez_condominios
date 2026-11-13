-- ============================================================================
-- TESTE DE DRIFT DE GRANTS — LISTA PERMITIDA vs LISTA REAL (T41 a T46)
-- ============================================================================
-- Este teste é o que o usuário pediu explicitamente:
-- "Adicione um teste que, após cada migration, liste os grants de
--  authenticated e anon e compare com a lista permitida, falhando o build
--  se houver diferença."
--
-- ⚠️⚠️ ESTE TESTE É AUTOCONTIDO E SEGURO PARA O REMOTO ⚠️⚠️
--
-- Ele:
--   • NÃO cria usuário (não depende de 00_preparacao.test.sql);
--   • NÃO cria condomínio;
--   • NÃO insere, altera ou apaga NADA (tudo é SELECT);
--   • NÃO depende de pgtap (usa SQL puro com RAISE EXCEPTION);
--   • LÊ a lista permitida do PRÓPRIO BANCO
--     (public.config_grants_permitidos, migration 016).
--
-- Isso significa que o MESMO arquivo roda:
--   • no local, como parte da bateria (run_tests.ps1);
--   • no remoto, depois do db push, sem adaptação nenhuma.
--
-- Para rodar no remoto:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--       -f supabase/tests/05_drift_grants.test.sql
--
-- ESCOPO DO T46 (default privileges)
-- ---------------------------------
-- O T46 e o UNICO teste cujo escopo muda entre o ambiente local e o
-- hospedado, e o motivo e tecnico, nao de conveniencia:
--
--   - O T46 olha os DEFAULT PRIVILEGES: as permissoes que um objeto novo
--     herda do papel que o cria.
--   - Nossas migrations rodam como `postgres`. Logo, o que importa e o
--     default privilege do `postgres` no schema `public`.
--   - O `supabase_admin` e o owner padrao de parte dos objetos da
--     plataforma. Ele NAO cria nenhum dos nossos objetos, entao os
--     defaults dele sao risco RESIDUAL: so vatam se ele algum dia criar
--     um objeto em `public`.
--   - No ambiente LOCAL, o bootstrap roda como `supabase_admin` e revoga
--     os dois conjuntos - entao da para ser estrito.
--   - No ambiente HOSPEDADO, o `postgres` nao pode alterar os default
--     privileges de outro papel (so o dono pode). Revogar os do
--     `supabase_admin` exige o Dashboard - e o usuario decidiu aceita-los
--     como risco residual, porque as nossas migrations rodam como
--     `postgres`.
--
-- Por isso o escopo e passado explicitamente:
--
--   escopo_t46=estrito   (padrao) -> postgres + supabase_admin + app_owner
--                            no schema public (+ entrada global). E o que o
--                            ambiente local usa.
--   escopo_t46=postgres            -> so quem cria os nossos objetos
--                            (postgres + app_owner) no schema public.
--                            E o que o ambiente HOSPEDADO usa.
--
-- Comando no remoto:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v escopo_t46=postgres \
--       -f supabase/tests/05_drift_grants.test.sql
--
-- O escopo NUNCA afeta o T42 (a lista real de grants x a lista permitida),
-- que e a garantia real e roda igual nos dois ambientes.
--
-- TODAS as verificações rodam numa única transação: se uma falhar, as
-- demais ainda são checadas e a exceção final lista TUDO que está errado
-- de uma vez (não só o primeiro problema).
-- ============================================================================

-- O escopo do T46 vem de uma variavel do psql. Sem ela, assume 'estrito'
-- (o ambiente local). No remoto, passe -v escopo_t46=postgres.
\if :{?escopo_t46}
\else
\set escopo_t46 'estrito'
\endif

select set_config('app.t46_escopo', :'escopo_t46', false);

do $$
declare
    v_falhas text := '';
    v_qtd    int;
    v_lista  text;
    v_escopo text;
    v_papeis text[];
begin
    -- Escopo desta verificacao (ver o cabecalho do arquivo).
    v_escopo := coalesce(current_setting('app.t46_escopo', true), 'estrito');

    if v_escopo = 'estrito' then
        v_papeis := array['postgres', 'supabase_admin', 'app_owner'];
    elsif v_escopo = 'postgres' then
        v_papeis := array['postgres', 'app_owner'];
    else
        raise exception 'escopo_t46 invalido: % (use estrito ou postgres)', v_escopo;
    end if;


    ------------------------------------------------------------------
    -- 1. Comparação da lista real com a lista permitida
    ------------------------------------------------------------------
    -- "SOBRA": existe privilégio no banco que não está na lista.
    -- "FALTA": existe na lista mas o banco não tem.
    ------------------------------------------------------------------
    select count(*)::int,
           coalesce(string_agg(
               format('  - %s / %s / %s (%s)', objeto, papel, privilegios, problema),
               E'\n'
           ), '')
      into v_qtd, v_lista
      from (
          with objetos as (
              select c.relname as nome,
                     c.relkind,
                     c.relacl,
                     c.relowner
                from pg_class c
                join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public'
                 and c.relkind in ('r', 'v', 'm', 'f', 'S')
          ),
          concessoes as (
              select o.nome,
                     o.relkind,
                     g.grantee::regrole::text as papel,
                     g.privilege_type
                from objetos o
                cross join lateral aclexplode(
                         coalesce(o.relacl, acldefault(o.relkind, o.relowner))
                     ) g
               where g.grantee in (
                       select oid from pg_roles where rolname in ('anon', 'authenticated')
                   )
          ),
          agrupadas as (
              select nome,
                     relkind,
                     papel,
                     string_agg(privilege_type, ',' order by privilege_type) as privilegios
                from concessoes
               group by nome, relkind, papel
          ),
          permitidas as (
              select objeto_nome as nome,
                     papel,
                     privilegios
                from public.config_grants_permitidos
               where schema_nome = 'public'
          ),
          drift as (
              select coalesce(a.nome, p.nome) as objeto,
                     coalesce(a.papel, p.papel) as papel,
                     coalesce(a.privilegios, p.privilegios) as privilegios,
                     case when a.nome is null then 'FALTA o privilegio'
                          when p.nome is null then 'SOBRA o privilegio'
                          else 'DIVERGENTE' end as problema
                from agrupadas a
                full outer join permitidas p
                  on a.nome = p.nome
                 and a.papel = p.papel
                 and a.privilegios = p.privilegios
               where a.nome is null
                  or p.nome is null
          )
          select * from drift
      ) d;

    if v_qtd > 0 then
        v_falhas := v_falhas || E'\n[LISTA PERMITIDA x LISTA REAL] ' ||
                    format('%s divergencia(s):%s', v_qtd, v_lista);
    else
        raise notice 'OK: lista permitida = lista real (nenhum drift)';
    end if;

    ------------------------------------------------------------------
    -- 2. T43 — anon não tem NENHUM privilégio no schema public
    ------------------------------------------------------------------
    select count(*)::int
      into v_qtd
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      cross join lateral aclexplode(
               coalesce(c.relacl, acldefault(c.relkind, c.relowner))
           ) g
     where n.nspname = 'public'
       and c.relkind in ('r', 'v', 'm', 'f', 'S')
       and g.grantee in (select oid from pg_roles where rolname = 'anon');

    if v_qtd > 0 then
        v_falhas := v_falhas || format(
            E'\n[T43] anon tem %s privilegio(s) no schema public', v_qtd);
    else
        raise notice 'OK: anon sem privilegios no schema public';
    end if;

    ------------------------------------------------------------------
    -- 3. T44 / T45 — nenhuma função pública é executável por anon
    ------------------------------------------------------------------
    select count(*)::int,
           coalesce(string_agg(p.proname || ' (' || p.prosrc || ')', E'\n  '), '')
      into v_qtd, v_lista
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and has_function_privilege('anon', p.oid, 'EXECUTE');

    if v_qtd > 0 then
        v_falhas := v_falhas || format(
            E'\n[T44] anon pode executar %s funcao(oes) publica(s):%s',
            v_qtd, v_lista);
    else
        raise notice 'OK: anon nao executa nenhuma funcao publica';
    end if;

    select count(*)::int
      into v_qtd
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and has_function_privilege('anon', p.oid, 'EXECUTE');

    if v_qtd > 0 then
        v_falhas := v_falhas || format(
            E'\n[T45] anon pode executar %s funcao(oes) SECURITY DEFINER publica(s)',
            v_qtd);
    else
        raise notice 'OK: anon nao executa funcao SECURITY DEFINER publica';
    end if;

    ------------------------------------------------------------------
    -- 4. T46 — os default privileges não dão acesso a anon/authenticated
    ------------------------------------------------------------------
    -- Escopo de SCHEMA: o `public` (onde vive o projeto) e a forma SEM
    -- clausula de schema (defaclnamespace = 0, que vale para TODOS os
    -- schemas). Schemas do proprio Supabase (ex.: `supabase_functions`,
    -- `storage`, `graphql`) ficam de fora: pertencem a plataforma, e revogar
    -- os default privileges deles quebraria a plataforma.
    --
    -- Escopo de PAPEL: so os papeis que criam os nossos objetos (ver
    -- `v_papeis`, montado no inicio do bloco). Ver o cabecalho do arquivo
    -- para a diferenca entre o escopo `estrito` (local) e `postgres`
    -- (hospedado).
    ------------------------------------------------------------------
    select count(*)::int,
           coalesce(string_agg(
               format('  - papel %s / %s / %s',
                      pg_get_userbyid(d.defaclrole),
                      coalesce(n.nspname, '(todos os schemas)'),
                      array_to_string(d.defaclacl, ', ')),
               E'\n'
           ), '')
      into v_qtd, v_lista
      from pg_default_acl d
      left join pg_namespace n on n.oid = d.defaclnamespace
     where (d.defaclnamespace = 0
            or d.defaclnamespace = 'public'::regnamespace)
       and pg_get_userbyid(d.defaclrole) = any(v_papeis)
       and (d.defaclacl::text like '%anon=%'
         or d.defaclacl::text like '%authenticated=%');

    if v_qtd > 0 then
        v_falhas := v_falhas || format(
            E'\n[T46] default privileges concedem acesso a anon/authenticated (escopo %s):%s',
            v_escopo, v_lista);
    else
        raise notice 'OK: nenhum default privilege concede acesso a anon/authenticated (escopo %)', v_escopo;
    end if;

    ------------------------------------------------------------------
    -- 5. T41 — nenhuma tabela de DETALHE tem privilégio para
    --         anon/authenticated
    ------------------------------------------------------------------
    -- A lista de tabelas de detalhe é explícita. Qualquer privilégio sobre
    -- elas é falha.
    --
    -- ⚠️ `perfis` e `granularidade_ordem` NÃO entram: são tabelas de
    -- CONFIGURAÇÃO, não de detalhe. O leitor tem SELECT nelas legitimamente.
    -- (`config_grants_permitidos` também não entra — o leitor NÃO tem
    -- privilégio nela desde 12/11/2026: o drift roda como postgres.)
    select count(*)::int,
           coalesce(string_agg(
               format('  - %s / %s / %s', table_name, grantee, privs), E'\n'
           ), '')
      into v_qtd, v_lista
      from (
            select table_name, grantee,
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
             group by table_name, grantee
      ) x;

    if v_qtd > 0 then
        v_falhas := v_falhas || format(
            E'\n[T41] tabela(s) de DETALHE com privilegio para anon/authenticated:%s',
            v_lista);
    else
        raise notice 'OK: nenhuma tabela de detalhe com privilegio para anon/authenticated';
    end if;

    ------------------------------------------------------------------
    -- Resultado
    ------------------------------------------------------------------
    if v_falhas <> '' then
        raise exception 'DRIFT DE GRANTS DETECTADO:%', v_falhas;
    end if;

    raise notice 'OK: todas as verificacoes de drift passaram';
end;
$$;
