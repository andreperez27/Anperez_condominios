-- ============================================================================
-- MIGRATION 018 — FASE 0: VIEWS AGREGADAS — LIMIAR, GRANULARIDADE E OBSERVAÇÃO
-- ============================================================================
-- Encontrado ao montar a matriz view x papel com dados fictícios (12/11/2026):
--
-- 1. As views AGREGADAS ignoravam `config_visibilidade`: o leitor (política
--    `granularidade_max = 'fundo'`, limiar 5) lia as 3 linhas de
--    `v_resumo_competencia_rubrica` — inclusive a célula PEQUENA "Multas"
--    (2 unidades, R$ 30,00), que `fn_resumo` suprimia via limiar.
--    Correção: a política passa a ser lida DENTRO da view, como em
--    `fn_resumo` (o dono da view não é filtrado por RLS).
--
-- 2. Colunas de TEXTO LIVRE escritas pelo auditor (`observacao` de
--    conciliação e de status de competência — ex.: "unidade 11 não enviou
--    extrato") eram devolvidas ao leitor. Correção: `observacao` só é
--    devolvida a quem tem papel NOMINAL no condomínio (auditor, síndico
--    ou conselho fiscal); para o leitor, volta NULL.
--
-- 3. `v_resumo_competencia_fundo` e `v_resultado_liquido_por_fundo` (e
--    `v_resultado_bruto`/`v_resultado_liquido`, por consistência) passam a
--    suprimir os valores quando a célula cobre entre 1 e limiar-1 unidades
--    ligadas a unidade (mesma regra do fn_resumo: `0 < qtd_unidades <
--    limiar`). Agregados sem unidade nenhuma nunca são suprimidos.
--
-- 4. `v_serie_historica` é série por `rubrica_alias` (granularidade
--    rubrica). Passa a valer o mesmo gate de granularidade da view de
--    rubrica: o leitor (máximo `fundo`) recebe 0 linhas.
--
-- Regra de supressão (idêntica a fn_resumo): a célula volta com
-- créditos/débitos (e resultado/transferências) NULL e `suprimido = true`;
-- `qtd_lancamentos` e as demais colunas de dimensão continuam visíveis.
-- Nunca R$ 0,00 no lugar de suprimido.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- v_resumo_competencia_fundo (+ qtd_unidades, suprimido)
-- ----------------------------------------------------------------------------
create or replace view public.v_resumo_competencia_fundo
with (security_barrier = true) as
with cells as (
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
        count(distinct l.unidade_id) filter (where l.unidade_id is not null) as qtd_unidades
    from public.lancamentos l
    join public.competencias c on c.id = l.competencia_id
    join public.fundos f       on f.id = l.fundo_id
    where l.status = 'ativo'
      and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
    group by l.condominio_id, c.ano, c.mes, l.fundo_id, f.nome, f.natureza
),
pol as (
    select c.condominio_id,
           coalesce(max(cv.limiar_minimo_unidades), 5) as limiar
      from (select distinct condominio_id from cells) c
      left join (
            select cv.condominio_id, cv.limiar_minimo_unidades
              from public.config_visibilidade cv
              join public.fn_papeis_do_usuario(cv.condominio_id) pu
                on pu.papel = cv.papel
      ) cv on cv.condominio_id = c.condominio_id
     group by c.condominio_id
)
select
    s.condominio_id,
    s.ano,
    s.mes,
    s.fundo_id,
    s.fundo_nome,
    s.fundo_natureza,
    s.qtd_lancamentos,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.creditos end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.debitos  end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null
         else s.creditos - s.debitos end                     as saldo_movimento,
    s.qtd_unidades,
    (s.qtd_unidades > 0 and s.qtd_unidades < p.limiar)       as suprimido
from cells s
join pol p on p.condominio_id = s.condominio_id;

-- ----------------------------------------------------------------------------
-- v_resumo_competencia_rubrica (+ gate de granularidade, qtd_unidades, suprimido)
-- ----------------------------------------------------------------------------
create or replace view public.v_resumo_competencia_rubrica
with (security_barrier = true) as
with cells as (
    select
        l.condominio_id,
        c.ano,
        c.mes,
        r.id                                            as rubrica_id,
        r.nome                                          as rubrica_nome,
        r.natureza                                      as rubrica_natureza,
        count(*)                                        as qtd_lancamentos,
        sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
        sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
        count(distinct l.unidade_id) filter (where l.unidade_id is not null) as qtd_unidades
    from public.lancamentos l
    join public.competencias c      on c.id = l.competencia_id
    join public.lancamento_rubrica lr on lr.lancamento_id = l.id
    join public.rubricas r          on r.id = lr.rubrica_id
    where l.status = 'ativo'
      and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
    group by l.condominio_id, c.ano, c.mes, r.id, r.nome, r.natureza
),
pol as (
    select c.condominio_id,
           coalesce(max(cv.limiar_minimo_unidades), 5) as limiar,
           coalesce(max(cv.rank), 0)                   as rank_max
      from (select distinct condominio_id from cells) c
      left join (
            select cv.condominio_id, cv.limiar_minimo_unidades, o.rank
              from public.config_visibilidade cv
              join public.fn_papeis_do_usuario(cv.condominio_id) pu
                on pu.papel = cv.papel
              join public.granularidade_ordem o
                on o.granularidade = cv.granularidade_max
      ) cv on cv.condominio_id = c.condominio_id
     group by c.condominio_id
)
select
    s.condominio_id,
    s.ano,
    s.mes,
    s.rubrica_id,
    s.rubrica_nome,
    s.rubrica_natureza,
    s.qtd_lancamentos,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.creditos end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.debitos  end,
    s.qtd_unidades,
    (s.qtd_unidades > 0 and s.qtd_unidades < p.limiar)       as suprimido
from cells s
join pol p on p.condominio_id = s.condominio_id
where p.rank_max >= (select rank from public.granularidade_ordem
                      where granularidade = 'rubrica');

-- ----------------------------------------------------------------------------
-- v_resultado_bruto (+ qtd_unidades, suprimido)
-- ----------------------------------------------------------------------------
create or replace view public.v_resultado_bruto
with (security_barrier = true) as
with cells as (
    select
        l.condominio_id,
        c.ano,
        c.mes,
        count(*)                                        as qtd_lancamentos,
        sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
        sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
        count(distinct l.unidade_id) filter (where l.unidade_id is not null) as qtd_unidades
    from public.lancamentos l
    join public.competencias c on c.id = l.competencia_id
    where l.status = 'ativo'
      and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
    group by l.condominio_id, c.ano, c.mes
),
pol as (
    select c.condominio_id,
           coalesce(max(cv.limiar_minimo_unidades), 5) as limiar
      from (select distinct condominio_id from cells) c
      left join (
            select cv.condominio_id, cv.limiar_minimo_unidades
              from public.config_visibilidade cv
              join public.fn_papeis_do_usuario(cv.condominio_id) pu
                on pu.papel = cv.papel
      ) cv on cv.condominio_id = c.condominio_id
     group by c.condominio_id
)
select
    s.condominio_id,
    s.ano,
    s.mes,
    s.qtd_lancamentos,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.creditos end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.debitos  end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null
         else s.creditos - s.debitos end                     as resultado,
    s.qtd_unidades,
    (s.qtd_unidades > 0 and s.qtd_unidades < p.limiar)       as suprimido
from cells s
join pol p on p.condominio_id = s.condominio_id;

-- ----------------------------------------------------------------------------
-- v_resultado_liquido (+ qtd_unidades, suprimido)
-- ----------------------------------------------------------------------------
create or replace view public.v_resultado_liquido
with (security_barrier = true) as
with cells as (
    select
        l.condominio_id,
        c.ano,
        c.mes,
        count(*)                                        as qtd_lancamentos,
        sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
        sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
        count(distinct l.unidade_id) filter (where l.unidade_id is not null) as qtd_unidades
    from public.lancamentos l
    join public.competencias c on c.id = l.competencia_id
    where l.status = 'ativo'
      and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
    group by l.condominio_id, c.ano, c.mes
),
pol as (
    select c.condominio_id,
           coalesce(max(cv.limiar_minimo_unidades), 5) as limiar
      from (select distinct condominio_id from cells) c
      left join (
            select cv.condominio_id, cv.limiar_minimo_unidades
              from public.config_visibilidade cv
              join public.fn_papeis_do_usuario(cv.condominio_id) pu
                on pu.papel = cv.papel
      ) cv on cv.condominio_id = c.condominio_id
     group by c.condominio_id
)
select
    s.condominio_id,
    s.ano,
    s.mes,
    s.qtd_lancamentos,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.creditos end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.debitos  end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null
         else s.creditos - s.debitos end                     as resultado,
    -- Transferências ainda em análise: valores que o líquido NÃO desconta.
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null
         else coalesce((
             select sum(t.valor)
             from public.transferencias_internas t
             join public.competencias ct on ct.id = t.competencia_id
             where t.condominio_id = s.condominio_id
               and ct.ano = s.ano
               and ct.mes = s.mes
               and t.status = 'sugerida'
         ), 0) end                                           as transferencias_pendentes,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null
         else coalesce((
             select sum(t.valor)
             from public.transferencias_internas t
             join public.competencias ct on ct.id = t.competencia_id
             where t.condominio_id = s.condominio_id
               and ct.ano = s.ano
               and ct.mes = s.mes
               and t.status = 'confirmada'
         ), 0) end                                           as transferencias_confirmadas,
    s.qtd_unidades,
    (s.qtd_unidades > 0 and s.qtd_unidades < p.limiar)       as suprimido
from cells s
join pol p on p.condominio_id = s.condominio_id;

-- ----------------------------------------------------------------------------
-- v_resultado_liquido_por_fundo (+ qtd_unidades, suprimido)
-- ----------------------------------------------------------------------------
create or replace view public.v_resultado_liquido_por_fundo
with (security_barrier = true) as
with cells as (
    select
        l.condominio_id,
        c.ano,
        c.mes,
        l.fundo_id,
        f.nome                                          as fundo_nome,
        count(*)                                        as qtd_lancamentos,
        sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
        sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
        count(distinct l.unidade_id) filter (where l.unidade_id is not null) as qtd_unidades
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
    group by l.condominio_id, c.ano, c.mes, l.fundo_id, f.nome
),
pol as (
    select c.condominio_id,
           coalesce(max(cv.limiar_minimo_unidades), 5) as limiar
      from (select distinct condominio_id from cells) c
      left join (
            select cv.condominio_id, cv.limiar_minimo_unidades
              from public.config_visibilidade cv
              join public.fn_papeis_do_usuario(cv.condominio_id) pu
                on pu.papel = cv.papel
      ) cv on cv.condominio_id = c.condominio_id
     group by c.condominio_id
)
select
    s.condominio_id,
    s.ano,
    s.mes,
    s.fundo_id,
    s.fundo_nome,
    s.qtd_lancamentos,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.creditos end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null else s.debitos  end,
    case when s.qtd_unidades > 0 and s.qtd_unidades < p.limiar then null
         else s.creditos - s.debitos end                     as resultado,
    s.qtd_unidades,
    (s.qtd_unidades > 0 and s.qtd_unidades < p.limiar)       as suprimido
from cells s
join pol p on p.condominio_id = s.condominio_id;

-- ----------------------------------------------------------------------------
-- v_serie_historica (gate de granularidade rubrica; sem vínculo com unidade)
-- ----------------------------------------------------------------------------
create or replace view public.v_serie_historica
with (security_barrier = true) as
with pol as (
    select c.condominio_id,
           coalesce(max(cv.rank), 0) as rank_max
      from (select distinct condominio_id from public.serie_historica_resumo
             where condominio_id in (select condominio_id from public.fn_condominios_do_usuario())) c
      left join (
            select cv.condominio_id, o.rank
              from public.config_visibilidade cv
              join public.fn_papeis_do_usuario(cv.condominio_id) pu
                on pu.papel = cv.papel
              join public.granularidade_ordem o
                on o.granularidade = cv.granularidade_max
      ) cv on cv.condominio_id = c.condominio_id
     group by c.condominio_id
)
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
join pol p on p.condominio_id = s.condominio_id
where p.rank_max >= (select rank from public.granularidade_ordem
                      where granularidade = 'rubrica');

-- ----------------------------------------------------------------------------
-- v_conciliacao (observacao só para papel nominal)
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
    case when public.fn_e_membro(cc.condominio_id, 'auditor')
          or public.fn_e_membro(cc.condominio_id, 'sindico')
          or public.fn_e_membro(cc.condominio_id, 'conselho_fiscal')
         then cc.observacao
    end                                             as observacao
from public.conciliacoes cc
join public.competencias c on c.id = cc.competencia_id
join public.fundos f       on f.id = cc.fundo_id
where cc.condominio_id in (select condominio_id from public.fn_condominios_do_usuario());

-- ----------------------------------------------------------------------------
-- v_cobertura_competencias (observacao só para papel nominal)
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
    case when public.fn_e_membro(c.condominio_id, 'auditor')
          or public.fn_e_membro(c.condominio_id, 'sindico')
          or public.fn_e_membro(c.condominio_id, 'conselho_fiscal')
         then sc.observacao
    end                                             as observacao
from public.competencias c
cross join lateral (
    select unnest(enum_range(null::public.fonte_contabil)) as fonte
) f
left join public.status_competencia sc
       on sc.competencia_id = c.id
      and sc.fonte = f.fonte
where c.condominio_id in (select condominio_id from public.fn_condominios_do_usuario());

-- ============================================================================
-- GRANTS / REVOKES (create or replace preserva os grants, mas o REVOKE
-- explícito fica escrito aqui de propósito: o objeto nasce fechado).
-- ============================================================================
revoke all on public.v_resumo_competencia_fundo     from public, anon, authenticated;
revoke all on public.v_resumo_competencia_rubrica   from public, anon, authenticated;
revoke all on public.v_resultado_bruto             from public, anon, authenticated;
revoke all on public.v_resultado_liquido           from public, anon, authenticated;
revoke all on public.v_resultado_liquido_por_fundo from public, anon, authenticated;
revoke all on public.v_cobertura_competencias      from public, anon, authenticated;
revoke all on public.v_conciliacao                  from public, anon, authenticated;
revoke all on public.v_serie_historica              from public, anon, authenticated;

grant select on public.v_resumo_competencia_fundo     to authenticated;
grant select on public.v_resumo_competencia_rubrica   to authenticated;
grant select on public.v_resultado_bruto             to authenticated;
grant select on public.v_resultado_liquido           to authenticated;
grant select on public.v_resultado_liquido_por_fundo to authenticated;
grant select on public.v_cobertura_competencias      to authenticated;
grant select on public.v_conciliacao                  to authenticated;
grant select on public.v_serie_historica              to authenticated;

comment on view public.v_resumo_competencia_fundo is
    'Agregado por competencia e fundo, com limiar de agregacao lido de config_visibilidade.';
comment on view public.v_resumo_competencia_rubrica is
    'Agregado por competencia e rubrica. Gate de granularidade e limiar lidos de config_visibilidade.';
comment on view public.v_resultado_bruto is
    'Resultado BRUTO (soma tudo). Limiar de agregacao lido de config_visibilidade.';
comment on view public.v_resultado_liquido is
    'Resultado LIQUIDO (desconta transferencias confirmadas). Limiar lido de config_visibilidade.';
comment on view public.v_resultado_liquido_por_fundo is
    'Saldo por fundo, descontando transferencias confirmadas. Limiar lido de config_visibilidade.';
comment on view public.v_serie_historica is
    'Serie historica por rubrica_alias. Gate de granularidade lido de config_visibilidade.';
comment on view public.v_conciliacao is
    'Conciliacao por fundo. observacao devolvida apenas a papel NOMINAL (auditor/sindico/conselho).';
comment on view public.v_cobertura_competencias is
    'Status de competencia por fonte. observacao devolvida apenas a papel NOMINAL.';
