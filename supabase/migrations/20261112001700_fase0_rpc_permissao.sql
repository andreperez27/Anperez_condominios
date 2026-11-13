-- ============================================================================
-- MIGRATION 017 — FASE 0: RPCs — PERMISSÃO UNIFORME E CORREÇÕES DE EXECUÇÃO
-- ============================================================================
-- Encontrado ao montar a matriz função x papel (12/11/2026). Quatro RPCs
-- executáveis por `authenticated` estavam quebradas para QUALQUER chamador
-- (o auditor inclusive) — o caminho feliz nunca executou:
--
-- 1. fn_aprovar_staging — o INSERT ... SELECT em duplicatas_candidatas e
--    pendencias (e o INSERT ... SELECT em lancamento_rubrica) usava literais
--    de texto para colunas de enum SEM CAST. Literais em VALUES fazem
--    coerção implícita, mas num INSERT ... SELECT a lista de projeção é
--    avaliada SEM o contexto da tabela-alvo — a função falhava em tempo de
--    plano, sempre ("column criterio is of type criterio_duplicata but
--    expression is of type text"). Resultado: a importação nunca entrou.
--
-- 2. fn_reconciliar_competencia — o `on conflict (competencia_id, fundo_id)`
--    era ambíguo (fundo_id é parâmetro de retorno da função), e o
--    `update ... set status = case when coalesce(diferenca_creditos, 0) ...`
--    comparava a VARIÁVEL de retorno (NULL) em vez da coluna — a contagem
--    "conciliado" nunca dispararia. Corrigido para `on conflict on
--    constraint conciliacoes_unica` e qualificação `c.` nas colunas.
--
-- 3. fn_responder_contestacao — typo `entidad` no INSERT em auditoria_log:
--    a função falhava com 42703 para QUALQUER chamador (auditor inclusive).
--
-- 4. fn_gerar_url_anexo — (a) anexo inexistente devolvia P0002, o que
--    permitia distinguir "não existe" de "sem permissão" (enumeração por
--    id). Agora os dois casos devolvem o MESMO 42501. (b) a função chamava
--    `storage.create_signed_url(...)`, que NÃO EXISTE como função do banco —
--    URLs assinadas são criadas pela Storage API (fora do Postgres). 
--    Decisão: a função passa a ser o PORTEIRO (valida a permissão e registra
--    o acesso no acesso_log) e devolve o CAMINHO do objeto; a URL assinada é
--    criada no front pelo supabase-js (createSignedUrl) — a policy de
--    storage.objects (migration 01500) garante que só quem passa por aqui
--    consegue baixar.
--
-- 5. fn_registrar_pendencia — NÃO validava nada: qualquer autenticado
--    podia gravar pendência em QUALQUER condomínio (escrita cross-tenant).
--    Agora exige papel de auditor NO CONDOMÍNIO PEDIDO.
-- ============================================================================

create or replace function public.fn_registrar_pendencia(
    p_condominio_id  uuid,
    p_tipo           public.tipo_pendencia,
    p_origem         public.origem_pendencia,
    p_gravidade      public.gravidade_pendencia,
    p_titulo         text,
    p_descricao      text,
    p_competencia_id uuid default null,
    p_fundo_id       uuid default null,
    p_unidade_id     uuid default null,
    p_lancamento_id  uuid default null,
    p_fonte_id       uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
declare
    v_id uuid;
begin
    -- Papel avaliado ANTES de qualquer escrita: pendencias são da alçada
    -- do auditor no condominio pedido.
    if not public.fn_e_membro(p_condominio_id, 'auditor') then
        raise exception 'somente auditor registra pendencia'
            using errcode = '42501';
    end if;

    insert into public.pendencias (
        condominio_id, tipo, origem, gravidade, titulo, descricao,
        competencia_id, fundo_id, unidade_id, lancamento_id, fonte_id,
        criada_por
    )
    values (
        p_condominio_id, p_tipo, p_origem, p_gravidade, p_titulo, p_descricao,
        p_competencia_id, p_fundo_id, p_unidade_id, p_lancamento_id, p_fonte_id,
        public.fn_usuario_atual()
    )
    returning id into v_id;

    return v_id;
end;
$fn$;

create or replace function public.fn_responder_contestacao(
    p_contestacao_id uuid,
    p_resposta       text,
    p_status         public.status_contestacao default 'acolhida'
)
returns void
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
declare
    v_cond uuid;
begin
    -- PAPEL antes da EXISTENCIA (ver nota em fn_aprovar_staging).
    select t.condominio_id into v_cond
      from public.contestacoes t where t.id = p_contestacao_id;

    if v_cond is null or not public.fn_e_membro(v_cond, 'auditor') then
        raise exception 'somente auditor responde contestacao' using errcode = '42501';
    end if;

    update public.contestacoes
       set resposta = p_resposta,
           status = p_status,
           respondida_por = public.fn_usuario_atual(),
           respondida_em = now()
     where id = p_contestacao_id;

    insert into public.auditoria_log (
        condominio_id, entidade, entidade_id, acao, depois, usuario_id
    )
    values (
        v_cond, 'contestacao', p_contestacao_id::text, 'responder',
        jsonb_build_object('status', p_status),
        public.fn_usuario_atual()
    );
end;
$fn$;

create or replace function public.fn_gerar_url_anexo(p_anexo_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
declare
    v_anexo public.anexos%rowtype;
begin
    select a.* into v_anexo from public.anexos a where a.id = p_anexo_id;

    -- Erro UNIFORME: "não existe" e "sem permissão" devolvem o mesmo 42501.
    -- Um chamador sem acesso não consegue distinguir os dois casos.
    if v_anexo.id is null or not public.fn_anexo_acessivel(v_anexo.caminho) then
        raise exception 'sem permissao para acessar este anexo' using errcode = '42501';
    end if;

    insert into public.acesso_log (
        condominio_id, usuario_id, operacao, recurso, entidade_id
    )
    values (
        v_anexo.condominio_id, public.fn_usuario_atual(), 'anexo',
        'fn_gerar_url_anexo', p_anexo_id::text
    );

    -- O CAMINHO é devolvido — NUNCA uma URL assinada (que só a Storage API
    -- sabe criar). O front chama supabase.storage.from('anexos')
    -- .createSignedUrl(caminho, 300): a policy de storage.objects garante
    -- que só quem passou pelo porteiro consegue baixar.
    return v_anexo.caminho;
end;
$fn$;

create or replace function public.fn_aprovar_staging(
    p_importacao_id uuid,
    p_staging_ids   uuid[],
    p_decisoes      jsonb default '{}'::jsonb
)
returns table (
    lancamentos_criados     int,
    lancamentos_atualizados int,
    duplicatas_criadas      int,
    pendencias_criadas      int,
    transferencias_criadas  int
)
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
declare
    v_cond     uuid;
    v_comp     uuid;
    v_criados  int := 0;
    v_atual    int := 0;
    v_dup      int := 0;
    v_pend     int := 0;
    v_transf   int := 0;
begin
    -- O PAPEL e' validado ANTES da existencia do registro: caso
    -- contrario, um usuario sem permissao receberia "importacao
    -- inexistente" (P0002) em vez de "sem permissao" (42501) e poderia
    -- ENUMERAR a existencia de importacoes por id. (E o PostgREST
    -- traduz 42501 -> HTTP 403, mas P0002 -> HTTP 500.)
    --
    -- O condominio vem da IMPORTACAO; o papel e' avaliado nele. Se o
    -- registro nao existir, o erro e' o mesmo de "sem permissao".
    select f.condominio_id, f.competencia_id
      into v_cond, v_comp
      from public.importacoes i
      join public.fontes_importacao f on f.id = i.fonte_id
     where i.id = p_importacao_id
     for update of i;

    if v_cond is null or not public.fn_e_membro(v_cond, 'auditor') then
        raise exception 'somente auditor pode aprovar importacao'
            using errcode = '42501';
    end if;

    -- 1. Lançamentos (idempotente pela chave natural)
    with ins as (
        insert into public.lancamentos (
            condominio_id, competencia_id, fundo_id, unidade_id,
            data_lancamento, data_vencimento, data_documento,
            valor, tipo_movimento, historico, documento, codigo_conta,
            descricao_conta, fonte_id, hash_arquivo, arquivo_nome, aba,
            pagina, linha_origem, coluna_origem, texto_origem,
            status_classificacao, origem_classificacao,
            chave_natural, numero_ocorrencia, criado_por
        )
        select
            s.condominio_id, v_comp, s.fundo_sugerido_id, u.id,
            s.data_lancamento, s.data_vencimento, s.data_vencimento,
            s.valor, s.tipo_movimento, s.historico, s.documento,
            s.codigo_conta, s.descricao_conta,
            s.fonte_id, f.hash_sha256, f.nome_arquivo, s.aba,
            s.pagina, s.linha_origem, null, s.texto_origem,
            'sugerida', 'importacao',
            s.chave_natural, s.numero_ocorrencia, public.fn_usuario_atual()
        from public.staging_lancamentos s
        join public.fontes_importacao f on f.id = s.fonte_id
        left join public.unidades u
               on u.condominio_id = s.condominio_id
              and u.numero = s.unidade_numero
        where s.importacao_id = p_importacao_id
          and s.id = any(p_staging_ids)
          and s.status <> 'erro_parse'
          and s.valor is not null
          and s.tipo_movimento is not null
          and s.data_lancamento is not null
          and s.codigo_conta is not null
        on conflict (condominio_id, chave_natural) do update
            set atualizado_em = now()
        returning (xmax = 0) as inseriu
    )
    select count(*) filter (where inseriu),
           count(*) filter (where not inseriu)
      into v_criados, v_atual
    from ins;

    -- 2. Classificação (sugerida) por lançamento aprovado
    insert into public.lancamento_rubrica (
        lancamento_id, rubrica_id, fundo_id, status, origem, confianca
    )
    select l.id, co.rubrica_id, l.fundo_id,
           'sugerida'::public.status_classificacao,
           'conta'::public.origem_classificacao,
           null
    from public.lancamentos l
    join public.contas_origem co
      on co.condominio_id = l.condominio_id
     and co.codigo = l.codigo_conta
    where l.condominio_id = v_cond
      and co.rubrica_id is not null
    on conflict (lancamento_id) do nothing;

    -- 3. Duplicatas candidatas (comparação pela TUPLA, nunca pela chave)
    insert into public.duplicatas_candidatas (
        condominio_id, chave_candidata, tupla_comum, criterio,
        lancamento_a_id, lancamento_b_id, status
    )
    select distinct
        l.condominio_id,
        encode(extensions.digest(l.chave_natural, 'sha256'), 'hex'),
        l.chave_natural,
        'mesma_tupla_no_arquivo'::public.criterio_duplicata,
        l.id,
        l2.id,
        'pendente'::public.status_duplicata
    from public.lancamentos l
    join public.lancamentos l2
      on l2.condominio_id = l.condominio_id
     and l2.id > l.id
     and l2.chave_natural = l.chave_natural
    where l.condominio_id = v_cond
    on conflict (lancamento_a_id, lancamento_b_id) do nothing;

    get diagnostics v_dup = row_count;

    -- 4. Pendência para lançamentos sem rubrica
    insert into public.pendencias (
        condominio_id, tipo, origem, gravidade, titulo, descricao,
        lancamento_id, competencia_id, fundo_id, status
    )
    select
        l.condominio_id,
        'classificacao'::public.tipo_pendencia,
        'importacao'::public.origem_pendencia,
        'media'::public.gravidade_pendencia,
        'Lançamento sem rubrica',
        'Lançamento ' || l.codigo_conta || ' — ' || l.descricao_conta
            || ' (arquivo ' || l.arquivo_nome || ', linha ' || l.linha_origem || ')',
        l.id, l.competencia_id, l.fundo_id,
        'aberta'::public.status_pendencia
    from public.lancamentos l
    where l.condominio_id = v_cond
      and not exists (
            select 1 from public.lancamento_rubrica lr
             where lr.lancamento_id = l.id
          );

    get diagnostics v_pend = row_count;

    -- 5. Status da competência: importado
    insert into public.status_competencia (
        competencia_id, fonte, status, atualizado_por
    )
    values (v_comp,
            'extrato'::public.fonte_contabil,
            'importado'::public.status_fonte,
            public.fn_usuario_atual())
    on conflict (competencia_id, fonte) do update
        set status = 'importado'::public.status_fonte,
            atualizado_em = now(),
            atualizado_por = public.fn_usuario_atual();

    -- 6. Marca o staging como aprovado
    update public.staging_lancamentos
       set status = 'aprovado'::public.status_staging,
           aprovado_em = now(),
           aprovado_por = public.fn_usuario_atual()
     where importacao_id = p_importacao_id
       and id = any(p_staging_ids);

    -- 7. Auditoria
    insert into public.auditoria_log (
        condominio_id, entidade, entidade_id, acao, depois, usuario_id
    )
    values (
        v_cond, 'importacao', p_importacao_id::text, 'aprovar',
        jsonb_build_object(
            'criados', v_criados,
            'atualizados', v_atual,
            'duplicatas', v_dup,
            'pendencias', v_pend
        ),
        public.fn_usuario_atual()
    );

    return query select v_criados, v_atual, v_dup, v_pend, v_transf;
end;
$fn$;

create or replace function public.fn_reconciliar_competencia(
    p_competencia_id uuid
)
returns table (
    fundo_id            uuid,
    status              public.status_conciliacao,
    diferenca_creditos  numeric,
    diferenca_debitos   numeric
)
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $fn$
declare
    v_cond uuid;
    r       record;
begin
    -- PAPEL antes da EXISTENCIA (ver nota em fn_aprovar_staging).
    select c.condominio_id into v_cond
      from public.competencias c where c.id = p_competencia_id;

    if v_cond is null or not public.fn_e_membro(v_cond, 'auditor') then
        raise exception 'somente auditor reconcilia' using errcode = '42501';
    end if;

    for r in
        select f.id as fundo_id,
               coalesce(sum(l.valor) filter (where l.tipo_movimento = 'credito'), 0) as creditos,
               coalesce(sum(l.valor) filter (where l.tipo_movimento = 'debito'), 0)  as debitos
        from public.fundos f
        left join public.lancamentos l
               on l.fundo_id = f.id
              and l.competencia_id = p_competencia_id
              and l.status = 'ativo'
        where f.condominio_id = v_cond
          and f.ativo
        group by f.id
    loop
        insert into public.conciliacoes (
            condominio_id, competencia_id, fundo_id, status,
            creditos_extrato, debitos_extrato,
            conciliado_em, conciliado_por
        )
        values (
            v_cond, p_competencia_id, r.fundo_id, 'sem_fonte'::public.status_conciliacao,
            r.creditos, r.debitos, now(), public.fn_usuario_atual()
        )
        on conflict on constraint conciliacoes_unica do update
            set creditos_extrato = excluded.creditos_extrato,
                debitos_extrato  = excluded.debitos_extrato,
                conciliado_em    = now(),
                conciliado_por   = public.fn_usuario_atual();

        -- Status: 'conciliado' quando as diferenças são zero (tolerância 0,01).
        -- ⚠️ qualificado com o alias: diferenca_creditos/debitos colidem com
        -- as colunas do RETURNS TABLE (bug original).
        update public.conciliacoes c
           set status = case
                            when coalesce(c.diferenca_creditos, 0) = 0
                             and coalesce(c.diferenca_debitos, 0) = 0
                            then 'conciliado'::public.status_conciliacao
                            else 'divergente'::public.status_conciliacao
                        end
         where c.competencia_id = p_competencia_id
           and c.fundo_id = r.fundo_id;

        -- Divergência vira pendência (nunca altera lançamento).
        if exists (
            select 1 from public.conciliacoes c
             where c.competencia_id = p_competencia_id
               and c.fundo_id = r.fundo_id
               and c.status = 'divergente'
        ) then
            insert into public.pendencias (
                condominio_id, tipo, origem, gravidade, titulo, descricao,
                conciliacao_id, competencia_id, fundo_id, status
            )
            values (
                v_cond,
                'divergencia'::public.tipo_pendencia,
                'sistema'::public.origem_pendencia,
                'alta'::public.gravidade_pendencia,
                'Divergência de conciliação por fundo',
                'A conciliação do fundo divergiu entre extrato e balancete.',
                (select c.id from public.conciliacoes c
                  where c.competencia_id = p_competencia_id
                    and c.fundo_id = r.fundo_id),
                p_competencia_id, r.fundo_id,
                'aberta'::public.status_pendencia
            );
        end if;
    end loop;

    -- Promove o status da competência se não houver divergência em nenhum fundo.
    if not exists (
        select 1 from public.conciliacoes c
         where c.competencia_id = p_competencia_id
           and c.status = 'divergente'
    ) then
        insert into public.status_competencia (
            competencia_id, fonte, status, atualizado_por
        )
        values (p_competencia_id,
                'balancete'::public.fonte_contabil,
                'conciliado'::public.status_fonte,
                public.fn_usuario_atual())
        on conflict (competencia_id, fonte) do update
            set status = 'conciliado'::public.status_fonte,
                atualizado_em = now(),
                atualizado_por = public.fn_usuario_atual();
    end if;

    return query
    select c.fundo_id, c.status, c.diferenca_creditos, c.diferenca_debitos
    from public.conciliacoes c
    where c.competencia_id = p_competencia_id
    order by c.fundo_id;
end;
$fn$;

-- ----------------------------------------------------------------------------
-- REVOKE EXPLÍCITO e GRANT (create or replace preserva os grants, mas o
-- REVOKE fica escrito aqui de propósito: objeto privilegiado nasce fechado).
-- ----------------------------------------------------------------------------
revoke all on function public.fn_registrar_pendencia(uuid, public.tipo_pendencia, public.origem_pendencia, public.gravidade_pendencia, text, text, uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.fn_responder_contestacao(uuid, text, public.status_contestacao) from public, anon, authenticated;
revoke all on function public.fn_gerar_url_anexo(uuid) from public, anon, authenticated;
revoke all on function public.fn_aprovar_staging(uuid, uuid[], jsonb) from public, anon, authenticated;
revoke all on function public.fn_reconciliar_competencia(uuid) from public, anon, authenticated;

grant execute on function public.fn_registrar_pendencia(uuid, public.tipo_pendencia, public.origem_pendencia, public.gravidade_pendencia, text, text, uuid, uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.fn_responder_contestacao(uuid, text, public.status_contestacao) to authenticated;
grant execute on function public.fn_gerar_url_anexo(uuid) to authenticated;
grant execute on function public.fn_aprovar_staging(uuid, uuid[], jsonb) to authenticated;
grant execute on function public.fn_reconciliar_competencia(uuid) to authenticated;
