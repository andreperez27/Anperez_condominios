-- ============================================================================
-- MIGRATION 0135 — FASE 0: HELPER DE USUÁRIO DA REQUISIÇÃO
-- ============================================================================
-- Ver a explicação completa no corpo da função.
--
-- Documento de referência: docs\SEGURANCA_RLS.md §2
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fn_usuario_atual — o usuário da requisição, sem depender do schema auth
-- ----------------------------------------------------------------------------
-- O `search_path` da SESSÃO no Supabase local é `"$user", public, extensions`
-- (SEM o schema `auth`). Dentro de uma função SECURITY DEFINER o
-- `search_path` fixado vale para o corpo, mas um `auth.uid()` usado num
-- INSERT pode ser resolvido no contexto do statement — e aí o schema `auth`
-- não existe no caminho, o planner resolve `auth` como PLANO e a coluna
-- vira NULL (verificado em 11/11/2026: "null value in column usuario_id").
--
-- Este helper lê o claim do JWT direto do GUC de sessão — exatamente o que
-- `auth.uid()` faz, sem a dependência de resolução de schema.
--
-- É VOLATILE e SECURITY DEFINER: precisa ler o claim mesmo quando o
-- chamador é `authenticated` (o claim é público; o que não é público é o
-- dado da tabela).
-- É VOLATILE (e não STABLE) de propósito: uma função STABLE é avaliada
-- pelo planner no início da query, e o claim do JWT pode ser trocado no
-- meio do teste (o `set local role` invalida o snapshot). Com VOLATILE, a
-- leitura do claim acontece no momento da chamada.
--
-- Verificado em 11/11/2026: com STABLE, `fn_usuario_atual()` devolvia NULL
-- dentro de `fn_atualizar_visibilidade` (o INSERT do auditoria_log recebia
-- usuario_id NULL), embora a chamada direta devolvesse o id correto.
create or replace function public.fn_usuario_atual()
returns uuid
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
    -- ⚠️ Replica EXATAMENTE a lógica do `auth.uid()` oficial do Supabase
    -- (verificado em 12/11/2026 no banco local):
    --
    --     coalesce(
    --       nullif(current_setting('request.jwt.claim.sub', true), ''),
    --       (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    --     )::uuid
    --
    -- Ou seja, DOIS lugares, nesta ordem:
    --   1. `request.jwt.claim.sub`  — GUC dedicado (Claim/Sub)
    --   2. `request.jwt.claims`    — GUC com o JSON INTEIRO do JWT
    --
    -- O PostgREST popula os dois (o segundo é o JSON completo do token,
    -- com 'sub', 'role', 'exp'...). Por isso o fallback cobre o formato
    -- real da API REST — e também o caso em que só o JSON é propagado.
    --
    -- A diferença em relação ao `auth.uid()` é APENAS a resolução de
    -- schema: o `search_path` da sessão no Supabase local é
    -- `"$user", public, extensions` (SEM o schema `auth`), então um
    -- `auth.uid()` resolvido no contexto de um statement vira PLANO e
    -- produz NULL. Este helper lê o GUC direto, sem depender de
    -- resolução de schema.
    --
    -- É VOLATILE (e não STABLE) de propósito: função STABLE é avaliada
    -- pelo planner no início da query, e o claim do JWT pode ser trocado
    -- no meio do teste (o `set local role` invalida o snapshot).
    select nullif(
        coalesce(
            nullif(current_setting('request.jwt.claim.sub', true), ''),
            (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
        ),
        ''
    )::uuid;
$$;

comment on function public.fn_usuario_atual() is
    'Usuario da requisicao (claim do JWT), lido direto do GUC de sessao. '
    'Substitui auth.uid() nas funcoes privilegiadas, por causa do search_path '
    'da sessao nao incluir o schema auth.';

-- REVOKE EXPLÍCITO (defesa em profundidade): o helper nasce fechado. O
-- `authenticated` recebe execute logo abaixo, de forma explícita — o que
-- é permitido fica escrito; o resto, não.
revoke all on function public.fn_usuario_atual() from public, anon, authenticated;
grant execute on function public.fn_usuario_atual() to authenticated;

-- O app_owner é o owner das funções privilegiadas e é quem executa este
-- helper no corpo delas. Sem este grant, o corpo falha com "permission
-- denied for function fn_usuario_atual" (verificado em 11/11/2026).
grant execute on function public.fn_usuario_atual() to app_owner;

