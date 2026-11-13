-- ============================================================================
-- MIGRATION 012 — FASE 0: PAPÉIS, HELPERS, POLÍTICAS E GRANTS
-- ============================================================================
-- Esta é a migration mais importante do projeto: ela define QUEM pode ver
-- QUÊ.
--
-- COMO O PAPEL É AVALIADO
-- -----------------------
-- No fluxo padrão do Supabase, todo usuário autenticado recebe a MESMA claim
-- `role: authenticated`. O banco enxerga UM role para todos os logados. O
-- papel de negócio (auditor, leitor, síndico, conselho fiscal) NÃO vem do
-- JWT: vem da tabela `membros`, consultado EM TEMPO DE CONSULTA, dentro das
-- policies e das funções.
--
-- ⚠️ CONCLUSÃO QUE MUDA O DESENHO: no fluxo padrão NÃO EXISTE `GRANT`
-- separado para o leitor. O leitor e o auditor são, para o Postgres, o mesmo
-- role. Não dá para escrever "REVOKE ... FROM app_leitor" — o role
-- `app_leitor` não existe no mundo do JWT.
--
-- Por isso a separação é feita em DUAS camadas acima do privilégio:
--
--   Camada 1 — PRIVILÉGIO DE TABELA:
--     `authenticated` NÃO tem `GRANT` sobre nenhuma tabela de detalhe.
--     O `SELECT` é recusado pelo Postgres com `permission denied`, antes de o
--     RLS ser avaliado.
--
--   Camada 2 — PAPEL DE NEGÓCIO:
--     Toda view e toda função verifica o papel do usuário NO CONDOMÍNIO da
--     própria linha e devolve agregado, linha, ou erro `42501`.
--
-- FORCE ROW LEVEL SECURITY × app_owner
-- ------------------------------------
-- `app_owner` recebe BYPASSRLS EXPLÍCITO. As tabelas usam FORCE RLS.
-- Consequência: o owner ignora as policies por decisão declarada e
-- auditável (não por default implícito, que quebraria com um simples
-- `ALTER TABLE ... OWNER TO postgres`). O preço é que o filtro de tenant tem
-- que ser MANUAL em cada função e view de app_owner — e é exatamente o que
-- o projeto exige. O controle desse preço: helper único, checklist de
-- revisão e teste automatizado cross-tenant.
--
-- Verificado em 11/11/2026: o Supabase local PERMITE criar role com
-- BYPASSRLS (`create role app_owner nologin bypassrls;` → CREATE ROLE).
--
-- Documento de referência: docs\SEGURANCA_RLS.md §2, §3, §4 e §7
-- ============================================================================

-- ----------------------------------------------------------------------------
-- ROLES
-- ----------------------------------------------------------------------------
-- app_owner: dono das funções e views privilegiadas. Sem login, com BYPASSRLS.
-- app_importador: usado pelo script Python de importação. Sem login aqui;
-- a credencial de login é criada fora do repositório.
-- Os roles (app_owner, app_importador) foram criados na migration 002,
-- porque o helper de usuário (00260) já precisa de um grant para o
-- app_owner — e o role precisa existir antes do grant.

grant app_owner to postgres;

-- Para RECEBER a propriedade de um objeto, o papel de destino precisa de
-- CREATE no schema que o contém. Sem esta linha, `alter function ... owner
-- to app_owner` falha com "permission denied for schema public".
-- Verificado em 11/11/2026.
grant usage, create on schema public to app_owner;

-- O app_owner é o owner das funções SECURITY DEFINER — é ELE quem executa o
-- corpo delas. Precisa de privilégio de LEITURA nas tabelas que elas
-- consultam (membros, fundos, rubricas, lancamentos, ...).
--
-- Sem estes grants, o corpo da função falha com "permission denied for
-- table X" (verificado em 11/11/2026).
--
-- ⚠️ O app_owner tem BYPASSRLS, então passa por cima das policies. É por
-- isso que o filtro de tenant é OBRIGATÓRIO dentro de cada função — o
-- privilégio sozinho não concede nada ao usuário: quem chama a função
-- continua sujeito à verificação de papel feita no corpo.
grant select on
    public.condominios,
    public.perfis,
    public.membros,
    public.convites,
    public.unidades,
    public.competencias,
    public.status_competencia,
    public.fundos,
    public.rubricas,
    public.rubrica_aliases,
    public.contas_origem,
    public.granularidade_ordem,
    public.config_visibilidade,
    public.fontes_importacao,
    public.importacoes,
    public.staging_lancamentos,
    public.staging_transacoes,
    public.staging_duplicatas,
    public.lancamentos,
    public.lancamento_rubrica,
    public.grupos_transferencia,
    public.transferencias_internas,
    public.duplicatas_candidatas,
    public.conciliacoes,
    public.conciliacao_detalhe,
    public.documentos,
    public.anexos,
    public.pendencias,
    public.pendencia_anotacoes,
    public.contestacoes,
    public.auditoria_log,
    public.acesso_log,
    public.config_retencao_acesso,
    public.serie_historica_resumo,
    public.serie_historica_anotacoes
to app_owner;

-- O app_owner também precisa ESCREVER nas tabelas que as RPCs alteram.
grant insert, update, delete on
    public.lancamentos,
    public.lancamento_rubrica,
    public.grupos_transferencia,
    public.transferencias_internas,
    public.duplicatas_candidatas,
    public.conciliacoes,
    public.conciliacao_detalhe,
    public.status_competencia,
    public.pendencias,
    public.pendencia_anotacoes,
    public.contestacoes,
    public.auditoria_log,
    public.acesso_log,
    public.staging_lancamentos,
    public.anexos,
    public.config_visibilidade,
    public.config_retencao_acesso,
    public.grupos_transferencia
to app_owner;

-- O acesso_log usa bigserial: para inserir, o app_owner precisa de USAGE na
-- sequência. Sem isso, a gravação no log falha com "permission denied for
-- sequence acesso_log_id_seq" (verificado em 11/11/2026).
grant usage on all sequences in schema public to app_owner;

-- ⚠️ O app_owner também precisa de USAGE no schema `auth` (é o owner das
-- funções SECURITY DEFINER, então é ele quem executa `public.fn_usuario_atual()`).
--
-- O schema `auth` pertence ao `supabase_admin`, e o `postgres` NÃO pode
-- conceder nele ("no privileges were granted for auth"). Por isso esse
-- grant fica no BOOTSTRAP (supabase/bootstrap/00-zerar_privilegios_padrao.sql),
-- que roda como supabase_admin.
--
-- Verificado em 11/11/2026.

-- ----------------------------------------------------------------------------
-- HELPERS DE PAPEL (avaliados POR CONDOMÍNIO)
-- ----------------------------------------------------------------------------
-- SECURITY DEFINER porque `membros` tem RLS própria — sem isso a consulta
-- recursaria (a policy de `membros` chamaria o helper, que consultaria
-- `membros`).
--
-- `public.fn_usuario_atual()` funciona dentro de SECURITY DEFINER porque lê a claim do JWT
-- da requisição (GUC de sessão), não o `current_user`.

-- Papéis do usuário autenticado NO CONDOMÍNIO INDICADO.
--
-- ⚠️ A coluna de saída é nomeada explicitamente (`returns table (...)`).
-- Com `returns setof uuid` o nome da coluna seria "uuid", e qualquer uso
-- não qualificado de `condominio_id` dentro de uma subconsulta passaria a
-- resolver para o escopo externo — gerando "column reference condominio_id is
-- ambiguous" nas views. Nomear a coluna evita a ambiguidade na raiz.
create or replace function public.fn_papeis_do_usuario(p_condominio_id uuid)
returns table (papel public.papel_membro)
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
    select m.papel
    from public.membros m
    where m.perfil_id = public.fn_usuario_atual()
      and m.ativo
      and m.condominio_id = p_condominio_id;
$$;

-- Condomínios do usuário autenticado.
create or replace function public.fn_condominios_do_usuario()
returns table (condominio_id uuid)
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
    select m.condominio_id
    from public.membros m
    where m.perfil_id = public.fn_usuario_atual()
      and m.ativo;
$$;

-- Atalho booleano para uso dentro de policies.
create or replace function public.fn_e_membro(
    p_condominio_id uuid,
    p_papel        public.papel_membro
)
returns boolean
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
    select exists (
        select 1
        from public.membros m
        where m.perfil_id = public.fn_usuario_atual()
          and m.ativo
          and m.condominio_id = p_condominio_id
          and m.papel = p_papel
    );
$$;

-- O usuário tem ALGUM papel no condomínio? (checagem de acesso, não de papel)
create or replace function public.fn_acessa_condominio(p_condominio_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth, extensions, pg_temp
as $$
    select exists (
        select 1
        from public.fn_condominios_do_usuario() c
        where c = p_condominio_id
    );
$$;

comment on function public.fn_papeis_do_usuario(uuid) is
    'Papéis do usuário autenticado NO CONDOMÍNIO indicado. Fonte única do papel.';
comment on function public.fn_e_membro(uuid, public.papel_membro) is
    'O usuário tem este papel neste condomínio? Usado em policies e funções.';

-- ----------------------------------------------------------------------------
-- REVOGAÇÃO GLOBAL (o coração da garantia do leitor)
-- ----------------------------------------------------------------------------
-- authenticated e anon não podem ler NENHUMA tabela de detalhe.
revoke all on table public.condominios            from public, anon, authenticated;
revoke all on table public.perfis                 from public, anon, authenticated;
revoke all on table public.membros                from public, anon, authenticated;
revoke all on table public.convites               from public, anon, authenticated;
revoke all on table public.unidades               from public, anon, authenticated;
revoke all on table public.competencias           from public, anon, authenticated;
revoke all on table public.status_competencia     from public, anon, authenticated;
revoke all on table public.fundos                 from public, anon, authenticated;
revoke all on table public.rubricas               from public, anon, authenticated;
revoke all on table public.rubrica_aliases        from public, anon, authenticated;
revoke all on table public.contas_origem          from public, anon, authenticated;
revoke all on table public.granularidade_ordem    from public, anon, authenticated;
revoke all on table public.config_visibilidade    from public, anon, authenticated;
revoke all on table public.fontes_importacao      from public, anon, authenticated;
revoke all on table public.importacoes            from public, anon, authenticated;
revoke all on table public.staging_lancamentos    from public, anon, authenticated;
revoke all on table public.staging_transacoes     from public, anon, authenticated;
revoke all on table public.staging_duplicatas      from public, anon, authenticated;
revoke all on table public.lancamentos            from public, anon, authenticated;
revoke all on table public.lancamento_rubrica     from public, anon, authenticated;
revoke all on table public.grupos_transferencia   from public, anon, authenticated;
revoke all on table public.transferencias_internas from public, anon, authenticated;
revoke all on table public.duplicatas_candidatas   from public, anon, authenticated;
revoke all on table public.conciliacoes           from public, anon, authenticated;
revoke all on table public.conciliacao_detalhe     from public, anon, authenticated;
revoke all on table public.documentos              from public, anon, authenticated;
revoke all on table public.anexos                  from public, anon, authenticated;
revoke all on table public.pendencias              from public, anon, authenticated;
revoke all on table public.pendencia_anotacoes     from public, anon, authenticated;
revoke all on table public.contestacoes             from public, anon, authenticated;
revoke all on table public.auditoria_log            from public, anon, authenticated;
revoke all on table public.acesso_log               from public, anon, authenticated;
revoke all on table public.config_retencao_acesso   from public, anon, authenticated;
revoke all on table public.serie_historica_resumo   from public, anon, authenticated;
revoke all on table public.serie_historica_anotacoes from public, anon, authenticated;

-- Sequências e objetos futuros.
select public.fn_revogar_sequencias_publicas();
select public.fn_revogar_funcoes_publicas();

-- ⚠️ O revogar acima tira o EXECUTE de TUDO em public, inclusive do
-- helper fn_usuario_atual (criado na migration 00260). Por isso o grant
-- dele é refeito aqui — o helper é usado no corpo das RPCs.
grant execute on function public.fn_usuario_atual() to authenticated;
grant execute on function public.fn_usuario_atual() to app_owner;

-- Objetos criados DEPOIS: sem privilégio herdado para anon/authenticated.
select public.fn_revogar_objetos_futuros();

-- ----------------------------------------------------------------------------
-- POLÍTICAS — o papel é SEMPRE avaliado no condomínio da própria linha
-- ----------------------------------------------------------------------------
-- As tabelas de detalhe não têm grant para `authenticated`; estas policies são
-- defesa em profundidade (protegem contra um GRANT futuro, contra o role
-- app_importador e contra o dono de tabela).

-- perfis: o usuário vê o próprio. A PK de perfis é `id` (FK para auth.users).
drop policy if exists perfis_leitura_proprio on public.perfis;
create policy perfis_leitura_proprio on public.perfis
    for select to authenticated
    using (id = public.fn_usuario_atual());

-- membros: o usuário vê as próprias associações
drop policy if exists membros_leitura_proprio on public.membros;
create policy membros_leitura_proprio on public.membros
    for select to authenticated
    using (perfil_id = public.fn_usuario_atual());

-- condomínios: quem tem algum papel no condomínio
drop policy if exists condominios_leitura on public.condominios;
create policy condominios_leitura on public.condominios
    for select to authenticated
    using (public.fn_acessa_condominio(id));

-- convites: só administrador (auditor) do condomínio
drop policy if exists convites_leitura on public.convites;
create policy convites_leitura on public.convites
    for select to authenticated
    using (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists convites_escrita on public.convites;
create policy convites_escrita on public.convites
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

-- unidades: leitura para quem tem papel com acesso nominal
drop policy if exists unidades_leitura on public.unidades;
create policy unidades_leitura on public.unidades
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'sindico')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

-- competências e status
drop policy if exists competencias_leitura on public.competencias;
create policy competencias_leitura on public.competencias
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists status_competencia_leitura on public.status_competencia;
create policy status_competencia_leitura on public.status_competencia
    for select to authenticated
    using (
        exists (
            select 1 from public.competencias c
            where c.id = competencia_id
              and public.fn_acessa_condominio(c.condominio_id)
        )
    );

drop policy if exists status_competencia_escrita on public.status_competencia;
create policy status_competencia_escrita on public.status_competencia
    for all to authenticated
    using (
        exists (
            select 1 from public.competencias c
            where c.id = competencia_id
              and public.fn_e_membro(c.condominio_id, 'auditor')
        )
    )
    with check (
        exists (
            select 1 from public.competencias c
            where c.id = competencia_id
              and public.fn_e_membro(c.condominio_id, 'auditor')
        )
    );

-- fundos, rubricas, aliases, contas de origem
drop policy if exists fundos_leitura on public.fundos;
create policy fundos_leitura on public.fundos
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists fundos_escrita on public.fundos;
create policy fundos_escrita on public.fundos
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists rubricas_leitura on public.rubricas;
create policy rubricas_leitura on public.rubricas
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists rubricas_escrita on public.rubricas;
create policy rubricas_escrita on public.rubricas
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists rubrica_aliases_leitura on public.rubrica_aliases;
create policy rubrica_aliases_leitura on public.rubrica_aliases
    for select to authenticated
    using (
        exists (
            select 1 from public.rubricas r
            where r.id = rubrica_id
              and public.fn_acessa_condominio(r.condominio_id)
        )
    );

drop policy if exists rubrica_aliases_escrita on public.rubrica_aliases;
create policy rubrica_aliases_escrita on public.rubrica_aliases
    for all to authenticated
    using (
        exists (
            select 1 from public.rubricas r
            where r.id = rubrica_id
              and public.fn_e_membro(r.condominio_id, 'auditor')
        )
    )
    with check (
        exists (
            select 1 from public.rubricas r
            where r.id = rubrica_id
              and public.fn_e_membro(r.condominio_id, 'auditor')
        )
    );

drop policy if exists contas_origem_leitura on public.contas_origem;
create policy contas_origem_leitura on public.contas_origem
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists contas_origem_escrita on public.contas_origem;
create policy contas_origem_escrita on public.contas_origem
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

-- config_visibilidade: só auditor, e alteração via RPC (que audita)
drop policy if exists config_visibilidade_leitura on public.config_visibilidade;
create policy config_visibilidade_leitura on public.config_visibilidade
    for select to authenticated
    using (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists config_visibilidade_escrita on public.config_visibilidade;
create policy config_visibilidade_escrita on public.config_visibilidade
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

-- fontes, importações e staging: auditor lê; só o importador escreve no staging
drop policy if exists fontes_leitura on public.fontes_importacao;
create policy fontes_leitura on public.fontes_importacao
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists importacoes_leitura on public.importacoes;
create policy importacoes_leitura on public.importacoes
    for select to authenticated
    using (
        exists (
            select 1 from public.fontes_importacao f
            where f.id = fonte_id
              and public.fn_acessa_condominio(f.condominio_id)
        )
    );

drop policy if exists staging_lancamentos_leitura on public.staging_lancamentos;
create policy staging_lancamentos_leitura on public.staging_lancamentos
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists staging_transacoes_leitura on public.staging_transacoes;
create policy staging_transacoes_leitura on public.staging_transacoes
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists staging_duplicatas_leitura on public.staging_duplicatas;
create policy staging_duplicatas_leitura on public.staging_duplicatas
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

-- lançamentos: leitura por papel, escrita só por auditor
drop policy if exists lancamentos_leitura on public.lancamentos;
create policy lancamentos_leitura on public.lancamentos
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'sindico')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists lancamentos_escrita on public.lancamentos;
create policy lancamentos_escrita on public.lancamentos
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists lancamento_rubrica_leitura on public.lancamento_rubrica;
create policy lancamento_rubrica_leitura on public.lancamento_rubrica
    for select to authenticated
    using (
        exists (
            select 1 from public.lancamentos l
            where l.id = lancamento_id
              and (
                    public.fn_e_membro(l.condominio_id, 'auditor')
                 or public.fn_e_membro(l.condominio_id, 'sindico')
                 or public.fn_e_membro(l.condominio_id, 'conselho_fiscal')
              )
        )
    );

drop policy if exists lancamento_rubrica_escrita on public.lancamento_rubrica;
create policy lancamento_rubrica_escrita on public.lancamento_rubrica
    for all to authenticated
    using (
        exists (
            select 1 from public.lancamentos l
            where l.id = lancamento_id
              and public.fn_e_membro(l.condominio_id, 'auditor')
        )
    )
    with check (
        exists (
            select 1 from public.lancamentos l
            where l.id = lancamento_id
              and public.fn_e_membro(l.condominio_id, 'auditor')
        )
    );

-- transferências e duplicatas
drop policy if exists grupos_transferencia_leitura on public.grupos_transferencia;
create policy grupos_transferencia_leitura on public.grupos_transferencia
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists transferencias_internas_leitura on public.transferencias_internas;
create policy transferencias_internas_leitura on public.transferencias_internas
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists transferencias_internas_escrita on public.transferencias_internas;
create policy transferencias_internas_escrita on public.transferencias_internas
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists duplicatas_candidatas_leitura on public.duplicatas_candidatas;
create policy duplicatas_candidatas_leitura on public.duplicatas_candidatas
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists duplicatas_candidatas_escrita on public.duplicatas_candidatas;
create policy duplicatas_candidatas_escrita on public.duplicatas_candidatas
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

-- conciliações
drop policy if exists conciliacoes_leitura on public.conciliacoes;
create policy conciliacoes_leitura on public.conciliacoes
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists conciliacoes_escrita on public.conciliacoes;
create policy conciliacoes_escrita on public.conciliacoes
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists conciliacao_detalhe_leitura on public.conciliacao_detalhe;
create policy conciliacao_detalhe_leitura on public.conciliacao_detalhe
    for select to authenticated
    using (
        exists (
            select 1 from public.conciliacoes c
            where c.id = conciliacao_id
              and public.fn_acessa_condominio(c.condominio_id)
        )
    );

-- documentos e anexos
drop policy if exists documentos_leitura on public.documentos;
create policy documentos_leitura on public.documentos
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'sindico')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists documentos_escrita on public.documentos;
create policy documentos_escrita on public.documentos
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists anexos_leitura on public.anexos;
create policy anexos_leitura on public.anexos
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'sindico')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists anexos_escrita on public.anexos;
create policy anexos_escrita on public.anexos
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

-- pendências
drop policy if exists pendencias_leitura on public.pendencias;
create policy pendencias_leitura on public.pendencias
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'sindico')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists pendencias_escrita on public.pendencias;
create policy pendencias_escrita on public.pendencias
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists pendencia_anotacoes_leitura on public.pendencia_anotacoes;
create policy pendencia_anotacoes_leitura on public.pendencia_anotacoes
    for select to authenticated
    using (
        exists (
            select 1 from public.pendencias p
            where p.id = pendencia_id
              and (
                    public.fn_e_membro(p.condominio_id, 'auditor')
                 or public.fn_e_membro(p.condominio_id, 'sindico')
                 or public.fn_e_membro(p.condominio_id, 'conselho_fiscal')
              )
        )
    );

drop policy if exists pendencia_anotacoes_escrita on public.pendencia_anotacoes;
create policy pendencia_anotacoes_escrita on public.pendencia_anotacoes
    for all to authenticated
    using (
        exists (
            select 1 from public.pendencias p
            where p.id = pendencia_id
              and (
                    public.fn_e_membro(p.condominio_id, 'auditor')
                 or public.fn_e_membro(p.condominio_id, 'sindico')
                 or public.fn_e_membro(p.condominio_id, 'conselho_fiscal')
              )
        )
    )
    with check (
        exists (
            select 1 from public.pendencias p
            where p.id = pendencia_id
              and (
                    public.fn_e_membro(p.condominio_id, 'auditor')
                 or public.fn_e_membro(p.condominio_id, 'sindico')
                 or public.fn_e_membro(p.condominio_id, 'conselho_fiscal')
              )
        )
    );

-- contestações: síndico e conselho fiscal CRIAM; auditor responde
drop policy if exists contestacoes_leitura on public.contestacoes;
create policy contestacoes_leitura on public.contestacoes
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'sindico')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists contestacoes_insercao on public.contestacoes;
create policy contestacoes_insercao on public.contestacoes
    for insert to authenticated
    with check (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'sindico')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists contestacoes_atualizacao on public.contestacoes;
create policy contestacoes_atualizacao on public.contestacoes
    for update to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

-- logs: auditor e conselho fiscal leem; ninguém além disso escreve
drop policy if exists auditoria_log_leitura on public.auditoria_log;
create policy auditoria_log_leitura on public.auditoria_log
    for select to authenticated
    using (
        public.fn_e_membro(condominio_id, 'auditor')
     or public.fn_e_membro(condominio_id, 'conselho_fiscal')
    );

drop policy if exists acesso_log_leitura on public.acesso_log;
create policy acesso_log_leitura on public.acesso_log
    for select to authenticated
    using (
        exists (
            select 1 from public.membros m
            where m.perfil_id = public.fn_usuario_atual()
              and m.ativo
              and m.condominio_id = acesso_log.condominio_id
              and m.papel in ('auditor','conselho_fiscal')
        )
    );

drop policy if exists config_retencao_acesso_leitura on public.config_retencao_acesso;
create policy config_retencao_acesso_leitura on public.config_retencao_acesso
    for select to authenticated
    using (public.fn_e_membro(condominio_id, 'auditor'));

drop policy if exists config_retencao_acesso_escrita on public.config_retencao_acesso;
create policy config_retencao_acesso_escrita on public.config_retencao_acesso
    for all to authenticated
    using      (public.fn_e_membro(condominio_id, 'auditor'))
    with check (public.fn_e_membro(condominio_id, 'auditor'));

-- série histórica
drop policy if exists serie_historica_leitura on public.serie_historica_resumo;
create policy serie_historica_leitura on public.serie_historica_resumo
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

drop policy if exists serie_historica_anotacoes_leitura on public.serie_historica_anotacoes;
create policy serie_historica_anotacoes_leitura on public.serie_historica_anotacoes
    for select to authenticated
    using (public.fn_acessa_condominio(condominio_id));

-- ----------------------------------------------------------------------------
-- GRANTS FINAIS
-- ----------------------------------------------------------------------------
-- authenticated: apenas o que o leitor pode usar como agregado + helpers.
grant select on public.granularidade_ordem to authenticated;
grant select on public.perfis to authenticated;
-- O grant da lista permitida de grants fica na migration 016, que é a que
-- cria a tabela public.config_grants_permitidos. Grantar aqui quebraria a
-- ordem das migrations (a tabela ainda não existiria).

grant execute on function public.fn_papeis_do_usuario(uuid) to authenticated;
grant execute on function public.fn_condominios_do_usuario()  to authenticated;
grant execute on function public.fn_e_membro(uuid, public.papel_membro) to authenticated;
grant execute on function public.fn_acessa_condominio(uuid) to authenticated;

-- O importador escreve no staging e NADA mais.
grant usage on schema public to app_importador;
grant insert, update on public.fontes_importacao   to app_importador;
grant insert, update on public.importacoes         to app_importador;
grant insert, update on public.staging_lancamentos to app_importador;
grant insert, update on public.staging_transacoes  to app_importador;
grant insert, update on public.staging_duplicatas   to app_importador;
grant insert, update on public.serie_historica_resumo     to app_importador;
grant insert, update on public.serie_historica_anotacoes to app_importador;
grant insert, update on public.contas_origem    to app_importador;
grant select on public.rubricas                to app_importador;
grant select on public.rubrica_aliases         to app_importador;
grant select on public.fundos                  to app_importador;
grant select on public.unidades                to app_importador;
grant select on public.competencias            to app_importador;

-- As funções privilegiadas são do app_owner, que ignora RLS.
alter function public.fn_papeis_do_usuario(uuid)             owner to app_owner;
alter function public.fn_condominios_do_usuario()            owner to app_owner;
alter function public.fn_e_membro(uuid, public.papel_membro) owner to app_owner;
alter function public.fn_acessa_condominio(uuid)             owner to app_owner;

-- Revoga o EXECUTE dos helpers e dos de manutenção de `authenticated`.
revoke all on function public.fn_papeis_do_usuario(uuid)             from public, anon, authenticated;
revoke all on function public.fn_condominios_do_usuario()            from public, anon, authenticated;
revoke all on function public.fn_e_membro(uuid, public.papel_membro) from public, anon, authenticated;
revoke all on function public.fn_acessa_condominio(uuid)             from public, anon, authenticated;
revoke all on function public.fn_log_escrita()                      from public, anon, authenticated;
revoke all on function public.fn_purgar_acesso_log(uuid)            from public, anon, authenticated;

grant execute on function public.fn_papeis_do_usuario(uuid)             to authenticated;
grant execute on function public.fn_condominios_do_usuario()            to authenticated;
grant execute on function public.fn_e_membro(uuid, public.papel_membro) to authenticated;
grant execute on function public.fn_acessa_condominio(uuid)             to authenticated;

-- Os helpers também são usados no corpo das views agregadas (que rodam
-- como app_owner) e das RPCs. Sem estes grants, o corpo falha com
-- "permission denied for function ..." (verificado em 11/11/2026).
grant execute on function public.fn_papeis_do_usuario(uuid)             to app_owner;
grant execute on function public.fn_condominios_do_usuario()            to app_owner;
grant execute on function public.fn_e_membro(uuid, public.papel_membro) to app_owner;
grant execute on function public.fn_acessa_condominio(uuid)             to app_owner;
