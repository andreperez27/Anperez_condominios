# Estrutura do repositório — ANPEREZ CONDOMÍNIOS

**Data:** 11/11/2026
**Status:** proposta — **nenhuma pasta, arquivo ou repositório Git foi criado**. Este documento descreve a estrutura que será criada após sua aprovação.
**Bases:** decisões D7 (escopo), D8 (fundos/transferências), D10 (leitor só agregado); `docs\MODELO_DADOS.md`, `docs\SEGURANCA_RLS.md`, `docs\IMPORTACAO.md`.

---

## 1. Visão geral

Monorepo com três partes independentes, cada uma com seu ciclo:

```
┌──────────────────────────────────────────────────────────────────┐
│  front/            React + Vite (TypeScript)                     │
│  ▸ dashboard do condomínio, conferência de importação,          │
│    pendências, conciliação                                       │
├──────────────────────────────────────────────────────────────────┤
│  supabase/         Postgres + Auth + RLS                         │
│  ▸ migrations/ (versionadas) ▸ seed ▸ config                     │
├──────────────────────────────────────────────────────────────────┤
│  scripts/          Python (importador, testes, utilitários)      │
│  ▸ importacao/ (parsers por layout) ▸ testes/ (pytest)           │
└──────────────────────────────────────────────────────────────────┘
        ↕ apenas via API do Supabase (HTTPS, com RLS)
```

**Regra de fluxo:** o Python **nunca** escreve em `lancamentos` — só em `staging_*`. O front **nunca** lê tabela de detalhe sem ser o papel certo. O banco é o ponto de encontro, e as regras estão nele (RLS + RPC).

---

## 2. Árvore real (após os passos 1 a 3)

```
G:\Anperez_Condominios\
│
├── .gitignore                      # bloqueia *.xls/*.xlsx/*.pdf/*.csv globalmente
├── AGENTS.md                        # instruções para agentes (convenções e armadilhas)
├── README.md                        # o que é, papéis, regras de ouro, comandos
│
├── docs\                            # ✅ já existe — documentação de projeto (versionada)
│   ├── INVENTARIO_DADOS.md
│   ├── QUALIDADE_DADOS.md
│   ├── MODELO_DADOS.md
│   ├── SEGURANCA_RLS.md
│   ├── IMPORTACAO.md
│   ├── ESTRUTURA_REPO.md
│   └── DIARIO_DE_BORDO.md
│
├── front\                           # ⏳ Fase 1 — criado só a pasta public/
│   └── public\
│       └── logo.png
│
├── supabase\
│   ├── config.toml                  # project_id = anperez_condominios
│   ├── seed.sql                     # carga de CONFIGURAÇÃO (fictícia)
│   ├── bootstrap\
│   │   ├── 00-zerar_privilegios_padrao.sql   # roda como supabase_admin
│   │   └── reset_local.ps1          # orchestrator do ambiente local
│   ├── migrations\                 # ✅ 16 migrations, aplicadas do zero
│   │   ├── 20261111000100_fase0_enums.sql
│   │   ├── 20261111000200_fase0_condominios_perfis_membros.sql
│   │   ├── 20261111000250_fase0_helpers_revocacao.sql
│   │   ├── 20261111000260_fase0_helper_usuario.sql
│   │   ├── 20261111000300_fase0_unidades.sql
│   │   ├── 20261111000400_fase0_competencias_status.sql
│   │   ├── 20261111000500_fase0_fundos_rubricas_aliases.sql
│   │   ├── 20261111000600_fase0_fontes_importacao_staging.sql
│   │   ├── 20261111000700_fase0_lancamentos.sql
│   │   ├── 20261111000800_fase0_transferencias_duplicatas.sql
│   │   ├── 20261111000900_fase0_conciliacao_documentos.sql
│   │   ├── 20261111001000_fase0_pendencias_auditoria.sql
│   │   ├── 20261111001100_fase0_serie_historica.sql
│   │   ├── 20261111001200_fase0_papeis_rls_grants.sql
│   │   ├── 20261111001300_fase0_views_agregadas.sql
│   │   ├── 20261111001400_fase0_rpcs.sql
│   │   └── 20261111001500_fase0_storage_buckets.sql
│   └── tests\                      # ✅ 53 testes de segurança (pgTAP)
│       ├── 00_preparacao.test.sql
│       ├── 01_leitor_tabela_detalhe.test.sql
│       ├── 02_granularidade_limiar.test.sql
│       ├── 03_isolamento_condominios.test.sql
│       ├── 04_papeis_importador_anexos.test.sql
│       ├── 05_drift_grants.test.sql
│       └── run_tests.ps1            # runner da bateria
│
├── scripts\                        # ⏳ Fase 1 — ainda não criado
│   └── importacao\
│
├── dados_origem\                   # ⏳ criado na Fase 1 — IGNORADO pelo Git
└── dados_trabalho\                 # ⏳ criado na Fase 1 — IGNORADO pelo Git
```

### 2.1 Por que `supabase/bootstrap/` existe

Os *default privileges* que dão acesso a `anon`/`authenticated` pertencem ao papel `supabase_admin` (não ao `postgres`, que não é superuser no Supabase local). Revogá-los de dentro de uma migration **não é possível** — o `postgres` recebe `permission denied to change default privileges`.

Por isso o revoke roda **fora** das migrations, num script que é executado como `supabase_admin`:

```powershell
pwsh -File supabase\bootstrap\reset_local.ps1
```

O script faz 4 passos: espera o banco, zera os privilégios padrão, instala `pgtap`/`pgcrypto`, e carrega o seed.

⚠️ **O bootstrap é obrigatório antes dos testes.** Sem ele, objetos novos nascem com acesso do `anon`/`authenticated` e a garantia do leitor se quebra.

### 2.2 O `project_id` do config.toml é LOCAL

```
project_id = "anperez_condominios"
```

É o identificador do ambiente local (nomeia os containers do Docker) — **não** é o project ref remoto. O projeto Supabase remoto é:

- URL: `https://aejuoiwxzzsxmhhizwau.supabase.co`
- ref: `aejuoiwxzzsxmhhizwau`

Para vincular o ambiente local ao remoto:

```bash
supabase link --project-ref aejuoiwxzzsxmhhizwau
```

⚠️ O `supabase link` pede o `SUPABASE_ACCESS_TOKEN` (ou a senha do banco remoto). Ele **não** foi executado — nenhuma migration foi aplicada no projeto remoto.

## 3. Onde fica cada coisa (e por quê)

| Item | Local | Racional |
|---|---|---|
| Documentação de projeto | `docs\` (versionado) | É a entrega da Fase 0 e precisa ser revisável |
| Dados brutos do condomínio | `dados_origem\` (**ignorado**) | Dado de terceiros e sensível (inadimplência, consumo por unidade) |
| Código do importador | `scripts\importacao\` | Python separado do front: ciclo e ferramentas diferentes |
| Migrations | `supabase\migrations\` | Versionadas, aplicadas em ordem; o banco é reconstruível do zero |
| Dados do banco | Supabase (Postgres gerenciado) | Com RLS, backups e Auth |
| Anexos (comprovantes escaneados) | Bucket privado do Supabase Storage | Fica junto do banco, com as mesmas policies; URL assinada |
| Cópia local do diário | `docs\DIARIO_DE_BORDO.md` | **Proposta:** o diário fica só em `docs\` — não duplicar na raiz |

---

## 4. `.gitignore`

```gitignore
# ─────────────────────────────────────────────────────────────
# DADOS DO CONDOMÍNIO — nunca versionar (LGPD + sigilo)
# ─────────────────────────────────────────────────────────────
dados_origem/
dados_trabalho/
*.env
*.env.*
!.env.example

# extratos, balancetes, caixas locais, planilhas de dados
*.xls
*.xlsx
*.xlsb
*.xlsm
*.pdf
*.csv
!docs/**/*.md
!supabase/seed.sql
!supabase/migrations/*.sql
!scripts/**/*.csv

# ─────────────────────────────────────────────────────────────
# SEGREDOS E CHAVES
# ─────────────────────────────────────────────────────────────
*.pem
*.key
*.p12
*.pfx
secrets/
credentials/
.service-account*.json
supabase/.temp/
supabase/.branches/
.env.local
.env.*.local

# ─────────────────────────────────────────────────────────────
# PYTHON
# ─────────────────────────────────────────────────────────────
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
.venv/
venv/
env/
.mypy_cache/
.pytest_cache/
.ruff_cache/
.coverage
coverage.xml
htmlcov/
*.egg-info/
dist/
build/
.uv/
uv.lock.bak

# ─────────────────────────────────────────────────────────────
# NODE / FRONT
# ─────────────────────────────────────────────────────────────
node_modules/
dist/
dist-ssr/
.vite/
*.local
coverage/
.eslintcache

# ─────────────────────────────────────────────────────────────
# EDITORES E SO
# ─────────────────────────────────────────────────────────────
.vscode/*
!.vscode/extensions.json
!.vscode/settings.json
.idea/
.DS_Store
Thumbs.db
desktop.ini
*.swp
*.swo
*~

# ─────────────────────────────────────────────────────────────
# ARQUIVOS DE DADOS GERADOS (redundante com o bloco de dados,
# mantido por clareza)
# ─────────────────────────────────────────────────────────────
output/
*.sqlite
*.sqlite3
*.db
*.dump
*.bak
```

### 4.1 Por que `\*.pdf` e `\*.xlsx` estão bloqueados globalmente

A regra mais importante do `.gitignore` é a **negativa global** de formatos de dado. Sem ela, basta um `git add .` numa pasta com a planilha-resumo para versionar **dados de inadimplência por unidade** no repositório.

As exceções (`!docs/**/*.md`, `!supabase/migrations/*.sql`, `!supabase/seed.sql`) garantem que:
- a documentação Markdown seja versionada (ela é `.md`, não é bloqueada, mas a exceção explicita documenta a intenção);
- as migrations e o seed entrem — mas **revisados**: o `seed.sql` não pode conter dado nominal.

⚠️ **Cuidado com `seed.sql`:** ele vai no Git. Deve conter apenas **dados de configuração** (condomínio com nome e CNPJ, 7 fundos, 24 rubricas, aliases, 72 unidades, 94 contas de origem com código e descrição). **Nenhum lançamento, nenhum valor, nenhuma unidade com situação financeira.** Se no futuro o condomínio virar produto multi-cliente, o seed vira template e os dados de cada condomínio entram por importação.

### 4.2 `.env.example` (versionado, sem valores)

```bash
# ── Supabase ──────────────────────────────────────────────
VITE_SUPABASE_URL=https://xxxxxxxxxxxx.supabase.co
VITE_SUPABASE_ANON_KEY=

# ── Somente para o script Python (fora do .env do front) ──
# Use SUA_URL e SUA_SENHA de um role dedicado (app_importador),
# NÃO a service_role_key.
IMPORTADOR_DATABASE_URL=
```

⚠️ `VITE_SUPABASE_ANON_KEY` é embutida no bundle do front **por design** — não é segredo. A proteção é a RLS. `IMPORTADOR_DATABASE_URL` (com senha) **não** vai para o front e **nunca** é versionado.

### 4.3 Onde a pasta antiga fica

`C:\Users\andre\Desktop\condominio` **não** é copiada para dentro do repositório de forma versionada. O fluxo é:

```
C:\Users\andre\Desktop\condominio   (origem, SOMENTE LEITURA)
        │
        │  scripts/copiar_origem.py  (copia, nunca move)
        ▼
G:\Anperez_Condominios\dados_origem\   (ignorado pelo Git)
        │
        │  scripts/importacao
        ▼
   Supabase: fontes_importacao → staging → (aprovação) → lancamentos
```

---

## 5. Versionamento das migrations

### 5.1 Convenção de nomes
```
AAAAMMDDHHMMSS_descricao_curta.sql
20261111000100_fase0_enums.sql
```
Sequencial, ordenável, sem ambiguidade.

### 5.2 Regras de conteúdo
- **Uma migration, uma finalidade.** Nada de "misc".
- Sempre com `create table if not exists` / `drop policy if exists` — a migration deve ser **idempotente**, para poder ser reaplicada em ambiente de teste.
- `create or replace function` em vez de `create function`, para permitir evolve sem dropar.
- Todo `create policy` vem acompanhado do `drop policy` correspondente.
- Comentário no topo da migration com: o que faz, por quê, e de qual documento de `docs\` ela veio.
- **Nenhuma migration contém dado de negócio.** Dado vai no `seed.sql` (configuração) ou entra por importação (dados reais).

### 5.3 Ordem sugerida
| # | Migration | Conteúdo |
|---|---|---|
| 1 | `enums` | `papel_membro`, `fonte_contabil`, `status_fonte`, `status_classificacao`, `natureza_rubrica`, `natureza_fundo`, `status_transferencia`, `status_duplicata`, `status_pendencia`, `status_conciliacao`, `tipo_movimento`, `status_lancamento`, `status_importacao`, `status_staging`, `criterio_duplicata`, `gravidade_pendencia`, `origem_pendencia`, `tipo_pendencia`, `tipo_documento`, `status_anexo`, `fonte_alias` |
| 2 | `condominios_perfis_membros` | `condominios`, `perfis`, `membros`, `convites` |
| 3 | `unidades` | `unidades` + carga das 72 |
| 4 | `competencias_status` | `competencias`, `status_competencia` |
| 5 | `fundos_rubricas_aliases` | `fundos`, `rubricas`, `rubrica_aliases`, `contas_origem` |
| 6 | `fontes_importacao_staging` | `fontes_importacao`, `importacoes`, `staging_*` |
| 7 | `lancamentos` | `lancamentos`, `lancamento_rubrica` |
| 8 | `transferencias_duplicatas` | `grupos_transferencia`, `transferencias_internas`, `duplicatas_candidatas` |
| 9 | `conciliacao_documentos` | `conciliacoes`, `conciliacao_detalhe`, `documentos`, `anexos` |
| 10 | `pendencias_auditoria` | `pendencias`, `pendencia_anotacoes`, `contestacoes`, `auditoria_log`, `acesso_log` |
| 11 | `serie_historica` | `serie_historica_resumo`, `serie_historica_anotacoes` |
| 12 | `roles_grants_rls` | roles `app_owner` (BYPASSRLS) e `app_importador`, `revoke` global, helpers `fn_papeis_do_usuario`/`fn_e_membro`/`fn_condominios_do_usuario`, policies, `granularidade_ordem`, `config_visibilidade` |
| 13 | `views_agregadas` | as views de `MODELO_DADOS` §17 |
| 14 | `rpcs` | `fn_aprovar_staging`, `fn_reconciliar_competencia`, `fn_resumo`, `fn_lancamentos`, `fn_contestar_lancamento`, `fn_liberar_anexo_para_leitor`, `fn_gerar_url_anexo`, … |
| 15 | `storage_buckets` | bucket `anexos` privado + policies de `storage.objects` |

⚠️ **A ordem importa:** `roles_grants_rls` (12) vem **depois** das tabelas, porque o `revoke all on all tables in schema public from anon, authenticated` precisa vir depois que todas as tabelas existem — senão uma tabela criada depois fica com o privilégio padrão do Supabase. Por isso a policy 12 faz `revoke` **e** o item 15 (storage) é a última.

### 5.4 Testes de segurança (pgTAP)

```
supabase/tests/rls_lancamentos.test.sql          # leitor não lê tabela de detalhe
supabase/tests/rls_leitor_agregados.test.sql     # agregado é agregado; limiar funciona
supabase/tests/rls_multitenant.test.sql         # nada vaza entre condomínios
supabase/tests/rls_papeis.test.sql              # papel avaliado por condomínio
supabase/tests/rpc_privilegios.test.sql          # função recusa quem não tem papel
supabase/tests/storage_anexos.test.sql           # anexo bloqueado por padrão
supabase/tests/acesso_log.test.sql               # toda escrita e toda leitura do leitor ficam registradas
```

**Personas de teste:** `leitor_cond_a`, `auditor_cond_a`, `leitor_cond_b` (outro condomínio), `sindico_cond_a`, e o role `app_importador`. A sessão de cada persona é simulada com `set local request.jwt.claims`.

A **bateria completa (40 cenários T01–T40)** está em `SEGURANCA_RLS.md` §11. Os 9 grupos que resumem a bateria:

| # | Grupo | O que se verifica |
|---|---|---|
| 1 | Leitor x tabela de detalhe | `select` e `count(*)` em `lancamentos`, `unidades`, `pendencias`, `duplicatas_candidatas`, `acesso_log` → `permission denied` |
| 2 | Leitor x função privilegiada | `fn_aprovar_staging`, `fn_classificar_lancamento`, `fn_decidir_duplicata`, `fn_contestar_lancamento`, `fn_liberar_anexo_para_leitor` → `exception 42501` |
| 3 | Leitor x granularidade | `fn_resumo(..., 'unidade')` e `'rubrica'` recusadas; `'fundo'` aceita |
| 4 | Isolamento entre condomínios | leitor do B **não** vê agregados do A; `fn_resumo` do condomínio alheio → `42501`; `fn_lancamentos` do alheio → sem linhas |
| 5 | Síndico | lê o próprio; **não** classifica (`42501`); **pode** contestar; não contesta no condomínio alheio |
| 6 | Importador | grava em `staging_*`; **não** grava nem lê `lancamentos`; **não** aprova |
| 7 | Storage | anexo não liberado → negado; liberado → permitido; anexo do outro condomínio → negado |
| 8 | Bruto x líquido | `v_resultado_bruto` devolve **todos** os lançamentos (não subtrai transferências) |
| 9 | Limiar de agregação | grupo com 2 unidades → valores `NULL` e `suprimido = true` para o leitor; valores presentes para o auditor (limiar 0) |

⚠️ **Regra do CI:** o build **falha** se qualquer cenário de segurança falhar. Não é "nice to have" — é o que garante que a garantia do leitor não foi quebrada por uma migration futura.

---

## 6. `.gitignore` — pontos que merecem atenção sua

| Ponto | Decisão | Por quê |
|---|---|---|
| `*.pdf` bloqueado globalmente | Sim | A pasta antiga tem 87 PDFs (atas, notas fiscais, extratos). Versionar qualquer um pode expor dado de assembleia ou de fornecedor |
| `*.xlsx` bloqueado globalmente | Sim | 75 planilhas, várias com consumo e inadimplência por unidade |
| `*.csv` bloqueado globalmente | Sim | 38 CSVs do `output\` antigo, todos derivados e cheios de dado por unidade |
| `dados_origem/` e `dados_trabalho/` | Sim | Dupla camada: mesmo que o global falhe, a pasta fica de fora |
| `supabase/seed.sql` | **Permitido** | Contém só configuração (fundos, rubricas, aliases, unidades, contas) — **sem lançamento e sem valor**. Precisa de revisão antes do commit |
| `docs/` | **Permitido** | Documentação; deve conter **exemplos anonimizados**, nunca linhas com unidade + valor |
| `.env*` com exceção só para `.env.example` | Sim | Nenhuma chave no Git |
| `*.db`, `*.sqlite` | Sim | Se algum dia houver cache local do importador, ele fica fora |

⚠️ **Revisão humana obrigatória antes do primeiro `git commit`:** o `git add -A` seguido de `git status` precisa mostrar **zero** arquivo de dado. Sugiro um comando de verificação no CI:
```bash
git ls-files | grep -Ei '\.(xls|xlsx|csv|pdf|db|sqlite|pem|key)$' && echo "❌ ARQUIVO DE DADO VERSIONADO — revisar" && exit 1
```

---

## 7. Onde o app Money entra

Você mencionou seguir o padrão do Anperez Money. Este é o esqueleto que ele já tem e que aqui será reproduzido:

| Padrão do Money | Aplicação aqui |
|---|---|
| RLS multi-tenant | `condominio_id` em tudo + helpers `fn_condominios_do_usuario()` / `fn_papeis_do_usuario()` |
| RPCs atômicas para operações compostas | `fn_aprovar_staging`, `fn_reconciliar_competencia`, `fn_classificar_lancamento`, `fn_decidir_duplicata`, `fn_confirmar_transferencia` |
| Migrations versionadas | `supabase\migrations\`, uma por finalidade, idempotentes |
| Diário de bordo do projeto | `docs\DIARIO_DE_BORDO.md`, atualizado a cada decisão |
| `.gitignore` que exclui dados | §4 |

⚠️ **Para casar os detalhes** (nomes dos roles, formato das policies, se as functions são `security definer` ou `invoker`, convenção de nomes de RPC, estrutura de pastas do front), preciso do **caminho do código do Anperez Money**. Não fui procurar sozinho, conforme você pediu. Me passe o caminho e eu ajusto esta proposta antes de criar qualquer arquivo.

---

## 8. Sequência de criação — **passos 1 a 3 concluídos**

| Ordem | Passo | Entregável verificável |
|---|---|---|
| 1 | `git init` + `.gitignore` + `README.md` + `AGENTS.md` | `git status` limpo, nenhum dado versionado |
| 2 | `docs\` finalizada + `DIARIO_DE_BORDO.md` | 6 documentos de projeto versionados |
| 3 | `supabase/migrations\` — migrations 1 a 11 (schema) | `supabase db reset` roda do zero sem erro |
| 4 | `supabase/seed.sql` — condomínio, fundos, rubricas, aliases, unidades, contas de origem | 7 fundos, 24 rubricas, ~120 aliases, 72 unidades, 94 contas |
| 5 | Migration 12 (roles, grants, RLS) + testes pgTAP | **40 cenários de segurança passam** (T01–T40), incluindo "leitor não lê lançamento" e "leitor do B não vê agregados do A" |
| 6 | Migrations 13–15 (views, RPCs, storage) | `fn_resumo` retorna agregado; `fn_aprovar_staging` recusa leitor |
| 7 | `scripts/` — `pyproject.toml`, `copiar_origem.py`, `detectar.py` | relatório de detecção: 18 extratos, 19 balancetes, 18 caixas locais, 1 planilha |
| 8 | `scripts/importacao/` — parsers + fixtures + testes | **os 18 extratos fecham contra o próprio bloco RESUMO** |
| 9 | `scripts/importacao/` — normalizar, classificar, duplicatas, gravar_staging | staging populado, idempotente |
| 10 | `front/` — Vite + layout + login + `VisaoGeral` (agregado) | leitor e auditor veem o mesmo dashboard agregado |
| 11 | `front/` — `ImportacaoConferencia` + `Pendencias` | você aprova linha a linha |
| 12 | Primeiro ciclo real: importar 2025-05 e conferir | 575 lançamentos em `lancamentos`, conciliado por fundo |
| 13 | Importar 2025-06 … 2026-10 | 11.439 lançamentos, 18 competências conciliadas |

---

## 9. Riscos e como são tratados

| Risco | Impacto | Tratamento |
|---|---|---|
| Dado pessoal versionado por engano | Alto (LGPD) | Negativa global de formatos + revisão antes do commit + check no CI |
| Chave ou senha no repositório | Alto | `.env*` ignorado; `service_role_key` fora do ambiente do front; importador usa role próprio |
| Importador escrever direto em `lancamentos` | Alto (dados não conferidos) | Role `app_importador` sem `INSERT` em `lancamentos`; só `staging_*` |
| Parser ler errado em silêncio | Alto (contabilidade errada) | Verificação de fechamento contra o RESUMO **antes** do staging; layout desconhecido vira pendência |
| Classificação errada esconder dinheiro | Alto | `v_resultado_bruto` como padrão; transferências só subtraem após confirmação humana |
| Duplicata descartada | Médio (dinheiro real perdido) | Duplicatas nunca descartadas; só marcadas e decididas |
| Ter um condomínio só e o modelo não escalar | Médio | Tudo escopado por `condominio_id` desde a migration 1; papéis já prontos para multi-cliente |
| Migração applied só em dev | Médio | `supabase db reset` no CI; migrations idempotentes |
| Segredo em variável de ambiente vazar em log | Médio | Importador nunca loga a URL completa; redaction no logger |

---

## 10. O que **não** foi decidido

- **Nome do repositório Git** e se será público ou privado — recomendo **privado**, mesmo com o `.gitignore` robusto: o histórico do Git guarda versões, e uma planilha esquecida num commit antigo continua no histórico. (O app antigo `app_condominial` está com remote no GitHub — vale verificar o que já foi commitado lá.)
- **Licença** (MIT / Apache-2.0 / outra) — só importa se o projeto for aberto.
- **Nome do pacote Python** (`importacao` vs `anperez_import`) e do projeto front (`front` vs `web` vs `app`).
- **Orquestrador de ambiente**: `uv` (rápido, lockfile único) vs `poetry` vs `pip` + `requirements.txt`. Recomendo `uv`.
- **Ferramenta de teste do front**: `vitest` + Testing Library, ou só `playwright` para e2e.
- **CI**: GitHub Actions (se o repo for no GitHub) com `supabase db reset`, `pytest` e `npm run build`.
- **Se o diário de bordo fica em `docs\` ou na raiz** — proponho só em `docs\`.
- **Padrão de commits e branch**: `main` + `develop`? `main` só? Commits convencionais (Conventional Commits)?
- **Domínio e hospedagem do front**: Vercel, Netlify, Cloudflare Pages ou self-host?

---

## 11. O que a implementação revelou (12/11/2026)

### 9.1 O passo 3 está concluído e é reproduzível

```powershell
supabase db reset                                   # aplica as 16 migrations do zero
pwsh -File supabase\bootstrap\reset_local.ps1     # bootstrap + seed
pwsh -File supabase\tests\run_tests.ps1           # 53 testes de segurança
```

**Resultado: 53/53 testes verdes, BUILD OK.** O `db reset` roda limpo e o ciclo inteiro é reproduzível do zero.

### 9.2 O `.gitignore` foi testado contra dado real

A regra negativa global (`*.xls`, `*.xlsx`, `*.pdf`, `*.csv`) garante que a pasta de dados do condomínio nunca entre no Git — mesmo com um `git add .` distraído.

Verificação sugerida para o CI:

```bash
git ls-files | grep -Ei '\.(xls|xlsx|csv|pdf|db|sqlite|pem|key)$' \
  && echo "ARQUIVO DE DADO VERSIONADO" && exit 1
```

### 9.3 O que ainda NÃO existe (Fase 1)

- `scripts/importacao/` — o importador Python (parsers por layout, normalização, gravação do staging).
- `front/src/` — o app React (dashboard, conferência de importação, pendências).
- `dados_origem/` e `dados_trabalho/` — as pastas de trabalho (ignoradas pelo Git).

### 9.4 O `.gitignore` precisou de um ajuste

O logo do projeto (`front/public/logo.png`) foi colocado na raiz durante a execução e movido para `front/public/`. Arquivos de **marca** podem ser versionados; arquivos de **dado** não. A regra global cobre `*.xls`, `*.xlsx`, `*.pdf`, `*.csv` — nenhum formato de imagem, então o logo está correto onde está.

