-- ============================================================================
-- MIGRATION 010 — FASE 0: PENDÊNCIAS, CONTESTAÇÕES E LOGS
-- ============================================================================
-- PENDÊNCIAS / ACHADOS
-- --------------------
-- A pendência é o NÚCLEO da auditoria: é o que o app mostra ao auditor como
-- fila de trabalho. Não é anotação em planilha — é entidade com origem,
-- ligação com o lançamento afetado, status, gravidade e histórico de
-- anotações.
--
-- CONTESTAÇÕES
-- ------------
-- O síndico e o conselho fiscal podem COMENTAR e CONTESTAR, mas não alteram
-- classificação. A contestação aponta para um LANÇAMENTO (não para uma
-- pendência) e tem estado próprio: aberta → em_analise → acolhida/rejeitada.
--
-- ACESSO_LOG
-- ----------
-- Todas as ESCRITAS (por trigger genérico) e as LEITURAS do leitor (por
-- dentro da função agregadora). ⚠️ Limitação real: o Postgres não tem trigger
-- de SELECT, então a leitura nominal do auditor depende de pgaudit — está
-- registrado como pendência em aberto.
--
-- Documento de referência: docs\MODELO_DADOS.md §12A, §12B e §13
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PENDÊNCIAS
-- ----------------------------------------------------------------------------
create table if not exists public.pendencias (
    id             uuid primary key default gen_random_uuid(),
    condominio_id  uuid not null references public.condominios(id) on delete cascade,
    tipo           public.tipo_pendencia not null,
    origem         public.origem_pendencia not null,
    gravidade      public.gravidade_pendencia not null default 'media',
    titulo         text not null,
    descricao      text not null,

    -- Ligações (todas opcionais, todas indexadas).
    lancamento_id    uuid references public.lancamentos(id) on delete cascade,
    conciliacao_id   uuid references public.conciliacoes(id) on delete cascade,
    documento_id     uuid references public.documentos(id) on delete cascade,
    fonte_id         uuid references public.fontes_importacao(id) on delete set null,
    competencia_id   uuid references public.competencias(id) on delete cascade,
    fundo_id         uuid references public.fundos(id) on delete set null,
    unidade_id       uuid references public.unidades(id) on delete set null,
    importacao_id    uuid references public.importacoes(id) on delete set null,
    duplicata_id     uuid references public.duplicatas_candidatas(id) on delete cascade,
    -- Referência à linha de staging, quando a pendência está numa linha que
    -- ainda não foi aprovada.
    staging_referencia text,

    status          public.status_pendencia not null default 'aberta',
    resolucao       text,
    criada_em       timestamptz not null default now(),
    criada_por      uuid references public.perfis(id),
    resolvida_em    timestamptz,
    resolvida_por   uuid references public.perfis(id)
);

comment on table public.pendencias is
    'Fila de achados e pendências — o núcleo da auditoria. Toda ligação é '
    'opcional: a pendência pode ser de uma competência sem fonte, de um '
    'código de conta sem rubrica, de um anexo ilegível etc.';

create index if not exists ix_pendencias_abertas
    on public.pendencias (condominio_id, gravidade)
    where status in ('aberta','em_analise');
create index if not exists ix_pendencias_lancamento
    on public.pendencias (lancamento_id) where lancamento_id is not null;
create index if not exists ix_pendencias_competencia
    on public.pendencias (competencia_id) where competencia_id is not null;

-- ----------------------------------------------------------------------------
-- ANOTAÇÕES DA PENDÊNCIA
-- ----------------------------------------------------------------------------
create table if not exists public.pendencia_anotacoes (
    id           uuid primary key default gen_random_uuid(),
    pendencia_id uuid not null references public.pendencias(id) on delete cascade,
    autor_id     uuid not null references public.perfis(id),
    texto        text not null,
    criado_em    timestamptz not null default now()
);

create index if not exists ix_pendencia_anotacoes_pendencia
    on public.pendencia_anotacoes (pendencia_id, criado_em);

-- ----------------------------------------------------------------------------
-- CONTESTAÇÕES E COMENTÁRIOS
-- ----------------------------------------------------------------------------
create table if not exists public.contestacoes (
    id             uuid primary key default gen_random_uuid(),
    condominio_id  uuid not null references public.condominios(id) on delete cascade,
    lancamento_id  uuid references public.lancamentos(id) on delete cascade,
    pendencia_id   uuid references public.pendencias(id) on delete cascade,
    documento_id   uuid references public.documentos(id) on delete cascade,
    autor_id       uuid not null references public.perfis(id),
    tipo           public.tipo_contestacao not null default 'comentario',
    texto          text not null,
    status         public.status_contestacao not null default 'aberta',
    respondida_por uuid references public.perfis(id),
    resposta       text,
    criado_em      timestamptz not null default now(),
    respondida_em  timestamptz
);

comment on table public.contestacoes is
    'Comentários e contestações do síndico/conselho fiscal. NÃO alteram a '
    'classificação nem o status do lançamento — é registro lateral.';

create index if not exists ix_contestacoes_abertas
    on public.contestacoes (condominio_id, criado_em desc) where status = 'aberta';
create index if not exists ix_contestacoes_lancamento
    on public.contestacoes (lancamento_id) where lancamento_id is not null;

-- ----------------------------------------------------------------------------
-- AUDITORIA_LOG — quem mudou o quê, quando e por quê
-- ----------------------------------------------------------------------------
create table if not exists public.auditoria_log (
    id            uuid primary key default gen_random_uuid(),
    condominio_id uuid not null references public.condominios(id) on delete cascade,
    entidade      text not null,
    entidade_id   text,
    acao          text not null,
    antes         jsonb,
    depois        jsonb,
    usuario_id    uuid not null references public.perfis(id),
    criado_em     timestamptz not null default now()
);

create index if not exists ix_auditoria_log_entidade
    on public.auditoria_log (condominio_id, entidade, entidade_id, criado_em desc);

-- ----------------------------------------------------------------------------
-- ACESSO_LOG — todas as escritas e as leituras do leitor
-- ----------------------------------------------------------------------------
create table if not exists public.acesso_log (
    id            bigserial primary key,
    condominio_id uuid references public.condominios(id) on delete cascade,
    usuario_id    uuid references public.perfis(id) on delete set null,
    operacao      public.operacao_acesso not null,
    recurso       text not null,
    entidade_id   text,
    detalhes      jsonb,
    criado_em     timestamptz not null default now()
);

comment on table public.acesso_log is
    'Registro de acesso. Escritas via trigger genérico; leituras do leitor via '
    'fn_resumo. Retenção configurável (ver fn_purgar_acesso_log).';

create index if not exists ix_acesso_log_usuario
    on public.acesso_log (usuario_id, criado_em desc);
create index if not exists ix_acesso_log_condominio
    on public.acesso_log (condominio_id, criado_em desc);
create index if not exists ix_acesso_log_retencao
    on public.acesso_log (criado_em);

-- ----------------------------------------------------------------------------
-- RETENÇÃO DO ACESSO_LOG — 12 meses (configurável)
-- ----------------------------------------------------------------------------
-- A retenção é configurável por condomínio. O valor inicial é 12 meses.
create table if not exists public.config_retencao_acesso (
    condominio_id   uuid primary key references public.condominios(id) on delete cascade,
    meses_retencao  integer not null default 12 check (meses_retencao >= 1),
    atualizado_em   timestamptz not null default now(),
    atualizado_por uuid references public.perfis(id)
);

comment on table public.config_retencao_acesso is
    'Retenção do acesso_log, em meses. Padrão: 12 meses.';

create or replace function public.fn_purgar_acesso_log(p_condominio_id uuid default null)
returns bigint
language plpgsql
volatile
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_meses integer;
    v_removidos bigint;
begin
    select coalesce(max(meses_retencao), 12) into v_meses
      from public.config_retencao_acesso
     where condominio_id = p_condominio_id
        or p_condominio_id is null;

    delete from public.acesso_log
     where (p_condominio_id is null or condominio_id = p_condominio_id)
       and criado_em < now() - make_interval(months => v_meses);

    get diagnostics v_removidos = row_count;
    return v_removidos;
end;
$$;

-- ----------------------------------------------------------------------------
-- TRIGGER GENÉRICO DE ESCRITA — registra toda escrita em acesso_log
-- ----------------------------------------------------------------------------
-- ⚠️ O Postgres NÃO tem trigger de SELECT. Por isso o trigger cobre só as
-- escritas; as leituras do leitor são registradas dentro de fn_resumo.
create or replace function public.fn_log_escrita()
returns trigger
language plpgsql
security definer
set search_path = public, auth, extensions, pg_temp
as $$
declare
    v_linha   jsonb := coalesce(to_jsonb(new), to_jsonb(old));
    v_cond    uuid;
begin
    v_cond := nullif(v_linha ->> 'condominio_id', '')::uuid;

    insert into public.acesso_log (
        condominio_id, usuario_id, operacao, recurso, entidade_id, detalhes
    )
    values (
        v_cond,
        public.fn_usuario_atual(),
        lower(tg_op)::public.operacao_acesso,
        tg_table_name,
        coalesce(v_linha ->> 'id', ''),
        jsonb_build_object('schema', 'public')
    );

    return coalesce(new, old);
end;
$$;

-- O REVOKE EXPLÍCITO e o GRANT desta função estão na seção GRANTS, no fim
-- desta migration (defesa em profundidade: o fechamento fica escrito).

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------alter table public.pendencias           enable row level security;
alter table public.pendencias           force  row level security;
alter table public.pendencia_anotacoes  enable row level security;
alter table public.pendencia_anotacoes  force  row level security;
alter table public.contestacoes          enable row level security;
alter table public.contestacoes          force  row level security;
alter table public.auditoria_log         enable row level security;
alter table public.auditoria_log         force  row level security;
alter table public.acesso_log            enable row level security;
alter table public.acesso_log            force  row level security;
alter table public.config_retencao_acesso enable row level security;
alter table public.config_retencao_acesso force  row level security;

-- ----------------------------------------------------------------------------
-- GRANTS
-- ----------------------------------------------------------------------------
-- REVOKE EXPLÍCITO DAS FUNÇÕES DESTA MIGRATION (defesa em profundidade).
--
-- `fn_purgar_acesso_log` é SECURITY DEFINER e apaga linhas do log de acesso.
-- Sem REVOKE explícito, ela nasce com EXECUTE para PUBLIC — e o `anon` (não
-- logado) poderia chamá-la. O fechamento abaixo é explícito e vale a partir
-- do instante em que a função é criada, sem depender da varredura dinâmica de
-- uma migration posterior.
revoke all on function public.fn_purgar_acesso_log(uuid) from public, anon, authenticated;
revoke all on function public.fn_log_escrita()          from public, anon, authenticated;

-- O que é permitido, de forma explícita: só o papel executor da manutenção.
grant execute on function public.fn_purgar_acesso_log(uuid) to postgres;
grant execute on function public.fn_log_escrita()          to postgres;

revoke all on table public.pendencias            from public, anon, authenticated;
revoke all on table public.pendencia_anotacoes   from public, anon, authenticated;
revoke all on table public.contestacoes           from public, anon, authenticated;
revoke all on table public.auditoria_log          from public, anon, authenticated;
revoke all on table public.acesso_log             from public, anon, authenticated;
revoke all on table public.config_retencao_acesso from public, anon, authenticated;

revoke all on sequence public.acesso_log_id_seq from public, anon, authenticated;

select public.fn_revogar_sequencias_publicas();
