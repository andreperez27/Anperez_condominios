-- ============================================================================
-- MIGRATION 013 — FASE 0: VISÕES AGREGADAS
-- ============================================================================
-- As visões agregadas são a superfície de leitura do LEITOR.
--
-- ⚠️ PONTO CRÍTICO: no Postgres, uma view roda com os privilégios do DONO da
-- view, não com os do usuário que consulta (a menos que se use
-- `security_invoker = true`). Uma view que faz `SELECT ... FROM lancamentos`
-- IGNORA as policies do `lancamentos` — e devolveria a soma de TODOS os
-- condomínios.
--
-- Por isso TODA view agregada tem:
--   1. `security_barrier = true` — impede "oracular" o conteúdo linha a linha
--      através de funções qualificadas no filtro do usuário;
--   2. filtro de tenant EXPLÍCITO dentro da view — `condominio_id in (select
--      condominio_id from fn_condominios_do_usuario())`;
--   3. NENHUMA coluna de identificação (unidade, documento, histórico).
--
-- Detalhe importante: v_resumo_competencia_fundo e v_resultado_bruto somam
-- TODOS os lançamentos, inclusive os de unidade — porque são agregados. É
-- exatamente o que o leitor pode ver. Nenhuma delas expõe linha individual.
--
-- Documento de referência: docs\SEGURANCA_RLS.md §1.3 e §5
-- ============================================================================

-- ----------------------------------------------------------------------------
-- v_resumo_competencia_fundo — o painel do mês
-- ----------------------------------------------------------------------------
create or replace view public.v_resumo_competencia_fundo
with (security_barrier = true) as
select
    l.condominio_id,
    c.ano,
    c.mes,
    l.fundo_id,
    f.nome                                          as fundo_nome,
    f.natureza                                      as fundo_natureza,
    count(*)                                        as qtd_lancamentos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
    sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito')
      - sum(l.valor) filter (where l.tipo_movimento = 'debito') as saldo_movimento
from public.lancamentos l
join public.competencias c on c.id = l.competencia_id
join public.fundos f       on f.id = l.fundo_id
where l.status = 'ativo'
  and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
group by l.condominio_id, c.ano, c.mes, l.fundo_id, f.nome, f.natureza;

comment on view public.v_resumo_competencia_fundo is
    'Agregado por competência e fundo. Superfície de leitura do leitor. '
    'Filtro de tenant dentro da view (o RLS do dono não se aplica).';

-- ----------------------------------------------------------------------------
-- v_resumo_competencia_rubrica
-- ----------------------------------------------------------------------------
create or replace view public.v_resumo_competencia_rubrica
with (security_barrier = true) as
select
    l.condominio_id,
    c.ano,
    c.mes,
    r.id                                            as rubrica_id,
    r.nome                                          as rubrica_nome,
    r.natureza                                      as rubrica_natureza,
    count(*)                                        as qtd_lancamentos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
    sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos
from public.lancamentos l
join public.competencias c      on c.id = l.competencia_id
join public.lancamento_rubrica lr on lr.lancamento_id = l.id
join public.rubricas r          on r.id = lr.rubrica_id
where l.status = 'ativo'
  and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
group by l.condominio_id, c.ano, c.mes, r.id, r.nome, r.natureza;

comment on view public.v_resumo_competencia_rubrica is
    'Agregado por competência e rubrica. Superfície de leitura do leitor.';

-- ----------------------------------------------------------------------------
-- v_resultado_bruto — o padrão: soma TUDO, não subtrai nada
-- ----------------------------------------------------------------------------
-- ⚠️ Esta é a visão padrão do consolidado. Ela NÃO desconta transferências
-- internas, mesmo que estejam confirmadas. A razão: se o consolidado padrão
-- já desconta, um erro de classificação ESCONDE dinheiro real. Com as duas
-- visões, o erro aparece como diferença explícita no painel.
create or replace view public.v_resultado_bruto
with (security_barrier = true) as
select
    l.condominio_id,
    c.ano,
    c.mes,
    count(*)                                        as qtd_lancamentos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
    sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito')
      - sum(l.valor) filter (where l.tipo_movimento = 'debito') as resultado
from public.lancamentos l
join public.competencias c on c.id = l.competencia_id
where l.status = 'ativo'
  and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
group by l.condominio_id, c.ano, c.mes;

comment on view public.v_resultado_bruto is
    'Resultado BRUTO: soma todos os lançamentos, incluindo transferências '
    'internas. É o padrão — nunca subtrai nada por conta própria.';

-- ----------------------------------------------------------------------------
-- v_resultado_liquido — desconta transferências CONFIRMADAS
-- ----------------------------------------------------------------------------
-- A exclusão depende da ÚNICA fonte de verdade do estado:
-- transferencias_internas.status = 'confirmada'.
create or replace view public.v_resultado_liquido
with (security_barrier = true) as
select
    l.condominio_id,
    c.ano,
    c.mes,
    count(*)                                        as qtd_lancamentos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
    sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito')
      - sum(l.valor) filter (where l.tipo_movimento = 'debito') as resultado,
    -- Transferências ainda em análise: valores que o líquido NÃO desconta.
    coalesce((
        select sum(t.valor)
        from public.transferencias_internas t
        join public.competencias ct on ct.id = t.competencia_id
        where t.condominio_id = l.condominio_id
          and ct.ano = c.ano
          and ct.mes = c.mes
          and t.status = 'sugerida'
    ), 0) as transferencias_pendentes,
    coalesce((
        select sum(t.valor)
        from public.transferencias_internas t
        join public.competencias ct on ct.id = t.competencia_id
        where t.condominio_id = l.condominio_id
          and ct.ano = c.ano
          and ct.mes = c.mes
          and t.status = 'confirmada'
    ), 0) as transferencias_confirmadas
from public.lancamentos l
join public.competencias c on c.id = l.competencia_id
where l.status = 'ativo'
  and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
group by l.condominio_id, c.ano, c.mes;

comment on view public.v_resultado_liquido is
    'Resultado LÍQUIDO: desconta apenas transferências internas CONFIRMADAS. '
    'Mostra também as pendentes, para a diferença ficar explícita.';

-- ----------------------------------------------------------------------------
-- v_resultado_liquido_por_fundo
-- ----------------------------------------------------------------------------
create or replace view public.v_resultado_liquido_por_fundo
with (security_barrier = true) as
select
    l.condominio_id,
    c.ano,
    c.mes,
    l.fundo_id,
    f.nome                                          as fundo_nome,
    count(*)                                        as qtd_lancamentos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
    sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito')
      - sum(l.valor) filter (where l.tipo_movimento = 'debito') as resultado
from public.lancamentos l
join public.competencias c on c.id = l.competencia_id
join public.fundos f       on f.id = l.fundo_id
where l.status = 'ativo'
  and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
  -- desconta a ponta de destino das transferências confirmadas
  and not exists (
        select 1
        from public.transferencias_internas t
        where t.lancamento_destino_id = l.id
          and t.status = 'confirmada'
      )
group by l.condominio_id, c.ano, c.mes, l.fundo_id, f.nome;

comment on view public.v_resultado_liquido_por_fundo is
    'Saldo por fundo, descontando transferências confirmadas.';

-- ----------------------------------------------------------------------------
-- v_cobertura_competencias — o que falta para fechar o mês
-- ----------------------------------------------------------------------------
create or replace view public.v_cobertura_competencias
with (security_barrier = true) as
select
    c.condominio_id,
    c.ano,
    c.mes,
    c.id                                             as competencia_id,
    c.data_inicio,
    c.data_fim,
    c.fechada_em,
    f.fonte,
    coalesce(sc.status, 'sem_fonte'::public.status_fonte) as status,
    sc.observacao
from public.competencias c
cross join lateral (
    select unnest(enum_range(null::public.fonte_contabil)) as fonte
) f
left join public.status_competencia sc
       on sc.competencia_id = c.id
      and sc.fonte = f.fonte
where c.condominio_id in (select condominio_id from public.fn_condominios_do_usuario());

comment on view public.v_cobertura_competencias is
    'Status de cada competência POR FONTE. "sem_fonte" é lacuna sinalizada, '
    'não mês vazio.';

-- ----------------------------------------------------------------------------
-- v_conciliacao
-- ----------------------------------------------------------------------------
create or replace view public.v_conciliacao
with (security_barrier = true) as
select
    cc.condominio_id,
    c.ano,
    c.mes,
    cc.fundo_id,
    f.nome                                          as fundo_nome,
    cc.status,
    cc.creditos_extrato,
    cc.debitos_extrato,
    cc.creditos_balancete,
    cc.debitos_balancete,
    cc.diferenca_creditos,
    cc.diferenca_debitos,
    cc.observacao
from public.conciliacoes cc
join public.competencias c on c.id = cc.competencia_id
join public.fundos f       on f.id = cc.fundo_id
where cc.condominio_id in (select condominio_id from public.fn_condominios_do_usuario());

-- ----------------------------------------------------------------------------
-- v_pendencias_resumo — o leitor vê a CONTAGEM, não o detalhe
-- ----------------------------------------------------------------------------
create or replace view public.v_pendencias_resumo
with (security_barrier = true) as
select
    p.condominio_id,
    p.tipo,
    p.gravidade,
    p.status,
    count(*)                                        as qtd,
    min(p.criada_em)                                as mais_antiga,
    max(p.criada_em)                                as mais_recente
from public.pendencias p
where p.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
group by p.condominio_id, p.tipo, p.gravidade, p.status;

comment on view public.v_pendencias_resumo is
    'CONTAGEM de pendências por tipo/gravidade. O leitor não vê o detalhe '
    '(que poderia apontar uma unidade específica).';

-- ----------------------------------------------------------------------------
-- v_serie_historica
-- ----------------------------------------------------------------------------
create or replace view public.v_serie_historica
with (security_barrier = true) as
select
    s.condominio_id,
    s.ano,
    s.mes,
    s.bloco,
    s.rubrica_alias,
    s.rubrica_id,
    s.fundo_id,
    s.saldo_anterior,
    s.creditos,
    s.debitos,
    s.saldo
from public.serie_historica_resumo s
where s.condominio_id in (select condominio_id from public.fn_condominios_do_usuario());

-- ----------------------------------------------------------------------------
-- v_transferencias_internas — só auditor e conselho fiscal
-- ----------------------------------------------------------------------------
create or replace view public.v_transferencias_internas
with (security_barrier = true) as
select
    t.condominio_id,
    c.ano,
    c.mes,
    t.id                                             as transferencia_id,
    t.grupo_id,
    t.fundo_origem_id,
    fo.nome                                          as fundo_origem,
    t.fundo_destino_id,
    fd.nome                                          as fundo_destino,
    t.valor,
    t.status,
    t.regra,
    t.confianca,
    t.justificativa,
    t.lancamento_origem_id,
    t.lancamento_destino_id,
    t.decidido_em
from public.transferencias_internas t
join public.competencias c on c.id = t.competencia_id
join public.fundos fo on fo.id = t.fundo_origem_id
join public.fundos fd on fd.id = t.fundo_destino_id
where t.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
  and (
        public.fn_e_membro(t.condominio_id, 'auditor')
     or public.fn_e_membro(t.condominio_id, 'conselho_fiscal')
  );

-- ----------------------------------------------------------------------------
-- v_duplicatas_candidatas — só auditor
-- ----------------------------------------------------------------------------
create or replace view public.v_duplicatas_candidatas
with (security_barrier = true) as
select
    d.condominio_id,
    c.ano,
    c.mes,
    d.id                                             as duplicata_id,
    d.criterio,
    d.tupla_comum,
    d.status,
    d.pareceres,
    d.lancamento_a_id,
    d.lancamento_b_id,
    d.decidido_em
from public.duplicatas_candidatas d
left join public.lancamentos la on la.id = d.lancamento_a_id
left join public.lancamentos lb on lb.id = d.lancamento_b_id
left join public.competencias c on c.id = coalesce(la.competencia_id, lb.competencia_id)
where d.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
  and public.fn_e_membro(d.condominio_id, 'auditor');

-- ----------------------------------------------------------------------------
-- v_lancamentos_com_duplicata — a linha repetida, marcada
-- ----------------------------------------------------------------------------
create or replace view public.v_lancamentos_com_duplicata
with (security_barrier = true) as
select
    l.condominio_id,
    c.ano,
    c.mes,
    l.id                                             as lancamento_id,
    l.linha_origem,
    l.numero_ocorrencia,
    l.arquivo_nome,
    l.historico,
    l.valor,
    l.tipo_movimento,
    l.unidade_id,
    d.id                                             as duplicata_id,
    d.criterio,
    d.status                                         as status_duplicata
from public.lancamentos l
join public.competencias c on c.id = l.competencia_id
left join public.duplicatas_candidatas d
       on d.lancamento_a_id = l.id or d.lancamento_b_id = l.id
where l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
  and public.fn_e_membro(l.condominio_id, 'auditor');

-- ----------------------------------------------------------------------------
-- v_contestacoes
-- ----------------------------------------------------------------------------
create or replace view public.v_contestacoes
with (security_barrier = true) as
select
    t.condominio_id,
    t.id                                             as contestacao_id,
    t.lancamento_id,
    t.pendencia_id,
    t.tipo,
    t.texto,
    t.status,
    t.autor_id,
    t.criado_em,
    t.resposta,
    t.respondida_por,
    t.respondida_em
from public.contestacoes t
where t.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
  and (
        public.fn_e_membro(t.condominio_id, 'auditor')
     or public.fn_e_membro(t.condominio_id, 'sindico')
     or public.fn_e_membro(t.condominio_id, 'conselho_fiscal')
  );

-- ----------------------------------------------------------------------------
-- v_importacao_resumo — o leitor vê o resultado, não o staging
-- ----------------------------------------------------------------------------
create or replace view public.v_importacao_resumo
with (security_barrier = true) as
select
    f.condominio_id,
    f.fonte,
    f.status                                        as status_fonte,
    count(*)                                        as qtd_fontes,
    count(distinct f.competencia_id)                as qtd_competencias,
    sum(i.linhas_lidas)                             as linhas_lidas,
    sum(i.linhas_novas)                             as linhas_novas,
    sum(i.linhas_atualizadas)                       as linhas_atualizadas,
    sum(i.linhas_rejeitadas)                        as linhas_rejeitadas
from public.fontes_importacao f
left join public.importacoes i on i.fonte_id = f.id
where f.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
group by f.condominio_id, f.fonte, f.status;

-- ----------------------------------------------------------------------------
-- OWNER E GRANTS
-- ----------------------------------------------------------------------------
-- As views são do app_owner (BYPASSRLS) — por isso o filtro de tenant
-- dentro delas é OBRIGATÓRIO e não redundante.
alter view public.v_resumo_competencia_fundo     owner to app_owner;
alter view public.v_resumo_competencia_rubrica   owner to app_owner;
alter view public.v_resultado_bruto             owner to app_owner;
alter view public.v_resultado_liquido           owner to app_owner;
alter view public.v_resultado_liquido_por_fundo owner to app_owner;
alter view public.v_cobertura_competencias      owner to app_owner;
alter view public.v_conciliacao                  owner to app_owner;
alter view public.v_pendencias_resumo           owner to app_owner;
alter view public.v_serie_historica              owner to app_owner;
alter view public.v_transferencias_internas      owner to app_owner;
alter view public.v_duplicatas_candidatas        owner to app_owner;
alter view public.v_lancamentos_com_duplicata    owner to app_owner;
alter view public.v_contestacoes                 owner to app_owner;
alter view public.v_importacao_resumo           owner to app_owner;

-- Revoga tudo e concede apenas o que o leitor pode usar.
revoke all on public.v_resumo_competencia_fundo     from public, anon, authenticated;
revoke all on public.v_resumo_competencia_rubrica   from public, anon, authenticated;
revoke all on public.v_resultado_bruto             from public, anon, authenticated;
revoke all on public.v_resultado_liquido           from public, anon, authenticated;
revoke all on public.v_resultado_liquido_por_fundo from public, anon, authenticated;
revoke all on public.v_cobertura_competencias      from public, anon, authenticated;
revoke all on public.v_conciliacao                  from public, anon, authenticated;
revoke all on public.v_pendencias_resumo           from public, anon, authenticated;
revoke all on public.v_serie_historica              from public, anon, authenticated;
revoke all on public.v_transferencias_internas      from public, anon, authenticated;
revoke all on public.v_duplicatas_candidatas        from public, anon, authenticated;
revoke all on public.v_lancamentos_com_duplicata    from public, anon, authenticated;
revoke all on public.v_contestacoes                 from public, anon, authenticated;
revoke all on public.v_importacao_resumo           from public, anon, authenticated;

-- Agregadas: liberadas a todos (o filtro de tenant está dentro da view).
grant select on public.v_resumo_competencia_fundo     to authenticated;
grant select on public.v_resumo_competencia_rubrica   to authenticated;
grant select on public.v_resultado_bruto             to authenticated;
grant select on public.v_resultado_liquido           to authenticated;
grant select on public.v_resultado_liquido_por_fundo to authenticated;
grant select on public.v_cobertura_competencias      to authenticated;
grant select on public.v_conciliacao                  to authenticated;
grant select on public.v_pendencias_resumo           to authenticated;
grant select on public.v_serie_historica              to authenticated;
grant select on public.v_importacao_resumo           to authenticated;

-- De detalhe: liberadas a todos, mas a POLICY interna restringe por papel.
grant select on public.v_transferencias_internas      to authenticated;
grant select on public.v_duplicatas_candidatas        to authenticated;
grant select on public.v_lancamentos_com_duplicata    to authenticated;
grant select on public.v_contestacoes                 to authenticated;
