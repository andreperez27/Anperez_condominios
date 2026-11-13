-- ============================================================================
-- TESTES DE SEGURANÇA — MATRIZ função x papel (21 funções × 6 personas)
-- ============================================================================
-- Cobre as 21 funções executáveis por `authenticated` no schema public:
--
--   Leitura agregada: fn_resumo, fn_lancamentos(*), fn_auditoria_log,
--     fn_acesso_log
--   Helpers de papel: fn_usuario_atual, fn_papeis_do_usuario,
--     fn_condominios_do_usuario, fn_e_membro, fn_acessa_condominio
--   Anexos: fn_anexo_acessivel, fn_gerar_url_anexo, fn_liberar_anexo_para_leitor
--   Operação do auditor: fn_aprovar_staging, fn_classificar_lancamento,
--     fn_decidir_duplicata, fn_confirmar_transferencia,
--     fn_reconciliar_competencia, fn_registrar_pendencia
--   Síndico/conselho: fn_contestar_lancamento; auditor: fn_responder_contestacao
--   Política: fn_atualizar_visibilidade
--
-- Personas no A: leitor, auditor, síndico, conselho_fiscal.
-- Cross-tenant: leitor@condB.test. Sem vínculo: sempapel@test.test.
--
-- Regra obrigatória (12/11/2026): papel INSUFICIENTE recebe o MESMO erro de
-- permissão (42501), sem revelar se o registro existe — nem para ids falsos.
-- (*) fn_lancamentos devolve o detalhe — verificado: leitor nunca chega lá.
-- ============================================================================

begin;
select extensions.plan(76);

-- ---------------------------------------------------------------------------
-- Ids reais, capturados ANTES de trocar o papel (as tabelas de detalhe não
-- são legíveis por authenticated)
-- ---------------------------------------------------------------------------
select set_config('test.lancamento_id',
    (select l.id::text from public.lancamentos l
      where l.condominio_id = public.test_cond_a() and l.codigo_conta = '1002'
      order by l.id limit 1), true);

select set_config('test.rubrica_id',
    (select r.id::text from public.rubricas r
      where r.condominio_id = public.test_cond_a() and r.codigo = 'COTA_CONDOMINIAL'
      order by r.id limit 1), true);

select set_config('test.duplicata_id',
    (select d.id::text from public.duplicatas_candidatas d
      where d.condominio_id = public.test_cond_a() order by d.id limit 1), true);

select set_config('test.transferencia_id',
    (select t.id::text from public.transferencias_internas t
      where t.condominio_id = public.test_cond_a() order by t.id limit 1), true);

select set_config('test.competencia_id',
    (select c.id::text from public.competencias c
      where c.condominio_id = public.test_cond_a() and c.ano = 2026 and c.mes = 10), true);

select set_config('test.importacao_id',
    (select i.id::text from public.importacoes i
      join public.fontes_importacao f on f.id = i.fonte_id
      where f.condominio_id = public.test_cond_a() order by i.id limit 1), true);

select set_config('test.anexo_bloqueado',
    (select a.id::text from public.anexos a
      where a.condominio_id = public.test_cond_a() and a.hash_sha256 = 'hash-anexo-1'), true);

select set_config('test.anexo_liberado',
    (select a.id::text from public.anexos a
      where a.condominio_id = public.test_cond_a() and a.hash_sha256 = 'hash-anexo-2'), true);

select set_config('test.caminho_liberado',
    (select a.caminho from public.anexos a
      where a.condominio_id = public.test_cond_a() and a.hash_sha256 = 'hash-anexo-2'), true);

select set_config('test.caminho_bloqueado',
    (select a.caminho from public.anexos a
      where a.condominio_id = public.test_cond_a() and a.hash_sha256 = 'hash-anexo-1'), true);

select set_config('test.contestacao_id',
    (select t.id::text from public.contestacoes t
      where t.condominio_id = public.test_cond_a() order by t.id limit 1), true);

-- ---------------------------------------------------------------------------
-- BLOCO 1 — helpers de papel e leitura agregada
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.is(
    (public.fn_usuario_atual() is not null),
    true, 'F1 leitor obtem o proprio id via fn_usuario_atual');

select extensions.is(
    (select papel::text from public.fn_papeis_do_usuario(public.test_cond_a())),
    'leitor', 'F2 leitor tem o papel leitor neste condominio');

select extensions.is(
    (public.fn_acessa_condominio(public.test_cond_a())),
    true, 'F3 leitor acessa o proprio condominio');

select extensions.is(
    (public.fn_e_membro(public.test_cond_a(), 'auditor')),
    false, 'F4 leitor nao e auditor');

select extensions.is(
    (select count(*)::int from public.fn_condominios_do_usuario()
      where condominio_id = public.test_cond_a()),
    1, 'F5 leitor ve o A nos seus condominios');

select extensions.is(
    (public.fn_acessa_condominio(public.test_cond_b())),
    false, 'F6 leitor do A nao acessa o B');

-- fn_resumo
select extensions.lives_ok(
    'select public.fn_resumo(public.test_cond_a(), null, ''fundo'')',
    'F7 leitor chama fn_resumo com granularidade fundo');

select extensions.throws_ok(
    'select public.fn_resumo(public.test_cond_a(), null, ''rubrica'')',
    '42501', null,
    'F8 granularidade rubrica recusada ao leitor');

select extensions.throws_ok(
    'select public.fn_resumo(public.test_cond_a(), null, ''unidade'')',
    '42501', null,
    'F9 granularidade unidade recusada ao leitor');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 1b — auditor no fn_resumo; B e sem vinculo
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.is(
    (select count(*)::int from public.fn_resumo(public.test_cond_a(), null, 'unidade')),
    12, 'F10 auditor obtem granularidade unidade (12 unidades)');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.lives_ok(
    'select public.fn_resumo(public.test_cond_a(), null, ''unidade'')',
    'F11 sindico (unidade, limiar 1) obtem granularidade unidade');

reset role;
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

select extensions.lives_ok(
    'select public.fn_resumo(public.test_cond_a(), null, ''unidade'')',
    'F12 conselho (unidade, limiar 1) obtem granularidade unidade');

reset role;
set local role authenticated;
select public.test_set_usuario('leitor@condB.test');

select extensions.throws_ok(
    'select public.fn_resumo(public.test_cond_b(), null, ''fundo'')',
    '42501', null,
    'F13 leitor do B: cond B sem politica de visibilidade recusada');

reset role;
set local role authenticated;
select public.test_set_usuario('sempapel@test.test');

select extensions.throws_ok(
    'select public.fn_resumo(public.test_cond_a(), null, ''fundo'')',
    '42501', null,
    'F14 sem vinculo nao chama fn_resumo');

-- fn_lancamentos
reset role;
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_lancamentos(public.test_cond_a(), null, null, null, 10, 0)',
    '42501', null,
    'F15 leitor nao le o detalhe via fn_lancamentos');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.is(
    (select count(*)::int from public.fn_lancamentos(public.test_cond_a(), null, null, null, 1000, 0)),
    14, 'F16 auditor le os 14 lancamentos');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.is(
    (select count(*)::int from public.fn_lancamentos(public.test_cond_a(), null, null, null, 1000, 0)),
    14, 'F17 sindico le o detalhe do proprio condominio');

reset role;
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

select extensions.is(
    (select count(*)::int from public.fn_lancamentos(public.test_cond_a(), null, null, null, 1000, 0)),
    14, 'F18 conselho le o detalhe do proprio condominio');

reset role;
set local role authenticated;
select public.test_set_usuario('leitor@condB.test');

select extensions.throws_ok(
    'select public.fn_lancamentos(public.test_cond_a(), null, null, null, 10, 0)',
    '42501', null,
    'F19 leitor do B nao le o detalhe do A');

reset role;
set local role authenticated;
select public.test_set_usuario('sempapel@test.test');

select extensions.throws_ok(
    'select public.fn_lancamentos(public.test_cond_a(), null, null, null, 10, 0)',
    '42501', null,
    'F20 sem vinculo nao le o detalhe');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 2 — operação do auditor (aprovar, classificar, duplicar, transferir)
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_aprovar_staging(current_setting(''test.importacao_id'')::uuid, array[]::uuid[], ''{}''::jsonb)',
    '42501', null,
    'F21 leitor nao aprova staging');

select extensions.throws_ok(
    'select public.fn_aprovar_staging(''00000000-0000-0000-0000-000000000000''::uuid, array[]::uuid[], ''{}''::jsonb)',
    '42501', null,
    'F22 papel insuficiente + id falso: mesmo erro de permissao');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.throws_ok(
    'select public.fn_aprovar_staging(current_setting(''test.importacao_id'')::uuid, array[]::uuid[], ''{}''::jsonb)',
    '42501', null,
    'F23 sindico nao aprova staging');

reset role;
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

select extensions.throws_ok(
    'select public.fn_aprovar_staging(current_setting(''test.importacao_id'')::uuid, array[]::uuid[], ''{}''::jsonb)',
    '42501', null,
    'F24 conselho nao aprova staging');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_aprovar_staging(current_setting(''test.importacao_id'')::uuid, array[]::uuid[], ''{}''::jsonb)',
    'F25 auditor aprova staging');

reset role;

-- fn_classificar_lancamento
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_classificar_lancamento(current_setting(''test.lancamento_id'')::uuid, current_setting(''test.rubrica_id'')::uuid, null, ''confirmada''::public.status_classificacao, null)',
    '42501', null,
    'F26 leitor nao classifica lancamento');

select extensions.throws_ok(
    'select public.fn_classificar_lancamento(''00000000-0000-0000-0000-000000000000''::uuid, current_setting(''test.rubrica_id'')::uuid)',
    '42501', null,
    'F27 papel insuficiente + lancamento falso: mesmo erro de permissao');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_classificar_lancamento(current_setting(''test.lancamento_id'')::uuid, current_setting(''test.rubrica_id'')::uuid, null, ''confirmada''::public.status_classificacao, null)',
    'F28 auditor classifica lancamento');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.throws_ok(
    'select public.fn_classificar_lancamento(current_setting(''test.lancamento_id'')::uuid, current_setting(''test.rubrica_id'')::uuid, null, ''confirmada''::public.status_classificacao, null)',
    '42501', null,
    'F29 sindico nao classifica');

reset role;
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

select extensions.throws_ok(
    'select public.fn_classificar_lancamento(current_setting(''test.lancamento_id'')::uuid, current_setting(''test.rubrica_id'')::uuid, null, ''confirmada''::public.status_classificacao, null)',
    '42501', null,
    'F30 conselho nao classifica');

reset role;

-- fn_decidir_duplicata
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_decidir_duplicata(current_setting(''test.duplicata_id'')::uuid, ''duplicata_confirmada''::public.status_duplicata, null, null)',
    '42501', null,
    'F31 leitor nao decide duplicata');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_decidir_duplicata(current_setting(''test.duplicata_id'')::uuid, ''duplicata_confirmada''::public.status_duplicata, null, null)',
    'F32 auditor decide duplicata');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.throws_ok(
    'select public.fn_decidir_duplicata(current_setting(''test.duplicata_id'')::uuid, ''duplicata_confirmada''::public.status_duplicata, null, null)',
    '42501', null,
    'F33 sindico nao decide duplicata');

reset role;
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

select extensions.throws_ok(
    'select public.fn_decidir_duplicata(current_setting(''test.duplicata_id'')::uuid, ''duplicata_confirmada''::public.status_duplicata, null, null)',
    '42501', null,
    'F34 conselho nao decide duplicata');

reset role;

-- fn_confirmar_transferencia
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_confirmar_transferencia(current_setting(''test.transferencia_id'')::uuid, ''confirmada''::public.status_transferencia, null)',
    '42501', null,
    'F35 leitor nao confirma transferencia');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_confirmar_transferencia(current_setting(''test.transferencia_id'')::uuid, ''confirmada''::public.status_transferencia, null)',
    'F36 auditor confirma transferencia');

reset role;
set local role authenticated;
select public.test_set_usuario('sempapel@test.test');

select extensions.throws_ok(
    'select public.fn_confirmar_transferencia(current_setting(''test.transferencia_id'')::uuid, ''confirmada''::public.status_transferencia, null)',
    '42501', null,
    'F37 sem vinculo nao confirma transferencia');

reset role;

-- fn_reconciliar_competencia
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_reconciliar_competencia(current_setting(''test.competencia_id'')::uuid)',
    '42501', null,
    'F38 leitor nao reconcilia competencia');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_reconciliar_competencia(current_setting(''test.competencia_id'')::uuid)',
    'F39 auditor reconcilia competencia');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.throws_ok(
    'select public.fn_reconciliar_competencia(current_setting(''test.competencia_id'')::uuid)',
    '42501', null,
    'F40 sindico nao reconcilia competencia');

reset role;

-- fn_registrar_pendencia
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_registrar_pendencia(public.test_cond_a(), ''classificacao''::public.tipo_pendencia, ''manual''::public.origem_pendencia, ''media''::public.gravidade_pendencia, ''TITULO MATRIZ'', ''DESCRICAO MATRIZ'')',
    '42501', null,
    'F41 leitor nao registra pendencia');

reset role;
set local role authenticated;
select public.test_set_usuario('sempapel@test.test');

select extensions.throws_ok(
    'select public.fn_registrar_pendencia(public.test_cond_a(), ''classificacao''::public.tipo_pendencia, ''manual''::public.origem_pendencia, ''media''::public.gravidade_pendencia, ''TITULO MATRIZ'', ''DESCRICAO MATRIZ'')',
    '42501', null,
    'F42 sem vinculo nao registra pendencia em condomínio alheio');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_registrar_pendencia(public.test_cond_a(), ''classificacao''::public.tipo_pendencia, ''manual''::public.origem_pendencia, ''media''::public.gravidade_pendencia, ''TITULO MATRIZ'', ''DESCRICAO MATRIZ'')',
    'F43 auditor registra pendencia');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 3 — contestações e anexos
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_contestar_lancamento(current_setting(''test.lancamento_id'')::uuid, ''x'', ''comentario''::public.tipo_contestacao)',
    '42501', null,
    'F44 leitor nao contesta lancamento');

select extensions.throws_ok(
    'select public.fn_contestar_lancamento(''00000000-0000-0000-0000-000000000000''::uuid, ''x'', ''comentario''::public.tipo_contestacao)',
    '42501', null,
    'F45 papel insuficiente + lancamento falso: mesmo erro de permissao');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_contestar_lancamento(current_setting(''test.lancamento_id'')::uuid, ''x'', ''comentario''::public.tipo_contestacao)',
    'F46 auditor contesta lancamento');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.lives_ok(
    'select public.fn_contestar_lancamento(current_setting(''test.lancamento_id'')::uuid, ''x'', ''comentario''::public.tipo_contestacao)',
    'F47 sindico contesta lancamento');

reset role;
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

select extensions.lives_ok(
    'select public.fn_contestar_lancamento(current_setting(''test.lancamento_id'')::uuid, ''x'', ''comentario''::public.tipo_contestacao)',
    'F48 conselho contesta lancamento');

reset role;
set local role authenticated;
select public.test_set_usuario('leitor@condB.test');

select extensions.throws_ok(
    'select public.fn_contestar_lancamento(current_setting(''test.lancamento_id'')::uuid, ''x'', ''comentario''::public.tipo_contestacao)',
    '42501', null,
    'F49 leitor do B nao contesta lancamento do A');

reset role;

-- fn_responder_contestacao
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_responder_contestacao(current_setting(''test.contestacao_id'')::uuid, ''resposta'', ''acolhida''::public.status_contestacao)',
    '42501', null,
    'F50 leitor nao responde contestacao');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_responder_contestacao(current_setting(''test.contestacao_id'')::uuid, ''resposta'', ''acolhida''::public.status_contestacao)',
    'F51 auditor responde contestacao');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.throws_ok(
    'select public.fn_responder_contestacao(current_setting(''test.contestacao_id'')::uuid, ''resposta'', ''acolhida''::public.status_contestacao)',
    '42501', null,
    'F52 sindico nao responde contestacao');

reset role;

-- fn_liberar_anexo_para_leitor
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_liberar_anexo_para_leitor(current_setting(''test.anexo_bloqueado'')::uuid, true)',
    '42501', null,
    'F53 leitor nao libera anexo');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_liberar_anexo_para_leitor(current_setting(''test.anexo_bloqueado'')::uuid, false)',
    'F54 auditor libera ou revoga anexo');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.throws_ok(
    'select public.fn_liberar_anexo_para_leitor(current_setting(''test.anexo_bloqueado'')::uuid, true)',
    '42501', null,
    'F55 sindico nao libera anexo');

reset role;
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

select extensions.throws_ok(
    'select public.fn_liberar_anexo_para_leitor(current_setting(''test.anexo_bloqueado'')::uuid, true)',
    '42501', null,
    'F56 conselho nao libera anexo');

reset role;

-- fn_anexo_acessivel
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.is(
    (public.fn_anexo_acessivel(current_setting('test.caminho_liberado'))),
    true, 'F57 leitor acessa o anexo LIBERADO');

select extensions.is(
    (public.fn_anexo_acessivel(current_setting('test.caminho_bloqueado'))),
    false, 'F58 leitor nao acessa o anexo bloqueado');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.is(
    (public.fn_anexo_acessivel(current_setting('test.caminho_bloqueado'))),
    true, 'F59 auditor acessa o anexo bloqueado');

reset role;
set local role authenticated;
select public.test_set_usuario('sempapel@test.test');

select extensions.is(
    (public.fn_anexo_acessivel(current_setting('test.caminho_liberado'))),
    false, 'F60 sem vinculo nao acessa anexo nem liberado');

reset role;

-- fn_gerar_url_anexo
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_gerar_url_anexo(current_setting(''test.anexo_bloqueado'')::uuid)',
    '42501', null,
    'F61 leitor sem permissao para anexo bloqueado');

select extensions.lives_ok(
    'select public.fn_gerar_url_anexo(current_setting(''test.anexo_liberado'')::uuid)',
    'F62 leitor acessa anexo liberado');

select extensions.throws_ok(
    'select public.fn_gerar_url_anexo(''00000000-0000-0000-0000-000000000000''::uuid)',
    '42501', null,
    'F63 id falso e sem permissao recebem o MESMO erro');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_gerar_url_anexo(current_setting(''test.anexo_bloqueado'')::uuid)',
    'F64 auditor acessa anexo bloqueado');

reset role;
set local role authenticated;
select public.test_set_usuario('sempapel@test.test');

select extensions.throws_ok(
    'select public.fn_gerar_url_anexo(current_setting(''test.anexo_liberado'')::uuid)',
    '42501', null,
    'F65 sem vinculo nao acessa anexo');

reset role;

-- ---------------------------------------------------------------------------
-- BLOCO 4 — política de visibilidade, logs de auditoria e acesso
-- ---------------------------------------------------------------------------
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_atualizar_visibilidade(public.test_cond_a(), ''leitor''::public.papel_membro, ''fundo'', 5)',
    '42501', null,
    'F66 leitor nao altera a politica de visibilidade');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.throws_ok(
    'select public.fn_atualizar_visibilidade(public.test_cond_a(), ''leitor''::public.papel_membro, ''fundo'', 5)',
    '42501', null,
    'F67 sindico nao altera a politica de visibilidade');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_atualizar_visibilidade(public.test_cond_a(), ''auditor''::public.papel_membro, ''unidade'', 0)',
    'F68 auditor altera a politica de visibilidade');

select extensions.throws_ok(
    'select public.fn_atualizar_visibilidade(''00000000-0000-0000-0000-000000000000''::uuid, ''leitor''::public.papel_membro, ''fundo'', 5)',
    '42501', null,
    'F69 condominio falso: mesmo erro de permissao');

reset role;

-- fn_auditoria_log / fn_acesso_log
set local role authenticated;
select public.test_set_usuario('leitor@condA.test');

select extensions.throws_ok(
    'select public.fn_auditoria_log(public.test_cond_a(), null, null, 5)',
    '42501', null,
    'F70 leitor nao le o log de auditoria');

select extensions.throws_ok(
    'select public.fn_acesso_log(public.test_cond_a(), null, 5)',
    '42501', null,
    'F71 leitor nao le o log de acesso');

reset role;
set local role authenticated;
select public.test_set_usuario('sindico@condA.test');

select extensions.throws_ok(
    'select public.fn_auditoria_log(public.test_cond_a(), null, null, 5)',
    '42501', null,
    'F72 sindico nao le o log de auditoria (auditor/conselho)');

reset role;
set local role authenticated;
select public.test_set_usuario('auditor@condA.test');

select extensions.lives_ok(
    'select public.fn_auditoria_log(public.test_cond_a(), null, null, 5)',
    'F73 auditor le o log de auditoria');

select extensions.lives_ok(
    'select public.fn_acesso_log(public.test_cond_a(), null, 5)',
    'F74 auditor le o log de acesso');

reset role;
set local role authenticated;
select public.test_set_usuario('conselho@condA.test');

select extensions.lives_ok(
    'select public.fn_auditoria_log(public.test_cond_a(), null, null, 5)',
    'F75 conselho le o log de auditoria');

select extensions.lives_ok(
    'select public.fn_acesso_log(public.test_cond_a(), null, 5)',
    'F76 conselho le o log de acesso');

reset role;

select * from finish();
rollback;
