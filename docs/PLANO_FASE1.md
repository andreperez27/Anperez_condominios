# Plano da Fase 1 — importador, conferência e primeira conciliação

**Data:** 12/11/2026
**Status:** **plano apenas — nenhum código, nenhum dado real, nenhum acesso ao remoto.**
**Escopo da Fase 1:** (1) importador Python por layout, (2) staging e tela mínima de conferência, (3) primeira conciliação por fundo, (4) testes com dados reais **somente no Supabase local**.

---

## 0. Regra de ouro desta fase

> **Dado real só entra no Supabase LOCAL.** O remoto (nuvem) só recebe dado depois que o importador estiver validado localmente, com a conferência aprovada por você, e com o `db push` das migrations da Fase 1 já feito.

**Por quê:** no remoto, um lançamento errado é harder de apagar do que de corrigir — e um `db reset` (que apaga o banco inteiro) é um comando local. A curva de risco é: local → local → local → (decisão sua) → remoto.

**Consequência prática:** o importador fala com o banco por conexão direta (Postgres), não pela API REST. Ele não precisa de chave nem de `service_role`. Ele usa o role `app_importador`, que só escreve em `staging_*`.

---

## 1. Ordem de construção

A ordem é **por layout**, do mais simples ao mais difícil, e cada layout entrega um teste de ponta a ponta completo antes do próximo. Isso evita construir toda a estrutura para depois descobrir que o balancete em PDF não cabe no modelo.

| Etapa | Entrega | Por que nesta ordem |
|---|---|---|
| **E1** | Esqueleto do importador + detecção de layout + registro da fonte | Tudo depende disso |
| **E2** | Layout `extrato_v3` (6 colunas) | O mais limpo: colunas nomeadas, sem parser ambíguo |
| **E3** | Layout `extrato_v2` (5 colunas, "código - descrição") | Diferença pequena: a descrição está colada no código |
| **E4** | Layout `extrato_v1` (5 colunas, código puro) | **O bug do app antigo.** Exige reescrita do parser |
| **E5** | Normalização + chave natural + ocorrência | Depende de ter linhas brutas de verdade |
| **E6** | Classificação (rubrica, fundo, unidade) + duplicatas + transferências | Depende da normalização |
| **E7** | Staging (gravação idempotente) | Depende de E5/E6 |
| **E8** | Aprovação (RPC) + conferência mínima (front) | Depende do staging |
| **E9** | Balancete em PDF + primeira conciliação por fundo | Fecha o ciclo contábil |
| **E10** | Caixa local em PDF (página 1) + anexos | Última, por ser o layout mais frágil |
| **E11** | Plano-resumo → série histórica | É o mais simples de todos, mas depende de tudo |

⚠️ **E4 (layout v1) pode ficar para depois.** Decisão D7 (escopo) definiu importar a partir de **2025-05** — e nesse período o layout é v2/v3. O v1 (2023-07 a 2024-06) fica para uma fase posterior. **Mas** o detector de layout **precisa reconhecer o v1** desde o começo, para que um arquivo v1 aparecendo não seja processado errado em silêncio — ele deve ser detectado e virar pendência.

---

## 2. E1 — Esqueleto e detecção de layout

### 2.1 Estrutura de pastas

```
scripts/
├── pyproject.toml
├── importacao/
│   ├── __init__.py
│   ├── cli.py                  # entrypoint: detectar | parse | staging | conferir
│   ├── config.py               # caminhos, conexão, limites
│   ├── modelos.py              # dataclasses: LinhaBruta, LinhaNormalizada, ResumoArquivo
│   ├── hash.py                 # SHA-256, normalização de histórico
│   ├── detectar.py             # LAYOUTS: detecção por conteúdo
│   ├── normalizar.py           # datas, valores, competência, unidade, vencimento
│   ├── classificar.py           # rubrica, fundo, unidade (sugestões)
│   ├── duplicatas.py           # pares candidatos
│   ├── transferencias.py        # regras de sugestão
│   ├── fechar.py               # verificação contra o bloco RESUMO
│   ├── gravar_staging.py       # escrita idempotente
│   ├── parsers/
│   │   ├── __init__.py
│   │   ├── extrato.py          # v1 / v2 / v3
│   │   ├── balancete.py        # PDF, 8 seções
│   │   ├── caixa_local.py      # PDF pág. 1
│   │   └── planilha_resumo.py  # série histórica
│   └── fixtures/               # arquivos SINTÉTICOS de teste
└── tests/
    ├── test_detectar.py
    ├── test_parser_extrato.py
    ├── test_normalizar.py
    ├── test_chave_natural.py
    ├── test_fechar.py
    └── test_gravar_staging.py
```

### 2.2 A regra de detecção

**Detecção por conteúdo, nunca por extensão.** O caso que prova o ponto: `extrato_2025-01.xlsx` é um `.xlsx` que é um extrato — a detecção por extensão classifica como planilha e o arquivo nunca entra.

Para cada layout, um detector com:
- **sinal de presença**: o que não pode faltar (ex.: a linha de cabeçalho `Conta | Descrição Conta | Data | Histórico | Débito | Crédito`).
- **sinal de ausência**: o que não pode existir (ex.: para o v3, a coluna `Descrição Conta`).
- **verificação**: todas as condições precisam passar; se falhar uma, o layout é **desconhecido** e o arquivo vira pendência — nunca é processado por tentativa-e-erro.

| Layout | Sinal de presença | Sinais de ausência |
|---|---|---|
| `extrato_v1` | 5 colunas; cabeçalho `Conta \| Data \| Histórico \| Débito \| Crédito`; coluna 0 só com dígitos | sem ` - ` na coluna 0 |
| `extrato_v2` | 5 colunas; cabeçalho idem; coluna 0 com `^\d{4,5} - ` | — |
| `extrato_v3` | 6 colunas; cabeçalho `Conta \| Descrição Conta \| Data \| Histórico \| Débito \| Crédito` | — |
| `extrato_xlsx_v1` | extensão `.xlsx`; aba `contaCorrente`; 5 colunas; linha 1 = `Conta Corrente` | — |
| `balancete_v1` | PDF; página 1 contém `Balancete Mensal` e `CONDOMINIO EXEMPLO` | — |
| `caixa_local_v1` | PDF; página 1 contém `Conta Despesas Locais` | — |
| `planilha_resumo_v1` | `.xlsx`; aba `resumo do saldo`; célula `Saldo referente ao mês MM/AAAA` | — |

### 2.3 Registro da fonte

Ao detectar, o importador grava em `fontes_importacao`:
- `hash_sha256` do arquivo **inteiro** (é a trava de idempotência de arquivo);
- `layout` detectado;
- `competencia_id` detectada;
- `status` = `detectado`.

Se o `hash_sha256` **já existir** para aquele condomínio+layout → o arquivo é `ignorado_duplicata` e o importador para. Isso é a idempotência de arquivo, e é testável sem banco: basta rodar o importador duas vezes.

### 2.4 Fixtures sintéticos

**Nenhum arquivo real nos testes.** Para cada layout, uma fixture `.xls`/`.xlsx`/`.pdf` **gerada por script**, com dados inventados:

| Fixture | Conteúdo | Verifica |
|---|---|---|
| `extrato_v3_sintetico.xlsx` | 30 linhas, 3 contas, 1 unidade, bloco RESUMO que fecha | layout, colunas, RESUMO |
| `extrato_v2_sintetico.xls` | idem, coluna 0 com `1002 - COTAS CONDOMINIAIS` | layout |
| `extrato_v1_sintetico.xls` | idem, coluna 0 só com dígitos | layout — **e que o parser não embaralha as colunas** |
| `extrato_com_duplicata.xlsx` | 2 linhas idênticas (mesma tupla) | occurrence, duplicata candidata |
| `extrato_com_valor_br.xlsx` | valores como texto `56.870,00` | normalização de valor |
| `extrato_data_2_digitos.xlsx` | vencimento `VC.10/10/26` |-century do vencimento |
| `balancete_sintetico.pdf` | 3 páginas, 8 seções, RESUMO FINANCEIRO com 5 fundos | parser de PDF |
| `caixa_local_sintetico.pdf` | página 1 com 10 lançamentos + 2 páginas de comprovante | parser + anexos |

⚠️ **A fixture `extrato_v1` é a mais importante.** Ela existe para provar que o parser **não** embaralha as colunas — o bug que Affected o app antigo (data virando histórico, crédito virando débito). O teste de regressão é explícito: para a linha de origem N, `data_lancamento` tem que ser a data, `historico` o histórico, e o valor tem que ter o sinal certo.

---

## 3. E2–E4 — Parsers de extrato

### 3.1 O que cada parser devolve

**Nada de decisão.** O parser devolve linhas **cruas**, com o número da linha:

```python
@dataclass
class LinhaBruta:
    linha_origem: int          # nº da linha na planilha
    texto_origem: str          # a linha inteira, como está no arquivo
    campos: dict[str, str]     # colunas já separadas, em TEXTO
```

O parser **não** interpreta data, não converte valor, não adivinha rubrica. Quem faz isso é a etapa de normalização (E5). Essa separação é o que permite ter 3 layouts sem 3 parsers de regras.

### 3.2 O que é comum aos três layouts de extrato

- **Cabeçalho**: 3 linhas (título, período, colunas). O período define a competência.
- **Bloco RESUMO**: linhas `RESUMO - ...`, `SALDO INICIAL`, `DÉBITO TOTAL`, `CRÉDITO TOTAL`, `SALDO FINAL`. Os 4 totais são **texto** em formato brasileiro, enquanto o corpo é numérico — a conversão é por tipo de célula, não por coluna.
- **Linha em branco** antes do RESUMO: ignorada sem erro.
- **Histórico**: campo único com convenções fixas (`RC.UN.######`, `RB.#########`, `VC.DD/MM/AA`, `RC.ATR.UN.######`, `RC.MLT.UN.######`, `ANTEC.UN.######`, `RC.DECOB ######`).

### 3.3 As regras que o app antigo errou

| Regra | Erro do app antigo | Correção |
|---|---|---|
| Mapeamento de coluna por layout | O v1 caía no ramo errado: `data_lancamento` recebia o histórico, `historico` recebia o valor, e o **crédito virava débito** | Cada layout tem seu próprio mapa de colunas, testado com fixture |
| Valor BR | O corpo é numérico, o RESUMO é texto | Conversão por **tipo de célula** |
| Vencimento com 2 dígitos de ano | `strptime` com `%y` (janela 1969–2068) | Janela explícita: 2 dígitos → 20xx quando o ano estiver entre 2020 e 2049 |
| Unidade | Regex permissiva aceitava número solto | Só padrões explícitos; número solto **não** vira unidade |

---

## 4. E5 — Normalização e chave natural

### 4.1 O que é normalizado

| Campo | De | Para | Observação |
|---|---|---|---|
| `data_lancamento` | `DD/MM/AAAA` | `date` | |
| `data_vencimento` | `VC.DD/MM/AA` | `date` | Ano de 2 dígitos → 20xx (janela 2020–2049) |
| `competencia` | cabeçalho `ATÉ:` | `YYYY-MM` | Mês de referência, **nunca** a data do lançamento |
| `valor` | `0` / `1750.00` / `56.870,00` | `numeric(14,2)` | Por tipo de célula |
| `tipo_movimento` | coluna Débito/Crédito | `credito`/`debito` | Valor sempre **positivo** |
| `unidade` | histórico | texto sem zeros | Só por padrão explícito |
| `documento` | `RB.#########` | texto | |
| `historico_normalizado` | histórico | minúsculas, sem acento, sem espaço duplo | Base da chave |

### 4.2 A chave natural e a ocorrência

```
tupla  = hash(competencia | conta | data | documento | tipo | valor | historico_normalizado)
ocorrencia = quantas vezes essa tupla já apareceu NESTE arquivo (1, 2, 3...)
chave_natural = sha256(tupla + '#' + ocorrencia)
```

**Por que a ocorrência é necessária:** duas linhas idênticas no mesmo arquivo (a unidade 42 em 2025-09, linhas 527 e 528) têm a mesma tupla. Sem a ocorrência, o `unique` faria a segunda ser **descartada em silêncio** — proibido pela regra "duplicata não se descarta". Com a ocorrência, as duas entram, com chaves distintas, e o par é marcado como **candidato** a duplicata.

**Idempotência preservada:** o `numero_ocorrencia` é calculado durante o parse, varrendo o arquivo em ordem. Reimportar o mesmo arquivo reproduz os mesmos números → as mesmas chaves → `ON CONFLICT` atualiza em vez de inserir.

**Segunda trava:** `unique (condominio_id, fonte_id, linha_origem, numero_ocorrencia)` cobre o caso da reexportação que muda a formatação do histórico (a tupla muda, mas a posição no arquivo não).

### 4.3 Verificação de fechamento (obrigatória)

Antes de gravar **qualquer** linha de um extrato, o importador compara:

```
soma(créditos do corpo)   vs  "CRÉDITO TOTAL" do RESUMO
soma(débitos do corpo)    vs  "DÉBITO TOTAL"  do RESUMO
saldo_inicial + créditos - débitos  vs  "SALDO FINAL" do RESUMO
```

Se não bater (tolerância R$ 0,01), o arquivo é **bloqueado** e vira pendência `divergencia`, com o número da diferença.

⚠️ **Esse é o teste que teria pego o bug do layout v1.** Sem ele, um parser errado entra no banco em silêncio — e o app antigo mostra que isso aconteceu (os extratos de 2023–2024 nunca entraram no consolidado, mas por outro motivo: o parser os leu errado).

**Resultado esperado hoje:** os 18 extratos em escopo fecham **exatamente**. (Verificado na análise: créditos, débitos e saldo final batem com o RESUMO nos 18 arquivos.)

---

## 5. E6 — Classificação, duplicatas e transferências (sugestões)

### 5.1 Tudo é sugestão até segunda ordem

| Sugestão | Origem | Como vira decisão |
|---|---|---|
| **Rubrica** | `contas_origem` → `rubrica_aliases` → palavra-chave | `status = 'sugerida'` na approve; o auditor confirma |
| **Fundo** | `contas_origem.fundo_id` (mapeamento explícito por código) | Idem |
| **Unidade** | padrão explícito no histórico | Se não existir em `unidades` → pendência, nunca descarta |
| **Duplicata** | tupla igual, documento igual, ou valor+data+conta | `duplicatas_candidatas.status = 'pendente'` |
| **Transferência interna** | palavra-chave + prefixo de fundo + valor | `transferencias_internas.status = 'sugerida'` |

⚠️ **A classificação sugerida nunca é aplicada sozinha.** A `fn_aprovar_staging` grava `status_classificacao = 'sugerida'` — a confirmação é um ato separado (`fn_classificar_lancamento`), e só o auditor pode fazê-lo.

### 5.2 Ordem de decisão da rubrica

1. `contas_origem` do condomínio, para o código exato → sugestão direta.
2. `rubrica_aliases` por (fonte, alias, contexto) → sugestão por rótulo.
3. Regra por palavra-chave no histórico → sugestão com confiança menor.
4. Nada → **sem rubrica** + pendência `classificacao`.

### 5.3 Transferência interna: as regras e o contraexemplo

| Ordem | Regra | Nota |
|---|---|---|
| 1 | Palavra-chave no histórico: `TRANSFERENCIA`, `TRANSF.`, `APLICACAO`, `REPOSICAO`, `REMESSA DE NUMERARIO` | Mais confiável |
| 2 | Fundos diferentes + mesmo valor + **mesma competência** | O "mesma competência" é essencial |
| 3 | Contas de transferência (`1041`, `1820`, `1821`) | Sempre candidata, nunca automática |
| 4 | Valor + data | **Sozinha, nunca decide** — dois pagamentos iguais podem ser legítimos |

⚠️ **O contraexemplo que motivou a regra:** em 2026-05 há `ISS NF-218 FORNECEDOR EXEMPLO` **crédito** em `3003` (Fundo de Reserva) e **débito** em `15501` (Pintura) — mesmo valor (R$ 170,00), mesma NF, meses diferentes. Uma regra só por valor/data erraria e marcaria uma reclassificação como transferência. Por isso a regra por valor exige **mesma competência**, e a palavra-chave vem **antes**.

### 5.4 Duplicatas: os 4 casos reais catalogados

| Caso | Arquivo | Linhas | Valor |
|---|---|---|---|
| Cota do salão (unidade 42) | `extrato_2025-09.xls` | 527 e 528 | R$ 185,00 |
| Reposição de caixa local | `extrato_2026-04.xls` | 387 e 388 | R$ 1.250,00 |
| Correção monetária (unidade 17) | `extrato_2026-09.xls` | 165 e 166 | R$ 0,09 |
| Correção monetária (unidade 17) | `extrato_2026-10.xls` | 234 e 235 | R$ 0,09 |

⚠️ **O caso de 2026-04 é o mais instrutivo:** a linha 387 e a 388 são idênticas **no arquivo original** — ou seja, o banco da administradora entregou a mesma transferência duas vezes. Não é o importador duplicando. Por isso a duplicata **precisa** entrar (é fato contábil registrado) **e** precisa ser marcada (é anomalia).

---

## 6. E7 — Staging (gravação idempotente)

### 6.1 Fluxo

```
arquivo → detectar → registrar fonte → parsear → normalizar →
classificar (sugerir) → gravar em staging_lancamentos → relatório
```

### 6.2 Idempotência no staging

- `unique (importacao_id, chave_natural)` + `ON CONFLICT DO UPDATE` → reexecutar o mesmo arquivo **atualiza**, não duplica.
- `unique (importacao_id, fonte_id, linha_origem, numero_ocorrencia)` → segunda trava, por posição.

### 6.3 O relatório por arquivo (saída do importador)

```
extrato_2026-10.xls
  SHA-256: 9f2c…  ·  layout extrato_v3  ·  competência 2026-10
  ✓ fechamento: créditos 208.250,00 = RESUMO 208.250,00
  ✓ fechamento: débitos 254.340,00 = RESUMO 254.340,00
  ✓ saldo: 195.850,00 + 208.250,00 − 254.340,00 = 149.760,00 = RESUMO
  778 novas  ·  2 duplicatas candidatas  ·  8 sem rubrica  ·  0 erros de parse
```

É esse relatório que você lê antes de aprovar. Se o fechamento não bater, o arquivo é bloqueado.

### 6.4 Conexão com o banco

O importador fala com o **Postgres direto** (não pela API REST), usando o role `app_importador`:
- `INSERT`/`UPDATE` em `fontes_importacao`, `importacoes`, `staging_*`, `serie_historica_*`, `contas_origem`;
- `SELECT` em `rubricas`, `rubrica_aliases`, `fundos`, `unidades`, `competencias`;
- **nunca** `INSERT`/`UPDATE` em `lancamentos`.

⚠️ A senha do `app_importador` fica no `.env.local` (ignorado pelo Git) ou na variável de ambiente do terminal. **Não** no código.

---

## 7. E8 — Aprovação e tela mínima de conferência

### 7.1 A tela mínima (o suficiente para destravar a Fase 1)

Uma tela, com três partes:

**A. Lista de importações** — arquivo, layout, competência, data, status, quantas linhas.

**B. Conferência por arquivo** — cada linha com:
| Coluna | Origem |
|---|---|
| origem | arquivo · linha N · coluna |
| **texto original** | como está no arquivo (não o interpretado) |
| data · valor · tipo | o que o parser entendeu |
| rubrica e fundo **sugeridos** | com o botão de corrigir |
| unidade detectada | com o botão de corrigir |
| marcações | "duplicata candidata", "sem rubrica", "transferência sugerida" |
| ação | aprovar / corrigir / rejeitar (com motivo) |

**C. Barra de totais** — no topo: quantas linhas, quantas aprovadas, quantas pendentes, e o fechamento do arquivo (verde/vermelho).

⚠️ **O botão "aprovar tudo" existe, mas mostra o fechamento antes.** A aprovação em lote é para o arquivo que fecha; se não fechar, a tela exige conferência linha a linha.

### 7.2 A aprovação

`fn_aprovar_staging(p_importacao_id, p_staging_ids, p_decisoes)` — já implementada e testada (T09, T38). Faz tudo em **uma transação**: cria os lançamentos, as classificações sugeridas, os pares de duplicata, as transferências sugeridas e as pendências.

⚠️ **Aprovação não é decisão de classificação.** O que foi aprovado fica com `status_classificacao = 'sugerida'`. O painel mostra as linhas **ainda por classificar** como fila de trabalho separada.

---

## 8. E9 — Balancete em PDF e primeira conciliação por fundo

### 8.1 O parser do balancete

O PDF tem 3 páginas e 8 seções, com a seção de despesas atravessando a quebra de página:

| Seção | Uso |
|---|---|
| COMPOSIÇÃO DE ARRECADAÇÃO | conferência |
| RESUMO DE ACORDOS | conferência |
| COMPOSIÇÃO RECEITAS ORDINÁRIAS | conferência por rubrica |
| COMPOSIÇÃO DESPESAS ORDINÁRIA | conferência por rubrica (atravessa a página) |
| RECEBIMENTO DE CONTAS EXTRAORDINÁRIAS | conferência |
| DESPESAS DE CONTAS EXTRAORDINÁRIAS | conferência |
| RESUMO DE INADIMPLÊNCIA | painel (opcional) |
| RESUMO COTAS EM ABERTO | inadimplência por unidade (opcional) |
| **RESUMO FINANCEIRO** | **a base da conciliação** (saldo anterior, créditos, débitos, saldo final por fundo) |

Todos os valores são **texto com formato brasileiro**, e as despesas são **negativas**.

### 8.2 A conciliação por fundo — o que muda

**A lógica antiga (errada):** comparava a linha `CONTA CONDOMINIO` do balancete contra o **total de todos os créditos do extrato**.

**A lógica nova (por fundo):**

```
para cada fundo F da competência C:
    creditos_extrato(F)   = soma dos créditos do extrato cujo fundo = F
    debitos_extrato(F)    = soma dos débitos do extrato cujo fundo = F
    creditos_balancete(F) = créditos da linha do fundo F no RESUMO FINANCEIRO
    diferenca(F)          = balancete(F) − extrato(F)
```

**Por que isso importa:** as transferências entre fundos **se cancelam dentro do próprio fundo**. A diferença que a versão antiga reportava era exatamente a soma dos outros fundos — dinheiro que se moveu dentro do condomínio, não dinheiro que sumiu.

⚠️ **Este é o achado mais importante da análise:** os 14 "DIVERGENTE" do app anterior **desaparecem** com a contagem por fundo. O que sobra é divergência de **rubrica** (o caso Fornecedor Exemplo: NF-209 em `3500 FUNDO DE RESERVA DESPESAS` no extrato e em `MANUTENCAO DE PINTURA` no balancete) — que vira pendência, com a linha a linha em `conciliacao_detalhe`.

### 8.3 A primeira conciliação (a ser validada por você)

O objetivo da E9 é **uma competência**, a mais recente com extrato e balancete:

1. Importar o extrato da competência.
2. Aprovar no staging (você confere).
3. Importar o balancete da competência.
4. Rodar `fn_reconciliar_competencia`.
5. Ver o resultado **por fundo**, lado a lado com o RESUMO FINANCEIRO do balancete.
6. Confirmar que as diferenças são só de rubrica (não de valor).

⚠️ **Critério de aceite da E9:** o total de créditos e débitos do extrato bate com o total do balancete **por fundo**, com diferença R$ 0,00 em todos — e as pendências de divergência que restarem são **todas** de classificação, nenhuma de valor.

---

## 9. E10 — Caixa local (PDF) e anexos

- **Página 1**: a conta (Data, Histórico, Débito, Crédito, Saldo Anterior, saldo final). As linhas de despesa e as de "REMESSA DE NUMERARIO" (crédito) são naturezas diferentes — o caixa local é um fundo de giro.
- **Páginas 2+**: comprovantes escaneados (imagens). O importador extrai a página como **anexo** (bucket privado) e **sugere** a vinculação por valor (tolerância R$ 0,50), como o app antigo fazia.
- ⚠️ A extração por regex sobre imagem é frágil: **62 das 68 linhas** conciliadas no app antigo ficaram sem fornecedor/CNPJ/NF. O modelo guarda o anexo e deixa a vinculação para o auditor — não inventa metadado.

---

## 10. E11 — Planilha-resumo → série histórica

A planilha-resumo (2020–2026, 78 meses) entra em `serie_historica_resumo`:
- cada bloco mensal → uma linha por rubrica, com a linha de origem;
- o bloco `APLICAÇÃO BANCO EXEMPLO` (cabeçalho `Aporte`/`Juros`) vai com `bloco = 'aplicacao_btg'`;
- as **21 linhas de anotação** das colunas H/I/J (caderno à mão) vão para `serie_historica_anotacoes`, com o texto e a linha preservados — **não** viram rubrica.

É o passo mais simples de todos (uma aba, um bloco por mês), mas depende de E1–E7 porque usa o mesmo fluxo de fonte → detecção → gravação.

---

## 11. Estratégia de testes da Fase 1

### 11.1 Fixtures sintéticas primeiro (100% do desenvolvimento)

Cada layout tem fixture gerada por script. Nenhum arquivo real entra no repositório.

| Suíte | Cobre |
|---|---|
| `test_detectar.py` | Detecção dos 8 layouts + layout desconhecido vira pendência |
| `test_parser_extrato.py` | v1/v2/v3: coluna certa na linha certa (regressão do bug antigo) |
| `test_normalizar.py` | Data BR, valor BR, competência, unidade (só padrão explícito), vencimento de 2 dígitos |
| `test_chave_natural.py` | Idempotência + occurrence + reexportação com formatação diferente |
| `test_fechar.py` | Extrato que não fecha é bloqueado |
| `test_gravar_staging.py` | Gravar 2× não duplica |

### 11.2 Dados reais — **somente no Supabase local**

Esta é a parte que muda deossia, e o ponto mais importante do plano:

> **Nenhum dado real vai para o remoto nesta fase.**

Sequência:

| Passo | Onde | O quê | Como o dado some depois |
|---|---|---|---|
| 1 | **Local** | Copiar da pasta antiga (somente leitura) para `dados_origem/` | A pasta é ignorada pelo Git |
| 2 | **Local** | Rodar o importador contra o extrato de 2026-10 | — |
| 3 | **Local** | Conferir o relatório: fechamento verde, contagens, duplicatas | — |
| 4 | **Local** | Conferir a tela de conferência e aprovar | — |
| 5 | **Local** | Rodar `fn_reconciliar_competencia` e validar por fundo | — |
| 6 | **Local** | Testar a **reimportação** (rodar o importador de novo → zero mudança) | — |
| 7 | **Local** | `supabase db reset` → importar de novo → resultado idêntico | Prova que nada depende de estado residual |

⚠️ **O passo 7 é o teste mais importante da fase:** se o `db reset` + reimportação produz exatamente o mesmo resultado, o importador é **determinístico** — e isso é o que vai permitir rodar no remoto com confiança depois.

⚠️ **Regra de higiene com dado real:**
- `dados_origem/` fica **fora** do Git (já está no `.gitignore`);
- o importador **nunca** escreve em `lancamentos` — só em `staging_*`;
- nada de dado real sai do computador: o Postgres local é local;
- o `git status` precisa estar limpo no fim de cada passo.

### 11.3 O que continua valendo do banco

A bateria de segurança (86 verificações) **roda depois de cada mudança** no importador, porque o importador mexe no staging, que é a porta de entrada do `lancamentos`.

⚠️ **Um teste novo precisa entrar:** o importador **não** pode escrever em `lancamentos`. Hoje isso é garantido pelo papel (`app_importador` não tem o privilégio) e testado (T37). Com o importador real, vale um teste adicional: rodar o importador completo e conferir que `lancamentos` continua vazio.

---

## 12. O que a Fase 1 **não** entrega

| Fora do escopo | Por quê |
|---|---|
| Front completo | A Fase 1 entrega só a tela mínima de conferência |
| Importador do layout `extrato_v1` (2023–2024) | Decisão D7: escopo a partir de 2025-05. O **detector** reconhece o v1, mas ele vira pendência |
| Consolidação por unidade / espelho de boleto | Depende de mais de uma competência importada |
| Upload de arquivo pelo front | A Fase 1 importa por linha de comando |
| Relatórios e gráficos | Fase 2 |
| Obras, orçamentos, assembleias | Fase 2 |
| Detecção de foto de nota fiscal | Fase 2 |

---

## 13. Riscos da Fase 1

| Risco | Impacto | Mitigação |
|---|---|---|
| Parser embaralhar colunas | Alto (contabilidade errada em silêncio) | Um mapa de colunas por layout + fixture de regressão para o v1 + **verificação de fechamento obrigatória** |
| Valor do RESUMO em texto passar pelo caminho do corpo | Alto | Conversão por **tipo de célula**, não por coluna |
| Duplicata descartada pelo `unique` | Alto (dinheiro real perdido) | `numero_ocorrencia` na chave + teste |
| Classificação automática aplicada sem revisão | Alto | Tudo começa como `sugerida`; confirmação é ato separado do auditor |
| Transferência interna marcar dinheiro real | Alto | Sugestão apenas; e o consolidado padrão (`v_resultado_bruto`) **não subtrai** nada |
| Importador escrever em `lancamentos` | Alto | O role `app_importador` não tem o privilégio; teste T37 |
| Dado real ir para o Git | Alto | `dados_origem/` ignorado + verificação antes do commit |
| Dado real ir para o remoto cedo demais | Alto | Regra da fase: real só no local; o remoto vem depois, com o push das migrations da Fase 1 |
| Importador não determinístico | Médio | Teste do `db reset` + reimportação |

---

## 14. Sequência de entrega (sugestão)

| Sprint | Entrega | Critério de aceite |
|---|---|---|
| **S1** | E1 + E2 (esqueleto + `extrato_v3`) | Detecta e parseia a fixture v3; grava a fonte; relatório com fechamento |
| **S2** | E5 (normalização + chave) + E7 (staging) | Reexecutar o importador não muda nada; duplicata entra **duas** vezes, marcada |
| **S3** | E3/E4 (v2, v1) | Fixture v1: data, histórico e sinal do valor corretos |
| **S4** | E6 (classificação + duplicatas + transferências) | Sugestões coerentes com os casos reais documentados |
| **S5** | E8 (tela mínima + aprovação) | Você aprova um arquivo real no local e o `lancamentos` fica preenchido |
| **S6** | E9 (balancete + conciliação) | **Uma competência concilia por fundo com diferença R$ 0,00** |
| **S7** | E10 + E11 (caixa local + série histórica) | Anexos no bucket; 78 meses na série |

⚠️ **S6 é o marco da fase.** É quando o app passa a dizer a verdade sobre a contabilidade do condomínio.

---

## 15. Perguntas em aberto para o começo da Fase 1

1. **Escopo da primeira competência:** 2026-10 (a mais recente, com extrato e balancete) ou outra?
2. **Importador por linha de comando primeiro, ou tela de upload já?** (Recomendo CLI primeiro: o ciclo de teste é muito mais rápido.)
3. **O `dados_origem/` recebe cópia de quais arquivos primeiro?** (Recomendo: um extrato + um balancete, para provar o ciclo.)
4. **A primeira conciliação é de uma competência só, ou de um trimestre?** (Recomendo uma, para isolar problemas.)
5. **Quem aprova a primeira importação — só você?** (Sim, por enquanto.)
