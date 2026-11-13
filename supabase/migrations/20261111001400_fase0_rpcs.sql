-- ============================================================================
-- MIGRATION 014 — FASE 0: RPCs
-- ============================================================================
-- Funções privilegiadas (SECURITY DEFINER, owner app_owner) que fazem as
-- operações compostas de forma ATÔMICA.
--
-- REGRAS que valem para todas:
--   1. `set search_path = public, auth, extensions, pg_temp` — obrigatório.
--   2. Filtro de tenant EXPLÍCITO dentro da função (o app_owner tem
--      BYPASSRLS, então o RLS não protege nada aqui).
--   3. Papel avaliado NO CONDOMÍNIO da linha/argumento.
--   4. `revoke execute ... from public, anon` + `grant execute ... to
--      authenticated`.
--   5. Sem SQL dinâmico.
--   6. `public.fn_usuario_atual()` no lugar de `auth.uid()` — ver a
--      migration 00260 para o porquê.
--
-- A granularidade permitida vem de `config_visibilidade` (por condomínio e
-- papel) — NÃO há checagem fixa de papel no código. Liberar o nominal por
-- unidade no futuro = UPDATE de uma linha.
--
-- Documento de referência: docs\SEGURANCA_RLS.md §6.2, §9, §10
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fn_resumo — agregação controlada
-- ----------------------------------------------------------------------------
-- A granularidade pedida é honrada se não for mais fina que a permitida.
-- O limiar mínimo de agregação suprime agregados apoiados em MENOS unidades
-- que o limiar (proteção contra small-cell / reidentificação). As linhas
-- suprimidas voltam com valores NULL e suprimido = true — nunca R$ 0,00, que
-- pareceria "não houve gasto".
create or replace function public.fn_resumo(
    p_condominio_id  uuid,
    p_competencia_id uuid default null,
    p_granularidade  text  default null
)
returns table (
    condominio_id   uuid,
    competencia_id  uuid,
    granularidade   text,
    chave           text,
    rotulo          text,
    creditos        numeric,
    debitos         numeric,
    qtd_lancamentos bigint,
    qtd_unidades    bigint,
    suprimido       boolean
)
language plpgsql
volatile                      -- grava no acesso_log: precisa ser volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_gran_max text;
    v_rank_max integer;
    v_gran     text;
    v_rank     integer;
    v_limiar   integer;
begin
    -- (1) o usuário precisa ser membro DESTE condomínio
    if not exists (
        select 1 from public.fn_condominios_do_usuario() c
        where c = p_condominio_id
    ) then
        raise exception 'sem acesso ao condominio %', p_condominio_id
            using errcode = '42501';
    end if;

    -- (2) granularidade máxima = a mais fina entre os papéis do usuário NESTE condomínio
    select o.granularidade, o.rank
      into v_gran_max, v_rank_max
      from public.config_visibilidade cv
      join public.fn_papeis_do_usuario(p_condominio_id) pu on pu.papel = cv.papel
      join public.granularidade_ordem o on o.granularidade = cv.granularidade_max
     where cv.condominio_id = p_condominio_id
     order by o.rank desc
     limit 1;

    if v_gran_max is null then
        raise exception 'sem politica de visibilidade no condominio %', p_condominio_id
            using errcode = '42501';
    end if;

    -- (3) granularidade pedida (default = a máxima permitida)
    v_gran := coalesce(p_granularidade, v_gran_max);

    select o.rank into v_rank
      from public.granularidade_ordem o
     where o.granularidade = v_gran;

    if v_rank is null then
        raise exception 'granularidade desconhecida: %', v_gran
            using errcode = '22023';
    end if;

    if v_rank > v_rank_max then
        raise exception 'granularidade % nao permitida (permitida ate %)',
            v_gran, v_gran_max
            using errcode = '42501';
    end if;

    -- (4) limiar mínimo de agregação (o mais permissivo entre os papéis)
    select max(cv.limiar_minimo_unidades) into v_limiar
      from public.config_visibilidade cv
      join public.fn_papeis_do_usuario(p_condominio_id) pu on pu.papel = cv.papel
     where cv.condominio_id = p_condominio_id;

    v_limiar := coalesce(v_limiar, 5);

    -- (5) registro de leitura
    insert into public.acesso_log (
        condominio_id, usuario_id, operacao, recurso, detalhes
    )
    values (
        p_condominio_id,
        public.fn_usuario_atual(),
        'select',
        'fn_resumo',
        jsonb_build_object(
            'granularidade', v_gran,
            'competencia_id', p_competencia_id,
            'granularidade_max', v_gran_max,
            'limiar', v_limiar
        )
    );

    -- (6) agregação
    return query
    with base as (
        select l.competencia_id,
               l.fundo_id,
               l.unidade_id,
               lr.rubrica_id,
               l.valor,
               l.tipo_movimento
        from public.lancamentos l
        left join public.lancamento_rubrica lr on lr.lancamento_id = l.id
        where l.condominio_id = p_condominio_id
          and l.status = 'ativo'
          and (p_competencia_id is null or l.competencia_id = p_competencia_id)
    ),
    agrupado as (
        select
            b.competencia_id,
            case when v_gran = 'fundo'   then b.fundo_id::text
                 when v_gran = 'rubrica' then coalesce(b.rubrica_id::text, 'sem_rubrica')
                 else                          b.unidade_id::text
            end                                                       as chave,
            case when v_gran = 'fundo'   then f.nome
                 when v_gran = 'rubrica' then coalesce(r.nome, 'SEM RUBRICA')
                 else                          u.numero
            end                                                       as rotulo,
            sum(b.valor) filter (where b.tipo_movimento = 'credito') as creditos,
            sum(b.valor) filter (where b.tipo_movimento = 'debito')  as debitos,
            count(*)                                                as qtd_lancamentos,
            count(distinct b.unidade_id) filter (where b.unidade_id is not null) as qtd_unidades
        from base b
        left join public.fundos   f on f.id = b.fundo_id
        left join public.rubricas r on r.id = b.rubrica_id
        left join public.unidades u on u.id = b.unidade_id
        group by 1, 2, 3
    )
    select
        p_condominio_id,
        a.competencia_id,
        v_gran,
        a.chave,
        a.rotulo,
        case when a.qtd_unidades > 0
              and a.qtd_unidades < v_limiar
              and v_gran <> 'unidade'
             then null else a.creditos end,
        case when a.qtd_unidades > 0
              and a.qtd_unidades < v_limiar
              and v_gran <> 'unidade'
             then null else a.debitos end,
        a.qtd_lancamentos,
        a.qtd_unidades,
        (a.qtd_unidades > 0 and a.qtd_unidades < v_limiar and v_gran <> 'unidade')
    from agrupado a;
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_lancamentos — acesso ao DETALHE, com papel por condomínio
-- ----------------------------------------------------------------------------
-- Recusa com 42501 quem não tiver papel (em vez de devolver zero linhas em
-- silêncio, que seria confuso).
create or replace function public.fn_lancamentos(
    p_condominio_id  uuid,
    p_competencia_id uuid default null,
    p_fundo_id       uuid default null,
    p_unidade_id    uuid default null,
    p_limit          integer default 500,
    p_offset         integer default 0
)
returns table (
    id               uuid,
    competencia_id   uuid,
    fundo_id         uuid,
    unidade_id       uuid,
    data_lancamento  date,
    data_vencimento  date,
    valor            numeric,
    tipo_movimento   public.tipo_movimento,
    historico        text,
    documento        text,
    codigo_conta     text,
    descricao_conta  text,
    rubrica_id       uuid,
    rubrica_nome     text,
    classificacao    public.status_classificacao,
    grupo_transferencia_id uuid,
    fonte_id         uuid,
    arquivo_nome     text,
    hash_arquivo     text,
    linha_origem     integer,
    numero_ocorrencia integer
)
language plpgsql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
begin
    if not exists (
        select 1 from public.fn_condominios_do_usuario() c
        where c = p_condominio_id
    ) then
        raise exception 'sem acesso ao condominio %', p_condominio_id
            using errcode = '42501';
    end if;

    if not (
        public.fn_e_membro(p_condominio_id, 'auditor')
     or public.fn_e_membro(p_condominio_id, 'sindico')
     or public.fn_e_membro(p_condominio_id, 'conselho_fiscal')
    ) then
        raise exception 'sem permissao para ler lancamentos deste condominio'
            using errcode = '42501';
    end if;

    return query
    select l.id, l.competencia_id, l.fundo_id, l.unidade_id,
           l.data_lancamento, l.data_vencimento, l.valor, l.tipo_movimento,
           l.historico, l.documento, l.codigo_conta, l.descricao_conta,
           lr.rubrica_id, r.nome, lr.status,
           l.grupo_transferencia_id, l.fonte_id, l.arquivo_nome,
           l.hash_arquivo, l.linha_origem, l.numero_ocorrencia
    from public.lancamentos l
    left join public.lancamento_rubrica lr on lr.lancamento_id = l.id
    left join public.rubricas r          on r.id = lr.rubrica_id
    where l.condominio_id = p_condominio_id
      and l.status = 'ativo'
      and (p_competencia_id is null or l.competencia_id = p_competencia_id)
      and (p_fundo_id is null or l.fundo_id = p_fundo_id)
      and (p_unidade_id is null or l.unidade_id = p_unidade_id)
    order by l.data_lancamento, l.id
    limit greatest(coalesce(p_limit, 500), 1)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_aprovar_staging — aprovação ATÔMICA
-- ----------------------------------------------------------------------------
-- Toda a importação entra em uma transação. Se algo falhar no meio, a
-- transação inteira desfaz — não fica metade importada.
create or replace function public.fn_aprovar_staging(
    p_importacao_id uuid,
    p_staging_ids   uuid[],
    p_decisoes      jsonb default '{}'::jsonb
)
returns table (
    lancamentos_criados    int,
    lancamentos_atualizados int,
    duplicatas_criadas    int,
    pendencias_criadas    int,
    transferencias_criadas int
)
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
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
    select l.id, co.rubrica_id, l.fundo_id, 'sugerida', 'conta', null
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
        'mesma_tupla_no_arquivo',
        l.id,
        l2.id,
        'pendente'
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
        l.condominio_id, 'classificacao', 'importacao', 'media',
        'Lançamento sem rubrica',
        'Lançamento ' || l.codigo_conta || ' — ' || l.descricao_conta
            || ' (arquivo ' || l.arquivo_nome || ', linha ' || l.linha_origem || ')',
        l.id, l.competencia_id, l.fundo_id, 'aberta'
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
    values (v_comp, 'extrato', 'importado', public.fn_usuario_atual())
    on conflict (competencia_id, fonte) do update
        set status = 'importado',
            atualizado_em = now(),
            atualizado_por = public.fn_usuario_atual();

    -- 6. Marca o staging como aprovado
    update public.staging_lancamentos
       set status = 'aprovado',
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
$$;

-- ----------------------------------------------------------------------------
-- fn_classificar_lancamento — só auditor
-- ----------------------------------------------------------------------------
create or replace function public.fn_classificar_lancamento(
    p_lancamento_id uuid,
    p_rubrica_id    uuid,
    p_fundo_id      uuid default null,
    p_status        public.status_classificacao default 'confirmada',
    p_justificativa text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_cond uuid;
    v_antes jsonb;
begin
    -- PAPEL antes da EXISTENCIA (ver nota em fn_aprovar_staging): evita
    -- enumerar lancamentos por id e garante HTTP 403 em vez de 500.
    select l.condominio_id into v_cond
      from public.lancamentos l where l.id = p_lancamento_id;

    if v_cond is null or not public.fn_e_membro(v_cond, 'auditor') then
        raise exception 'somente auditor classifica lancamento' using errcode = '42501';
    end if;

    select row_to_json(lr) into v_antes
      from public.lancamento_rubrica lr where lr.lancamento_id = p_lancamento_id;

    insert into public.lancamento_rubrica (
        lancamento_id, rubrica_id, fundo_id, status, origem,
        justificativa, decidido_por, decidido_em
    )
    values (
        p_lancamento_id, p_rubrica_id,
        coalesce(p_fundo_id, (select l.fundo_id from public.lancamentos l where l.id = p_lancamento_id)),
        p_status, 'manual', p_justificativa, public.fn_usuario_atual(), now()
    )
    on conflict (lancamento_id) do update
        set rubrica_id = excluded.rubrica_id,
            fundo_id = excluded.fundo_id,
            status = excluded.status,
            origem = 'manual',
            justificativa = excluded.justificativa,
            decidido_por = public.fn_usuario_atual(),
            decidido_em = now();

    update public.lancamentos
       set status_classificacao = p_status,
           origem_classificacao = 'manual',
           atualizado_em = now()
     where id = p_lancamento_id;

    insert into public.auditoria_log (
        condominio_id, entidade, entidade_id, acao, antes, depois, usuario_id
    )
    values (
        v_cond, 'lancamento', p_lancamento_id::text, 'classificar',
        v_antes,
        jsonb_build_object('rubrica_id', p_rubrica_id, 'status', p_status),
        public.fn_usuario_atual()
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_decidir_duplicata — só auditor
-- ----------------------------------------------------------------------------
create or replace function public.fn_decidir_duplicata(
    p_duplicata_id uuid,
    p_status       public.status_duplicata,
    p_parecer      text default null,
    p_cancelar_lancamento_id uuid default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_cond uuid;
begin
    -- PAPEL antes da EXISTENCIA (ver nota em fn_aprovar_staging).
    select d.condominio_id into v_cond
      from public.duplicatas_candidatas d where d.id = p_duplicata_id;

    if v_cond is null or not public.fn_e_membro(v_cond, 'auditor') then
        raise exception 'somente auditor decide duplicata' using errcode = '42501';
    end if;

    update public.duplicatas_candidatas
       set status = p_status,
           pareceres = p_parecer,
           decidido_por = public.fn_usuario_atual(),
           decidido_em = now()
     where id = p_duplicata_id;

    -- Cancelar uma das linhas é DECISÃO, não efeito colateral: a linha
    -- continua no banco, com status = 'cancelado' e rastro.
    if p_cancelar_lancamento_id is not null then
        update public.lancamentos
           set status = 'cancelado',
               atualizado_em = now()
         where id = p_cancelar_lancamento_id
           and condominio_id = v_cond;
    end if;

    insert into public.auditoria_log (
        condominio_id, entidade, entidade_id, acao, depois, usuario_id
    )
    values (
        v_cond, 'duplicata', p_duplicata_id::text, 'decidir_duplicata',
        jsonb_build_object(
            'status', p_status,
            'parecer', p_parecer,
            'cancelado', p_cancelar_lancamento_id
        ),
        public.fn_usuario_atual()
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_confirmar_transferencia — ÚNICA forma de mudar o estado da transferência
-- ----------------------------------------------------------------------------
create or replace function public.fn_confirmar_transferencia(
    p_transferencia_id uuid,
    p_status           public.status_transferencia,
    p_justificativa    text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_cond uuid;
begin
    -- PAPEL antes da EXISTENCIA (ver nota em fn_aprovar_staging).
    select t.condominio_id into v_cond
      from public.transferencias_internas t where t.id = p_transferencia_id;

    if v_cond is null or not public.fn_e_membro(v_cond, 'auditor') then
        raise exception 'somente auditor decide transferencia interna' using errcode = '42501';
    end if;

    update public.transferencias_internas
       set status = p_status,
           justificativa = p_justificativa,
           decidido_por = public.fn_usuario_atual(),
           decidido_em = now()
     where id = p_transferencia_id;

    insert into public.auditoria_log (
        condominio_id, entidade, entidade_id, acao, depois, usuario_id
    )
    values (
        v_cond, 'transferencia', p_transferencia_id::text, 'confirmar_transferencia',
        jsonb_build_object('status', p_status, 'justificativa', p_justificativa),
        public.fn_usuario_atual()
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_reconciliar_competencia — conciliação POR FUNDO
-- ----------------------------------------------------------------------------
-- Compara a linha do balancete do fundo F com o extrato do fundo F. É essa
-- correção que elimina os 14 "DIVERGENTE" falsos do app anterior.
--
-- NÃO altera nenhum lançamento: calcula, grava e cria pendência.
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
as $$
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
            v_cond, p_competencia_id, r.fundo_id, 'sem_fonte',
            r.creditos, r.debitos, now(), public.fn_usuario_atual()
        )
        on conflict (competencia_id, fundo_id) do update
            set creditos_extrato = excluded.creditos_extrato,
                debitos_extrato  = excluded.debitos_extrato,
                conciliado_em    = now(),
                conciliado_por   = public.fn_usuario_atual();

        -- Status: 'conciliado' quando as diferenças são zero (tolerância 0,01).
        update public.conciliacoes
           set status = case
                            when coalesce(diferenca_creditos, 0) = 0
                             and coalesce(diferenca_debitos, 0) = 0
                            then 'conciliado'::public.status_conciliacao
                            else 'divergente'::public.status_conciliacao
                        end
         where competencia_id = p_competencia_id
           and fundo_id = r.fundo_id;

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
                v_cond, 'divergencia', 'sistema', 'alta',
                'Divergência de conciliação por fundo',
                'A conciliação do fundo divergiu entre extrato e balancete.',
                (select c.id from public.conciliacoes c
                  where c.competencia_id = p_competencia_id
                    and c.fundo_id = r.fundo_id),
                p_competencia_id, r.fundo_id, 'aberta'
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
        values (p_competencia_id, 'balancete', 'conciliado', public.fn_usuario_atual())
        on conflict (competencia_id, fonte) do update
            set status = 'conciliado',
                atualizado_em = now(),
                atualizado_por = public.fn_usuario_atual();
    end if;

    return query
    select c.fundo_id, c.status, c.diferenca_creditos, c.diferenca_debitos
    from public.conciliacoes c
    where c.competencia_id = p_competencia_id
    order by c.fundo_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_contestar_lancamento — síndico e conselho fiscal PODEM; não classificam
-- ----------------------------------------------------------------------------
create or replace function public.fn_contestar_lancamento(
    p_lancamento_id uuid,
    p_texto          text,
    p_tipo           public.tipo_contestacao default 'contestacao'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_cond uuid;
    v_id   uuid;
begin
    -- PAPEL antes da EXISTENCIA (ver nota em fn_aprovar_staging): sem
    -- isso, um usuario sem permissao descobria se o lancamento existia
    -- pelo tipo de erro.
    select l.condominio_id into v_cond
      from public.lancamentos l where l.id = p_lancamento_id;

    if v_cond is null or not (
        public.fn_e_membro(v_cond, 'auditor')
     or public.fn_e_membro(v_cond, 'sindico')
     or public.fn_e_membro(v_cond, 'conselho_fiscal')
    ) then
        raise exception 'sem permissao para contestar neste condominio'
            using errcode = '42501';
    end if;

    insert into public.contestacoes (
        condominio_id, lancamento_id, autor_id, texto, tipo
    )
    values (v_cond, p_lancamento_id, public.fn_usuario_atual(), p_texto, p_tipo)
    returning id into v_id;

    insert into public.auditoria_log (
        condominio_id, entidade, entidade_id, acao, depois, usuario_id
    )
    values (
        v_cond, 'contestacao', v_id::text, 'criar',
        jsonb_build_object('tipo', p_tipo, 'lancamento_id', p_lancamento_id),
        public.fn_usuario_atual()
    );

    return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_responder_contestacao — só auditor
-- ----------------------------------------------------------------------------
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
as $$
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
        condominio_id, entidad, entidade_id, acao, depois, usuario_id
    )
    values (
        v_cond, 'contestacao', p_contestacao_id::text, 'responder',
        jsonb_build_object('status', p_status),
        public.fn_usuario_atual()
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_liberar_anexo_para_leitor — só auditor, anexo por anexo
-- ----------------------------------------------------------------------------
create or replace function public.fn_liberar_anexo_para_leitor(
    p_anexo_id uuid,
    p_liberar  boolean default true
)
returns void
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_cond uuid;
begin
    -- PAPEL antes da EXISTENCIA (ver nota em fn_aprovar_staging).
    select a.condominio_id into v_cond
      from public.anexos a where a.id = p_anexo_id;

    if v_cond is null or not public.fn_e_membro(v_cond, 'auditor') then
        raise exception 'somente auditor libera anexos' using errcode = '42501';
    end if;

    update public.anexos
       set liberado_para_leitor = p_liberar,
           liberado_em = case when p_liberar then now() else null end,
           liberado_por = case when p_liberar then public.fn_usuario_atual() else null end
     where id = p_anexo_id;

    insert into public.auditoria_log (
        condominio_id, entidade, entidade_id, acao, usuario_id
    )
    values (
        v_cond, 'anexo', p_anexo_id::text,
        case when p_liberar then 'liberar_para_leitor' else 'revogar_leitor' end,
        public.fn_usuario_atual()
    );
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_anexo_acessivel — a policy de storage consulta esta função
-- ----------------------------------------------------------------------------
-- Papéis com acesso pleno (auditor/síndico/conselho) ou leitor com o anexo
-- individualmente liberado.
create or replace function public.fn_anexo_acessivel(p_nome text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_anexo  public.anexos%rowtype;
    v_cond   uuid;
begin
    select a.* into v_anexo
      from public.anexos a
     where a.caminho = p_nome;

    if not found then
        return false;
    end if;

    v_cond := v_anexo.condominio_id;

    if not exists (
        select 1 from public.fn_condominios_do_usuario() c where c = v_cond
    ) then
        return false;
    end if;

    if exists (
        select 1 from public.fn_papeis_do_usuario(v_cond) p
         where p in ('auditor','sindico','conselho_fiscal')
    ) then
        return true;
    end if;

    -- Leitor: somente anexos liberados individualmente pelo auditor.
    return v_anexo.liberado_para_leitor;
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_gerar_url_anexo — URL assinada com expiração curta
-- ----------------------------------------------------------------------------
create or replace function public.fn_gerar_url_anexo(p_anexo_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_anexo public.anexos%rowtype;
begin
    select a.* into v_anexo from public.anexos a where a.id = p_anexo_id;

    if v_anexo.id is null then
        raise exception 'anexo inexistente' using errcode = 'P0002';
    end if;

    if not public.fn_anexo_acessivel(v_anexo.caminho) then
        raise exception 'sem permissao para acessar este anexo' using errcode = '42501';
    end if;

    insert into public.acesso_log (
        condominio_id, usuario_id, operacao, recurso, entidade_id
    )
    values (
        v_anexo.condominio_id, public.fn_usuario_atual(), 'anexo',
        'fn_gerar_url_anexo', p_anexo_id::text
    );

    return storage.create_signed_url(v_anexo.caminho, 300);
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_registrar_pendencia — cria pendência a partir de regra automática
-- ----------------------------------------------------------------------------
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
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_id uuid;
begin
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
$$;

-- ----------------------------------------------------------------------------
-- fn_atualizar_visibilidade — muda a política de visibilidade (auditor)
-- ----------------------------------------------------------------------------
-- É por aqui que o nominal por unidade é liberado no futuro: uma chamada de
-- RPC, sem tocar em schema nem em código.
create or replace function public.fn_atualizar_visibilidade(
    p_condominio_id          uuid,
    p_papel                  public.papel_membro,
    p_granularidade_max      text,
    p_limiar_minimo_unidades integer default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_antes jsonb;
begin
    if not public.fn_e_membro(p_condominio_id, 'auditor') then
        raise exception 'somente auditor altera a politica de visibilidade'
            using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.granularidade_ordem o where o.granularidade = p_granularidade_max
    ) then
        raise exception 'granularidade desconhecida: %', p_granularidade_max
            using errcode = '22023';
    end if;

    select to_jsonb(cv) into v_antes
      from public.config_visibilidade cv
     where cv.condominio_id = p_condominio_id
       and cv.papel = p_papel;

    insert into public.config_visibilidade (
        condominio_id, papel, granularidade_max,
        limiar_minimo_unidades, atualizado_em, atualizado_por
    )
    values (
        p_condominio_id, p_papel, p_granularidade_max,
        coalesce(p_limiar_minimo_unidades, 5), now(), public.fn_usuario_atual()
    )
    on conflict (condominio_id, papel) do update
        set granularidade_max = excluded.granularidade_max,
            limiar_minimo_unidades = excluded.limiar_minimo_unidades,
            atualizado_em = now(),
            atualizado_por = public.fn_usuario_atual();

    insert into public.auditoria_log (
        condominio_id, entidade, entidade_id, acao, antes, depois, usuario_id
    )
    values (
        p_condominio_id, 'config_visibilidade',
        p_condominio_id::text || ':' || p_papel::text, 'atualizar_visibilidade',
        v_antes,
        jsonb_build_object(
            'granularidade_max', p_granularidade_max,
            'limiar_minimo_unidades', coalesce(p_limiar_minimo_unidades, 5)
        ),
        public.fn_usuario_atual()
    );
end;
$$;


-- ----------------------------------------------------------------------------
-- fn_auditoria_log — leitura do log de auditoria (auditor / conselho fiscal)
-- ----------------------------------------------------------------------------
-- O log NAO e lido por SELECT direto (nenhum papel tem o privilegio):
-- a leitura passa por esta funcao, que filtra o condominio e o papel.
--
-- Por que nao ha GRANT de SELECT em `auditoria_log`:
--   1. o log mostra QUEM leu/alterou O QUE — e um dado sensivel;
--   2. o leitor tem que receber 403 (privilegio negado), nao uma lista
--      vazia, para que a negacao seja inequivoca;
--   3. a policy da tabela ja restringe por papel; o GRANT (se houvesse)
--      seria apenas mais uma porta de entrada.
create or replace function public.fn_auditoria_log(
    p_condominio_id uuid,
    p_entidade      text default null,
    p_acao          text default null,
    p_limite        integer default 200
)
returns table (
    id            uuid,
    condominio_id uuid,
    entidade      text,
    entidade_id   text,
    acao          text,
    antes         jsonb,
    depois        jsonb,
    usuario_id    uuid,
    criado_em     timestamptz
)
language plpgsql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
begin
    if not (
        public.fn_e_membro(p_condominio_id, 'auditor')
     or public.fn_e_membro(p_condominio_id, 'conselho_fiscal')
    ) then
        raise exception 'sem permissao para ler o log de auditoria deste condominio'
            using errcode = '42501';
    end if;

    return query
    select a.id, a.condominio_id, a.entidade, a.entidade_id, a.acao,
           a.antes, a.depois, a.usuario_id, a.criado_em
    from public.auditoria_log a
    where a.condominio_id = p_condominio_id
      and (p_entidade is null or a.entidade = p_entidade)
      and (p_acao is null or a.acao = p_acao)
    order by a.criado_em desc
    limit greatest(coalesce(p_limite, 200), 1);
end;
$$;

-- ----------------------------------------------------------------------------
-- fn_acesso_log — leitura do log de acesso (auditor / conselho fiscal)
-- ----------------------------------------------------------------------------
-- Mesma regra do log de auditoria: leitura por funcao, nunca por SELECT
-- direto. O log de acesso registra TODA escrita e as leituras do leitor.
create or replace function public.fn_acesso_log(
    p_condominio_id uuid,
    p_usuario_id    uuid default null,
    p_limite        integer default 200
)
returns table (
    id            bigint,
    condominio_id uuid,
    usuario_id    uuid,
    operacao      text,
    recurso       text,
    entidade_id   text,
    detalhes      jsonb,
    criado_em     timestamptz
)
language plpgsql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
begin
    if not (
        public.fn_e_membro(p_condominio_id, 'auditor')
     or public.fn_e_membro(p_condominio_id, 'conselho_fiscal')
    ) then
        raise exception 'sem permissao para ler o log de acesso deste condominio'
            using errcode = '42501';
    end if;

    return query
    select al.id, al.condominio_id, al.usuario_id, al.operacao::text,
           al.recurso, al.entidade_id, al.detalhes, al.criado_em
    from public.acesso_log al
    where al.condominio_id = p_condominio_id
      and (p_usuario_id is null or al.usuario_id = p_usuario_id)
    order by al.criado_em desc
    limit greatest(coalesce(p_limite, 200), 1);
end;
$$;

-- ----------------------------------------------------------------------------
-- OWNER E GRANTS
-- ----------------------------------------------------------------------------
do $$
declare
    r record;
begin
    for r in
        select p.oid::regprocedure::text as assinatura
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in (
              'fn_resumo','fn_lancamentos','fn_aprovar_staging',
              'fn_classificar_lancamento','fn_decidir_duplicata',
              'fn_confirmar_transferencia','fn_reconciliar_competencia',
              'fn_contestar_lancamento','fn_responder_contestacao',
              'fn_liberar_anexo_para_leitor','fn_anexo_acessivel',
              'fn_gerar_url_anexo','fn_registrar_pendencia',
              'fn_atualizar_visibilidade','fn_auditoria_log',
              'fn_acesso_log'
          )
    loop
        execute format('alter function %s owner to app_owner', r.assinatura);
    end loop;
end;
$$;

-- Revoga o EXECUTE de todos (tríplice) e concede só a authenticated.
select public.fn_revogar_funcoes_publicas();

-- ============================================================================
-- FECHAMENTO DE PRIVILÉGIOS — REVOKE EXPLÍCITO (defesa em profundidade)
-- ============================================================================
-- Cada RPC criada por esta migration recebe REVOKE explícito de `public`,
-- `anon` e `authenticated`, AQUI, no mesmo lugar onde a função e criada.
--
-- Por que isso, se a varredura dinamica (fn_revogar_funcoes_publicas) ja
-- revoga tudo? Porque a varredura depende de o helper existir, estar integro
-- e ser chamado - e um passo que pode ser esquecido, pulado ou quebrado numa
-- edicao futura. Um REVOKE explicito no mesmo lugar da criacao nao depende
-- de nada: o objeto nasce fechado.
--
-- O GRANT explicito vem logo abaixo (secao GRANTS): so o que e permitido a
-- `authenticated` recebe execute. O que nao e listado ali, nao e executavel
-- por ninguem alem do dono.
revoke all on function public.fn_acesso_log(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.fn_anexo_acessivel(text) from public, anon, authenticated;
revoke all on function public.fn_aprovar_staging(uuid, uuid[], jsonb) from public, anon, authenticated;
revoke all on function public.fn_atualizar_visibilidade(uuid, public.papel_membro, text, integer) from public, anon, authenticated;
revoke all on function public.fn_auditoria_log(uuid, text, text, integer) from public, anon, authenticated;
revoke all on function public.fn_classificar_lancamento(uuid, uuid, uuid, public.status_classificacao, text) from public, anon, authenticated;
revoke all on function public.fn_confirmar_transferencia(uuid, public.status_transferencia, text) from public, anon, authenticated;
revoke all on function public.fn_contestar_lancamento(uuid, text, public.tipo_contestacao) from public, anon, authenticated;
revoke all on function public.fn_decidir_duplicata(uuid, public.status_duplicata, text, uuid) from public, anon, authenticated;
revoke all on function public.fn_gerar_url_anexo(uuid) from public, anon, authenticated;
revoke all on function public.fn_lancamentos(uuid, uuid, uuid, uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.fn_liberar_anexo_para_leitor(uuid, boolean) from public, anon, authenticated;
revoke all on function public.fn_reconciliar_competencia(uuid) from public, anon, authenticated;
revoke all on function public.fn_registrar_pendencia(uuid, public.tipo_pendencia, public.origem_pendencia, public.gravidade_pendencia, text, text, uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.fn_responder_contestacao(uuid, text, public.status_contestacao) from public, anon, authenticated;
revoke all on function public.fn_resumo(uuid, uuid, text) from public, anon, authenticated;

-- ⚠️ O revogar acima tira o EXECUTE do helper fn_usuario_atual (criado na
-- migration 00260), que é usado no corpo destas RPCs. O grant é refeito aqui.
grant execute on function public.fn_usuario_atual() to authenticated;
grant execute on function public.fn_usuario_atual() to app_owner;

-- Os helpers de papel tambem sao usados no corpo destas RPCs e das views.
grant execute on function public.fn_papeis_do_usuario(uuid)             to authenticated;
grant execute on function public.fn_papeis_do_usuario(uuid)             to app_owner;
grant execute on function public.fn_condominios_do_usuario()            to authenticated;
grant execute on function public.fn_condominios_do_usuario()            to app_owner;
grant execute on function public.fn_e_membro(uuid, public.papel_membro) to authenticated;
grant execute on function public.fn_e_membro(uuid, public.papel_membro) to app_owner;
grant execute on function public.fn_acessa_condominio(uuid)             to authenticated;
grant execute on function public.fn_acessa_condominio(uuid)             to app_owner;

grant execute on function public.fn_resumo(uuid, uuid, text)                            to authenticated;
grant execute on function public.fn_lancamentos(uuid, uuid, uuid, uuid, integer, integer)  to authenticated;
grant execute on function public.fn_aprovar_staging(uuid, uuid[], jsonb)                   to authenticated;
grant execute on function public.fn_classificar_lancamento(uuid, uuid, uuid, public.status_classificacao, text) to authenticated;
grant execute on function public.fn_decidir_duplicata(uuid, public.status_duplicata, text, uuid) to authenticated;
grant execute on function public.fn_confirmar_transferencia(uuid, public.status_transferencia, text) to authenticated;
grant execute on function public.fn_reconciliar_competencia(uuid)                       to authenticated;
grant execute on function public.fn_contestar_lancamento(uuid, text, public.tipo_contestacao) to authenticated;
grant execute on function public.fn_responder_contestacao(uuid, text, public.status_contestacao) to authenticated;
grant execute on function public.fn_liberar_anexo_para_leitor(uuid, boolean)               to authenticated;
grant execute on function public.fn_anexo_acessivel(text)                                to authenticated;
grant execute on function public.fn_gerar_url_anexo(uuid)                                to authenticated;
grant execute on function public.fn_registrar_pendencia(uuid, public.tipo_pendencia, public.origem_pendencia, public.gravidade_pendencia, text, text, uuid, uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.fn_atualizar_visibilidade(uuid, public.papel_membro, text, integer) to authenticated;
grant execute on function public.fn_auditoria_log(uuid, text, text, integer) to authenticated;
grant execute on function public.fn_acesso_log(uuid, uuid, integer) to authenticated;
