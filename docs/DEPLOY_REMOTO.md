# Roteiro de implantação remota — ANPEREZ CONDOMÍNIOS

**Data:** 12/11/2026
**Projeto Supabase remoto:** `aejuoiwxzzsxmhhizwau` — https://aejuoiwxzzsxmhhizwau.supabase.co
**Repositório remoto:** https://github.com/andreperez27/Anperez_condominios.git
**Quem executa:** você, no seu terminal. **Eu não preciso — nem quero — de token, senha ou `SUPABASE_ACCESS_TOKEN`.**

> Este roteiro descreve **exatamente o que muda** entre o ambiente local (onde a Fase 0 foi validada com a bateria pgTAP + e2e verdes) e o ambiente hospedado.
>
> ⚠️ **Estado em 12/11/2026:** as verificações do §3.1 JÁ RODARAM no remoto e **confirmaram o plano A** (ver §0). As migrations **ainda não foram aplicadas** no remoto — nada de estrutura foi criado lá além do `app_owner` (idempotente na migration 00200).

---

## 0. Antes de começar: o que já está validado

| Item | Estado |
|---|---|
| 21 migrations aplicam do zero, sem erro | ✅ validado localmente (`supabase db reset`) — **21 migrations** desde 12/11/2026 (a `01600_lista_grants_permitidos` entrou em 11/2026; a 19–21 em 12/11/2026, junto com a matriz view x papel; ver §4.4) |
| Bateria pgTAP | ✅ 47/47 verdes |
| Teste e2e com token real (API REST) | ✅ 33/33 verdes |
| Teste de drift de grants (7 verificações autocontidas) | ✅ verde |
| Seed | ✅ só configuração fictícia, zero dado real |
| Dado real do condomínio | ❌ **nenhum** — nada foi importado |
| Anperez Money | ❌ **não tocado** — 0 arquivos modificados |
| **Verificação do §3.1 no remoto** | ✅ **EXECUTADA em 12/11/2026 — plano A CONFIRMADO** (ver abaixo) |

### 0.1 Resultado da verificação no remoto (12/11/2026)

O teste do §3.1 rodou no SQL Editor do projeto `aejuoiwxzzsxmhhizwau`, com este resultado:

| Papel | `rolbypassrls` | `rolcanlogin` | `rolsuper` | Leitura |
|---|---|---|---|---|
| `postgres` (hospedado) | `t` | `t` | `f` | Não é superuser, mas **tem BYPASSRLS** — ignora as policies |
| `app_owner` | `t` | `f` | `f` | **Criado com sucesso** no remoto (nologin, bypassrls, sem super) |

**Consequências:**

- ✅ **Plano A CONFIRMADO** — o `app_owner` com `BYPASSRLS` é o dono dos objetos privilegiados, exatamente como no local. Nenhuma adaptação de migration é necessária.
- ❌ **Plano B NÃO é necessário** — a seção do plano B no §3.1 fica como registro histórico apenas.
- ✅ A migration `20261111000200` é **idempotente** (`if not exists` + garantia de BYPASSRLS): com o `app_owner` já criado no remoto, ela é no-op — pode ser aplicada pelo `db push` sem ajuste.
- ✅ O `pg_default_acl` do remoto foi inspecionado: **não há defaults globais** (todos por schema). Defaults que concedem acesso a `anon`/`authenticated` existem para `postgres` em `public` (tabelas/funções/sequences) e para `supabase_admin` em `public`, `graphql`, `graphql_public`. Os defaults de `storage`, `graphql`, `graphql_public` são **internos da plataforma** (não alterar). O do `postgres` em `public` é limpo pelo bootstrap (§3.2). O do `supabase_admin` é **risco residual aceito** — ver §5.1.

---

## 1. O que muda do local para o hospedado

### 1.1 As 5 diferenças concretas

| # | Diferença | Impacto | Como tratar |
|---|---|---|---|
| **D1** | O `postgres` **não é superuser** no hospedado (é superuser no local) | ~~Bloqueante~~ ✅ **Resolvido** — confirmado em 12/11/2026 que ele tem `rolbypassrls = true` e pode criar o `app_owner` (ver §0.1) | Ver §3.2 |
| **D2** | Os *default privileges* do papel que executa as migrations podem diferir | Um objeto novo pode nascer com acesso do `anon`/`authenticated` | Ver §3.2 |
| **D3** | O schema `auth` pertence ao `supabase_admin`, e o `postgres` **não pode** conceder nele | O `grant usage on schema auth to app_owner` e o `grant select on auth.users` **não podem** ser feitos pelo `postgres` | Ver §3.2 |
| **D4** | Não existe `supabase_admin` acessível por senha (o acesso é via service role / Management API) | O bootstrap local **não roda** no remoto | Ver §3.2 |
| **D5** | O `db push` aplica migrations **uma a uma**, sem rollback automático | Uma migration que falha deixa o banco parcial | Ver §4 (dry-run e ordem) |

### 1.2 O que NÃO muda

- A estrutura do modelo (36 tabelas, 14 views, 40 funções, 53 policies, 26 enums).
- O `app_owner` com `BYPASSRLS` — ✅ **confirmado no remoto em 12/11/2026** (ver §0.1).
- A lógica de RLS: os helpers `fn_papeis_do_usuario(p_condominio_id)`, `fn_e_membro(p_condominio_id, p_papel)` e `fn_condominios_do_usuario()` são exatamente os mesmos.
- O `fn_usuario_atual()` — o formato do claim é o mesmo (o PostgREST popula `request.jwt.claims` com o JSON do JWT).
- O `seed.sql` — **não é carregado no remoto** (decisão de 12/11/2026; ver §4.5). O banco nasce sem nenhuma configuração fictícia.

---

## 2. Pré-requisitos

- [ ] A conta do Supabase é a **dona** do projeto `aejuoiwxzzsxmhhizwau`.
- [ ] O repositório GitHub `andreperez27/Anperez_condominios` está **privado** (veja §6 — confirme antes de dar push).
- [ ] Você tem o `SUPABASE_ACCESS_TOKEN` no seu terminal (criado em https://supabase.com/dashboard/account/tokens). **Só no seu terminal** — não me passe.

---

## 3. As migrations no hospedado

### 3.1 Passo crítico: o `app_owner` com BYPASSRLS pode ser criado?

✅ **RESOLVIDO — EXECUTADO NO REMOTO EM 12/11/2026.** O teste abaixo rodou no SQL Editor do projeto `aejuoiwxzzsxmhhizwau`, o `app_owner` foi **criado com sucesso** (nologin, `bypassrls = true`, sem super) e o `postgres` hospedado tem `rolbypassrls = true`. **Plano A confirmado; plano B NÃO é necessário.**

O bloco fica aqui como **registro do que foi executado** — e como verificação a refazer se o projeto for recriado do zero:

```sql
-- conecte ao banco hospedado (Dashboard > SQL Editor, ou psql)
-- e rode:

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'app_owner') then
        create role app_owner nologin bypassrls;
    end if;
end
$$;

select rolname, rolbypassrls, rolcanlogin, rolsuper
  from pg_roles
 where rolname in ('app_owner', 'app_importador');
```

**Resultado observado no remoto (12/11/2026):** `app_owner` com `rolbypassrls = t`, `rolcanlogin = f`, `rolsuper = f` — exatamente o esperado na tabela abaixo. Como o papel **já existe**, a migration `20261111000200` é no-op (idempotente).

**Resultado esperado:**

| papel | rolbypassrls | rolcanlogin | rolsuper |
|---|---|---|---|
| `app_owner` | `t` | `f` | `f` |
| `app_importador` | `f` | `f` | `f` |

#### O `postgres` hospedado tem `BYPASSRLS`?

✅ **SIM — CONFIRMADO em 12/11/2026:** `postgres.rolbypassrls = true`, `rolsuper = false` no projeto `aejuoiwxzzsxmhhizwau`. O bloco abaixo fica como registro da verificação (e refazer se o projeto for recriado):

```sql
select
    rolname,
    rolsuper,          -- superuser? (o local tem t, o hospedado tem f)
    rolbypassrls,      -- BYPASSRLS?
    rolcanlogin
from pg_roles
where rolname in ('postgres', 'app_owner', 'app_importador', 'anon', 'authenticated')
order by rolname;
```

**Leitura do resultado:**

| `postgres.rolbypassrls` | Significado | Plano |
|---|---|---|
| `t` | O `postgres` ignora as policies | **A** — o `app_owner` pode ser criado com `BYPASSRLS` e ser o dono |
| `f` | O `postgres` respeita as policies | **B** — o `postgres` **não** pode ser o dono (o `FORCE ROW LEVEL SECURITY` o sujeita às policies) |

#### Plano B — ARQUIVADO (registro histórico)

⚠️ **O plano B NÃO é necessário no projeto atual** (plano A confirmado em 12/11/2026). A seção abaixo fica **apenas como registro**, para o caso de o projeto ser recriado num cenário diferente.

O erro, num cenário de plano B, seria:

```
ERROR: permission denied to create role
```

**Plano B: usar o `postgres` como dono das funções e views, sem `BYPASSRLS`.**

⚠️ **O plano B SÓ vale se o `postgres` hospedado tiver `rolbypassrls = true`.** Se o `postgres` tiver `rolbypassrls = false`, ele **não pode** ser o dono de objetos privilegiados: com `FORCE ROW LEVEL SECURITY`, o owner é sujeito às próprias policies, e as funções `SECURITY DEFINER` dele passariam a depender das policies — exatamente o que o modelo evita.

Nesse caso (sem `BYPASSRLS` nem no `postgres` nem criação de role), as saídas são:

| Opção | Como |
|---|---|
| **B1** | Pedir ao Supabase para criar o role com BYPASSRLS (o time deles pode, por ser superuser) |
| **B2** | Usar o `supabase_admin` como owner das funções (se você tiver um acesso privilegiado — e a Management API) |
| **B3** | Recuar as funções privilegiadas e mover a verificação de papel para dentro das funções comuns (mais trabalho, mais exposição) |

O que mudaria (quando o plano B for válido):

| Item | Com `app_owner` (plano A) | Plano B (`postgres` como dono) |
|---|---|---|
| Owner das funções/views | `app_owner` (BYPASSRLS) | `postgres` |
| Filtro de tenant dentro das funções | **obrigatório** (o owner ignora as policies) | **obrigatório** (idem) |
| RLS nas tabelas | `enable` + `force` | `enable` + `force` |
| `grant app_owner to postgres` | necessário (para o `alter ... owner to`) | não se aplica |
| `postgres` como owner | — | ⚠️ **só é válido com `postgres.rolbypassrls = true`** — verifique antes |
| Impacto no comportamento | nenhum | **nenhum** — o comportamento observável é o mesmo, porque o filtro de tenant é manual em ambos os casos |

**Como ativar o plano B (2 edits, ambos em `supabase/migrations/`):**

1. Na migration `20261111000200` (onde o role é criado), trocar:
   ```sql
   create role app_owner nologin bypassrls;
   ```
   por:
   ```sql
   -- PLANO B: o postgres hospedado nao pode criar role com BYPASSRLS.
   -- Os objetos privilegiados ficam com o postgres como dono.
   ```
   (e remover o `grant app_owner to postgres` e o `grant usage, create on schema public to app_owner`).

2. Em todas as migrations que fazem `alter function ... owner to app_owner` (a `01200` e a `01400`), trocar `owner to app_owner` por `owner to postgres`.

3. Em todas as migrations que concedem privilégio a `app_owner` (`grant ... to app_owner`), remover essas linhas — o `postgres` já tem os privilégios (ele é `BYPASSRLS` no plano A, ver §3.1).

⚠️ **Antes de ativar o plano B, rodar o teste do §3.1 no remoto.** É uma mudança de ~10 linhas em 3 arquivos, e não se aplica por suposição.

### 3.2 O bootstrap no hospedado: o que o `postgres` PODE e o que NÃO PODE fazer

O bootstrap local (`supabase/bootstrap/00-zerar_privilegios_padrao.sql`) roda como `supabase_admin` porque ele é o único que pode:
- zerar os *default privileges* do `supabase_admin`;
- conceder no schema `auth`.

**No hospedado, `supabase_admin` não é acessível por senha.** Então o bootstrap **não roda** — e não deve rodar.

#### O que fazer no hospedado, com o `postgres`

Crie um arquivo **só para o remoto** (`supabase/bootstrap/01-zerar_privilegios_remoto.sql`) com o que o `postgres` consegue:

```sql
-- Rodar como `postgres` no banco HOSPEDADO (Dashboard > SQL Editor).
-- ⚠️ NÃO é o bootstrap local: aqui só vai o que o postgres pode fazer.
-- (Este é o arquivo supabase/bootstrap/01-zerar_privilegios_remoto.sql.)

-- 1. Zerar os default privileges do proprio `postgres` (ele pode).
--    ⚠️ NAS DUAS FORMAS: o Postgres guarda os default privileges em uma
--    entrada GLOBAL (sem cláusula de schema) e outra POR SCHEMA
--    (`in schema public`), e as DUAS são aplicadas a um objeto novo.
--    Revogar só a global NÃO limpa a entrada por schema — e vice-versa.
--    A forma SEM `in schema public` cobre todos os schemas.
--    O `supabase_admin` nao e acessivel por senha no hospedado e o
--    `postgres` NAO PODE alterar os default privileges dele. Os defaults
--    do `supabase_admin` sao RISCO RESIDUAL ACEITO (ver §5.1): ele nao
--    cria nenhum dos nossos objetos, e o T42 confere os grants reais.
alter default privileges for role postgres
    revoke all on tables    from anon, authenticated;
alter default privileges for role postgres
    revoke all on functions  from anon, authenticated;
alter default privileges for role postgres
    revoke all on sequences from anon, authenticated;

alter default privileges for role postgres in schema public
    revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public
    revoke all on functions  from anon, authenticated;
alter default privileges for role postgres in schema public
    revoke all on sequences from anon, authenticated;

-- 2. Privilegios do app_owner no schema public.
grant usage, create on schema public to app_owner;
grant app_owner to postgres;

-- 3. O app_owner precisa de USAGE no schema auth para o auth.uid().
--    ⚠️ O schema `auth` pertence ao supabase_admin: o postgres pode
--    falhar aqui. Se falhar, o app_owner NAO precisa do schema auth,
--    porque todas as funcoes usam public.fn_usuario_atual(), que le o
--    GUC de sessao direto (sem resolver o schema auth).
--    Verifique com: select has_schema_privilege('app_owner','auth','usage');
--    Se der false, pule esta linha — e o app_owner precisa de USAGE em
--    auth.users APENAS para os helpers de TESTE (que somem no remoto).
--    grant usage on schema auth to app_owner;

-- 4. Leitura de auth.users para os helpers de teste (opcional no remoto).
-- grant select on auth.users to app_owner;

-- 5. O pgcrypto (extensions) precisa ser utilizavel pelo app_owner.
grant usage on schema extensions to app_owner;
grant execute on all functions in schema extensions to app_owner;

-- 6. CONFERENCIA em pg_default_acl (o passo 6 do script): mostra o estado
--    depois dos revokes, com TRES categorias —
--      • "ok" / "refazer o bootstrap": o que este script controla
--        (postgres/app_owner em public ou global);
--      • "risco residual aceito": defaults do `supabase_admin`
--        (ele nao cria nossos objetos; T42 confere os grants reais);
--      • "schema interno da plataforma": storage, graphql, graphql_public,
--        supabase_functions etc. (nao alterar).
```

✅ **Este arquivo já existe e está versionado:** `supabase/bootstrap/01-zerar_privilegios_remoto.sql` (com revokes nas duas formas e a conferência categorizada do §6). Sintaxe validada localmente em 12/11/2026 (rodou em transação com rollback, sem erro).

#### Como o `app_owner` fica sem `USAGE` no schema `auth`

Se o passo 3 falhar (esperado no hospedado), **não é bloqueio**:

- As funções de produção **não** chamam `auth.uid()` — todas usam `public.fn_usuario_atual()`, que lê o GUC de sessão (`request.jwt.claim.sub` / `request.jwt.claims`) **sem resolver o schema `auth`**.
- O único uso de `auth.users` é o helper de teste `test_criar_usuario()`, que **não existe no remoto** (os usuários são criados pela interface do Supabase, não por migration).
- `auth.uid()` é usado apenas nas **policies** (que rodam com os privilégios do usuário, `authenticated`, que tem USAGE no schema `auth` por padrão no Supabase).

⚠️ **Ação para você:** rode o passo 3 e me diga o resultado. Se der `ERROR: permission denied for schema auth`, rode sem a linha 3 — está comentado no script acima.

---

## 4. O `db push`, com dry-run

### 4.1 Vincular (uma vez)

```powershell
Set-Location G:\Anperez_Condominios

supabase login                    # abre o navegador, você autentica
supabase link --project-ref aejuoiwxzzsxmhhizwau
```

O `link` grava o `project_id` em `supabase/.temp/project-ref` e cria `supabase/.temp/` — que já está no `.gitignore`.

### 4.2 Conferir o que será aplicado (dry-run nativo)

✅ **O Supabase CLI 2.107 TEM dry-run nativo** — confirmado em `supabase db push --help`:

```
FLAGS
  --dry-run    Print the migrations that would be applied, but don't actually apply them.
```

**Use-o.** Ele imprime as migrations que seriam aplicadas, **sem aplicar nada**:

```powershell
# 1. O que o CLI acha que falta aplicar:
supabase migration list --linked

# 2. DRY-RUN: imprime as migrations que seriam aplicadas, sem aplicar:
supabase db push --linked --dry-run
```

⚠️ **Não use `--include-all` na primeira aplicação.** A flag reaplica migrations já registradas no histórico remoto — num primeiro push não há histórico, e forçar a inclusão de tudo mascararia a ordem real de aplicação e qualquer migration fora de ordem. Sem a flag, o CLI aplica exatamente as migrations que faltam, na ordem cronológica do nome do arquivo.

Comparação extra (opcional, mostra o diff de schema):
```powershell
supabase db diff --linked
```

Se o dry-run mostrar algo inesperado (uma migration fora de ordem, uma tabela a mais), **pare**.

### 4.3 Aplicar

```powershell
supabase db push --linked
```

Sem `--include-all`: o CLI aplica **exatamente** as migrations que faltam no remoto, na ordem cronológica do nome do arquivo. É a primeira aplicação — não há histórico remoto, então a lista é a migrada inteira.

⚠️ Se o `db push` reclamar que uma migration já foi aplicada (por causa de uma tentativa anterior interrompida), rode `supabase migration repair` — e me passe a saída antes de usar.

### 4.4 Ordem de aplicação e por que ela importa

A ordem das migrations não é decorativa — há dependências de criação:

| # | Migration | Depende de |
|---|---|---|
| 1 | `00100_enums` | — |
| 2 | `00200_condominios_perfis_membros` | 1 (roles `app_owner`, `app_importador` criados aqui) |
| 3 | `00250_helpers_revocacao` | 1 |
| 4 | `00260_helper_usuario` | 1 (`fn_usuario_atual()`) |
| 5 | `00300_unidades` | 2 |
| 6 | `00400_competencias_status` | 2 |
| 7 | `00500_fundos_rubricas_aliases` | 1, 2 |
| 8 | `00600_fontes_importacao_staging` | 2, 4 |
| 9 | `00700_lancamentos` | 5, 6, 7 |
| 10 | `00800_transferencias_duplicatas` | 9 |
| 11 | `00900_conciliacao_documentos` | 5, 7 |
| 12 | `01000_pendencias_auditoria` | 7, 9 |
| 13 | `01100_serie_historica` | 8 |
| 14 | `01200_papeis_rls_grants` | 2, 4 (helpers de papel + revoke global + policies) |
| 15 | `01300_views_agregadas` | 9, 12 |
| 16 | `01400_rpcs` | 12, 15 |
| 17 | `01500_storage_buckets` | 15 |
| 18 | `01600_lista_grants_permitidos` | 12 (usa a lista de grants como dado; testada pela bateria de drift) |
| 19 | `20261112001700_fase0_rpc_permissao` | 16 (create or replace das RPCs: permissão uniforme, casts de enum, on conflict por constraint; revoga e regrava grants) |
| 20 | `20261112001800_fase0_views_limiar` | 15, 19 (create or replace das views: limiar e gate de granularidade lidos de config_visibilidade; observação só para papel nominal) |
| 21 | `20261112001900_fase0_revoga_grants_permitidos` | 18 (revoga o SELECT de authenticated na lista; o drift roda como postgres) |

⚠️ **Se o `db push` falhar no meio**, o banco fica parcial. O CLI mostra a migration que falhou; corrija-a e rode `db push` de novo (o CLI retoma da próxima).

### 4.5 O seed NÃO é carregado no remoto (decisão de 12/11/2026)

⚠️ **Decisão: o `seed.sql` não será aplicado no banco hospedado.** O seed existe para o ambiente local abrir com dados fictícios e a bateria de testes passar nele. No remoto, ele traria um condomínio fictício inteiro para a produção.

O que isso significa, na prática:

- O banco hospedado nasce **vazio de aplicação**: as tabelas de estrutura, as views e as funções — **nenhuma configuração fictícia** (nada de "Condominio Residencial Exemplo", fundos, rubricas ou contas falsas).
- O **condomínio real**, os **fundos/rubricas/contas/aliases/unidades reais** e os **membros** (com contas reais convidadas por e-mail, confirmadas na primeira entrada) entram por um **script de início separado** — um `supabase\bootstrap\` próprio, ainda **não escrito**. Ele só será criado e aplicado **quando o importador estiver validado no local** (o script precisa que o formato de importação esteja fechado).
- Até lá, a validação remota limita-se a: conferências do §0/§3 (role, tabelas, grants) e ao **teste de drift (§5.1)**. Efeitos colaterais: o e2e remoto (§5.3) e qualquer validação com dado **não são possíveis** — dependem do script de início (ou de uma decisão explícita de carregar o seed, o que está descartado por ora).

⚠️ **Não rode** `supabase\seed.sql` no remoto. Se a carga de configuração real for feita pelo script de início, rodar o seed **junto** traria o condomínio fictício — e removê-lo depois quebraria as dependências do que for real.

---

## 5. Validação depois do push

### 5.1 O teste de drift de grants, contra o remoto

#### 5.1.1 Forma recomendada — colar no SQL Editor do painel

1. No painel do projeto, abra **SQL Editor → New query**.
2. Cole o conteúdo **INTEIRO** de `supabase\tests\05_drift_grants_remoto.sql`.
3. Execute (Ctrl+Enter). O script:
   - **não cria usuário**, não cria condomínio, não insere/atualiza/apaga nada do projeto;
   - usa uma **tabela temporária de sessão** para montar a resposta (some ao fechar a aba);
   - tem o escopo do **T46 FIXO** em `postgres` + `app_owner` (quem cria os nossos objetos no hospedado);
   - **não usa** meta-comandos do psql nem variáveis (`\set`, `\if`) — é SQL puro.
4. O resultado aparece como **duas tabelas**: a primeira lista as 6 verificações (uma linha por teste) e a segunda traz o resumo. Esperado:

   | resumo | falhas | verificacoes |
   |---|---|---|
   | `DRIFT OK — todos os 6 testes passaram` | 0 | 6 |

5. Se alguma linha vier com `resultado = 'FALHA'`, a coluna `detalhe` traz a lista completa do que está errado — me passe a tabela inteira.

#### 5.1.2 Alternativa — linha de comando (psql)

O teste `supabase/tests/05_drift_grants.test.sql` verifica que os grants de `authenticated`/`anon` batem com a **lista permitida**.

✅ **O teste é autocontido e seguro para o remoto.** Ele:
- **não cria usuário** e **não depende** de `00_preparacao.test.sql`;
- **não cria condomínio** e **não insere, altera ou apaga nada** (tudo é `SELECT`);
- **não depende de pgtap** (usa SQL puro com `RAISE EXCEPTION`);
- **lê a lista permitida do próprio banco** — a tabela `public.config_grants_permitidos`, criada pela migration `20261111001600`.

⚠️ **Não rode `00_preparacao.test.sql` no remoto.** Ele cria usuários com a senha fixa `teste12345` e os helpers de teste — ficariam no banco de produção.

Ele roda com `psql` no banco alvo (⚠️ exige psql instalado e `DATABASE_URL` apontando para o pooler em modo SESSÃO, porta 5432):

```powershell
# Aponta DATABASE_URL para o banco REMOTO (pooler em modo SESSAO, porta 5432)
$env:DATABASE_URL = "postgresql://postgres.<ref>:<senha>@aws-0-<regiao>.pooler.supabase.com:5432/postgres"

# ⚠️ SÓ o teste de drift: ele é autocontido e não cria usuário nem dado.
# ⚠️ No remoto, passe o ESCOPO do T46: só quem cria os nossos objetos
#    (postgres + app_owner) — os defaults do supabase_admin sao risco
#    residual aceito (ver abaixo).
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -v escopo_t46=postgres -f supabase\tests\05_drift_grants.test.sql
```

**O que ele verifica (T41–T46):**

| Teste | Verifica |
|---|---|
| T41 | Nenhuma tabela de **detalhe** tem privilégio para `anon`/`authenticated` |
| T42 | A lista real de grants bate **exatamente** com a lista permitida |
| T43 | `anon` não tem nenhum privilégio no schema `public` |
| T44 | Nenhuma função pública (fora as de teste) é executável por `anon` |
| T45 | Nenhuma função `SECURITY DEFINER` é executável por `anon` |
| T46 | Nenhum *default privilege* do **escopo** concede acesso a `anon`/`authenticated` |

#### O escopo do T46: `estrito` (local) × `postgres` (remoto)

O T46 é o **único** teste cujo escopo muda entre os ambientes, e o motivo é técnico:

| Ambiente | Comando | Escopo avaliado | Por quê |
|---|---|---|---|
| **Local** (bateria) | padrão (`estrito`) | `postgres` + `supabase_admin` + `app_owner` | O bootstrap local roda como `supabase_admin` e limpa os dois conjuntos — dá para ser estrito |
| **Remoto** | `-v escopo_t46=postgres` | `postgres` + `app_owner` | O `postgres` hospedado **não pode** alterar os default privileges de outro papel (só o dono pode) |

Sem a variável, o T46 assume `estrito` — se rodar no remoto sem `-v`, ele pode reportar falsos positivos dos defaults do `supabase_admin`.

**Risco residual aceito (decisão de 12/11/2026):** os *default privileges* do `supabase_admin` no remoto concedem acesso a `anon`/`authenticated`. Isso é aceitável porque:

1. O `supabase_admin` **não cria nenhum** dos nossos objetos — as migrations rodam como `postgres`;
2. Os defaults dele só valem se ele algum dia criar um objeto em `public`;
3. O **T42 continua conferindo os GRANTS REAIS** de tudo em `public` contra a lista permitida — a garantia real não muda;
4. Ajustá-los exigiria o Dashboard/Management API, e o benefício não compensa a intervenção.

Os *default privileges* dos schemas `storage`, `graphql`, `graphql_public` e `supabase_functions` são **internos da plataforma** e não são tocados (nem no T46 nem no bootstrap).

⚠️ **T46 é o que detecta a D2** (os default privileges do papel que cria os objetos). Se falhar no remoto, o ajuste é o passo 1 do §3.2 (refazer o bootstrap).

⚠️ **T42 é o que detecta qualquer tabela nova** que a plataforma cria por conta própria (por exemplo, `realtime.messages`, que o Supabase cria para o Realtime). Se aparecer, é preciso adicioná-la à lista permitida **ou** revogar o privilégio dela explicitamente.

✅ **O teste acumula todas as falhas numa única exceção** — uma execução contra o remoto mostra a lista completa do que está errado, não só o primeiro problema.

### 5.2 A bateria completa, contra o remoto

⚠️ **Adiada.** Com a decisão do §4.5 (sem seed, sem dado no remoto), a bateria pgTAP não tem dado para rodar lá — e não deve criar nada dele. A bateria foi validada no **local** (220 verificações verdes em 12/11/2026). No remoto, o que vale hoje é o drift do §5.1 e as conferências do §0/§3. As seções 5.2 e 5.3 ficam para **depois do script de início** existir (§4.5).

```powershell
# A bateria pgTAP completa, contra o remoto — SOMENTE apos o script de inicio.
# ⚠️ NÃO rode o 00_preparacao no remoto: ele cria usuários com senha fixa.
Get-ChildItem 'supabase\tests\0*.test.sql' |
    Where-Object { $_.Name -ne '00_preparacao.test.sql' } |
    ForEach-Object {
        Write-Host "=== $($_.Name) ==="
        psql $env:DATABASE_URL -q -v ON_ERROR_STOP=1 -f $_.FullName |
            Select-String -Pattern '^ ?(ok|not ok)|^NOTICE|^ERROR'
    }
```

⚠️ **A bateria precisa de adaptadores que só existem no local:**
- `00_preparacao.test.sql` cria usuários em `auth.users` com senha `teste12345` — **não rode no remoto sem querer**. No remoto, os usuários são reais (criados pela interface).
- Os helpers `test_*` são criados pela própria `00_preparacao` e **não fazem parte das migrations** — eles não vão para o remoto.

**Recomendação:** no remoto, rode **apenas o T41–T46 (drift de grants)** e o **teste e2e com usuários reais**. O restante da bateria já foi validado no local, e o código é o mesmo.

### 5.3 O teste e2e contra o remoto (com usuários reais)

⚠️ **Adiado (decisão de 12/11/2026, com o §4.5).** O e2e precisa de fundos, rubricas, contas, unidades e do condomínio de teste no banco. Como o seed não será carregado e o script de início ainda não existe, **o e2e remoto não é executável hoje**. O roteiro abaixo fica como referência para quando o script de início existir.

O `supabase/tests/e2e_rest.py` faz login pela API de autenticação e chama as funções/views pelo REST. Para rodar no remoto:

#### 5.3.1 Conexão — use o pooler em modo SESSÃO (porta 5432)

```powershell
$env:DATABASE_URL = "postgresql://postgres.<ref>:<senha>@aws-0-<regiao>.pooler.supabase.com:5432/postgres"
```

⚠️ **Porta 5432 = modo SESSÃO; porta 6543 = modo TRANSAÇÃO.**

O modo transação (6543) **não serve** para os testes:
- o `psql` roda cada comando em uma transação **distinta**, e o teste precisa de `set role`/`set_config` consistentes entre comandos;
- o pooler em modo transação faz *pool* de conexões — o `set_config` de sessão (o claim do JWT) pode ir para uma conexão e o comando seguinte para outra;
- `DROP`/`VACUUM` e operações de DDL são recusados.

O modo sessão (5432) mantém **uma** conexão para a sessão do `psql`, que é o que o `auth.uid()` e as policies esperam.

#### 5.3.2 Usuários de teste com senha FORTE

⚠️ **No remoto, use senhas fortes e exclusivas.** A senha `teste12345` do ambiente local **não pode** ir para produção: o `e2e_rest.py` a usa por padrão, e uma senha trivial em conta de teste é porta de entrada.

Crie os usuários no painel (Authentication > Users > Add user, com **"Auto Confirm User"** ligado) usando senhas como `Ts9#kQ2!vLm4` — únicas para cada usuário, geradas por você:

| Usuário | Papel | Condomínio |
|---|---|---|
| `leitor@condA.test` | `leitor` | A |
| `auditor@condA.test` | `auditor` | A |
| `leitor@condB.test` | `leitor` | B |

⚠️ **Não reutilize senha de nenhum outro sistema.**

#### 5.3.3 Preparar o banco

```sql
-- Pegue os ids no painel (Authentication > Users) e ajuste:
insert into public.condominios (id, nome) values
  ('11111111-1111-1111-1111-111111111111', 'Condominio A'),
  ('99999999-9999-9999-9999-999999999999', 'Condominio B')
on conflict (id) do nothing;

insert into public.perfis (id, nome, email)
select id, email, email from auth.users
 where email in ('leitor@condA.test','auditor@condA.test','leitor@condB.test')
on conflict (id) do nothing;

insert into public.membros (condominio_id, perfil_id, papel, ativo)
select '11111111-1111-1111-1111-111111111111', id, 'leitor',  true
  from auth.users where email = 'leitor@condA.test'
union all
select '11111111-1111-1111-1111-111111111111', id, 'auditor', true
  from auth.users where email = 'auditor@condA.test'
union all
select '99999999-9999-9999-9999-999999999999', id, 'leitor',  true
  from auth.users where email = 'leitor@condB.test'
on conflict (condominio_id, perfil_id, papel) do nothing;

-- As unidades do condominio de teste (sem o seed, este bloco cria o que o e2e precisa):
insert into public.unidades (condominio_id, numero, andar, posicao)
select '11111111-1111-1111-1111-111111111111',
       (a * 10 + p)::text, a, p
  from generate_series(1, 18) as a
 cross join generate_series(1, 4) as p
on conflict (condominio_id, numero) do nothing;

-- Politica de visibilidade
insert into public.config_visibilidade (condominio_id, papel, granularidade_max, limiar_minimo_unidades)
values ('11111111-1111-1111-1111-111111111111', 'auditor', 'unidade', 0),
       ('11111111-1111-1111-1111-111111111111', 'leitor',  'fundo',   5),
       ('99999999-9999-9999-9999-999999999999', 'leitor',  'fundo',   5)
on conflict (condominio_id, papel) do nothing;
```

#### 5.3.4 Ajustar e rodar o e2e

```powershell
# Copie o script e ajuste URL e senhas (NAO edite o original versionado):
Copy-Item 'supabase\tests\e2e_rest.py' 'supabase\tests\e2e_rest_remoto.py'

# No arquivo copiado:
#   API = "https://aejuoiwxzzsxmhhizwau.supabase.co"
#   SENHA = "<a senha forte que voce definiu>"
#   (as senhas podem ser diferentes por usuario: ajuste a funcao login)

python supabase\tests\e2e_rest_remoto.py
```

⚠️ **`e2e_rest_remoto.py` NÃO entra no Git** — ele tem senha. Adicione ao `.gitignore` ou apague depois de usar.

**Resultado esperado: 33/33.** Se alguma verificação falhar, **não continue** — me passe a saída.

#### 5.3.5 LIMPEZA OBRIGATÓRIA ao final

⚠️ **Ao terminar os testes, remova TUDO que foi criado para eles.** No banco de produção, conta de teste e condomínio de teste são Passivo — e a próxima pessoa que rodar o e2e não deve herdar dados velhos.

⚠️ **A ORDEM IMPORTA — testada localmente em 12/11/2026.** As colunas `*_por` (quem fez a operação) e as referências de negócio (`lancamentos.unidade_id`, `lancamento_rubrica.fundo_id`, `fontes_importacao.competencia_id` etc.) são `NO ACTION`, e o `ON DELETE CASCADE` do condomínio processa as filhas em ordem **indefinida** — apagar `unidades` (ou o condomínio) primeiro quebra a FK. Por isso: filhos de negócio **antes**, condomínio **depois**, usuários **por último**.

```sql
-- ============================================================================
-- LIMPEZA DO E2E — ORDEM FK-SEGURA (testada no local: rastro zero)
-- ============================================================================
begin;

-- 1. Membros (por condominio de teste OU por usuario de teste)
delete from public.membros
 where condominio_id in ('11111111-1111-1111-1111-111111111111',
                         '99999999-9999-9999-9999-999999999999')
    or perfil_id in (select id from auth.users
                      where email in ('leitor@condA.test','auditor@condA.test','leitor@condB.test'));

-- 2. Negocio em ordem FK-segura (filhos antes dos pais)
delete from public.anexos              where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.conciliacao_detalhe where conciliacao_id in (select id from public.conciliacoes where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999'));
delete from public.conciliacoes        where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.lancamento_rubrica  where lancamento_id in (select id from public.lancamentos where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999'));
delete from public.transferencias_internas where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.duplicatas_candidatas   where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.documentos          where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.contestacoes        where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.pendencia_anotacoes where pendencia_id in (select id from public.pendencias where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999'));
delete from public.pendencias          where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.lancamentos         where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.grupos_transferencia where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.staging_lancamentos where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.staging_transacoes  where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.staging_duplicatas  where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.importacoes         where fonte_id in (select id from public.fontes_importacao where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999'));
delete from public.fontes_importacao   where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.status_competencia  where competencia_id in (select id from public.competencias where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999'));
delete from public.competencias        where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.serie_historica_anotacoes where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.serie_historica_resumo    where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.contas_origem       where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.rubrica_aliases     where rubrica_id in (select id from public.rubricas where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999'));
delete from public.rubricas            where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.fundos              where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.unidades            where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.config_visibilidade where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');
delete from public.config_retencao_acesso where condominio_id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');

-- 3. LOGS — por condominio E por usuario de teste (evita rastro com
--    condominio nulo apontando para um perfil de teste)
delete from public.auditoria_log
 where condominio_id in ('11111111-1111-1111-1111-111111111111',
                         '99999999-9999-9999-9999-999999999999')
    or usuario_id in (select id from auth.users
                       where email in ('leitor@condA.test','auditor@condA.test','leitor@condB.test'));
delete from public.acesso_log
 where condominio_id in ('11111111-1111-1111-1111-111111111111',
                         '99999999-9999-9999-9999-999999999999')
    or usuario_id in (select id from auth.users
                       where email in ('leitor@condA.test','auditor@condA.test','leitor@condB.test'));

-- 4. Convites e condominios (por ultimo — sem dependentes restantes)
delete from public.convites
 where condominio_id in ('11111111-1111-1111-1111-111111111111',
                         '99999999-9999-9999-9999-999999999999');
delete from public.condominios
 where id in ('11111111-1111-1111-1111-111111111111',
              '99999999-9999-9999-9999-999999999999');

commit;
```

⚠️ **Depois do `commit`** (e só depois): **apague os 3 usuários no painel** (Authentication > Users). O `perfis.id → auth.users` é CASCADE, e nenhuma linha de log restante referencia os perfis de teste — a exclusão não vai dar erro de FK.

⚠️ **Confira que sobrou nada** (o e2e grava em `auditoria_log` e `acesso_log`, então os logs entram na conferência):
```sql
select count(*) as usuarios_de_teste from auth.users
 where email like '%@condA.test' or email like '%@condB.test' or email like '%@test.test';

select count(*) as condominios_de_teste from public.condominios
 where id in ('11111111-1111-1111-1111-111111111111','99999999-9999-9999-9999-999999999999');

select count(*) as perfis_de_teste from public.perfis
 where id in (select id from auth.users
              where email like '%@condA.test' or email like '%@condB.test');

select count(*) as lancamentos from public.lancamentos;   -- deve ser 0

select count(*) as auditoria_log from public.auditoria_log;   -- deve ser 0
select count(*) as acesso_log    from public.acesso_log;      -- deve ser 0
```

**TUDO precisa dar 0.** Em especial os dois últimos: os logs de auditoria e acesso do e2e têm de sair junto — senão ficam de rastro no banco de produção.

---

### 5.4 Checklist de aceite do remoto

- [ ] `supabase db push` aplicou as **21** migrations sem erro (a ordem está no §4.4)
- [ ] **Nenhuma** configuração fictícia no remoto: o seed NÃO foi aplicado (§4.5) e não há condomínio de teste
- [ ] `select count(*) from public.lancamentos` → **0** (nenhum dado real subiu)
- [ ] As 6 verificações de drift de grants verdes contra o remoto (T41–T46) — pelo SQL Editor (§5.1.1) ou por psql (§5.1.2)
- [ ] e2e 33/33 contra o remoto, com usuários reais — **somente após o script de início** (§4.5/§5.3)
- [ ] (Se o e2e tiver rodado) Limpeza do §5.3.5 executada: conferência final **tudo 0** — inclusive `auditoria_log` e `acesso_log`
- [ ] Nenhum arquivo de dado no Git (`git ls-files | Select-String -Pattern '\.(xls|xlsx|csv|pdf)$'` → vazio)
- [ ] O repositório GitHub está **privado**

---

## 6. O `git push`

### 6.1 Antes do push: confirme que o repositório é privado

```
No GitHub: Settings > General > Danger Zone > "Change repository visibility"
Deve estar em PRIVATE.
```

⚠️ **Por que isso importa mesmo com o `.gitignore`:** o `.gitignore` impede que um arquivo **novo** de dado entre. Ele **não** remove um arquivo já commitado. E o histórico do Git guarda todas as versões. Um repositório privado é a garantia de que, mesmo que algo entre por engano, o dado não fica exposto.

### 6.2 Preparar o remote

```powershell
Set-Location G:\Anperez_Condominios

git remote add origin https://github.com/andreperez27/Anperez_condominios.git
git remote -v
```

⚠️ Se o repositório **já** tiver esse remote, o `add` falha com "remote origin already exists" — nesse caso use `git remote set-url origin <url>`.

### 6.3 Conferir o que será enviado

```powershell
# O que será enviado:
git ls-files --others --exclude-standard

# ⚠️ VERIFICAÇÃO OBRIGATÓRIA: nenhum arquivo de dado pode aparecer.
$arquivosDeDado = git ls-files |
    Select-String -Pattern '\.(xls|xlsx|xlsm|csv|pdf|db|sqlite|pem|key)$'
if ($arquivosDeDado) {
    Write-Host '❌ ARQUIVO DE DADO VERSIONADO — PARE' -ForegroundColor Red
    $arquivosDeDado
} else {
    Write-Host '✅ nenhum arquivo de dado' -ForegroundColor Green
}

# Nenhuma credencial:
$credenciais = git ls-files |
    Select-String -Pattern '(\.env|secret|service_role|\.pem$|\.key$)'
if ($credenciais) {
    Write-Host '❌ POSSÍVEL CREDENCIAL — PARE' -ForegroundColor Red
    $credenciais
} else {
    Write-Host '✅ nenhuma credencial' -ForegroundColor Green
}
```

### 6.4 O push

```powershell
git push -u origin main
```

### 6.5 Depois do push

```powershell
git status              # deve estar limpo
git log --oneline -3
```

---

## 7. O que configurar no painel do Supabase

### 7.1 Autenticação — cadastro público DESATIVADO

| Configuração | Valor | Por quê |
|---|---|---|
| **Enable email signup** | **DESATIVADO** | Com cadastro público aberto, qualquer pessoa cria conta e — se houver um `membro` com o mesmo e-mail — ganha acesso. O fluxo correto é **convite** (`fn_convite`/tabela `convites`) |
| **Enable phone signup** | DESATIVADO | Não usamos telefone |
| **Confirm email** | Ativado | Os usuários de teste são criados por convite; sem confirmação, o e-mail pode ser typosquatado |
| **Password strength** | **Mínimo 12 caracteres** | ⚠️ **Controle principal** desta tabela — dado financeiro exige senha longa |
| **Leaked password protection** | Ativado, **se disponível no plano** | Proteção complementar (consulta a listas vazadas). Alguns planos não oferecem — nesse caso, o mínimo de 12 caracteres (acima) é o controle que fica |
| **JWT expiry** | 3600 s (padrão) | Não aumentar |

⚠️ **Com "Enable email signup" desativado, o `e2e_rest.py` funciona?** Sim — o login por senha continua disponível; só o **cadastro** é bloqueado. O `signUp` é que falha. O script usa `/auth/v1/token?grant_type=password` (login), não `signUp`. Mas os usuários precisam existir: no remoto, crie-os pelo painel.

### 7.2 API — schemas expostos

| Configuração | Valor | Por quê |
|---|---|---|
| **Exposed schemas** | `public`, `graphql_public` | `public` é o schema do app. **Não** exponha `auth`, `storage` ou `extensions` pela Data API. Se o passo opcional do §7.7 (desativar o `pg_graphql`) for feito, `graphql_public` pode sair desta lista — sobra só `public` |
| **Extra search path** | `public`, `extensions` | ⚠️ É o que o `search_path` da sessão fica — e é a razão de o `auth.uid()` falhar. **Não** adicione `auth` aqui: o `fn_usuario_atual()` existe justamente para não depender disso |

⚠️ **Se `auth` for exposto**, o `anon`/`authenticated` poderiam consultar `auth.users` diretamente — e o `auth.users` tem e-mail de toda pessoa com conta. Não exponha.

⚠️ **Verifique `auto_expose_new_tables`** (Advanced Settings): deve estar **desativado** (ou o padrão novo, que não expõe). Se estiver ligado, qualquer tabela nova nasce pública pela API.

### 7.3 Storage

| Configuração | Valor |
|---|---|
| Bucket `anexos` | privado (`public = false`) — criado pela migration 015 |
| Limite de arquivo | 25 MB |
| MIME types | `application/pdf`, `image/png`, `image/jpeg`, `image/webp` |

⚠️ O bucket é criado pela migration. Se o `db push` falhar antes dela, crie pelo painel (Storage > New bucket) com **as mesmas** configurações — a migration 015 usa `ON CONFLICT DO UPDATE`, então ela se ajusta se o bucket já existir.

### 7.4 Região

| Item | Recomendação |
|---|---|
| Região do projeto | A **mais próxima** de você e dos usuários (São Paulo → `sa-east-1`) |
| Pooler | Habilitado (o `db push` usa a conexão direta; o app usa o pooler) |
| IPv4 | Habilitado se o seu provedor exigir (Supabase free tem limite de conexões) |

⚠️ **A região é escolhida na criação do projeto** e não muda depois. Se o projeto `aejuoiwxzzsxmhhizwau` já existe, a região já está definida — descubra em Settings > Database > Region.

### 7.5 Rede e conexões

| Configuração | Valor | Por quê |
|---|---|---|
| **Restrição de rede** | Se houver IP fixo em casa/servidor, restrinja por IP | O `service_role` bypassa RLS |
| **Pooler (porta 6543)** |.transaction ou.session | O `session` é necessário se você quiser `SET ROLE` nos testes remotos |
| **Limite de conexões** |Ajuste conforme o plano | O importador + front + testes abrem várias |

### 7.6 PWA / Analytics / Logs

| Item | Recomendação |
|---|---|
| PWA | Desativado (não é app instalável nesta fase) |
| Analytics | Desativado ou no mínimo — **evita que dado de uso viaje para fora** |
| Logs / Logflare | Pode ficar ligado (é infraestrutura do Supabase), mas **não envie dado de condomínio para lá** |
| **Sentry / observabilidade externa** | **Não configurar** enquanto houver dado real em trânsito |

---

### 7.7 Opcional: desativar a extensão `pg_graphql`

**O app não usa GraphQL** — nem vai usar: o front fala só com a Data API REST (`/rest/v1`) e com os RPCs. O `pg_graphql` é instalado por padrão em todo projeto Supabase e expõe um endpoint GraphQL (`/graphql/v1`) que, aqui, é superfície de ataque sem função.

**Passo opcional, mas recomendado.** Fazer no painel:

| Passo | Onde | Como |
|---|---|---|
| 1. Desativar o endpoint GraphQL | Settings > API Settings | Desligar **"Enable GraphQL"** (ou remover `graphql_public` dos *Exposed schemas*) |
| 2. Remover a extensão (opcional, mais completo) | Database > Extensions | Desativar **`pg_graphql`** — o schema `graphql_public` deixa de expor objetos |

⚠️ **Ordem:** desative primeiro o endpoint (passo 1); só remova a extensão (passo 2) se nada no painel reclamar. Remover a extensão **não toca** no schema `public` nem nos nossos objetos — é uma extensão isolada no schema `graphql`.

⚠️ **Efeito colateral esperado:** depois do passo 2, o `pg_default_acl` passa a não mostrar mais defaults do `supabase_admin` em `graphql`/`graphql_public` — uma superfície a menos. O teste de drift (T46, escopo `postgres`) não é afetado.

⚠️ **Se algo do app começar a chamar `/graphql/v1` no futuro** (não é o plano), o passo é reversível: reative a extensão no painel.

## 8. Checklist geral de implantação

```powershell
# ── 1. Pré-requisitos
Set-Location G:\Anperez_Condominios
supabase login
supabase link --project-ref aejuoiwxzzsxmhhizwau

# ── 2. Testar se o app_owner com BYPASSRLS pode ser criado + se o
#       postgres hospedado tem BYPASSRLS (ver §3.1)
#       (Dashboard > SQL Editor)

# ── 3. Zerar os default privileges do postgres no remoto (§3.2)
#       (Dashboard > SQL Editor, com supabase\bootstrap\01-zerar_privilegios_remoto.sql)

# ── 4. Conferir o dry-run antes de aplicar (§4.2)
supabase migration list --linked
supabase db push --linked --dry-run

# ── 5. Aplicar (sem --include-all)
supabase db push --linked

# ── 6. O seed NAO E aplicado no remoto (decisao de 12/11/2026, ver secao 4.5).
#       O condominio REAL + membros entram pelo script de inicio, quando o
#       importador estiver validado no local.

# ── 7. Validar: drift de grants pelo SQL Editor (secao 5.1.1)
#       (o e2e e a limpeza ficam para depois do script de inicio)

# ── 8. Git (§6)
git remote add origin https://github.com/andreperez27/Anperez_condominios.git
git ls-files | Select-String -Pattern '\.(xls|xlsx|csv|pdf)$' | ForEach-Object { Write-Host 'PARE' }
git push -u origin main
