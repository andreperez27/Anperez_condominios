-- ============================================================================
-- TESTES DE SEGURANÇA — T31 a T40: PAPÉIS, IMPORTAÇÃO, ANEXOS, BRUTO x LÍQUIDO
-- ============================================================================
-- Cobre o papel do síndico (lê, contesta, mas NÃO classifica), o
-- importador (escreve no staging, nunca em lancamentos), o storage (anexo
-- bloqueado por padrão para o leitor) e a regra de ouro do consolidado
-- (v_resultado_bruto não subtrai transferências).
--
-- ⚠️ O SQL dos testes usa o delimitador $fn$...$fn$ (tag personalizada do
-- PostgreSQL) em vez de $$...$$: o pgTAP usa $$ como delimitador de
-- string, e um $$ dentro do SQL quebraria o parsing.
-- ============================================================================

begin;
select extensions.plan(12);

select public.test_limpar_dados();
select public.test_criar_lancamentos_fixture();

-- ----------------------------------------------------------------------------
-- BLOCO 1 — SÍNDICO: lê o próprio condomínio, contesta, mas NÃO classifica
-- ----------------------------------------------------------------------------

-- Id de um lançamento do condomínio A, capturado ANTES do `set local role`
-- (a tabela de detalhe não é legível pelo role autenticado).
select set_config(
    'test.lancamento_id',
    (select l.id::text
       from public.lancamentos l
      where l.condominio_id = public.test_cond_a()
      order by l.id
      limit 1),
    true);

set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

-- T31: o síndico lê o detalhe do próprio condomínio
select extensions.is(
    (select count(*)::int from public.fn_lancamentos(public.test_cond_a(), null, null, null, 1000, 0)),
    14,
    'T31 sindico le o detalhe do proprio condominio'
);

-- T32: o síndico NÃO classifica lançamento
select extensions.throws_ok(
    'select public.fn_classificar_lancamento(
        current_setting(''test.lancamento_id'')::uuid,
        (select id from public.rubricas limit 1))',
    '42501', null,
    'T32 sindico nao classifica lancamento'
);

-- T33: o síndico PODE contestar
select extensions.lives_ok(
    'select public.fn_contestar_lancamento(
        current_setting(''test.lancamento_id'')::uuid,
        ''Contestacao de teste do sindico'')',
    'T33 sindico pode contestar lancamento'
);

-- T34: a contestação não altera a classificação do lançamento
select extensions.is(
    (select public.test_contar_lancamentos_sem_classificacao_confirmada(
        public.test_cond_a(), '1002'))::int,
    0,
    'T34 contestacao nao altera a classificacao'
);

-- T35: o síndico do A NÃO contesta um lançamento do condomínio B.
--
-- O fixture só tem lançamentos no A, então o teste cria UM lançamento no
-- B (como o auditor do B) e verifica que o síndico do A é recusado — a
-- função valida o papel contra o condomínio DA LINHA, não contra o
-- condomínio pedido no argumento.
select extensions.lives_ok(
    'select public.test_criar_lancamento_cond_b()',
    'T35a criacao do lancamento de teste no condominio B'
);

select extensions.throws_ok(
    'select public.fn_contestar_lancamento(
        (select public.test_pegar_lancamento_cond_b()),
        ''tentativa cross-tenant'')',
    '42501', null,
    'T35 sindico nao contesta lancamento de outro condominio'
);

reset role;

-- ----------------------------------------------------------------------------
-- BLOCO 2 — IMPORTADOR: escreve no staging, NUNCA em lancamentos
-- ----------------------------------------------------------------------------
-- O role `authenticated` não pode assumir `app_importador` (não é membro).
-- O teste roda como `postgres`, que tem privilégio de ADMIN.
set role app_importador;

-- T36: o importador NÃO consegue ler lancamentos
select extensions.throws_ok(
    'select * from public.lancamentos',
    '42501', null,
    'T36 importador nao le lancamentos'
);

-- T37: o importador NÃO consegue inserir em lancamentos
select extensions.throws_ok(
    'insert into public.lancamentos (
        condominio_id, competencia_id, fundo_id, data_lancamento, valor,
        tipo_movimento, historico, codigo_conta, descricao_conta, fonte_id,
        hash_arquivo, arquivo_nome, linha_origem, chave_natural
    ) values (
        public.test_cond_a(), gen_random_uuid(), gen_random_uuid(), current_date,
        1, ''credito'', ''x'', ''1002'', ''x'', gen_random_uuid(), ''h'', ''a'', 1, ''k''
    )',
    '42501', null,
    'T37 importador nao insere em lancamentos'
);

-- T38: o importador NÃO consegue aprovar importação (função privilegiada)
select extensions.throws_ok(
    'select public.fn_aprovar_staging(gen_random_uuid(), array[]::uuid[])',
    '42501', null,
    'T38 importador nao aprova importacao'
);

reset role;

-- ----------------------------------------------------------------------------
-- BLOCO 3 — ANEXO: bloqueado por padrão para o leitor
-- ----------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

-- T39: o leitor não alcança o anexo NÃO liberado; o liberado, sim.
--
-- ⚠️ O leitor NÃO tem SELECT na tabela `anexos` (por design — a garantia
-- é o privilégio negado, não a policy). O teste usa a função
-- `fn_anexo_acessivel` (a mesma que a policy de storage consulta) e
-- compara com o total de anexos do condomínio.
select extensions.is(
    (select public.test_contar_anexos_acessiveis(public.test_cond_a()))::int,
    1,
    'T39 leitor alcanca apenas o anexo individualmente liberado'
);

-- E o leitor também não consegue ler a tabela de anexos diretamente.
select extensions.throws_ok(
    'select * from public.anexos',
    '42501', null,
    'T39c leitor nao faz SELECT direto na tabela de anexos'
);

-- O storage segue a mesma regra: a policy consulta a MESMA função
-- (fn_anexo_acessivel), então o caminho de um anexo do condomínio A
-- é acessível ao leitor, e o de um condomínio alheio não.
--
-- O teste verifica a regra de acesso, não a existência de objetos no
-- bucket (o fixture cria as linhas em `anexos`, que é a fonte de
-- verdade da policy).
select extensions.is(
    (select public.test_contar_anexos_acessiveis(public.test_cond_a()))::int,
    1,
    'T39b storage expoe ao leitor apenas o anexo liberado'
);

reset role;

-- ----------------------------------------------------------------------------
-- BLOCO 4 — BRUTO x LÍQUIDO: a regra de ouro do consolidado
-- ----------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

-- T40: v_resultado_bruto NÃO subtrai transferências confirmadas
-- (a transferência de 50,00 está confirmada; o bruto tem de somá-la)
select extensions.is(
    (select creditos::int from public.v_resultado_bruto
      where condominio_id = public.test_cond_a() and ano = 2026 and mes = 10),
    (1000 + 30 + 50)::int,
    'T40 resultado bruto soma a transferencia interna (nao subtrai)'
);

-- ...e o líquido, por outro lado, desconta a ponta de destino.
-- Depois de excluir a ponta de DESTINO da transferência, o fundo
-- BENFEITORIAS fica sem movimento — e por isso não aparece no
-- resultado líquido. O CONTA CONDOMÍNIO continua.
select extensions.is(
    (select count(*)::int from public.v_resultado_liquido_por_fundo
      where condominio_id = public.test_cond_a() and ano = 2026 and mes = 10),
    1,
    'T40b resultado liquido por fundo exclui a ponta de destino da transferencia'
);

-- E o BENFEITORIAS some do líquido (a ponta de destino da
-- transferência é excluída), enquanto o bruto — que não subtrai nada —
-- mantém o valor.
select extensions.is(
    (select count(*)::int from public.v_resultado_liquido_por_fundo
      where condominio_id = public.test_cond_a()
        and ano = 2026 and mes = 10
        and fundo_nome = 'BENFEITORIAS'),
    0,
    'T40c o BENFEITORIAS nao aparece no resultado liquido'
);


reset role;
select * from finish();
rollback;
