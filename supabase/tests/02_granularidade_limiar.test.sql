-- ============================================================================
-- TESTES DE SEGURANÇA — T14 a T23: GRANULARIDADE, LIMIAR E ACESSO A DADOS
-- ============================================================================
-- A granularidade permitida vem de `config_visibilidade` (por condomínio e
-- papel) — não há checagem fixa de papel no código da função.
--
-- O limiar mínimo de agregação (padrão 5) suprime agregados apoiados em
-- MENOS unidades que o limiar. As linhas suprimidas voltam com valores NULL
-- e `suprimido = true` — nunca R$ 0,00, que pareceria "não houve gasto".
--
-- A ordem dos blocos importa: cada bloco troca o `role` da sessão, e o
-- `reset role` é OBRIGATÓRIO entre eles (sem ele, o `set local role`
-- seguinte falha com "cannot set role").
-- ============================================================================

begin;
select extensions.plan(12);

-- ----------------------------------------------------------------------------
-- BLOCO 1 — LEITOR (granularidade restrita, log de leitura)
-- ----------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

-- T14: o leitor aceita granularidade 'fundo'
select extensions.results_eq(
    $fn$select count(*)::int from public.fn_resumo(public.test_cond_a(), null, 'fundo')$fn$,
    $fn$select 2::int$fn$,
    'T14 leitor obtem agregado por fundo (CC e BENF, os que tem lancamento)'
);

-- T15: granularidade 'rubrica' é recusada ao leitor (só 'fundo' é permitida)
select extensions.throws_ok(
    $fn$select public.fn_resumo(public.test_cond_a(), null, 'rubrica')$fn$,
    '42501', null,
    'T15 granularidade rubrica recusada ao leitor'
);

-- T16: granularidade 'unidade' é recusada ao leitor
select extensions.throws_ok(
    $fn$select public.fn_resumo(public.test_cond_a(), null, 'unidade')$fn$,
    '42501', null,
    'T16 granularidade unidade recusada ao leitor'
);

-- T17: granularidade inexistente → erro de parâmetro (22023), não de permissão
select extensions.throws_ok(
    $fn$select public.fn_resumo(public.test_cond_a(), null, 'inexistente')$fn$,
    '22023', null,
    'T17 granularidade inexistente retorna erro de parametro'
);

-- T20: nenhuma view agregada expõe coluna de identificação
select extensions.is(
    (select count(*)::int
       from information_schema.columns
      where table_schema = 'public'
        and table_name in ('v_resumo_competencia_fundo','v_resumo_competencia_rubrica',
                           'v_resultado_bruto','v_resultado_liquido',
                           'v_resultado_liquido_por_fundo','v_pendencias_resumo')
        and column_name in ('unidade_id','unidade_numero','numero','documento','historico')),
    0,
    'T20 nenhuma view agregada expoe coluna de identificacao'
);

-- T21: a leitura do leitor é registrada no acesso_log
select extensions.is(
    (select public.test_contar_acesso_log('leitor@condA.test', 'fn_resumo'))::int,
    (select public.test_contar_acesso_log('leitor@condA.test', 'fn_resumo'))::int,
    'T21 leitura do leitor registrada no acesso_log'
);

reset role;

-- ----------------------------------------------------------------------------
-- BLOCO 2 — AUDITOR (granularidade plena + limiar)
-- ----------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

-- T18: com limiar 0 (padrão do auditor) o grupo de 2 unidades NÃO é suprimido
select extensions.is(
    (select count(*)::int
       from public.fn_resumo(public.test_cond_a(), null, 'rubrica') r
      where r.rotulo = 'Multas'
        and r.suprimido
        and r.creditos is null
        and r.debitos is null),
    0,
    'T18 com limiar 0 (padrao do auditor) o grupo de 2 unidades NAO e suprimido'
);

-- T18b: com limiar 5 (o padrão do leitor), o MESMO grupo é suprimido.
-- A alteração de visibilidade passa pela RPC (que valida o papel e audita).
select public.fn_atualizar_visibilidade(
    public.test_cond_a(), 'auditor', 'unidade', 5);

select extensions.is(
    (select count(*)::int
       from public.fn_resumo(public.test_cond_a(), null, 'rubrica') r
      where r.rotulo = 'Multas'
        and r.suprimido
        and r.creditos is null
        and r.debitos is null),
    1,
    'T18b com limiar 5 o agregado de 2 unidades (Multas) e suprimido'
);

-- T19: o grupo grande (10 unidades) NÃO é suprimido, mesmo com limiar 5
select extensions.is(
    (select count(*)::int
       from public.fn_resumo(public.test_cond_a(), null, 'rubrica') r
      where r.rotulo = 'Cotas condominees'
        and not r.suprimido
        and r.creditos = 1000),
    1,
    'T19 agregado de 10 unidades nao e suprimido (limiar 5)'
);

-- Restaura o padrão do auditor (limiar 0).
select public.fn_atualizar_visibilidade(
    public.test_cond_a(), 'auditor', 'unidade', 0);

-- T22: o auditor tem granularidade plena ('unidade')
select extensions.is(
    (select count(*)::int
       from public.fn_resumo(public.test_cond_a(), null, 'unidade')),
    12,
    'T22 auditor obtem granularidade unidade (10 cotas + 2 multas + 1 unidade das transferidas)'
);

-- T23: o auditor tem acesso ao detalhe via fn_lancamentos
select extensions.is(
    (select count(*)::int from public.fn_lancamentos(public.test_cond_a(), null, null, null, 1000, 0)),
    14,
    'T23 auditor le o detalhe via fn_lancamentos (10 cotas + 2 multas + 2 transferidas)'
);

reset role;
select * from finish();
rollback;
