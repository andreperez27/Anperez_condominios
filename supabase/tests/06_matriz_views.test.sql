-- ============================================================================
-- TESTES DE SEGURANÇA — MATRIZ view x papel (14 views × 6 personas)
-- ============================================================================
-- Dados: fixture completa (00_preparacao → test_criar_lancamentos_fixture +
-- test_criar_fixture_matriz), com 14 lançamentos, 1 transferência confirmada,
-- 1 duplicata candidata, 2 pendências, 2 conciliações, 2 contestações,
-- 2 linhas de série histórica e 1 condomínio B para isolamento.
--
-- Personas no condomínio A: leitor, auditor, síndico, conselho_fiscal.
-- Persona cross-tenant: leitor@condB.test (outro condomínio).
-- Persona sem vínculo: sempapel@test.test (logado, sem papel em lugar nenhum).
--
-- Regra geral das views (migration 01300 + 01800):
--   • agregadas: todo mundo do condomínio lê, com o limiar de
--     config_visibilidade lido DENTRO da view e suprimir células 1..limiar-1;
--   • detalhe com filtro interno por papel: leitor recebe ZERO linhas;
--   • observação (texto livre) só para papel NOMINAL (auditor/síndico/conselho).
-- ============================================================================

begin;
select extensions.plan(55);

-- ---------------------------------------------------------------------------
-- BLOCO 1 — LEITOR (granularidade máxima 'fundo', limiar 5)
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

-- V1/V2/V3: agregados de fundo visíveis; FUNDO CC visível (12 unidades)
select extensions.is(
    (select count(*)::int from public.v_resumo_competencia_fundo
      where condominio_id = public.test_cond_a()),
    2, 'V1 leitor ve os 2 fundos com lancamento');

select extensions.is(
    (select creditos::int from public.v_resumo_competencia_fundo
      where condominio_id = public.test_cond_a() and fundo_nome = 'CONTA CONDOMINIO'),
    1030, 'V2 fundo CC: creditos 1030 (1000 cotas + 30 multas), celular visivel');

select extensions.is(
    (select suprimido from public.v_resumo_competencia_fundo
      where condominio_id = public.test_cond_a() and fundo_nome = 'CONTA CONDOMINIO'),
    false, 'V3 fundo CC nao e suprimido (12 unidades > limiar 5)');

-- V4: o leitor NÃO lê agregados de rubrica (max = fundo) — a célula Multas
-- (2 unidade
select extensions.is(
    (select count(*)::int from public.v_resumo_competencia_rubrica
      where condominio_id = public.test_cond_a()),
    0, 'V4 leitor nao le agregados de rubrica (granularidade_max=fundo)');

-- V5: série histórica por rubrica_alias fica fora do alcance do fundo
select extensions.is(
    (select count(*)::int from public.v_serie_historica
      where condominio_id = public.test_cond_a()),
    0, 'V5 leitor nao le a serie historica por rubrica_alias');

-- V6/V7: observação (texto livre) NÃO chega ao leitor — nem por conciliação,
-- nem por status de competência
select extensions.is(
    (select count(*)::int from public.v_conciliacao
      where condominio_id = public.test_cond_a()
        and observacao is not null),
    0, 'V6 leitor nao recebe observacao de conciliacao');

select extensions.is(
    (select count(*)::int from public.v_cobertura_competencias
      where condominio_id = public.test_cond_a()
        and observacao is not null),
    0, 'V7 leitor nao recebe observacao de status de competencia');

-- V8/V9/V10: as 4 views de DETALHE devolvem zero linhas ao leitor
select extensions.is(
    (select count(*)::int from public.v_transferencias_internas
      where condominio_id = public.test_cond_a()),
    0, 'V8 leitor nao le transferencias internas');

select extensions.is(
    (select count(*)::int from public.v_duplicatas_candidatas
      where condominio_id = public.test_cond_a()),
    0, 'V9 leitor nao le duplicatas candidatas');

select extensions.is(
    (select count(*)::int from public.v_lancamentos_com_duplicata
      where condominio_id = public.test_cond_a()),
    0, 'V10 leitor nao le lancamentos com duplicata');

select extensions.is(
    (select count(*)::int from public.v_contestacoes
      where condominio_id = public.test_cond_a()),
    0, 'V11 leitor nao le contestacoes');

-- V12: v_pendencias_resumo é a CONTAGEM — 2 pendências em 2 grupos, sem detalhe
select extensions.is(
    (select count(*)::int from public.v_pendencias_resumo
      where condominio_id = public.test_cond_a()),
    2, 'V12 leitor recebe 2 linhas de contagem de pendencias');

select extensions.is(
    (select count(*)::int from public.v_pendencias_resumo
      where condominio_id = public.test_cond_a()
        and (tipo is null or gravidade is null or qtd is null or status is null)),
    0, 'V13 cada linha de pendencias traz tipo, gravidade, status e qtd');

-- V14/V15: o bruto soma tudo (inclusive transferência); o resultado bruto do leitor bate com o auditor
select extensions.is(
    (select creditos::int from public.v_resultado_bruto
      where condominio_id = public.test_cond_a() and ano = 2026 and mes = 10),
    1080, 'V14 bruto soma 1080 (1000 cotas + 30 multas + 50 transferencia)');

select extensions.is(
    (select resultado::int from public.v_resultado_bruto
      where condominio_id = public.test_cond_a() and ano = 2026 and mes = 10),
    1030, 'V15 resultado bruto = 1080 - 50 debitos da transferencia');

-- V16: v_importacao_resumo é o agregado operacional — o leitor lê, sem staging
select extensions.is(
    (select qtd_fontes::int from public.v_importacao_resumo
      where condominio_id = public.test_cond_a() and fonte = 'extrato'),
    1, 'V16 leitor le o resumo de importacao (1 fonte, sem detalhe de staging)');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 2 — AUDITOR (granularidade plena, limiar 0)
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

-- V17/V18: rubrica e série visíveis; Multas NÃO suprimido (limiar 0)
select extensions.is(
    (select count(*)::int from public.v_resumo_competencia_rubrica
      where condominio_id = public.test_cond_a()),
    3, 'V17 auditor le as 3 rubricas');

select extensions.is(
    (select creditos::int from public.v_resumo_competencia_rubrica
      where condominio_id = public.test_cond_a() and rubrica_nome = 'Multas'),
    30, 'V18 auditor ve Multas (2 unidades) sem supressao (limiar 0)');

select extensions.is(
    (select count(*)::int from public.v_serie_historica
      where condominio_id = public.test_cond_a()),
    2, 'V19 auditor le a serie historica');

-- V20/V21/V22: as 4 views de DETALHE devolvem as linhas
select extensions.is(
    (select count(*)::int from public.v_transferencias_internas
      where condominio_id = public.test_cond_a()),
    1, 'V20 auditor le a transferencia interna');

select extensions.is(
    (select count(*)::int from public.v_duplicatas_candidatas
      where condominio_id = public.test_cond_a()),
    1, 'V21 auditor le a duplicata candidata');

select extensions.is(
    (select count(*)::int from public.v_lancamentos_com_duplicata
      where condominio_id = public.test_cond_a()),
    14, 'V22 auditor le os 14 lancamentos marcados');

select extensions.is(
    (select count(*)::int from public.v_contestacoes
      where condominio_id = public.test_cond_a()),
    2, 'V23 auditor le as 2 contestacoes');

-- V24/V25: observação visível para papel nominal
select extensions.is(
    (select count(*)::int from public.v_conciliacao
      where condominio_id = public.test_cond_a()
        and observacao like 'OBSERVACAO MATRIZ%'),
    1, 'V24 auditor le a observacao da conciliacao');

select extensions.is(
    (select count(*)::int from public.v_cobertura_competencias
      where condominio_id = public.test_cond_a()
        and observacao like 'OBSERVACAO MATRIZ%'),
    1, 'V25 auditor le a observacao do status de competencia');

-- V26/V27: limiar na view — com limiar 5 temporário, a célula Multas
-- (2 unidades) some; as grandes ficam. O auditor volta a 0 no fim.
select public.fn_atualizar_visibilidade(public.test_cond_a(), 'auditor', 'unidade', 5);

select extensions.is(
    (select (creditos is null and suprimido) from public.v_resumo_competencia_rubrica
      where condominio_id = public.test_cond_a() and rubrica_nome = 'Multas'),
    true, 'V26 com limiar 5, a celula Multas (2 unidades) e suprimida');

select extensions.is(
    (select suprimido from public.v_resumo_competencia_rubrica
      where condominio_id = public.test_cond_a() and rubrica_nome = 'Cotas condominees'),
    false, 'V27 com limiar 5, Cotas (10 unidades) nao e suprimida');

select public.fn_atualizar_visibilidade(public.test_cond_a(), 'auditor', 'unidade', 0);
reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 3 — SÍNDICO (unidade, limiar 1)
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

-- V28..V31: detalhe limitado a contestações/logs próprio papel; 0 nas demais
select extensions.is(
    (select count(*)::int from public.v_transferencias_internas
      where condominio_id = public.test_cond_a()),
    0, 'V28 sindico nao le transferencias internas (view restrita a auditor/conselho)');

select extensions.is(
    (select count(*)::int from public.v_duplicatas_candidatas
      where condominio_id = public.test_cond_a()),
    0, 'V29 sindico nao le duplicatas candidatas');

select extensions.is(
    (select count(*)::int from public.v_lancamentos_com_duplicata
      where condominio_id = public.test_cond_a()),
    0, 'V30 sindico nao le lancamentos com duplicata');

select extensions.is(
    (select count(*)::int from public.v_contestacoes
      where condominio_id = public.test_cond_a()),
    2, 'V31 sindico le as contestacoes');

-- V32/V33: papel nominal — observação visível; rubrica visível (unidade ≥ limiar 1)
select extensions.is(
    (select count(*)::int from public.v_conciliacao
      where condominio_id = public.test_cond_a()
        and observacao is not null),
    1, 'V32 sindico (papel nominal) le a observacao da conciliacao');

select extensions.is(
    (select count(*)::int from public.v_resumo_competencia_rubrica
      where condominio_id = public.test_cond_a()),
    3, 'V33 sindico (unidade, limiar 1) le as rubricas');

-- V34: o agregado do mês é o mesmo do leitor
select extensions.is(
    (select creditos::int from public.v_resultado_bruto
      where condominio_id = public.test_cond_a() and ano = 2026 and mes = 10),
    1080, 'V34 sindico le o mesmo bruto do condominio');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 4 — CONSELHO FISCAL (unidade, limiar 1)
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

-- V35/V36: transferências e contestações SIM (papel fiscal)
select extensions.is(
    (select count(*)::int from public.v_transferencias_internas
      where condominio_id = public.test_cond_a()),
    1, 'V35 conselho le a transferencia interna');

select extensions.is(
    (select count(*)::int from public.v_contestacoes
      where condominio_id = public.test_cond_a()),
    2, 'V36 conselho le as contestacoes');

-- V37/V38: duplicatas e lancamentos_com_duplicata NÃO
select extensions.is(
    (select count(*)::int from public.v_duplicatas_candidatas
      where condominio_id = public.test_cond_a()),
    0, 'V37 conselho nao le duplicatas candidatas');

select extensions.is(
    (select count(*)::int from public.v_lancamentos_com_duplicata
      where condominio_id = public.test_cond_a()),
    0, 'V38 conselho nao le lancamentos com duplicata');

-- V39: papel nominal — observação visível
select extensions.is(
    (select count(*)::int from public.v_conciliacao
      where condominio_id = public.test_cond_a()
        and observacao is not null),
    1, 'V39 conselho (papel nominal) le a observacao da conciliacao');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 5 — LEITOR DO CONDOMÍNIO B (cross-tenant: nada de A)
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condB.test');

select extensions.is(
    (select count(*)::int from public.v_resumo_competencia_fundo where condominio_id = public.test_cond_a()),
    0, 'V40 leitor do B nao ve agregados do A');

select extensions.is(
    (select count(*)::int from public.v_resumo_competencia_rubrica where condominio_id = public.test_cond_a()),
    0, 'V41 leitor do B nao ve rubricas do A');

select extensions.is(
    (select count(*)::int from public.v_resultado_bruto where condominio_id = public.test_cond_a()),
    0, 'V42 leitor do B nao ve resultado do A');

select extensions.is(
    (select count(*)::int from public.v_resultado_liquido where condominio_id = public.test_cond_a()),
    0, 'V43 leitor do B nao ve liquido do A');

select extensions.is(
    (select count(*)::int from public.v_resultado_liquido_por_fundo where condominio_id = public.test_cond_a()),
    0, 'V44 leitor do B nao ve por fundo do A');

select extensions.is(
    (select count(*)::int from public.v_cobertura_competencias where condominio_id = public.test_cond_a()),
    0, 'V45 leitor do B nao ve cobertura do A');

select extensions.is(
    (select count(*)::int from public.v_conciliacao where condominio_id = public.test_cond_a()),
    0, 'V46 leitor do B nao ve conciliacao do A');

select extensions.is(
    (select count(*)::int from public.v_pendencias_resumo where condominio_id = public.test_cond_a()),
    0, 'V47 leitor do B nao ve pendencias do A');

select extensions.is(
    (select count(*)::int from public.v_serie_historica where condominio_id = public.test_cond_a()),
    0, 'V48 leitor do B nao ve serie historica do A');

select extensions.is(
    (select count(*)::int from public.v_importacao_resumo where condominio_id = public.test_cond_a()),
    0, 'V49 leitor do B nao ve importacao do A');

select extensions.is(
    (select count(*)::int from public.v_transferencias_internas where condominio_id = public.test_cond_a()),
    0, 'V50 leitor do B nao ve transferencias do A');

select extensions.is(
    (select count(*)::int from public.v_duplicatas_candidatas where condominio_id = public.test_cond_a()),
    0, 'V51 leitor do B nao ve duplicatas do A');

select extensions.is(
    (select count(*)::int from public.v_lancamentos_com_duplicata where condominio_id = public.test_cond_a()),
    0, 'V52 leitor do B nao ve lancamentos com duplicata do A');

select extensions.is(
    (select count(*)::int from public.v_contestacoes where condominio_id = public.test_cond_a()),
    0, 'V53 leitor do B nao ve contestacoes do A');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 6 — USUÁRIO SEM VÍNCULO (logado, sem papel em condomínio nenhum)
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('sempapel@test.test');

select extensions.is(
    (select
        (select count(*) from public.v_resumo_competencia_fundo) +
        (select count(*) from public.v_resumo_competencia_rubrica) +
        (select count(*) from public.v_resultado_bruto) +
        (select count(*) from public.v_resultado_liquido) +
        (select count(*) from public.v_resultado_liquido_por_fundo) +
        (select count(*) from public.v_cobertura_competencias) +
        (select count(*) from public.v_conciliacao) +
        (select count(*) from public.v_pendencias_resumo) +
        (select count(*) from public.v_serie_historica) +
        (select count(*) from public.v_importacao_resumo) +
        (select count(*) from public.v_transferencias_internas) +
        (select count(*) from public.v_duplicatas_candidatas) +
        (select count(*) from public.v_lancamentos_com_duplicata) +
        (select count(*) from public.v_contestacoes))::int,
    0, 'V54 sem vinculo, as 14 views devolvem zero linhas');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 7 — v_pendencias_resumo não expõe as colunas do detalhe
-- ---------------------------------------------------------------------------
select extensions.is(
    (select count(*)::int from information_schema.columns
      where table_schema = 'public'
        and table_name = 'v_pendencias_resumo'
        and column_name in ('titulo', 'descricao', 'unidade_id', 'lancamento_id', 'resolucao')),
    0, 'V55 v_pendencias_resumo nao expoe titulo, descricao ou ligacoes do detalhe');

select * from finish();
rollback;
