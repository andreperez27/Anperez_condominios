-- ============================================================================
-- DRIFT DE GRANTS — VERSÃO REMOTA (SQL Editor do painel)
-- ============================================================================
-- Roda no console SQL do Supabase (painel) ou em `psql` como superusuário.
--
-- O que ele verifica (T41 a T46):
--   T41  nenhuma tabela de DETALHE tem privilégio para anon/authenticated
--   T42  a lista real de grants bate EXATAMENTE com a lista permitida
--   T43  anon não tem nenhum privilégio no schema public
--   T44  nenhuma função pública é executável por anon
--   T45  nenhuma função SECURITY DEFINER é executável por anon
--   T46  nenhum default privilege de postgres/app_owner concede acesso a
--        anon/authenticated no schema public
--
-- REGRAS (diferentes da versão local por necessidade):
--   • ESCOPO FIXO no T46: postgres + app_owner — quem cria os nossos
--     objetos no hospedado. Os default privileges do supabase_admin são
--     RISCO RESIDUAL ACEITO (ver DEPLOY_REMOTO.md §5.1).
--   • SEM variáveis do psql (\set, \if) — o SQL Editor não entende
--     meta-comandos; tudo é SQL puro e o escopo está escrito aqui.
--   • SOMENTE LEITURA: não cria usuário, não cria condomínio, não insere,
--     atualiza ou apaga nada nas tabelas do projeto. Uma tabela TEMPORÁRIA
--     de sessão armazena as linhas do resultado — ela não vai para o disco
--     do banco.
--
-- Como usar: cole o ARQUIVO INTEIRO no SQL Editor e execute. O resultado
-- aparece como uma tabela com uma linha por verificação (colunas: n, teste,
-- resultado, detalhe), terminando com um resumo. Procure por linhas com
-- resultado = 'FALHA' — idealmente não há nenhuma.
-- ============================================================================

drop table if exists drift_remoto_resultado;
create temporary table drift_remoto_resultado (
    n         int primary key,
    teste     text not null,
    resultado text not null,
    detalhe   text not null default ''
);

do $$
declare
    v_falhas text;
    v_qtd    int;
    v_lista  text;
begin
    -- ESCOPO FIXO DO T46 PARA O AMBIENTE HOSPEDADO (não editar aqui; para
    -- rodar a versão estrita, use o 05_drift_grants.test.sql local).
    -- (o $suffix$literais$ é apenas documentação — a lista está na query)

    ------------------------------------------------------------------
    -- T42 / LISTA PERMITIDA x LISTA REAL (a garantia principal)
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
        insert into drift_remoto_resultado
        values (1, 'T42 lista permitida x lista real', 'FALHA',
                format('%s divergencia(s):%s', v_qtd, E'\n' || v_lista));
    else
        insert into drift_remoto_resultado
        values (1, 'T42 lista permitida x lista real', 'ok', 'nenhum drift');
    end if;

    ------------------------------------------------------------------
    -- T43 — anon nao tem NENHUM privilegio no schema public
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
        insert into drift_remoto_resultado
        values (2, 'T43 anon x schema public', 'FALHA',
                format('anon tem %s privilegio(s)', v_qtd));
    else
        insert into drift_remoto_resultado
        values (2, 'T43 anon x schema public', 'ok', 'anon sem privilegios');
    end if;

    ------------------------------------------------------------------
    -- T44 / T45 — anon nao executa funcao publica
    ------------------------------------------------------------------
    select count(*)::int,
           coalesce(string_agg(p.proname, ', '), '')
      into v_qtd, v_lista
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and has_function_privilege('anon', p.oid, 'EXECUTE');

    if v_qtd > 0 then
        insert into drift_remoto_resultado
        values (3, 'T44 anon x funcoes publicas', 'FALHA',
                format('anon executa %s funcao(oes): %s', v_qtd, v_lista));
    else
        insert into drift_remoto_resultado
        values (3, 'T44 anon x funcoes publicas', 'ok', 'anon nao executa');
    end if;

    select count(*)::int
      into v_qtd
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and has_function_privilege('anon', p.oid, 'EXECUTE');

    if v_qtd > 0 then
        insert into drift_remoto_resultado
        values (4, 'T45 anon x SECURITY DEFINER', 'FALHA',
                format('anon executa %s SECURITY DEFINER', v_qtd));
    else
        insert into drift_remoto_resultado
        values (4, 'T45 anon x SECURITY DEFINER', 'ok', 'anon nao executa');
    end if;

    ------------------------------------------------------------------
    -- T46 — default privileges de postgres/app_owner no public
    -- (ESCOPO FIXO do ambiente hospedado; ver cabecalho)
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
       and pg_get_userbyid(d.defaclrole) in ('postgres', 'app_owner')
       and (d.defaclacl::text like '%anon=%'
         or d.defaclacl::text like '%authenticated=%');

    if v_qtd > 0 then
        insert into drift_remoto_resultado
        values (5, 'T46 default privileges (postgres/app_owner)', 'FALHA',
                format('%s default(s) concedem acesso a anon/authenticated:%s',
                       v_qtd, E'\n' || v_lista));
    else
        insert into drift_remoto_resultado
        values (5, 'T46 default privileges (postgres/app_owner)', 'ok',
                'nenhum default privilege concede acesso a anon/authenticated');
    end if;

    ------------------------------------------------------------------
    -- T41 — nenhuma tabela de DETALHE tem privilegio para anon/authenticated
    ------------------------------------------------------------------
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
        insert into drift_remoto_resultado
        values (6, 'T41 detalhe x anon/authenticated', 'FALHA',
                format('%s tabela(s) de detalhe com privilegio:%s', v_qtd, E'\n' || v_lista));
    else
        insert into drift_remoto_resultado
        values (6, 'T41 detalhe x anon/authenticated', 'ok',
                'nenhuma tabela de detalhe com privilegio');
    end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- RESULTADO (o que aparece no SQL Editor)
-- ----------------------------------------------------------------------------
select n, teste, resultado, detalhe
  from drift_remoto_resultado
 order by n;

select case
           when count(*) filter (where resultado = 'FALHA') = 0
               then 'DRIFT OK — todos os 6 testes passaram'
           else format('DRIFT FALHOU — %s de 6 verificacao(oes) com problema',
                       count(*) filter (where resultado = 'FALHA'))
       end as resumo,
       count(*) filter (where resultado = 'FALHA') as falhas,
       count(*) as verificacoes
  from drift_remoto_resultado;
