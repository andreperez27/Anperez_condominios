-- ============================================================================
-- TESTES DE SEGURANÇA — T01 a T12: LEITOR x TABELA DE DETALHE
-- ============================================================================
-- Verificado em 11/11/2026 no ambiente local (Supabase CLI 2.107.0,
-- PostgreSQL 17.6).
--
-- O leitor NÃO tem privilégio de tabela. O `SELECT` é recusado pelo Postgres
-- com "permission denied" ANTES de o RLS ser avaliado — por isso o teste
-- espera EXCEÇÃO, não zero linhas.
-- ============================================================================

begin;
select extensions.plan(14);

-- O leitor existe e tem o papel certo
select extensions.is(
    (select count(*)::int from public.membros m
       join auth.users u on u.id = m.perfil_id
      where u.email = 'leitor@condA.test'
        and m.papel = 'leitor'
        and m.condominio_id = public.test_cond_a()),
    1, 'leitor do condominio A existe com o papel leitor'
);

-- T01..T06: SELECT direto em tabela de detalhe → permission denied
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select * from public.lancamentos',
    '42501', null,
    'T01 leitor nao faz SELECT em lancamentos'
);

select extensions.throws_ok(
    'select count(*) from public.lancamentos',
    '42501', null,
    'T02 leitor nao conta lancamentos'
);

select extensions.throws_ok(
    'select * from public.unidades',
    '42501', null,
    'T03 leitor nao faz SELECT em unidades'
);

select extensions.throws_ok(
    'select * from public.pendencias',
    '42501', null,
    'T04 leitor nao faz SELECT em pendencias'
);

select extensions.throws_ok(
    'select * from public.duplicatas_candidatas',
    '42501', null,
    'T05 leitor nao faz SELECT em duplicatas_candidatas'
);

select extensions.throws_ok(
    'select * from public.acesso_log',
    '42501', null,
    'T06 leitor nao faz SELECT em acesso_log'
);

-- T07/T08: escrita direta → permission denied
select extensions.throws_ok(
    'insert into public.lancamentos (condominio_id, competencia_id, fundo_id, data_lancamento, valor, tipo_movimento, historico, codigo_conta, descricao_conta, fonte_id, hash_arquivo, arquivo_nome, linha_origem, chave_natural) values (public.test_cond_a(), gen_random_uuid(), gen_random_uuid(), current_date, 1, ''credito'', ''x'', ''1002'', ''x'', gen_random_uuid(), ''h'', ''a'', 1, ''k'')',
    '42501', null,
    'T07 leitor nao insere lancamento'
);

select extensions.throws_ok(
    'update public.lancamentos set valor = 0',
    '42501', null,
    'T08 leitor nao atualiza lancamento'
);

reset role;

-- T09..T13: funcao privilegiada → excecao 42501 (papel insuficiente)
--
-- Os ids usados abaixo sao de registros REAIS do condominio A, capturados
-- ANTES do `set local role` (as tabelas de detalhe nao sao legiveis por
-- esse role). Usar gen_random_uuid() daria P0002 (registro inexistente)
-- em vez de 42501 (sem permissao) — o teste mediria outra coisa.
select set_config(
    'test.lancamento_id',
    (select l.id::text
       from public.lancamentos l
      where l.condominio_id = public.test_cond_a()
      order by l.id
      limit 1),
    true);

select set_config(
    'test.duplicata_id',
    (select d.id::text
       from public.duplicatas_candidatas d
      where d.condominio_id = public.test_cond_a()
      order by d.id
      limit 1),
    true);

select set_config(
    'test.anexo_id',
    (select a.id::text
       from public.anexos a
      where a.condominio_id = public.test_cond_a()
      order by a.id
      limit 1),
    true);

select set_config(
    'test.rubrica_id',
    (select r.id::text
       from public.rubricas r
      where r.condominio_id = public.test_cond_a()
      order by r.id
      limit 1),
    true);

-- Id de uma importacao REAL do condominio A, capturado ANTES do
-- `set local role` (as tabelas operacionais nao sao legiveis por esse
-- role). Sem isso, fn_aprovar_staging erroaria P0002 (inexistente)
-- em vez de 42501 (sem permissao) — o teste mediria outra coisa.
select set_config(
    'test.importacao_id',
    (select i.id::text
       from public.importacoes i
       join public.fontes_importacao f on f.id = i.fonte_id
      where f.condominio_id = public.test_cond_a()
      order by i.id
      limit 1),
    true);

set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_aprovar_staging(current_setting(''test.importacao_id'')::uuid, array[]::uuid[])',
    '42501', null,
    'T09 leitor nao aprova importacao'
);

select extensions.throws_ok(
    'select public.fn_classificar_lancamento(current_setting(''test.lancamento_id'')::uuid, current_setting(''test.rubrica_id'')::uuid)',
    '42501', null,
    'T10 leitor nao classifica lancamento'
);

select extensions.throws_ok(
    'select public.fn_decidir_duplicata(current_setting(''test.duplicata_id'')::uuid, ''duplicata_confirmada'')',
    '42501', null,
    'T11 leitor nao decide duplicata'
);

select extensions.throws_ok(
    'select public.fn_contestar_lancamento(current_setting(''test.lancamento_id'')::uuid, ''texto'')',
    '42501', null,
    'T12 leitor nao contesta lancamento'
);

select extensions.throws_ok(
    'select public.fn_liberar_anexo_para_leitor(current_setting(''test.anexo_id'')::uuid, true)',
    '42501', null,
    'T13 leitor nao libera anexo'
);

reset role;
select * from finish();
rollback;
