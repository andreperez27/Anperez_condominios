# Proposta de modelo de dados — ANPEREZ CONDOMÍNIOS (Fase 0 + parte contábil)

**Data:** 11/11/2026
**Status:** proposta — nada foi criado no banco. Este documento descreve o que *será* feito após sua aprovação.
**Bases:** `docs\INVENTARIO_DADOS.md`, `docs\QUALIDADE_DADOS.md`, decisões D7–D12 do diário de bordo.

---

## 1. Princípios de desenho

| # | Princípio | Origem |
|---|---|---|
| P1 | O **condomínio é a unidade central** desde a primeira migration. Tudo que é financeiro ou pessoal é escopado por `condominio_id`. | Requisito do usuário |
| P2 | Todo dado importado guarda **arquivo de origem, hash do arquivo, aba ou página e linha de origem** — sem exceção. | Requisito 5 do usuário |
| P3 | **Nada é gravado automaticamente.** Tudo passa por área de conferência (`staging`) e só entra em `lancamentos` por aprovação explícita. | Requisito 6 do usuário |
| P4 | Importação é **idempotente**: reimportar o mesmo arquivo não duplica nada; reimportar arquivo re-exportado acrescenta só o que é novo. | Requisito 6 |
| P5 | Classificação tem **estado**: `sugerida` (vinda do mapeamento) ou `confirmada` (decidida por humano). Nenhuma sugestão vira verdade sozinha. | Requisito 3 |
| P6 | **Classificação errada não pode esconder dinheiro.** O consolidado nunca subtrai transferência interna por padrão; a exclusão só existe numa visão derivada e separada. | Requisito 2 |
| P7 | **Duplicatas não são descartadas.** Linhas repetidas são sinalizadas como *candidatas* e decidas por humano. Dois pagamentos iguais no mesmo dia podem ser legítimos. | Requisito 4 |
| P8 | Tudo que é sensível (unidade ↔ situação financeira) fica atrás de RLS + revogação de privilégio, com o leitor sem `SELECT` direto nas tabelas de detalhe. | Decisão D10 |
| P9 | O modelo nasce **multi-condomínio** mesmo hoje com um só condomínio. Não há coluna "imóvel", há `condominio_id`. | Requisito do usuário |
| P10 | Lacunas são **primeira classe**: competência sem balancete é "sem fonte", não "mês vazio". | Resposta do usuário |
| P11 | Achados e pendências são **tabela de primeira classe**, não anotação em planilha. | Resposta do usuário |
| P12 | **O papel é sempre avaliado por condomínio.** Uma pessoa tem um papel *em um condomínio*; as policies e funções testam o papel contra o condomínio da própria linha. | Correção de 11/11/2026 |
| P13 | **Uma única fonte de verdade por estado.** O estado de uma transferência interna mora só em `transferencias_internas.status`; o estado de uma classificação só em `lancamento_rubrica.status`; o estado de uma duplicata só em `duplicatas_candidatas.status`. | Correção de 11/11/2026 |
| P14 | **Papel não é privilégio de banco.** No fluxo padrão do Supabase todos os autenticados são `authenticated`; a separação de papéis acontece dentro de views e funções, não em `GRANT` separado. | Correção de 11/11/2026 |

---

## 2. Convenções

- **Competência**: chave canônica `YYYY-MM`, sempre derivada do **mês de referência**, nunca da data do documento. Guardada decomposta (`ano`, `mes`) para agregação e como `date` para ordenar.
- **Valores**: `numeric(14,2)`, sempre positivos, com `tipo_movimento` (`credito`/`debito`) ao lado. Um valor com sinal misturado é fonte de bug; o sinal vem do tipo.
- **Datas**: `date` puro. Nenhuma data em formato brasileiro ou ISO fica gravada; a conversão acontece na entrada.
- **Nomes de coluna**: `snake_case`, em português, sem acento, sem cedilha.
- **Chave natural de linha**: hash SHA-256 de uma tupla estável **mais o número da ocorrência da linha idêntica dentro do arquivo** (§8.4), guardada em `chave_natural`, com `UNIQUE (condominio_id, chave_natural)`. É a base da idempotência **e** permite que duplicatas reais sejam inseridas e marcadas.
- **Soft delete** só onde faz sentido (rubricas, unidades, aliases). Lançamentos não são apagados: têm `status` ('ativo','estornado','cancelado') + `estornado_por_lancamento_id`.
- **Auditoria**: toda decisão humana gera registro em `auditoria_log` (quem, quando, o que mudou, valor antes/depois).
- **Acesso**: toda escrita e toda leitura do leitor geram registro em `acesso_log` (§12B).

---

## 3. Mapa de entidades

```
auth.users ──┐
             ▼
        perfis ───► membros ───► condomínios ───┬──► unidades
                              │                │
                              │                ├──► competencias ───► status_competencia
                              │                │
                              │                ├──► fundos
                              │                │
                              │                ├──► rubricas ───► rubrica_aliases
                              │                │
                              │                ├──► contas_origem (código do extrato → rubrica + fundo)
                              │                │
                              │                ├──► fontes_importacao ───► importacoes
                              │                │                              │
                              │                │                              ▼
                              │                │                        staging_lancamentos
                              │                │                        staging_transacoes
                              │                │                        staging_duplicatas
                              │                │                              │ (aprovação → RPC atômica)
                              │                │                              ▼
                              │                ├──► lancamentos ──┬──► lancamento_rubrica
                              │                │                 ├──► grupo_transferencia ──► transferencias_internas
                              │                │                 ├──► duplicatas_candidatas
                              │                │                 ├──► documentos ──► anexos
                              │                │                 ├──► contestacoes
                              │                │                 └──► pendencias ──► pendencia_anotacoes
                              │                ├──► conciliacoes ──► conciliacao_detalhe
                              │                ├──► serie_historica_resumo
                              │                ├──► config_visibilidade
                              │                ├──► granularidade_ordem
                              │                ├──► auditoria_log
                              │                └──► acesso_log
                              └──► convites
```

---

## 4. Fase 0 — Condomínio, pessoas e papéis

### 4.1 `condominios`
```
id              uuid pk default gen_random_uuid()
nome            text not null
cnpj            text null            -- formato 00.000.000/0000-00, unique quando preenchido
endereco        text null
cidade          text null
uf              char(2) null
ativo           boolean not null default true
criado_em       timestamptz not null default now()
atualizado_em   timestamptz not null default now()
```
Uma linha hoje: *Condomínio Residencial Quinta de Niágara*, CNPJ 1706... (a ser preenchido).

### 4.2 `perfis` (extensão de `auth.users`)
```
id              uuid pk references auth.users(id) on delete cascade
nome            text not null
email           text not null
criado_em       timestamptz not null default now()
```
Perfis não carregam condomínio nem papel — isso é da tabela de membros.

### 4.3 `membros` (a junta central: condomínio × pessoa × papel)
```
id              uuid pk
condominio_id   uuid not null references condominios(id) on delete cascade
perfil_id       uuid not null references perfis(id) on delete cascade
papel           papel_membro not null
ativo           boolean not null default true
convidado_em    timestamptz null
aceitou_em      timestamptz null
criado_em       timestamptz not null default now()
unique (condominio_id, perfil_id, papel)
```
Enum `papel_membro`:
| Papel | Existe hoje | Previsão |
|---|---|---|
| `auditor` | ✅ (você) | Admin da contabilidade do condomínio: lê tudo, escreve, aprova importações, classifica, decide duplicatas, fecha competência. |
| `leitor` | ✅ (Sr. Adilson) | Somente leitura, visão agregada. Sem `SELECT` em tabelas de detalhe. |
| `sindico` | ⏳ futuro | Responsável pela gestão: precisa da visão nominal de unidades do **próprio condomínio**, e do fluxo de comprovação de despesas (aprovar/rejeitar comprovante de caixa local). |
| `conselho_fiscal` | ⏳ futuro | Fiscalização: leitura nominal restrita (lançamentos e conciliação, sem alterar classificação) + relatório de parecer. |
| `admin_plataforma` | ⏳ futuro | Operação da plataforma (multi-condomínio), fora do domínio de um condomínio. |

O enum já nasce com os 5 valores: acrescentar papel depois é `ALTER TYPE ... ADD VALUE`, sem reescrever policies.

### 4.4 `convites`
```
id            uuid pk
condominio_id uuid not null references condominios(id) on delete cascade
email         text not null
papel         papel_membro not null
token_hash    text not null unique     -- nunca o token em claro
expira_em     timestamptz not null
aceito_em     timestamptz null
criado_em     timestamptz not null default now()
```

### 4.5 `unidades` (entidade, conforme D9)
```
id            uuid pk
condominio_id uuid not null references condominios(id) on delete cascade
numero        text not null            -- '11'..'184' como texto: preserva o zero à esquerda original
andar         smallint null
posicao       smallint null            -- 1..4 dentro do andar
descricao     text null                -- 'Apto 74 Bloco 1' etc. — hoje não existe na base
ativa         boolean not null default true
criado_em     timestamptz not null default now()
unique (condominio_id, numero)
```
- `numero` é **texto**, não inteiro: o extrato usa `UN.000033` (6 dígitos) e a planilha usa `000013` (6 dígitos) — o mesmo imóvel aparece com zeros à esquerda diferentes. Texto normalizado sem zeros resolve, mas guardar o original evita perda.
- `andar`/`posicao` são derivados de `numero` na carga inicial (18 andares × 4) e ficam editáveis.
- `descricao` fica vazia hoje — **não há nome de morador em nenhuma fonte**. A chave de privacidade é o par (unidade, situação financeira).

---

## 5. Competências e status por fonte

### 5.1 `competencias`
```
id             uuid pk
condominio_id  uuid not null references condominios(id) on delete cascade
ano            smallint not null check (ano between 2000 and 2100)
mes            smallint not null check (mes between 1 and 12)
data_inicio    date not null
data_fim       date not null
fechada_em     timestamptz null
fechada_por    uuid null references perfis(id)
unique (condominio_id, ano, mes)
```

### 5.2 `status_competencia` — o status é **por fonte** (resposta do usuário)
```
id             uuid pk
competencia_id uuid not null references competencias(id) on delete cascade
fonte          fonte_contabil not null   -- 'extrato' | 'balancete' | 'caixa_local' | 'planilha_resumo'
status         status_fonte not null     -- 'sem_fonte' | 'importado' | 'conciliado' | 'fechado'
observacao     text null
atualizado_em  timestamptz not null default now()
atualizado_por uuid null references perfis(id)
unique (competencia_id, fonte)
```
Enums:
```
fonte_contabil  := ('extrato','balancete','caixa_local','planilha_resumo')
status_fonte    := ('sem_fonte','importado','conciliado','fechado')
```
Semântica:
- `sem_fonte` — competência existe mas não há documento daquela fonte. **Aparece como pendência no painel**, não como zero.
- `importado` — o arquivo foi lido, passou pela conferência e foi aprovado.
- `conciliado` — há conciliação da competência **sem divergência** (por fundo).
- `fechado` — competência formalmente encerrada pelo auditor (competência é o objeto do "período" na prestação de contas futura).

Situação atual, com as decisões do usuário:

| Competência | Extrato | Balancete | Caixa local | Planilha-resumo |
|---|---|---|---|---|
| 2020-05 … 2024-06 | sem_fonte | sem_fonte | sem_fonte | importado |
| 2024-07 … 2024-12 | sem_fonte | sem_fonte | sem_fonte | importado |
| 2025-01 | sem_fonte | importado | sem_fonte | importado |
| 2025-02 … 2025-04 | sem_fonte | **sem_fonte** | **sem_fonte** | importado |
| 2025-05 … 2026-10 | importado | importado | importado | importado |

Regra de promote: `sem_fonte → importado` quando o `status_competencia` é gravado pelo `approve` da importação; `importado → conciliado` quando existe conciliação da competência sem divergência em nenhum fundo; `conciliado → fechado` por ação explícita do auditor.

---

## 6. Fundos — entidade própria (requisito 1)

```
fundos
id             uuid pk
condominio_id  uuid not null references condominios(id) on delete cascade
codigo         text not null             -- 'CC' | 'BENF' | 'FR' | 'PINT' | 'SAL' | 'PA' | 'APL'
nome           text not null             -- 'CONTA CONDOMÍNIO', 'BENFEITORIAS', ...
natureza       natureza_fundo not null   -- 'principal' | 'fundo' | 'aplicacao_financeira'
prefixo_conta  text null                 -- '1', '15', '19', '2', '3', '10'
ativo          boolean not null default true
unique (condominio_id, codigo)
```
Enum `natureza_fundo`: `principal` (CONTA CONDOMÍNIO), `fundo` (BENFEITORIAS, FUNDO DE RESERVA, FUNDO DE PINTURA, SALÃO DE FESTAS), `aplicacao_financeira` (APLICAÇÃO BANCO EXEMPLO).

Carga inicial a partir da análise do prefixo dos códigos do extrato:

| Fundo | Códigos do extrato | Prefixo | Natureza |
|---|---|---|---|
| CONTA CONDOMÍNIO | 1001, 1002, 1006, 1010, 1015, 1023, 1024, 1026, 1041, 1042, 1050, 1052, 1098, 1099, 1102, 1521, 1561–1583, 1592, 1610–1624, 1634, 1641–1649, 1653, 1662, 1667, 1677, 1681, 1685, 1690, 1693, 1702, 1712, 1714, 1721, 1723, 1725, 1732, 1733, 1743, 1747, 1770, 1772, 1803, 1818, 1820, 1821 | `1` | principal |
| MANUTENÇÃO DE PINTURA | 15001, 15002, 15007, 15005, 15500, 15501, 15998, 15999 | `15` | fundo |
| SALÃO DE FESTAS | 19001, 19002, 19005, 19500, 19998, 19999 | `19` | fundo |
| PORTA AUTOMÁTICA | 10003, 10500 | `10` | fundo |
| BENFEITORIAS | 2001, 2002, 2003, 2005, 2500, 2501, 2998, 2999 | `2` | fundo |
| FUNDO DE RESERVA | 3001, 3002, 3003, 3005, 3500, 3998, 3999 | `3` | fundo |
| APLICAÇÃO BANCO EXEMPLO | (não tem código próprio no extrato; é rubrica da planilha-resumo) | — | aplicacao_financeira |

⚠️ **Atenção ao prefixo:** `1`, `10`, `15` e `19` começam igual. Por isso o prefixo serve só como **heurística de fallback** para códigos novos; a fonte de verdade é o mapeamento explícito em `contas_origem` (§8.3).

---

## 7. Rubricas, aliases e catálogo de contas

### 7.1 `rubricas` — a taxonomia canônica
```
id             uuid pk
condominio_id  uuid not null references condominios(id) on delete cascade
codigo         text not null             -- 'COTA_CONDOMINIAL', 'CONSUMO_AGUA', 'ALUGUEL'...
nome           text not null             -- rótulo exibido
natureza       natureza_rubrica not null -- 'receita' | 'despesa' | 'transferencia' | 'patrimonio'
fundo_padrao   uuid null references fundos(id)
unidade_de_medida text null              -- 'R$', 'm3', 'kWh', 'un'
ativo          boolean not null default true
criado_em      timestamptz not null default now()
unique (condominio_id, codigo)
```
Enum `natureza_rubrica`: `receita`, `despesa`, `transferencia`, `patrimonio`.

Carga inicial: as **24 categorias** já existentes no `mapa_contas.yaml` viram rubricas canônicas (`COTA_CONDOMINIAL`, `AGUA`, `GAS`, `FUNDO_RESERVA`, `BENFEITORIAS`, `SALAO_FESTAS`, `MULTAS`, `ACORDOS`, `CORRECAO_MONETARIA`, `RENDIMENTO_APLICACAO`, `TRANSFERENCIA_ENTRE_CONTAS`, `RECEITAS_EVENTUAIS`, `MANUTENCOES_DIVERSAS`, `TAXA_ADMINISTRACAO`, `ATRASO_COTA_CONDOMINIAL`, `ATRASO_BENFEITORIAS`, `ATRASO_FUNDO_RESERVA`, `ATRASO_SALAO_FESTAS`, `MANUT_PINTURA`, `PORTA_AUTOMATICA_RECEITAS`, `ENERGIA_AREA_COMUM`, `DESPESA_AGUA`, `DESPESA_GAS`, `TRIBUTOS_FOLHA`, `CAIXA_LOCAL`, `DIVERSOS`, `RECEITAS_FUNDO_RESERVA`, `ESTORNO`).

### 7.2 `rubrica_aliases` — a ponte entre as três taxonomias (requisito 3)
```
id          uuid pk
rubrica_id  uuid not null references rubricas(id) on delete cascade
fonte       fonte_alias not null     -- 'extrato' | 'planilha_resumo' | 'balancete' | 'manual'
alias       text not null            -- texto EXATO como aparece na fonte
contexto    text null                -- opcional: quando o mesmo alias designa coisas diferentes
            -- ex.: 'CONSUMO DE AGUA' no extrato = receita (1052) e despesa (1642)
prioridade  smallint not null default 100
ativo       boolean not null default true
unique (fonte, alias, contexto)
```
Enum `fonte_alias`: `extrato`, `planilha_resumo`, `balancete`, `manual`.

Exemplos de alias que o modelo precisa absorver:

| Fonte | Alias exato | → Rubrica |
|---|---|---|
| extrato | `COTAS CONDOMINIAIS` | COTA_CONDOMINIAL |
| extrato | `CONSUMO DE AGUA` (contexto `receita:1052`) | AGUA |
| extrato | `CONSUMO DE AGUA` (contexto `despesa:1642`) | DESPESA_AGUA |
| extrato | `MULTAS` / `MULTAS ARRECADADAS` | MULTAS |
| extrato | `COTAS RECEB.P/ANTECIPACAO` / `COTAS RECEB P/ANTECIPACAO` | ANTECIPACOES |
| extrato | `TRANSF. REGUL. ENTRE CONTAS` / `TRANSF.REGUL. ENTRE CONTAS` / `TRANSFERENCIAS` | TRANSFERENCIA_ENTRE_CONTAS |
| extrato | `TELEFONE` / `TELEFONE / INTERNET` | TELEFONE_INTERNET |
| planilha_resumo | `CONTA CONDOMINIO` | COTA_CONDOMINIAL |
| planilha_resumo | `Mant. PINTURA` / `MANUT. PINTURA` | MANUT_PINTURA |
| planilha_resumo | `APLICAÇÃO BANCO EXEMPLO` / `APLICACAO BANCO EXEMPLO` | RENDIMENTO_APLICACAO |
| planilha_resumo | `FDO P/TROCA TUBULACAO GAS` | TROCA_TUBULACAO_GAS |
| balancete | `CONTA BENFEITORIAS` | BENFEITORIAS |
| balancete | `MANUTENCAO DE PINTURA` | MANUT_PINTURA |
| balancete | `DESPESAS COM PESSOAL`, `ENCARGOS SOCIAIS`, `CONCESSAO DE SERVICOS`, `REGUL. DESPESAS ENTRE CONTAS`, … | rubricas de despesa correspondentes (hoje 184 linhas ficavam `CONTA_NAO_MAPEADA_*`) |

O campo `contexto` resolve o caso "mesmo alias, sentidos diferentes" (CONSUMO DE AGUA) sem duplicar a rubrica.

### 7.3 `contas_origem` — o catálogo do código contábil da administradora
```
id                uuid pk
condominio_id     uuid not null references condominios(id) on delete cascade
codigo            text not null        -- '1002', '1642', '1723'...
descricao_origem  text not null        -- 'COTAS CONDOMINIAIS' (como vem no extrato)
fundo_id          uuid not null references fundos(id)
rubrica_id        uuid null references rubricas(id)
status            status_classificacao not null  -- 'sugerida' | 'confirmada'
origem_sugestao   text null            -- 'mapa_contas.yaml' | 'palavra_chave' | 'manual'
justificativa     text null
decidido_por      uuid null references perfis(id)
decidido_em       timestamptz null
unique (condominio_id, codigo)
```
Estado `status_classificacao`: `sugerida` | `confirmada`.

Carga inicial: os **94 códigos** observados no extrato consolidado. Os 41 que já têm regra viram `sugerida` (mapeamento direto) ou `confirmada` (você confirma na conferência). Os **55 sem mapeamento** entram como `sugerida` via palavra-chave ou `sem rubrica` — e viram pendência.

### 7.4 Classificação por lançamento
Nem toda rubrica é dedutível só do código: em 2026-04, `1647 MANUT AREAS COMUNS` recebeu o Doc-230 da Fornecedor Exemplo (pintura) — mesma conta, uso diferente. Por isso a classificação é **por lançamento**:

```
lancamento_rubrica
lancamento_id       uuid not null references lancamentos(id) on delete cascade
rubrica_id          uuid not null references rubricas(id)
fundo_id            uuid not null references fundos(id)
status              status_classificacao not null  -- 'sugerida' | 'confirmada'
origem              origem_classificacao not null -- 'conta' | 'palavra_chave' | 'manual' | 'importacao'
confianca           numeric(4,3) null             -- 0..1, só para 'sugerida'
justificativa       text null
decidido_por        uuid null references perfis(id)
decidido_em         timestamptz null
primary key (lancamento_id)
```
O `lancamento_rubrica` é 1:1 com o lançamento (uma rubrica por lançamento), mas fica em tabela separada porque o histórico de decisão (quem, quando, de qual rubrica veio) é o que uma auditoria exige.

---

## 8. Fontes de importação e rastreabilidade

### 8.1 `fontes_importacao`
```
id                 uuid pk
condominio_id      uuid not null references condominios(id) on delete cascade
fonte              fonte_contabil not null
nome_arquivo       text not null
caminho_relativo   text not null       -- relativo à pasta de dados de origem, versionada fora do Git
hash_sha256        text not null       -- do arquivo inteiro
tamanho_bytes      bigint not null
layout             text not null       -- 'extrato_v1' | 'extrato_v2' | 'extrato_v3' | 'extrato_xlsx_v1'
                                           | 'balancete_v1' | 'caixa_local_v1' | 'planilha_resumo_v1'
                                           | 'leitura_agua_v1' | 'leitura_gas_v1'
aba                text null           -- aba da planilha
pagina_inicio      int null
pagina_fim         int null
competencia_id     uuid null references competencias(id)
detectado_em       timestamptz not null default now()
status             status_fonte_arquivo not null -- 'detectado'|'importado'|'ignorado_duplicata'|'erro'
mensagem           text null
unique (condominio_id, hash_sha256, layout)
```
O `unique (condominio_id, hash_sha256, layout)` é a **trava de idempotência de arquivo**: o mesmo conteúdo nunca vira duas fontes. Re-exportação (hash diferente) vira fonte nova, e as linhas repetidas são reconhecidas pela `chave_natural`.

### 8.2 `importacoes` (execuções)
```
id               uuid pk
fonte_id         uuid not null references fontes_importacao(id) on delete cascade
iniciada_em      timestamptz not null default now()
concluida_em     timestamptz null
status           status_importacao not null -- 'em_andamento'|'concluida'|'erro'|'cancelada'
linhas_lidas     int not null default 0
linhas_novas     int not null default 0
linhas_atualizadas int not null default 0
linhas_rejeitadas  int not null default 0
erro             text null
executado_por    uuid null references perfis(id)
```

### 8.3 `lancamentos` — a tabela central (requisito 5, sem exceção)
```
id                uuid pk
condominio_id     uuid not null references condominios(id) on delete cascade
competencia_id    uuid not null references competencias(id)
fundo_id          uuid not null references fundos(id)
unidade_id        uuid null references unidades(id)

data_lancamento   date not null
data_vencimento   date null
data_documento    date null

valor             numeric(14,2) not null check (valor >= 0)
tipo_movimento    tipo_movimento not null   -- 'credito' | 'debito'

historico         text not null             -- texto cru, como no extrato
documento         text null                 -- RB./RC./CB.
codigo_conta      text not null             -- '1002'
descricao_conta   text not null             -- 'COTAS CONDOMINIAIS'
referencia_extraida text null               -- 'RC.UN.000012'

-- ===== RASTREABILIDADE (sempre preenchido) =====
fonte_id          uuid not null references fontes_importacao(id)
hash_arquivo      text not null             -- cópia do hash da fonte (não depende de join)
arquivo_nome      text not null
aba               text null
pagina            int null
linha_origem      int not null              -- linha na planilha / página no PDF
coluna_origem     int null
texto_origem      text null                 -- linha bruta, para conferência sem reabrir o arquivo

-- ===== CLASSIFICAÇÃO =====
status_classificacao status_classificacao not null default 'sugerida'
origem_classificacao origem_classificacao not null default 'importacao'

-- ===== TRANSFERÊNCIA INTERNA (P6: não afeta o consolidado) =====
grupo_transferencia_id uuid null references grupos_transferencia(id)
-- ⚠️ O estado da transferência NÃO mora aqui. A única fonte de verdade é
--    transferencias_internas.status (§9). O lançamento apenas aponta para o grupo.

status            status_lancamento not null default 'ativo'  -- 'ativo'|'estornado'|'cancelado'
chave_natural     text not null
numero_ocorrencia smallint not null default 1   -- nº da ocorrência da linha idêntica dentro do arquivo (§8.4)
criado_em         timestamptz not null default now()
criado_por        uuid null references perfis(id)
atualizado_em     timestamptz not null default now()
unique (condominio_id, chave_natural)
unique (condominio_id, fonte_id, linha_origem, numero_ocorrencia)
```
Enums:
```
tipo_movimento     := ('credito','debito')
status_classificacao := ('sugerida','confirmada')
origem_classificacao := ('conta','palavra_chave','manual','importacao','planilha')
status_transferencia := ('sugerida','confirmada','rejeitada')   -- só existe em transferencias_internas
status_lancamento := ('ativo','estornado','cancelado')
status_duplicata  := ('pendente','duplicata_confirmada','nao_duplicata')
```
⚠️ O enum `status_transferencia` **não tem** o valor `nao_aplicavel`: um lançamento que não é transferência interna simplesmente **não tem** `grupo_transferencia_id` preenchido, e portanto não tem linha em `transferencias_internas`. "Não é transferência" e "transferência ainda não revisada" são coisas diferentes, e o modelo só precisa registrar a segunda.

**`hash_arquivo`, `arquivo_nome`, `linha_origem` são denormalizados de propósito**: a auditoria precisa ser respondida com uma query só, mesmo que a fonte seja removida do disco.

### 8.4 `chave_natural` — a fórmula, com número da ocorrência

A chave tem **duas partes**: uma tupla semântica (o "fato contábil") e o número da ocorrência da linha idêntica dentro do arquivo.

```
-- 1. a tupla semântica: identifica o FATO
tupla = condominio_id || '|' ||
         competencia_ano || '-' || competencia_mes || '|' ||
         codigo_conta || '|' ||
         data_lancamento || '|' ||
         coalesce(documento,'') || '|' ||
         tipo_movimento || '|' ||
         valor_formatado_2casas || '|' ||
         historico_normalizado

-- 2. o número da ocorrência: distingue linhas IDÊNTICAS no mesmo arquivo
numero_ocorrencia = quantas vezes a MESMA tupla já apareceu antes NESTE arquivo,
                     contando de 1 (a primeira ocorrência é 1)

-- 3. a chave final
chave_natural = sha256(tupla || '#' || numero_ocorrencia)
```

**Por que o número da ocorrência é necessário** (requisito seu nº 5):

Sem ele, as duas linhas idênticas do arquivo (`RC.UN.000183` repetido nas linhas 527 e 528 do extrato de 2025-09) teriam a **mesma** `chave_natural` e o `unique (condominio_id, chave_natural)` faria a segunda ser **descartada silenciosamente** — o que está exatamente proibido pela regra P7 (duplicata não se descarta, se sinaliza).

Com ele:
- a 1ª ocorrência da tupla tem `numero_ocorrencia = 1` e uma chave;
- a 2ª ocorrência **idêntica** tem `numero_ocorrencia = 2` e **outra** chave → as duas linhas são **inseridas**;
- e o par é sinalizado como **candidata a duplicata** (`mesma_tupla_dentro_do_arquivo`), porque compartilham a mesma `tupla`.

**Por que a idempotência continua valendo** na reimportação:

O número da ocorrência é calculado **dentro do arquivo**, de forma determinística (varredura na ordem das linhas). Ao reimportar o **mesmo** arquivo, a Nª ocorrência da mesma tupla cai na **mesma** linha e recebe o **mesmo** `numero_ocorrencia` → mesma `chave_natural` → `ON CONFLICT` atualiza em vez de inserir.

O `unique (condominio_id, fonte_id, linha_origem, numero_ocorrencia)` é a trava secundária: mesmo que a reexportação mude a formatação do histórico (e portanto a tupla), a posição no arquivo continua identificando a linha.

**Três casos reais, lado a lado:**

| Caso | Tupla | Ocorrência | Resultado |
|---|---|---|---|
| Duas linhas idênticas no mesmo arquivo (unidade 42, 09/2025) | idêntica | 1 e 2 | **As duas entram**, marcadas como candidatas |
| Reimportação do mesmo arquivo | idêntica | 1 e 2 (idem) | Nada muda (`ON CONFLICT` atualiza) |
| Dois pagamentos iguais no mesmo dia, com documentos diferentes | **diferente** | 1 e 1 | Entram como fatos distintos — **não** viram duplicatas |

`historico_normalizado`: histórico em minúsculas, sem espaços duplicados, sem acentos — para que reexportação com formatação diferente reconheça a mesma linha.

---

## 9. Transferências internas (requisito 2)

### 9.1 `grupos_transferencia`
```
id               uuid pk
condominio_id    uuid not null references condominios(id) on delete cascade
competencia_id   uuid not null references competencias(id)
grupo_ref        text not null            -- identificador do grupo, ex.: 'TRF-2026-02-0007'
criado_em        timestamptz not null default now()
unique (condominio_id, grupo_ref)
```

### 9.2 `transferencias_internas`
```
id                    uuid pk
condominio_id         uuid not null references condominios(id) on delete cascade
competencia_id        uuid not null references competencias(id)
grupo_id              uuid not null references grupos_transferencia(id)
fundo_origem_id       uuid not null references fundos(id)
fundo_destino_id      uuid not null references fundos(id)
valor                 numeric(14,2) not null check (valor > 0)
lancamento_origem_id  uuid not null references lancamentos(id)
lancamento_destino_id uuid not null references lancamentos(id)
status                status_transferencia not null -- 'sugerida'|'confirmada'|'rejeitada'
regra                 text not null   -- 'prefixo' | 'codigo' | 'valor_data' | 'manual'
confianca             numeric(4,3) null
justificativa         text null
decidido_por          uuid null references perfis(id)
decidido_em           timestamptz null
criado_em             timestamptz not null default now()
unique (lancamento_origem_id)
unique (lancamento_destino_id)
```
- **As duas pontas ficam ligadas** por `grupo_id`: o débito e o crédito da mesma transferência apontam para o mesmo grupo. A lista de transferências internas é uma entidade, não uma inferência.
- `status = 'sugerida'` é o estado inicial vindo do importador. **Só `confirmada` conta como decisão.**

### 9.3 A fonte única de verdade do estado

O estado de uma transferência interna mora **exclusivamente** em `transferencias_internas.status`. Não existe coluna de estado no lançamento nem em `grupos_transferencia`.

| Onde | O que guarda | Estado da transferência? |
|---|---|---|
| `lancamentos.grupo_transferencia_id` | **apenas a ligação** com o grupo | ❌ não |
| `grupos_transferencia` | o agrupamento (competência + `grupo_ref`) | ❌ não |
| **`transferencias_internas.status`** | **sugerida / confirmada / rejeitada** | ✅ **única fonte** |

**Por que isso importa:** com duas colunas de estado (uma no lançamento e outra na transferência), inevitably surge a situação "o lançamento diz que é interno, mas a transferência diz que não foi confirmada" — e ninguém sabe qual vale. Com uma fonte única, a pergunta "essa transferência está confirmada?" tem **uma** resposta, e todas as consultas usam a mesma expressão:

```sql
-- em qualquer lugar do sistema, a mesma condição:
exists (
    select 1
    from public.transferencias_internas ti
    where ti.grupo_id = l.grupo_transferencia_id
      and ti.status = 'confirmada'
)
```

Um lançamento **sem** `grupo_transferencia_id` **não é** transferência interna — ponto, sem estado a consultar.

### 9.4 Como o estado "interno" NÃO esconde dinheiro (P6)

Este é o ponto central do requisito 2, e a regra é simétrica e explícita:

| Visão | O que soma | Quando usar |
|---|---|---|
| `v_resultado_bruto` | **todos** os lançamentos, sem exceção, incluindo transferências internas | é o "dinheiro que passou pelo banco". Nunca usado para resultado do período. |
| `v_resultado_liquido` | soma tudo **menos** as transferências com `status = 'confirmada'` | Demonstra o resultado do condomínio. |
| `v_resultado_liquido_por_fundo` | idem, agrupado por fundo | mostra o saldo real de cada fundo. |

**Consequência prática:** se a marcação "interno" estiver errada (ou ainda em `sugerida`), o `v_resultado_bruto` continua mostrando todo o dinheiro e o `v_resultado_liquido` só muda depois de uma confirmação humana. Um erro de classificação **nunca** pode esconder dinheiro real do consolidado — porque o consolidado por padrão **não subtrai** nada.

Além disso, o painel mostra as duas visões lado a lado, com a diferença explicitada: "transferências internas confirmadas: R$ 85.000,00 (1 transferência) — ainda em análise: R$ 12.500,00 (3)".

### 9.5 Regras de detecção sugerida (vêm como `sugerida`, nunca aplicadas)
1. **Prefixo**: entrada e saída com prefixos de fundo diferentes e mesmo valor na mesma competência → candidata.
2. **Palavra-chave no histórico**: `TRANSFERENCIA`, `TRANSF.`, `APLICACAO`, `REPOSICAO`, `REMESSA DE NUMERARIO`, `TRANSFERENCIA DA CONTA APLICACAO`.
3. **Conta 1041 / 1820 / 1821** (`TRANSFERENCIA ENTRE CONTAS`) → sempre candidata, nunca automática.
4. **Valor + data** como reforço, nunca como critério único (por causa da regra dos pagamentos iguais).

Detalhe real do caso Fornecedor Exemplo que motivou a regra: em 2026-05 há `ISS NF-218 FORNECEDOR EXEMPLO` crédito em 3003 e `ISS NF-218 FORNECEDOR EXEMPLO` débito em 15501 — mesma NF, mesmo valor (170,00), meses diferentes. É reclassificação, não transferência entre fundos, e a regra por valor/data sozinha erraria. Por isso a regra de prefixo + palavra-chave vem **antes** da de valor/data, e o resultado sempre é `sugerida`.

---

## 10. Duplicatas — candidatas, não descartes (requisito 4)

### 10.1 `duplicatas_candidatas`
```
id                  uuid pk
condominio_id       uuid not null references condominios(id) on delete cascade
chave_candidata     text not null      -- hash do padrão que casou
tupla_comum         text not null      -- a tupla semântica comum às duas linhas (§8.4)
criterio            criterio_duplicata not null
   -- 'mesma_tupla_no_arquivo' | 'mesmo_valor_data_conta' | 'mesmo_documento' | 'mesmo_historico_normalizado'
lancamento_a_id     uuid not null references lancamentos(id) on delete cascade
lancamento_b_id     uuid not null references lancamentos(id) on delete cascade
status              status_duplicata not null default 'pendente'
   -- 'pendente' | 'duplicata_confirmada' | 'nao_duplicata'
pareceres           text null
decidido_por        uuid null references perfis(id)
decidido_em         timestamptz null
criado_em           timestamptz not null default now()
unique (lancamento_a_id, lancamento_b_id)
check (lancamento_a_id <> lancamento_b_id)
```
Enum `status_duplicata`: `pendente`, `duplicata_confirmada`, `nao_duplicata`.

### 10.2 Comportamento
- As **duas linhas continuam existindo** em `lancamentos`. Nada é apagado.
- A decisão `duplicata_confirmada` **não apaga**: marca o par e a pendência é resolvida. Opcionalmente, o auditor pode marcar uma das linhas como `status = 'cancelado'` com rastro em `auditoria_log` — cancelamento é decisão, não efeito colateral.
- A view `v_lancamentos_com_duplicata` mostra a linha repetida marcada, com o número da linha original no arquivo de origem e o número da ocorrência.
- Casos reais que o modelo já comporta:
  - `RC.UN.000183` / `RB.49142365` / 185,00 — mesma linha repetida nas linhas 527 e 528 do extrato de 2025-09 → **ocorrências 1 e 2 da mesma tupla** → critério `mesma_tupla_no_arquivo`.
  - `REPOSICAO DE CAIXA LOCAL` / 1.250,00 — linhas 387 e 388 do extrato de 2026-04 → `mesma_tupla_no_arquivo`.
  - `COR.MON.DECOB 000032` / 0,09 — linhas 165-166 (2026-09) e 234-235 (2026-10) → `mesma_tupla_no_arquivo` + `mesmo_valor_data_conta`.
  - `ISS NF-218 FORNECEDOR EXEMPLO` / 170,00 em 2026-04 (débito), 2026-05 (crédito) e 2026-05 (débito) → **`mesmo_valor_data_conta` entre meses diferentes, mas NÃO duplicata** → vai para `nao_duplicata` com parecer "reclassificação interna da mesma NF".

---

## 11. Conciliação extrato × balancete — por fundo e por competência (requisito 7)

### 11.1 `conciliacoes`
```
id                        uuid pk
condominio_id             uuid not null references condominios(id) on delete cascade
competencia_id            uuid not null references competencias(id)
fundo_id                  uuid not null references fundos(id)
status                    status_conciliacao not null
   -- 'sem_fonte' | 'conciliado' | 'divergente' | 'nao_aplicavel'
saldo_inicial_extrato     numeric(14,2) null
creditos_extrato          numeric(14,2) null
debitos_extrato           numeric(14,2) null
saldo_final_extrato       numeric(14,2) null
saldo_inicial_balancete   numeric(14,2) null
creditos_balancete        numeric(14,2) null
debitos_balancete         numeric(14,2) null
saldo_final_balancete     numeric(14,2) null
diferenca_creditos        numeric(14,2) null
diferenca_debitos         numeric(14,2) null
diferenca_saldo_final     numeric(14,2) null
observacao                text null
conciliado_em             timestamptz null
conciliado_por            uuid null references perfis(id)
unique (competencia_id, fundo_id)
```

### 11.2 A correção da lógica que gerou os falsos "divergente"

O erro do app antigo: comparar a linha `CONTA CONDOMINIO` do balancete contra o **total de todos os créditos do extrato**. A nova regra, por fundo:

```
-- Para cada fundo F da competência C:
creditos_extrato(F)   = soma dos créditos do extrato cujo fundo = F
debitos_extrato(F)    = soma dos débitos do extrato cujo fundo = F
saldo_inicial_extrato(F) = saldo inicial do fundo, carregado do mês anterior
saldo_final_extrato(F)   = saldo_inicial + creditos - debitos

creditos_balancete(F)  = créditos da linha do fundo F no RESUMO FINANCEIRO do balancete
...
diferenca_creditos = creditos_balancete(F) - creditos_extrato(F)
```

Com a comparação **por fundo**, as transferências internas se cancelam dentro do próprio fundo e o resultado fecha. Verificação com os dados reais (as 18 competências):

| Competência | Total extrato × total balancete | Por fundo (CC, BENF, FR, PINT, SAL) |
|---|---|---|
| 2025-05 … 2026-10 | **R$ 0,00 em créditos e débitos, nas 18** | idêntico (é a decomposição do mesmo total) |

Exemplo do que muda, 2025-07:
- Antes: `CONTA CONDOMINIO` (93.680,00) × total do extrato (106.500,00) = **−12.820,00 "divergente"**.
- Agora: `CONTA CONDOMINIO` (93.680,00) × extrato do fundo CONTA (93.680,00) = **0,00**; BENFEITORIAS 9.180,00 × 9.180,00 = 0,00; FUNDO 2.910,00 × 2.910,00 = 0,00; SALÃO 730,00 × 730,00 = 0,00.

As transferências entre fundos (ex.: 85.000,00 de CONTA para PINTURA em 2026-10) aparecem como movimento nos dois fundos e **não** como divergência.

### 11.3 `conciliacao_detalhe`
```
id              uuid pk
conciliacao_id  uuid not null references conciliacoes(id) on delete cascade
rubrica_id      uuid null references rubricas(id)
alias_origem    text not null          -- rótulo como veio da fonte
fundo_id        uuid null references fundos(id)
lado            text not null          -- 'extrato' | 'balancete'
valor           numeric(14,2) not null
observacao      text null
```
Guarda a linha a linha da comparação — é o que permite dizer "a divergência de 2026-10 são 2 transferências de R$ 85.000,00 e R$ 99.060,00", e não só um número.

---

## 12. Documentos, anexos e comprovantes

### 12.1 `documentos`
```
id               uuid pk
condominio_id    uuid not null references condominios(id) on delete cascade
tipo             tipo_documento not null
   -- 'nota_fiscal'|'boleto'|'comprovante'|'contrato'|'ata'|'anexo'|'outro'
titulo           text not null
numero           text null             -- NF, número do contrato
fornecedor       text null
cnpj             text null
data_documento   date null
valor            numeric(14,2) null
competencia_id   uuid null references competencias(id)
lancamento_id    uuid null references lancamentos(id)
fonte_id         uuid null references fontes_importacao(id)
hash_sha256      text null
caminho          text null             -- caminho no storage privado
criado_em        timestamptz not null default now()
```
### 12.2 `anexos` (comprovantes escaneados do caixa local)
```
id              uuid pk
condominio_id   uuid not null references condominios(id) on delete cascade
documento_id    uuid null references documentos(id)
lancamento_id   uuid null references lancamentos(id)
fonte_id        uuid not null references fontes_importacao(id)
pagina          int not null
rotulo          text null             -- 'comprovante NADO AZUL parcela 3/13'
hash_sha256     text not null
caminho         text not null         -- objeto no bucket privado
status          status_anexo not null default 'sugerido'
   -- 'sugerido' | 'vinculado' | 'rejeitado'

-- ===== LIBERAÇÃO PARA O LEITOR (padrão: bloqueado) =====
liberado_para_leitor boolean not null default false
liberado_em           timestamptz null
liberado_por           uuid null references perfis(id)

criado_em       timestamptz not null default now()
```
O caso real do caixa local: a página 1 do PDF traz a conta (Data, Histórico, Débito, Crédito, Saldo Anterior, saldo final); as páginas 2+ são **comprovantes escaneados** (imagens). O importador extrai cada página como anexo e sugere a vinculação por **valor** (tolerância de R$ 0,50, como no app antigo) — sempre como `sugerido`, com a decisão humana registrada.

As 68 linhas conciliadas do app antigo estão com fornecedor/CNPJ/NF **vazios** — porque a extração por regex sobre imagem é frágil. O modelo guarda o anexo, o auditor liga na mão, e a pendência fica visível.

**Regra de acesso aos anexos (requisito seu nº 7):** o anexo é **bloqueado por padrão** para o leitor. O auditor libera **anexo por anexo** (`liberado_para_leitor`), e a liberação fica registrada em `auditoria_log`. A policy de storage e a função `fn_anexo_acessivel` estão em `SEGURANCA_RLS.md` §10.

**Por que liberar um a um e não em lote:** mesmo sem dado de morador no comprovante, o documento de uma despesa de R$ 2.950,00 da piscina, combinado com o extrato, permite reconstruir a operação de uma unidade específica. A liberação granular dá controle sem custar nada ao auditor.

---

## 12A. Contestações e comentários (síndico e conselho fiscal)

O síndico **não altera classificação**, mas **pode comentar e contestar**, e isso fica registrado.

```
contestacoes
id              uuid pk
condominio_id   uuid not null references condominios(id) on delete cascade
lancamento_id   uuid null references lancamentos(id) on delete cascade
pendencia_id    uuid null references pendencias(id) on delete cascade
documento_id    uuid null references documentos(id) on delete cascade
autor_id        uuid not null references perfis(id)
tipo            text not null default 'comentario'
   -- 'comentario' | 'contestacao'
texto           text not null
status          text not null default 'aberta'
   -- 'aberta' | 'em_analise' | 'acolhida' | 'rejeitada'
respondida_por  uuid null references perfis(id)
resposta        text null
criado_em       timestamptz not null default now()
respondida_em   timestamptz null
```
Regras:
- **Criar**: `sindico`, `conselho_fiscal` e `auditor`, **apenas** no condomínio onde têm papel. O leitor não.
- **Responder**: só `auditor` (acolhe ou rejeita).
- A contestação **não altera** a classificação nem o status do lançamento — é registro lateral. O front destaca lançamentos contestados para o auditor.
- Criação e resposta entram no `acesso_log` (trigger) e no `auditoria_log`.

---

## 12B. `acesso_log` — todas as escritas e as leituras do leitor

```
acesso_log
id             bigserial pk
condominio_id  uuid null references condominios(id) on delete cascade
usuario_id     uuid null references perfis(id) on delete set null
operacao       text not null check (operacao in ('select','insert','update','delete','rpc','storage','anexo'))
recurso        text not null       -- tabela, view ou função
entidade_id    text null
detalhes       jsonb null
criado_em      timestamptz not null default now()
```
| Evento | Registrado? | Como |
|---|---|---|
| Qualquer escrita em tabela de negócio | ✅ sempre | trigger genérico AFTER em cada tabela |
| Leitura agregada (leitor e todos) | ✅ sempre | a própria `fn_resumo` grava antes de devolver |
| Leitura de detalhe pelo auditor | ⚠️ depende do ambiente | `pgaudit` ou log de statement do Postgres |
| Anexo baixado | ✅ | `fn_gerar_url_anexo` grava antes de devolver a URL assinada |
| Contestação criada/respondida | ✅ | trigger + `auditoria_log` |

⚠️ **Limitação real:** não existe trigger de `SELECT` no Postgres. A leitura **do leitor** é registrada porque o único caminho dele para os dados é a função, que grava. A leitura **nominal do auditor** depende de `pgaudit` (disponibilidade depende do plano) — está registrado como pendência em aberto em `SEGURANCA_RLS.md` §13.4.

---

## 13. Pendências e achados — tabela de primeira classe (resposta do usuário)

```
pendencias
id               uuid pk
condominio_id    uuid not null references condominios(id) on delete cascade
tipo             tipo_pendencia not null
   -- 'classificacao' | 'duplicata' | 'divergencia' | 'conferencia_importacao'
   -- | 'documento_faltante' | 'lancamento_orfao' | 'competencia_sem_fonte'
   -- | 'arquivo_ilegivel' | 'senha_necessaria' | 'validacao_manual'
   -- | 'classificacao_sugerida'
origem           fonte_pendencia not null
   -- 'extrato'|'balancete'|'caixa_local'|'planilha_resumo'|'importacao'|'manual'|'sistema'
gravidade        gravidade_pendencia not null  -- 'baixa'|'media'|'alta'|'critica'
titulo           text not null
descricao        text not null

-- Ligações (todas opcionais, todas indexadas)
lancamento_id    uuid null references lancamentos(id) on delete cascade
conciliacao_id   uuid null references conciliacoes(id) on delete cascade
documento_id     uuid null references documentos(id) on delete cascade
fonte_id         uuid null references fontes_importacao(id)
competencia_id   uuid null references competencias(id)
fundo_id         uuid null references fundos(id)
unidade_id       uuid null references unidades(id)
importacao_id    uuid null references importacoes(id)
staging_id       uuid null                              -- se a pendência está numa linha de staging
duplicata_id     uuid null references duplicatas_candidatas(id)

status           status_pendencia not null default 'aberta'
   -- 'aberta'|'em_analise'|'resolvida'|'ignorada'
resolucao        text null
criada_em        timestamptz not null default now()
criada_por       uuid null references perfis(id)
resolvida_em     timestamptz null
resolvida_por    uuid null references perfis(id)
```
```
pendencia_anotacoes
id            uuid pk
pendencia_id  uuid not null references pendencias(id) on delete cascade
autor_id      uuid not null references perfis(id)
texto         text not null
criado_em     timestamptz not null default now()
```

### 13.1 Povoamento inicial com o que já sabemos (29 itens, todos rastreáveis)

| Tipo | Quantidade | Origem |
|---|---|---|
| `classificacao` | 55 | Um por código de conta sem rubrica (`contas_origem` com `rubrica_id` nulo) |
| `classificacao_sugerida` | 55 | Um por código com rubrica sugerida por palavra-chave, aguardando confirmação |
| `duplicata` | 4 | Pares de linhas duplicadas no arquivo de origem (2 já sinalizados no app antigo, 2 não) |
| `divergencia` | 19 | Competências com `DIVERGENTE` no relatório antigo — **todas reavaliadas na conciliação por fundo**; sobrevivem só as que restarem depois do recálculo |
| `competencia_sem_fonte` | 13 | 2025-02 a 2025-04 (sem balancete e sem caixa local) + lacunas de 2024-07 a 2025-04 (sem extrato) |
| `validacao_manual` | 5 | As 5 linhas de `manual_validations.csv` (competência 2026-03, unidade 14) — hoje com `status = pendente` e sem responsável |
| `classificacao` | 35 | As linhas de `despesas_a_esclarecer.xlsx` com "Classificacao Sugerida" preenchida |
| `lancamento_orfao` | 7 | Despesas de caixa local sem correspondência no extrato |
| `arquivo_ilegivel` | 1 | `documento_criptografado.pdf` — criptografado (AES). **Registro como pendência de obter cópia sem senha** |
| `documento_faltante` | 2 | NFs de fornecedor existentes (`NFs\`) sem NF-e de referência do ano anterior |

### 13.2 Painel
O painel do auditor mostra: pendências por tipo/gravidade, por competência, por fundo e por unidade; e uma visão "competência sem fonte" que responde à pergunta "o que falta para fechar este mês?".

---

## 14. Série histórica da planilha-resumo (requisito 8)

A planilha-resumo cobre 05/2020 a 10/2026 (78 meses, sem lacuna) e é a **única** série longa. Como não há lançamentos nesse período, ela entra em tabela própria, sem virar lançamento:

```
serie_historica_resumo
id                uuid pk
condominio_id     uuid not null references condominios(id) on delete cascade
ano               smallint not null
mes               smallint not null
bloco             text not null         -- 'conta' | 'aplicacao_btg'
rubrica_alias     text not null         -- 'CONTA CONDOMINIO', 'FUNDO DE RESERVA', 'APLICAÇÃO BANCO EXEMPLO'...
rubrica_id        uuid null references rubricas(id)
fundo_id          uuid null references fundos(id)
saldo_anterior    numeric(14,2) null
creditos          numeric(14,2) null
debitos           numeric(14,2) null
saldo             numeric(14,2) null
fonte_id          uuid not null references fontes_importacao(id)
linha_origem      int not null
criado_em         timestamptz not null default now()
unique (condominio_id, ano, mes, bloco, rubrica_alias)
```
- 78 blocos × 4 a 7 rubricas ≈ **420 linhas**.
- As **21 linhas de anotação** das colunas H/I/J (caderno à mão: "TOTAL FUNDO RESERVA", "desc. IRRF", "gasto 4800.00") **não** viram rubrica: entram em `serie_historica_anotacoes` (ou em `pendencias` do tipo `classificacao_sugerida`), preservando o texto original e a linha.
- A série serve para **tendência de longo prazo** (saldo consolidado, composição de despesas, evolução da cota) e para *seed* do saldo inicial de competências antigas, se um dia vierem a ser importadas.
- `unique` garante idempotência: reimportar a planilha atualiza, não duplica.

---

## 15. Staging — a área de conferência

### 15.1 `staging_lancamentos`
```
id                 uuid pk
importacao_id      uuid not null references importacoes(id) on delete cascade
fonte_id           uuid not null references fontes_importacao(id)
condominio_id      uuid not null references condominios(id)
competencia_ano    smallint not null
competencia_mes    smallint not null
linha_origem       int not null
aba                text null
pagina             int null
texto_origem       text not null
-- campos já parseados
data_lancamento    date null
data_vencimento    date null
codigo_conta       text null
descricao_conta    text null
historico          text null
documento          text null
valor              numeric(14,2) null
tipo_movimento     tipo_movimento null
unidade_numero     text null
fundo_sugerido_id  uuid null references fundos(id)
rubrica_sugerida_id uuid null references rubricas(id)
confianca          numeric(4,3) null
chave_natural      text not null
-- avaliação
status             status_staging not null default 'novo'
   -- 'novo'|'duplicado_candidato'|'conflito'|'erro_parse'|'rejeitado'|'aprovado'
mensagem           text null
aprovado_em        timestamptz null
aprovado_por       uuid null references perfis(id)
criado_em          timestamptz not null default now()
unique (importacao_id, chave_natural)
```

### 15.2 `staging_transacoes` e `staging_duplicatas`
Mesma ideia, guardando as **sugestões** antes de virarem definitivamente:
```
staging_transacoes
id, importacao_id, fonte_id, competencia_ano, competencia_mes,
grupo_ref_sugerido, fundo_origem_id, fundo_destino_id, valor,
linha_origem_origem, linha_origem_destino, regra, confianca, status

staging_duplicatas
id, importacao_id, chave_candidata, criterio,
staging_a_id, staging_b_id, status
```

### 15.3 O que a conferência mostra
Por linha: o texto original (coluna A da planilha, ou a linha do PDF), o que o parser entendeu, a rubrica e o fundo sugeridos, a unidade detectada, se há candidata a duplicata, e se a linha fecha com o total do arquivo. E o resumo do arquivo: N linhas, N novas, N duplicatas candidatas, N sem rubrica, N com valor que não fecha, e o total de créditos/débitos lido **contra** o total do bloco RESUMO do próprio extrato.

---

## 16. Auditoria e log de decisões

```
auditoria_log
id            uuid pk
condominio_id uuid not null references condominios(id) on delete cascade
entidade      text not null      -- 'lancamento'|'rubrica'|'duplicata'|'transferencia'|'staging'|'conta_origem'|'competencia'
entidade_id   uuid null
acao          text not null      -- 'aprovar'|'rejeitar'|'classificar'|'decidir_duplicata'|'confirmar_transferencia'|'fechar_competencia'|'importar'
antes         jsonb null
depois        jsonb null
usuario_id    uuid not null references perfis(id)
criado_em     timestamptz not null default now()
```
Toda vez que o auditor aprova uma linha de staging, reclassifica um lançamento, decide uma duplicata ou confirma uma transferência, nasce um registro. Isso responde à pergunta que uma auditoria sempre faz: *"quem mudou isso, quando, e por quê?"*

---

## 17. Visões (catálogo)

| Visão | Grão | Quem pode ver |
|---|---|---|
| `v_lancamentos` | linha | auditor, sindico (próprio), conselho fiscal (próprio) |
| `v_lancamentos_anon` | linha, **sem** `unidade_id`/`unidade_numero` | nenhum hoje; base para o leitor se um dia liberado |
| `v_resumo_competencia_fundo` | competência × fundo | **leitor** e todos |
| `v_resumo_competencia_rubrica` | competência × rubrica | **leitor** e todos |
| `v_resultado_bruto` | competência (soma tudo) | todos |
| `v_resultado_liquido` | competência (desconta transferências **confirmadas**) | todos |
| `v_resultado_liquido_por_fundo` | competência × fundo | todos |
| `v_conciliacao` | competência × fundo | todos (com o status) |
| `v_pendencias_resumo` | contagem por tipo/gravidade | **leitor** (só contagem) e todos |
| `v_pendencias` | pendência | auditor, conselho fiscal — via `fn_pendencias`, não por `GRANT` direto |
| `v_cobertura_competencias` | competência × fonte × status | todos (é a visão "o que falta") |
| `v_duplicatas_candidatas` | par de lançamentos | auditor |
| `v_transferencias_internas` | transferência | auditor, conselho fiscal |
| `v_contestacoes` | contestação | auditor, sindico (próprio), conselho fiscal (próprio) |
| `v_serie_historica` | ano-mês × rubrica | todos |
| `v_lancamentos_com_duplicata` | linha, marcando o par | auditor |

Detalhe importante: `v_resumo_competencia_fundo` e `v_resultado_bruto` somam **todos** os lançamentos — inclusive os de unidade — porque são agregados. É exatamente o que o leitor pode ver. Nenhuma delas expõe linha individual.

**Nota sobre o acesso às visões:** por decisão de segurança (SEGURANCA_RLS §3.2), `authenticated` **não** tem `GRANT` de tabela; o leitor chega às agregadas por `GRANT SELECT` na view **e** por `EXECUTE` em `fn_resumo` (que aplica o limiar mínimo de agregação). As visões de detalhe (`v_lancamentos`, `v_pendencias`) existem, mas o caminho previsto para elas é a função privilegiada, que verifica o papel **por condomínio** e devolve erro claro em vez de zero linhas silencioso.

---

## 18. Funções (catálogo)

| Função | Tipo | O que faz |
|---|---|---|
| `fn_aprovar_staging(p_importacao_id uuid, p_staging_ids uuid[], p_decisoes jsonb)` | SECURITY DEFINER | Aprova linhas de staging → grava `lancamentos` + `lancamento_rubrica` + `grupos_transferencia`/`transferencias_internas` + `duplicatas_candidatas` + `pendencias`, tudo em **uma transação**. Atômico. |
| `fn_rejeitar_staging(p_importacao_id uuid, p_staging_ids uuid[], p_motivo text)` | SECURITY DEFINER | Rejeita com motivo; gera pendência do tipo `conferencia_importacao`. |
| `fn_classificar_lancamento(p_lancamento_id, p_rubrica_id, p_fundo_id, p_status)` | SECURITY DEFINER | Classifica (sugerida → confirmada), grava `auditoria_log`. **Só auditor.** |
| `fn_decidir_duplicata(p_duplicata_id, p_status, p_parecer)` | SECURITY DEFINER | Decide o par; `duplicata_confirmada` opcionalmente cancela uma das linhas, com rastro. |
| `fn_confirmar_transferencia(p_transferencia_id, p_status, p_justificativa)` | SECURITY DEFINER | Confirma/rejeita a transferência interna — **única forma de mudar `transferencias_internas.status`**. |
| `fn_reconciliar_competencia(p_competencia_id uuid)` | SECURITY DEFINER | Calcula a conciliação **por fundo** e grava `conciliacoes` + `conciliacao_detalhe`; atualiza `status_competencia`. |
| `fn_resumo(p_condominio_id uuid, p_competencia_id uuid, p_granularidade text)` | SECURITY DEFINER | Agregação controlada. A granularidade permitida vem de `config_visibilidade` (por condomínio e papel); aplica limiar mínimo de agregação (padrão 5) nas agregações apoiadas em dado ligado a unidade. Grava a leitura em `acesso_log`. |
| `fn_lancamentos(p_condominio_id uuid, p_competencia_id uuid, ...)` | SECURITY DEFINER | Acesso ao **detalhe**, com verificação de papel **por condomínio**. Recusa com `42501` quem não tiver papel. |
| `fn_contestar_lancamento(p_lancamento_id uuid, p_texto text, p_tipo text)` | SECURITY DEFINER | Cria contestação/comentário. **Síndico e conselho fiscal podem; não alteram classificação.** |
| `fn_responder_contestacao(p_contestacao_id uuid, p_resposta text, p_status text)` | SECURITY DEFINER | Auditor acolhe ou rejeita a contestação. |
| `fn_liberar_anexo_para_leitor(p_anexo_id uuid, p_liberar boolean)` | SECURITY DEFINER | Libera (ou revoga) o acesso de um anexo ao leitor. Só auditor. |
| `fn_gerar_url_anexo(p_anexo_id uuid)` | SECURITY DEFINER | URL assinada de expiração curta; grava em `acesso_log`. |
| `fn_registrar_pendencia(...)` | SECURITY DEFINER | Cria pendência a partir de regra automática. |
| `fn_status_competencias(p_condominio_id uuid, p_ano int, p_mes int)` | SECURITY DEFINER | Situação por competência e por fonte — a visão "o que falta". |
| `fn_papeis_do_usuario(p_condominio_id uuid)` | SECURITY DEFINER | Helper: papéis do usuário **no condomínio indicado**. |
| `fn_e_membro(p_condominio_id uuid, p_papel papel_membro)` | SECURITY DEFINER | Helper booleano, usado dentro das policies. |
| `fn_condominios_do_usuario()` | SECURITY DEFINER | Helper: condomínios do usuário autenticado. |

---

## 19. Índices

```sql
create index ix_lancamentos_comp_fundo     on lancamentos (condominio_id, competencia_id, fundo_id);
create index ix_lancamentos_unidade        on lancamentos (unidade_id, competencia_id);
create index ix_lancamentos_data           on lancamentos (condominio_id, data_lancamento);
create index ix_lancamentos_classif        on lancamentos (status_classificacao) where status_classificacao = 'sugerida';
create index ix_lancamentos_grupo_trf      on lancamentos (grupo_transferencia_id) where grupo_transferencia_id is not null;
create index ix_lancamentos_origem         on lancamentos (fonte_id, linha_origem, numero_ocorrencia);
create index ix_pendencias_abertas         on pendencias (condominio_id, gravidade) where status in ('aberta','em_analise');
create index ix_pendencias_alvo            on pendencias (lancamento_id) where lancamento_id is not null;
create index ix_duplicatas_pendentes       on duplicatas_candidatas (condominio_id) where status = 'pendente';
create index ix_staging_importacao         on staging_lancamentos (importacao_id, status);
create index ix_contestacoes_abertas       on contestacoes (condominio_id, criado_em desc) where status = 'aberta';
create index ix_acesso_log_usuario          on acesso_log (usuario_id, criado_em desc);
create index ix_acesso_log_condominio       on acesso_log (condominio_id, criado_em desc);
create index ix_config_visibilidade_cond    on config_visibilidade (condominio_id, papel);
```

---

## 20. Mapeamento da base antiga → modelo novo

| Origem | Destino | Observação |
|---|---|---|
| `data\renamed\extrato_*.xls` (18) | `fontes_importacao` (tipo `extrato`, layout `extrato_v3` ou `extrato_v2`) → `staging_lancamentos` → `lancamentos` | 2 layouts no conjunto (v2 = 5 col "código - descrição", v3 = 6 col) |
| `data\renamed\balancete_*.pdf` (18) | `fontes_importacao` (layout `balancete_v1`) → `conciliacoes` | Extrai as 8 seções; alimenta a conciliação por fundo |
| `data\renamed\despesas_locais_*.pdf` (18) | `fontes_importacao` (layout `caixa_local_v1`) → `staging_lancamentos` + `anexos` | Página 1 = conta; páginas 2+ = comprovantes |
| `planilha-resumo.xlsx` (78 blocos) | `fontes_importacao` (layout `planilha_resumo_v1`) → `serie_historica_resumo` | Série histórica agregada, sem lançamentos |
| `config\mapa_contas.yaml` | `rubricas` + `rubrica_aliases` + `contas_origem` | 41 códigos → 24 rubricas + aliases |
| `config\unidades.yaml` | `unidades` (72) | Com `andar`/`posicao` derivados |
| `data\manual_validations.csv` (5) | `pendencias` (tipo `validacao_manual`) | Ficam pendentes até decididas — **não** são aplicadas em lote |
| `despesas_a_esclarecer.xlsx` (35) | `pendencias` (tipo `classificacao`) | Com a classificação sugerida em `rubrica_aliases` |
| `caixa_local_sem_match.csv` (7) | `pendencias` (tipo `lancamento_orfao`) | Não entra em `lancamentos`; fica na fila de decisão |
| `itens_duplicados_unidade.csv` (1) + os 2 não sinalizados | `duplicatas_candidatas` (4 pares) | As duas linhas permanecem em `lancamentos` |
| `balancete_status_conciliacao.csv` (14 DIVERGENTE) | `pendencias` (tipo `divergencia`) → recalculadas por fundo | A maioria deve sumir no recálculo |
| `documento_criptografado.pdf` | `pendencias` (tipo `senha_necessaria`) | Fora do escopo até obter cópia sem senha |
| `output\*.csv` (artefatos do app antigo) | **não importados** | São derivados; o modelo novo recalcula tudo |
| `Extratos_gestao_01\` (2023-2024), `extrato_2025-01.xlsx` | **não importados** (decisão D7) | Registrados como `competencia_sem_fonte` |

---

## 21. Decisões de modelagem e alternativas descartadas

| Decisão | Alternativa descartada | Por quê |
|---|---|---|
| Fundo como entidade com prefixo | Texto de fundo dentro do lançamento | O prefixo do código já identifica o fundo; sem entidade não dá para conciliar por fundo nem agregar sem `CASE` espalhado |
| **Estado da transferência só em `transferencias_internas.status`** | Coluna de estado também no lançamento | Duas colunas de estado inevitavelmente divergem ("o lançamento diz interno, a transferência diz não confirmada"). Com uma fonte única, a pergunta tem uma resposta só |
| `chave_natural` = tupla semântica + **número da ocorrência** | Chave só pela tupla | Sem a ocorrência, a 2ª linha idêntica do arquivo seria descartada em silêncio pelo `unique` — proibido pela regra de não descartar duplicata |
| `chave_natural` inclui documento, tipo e valor | Chave por data+valor | Dois pagamentos iguais no mesmo dia são legítimos (a regra do usuário). Chave por data+valor fundiria dinheiro real |
| Duplicatas ficam **dentro** de `lancamentos` | Tabela separada de "lançamentos rejeitados" | Uma linha rejeitada ainda é fato contábil; esconder em outra tabela quebra a rastreabilidade |
| `v_resultado_bruto` como padrão | Consolidado único já líquido | Se o consolidado padrão já desconta transferências, um erro de classificação esconde dinheiro. Com as duas visões, o erro aparece como diferença explícita |
| Série da planilha-resumo em tabela própria | Tratar como lançamentos de um "lançamento sintético" por mês | Não há documento nem linha por trás; e a competência de referência é ambígua. Tabela própria permite tendência sem poluir o extrato |
| Classificação por lançamento (`lancamento_rubrica`) | Só rubrica por código de conta | O caso Fornecedor Exemplo mostra que a mesma conta (1647) recebe naturezas diferentes |
| `unidade_id` nullable, sempre presente na tabela | Coluna de texto com a unidade | Precisa de FK para "cobertura das 72 unidades" e para as pendências por unidade |
| Contestação como entidade separada (`contestacoes`) | Anotação dentro da pendência | O síndico contesta **um lançamento**, não uma pendência; e a resposta do auditor precisa de estado próprio (`aberta` → `acolhida`/`rejeitada`) |
| Anexo **bloqueado por padrão** para o leitor | Liberar o bucket inteiro para o leitor | Um comprovante, combinado com o extrato, permite reconstruir a operação de uma unidade. A liberação por anexo dá controle sem custo ao auditor |

---

## 22. O que este documento **não** decide

- Nomes exatos de colunas de `staging_transacoes`/`staging_duplicatas` (detalhados na implementação).
- Onde os anexos ficam fisicamente (bucket privado do Supabase vs. disco local) — detalhado em SEGURANCA_RLS.md.
- Se a importação roda por script Python local (recomendado) ou por Edge Function — detalhado em IMPORTACAO.md.
- Granularidade da política nominal futura — detalhado em SEGURANCA_RLS.md.

---

## 23. O que a implementação revelou (12/11/2026)

A Fase 0 foi implementada: 16 migrations aplicadas do zero (`supabase db reset` sem erro), com **53 testes de segurança verdes**. Este capítulo registra o que mudou em relação ao desenho original.

### 23.1 Ordem das migrations

A ordem importa e foi definida por dependência de criação, não por tema:

| # | Migration | Dependência |
|---|---|---|
| 00100 | `enums` | — |
| 00200 | `condominios_perfis_membros` | cria **os roles** `app_owner` e `app_importador` |
| 00250 | `helpers_revocacao` | helpers de revogação dinâmica |
| 00260 | `helper_usuario` | `fn_usuario_atual()` — usado por todas as migrations seguintes |
| 00300 | `unidades` | — |
| 00400 | `competencias_status` | — |
| 00500 | `fundos_rubricas_aliases` | — |
| 00600 | `fontes_importacao_staging` | — |
| 00700 | `lancamentos` | — |
| 00800 | `transferencias_duplicatas` | FK do lançamento → grupo |
| 00900 | `conciliacao_documentos` | — |
| 01000 | `pendencias_auditoria` | — |
| 01100 | `serie_historica` | — |
| 01200 | `papeis_rls_grants` | **helpers de papel** + revoke global + policies |
| 01300 | `views_agregadas` | — |
| 01400 | `rpcs` | — |
| 01500 | `storage_buckets` | — |

**Por que os roles foram para a 00200:** o `app_owner` precisa existir antes de qualquer `grant` que o mencione. A 00260 (helper de usuário) e a 01200 (papéis) já concedem privilégio a ele.

**Por que a 00260 vem antes da 01200 e da 01400:** `fn_usuario_atual()` é usado no corpo das funções privilegiadas, e precisa existir antes delas.

### 23.2 `auth.uid()` foi substituído por `fn_usuario_atual()`

Motivo e solução em `SEGURANCA_RLS.md` §16.1. Resumo:

- O `search_path` da sessão no Supabase local é `"$user", public, extensions` — **sem `auth`**.
- Um `auth.uid()` dentro de um `INSERT` pode ser resolvido no contexto do statement, e a coluna vira NULL.
- O helper `public.fn_usuario_atual()` lê o claim do JWT direto do GUC de sessão.
- É `VOLATILE` (não `STABLE`), senão o planner avalia no início da query e o claim trocado no meio do teste invalida o snapshot.

### 23.3 O estado da transferência interna: uma fonte só — confirmado

A implementação manteve o desenho: `transferencias_internas.status` é a **única** fonte de verdade. O lançamento tem apenas `grupo_transferencia_id` (FK), sem coluna de estado.

A verificação está no teste T40:

```sql
-- bruto: soma a transferência (R$ 50,00 entra no total)
select creditos from v_resultado_bruto where ...;   -- 1080,00
-- líquido: desconta a ponta de destino
select count(*) from v_resultado_liquido_por_fundo where ...;  -- 1 fundo
```

O BENFEITORIAS **sume** do resultado líquido (a ponta de destino é excluída) e **continua** no bruto. É exatamente a regra de ouro: classificação errada não esconde dinheiro, porque o consolidado padrão não subtrai nada.

### 23.4 A classificação é por lançamento — confirmado

`lancamento_rubrica` é 1:1 com o lançamento. O fixture de teste demonstra os três casos: um mesmo fundo (CONTA CONDOMÍNIO) com rubricas diferentes (cotas, multas, transferência), e o agregado por rubrica separa corretamente.

### 23.5 A chave natural com número da ocorrência — implementado

`chave_natural` = `sha256(tupla_semantica || '#' || numero_ocorrencia)`, com `numero_ocorrencia` contado durante o parse (quantas vezes a mesma tupla já apareceu no arquivo).

A trava secundária `unique (condominio_id, fonte_id, linha_origem, numero_ocorrencia)` cobre o caso da reexportação que muda a formatação do histórico.

### 23.6 Duplicatas: 4 pares reais catalogados

O fixture cria um par de duplicatas com a mesma tupla (mesmo documento, mesma data, mesmo valor) em duas linhas distintas — e **as duas permanecem** em `lancamentos`, com o par marcado como `pendente` em `duplicatas_candidatas`. O teste T34 verifica que a contestação de um lançamento não altera a classificação do outro.

### 23.7 Pendências: 13 tipos, com ligação opcional

A tabela `pendencias` tem 8 colunas de ligação (lançamento, conciliação, documento, fonte, competência, fundo, unidade, duplicata) — todas opcionais, todas indexadas. Uma pendência pode ser "competência sem fonte" (sem nenhum vínculo de linha) ou "lançamento sem rubrica" (com vínculo).

### 23.8 Anexo: bloqueado por padrão, liberação individual

`anexos.liberado_para_leitor` (default `false`) + `fn_liberar_anexo_para_leitor` (só auditor) + `fn_anexo_acessivel` (consultada pela policy de storage). O teste T39 verifica que o leitor alcança **apenas** o anexo liberado, e o T39c que ele não tem `SELECT` direto na tabela `anexos`.

### 23.9 `acesso_log` — escrita por trigger, leitura pela função

- **Toda escrita** em tabela de negócio é registrada pelo trigger genérico `fn_log_escrita`.
- **Toda leitura agregada** é registrada pela própria `fn_resumo` (que insere no log antes de devolver).
- A retenção é configurável por condomínio (`config_retencao_acesso.meses_retencao`, padrão **12 meses**), com a função `fn_purgar_acesso_log`.
- ⚠️ Limitação registrada: o Postgres **não tem trigger de SELECT**, então a leitura *nominal* do auditor não passa pelo log (depende de `pgaudit`).

### 23.10 Contestação: entidade própria, com resposta do auditor

`contestacoes` aponta para o **lançamento** (não para a pendência) e tem estado próprio (`aberta` → `acolhida`/`rejeitada`). O síndico cria; só o auditor responde. O teste T31–T35 verifica: síndico lê o detalhe, não classifica, contesta, e **não** contesta lançamento de outro condomínio.

### 23.11 Série histórica: 78 meses, sem lançamentos

`serie_historica_resumo` recebe ~420 linhas (78 meses × 4–7 rubricas). As 21 anotações manuscritas das colunas H/I/J ficam em `serie_historica_anotacoes`, com o texto e a linha de origem preservados.

### 23.12 Carga inicial (seed) — só configuração, zero dado real

O `seed.sql` é versionado e contém **apenas configuração**:
- 1 condomínio (fictício: "Condominio Residencial Exemplo")
- 7 fundos, 31 rubricas, 55 aliases, 19 contas de origem
- 72 unidades (18 andares × 4)
- 4 políticas de visibilidade (auditor/leitor/síndico/conselho), retenção de 12 meses

**Nenhum lançamento, nenhum valor, nenhum dado de morador.** Os dados reais entram por importação.

### 23.13 O que mudou em relação ao desenho original

| Desenho original | Implementação | Motivo |
|---|---|---|
| `auth.uid()` nas funções privilegiadas | `public.fn_usuario_atual()` | `search_path` da sessão não inclui `auth` (§23.2) |
| `fn_usuario_atual()` `STABLE` | `VOLATILE` | claim pode ser trocado no meio do teste |
| `app_owner` criado na migration de papéis | criado na migration 00200 | os `grant` da 00260 já o mencionam |
| Revogação de default privileges nas migrations | no bootstrap (como `supabase_admin`) | o `postgres` não pode alterar os do `supabase_admin` |
| `unidades` com FK de `unidades` → nada | idem | — |
| Sem helper de usuário | migration 00260 | — |

### 23.14 Estado atual do banco (verificado)

| Objeto | Quantidade |
|---|---|
| Tabelas em `public` | 35 |
| Views agregadas | 14 |
| Funções privilegiadas (`SECURITY DEFINER`) | 16 |
| Funções auxiliares de teste | 12 |
| Policies de RLS | 40 |
| Enums | 26 |
| Roles de aplicação | 2 (`app_owner`, `app_importador`) |

