-- ============================================================================
-- TESTES DE SEGURANÇA — PREPARAÇÃO (fixxtures)
-- ============================================================================
-- Cria os usuários de teste em auth.users + auth.identities, os perfis, os
-- membros (papéis) e os condomínios fictícios.
--
-- ⚠️ Este arquivo roda ANTES da bateria de testes e é idempotente.
--
-- PERSONAS:
--   leitor_cond_a    → leitor do condomínio A
--   auditor_cond_a   → auditor do condomínio A
--   leitor_cond_b    → leitor de OUTRO condomínio (testa isolamento)
--   sindico_cond_a   → síndico do condomínio A
--   sem_papel        → autenticado, sem nenhum vínculo
--
-- Todos com senha 'teste12345' (somente local).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- EXTENSÃO pgcrypto (para gerar os UUIDs de forma determinística)
-- ----------------------------------------------------------------------------
create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- CONDOMÍNIOS FICTÍCIOS
-- ----------------------------------------------------------------------------
-- O condomínio A é o do seed (id fixo). O B é criado só para os testes.
insert into public.condominios (id, nome, cnpj, cidade, uf)
values (
    '99999999-9999-9999-9999-999999999999',
    'Condominio Residencial de Testes B',
    '55.666.777/0001-88',
    'Teste',
    'SP'
)
on conflict (id) do nothing;

-- ----------------------------------------------------------------------------
-- FUNÇÃO AUXILIAR: cria (ou reaproveita) um usuário de teste
-- ----------------------------------------------------------------------------
create or replace function public.test_criar_usuario(
    p_email text,
    p_nome  text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
    v_id uuid;
begin
    select id into v_id from auth.users where email = p_email;

    if v_id is null then
        v_id := gen_random_uuid();

        insert into auth.users (
            instance_id, id, aud, role, email, encrypted_password,
            email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
            created_at, updated_at, confirmation_token, email_change,
            email_change_token_new, recovery_token
        )
        values (
            '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
            p_email, extensions.crypt('teste12345', extensions.gen_salt('bf')),
            now(), '{"provider":"email","providers":["email"]}',
            jsonb_build_object('nome', p_nome),
            now(), now(), '', '', '', ''
        );

        insert into auth.identities (
            id, user_id, provider_id, identity_data, provider, last_sign_in_at,
            created_at, updated_at
        )
        values (
            gen_random_uuid(), v_id, p_email::text,
            jsonb_build_object('sub', v_id::text, 'email', p_email, 'email_verified', true),
            'email', now(), now(), now()
        );
    end if;

    insert into public.perfis (id, nome, email)
    values (v_id, p_nome, p_email)
    on conflict (id) do update
        set nome = excluded.nome,
            email = excluded.email;

    return v_id;
end;
$fn$;

-- ----------------------------------------------------------------------------
-- CRIAÇÃO DAS PERSONAS
-- ----------------------------------------------------------------------------
do $fn$
declare
    v_leitor_a  uuid;
    v_auditor_a uuid;
    v_leitor_b  uuid;
    v_sindico_a uuid;
    v_sem_papel uuid;
begin
    v_leitor_a  := public.test_criar_usuario('leitor@condA.test',  'Leitor Condominio A');
    v_auditor_a := public.test_criar_usuario('auditor@condA.test', 'Auditor Condominio A');
    v_leitor_b  := public.test_criar_usuario('leitor@condB.test',  'Leitor Condominio B');
    v_sindico_a := public.test_criar_usuario('sindico@condA.test', 'Sindico Condominio A');
    v_sem_papel := public.test_criar_usuario('sempapel@test.test',  'Usuario Sem Papel');

    -- Condomínio A: leitor, auditor e síndico
    insert into public.membros (condominio_id, perfil_id, papel, finalidade, ativo)
    values
        ('11111111-1111-1111-1111-111111111111', v_leitor_a,  'leitor',  'Consulta agregada', true),
        ('11111111-1111-1111-1111-111111111111', v_auditor_a, 'auditor', 'Auditoria', true),
        ('11111111-1111-1111-1111-111111111111', v_sindico_a, 'sindico', 'Gestao', true),
        -- Condomínio B: leitor de outro condomínio
        ('99999999-9999-9999-9999-999999999999', v_leitor_b,  'leitor',  'Consulta agregada', true)
    on conflict (condominio_id, perfil_id, papel) do nothing;
end;
$fn$;

-- ----------------------------------------------------------------------------
-- HELPERS DE TESTE
-- ----------------------------------------------------------------------------

-- Simula a sessão de um usuário (equivale a estar logado).
create or replace function public.test_set_usuario(p_email text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
    v_id uuid;
begin
    select id into v_id from auth.users where email = p_email;

    if v_id is null then
        raise exception 'usuario de teste inexistente: %', p_email;
    end if;

    -- ⚠️ `set_config(..., true)` é LOCAL À TRANSAÇÃO e é descartado quando
    -- o `set local role` troca o role no meio do teste. Por isso o claim é
    -- definido no escopo da SESSÃO (`false`), que sobrevive.
    perform set_config('request.jwt.claim.sub', v_id::text, false);
    perform set_config(
        'request.jwt.claims',
        json_build_object(
            'sub', v_id::text,
            'email', p_email,
            'role', 'authenticated'
        )::text,
        false);
    perform set_config('request.jwt.claims.role', 'authenticated', false);
end;
$fn$;

-- Limpa a sessão simulada.
create or replace function public.test_limpar_sessao()
returns void
language sql
as $fn$
    select set_config('request.jwt.claim.sub', '', true),
           set_config('request.jwt.claims', '', true),
           set_config('request.jwt.claims.role', '', true);
$fn$;

-- Id do condomínio A / B para uso nos testes.
create or replace function public.test_cond_a()
returns uuid language sql immutable as $fn$ select '11111111-1111-1111-1111-111111111111'::uuid $fn$;

create or replace function public.test_cond_b()
returns uuid language sql immutable as $fn$ select '99999999-9999-9999-9999-999999999999'::uuid $fn$;

-- Contador de acessos — helper de teste. `auth.users` não é legível por
-- `authenticated`, então a contagem do log precisa rodar como dono.
--
-- ⚠️ O owner é `app_owner` (e não `postgres`): a tabela `acesso_log` tem
-- FORCE ROW LEVEL SECURITY, e o `postgres` local NÃO tem BYPASSRLS efetivo
-- sobre ela — o `postgres` é dono da tabela, mas FORCE RLS o sujeita às
-- policies (verificado em 11/11/2026).
create or replace function public.test_contar_acesso_log(
    p_email   text,
    p_recurso text
)
returns bigint
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
    select count(*)
      from public.acesso_log al
      join auth.users u on u.id = al.usuario_id
     where u.email = p_email
       and al.recurso = p_recurso;
$fn$;

alter function public.test_contar_acesso_log(text, text) owner to app_owner;

revoke all on function public.test_contar_acesso_log(text, text) from public, anon;
grant execute on function public.test_contar_acesso_log(text, text) to postgres, authenticated;


-- Contador de lançamentos sem classificação confirmada — helper de teste.
-- `lancamentos` não é legível pelo role autenticado (só via fn_lancamentos),
-- então a contagem roda como dono.
create or replace function public.test_contar_lancamentos_sem_classificacao_confirmada(
    p_condominio_id uuid,
    p_codigo_conta  text
)
returns bigint
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
    select count(*)
      from public.lancamentos l
      join public.lancamento_rubrica lr on lr.lancamento_id = l.id
     where l.condominio_id = p_condominio_id
       and l.codigo_conta = p_codigo_conta
       and lr.status <> 'confirmada';
$fn$;

alter function public.test_contar_lancamentos_sem_classificacao_confirmada(uuid, text) owner to app_owner;

revoke all on function public.test_contar_lancamentos_sem_classificacao_confirmada(uuid, text) from public, anon;
grant execute on function public.test_contar_lancamentos_sem_classificacao_confirmada(uuid, text) to postgres, authenticated;


-- Contador de anexos acessíveis ao usuário do condomínio — helper de teste.
-- `anexos` não é legível pelo role autenticado (por design), então a
-- contagem roda como dono e usa a MESMA função que a policy de storage
-- consulta (fn_anexo_acessivel).
create or replace function public.test_contar_anexos_acessiveis(
    p_condominio_id uuid
)
returns bigint
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
    select count(*)
      from public.anexos a
     where a.condominio_id = p_condominio_id
       and public.fn_anexo_acessivel(a.caminho);
$$;

alter function public.test_contar_anexos_acessiveis(uuid) owner to app_owner;

revoke all on function public.test_contar_anexos_acessiveis(uuid) from public, anon;
grant execute on function public.test_contar_anexos_acessiveis(uuid) to postgres, authenticated;


-- ------------------------------------------------------------------
-- FIXTURES DO CONDOMÍNIO B (para os testes de isolamento)
-- ------------------------------------------------------------------
-- O condomínio B precisa de uma competência e uma fonte de importação
-- para que o teste de isolamento cross-tenant possa criar um lançamento
-- "de outro condomínio".
create or replace function public.test_criar_fixture_cond_b()
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_comp uuid;
    v_src  uuid;
    v_aud  uuid;
begin
    select id into v_aud from auth.users where email = 'auditor@condB.test';

    if v_aud is null then
        v_aud := public.test_criar_usuario('auditor@condB.test', 'Auditor Condominio B');
        insert into public.membros (condominio_id, perfil_id, papel, finalidade, ativo)
        values (public.test_cond_b(), v_aud, 'auditor', 'Auditoria', true)
        on conflict (condominio_id, perfil_id, papel) do nothing;
    end if;

    -- O RETURNING precisa vir de um SELECT: num ON CONFLICT DO UPDATE, o
    -- RETURNING devolve a linha afetada; mas se a inserção foi feita num
    -- passo anterior (ou o conflito veio de outra constraint), ele pode
    -- vir vazio. Por isso o id é buscado explicitamente.
    insert into public.competencias (condominio_id, ano, mes, data_inicio, data_fim)
    values (public.test_cond_b(), 2026, 10, '2026-10-01', '2026-10-31')
    on conflict (condominio_id, ano, mes) do update
        set data_inicio = excluded.data_inicio,
            data_fim = excluded.data_fim;

    select id into v_comp
      from public.competencias
     where condominio_id = public.test_cond_b()
       and ano = 2026 and mes = 10;

    insert into public.fontes_importacao (
        condominio_id, fonte, nome_arquivo, caminho_relativo, hash_sha256,
        tamanho_bytes, layout, competencia_id, status
    )
    values (
        public.test_cond_b(), 'extrato', 'extrato_ficticio_condB_2026-10.xls',
        'ficticio/extrato_ficticio_condB_2026-10.xls',
        encode(extensions.digest('ficticio-condB-2026-10', 'sha256'), 'hex'),
        1024, 'extrato_v3', v_comp, 'detectado'
    )
    on conflict (condominio_id, hash_sha256, layout) do nothing;

    select id into v_src
      from public.fontes_importacao
     where condominio_id = public.test_cond_b()
       and hash_sha256 = encode(extensions.digest('ficticio-condB-2026-10', 'sha256'), 'hex');
end;
$$;

alter function public.test_criar_fixture_cond_b() owner to app_owner;

revoke all on function public.test_criar_fixture_cond_b() from public, anon;
grant execute on function public.test_criar_fixture_cond_b() to postgres;


-- Cria um lançamento no condomínio B (para o teste de isolamento
-- cross-tenant) e devolve o id. Executável por `authenticated` porque é
-- SECURITY DEFINER com filtro de tenant próprio.
create or replace function public.test_criar_lancamento_cond_b()
returns uuid
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_id    uuid;
    v_comp  uuid;
    v_fundo uuid;
    v_src   uuid;
begin
    -- Garante os FUNDOS do B: sem eles o lançamento não tem fundo_id.
    -- O seed só cria os fundos do condominio A.
    insert into public.fundos (id, condominio_id, codigo, nome, natureza, prefixo_conta)
    values
        ('21111111-1111-1111-1111-111111111121', public.test_cond_b(), 'CC',   'CONTA CONDOMINIO', 'principal', '1'),
        ('21111111-1111-1111-1111-111111111122', public.test_cond_b(), 'BENF', 'BENFEITORIAS',     'fundo',     '2')
    on conflict (id) do nothing;

    -- Garante a competencia e a fonte do B (podem ter sido apagadas
    -- pela limpeza entre as baterias).
    insert into public.competencias (condominio_id, ano, mes, data_inicio, data_fim)
    values (public.test_cond_b(), 2026, 10, '2026-10-01', '2026-10-31')
    on conflict (condominio_id, ano, mes) do update
        set data_inicio = excluded.data_inicio,
            data_fim = excluded.data_fim;

    select id into v_comp
      from public.competencias
     where condominio_id = public.test_cond_b()
       and ano = 2026 and mes = 10;

    select id into v_fundo
      from public.fundos
     where condominio_id = public.test_cond_b()
       and codigo = 'CC';

    insert into public.fontes_importacao (
        condominio_id, fonte, nome_arquivo, caminho_relativo, hash_sha256,
        tamanho_bytes, layout, competencia_id, status
    )
    values (
        public.test_cond_b(), 'extrato', 'extrato_ficticio_condB_2026-10.xls',
        'ficticio/extrato_ficticio_condB_2026-10.xls',
        encode(extensions.digest('ficticio-condB-2026-10', 'sha256'), 'hex'),
        1024, 'extrato_v3', v_comp, 'detectado'
    )
    on conflict (condominio_id, hash_sha256, layout) do nothing;

    select id into v_src
      from public.fontes_importacao
     where condominio_id = public.test_cond_b()
       and hash_sha256 = encode(extensions.digest('ficticio-condB-2026-10', 'sha256'), 'hex');

    delete from public.lancamentos
     where condominio_id = public.test_cond_b()
       and codigo_conta = '1002';

    insert into public.lancamentos (
        condominio_id, competencia_id, fundo_id, data_lancamento, valor,
        tipo_movimento, historico, documento, codigo_conta, descricao_conta,
        fonte_id, hash_arquivo, arquivo_nome, linha_origem, chave_natural,
        numero_ocorrencia, criado_por
    )
    select
        public.test_cond_b(),
        v_comp,
        v_fundo,
        date '2026-10-10', 99.00, 'credito'::public.tipo_movimento,
        'RC.UN.000099 RB.TESTEB', 'RB.TESTEB', '1002', 'COTAS CONDOMINIAIS',
        v_src,
        'hash-ficticio-b', 'extrato_ficticio_condB.xls', 999,
        encode(extensions.digest('lanco-b', 'sha256'), 'hex'), 1,
        public.fn_usuario_atual()
    returning id into v_id;

    return v_id;
end;
$$;

-- Pega o id do lançamento criado no condomínio B.
create or replace function public.test_pegar_lancamento_cond_b()
returns uuid
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
    select l.id
      from public.lancamentos l
     where l.condominio_id = public.test_cond_b()
       and l.codigo_conta = '1002'
     order by l.id
     limit 1;
$$;

alter function public.test_criar_lancamento_cond_b() owner to app_owner;
alter function public.test_pegar_lancamento_cond_b() owner to app_owner;

revoke all on function public.test_criar_lancamento_cond_b() from public, anon;
revoke all on function public.test_pegar_lancamento_cond_b() from public, anon;
grant execute on function public.test_criar_lancamento_cond_b() to postgres, authenticated;
grant execute on function public.test_pegar_lancamento_cond_b() to postgres, authenticated;

-- ----------------------------------------------------------------------------
-- LIMPEZA (executada entre cenários)
-- ----------------------------------------------------------------------------
create or replace function public.test_limpar_dados()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
    delete from public.duplicatas_candidatas;
    delete from public.transferencias_internas;
    delete from public.grupos_transferencia;
    delete from public.lancamento_rubrica;
    delete from public.lancamentos;
    delete from public.conciliacao_detalhe;
    delete from public.conciliacoes;
    delete from public.lancamento_rubrica;
    delete from public.anexos;
    delete from public.documentos;
    delete from public.pendencia_anotacoes;
    delete from public.pendencias;
    delete from public.contestacoes;
    delete from public.acesso_log;
    delete from public.auditoria_log;
    delete from public.serie_historica_anotacoes;
    delete from public.serie_historica_resumo;
    delete from public.staging_duplicatas;
    delete from public.staging_transacoes;
    delete from public.staging_lancamentos;
    delete from public.importacoes;
    delete from public.fontes_importacao;
    delete from public.status_competencia;
    delete from public.competencias;
end;
$fn$;

-- ----------------------------------------------------------------------------
-- FIXTURES DE DADOS FINANCEIROS (valores fictícios)
-- ----------------------------------------------------------------------------
-- Cria uma competência, fundos e lançamentos sintéticos no condomínio A.
-- Usado pelos testes de granularidade, limiar e bruto x líquido.
--
-- ⚠️ Os lançamentos usam `select ... from generate_series` em vez de laço
-- PL/pgSQL: o `values` com subquery no meio tornava o diagnóstico de
-- erro de sintaxe desnecessariamente difícil, e o conjunto é pequeno e
-- fixo. O resultado é idêntico.
create or replace function public.test_criar_lancamentos_fixture()
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
declare
    v_comp uuid;
    v_f_cc uuid;
    v_f_benf uuid;
    v_u1 uuid;
    v_u2 uuid;
    v_src uuid;
    v_imp uuid;
    v_autor uuid;
    v_rub_cota uuid;
    v_rub_multa uuid;
    v_rub_transf uuid;
begin
    select id into v_autor from auth.users where email = 'auditor@condA.test';

    -- Competência
    insert into public.competencias (condominio_id, ano, mes, data_inicio, data_fim)
    values (public.test_cond_a(), 2026, 10, '2026-10-01', '2026-10-31')
    on conflict (condominio_id, ano, mes) do update
        set data_inicio = excluded.data_inicio,
            data_fim = excluded.data_fim;

    select id into v_comp
      from public.competencias
     where condominio_id = public.test_cond_a()
       and ano = 2026 and mes = 10;

    select id into v_f_cc   from public.fundos where condominio_id = public.test_cond_a() and codigo = 'CC';
    select id into v_f_benf from public.fundos where condominio_id = public.test_cond_a() and codigo = 'BENF';
    select id into v_u1 from public.unidades where condominio_id = public.test_cond_a() and numero = '11';
    select id into v_u2 from public.unidades where condominio_id = public.test_cond_a() and numero = '12';
    select id into v_rub_cota  from public.rubricas where condominio_id = public.test_cond_a() and codigo = 'COTA_CONDOMINIAL';
    select id into v_rub_multa from public.rubricas where condominio_id = public.test_cond_a() and codigo = 'MULTAS';
    select id into v_rub_transf from public.rubricas where condominio_id = public.test_cond_a() and codigo = 'TRANSFERENCIA_CONTAS';

    -- Fonte de importação fictícia
    insert into public.fontes_importacao (
        condominio_id, fonte, nome_arquivo, caminho_relativo, hash_sha256,
        tamanho_bytes, layout, competencia_id, status
    )
    values (
        public.test_cond_a(), 'extrato', 'extrato_ficticio_2026-10.xls',
        'ficticio/extrato_ficticio_2026-10.xls',
        encode(extensions.digest('ficticio-2026-10', 'sha256'), 'hex'),
        1024, 'extrato_v3', v_comp, 'detectado'
    )
    returning id into v_src;

    insert into public.importacoes (fonte_id, status, executado_por)
    values (v_src, 'concluida', v_autor)
    returning id into v_imp;

    -- 10 lançamentos de cota em 10 unidades DISTINTAS.
    -- As unidades seguem o padrão "andar*10 + posicao" (11..14, 21..24, ...):
    -- usar uma sequência simples (11..20) faria várias linhas caírem na mesma
    -- unidade (11..14 existem; 15..20 não) e o `qtd_unidades` do agregado
    -- sairia errado.
    insert into public.lancamentos (
        condominio_id, competencia_id, fundo_id, unidade_id,
        data_lancamento, valor, tipo_movimento, historico, documento,
        codigo_conta, descricao_conta, fonte_id, hash_arquivo, arquivo_nome,
        linha_origem, chave_natural, numero_ocorrencia, criado_por
    )
    select
        public.test_cond_a(),
        v_comp,
        v_f_cc,
        u.id,
        date '2026-10-05',
        100.00,
        'credito'::public.tipo_movimento,
        'RC.UN.' || lpad(u.numero, 6, '0') || ' RB.TESTE' || g.i,
        'RB.TESTE' || g.i,
        '1002',
        'COTAS CONDOMINIAIS',
        v_src,
        'hash-ficticio',
        'extrato_ficticio_2026-10.xls',
        100 + g.i,
        encode(extensions.digest('cota-' || g.i::text, 'sha256'), 'hex'),
        1,
        v_autor
    from generate_series(1, 10) as g(i)
    join public.unidades u
      on u.condominio_id = public.test_cond_a()
     and u.numero = (((g.i / 4) + 1) * 10 + ((g.i % 4) + 1))::text
    on conflict (condominio_id, chave_natural) do nothing;

    -- 2 lançamentos de multa (2 unidades) → abaixo do limiar de 5
    insert into public.lancamentos (
        condominio_id, competencia_id, fundo_id, unidade_id,
        data_lancamento, valor, tipo_movimento, historico, documento,
        codigo_conta, descricao_conta, fonte_id, hash_arquivo, arquivo_nome,
        linha_origem, chave_natural, numero_ocorrencia, criado_por
    )
    select
        public.test_cond_a(),
        v_comp,
        v_f_cc,
        u.id,
        date '2026-10-06',
        10.00 * g.i,
        'credito'::public.tipo_movimento,
        'RC.MLT.UN.' || lpad(u.numero, 6, '0') || ' RB.TESTEM' || g.i,
        'RB.TESTEM' || g.i,
        '1098',
        'MULTAS',
        v_src,
        'hash-ficticio',
        'extrato_ficticio_2026-10.xls',
        200 + g.i,
        encode(extensions.digest('multa-' || g.i::text, 'sha256'), 'hex'),
        1,
        v_autor
    from generate_series(1, 2) as g(i)
    join public.unidades u
      on u.condominio_id = public.test_cond_a()
     and u.numero = (10 + g.i)::text
    on conflict (condominio_id, chave_natural) do nothing;

    -- Transferência interna: 50,00 do CC para BENF (confirmada)
    insert into public.grupos_transferencia (id, condominio_id, competencia_id, grupo_ref)
    values (
        '77777777-7777-7777-7777-777777777777',
        public.test_cond_a(), v_comp, 'TRF-TESTE-0001'
    )
    on conflict (id) do nothing;

    insert into public.lancamentos (
        id, condominio_id, competencia_id, fundo_id, unidade_id,
        data_lancamento, valor, tipo_movimento, historico, documento,
        codigo_conta, descricao_conta, fonte_id, hash_arquivo, arquivo_nome,
        linha_origem, chave_natural, numero_ocorrencia, grupo_transferencia_id, criado_por
    )
    values (
        '88888888-8888-8888-8888-888888888881',
        public.test_cond_a(), v_comp, v_f_cc, null,
        date '2026-10-07', 50.00, 'debito'::public.tipo_movimento,
        'TRANSFERENCIA PARA BENFEITORIAS', 'TRF.TESTE.1',
        '1041', 'TRANSF. REGUL. ENTRE CONTAS',
        v_src, 'hash-ficticio', 'extrato_ficticio_2026-10.xls', 300,
        encode(extensions.digest('trf-debito', 'sha256'), 'hex'), 1,
        '77777777-7777-7777-7777-777777777777', v_autor
    )
    on conflict (id) do nothing;

    insert into public.lancamentos (
        id, condominio_id, competencia_id, fundo_id, unidade_id,
        data_lancamento, valor, tipo_movimento, historico, documento,
        codigo_conta, descricao_conta, fonte_id, hash_arquivo, arquivo_nome,
        linha_origem, chave_natural, numero_ocorrencia, grupo_transferencia_id, criado_por
    )
    values (
        '88888888-8888-8888-8888-888888888882',
        public.test_cond_a(), v_comp, v_f_benf, null,
        date '2026-10-07', 50.00, 'credito'::public.tipo_movimento,
        'TRANSFERENCIA DA CONTA CONDOMINIO', 'TRF.TESTE.2',
        '1041', 'TRANSF. REGUL. ENTRE CONTAS',
        v_src, 'hash-ficticio', 'extrato_ficticio_2026-10.xls', 301,
        encode(extensions.digest('trf-credito', 'sha256'), 'hex'), 1,
        '77777777-7777-7777-7777-777777777777', v_autor
    )
    on conflict (id) do nothing;

    insert into public.transferencias_internas (
        condominio_id, competencia_id, grupo_id, fundo_origem_id, fundo_destino_id,
        valor, lancamento_origem_id, lancamento_destino_id, status, regra
    )
    values (
        public.test_cond_a(), v_comp, '77777777-7777-7777-7777-777777777777',
        v_f_cc, v_f_benf, 50.00,
        '88888888-8888-8888-8888-888888888881',
        '88888888-8888-8888-8888-888888888882',
        'confirmada', 'manual'
    )
    on conflict (lancamento_origem_id) do nothing;

    -- Classificação dos lançamentos de cota e multa
    insert into public.lancamento_rubrica (lancamento_id, rubrica_id, fundo_id, status, origem)
    select l.id, v_rub_cota, l.fundo_id, 'confirmada', 'manual'
    from public.lancamentos l
    where l.condominio_id = public.test_cond_a()
      and l.codigo_conta = '1002'
    on conflict (lancamento_id) do nothing;

    insert into public.lancamento_rubrica (lancamento_id, rubrica_id, fundo_id, status, origem)
    select l.id, v_rub_multa, l.fundo_id, 'confirmada', 'manual'
    from public.lancamentos l
    where l.condominio_id = public.test_cond_a()
      and l.codigo_conta = '1098'
    on conflict (lancamento_id) do nothing;

    -- A transferência interna também é classificada (senão o agregado por
    -- rubrica mostra um grupo "SEM RUBRICA").
    insert into public.lancamento_rubrica (lancamento_id, rubrica_id, fundo_id, status, origem)
    select l.id, v_rub_transf, l.fundo_id, 'confirmada', 'manual'
    from public.lancamentos l
    where l.condominio_id = public.test_cond_a()
      and l.codigo_conta = '1041'
    on conflict (lancamento_id) do nothing;

    -- Par de duplicatas candidatas (mesma tupla, duas linhas) — usado pelo
    -- teste de decisão de duplicata. As DUAS linhas existem: duplicata
    -- nunca é descartada, só marcada.
    insert into public.duplicatas_candidatas (
        condominio_id, chave_candidata, tupla_comum, criterio,
        lancamento_a_id, lancamento_b_id, status
    )
    select
        public.test_cond_a(),
        encode(extensions.digest('dup-teste', 'sha256'), 'hex'),
        encode(extensions.digest('tupla-duplicada', 'sha256'), 'hex'),
        'mesma_tupla_no_arquivo'::public.criterio_duplicata,
        l.id,
        l2.id,
        'pendente'::public.status_duplicata
    from public.lancamentos l
    join public.lancamentos l2
      on l2.condominio_id = l.condominio_id
     and l2.id > l.id
     and l2.codigo_conta = l.codigo_conta
    where l.condominio_id = public.test_cond_a()
      and l.codigo_conta = '1002'
    order by l.id, l2.id
    limit 1
    on conflict (lancamento_a_id, lancamento_b_id) do nothing;

    -- Anexo fictício (liberado e não liberado) para o teste de storage.
    -- ⚠️ `anexos` não tem constraint única, então `on conflict` sem alvo
    -- não é válido — o "do nothing" só funciona se houver conflito
    -- detectável. Aqui a idempotência vem da limpeza prévia
    -- (test_limpar_dados).
    delete from public.anexos
     where condominio_id = public.test_cond_a()
       and fonte_id = v_src;

    insert into public.anexos (
        condominio_id, fonte_id, pagina, rotulo, hash_sha256, caminho,
        status, liberado_para_leitor
    )
    values
    (public.test_cond_a(), v_src, 2, 'comprovante NAO liberado',
     'hash-anexo-1', '11111111-1111-1111-1111-111111111111/anexo-1.pdf',
     'vinculado', false),
    (public.test_cond_a(), v_src, 3, 'comprovante liberado',
     'hash-anexo-2', '11111111-1111-1111-1111-111111111111/anexo-2.pdf',
     'vinculado', true);
end;
$fn$;

-- Os helpers de teste são chamáveis por `authenticated` porque o teste
-- precisa trocar a sessão SIMULADA depois de `set local role authenticated`.
-- Eles só mudam GUCs de sessão (o JWT simulado) — não dão acesso a dado.
--
-- ⚠️ `test_set_usuario` e `test_contar_acesso_log` têm owner = app_owner:
--   o app_owner tem USAGE no schema auth e BYPASSRLS, então consegue ler
--   `auth.users`. Com owner = postgres, a leitura de auth.users falharia
--   (o postgres local não tem BYPASSRLS efetivo sobre tabelas com FORCE RLS).
alter function public.test_set_usuario(text) owner to app_owner;

revoke all on function public.test_criar_usuario(text, text) from public, anon;
revoke all on function public.test_set_usuario(text) from public, anon;
revoke all on function public.test_limpar_sessao() from public, anon;
revoke all on function public.test_limpar_dados() from public, anon;
revoke all on function public.test_criar_lancamentos_fixture() from public, anon;

grant execute on function public.test_criar_usuario(text, text) to postgres;
-- O app_owner é o owner de vários helpers e precisa chamá-los.
grant execute on function public.test_criar_usuario(text, text) to app_owner;
grant execute on function public.test_set_usuario(text) to postgres, authenticated;

-- Os helpers de teste (owner = app_owner) gravam em `membros`, `perfis` e
-- `auth.users`. O app_owner precisa desses privilégios — sem eles o corpo
-- falha com "permission denied for table membros".
grant insert, update on public.membros  to app_owner;
grant insert, update on public.perfis   to app_owner;
grant insert, update on public.lancamentos to app_owner;
grant insert, update on public.fontes_importacao to app_owner;
grant insert, update on public.competencias to app_owner;
grant insert, update on public.importacoes to app_owner;
grant insert, update on public.lancamento_rubrica to app_owner;
grant insert, update on public.duplicatas_candidatas to app_owner;
grant insert, update on public.transferencias_internas to app_owner;
grant insert, update on public.grupos_transferencia to app_owner;
grant insert, update on public.anexos to app_owner;
grant insert, update on public.acesso_log to app_owner;
grant insert, update on public.auditoria_log to app_owner;
-- A fixture da matriz (06/07) cria e apaga dados nessas tabelas
grant insert, update, delete on public.pendencias to app_owner;
grant insert, update, delete on public.conciliacoes to app_owner;
grant insert, update, delete on public.contestacoes to app_owner;
grant insert, update, delete on public.status_competencia to app_owner;
grant insert, update, delete on public.serie_historica_resumo to app_owner;
grant select on public.membros, public.perfis, public.unidades,
                public.fundos, public.rubricas, public.competencias,
                public.fontes_importacao, public.lancamentos,
                public.lancamento_rubrica, public.duplicatas_candidatas,
                public.transferencias_internas, public.grupos_transferencia,
                public.anexos, public.acesso_log, public.auditoria_log,
                public.pendencias, public.conciliacoes, public.contestacoes,
                public.status_competencia, public.serie_historica_resumo
to app_owner;
grant execute on function public.test_limpar_sessao() to postgres, authenticated;
grant execute on function public.test_limpar_dados() to postgres;
grant execute on function public.test_criar_lancamentos_fixture() to postgres;
grant execute on function public.test_cond_a() to postgres, authenticated;
grant execute on function public.test_cond_b() to postgres, authenticated;

-- Os dois helpers acima devolvem o id do condomínio de teste. Sem o revoke
-- do PUBLIC, o `anon` (não logado) também poderia chamá-los — o que o teste
-- de drift (T44/T45) acusa como falha.
revoke all on function public.test_cond_a() from public, anon;
revoke all on function public.test_cond_b() from public, anon;

-- O `app_owner` é o dono das funções SECURITY DEFINER de teste (que chamam
-- estes helpers), por isso precisa do EXECUTE explícito.
grant execute on function public.test_cond_a() to app_owner;
grant execute on function public.test_cond_b() to app_owner;

-- ----------------------------------------------------------------------------
-- FIXTURE DA MATRIZ view x papel (usada por 06_matriz_views e 07_matriz_funcoes)
-- ----------------------------------------------------------------------------
-- Completa o condomínio A com os dados que test_criar_lancamentos_fixture NÃO
-- cria, para que as views e funções possam ser exercitadas de ponta a ponta:
--   • persona conselho_fiscal (conselho@condA.test) no A;
--   • 2 pendências (uma de unidade, uma sem);
--   • 2 conciliações (CC divergente com observação, BENF conciliada);
--   • 2 contestações (síndico e auditor);
--   • 2 linhas de série histórica;
--   • status de competência com observação.
-- Idempotente: apaga pelo marcador MATRIZ e recria.
create or replace function public.test_criar_fixture_matriz()
returns void
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
declare
    v_cond_a   uuid := public.test_cond_a();
    v_comp     uuid;
    v_f_cc     uuid;
    v_f_benf   uuid;
    v_u1       uuid;
    v_src      uuid;
    v_autor    uuid;
    v_sindico  uuid;
    v_conselho uuid;
    v_lanc     uuid;
begin
    -- 1. Persona conselho_fiscal do condominio A
    v_conselho := public.test_criar_usuario('conselho@condA.test', 'Conselho Condominio A');
    insert into public.membros (condominio_id, perfil_id, papel, finalidade, ativo)
    values (v_cond_a, v_conselho, 'conselho_fiscal', 'Fiscalizacao', true)
    on conflict (condominio_id, perfil_id, papel) do nothing;

    select id into v_autor   from auth.users where email = 'auditor@condA.test';
    select id into v_sindico from auth.users where email = 'sindico@condA.test';

    -- contexto da fixture base
    select id into v_comp from public.competencias
     where condominio_id = v_cond_a and ano = 2026 and mes = 10;
    select id into v_f_cc   from public.fundos where condominio_id = v_cond_a and codigo = 'CC';
    select id into v_f_benf from public.fundos where condominio_id = v_cond_a and codigo = 'BENF';
    select id into v_u1     from public.unidades where condominio_id = v_cond_a and numero = '11';
    select id into v_src    from public.fontes_importacao
     where condominio_id = v_cond_a
       and hash_sha256 = encode(extensions.digest('ficticio-2026-10', 'sha256'), 'hex');
    select l.id into v_lanc from public.lancamentos l
     where l.condominio_id = v_cond_a and l.codigo_conta = '1002'
     order by l.id limit 1;

    -- 2. Pendencias
    delete from public.pendencias
     where condominio_id = v_cond_a and titulo like 'PENDENCIA MATRIZ%';
    insert into public.pendencias (
        condominio_id, tipo, origem, gravidade, titulo, descricao,
        competencia_id, fundo_id, unidade_id, status, criada_por
    ) values
        (v_cond_a, 'classificacao', 'manual',  'media',
         'PENDENCIA MATRIZ 1 (unidade 11)', 'Fixture da matriz view x papel',
         v_comp, v_f_cc, v_u1, 'aberta', v_autor),
        (v_cond_a, 'divergencia',   'sistema', 'alta',
         'PENDENCIA MATRIZ 2 (sem unidade)', 'Fixture da matriz view x papel',
         v_comp, v_f_cc, null, 'aberta', v_autor);

    -- 3. Conciliacoes (CC divergente com observacao; BENF conciliada)
    delete from public.conciliacoes
     where condominio_id = v_cond_a and observacao like 'OBSERVACAO MATRIZ%';
    insert into public.conciliacoes (
        condominio_id, competencia_id, fundo_id, status,
        creditos_extrato, debitos_extrato, creditos_balancete, debitos_balancete,
        diferenca_creditos, diferenca_debitos, observacao, conciliado_em, conciliado_por
    ) values
        (v_cond_a, v_comp, v_f_cc, 'divergente', 1000, 50, 1050, 50, -50, 0,
         'OBSERVACAO MATRIZ: unidade 11 nao enviou extrato', now(), v_autor)
    on conflict (competencia_id, fundo_id) do update
        set status = excluded.status,
            observacao = excluded.observacao,
            conciliado_em = excluded.conciliado_em,
            conciliado_por = excluded.conciliado_por;
    insert into public.conciliacoes (
        condominio_id, competencia_id, fundo_id, status,
        creditos_extrato, debitos_extrato, creditos_balancete, debitos_balancete,
        diferenca_creditos, diferenca_debitos, observacao, conciliado_em, conciliado_por
    ) values
        (v_cond_a, v_comp, v_f_benf, 'conciliado', 50, 0, 50, 0, 0, 0,
         null, now(), v_autor)
    on conflict (competencia_id, fundo_id) do update
        set status = excluded.status,
            observacao = excluded.observacao,
            conciliado_em = excluded.conciliado_em,
            conciliado_por = excluded.conciliado_por;

    -- 4. Contestacoes (sindico e auditor)
    delete from public.contestacoes
     where condominio_id = v_cond_a and texto like 'CONTESTACAO MATRIZ%';
    insert into public.contestacoes (
        condominio_id, lancamento_id, autor_id, tipo, texto, status
    ) values
        (v_cond_a, v_lanc, v_sindico, 'comentario',
         'CONTESTACAO MATRIZ do sindico', 'aberta'),
        (v_cond_a, v_lanc, v_autor,   'contestacao',
         'CONTESTACAO MATRIZ do auditor', 'aberta');

    -- 5. Serie historica (2 linhas, 2020)
    delete from public.serie_historica_resumo
     where condominio_id = v_cond_a and rubrica_alias like 'MATRIZ ALIAS%';
    insert into public.serie_historica_resumo (
        condominio_id, ano, mes, bloco, rubrica_alias, rubrica_id, fundo_id,
        saldo_anterior, creditos, debitos, saldo, fonte_id, linha_origem
    )
    select
        v_cond_a, 2020, 1, 'conta',
        'MATRIZ ALIAS ' || g.i,
        (select id from public.rubricas where condominio_id = v_cond_a and codigo = 'COTA_CONDOMINIAL'),
        v_f_cc,
        1000 + g.i, 1200, 800, 1400 + g.i, v_src, 900 + g.i
    from generate_series(1, 2) as g(i);

    -- 6. Status de competencia (com observacao)
    insert into public.status_competencia (
        competencia_id, fonte, status, observacao, atualizado_por
    ) values (
        v_comp, 'extrato', 'importado',
        'OBSERVACAO MATRIZ: competencia conferida', v_autor
    )
    on conflict (competencia_id, fonte) do update
        set status = excluded.status,
            observacao = excluded.observacao,
            atualizado_em = now(),
            atualizado_por = excluded.atualizado_por;
end;
$fn$;

alter function public.test_criar_fixture_matriz() owner to app_owner;

revoke all on function public.test_criar_fixture_matriz() from public, anon;
grant execute on function public.test_criar_fixture_matriz() to postgres;
