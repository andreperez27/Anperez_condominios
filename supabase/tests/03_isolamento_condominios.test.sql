-- ============================================================================
-- TESTES DE SEGURANÇA — T24 a T30: ISOLAMENTO ENTRE CONDOMÍNIOS
-- ============================================================================
-- Nada vaza entre condomínios: nem agregado, nem detalhe, nem função.
--
-- Este é o teste que garante a natureza MULTI-TENANT do modelo.
-- ============================================================================

begin;
select extensions.plan(8);

select public.test_limpar_dados();
select public.test_criar_lancamentos_fixture();

-- ----------------------------------------------------------------------------
-- Leitor do condomínio A
-- ----------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

-- T24: o leitor do A vê agregados do A
select extensions.is(
    (select count(*)::int
       from public.v_resumo_competencia_fundo
      where condominio_id = public.test_cond_a()),
    2,
    'T24 leitor do A ve os 2 fundos que tem lancamento no A'
);

-- T25: o leitor do A NÃO vê agregados do B
select extensions.is(
    (select count(*)::int
       from public.v_resumo_competencia_fundo
      where condominio_id = public.test_cond_b()),
    0,
    'T25 leitor do A nao ve agregados do B'
);

-- T26: o leitor do A não pode pedir o condomínio B na função
select extensions.throws_ok(
    $fn$select public.fn_resumo(public.test_cond_b(), null, 'fundo')$fn$,
    '42501', null,
    'T26 leitor do A nao le agregados do B pela funcao'
);

-- T27: o leitor do A não pode pedir o detalhe do B
select extensions.throws_ok(
    $fn$select public.fn_lancamentos(public.test_cond_b(), null, null, null, 100, 0)$fn$,
    '42501', null,
    'T27 leitor do A nao le detalhe do B pela funcao'
);

reset role;

-- ----------------------------------------------------------------------------
-- Leitor do condomínio B
-- ----------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condB.test');

-- T28: o leitor do B não vê nenhum lançamento do A
select extensions.is(
    (select count(*)::int
       from public.v_resumo_competencia_fundo
      where condominio_id = public.test_cond_a()),
    0,
    'T28 leitor do B nao ve dados do A'
);

-- T29: o leitor do B não acessa o condomínio A
select extensions.throws_ok(
    $fn$select public.fn_resumo(public.test_cond_a(), null, 'fundo')$fn$,
    '42501', null,
    'T29 leitor do B nao acessa o condominio A'
);

reset role;

-- ----------------------------------------------------------------------------
-- Usuário autenticado SEM nenhum vínculo
-- ----------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('sempapel@test.test');

-- T30: sem vínculo, não vê nada nem por view
select extensions.is(
    (select count(*)::int from public.v_resumo_competencia_fundo),
    0,
    'T30 usuario sem vinculo nao ve nenhum agregado'
);

reset role;
select * from finish();
rollback;
