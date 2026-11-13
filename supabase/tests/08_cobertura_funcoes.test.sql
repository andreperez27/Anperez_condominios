-- ============================================================================
-- COBERTURA DE FUNÇÕES — TODA função de produção foi executada COM SUCESSO
-- e COM NEGAÇÃO (13/11/2026)
-- ============================================================================
-- PROTEÇÃO ESTRUTURAL (o que motivou este teste):
--   Duas RPCs (fn_aprovar_staging e fn_reconciliar_competencia) estavam
--   quebradas desde a criação — e a bateria passava, porque nenhum teste
--   exercitava o CAMINHO FELIZ delas. A regra agora é:
--
--   1. TODA função de produção do schema public precisa de um CASO aqui:
--      um caminho feliz e uma negação. Função nova sem caso => BUILD QUEBRA.
--   2. O caminho feliz precisa EXECUTAR de verdade (a prova é o resultado da
--      chamada, e a contraprova é a estatística do Postgres).
--   3. A negação precisa devolver o MESMO erro de permissão (42501) — ou,
--      nas funções de leitura que não têm "negação por erro", o resultado
--      vazio/false esperado.
--
-- COMO A "PROVA DE EXECUÇÃO" FUNCIONA:
--   O runner liga `track_functions = 'all'` (ALTER SYSTEM, no superuser
--   local supabase_admin) ANTES da bateria e zera os contadores. Depois da
--   bateria, este arquivo confere `pg_stat_user_functions`:
--
--   ⚠️ LIMITACOES CONHECIDAS DO PGSTAT (medidas em 13/11/2026):
--     • uma chamada que termina em ERRO NÃO entra em pg_stat_user_functions
--       (só as bem-sucedidas são contadas);
--     • uma transação que ABORTA descarta as estatísticas pendentes — por
--       isso os blocos deste arquivo são separados: o que prova a execução
--       COMMITA antes do bloco que pode levantar a exceção final.
--   Por isso:
--     • a prova de "executou com sucesso" vem das stats (calls > 0);
--     • a prova de "executou com negação" vem do SQLSTATE capturado aqui.
--   Se `track_functions` estiver desligado, a prova de execução não existe —
--   e o teste FALHA (não passa em silêncio).
--
-- LISTA DE APOIO (funções fora da exigência, explicitamente):
--   • test_* — helpers criados pela 00_preparacao;
--   • fn_log_escrita — TRIGGER genérico de log (não é chamada diretamente);
--   • fn_purgar_acesso_log — manutenção, só `postgres` executa;
--   • fn_revogar_funcoes_publicas, fn_revogar_sequencias_publicas,
--     fn_revogar_tabelas_publicas, fn_revogar_objetos_futuros — helpers de
--     migration (só `postgres` executa).
--
-- Este arquivo roda DEPOIS da bateria completa (runner), como postgres, e
-- não depende de pgtap nem de 00_preparacao.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Bloco A — tabelas temporárias de caso e de resultado
-- ----------------------------------------------------------------------------
drop table if exists cobertura_casos;
drop table if exists cobertura_resultado;

create temporary table cobertura_casos (
    fnome             text primary key,
    sql_sucesso       text not null,
    esperado_sucesso  text not null default 'sem_erro',
    sql_negacao       text,
    tipo_negacao      text not null default 'erro',   -- 'erro' | 'valor' | 'sem'
    esperado_negacao  text,
    usuario_negacao   text not null default 'leitor'  -- 'leitor' | 'sem_vinculo'
);

create temporary table cobertura_resultado (
    ordem       serial primary key,
    verificacao text not null,
    resultado   text not null,
    detalhe     text not null default ''
);

insert into cobertura_casos values
-- Helpers de papel e identidade
('fn_usuario_atual',
 'select public.fn_usuario_atual()', 'sem_erro',
 null, 'sem', null, 'leitor'),

('fn_papeis_do_usuario',
 'select public.fn_papeis_do_usuario(''11111111-1111-1111-1111-111111111111'')', 'sem_erro',
 'select count(*) from public.fn_papeis_do_usuario(''11111111-1111-1111-1111-111111111111'')',
 'valor', '0', 'sem_vinculo'),

('fn_condominios_do_usuario',
 'select public.fn_condominios_do_usuario()', 'sem_erro',
 'select count(*) from public.fn_condominios_do_usuario()',
 'valor', '0', 'sem_vinculo'),

('fn_e_membro',
 'select public.fn_e_membro(''11111111-1111-1111-1111-111111111111'', ''auditor'')', 'true',
 'select public.fn_e_membro(''11111111-1111-1111-1111-111111111111'', ''auditor'')',
 'valor', 'false', 'leitor'),

('fn_acessa_condominio',
 'select public.fn_acessa_condominio(''11111111-1111-1111-1111-111111111111'')', 'true',
 'select public.fn_acessa_condominio(''99999999-9999-9999-9999-999999999999'')',
 'valor', 'false', 'leitor'),

-- Leitura agregada
('fn_resumo',
 'select public.fn_resumo(''11111111-1111-1111-1111-111111111111'', null, ''fundo'')', 'sem_erro',
 'select public.fn_resumo(''11111111-1111-1111-1111-111111111111'', null, ''unidade'')',
 'erro', '42501', 'leitor'),

('fn_lancamentos',
 'select public.fn_lancamentos(''11111111-1111-1111-1111-111111111111'', null, null, null, 10, 0)', 'sem_erro',
 'select public.fn_lancamentos(''11111111-1111-1111-1111-111111111111'', null, null, null, 10, 0)',
 'erro', '42501', 'leitor'),

-- Operação do auditor
-- ⚠️ os ids são SEMPRE filtrados pelo condominio A: o fixture do B tambem
-- tem lancamentos e competencia, e o auditor do A NAO tem papel no B
-- (a recusa 42501 seria correta, mas nao seria o caso de sucesso do A).
('fn_aprovar_staging',
 'select public.fn_aprovar_staging((select i.id from public.importacoes i join public.fontes_importacao f on f.id = i.fonte_id where f.condominio_id = ''11111111-1111-1111-1111-111111111111'' limit 1), array[]::uuid[], ''{}''::jsonb)', 'sem_erro',
 'select public.fn_aprovar_staging((select i.id from public.importacoes i join public.fontes_importacao f on f.id = i.fonte_id where f.condominio_id = ''11111111-1111-1111-1111-111111111111'' limit 1), array[]::uuid[], ''{}''::jsonb)',
 'erro', '42501', 'leitor'),

('fn_classificar_lancamento',
 'select public.fn_classificar_lancamento((select l.id from public.lancamentos l where l.condominio_id = ''11111111-1111-1111-1111-111111111111'' and l.codigo_conta = ''1002'' order by l.id limit 1), (select r.id from public.rubricas r where r.condominio_id = ''11111111-1111-1111-1111-111111111111'' and r.codigo = ''COTA_CONDOMINIAL'' limit 1))', 'sem_erro',
 'select public.fn_classificar_lancamento((select l.id from public.lancamentos l where l.condominio_id = ''11111111-1111-1111-1111-111111111111'' and l.codigo_conta = ''1002'' order by l.id limit 1), (select r.id from public.rubricas r where r.condominio_id = ''11111111-1111-1111-1111-111111111111'' and r.codigo = ''COTA_CONDOMINIAL'' limit 1))',
 'erro', '42501', 'leitor'),

('fn_decidir_duplicata',
 'select public.fn_decidir_duplicata((select d.id from public.duplicatas_candidatas d where d.condominio_id = ''11111111-1111-1111-1111-111111111111'' limit 1), ''duplicata_confirmada''::public.status_duplicata, null, null)', 'sem_erro',
 'select public.fn_decidir_duplicata((select d.id from public.duplicatas_candidatas d where d.condominio_id = ''11111111-1111-1111-1111-111111111111'' limit 1), ''duplicata_confirmada''::public.status_duplicata, null, null)',
 'erro', '42501', 'leitor'),

('fn_confirmar_transferencia',
 'select public.fn_confirmar_transferencia((select t.id from public.transferencias_internas t where t.condominio_id = ''11111111-1111-1111-1111-111111111111'' limit 1), ''confirmada''::public.status_transferencia, null)', 'sem_erro',
 'select public.fn_confirmar_transferencia((select t.id from public.transferencias_internas t where t.condominio_id = ''11111111-1111-1111-1111-111111111111'' limit 1), ''confirmada''::public.status_transferencia, null)',
 'erro', '42501', 'leitor'),

('fn_reconciliar_competencia',
 'select public.fn_reconciliar_competencia((select c.id from public.competencias c where c.condominio_id = ''11111111-1111-1111-1111-111111111111'' and c.ano = 2026 and c.mes = 10 limit 1))', 'sem_erro',
 'select public.fn_reconciliar_competencia((select c.id from public.competencias c where c.condominio_id = ''11111111-1111-1111-1111-111111111111'' and c.ano = 2026 and c.mes = 10 limit 1))',
 'erro', '42501', 'leitor'),

('fn_registrar_pendencia',
 'select public.fn_registrar_pendencia(''11111111-1111-1111-1111-111111111111'', ''classificacao''::public.tipo_pendencia, ''manual''::public.origem_pendencia, ''media''::public.gravidade_pendencia, ''COBERTURA'', ''COBERTURA'')', 'sem_erro',
 'select public.fn_registrar_pendencia(''11111111-1111-1111-1111-111111111111'', ''classificacao''::public.tipo_pendencia, ''manual''::public.origem_pendencia, ''media''::public.gravidade_pendencia, ''COBERTURA'', ''COBERTURA'')',
 'erro', '42501', 'leitor'),

-- Contestações
('fn_contestar_lancamento',
 'select public.fn_contestar_lancamento((select l.id from public.lancamentos l where l.condominio_id = ''11111111-1111-1111-1111-111111111111'' and l.codigo_conta = ''1002'' order by l.id limit 1), ''COBERTURA'')', 'sem_erro',
 'select public.fn_contestar_lancamento((select l.id from public.lancamentos l where l.condominio_id = ''11111111-1111-1111-1111-111111111111'' and l.codigo_conta = ''1002'' order by l.id limit 1), ''COBERTURA'')',
 'erro', '42501', 'leitor'),

('fn_responder_contestacao',
 'select public.fn_responder_contestacao((select t.id from public.contestacoes t where t.condominio_id = ''11111111-1111-1111-1111-111111111111'' order by t.id limit 1), ''COBERTURA'', ''acolhida''::public.status_contestacao)', 'sem_erro',
 'select public.fn_responder_contestacao((select t.id from public.contestacoes t where t.condominio_id = ''11111111-1111-1111-1111-111111111111'' order by t.id limit 1), ''COBERTURA'', ''acolhida''::public.status_contestacao)',
 'erro', '42501', 'leitor'),

-- Anexos
('fn_anexo_acessivel',
 'select public.fn_anexo_acessivel((select a.caminho from public.anexos a where a.condominio_id = ''11111111-1111-1111-1111-111111111111'' order by a.id limit 1))', 'true',
 'select public.fn_anexo_acessivel((select a.caminho from public.anexos a where a.condominio_id = ''11111111-1111-1111-1111-111111111111'' and a.liberado_para_leitor = false order by a.id limit 1))',
 'valor', 'false', 'leitor'),

('fn_liberar_anexo_para_leitor',
 'select public.fn_liberar_anexo_para_leitor((select a.id from public.anexos a where a.condominio_id = ''11111111-1111-1111-1111-111111111111'' order by a.id limit 1), false)', 'sem_erro',
 'select public.fn_liberar_anexo_para_leitor((select a.id from public.anexos a where a.condominio_id = ''11111111-1111-1111-1111-111111111111'' order by a.id limit 1), false)',
 'erro', '42501', 'leitor'),

('fn_gerar_url_anexo',
 'select public.fn_gerar_url_anexo((select a.id from public.anexos a where a.condominio_id = ''11111111-1111-1111-1111-111111111111'' order by a.id limit 1))', 'sem_erro',
 'select public.fn_gerar_url_anexo((select a.id from public.anexos a where a.condominio_id = ''11111111-1111-1111-1111-111111111111'' and a.liberado_para_leitor = false order by a.id limit 1))',
 'erro', '42501', 'leitor'),

-- Política de visibilidade
('fn_atualizar_visibilidade',
 'select public.fn_atualizar_visibilidade(''11111111-1111-1111-1111-111111111111'', ''auditor''::public.papel_membro, ''unidade'', 0)', 'sem_erro',
 'select public.fn_atualizar_visibilidade(''11111111-1111-1111-1111-111111111111'', ''leitor''::public.papel_membro, ''fundo'', 5)',
 'erro', '42501', 'leitor'),

-- Logs
('fn_auditoria_log',
 'select public.fn_auditoria_log(''11111111-1111-1111-1111-111111111111'', null, null, 5)', 'sem_erro',
 'select public.fn_auditoria_log(''11111111-1111-1111-1111-111111111111'', null, null, 5)',
 'erro', '42501', 'leitor'),

('fn_acesso_log',
 'select public.fn_acesso_log(''11111111-1111-1111-1111-111111111111'', null, 5)', 'sem_erro',
 'select public.fn_acesso_log(''11111111-1111-1111-1111-111111111111'', null, 5)',
 'erro', '42501', 'leitor');

-- ----------------------------------------------------------------------------
-- Bloco B — nenhuma função de produção pode ficar SEM CASO
-- ----------------------------------------------------------------------------
do $$
declare
    v_faltando text;
begin
    select string_agg(p.proname || '/' || p.pronargs, ', ' order by p.proname)
      into v_faltando
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       -- lista de APOIO (explicita)
       and p.proname not like 'test\_%'
       and p.proname not in ('fn_revogar_funcoes_publicas',
                             'fn_revogar_sequencias_publicas',
                             'fn_revogar_tabelas_publicas',
                             'fn_revogar_objetos_futuros',
                             'fn_log_escrita',
                             'fn_purgar_acesso_log')
       and not exists (
            select 1 from cobertura_casos c where c.fnome = p.proname
       );

    if v_faltando is not null then
        insert into cobertura_resultado (verificacao, resultado, detalhe)
        values ('todas as funcoes de producao tem caso', 'FALHA',
                format('funcao(oes) sem caso de cobertura: %s', v_faltando));
    else
        insert into cobertura_resultado (verificacao, resultado)
        values ('todas as funcoes de producao tem caso', 'ok');
        raise notice 'OK: todas as funcoes de producao tem caso de cobertura';
    end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- Bloco C — executa os casos (caminho feliz e negação)
-- ----------------------------------------------------------------------------
-- Este bloco COMMITTA ao final (é o que publica as estatísticas do
-- pg_stat_user_functions). Por isso ele NÃO levanta exceção: o veredito é
-- dado no Bloco D.
do $$
declare
    r          record;
    v_res      text;
    v_erro     text;
    v_auditor  uuid;
    v_leitor   uuid;
    v_sem      uuid;
    v_tracking text;
begin
    select id into v_auditor from auth.users where email = 'auditor@condA.test';
    select id into v_leitor  from auth.users where email = 'leitor@condA.test';
    select id into v_sem     from auth.users where email = 'sempapel@test.test';

    if v_auditor is null or v_leitor is null or v_sem is null then
        insert into cobertura_resultado (verificacao, resultado, detalhe)
        values ('usuarios de teste', 'FALHA', 'rode a bateria antes deste teste');
        return;
    end if;

    -- O tracking precisa estar LIGADO: sem ele não existe prova de execução.
    v_tracking := current_setting('track_functions', true);
    if v_tracking <> 'all' then
        insert into cobertura_resultado (verificacao, resultado, detalhe)
        values ('track_functions ligado', 'FALHA',
                format('track_functions = %s (esperado ''all'')', coalesce(v_tracking, '(null)')));
        return;
    end if;
    insert into cobertura_resultado (verificacao, resultado)
    values ('track_functions ligado', 'ok');
    raise notice 'OK: track_functions ligado';

    for r in select * from cobertura_casos order by fnome loop
        ------------------------------------------------------------------
        -- CASO DE SUCESSO (como auditor)
        ------------------------------------------------------------------
        perform set_config('request.jwt.claim.sub', v_auditor::text, false);
        perform set_config('request.jwt.claims.role', 'authenticated', false);

        v_res  := null;
        v_erro := null;
        begin
            execute r.sql_sucesso into v_res;
        exception when others then
            v_erro := sqlstate;
        end;

        if v_erro is not null then
            insert into cobertura_resultado (verificacao, resultado, detalhe)
            values (format('[%s] caminho feliz', r.fnome), 'FALHA',
                    format('erro %s em: %s', v_erro, r.sql_sucesso));
        elsif r.esperado_sucesso <> 'sem_erro'
              and coalesce(v_res, '(null)') <> r.esperado_sucesso then
            insert into cobertura_resultado (verificacao, resultado, detalhe)
            values (format('[%s] caminho feliz', r.fnome), 'FALHA',
                    format('devolveu %s (esperado %s)',
                           coalesce(v_res, '(null)'), r.esperado_sucesso));
        else
            insert into cobertura_resultado (verificacao, resultado)
            values (format('[%s] caminho feliz', r.fnome), 'ok');
            raise notice 'OK: [%] caminho feliz', r.fnome;
        end if;

        ------------------------------------------------------------------
        -- CASO DE NEGAÇÃO (leitor — ou sem vínculo, quando a função não tem
        -- permissão negativa mas precisa devolver vazio)
        ------------------------------------------------------------------
        if r.tipo_negacao <> 'sem' then
            if r.usuario_negacao = 'sem_vinculo' then
                perform set_config('request.jwt.claim.sub', v_sem::text, false);
            else
                perform set_config('request.jwt.claim.sub', v_leitor::text, false);
            end if;
            perform set_config('request.jwt.claims.role', 'authenticated', false);

            v_res  := null;
            v_erro := null;
            begin
                execute r.sql_negacao into v_res;
            exception when others then
                v_erro := sqlstate;
            end;

            if r.tipo_negacao = 'erro' then
                if v_erro is distinct from r.esperado_negacao then
                    insert into cobertura_resultado (verificacao, resultado, detalhe)
                    values (format('[%s] negacao', r.fnome), 'FALHA',
                            format('devolveu %s (esperado %s)',
                                   coalesce(v_erro, 'sem erro'), r.esperado_negacao));
                else
                    insert into cobertura_resultado (verificacao, resultado)
                    values (format('[%s] negacao', r.fnome), 'ok');
                    raise notice 'OK: [%] negacao', r.fnome;
                end if;
            else  -- 'valor'
                if coalesce(v_res, '(null)') <> r.esperado_negacao then
                    insert into cobertura_resultado (verificacao, resultado, detalhe)
                    values (format('[%s] negacao', r.fnome), 'FALHA',
                            format('devolveu %s (esperado %s)',
                                   coalesce(v_res, '(null)'), r.esperado_negacao));
                else
                    insert into cobertura_resultado (verificacao, resultado)
                    values (format('[%s] negacao', r.fnome), 'ok');
                    raise notice 'OK: [%] negacao', r.fnome;
                end if;
            end if;
        end if;
    end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Bloco E — limpeza: os casos de sucesso gravaram (classificação, duplicata,
-- contestação, pendência, logs). O banco volta ao estado pós-bateria.
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regprocedure('public.test_limpar_dados()') is not null then
        perform public.test_limpar_dados();
        perform public.test_criar_fixture_cond_b();
        perform public.test_criar_lancamentos_fixture();
        if to_regprocedure('public.test_criar_fixture_matriz()') is not null then
            perform public.test_criar_fixture_matriz();
        end if;
        raise notice 'OK: residuos da cobertura removidos (fixtures recriadas)';
    else
        raise notice 'OK: helpers de teste ausentes — nada a limpar';
    end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- Bloco D — PROVA DE EXECUÇÃO (pg_stat_user_functions) e VEREDITO
-- ----------------------------------------------------------------------------
do $$
declare
    v_qtd    int;
    v_lista  text;
    v_falhas text;
begin
    -- O back-end publica as estatísticas com alguns milissegundos de atraso;
    -- sem a espera, a consulta pode ver calls = 0.
    perform pg_sleep(1.5);

    select count(*)::int,
           coalesce(string_agg(format('%s (calls=%s)', c.fnome, coalesce(s.calls, 0)), ', '), '')
      into v_qtd, v_lista
      from cobertura_casos c
      left join pg_stat_user_functions s
             on s.funcid = (
                select p.oid from pg_proc p
                 join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = c.fnome
                order by p.oid limit 1
             )
     where c.tipo_negacao = 'erro'   -- quem tem caso de negacao por excecao
       and coalesce(s.calls, 0) = 0;

    if v_qtd > 0 then
        insert into cobertura_resultado (verificacao, resultado, detalhe)
        values ('execucao registrada no pg_stat', 'FALHA',
                format('funcao(oes) SEM execucao registrada: %s', v_lista));
    else
        insert into cobertura_resultado (verificacao, resultado)
        values ('execucao registrada no pg_stat', 'ok');
        raise notice 'OK: execucao registrada no pg_stat';
    end if;

    -- VEREDITO: a lista completa do que deu errado (não só o primeiro).
    select coalesce(string_agg(
               format('  - %s: %s', verificacao, detalhe), E'\n'), '')
      into v_falhas
      from cobertura_resultado
     where resultado = 'FALHA';

    if v_falhas is not null and v_falhas <> '' then
        raise exception 'COBERTURA DE FUNCOES FALHOU:%', v_falhas;
    end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- RESULTADO (para leitura humana)
-- ----------------------------------------------------------------------------
select ordem, verificacao, resultado, detalhe
  from cobertura_resultado
 order by ordem;
