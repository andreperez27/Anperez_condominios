# Relatório de qualidade dos dados — ANPEREZ CONDOMÍNIOS

**Data da análise:** 11/11/2026
**Base analisada:** `C:\Users\andre\Desktop\condominio` (somente leitura)
**Escopo:** parte contábil da Fase 0 (extrato, balancete, caixa local, rubricas, competências, documentos)

Este relatório **apenas relata** o que foi encontrado. Nenhum arquivo foi corrigido, normalizado ou alterado. Nenhuma suggestion de correção está aplicada.

---

## 1. Resumo executivo

| Achado | Situação |
|---|---|
| Totais do extrato × totais do balancete | ✅ **Conferem exatamente** (R$ 0,00 de diferença em créditos e débitos) nas 18 competências comparadas (2025-05 a 2026-10) |
| O "DIVERGENTE" do relatório antigo | ⚠️ É **artefato de cálculo** (comparação entre escopos diferentes), não divergência contábil |
| Extratos 2023-07 a 2024-06 (12 arquivos) | 🔴 **Interpretados de forma errada** pelo parser atual — datas, valor e tipo de lançamento ficam trocados |
| Extrato `extrato_2025-01.xlsx` | 🔴 Não é lido pelo pipeline (`.xlsx` tratado como planilha-resumo) |
| Duplicidades | 🟡 4 pares de linhas duplicadas no consolidado + 3 reclassificações internas repetidas |
| Rubricas sem mapeamento | 🟡 602 lançamentos (5,3%) e 55 códigos de conta (de 94) sem categoria |
| Meses faltando | 🟡 10 meses sem extrato, 3 sem balancete, 4 sem caixa local |
| Formatos mistos | 🟡 Datas e valores em 4+ formatos diferentes entre as fontes |
| Rastreabilidade atual | 🟡 Só o `extrato_consolidado.csv` guarda `arquivo_origem`; a linha de origem foi perdida na consolidação |

---

## 2. Divergências entre extrato e balancete — o ponto mais importante

### 2.1 O que a comparação real mostra

Comparando o **total do extrato** (soma de créditos e débitos de todos os lançamentos do mês) com a linha `SALDO FINAL` do **quadro RESUMO FINANCEIRO** do balancete:

| Competência | Créditos balancete | Créditos extrato | Diferença | Débitos balancete | Débitos extrato | Diferença |
|---|---|---|---|---|---|---|
| 2025-05 | 101.950,00 | 101.950,00 | **0,00** | 97.650,00 | 97.650,00 | **0,00** |
| 2025-06 | 94.130,00 | 94.130,00 | **0,00** | 92.230,00 | 92.230,00 | **0,00** |
| 2025-07 | 106.500,00 | 106.500,00 | **0,00** | 110.570,00 | 110.570,00 | **0,00** |
| 2025-08 | 100.870,00 | 100.870,00 | **0,00** | 97.930,00 | 97.930,00 | **0,00** |
| 2025-09 | 91.850,00 | 91.850,00 | **0,00** | 92.190,00 | 92.190,00 | **0,00** |
| 2025-10 | 101.500,00 | 101.500,00 | **0,00** | 92.000,00 | 92.000,00 | **0,00** |
| 2025-11 | 92.500,21 | 92.500,21 | **0,00** | 87.000,00 | 87.000,00 | **0,00** |
| 2025-12 | 118.350,00 | 118.350,00 | **0,00** | 91.520,00 | 91.520,00 | **0,00** |
| 2026-01 | 122.930,00 | 122.930,00 | **0,00** | 89.760,00 | 89.760,00 | **0,00** |
| 2026-02 | 191.080,00 | 191.080,00 | **0,00** | 179.120,00 | 179.120,00 | **0,00** |
| 2026-03 | 126.830,00 | 126.830,00 | **0,00** | 107.110,00 | 107.110,00 | **0,00** |
| 2026-04 | 93.630,00 | 93.630,00 | **0,00** | 103.780,00 | 103.780,00 | **0,00** |
| 2026-05 | 133.000,00 | 133.000,00 | **0,00** | 131.760,00 | 131.760,00 | **0,00** |
| 2026-06 | 121.640,00 | 121.640,00 | **0,00** | 100.220,00 | 100.220,00 | **0,00** |
| 2026-07 | 115.890,00 | 115.890,00 | **0,00** | 107.780,00 | 107.780,00 | **0,00** |
| 2026-08 | 116.670,00 | 116.670,00 | **0,00** | 102.680,00 | 102.680,00 | **0,00** |
| 2026-09 | 98.200,00 | 98.200,00 | **0,00** | 105.490,00 | 105.490,00 | **0,00** |
| 2026-10 | 208.250,00 | 208.250,00 | **0,00** | 254.340,00 | 254.340,00 | **0,00** |

**Nenhuma diferença real entre extrato e balancete no total do mês.**

### 2.2 Por que o relatório antigo marca 14 meses como DIVERGENTE

`balancete_status_conciliacao.csv` marca **todas as 14 competências** (2025-07 a 2026-08) como `DIVERGENTE`. A causa está em `balancete_matcher.py`: ele compara a linha **`CONTA CONDOMINIO`** do balancete contra o **total de todos os créditos do extrato**, sem excluir os demais fundos.

A diferença apurada corresponde exatamente à soma dos **outros fundos** do próprio balancete:

| Competência | Diferença créditos | Composição no balancete (linhas do RESUMO FINANCEIRO) | Confere |
|---|---|---|---|
| 2025-07 | −12.820,00 | BENFEITORIAS 9.180,00 + FUNDO 2.910,00 + SALÃO 730,00 | ✅ 12.820,00 |
| 2025-08 | −6.730,00 | BENFEITORIAS 3.320,00 + FUNDO 2.870,00 + SALÃO 540,00 | ✅ 6.730,00 |
| 2026-02 (débitos) | −92.500,00 | NF-209 FORNECEDOR EXEMPLO 92.500,00 lançada em `3500 FUNDO DE RESERVA DESPESAS` | ✅ 92.500,00 |
| 2026-10 (débitos) | −163.950,00 | FUNDO −27.500,00 + PINTURA −136.450,00 | ✅ 163.950,00 |
| 2026-10 (créditos) | −106.380,00 | BENFEITORIAS 3.530,00 + FUNDO 3.230,00 + PINTURA 99.060,00 + SALÃO 560,00 | ✅ 106.380,00 |

Em outras palavras: **as "divergências" são transferências entre os próprios fundos do condomínio**. O extrato registra, por exemplo, `TRANSFERENCIA DA CONTA APLICACAO EXEMPLO 85.000,00` (conta 15007) — dinheiro que sai da CONTA CONDOMÍNIO e entra na MANUTENÇÃO DE PINTURA. Somado sem eliminar o intra-grupo, o total do extrato parece maior que o da linha CONTA CONDOMINIO.

### 2.3 Divergências de classificação (sim, existem — mas são de rubrica, não de valor)

Mesmo com os totais batendo, há lançamentos **classificados em rubricas diferentes** entre extrato e balancete:

| Lançamento | No extrato | No balancete | Período |
|---|---|---|---|
| NF-209 FORNECEDOR EXEMPLO — pintura, R$ 92.500,00 | `3500 FUNDO DE RESERVA DESPESAS` | `MANUTENCAO DE PINTURA` | 2026-02 |
| NF-218 FORNECEDOR EXEMPLO — pintura, R$ 10.850,00 | `3500 FUNDO DE RESERVA DESPESAS` | `MANUTENCAO DE PINTURA` | 2026-03 |
| Doc-230 FORNECEDOR EXEMPLO — pintura, R$ 10.849,50 | `1647 MANUT AREAS COMUNS` | `MANUTENCAO DE PINTURA` | 2026-04 |
| FORNECEDOR PISCINA parcela, R$ 2.950,00 | `2501 DIVERSOS` (conta de despesa) | `CONTA BENFEITORIAS` | 2025-05 em diante |
| ISS NF-218/230/240/248/263 FORNECEDOR EXEMPLO, R$ 170,00 cada | ora `15501 DIVERSOS`, ora `15500 MANUTENCAO PINTURA DESPESAS` | `MANUTENCAO DE PINTURA` | 2026-04 a 2026-10 |

A planilha `despesas_a_esclarecer.xlsx` (35 linhas) já documenta parte disso, com colunas "Classificacao Atual" e "Classificacao Sugerida".

### 2.4 A conciliação extrato × planilha-resumo (`conciliacao.csv`)

499 linhas: 306 `apenas_no_extrato`, 184 `apenas_na_planilha`, 9 `divergente`.

- 306 e 184 não são erro: são **taxonomias diferentes**. A planilha-resumo tem 8 rubricas (CONTA CONDOMINIO, FUNDO DE RESERVA, SALAO DE FESTAS, BENFEITORIAS, APLICAÇÃO BANCO EXEMPLO, FDO P/TROCA TUBULACAO GAS, Mant. PINTURA, SALDO FINAL); o extrato tem 94 códigos de conta. Logo quase nada "bate" por nome.
- As 9 linhas `divergente` (2026-07 e 2026-08) exibem valores sem sentido: por exemplo, `COTA_CONDOMINIAL` com "saldo extrato" R$ 232.300,00 contra "saldo planilha" R$ 20.130,00. A causa é a mesma do item 2.2 vista pelo outro lado: `conciliacao.py` soma o **saldo inicial global do banco** (R$ 181.050,00 em 2026-07) ao **fluxo de uma única rubrica** (R$ 51.270,00 de cotas) — misturando saldo e movimento. Não é problema nos dados de origem.

---

## 3. Formatos de data misturados

| Formato | Onde aparece |
|---|---|
| `DD/MM/AAAA` (texto) | extratos `.xls` (coluna Data), PDFs da administradora, `lancamentos_caixa_local.xlsx` (Data), `despesas_a_esclarecer.xlsx`, `material_limpeza_detalhado.xlsx`, `lancamentos_pintura.xlsx` |
| `DD/MM/AA` (2 dígitos, no histórico do extrato) | campo de vencimento: `VC.10/10/26`, `V.25/07/25`, `VC.19/07/23` |
| `AAAA-MM-DD` (ISO) | `extrato_consolidado.csv` (`data_lancamento`, `data_documento`) |
| `AAAA-MM-AA 00:00:00` (datetime) | `lancamentos_hidraulica.xlsx`, `lancamentos_caixa_local.xlsx` (coluna Mês Ref.), `gastos_nao_previstos.xlsx`, `gastos_energia.xlsx`, `controle_pintura_orcamento.xlsx` |
| `MM/AAAA` | cabeçalho dos blocos da planilha-resumo ("Saldo referente ao mês 05/2025"), `lancamentos_caixa_local.xlsx` ("05/2025 — 3 lançamentos") |
| `MMM/AA` e `MMM/AAAA` | `lancamentos_hidraulica.xlsx` ("abr/25", "jun/2025"), `comparativo_energia.xlsx` ("jul/24"), `relatorio_energia.xlsx` |
| `MMAAAA` numérico | `leitura_agua_2026-10.xlsx`, coluna `MES_REF` = `102026` |
| Texto por extenso | `leitura_gas_2026-10.xlsx`, "Referência: Outubro/2026" |

Consequências observadas:
- A competência é representada de **9 maneiras** diferentes (`2025-05`, `05/2025`, `mai/25`, `maio/2025`, `abr/25`, `102026`, ...). Qualquer consolidação por competência precisa de uma normalização única, com base no **mês de referência** e não na data do documento.
- `data_documento` está vazio em **702 linhas** (6,1%) do consolidado — são os lançamentos sem vencimento no histórico (despesas de fornecedor, transfers), não data faltando.
- O ano de 2 dígitos no vencimento é resolvido pela biblioteca padrão de forma coerente com o período, mas continua sendo uma fonte de ambiguidade se um arquivo antigo entrar na base.

---

## 4. Formatos de valor misturados

| Formato | Onde aparece | Observação |
|---|---|---|
| Número decimal com ponto (`1750.00`) | corpo dos extratos `.xls` | Majority — 11.439 de 11.439 linhas |
| **Texto com formato brasileiro** (`56.870,00`) | as 4 linhas do bloco `RESUMO` de **todos os 18 extratos** | 4 células por arquivo × 18 = 72 células |
| Texto BR com sinal negativo (`-34.800,00`) | todos os PDFs de balancete | |
| Decimal com ruído binário | planilha-resumo (cópias antigas): `66211.40999999999`, `236.51000000000076`, `1019.4799999999999` | A cópia `renamed\planilha_resumo.xlsx` já vem limpa (`1019.48`) |
| Inteiro sem casas | valores como `1200`, `200`, `112` (R$ 1.250,00; R$ 200,00) | |
| Texto com prefixo e sufixo | `R$ 1.250,00`, `R$ 1.250,00 REFERENTE A CONTRATAÇÃO DE MÃO` | no PDF de caixa local, o valor aparece **dentro do histórico** |

Observações:
- Nenhum valor negativo no extrato (0 crédito negativo, 0 débito negativo). No balancete, despesas são negativas. Convenção a padronizar.
- Nenhuma linha com débito e crédito simultâneos; nenhuma linha com os dois zerados.
- `parse_valor_bruto` já trata o formato BR, mas a conversão é aplicada só onde a célula é texto — o bloco RESUMO do extrato **é** texto e os números do corpo **não** são, então uma normalização ingênua que soma coluna a coluna quebra justamente nos totais.

---

## 5. Lançamentos duplicados

### 5.1 Duplicatas exatas dentro da mesma competência (8 linhas / 4 pares)

| # | Competência | Data | Conta | Histórico | Valor | Arquivo | Linhas no arquivo bruto |
|---|---|---|---|---|---|---|---|
| 1 | 2025-09 | 10/09/2025 | 19002 | `RC.UN.000183 RB.49142365 VC.10/09/25` | 185,00 (crédito) | extrato_2025-09.xls | 527 e 528 — **duplicado no arquivo de origem** |
| 2 | 2026-04 | 10/04/2026 | 1723 | `REPOSICAO DE CAIXA LOCAL` | 1.250,00 (débito) | extrato_2026-04.xls | 387 e 388 — **duplicado no arquivo de origem** |
| 3 | 2026-09 | 21/09/2026 | 1023 | `COR.MON.DECOB 000032 21/09/26 RB.3275192` | 0,09 (crédito) | extrato_2026-09.xls | 165 e 166 — **duplicado no arquivo de origem** |
| 4 | 2026-10 | 20/10/2026 | 1023 | `COR.MON.DECOB 000032 20/10/26 RB.3275193` | 0,09 (crédito) | extrato_2026-10.xls | 234 e 235 — **duplicado no arquivo de origem** |

As duplicatas 1 e 2 já estão sinalizadas em `itens_duplicados_unidade.csv`. As duplicatas 3 e 4 (correção monetária de 8 centavos) **não** estão.

### 5.2 Mesmo valor/histórico em competências diferentes — reclassificações internas

| Valor | Aparições | Natureza |
|---|---|---|
| R$ 170,00 — `ISS NF-218 FORNECEDOR EXEMPLO` | débito 2026-04, crédito 2026-05, débito 2026-05 | ISS de 5% pago, devolvido e repagado no mês seguinte (3 lançamentos legítimos de reclassificação, mesma NF) |
| R$ 170,00 — `ISS NF-230 FORNECEDOR EXEMPLO` | crédito 2026-05 e débito 2026-05 | idem |
| R$ 1.250,00 — `REPOSICAO DE CAIXA LOCAL` | 2026-04 (2×, sendo 1 duplicata) e 2026-07 | Reposições de caixa em meses distintos |
| R$ 75,00 — `REPOSICAO DE CAIXA LOCAL` | 2026-02 e 2026-08 | idem |

Isso mostra que **"mesmo valor + mesmo histórico" não é sinal suficiente de duplicidade** — o valor isolado não identifica o documento. A chave natural precisa incluir data + conta + documento (`RB.`/`RC.`/`CB.`) + competência.

### 5.3 Arquivos duplicados na pasta

| Duplicata | Onde | Observação |
|---|---|---|
| 12 extratos 2023-07 a 2024-06 | `Extratos_gestao_01\` e `gestao1\Extratos_gestao_01\` | 11 idênticos por MD5; o de 2023-07 tem MD5 diferente mas conteúdo lido **igual** (re-exportado) |
| Planilha-resumo, 4 versões | raiz (78 blocos, até 10/2026), `data\renamed\planilha_resumo.xlsx` (78, limpa), `data\raw\...xlsx` (72, até 04/2026), `planilha-resumo-antiga.xlsx` na raiz (66, até 10/2025), `planilha-resumo_backup.xlsx` | 4 conteúdos diferentes para a mesma planilha |
| Balancete 04/2026 | `Balancetes\2026-04\balancete.pdf` e `data\renamed\balancete_2026-04.pdf` | mesmo período, MD5 diferente |
| `app_antigo.zip` (77 MB) e `assembleia_2026.zip` (27 MB) | raiz e `app condominial\` | cópias compactadas do próprio projeto |

---

## 6. Rubricas com nomes diferentes para a mesma coisa

### 6.1 No plano de contas do extrato — o mesmo código com nomes diferentes

| Código(s) | Descrição no extrato |
|---|---|
| 1098 / 2998 / 3998 / 15998 / 19998 | `MULTAS` e `MULTAS ARRECADADAS` — mesma natureza em 5 códigos |
| 1001 / 15001 / 2001 / 3001 / 19001 | `CONDOMINOS EM ATRASO` repetido em 5 fundos |
| 1006 / 2005 / 3005 / 15005 | `RECEITA PARCELAS ACORDO` em 4 fundos |
| 15999 / 19999 / 2999 / 3999 | `COTAS RECEB.P/ANTECIPACAO` / `COTAS RECEB P/ANTECIPACAO` (com e sem espaço) |
| 1052 vs 1642 | `CONSUMO DE AGUA` — um é **receita** (cobrança da unidade), o outro é **despesa** (compra/concessionária) |
| 1010 vs 1643 | `CONSUMO DE GAS` — mesma ambiguidade receita/despesa |
| 1041 vs 1820 vs 1821 | `TRANSF. REGUL. ENTRE CONTAS`, `TRANSF.REGUL. ENTRE CONTAS` (sem espaço), `TRANSFERENCIAS` |
| 1644 vs 1743 | `TELEFONE` e `TELEFONE / INTERNET` |
| 15501 vs 2501 | `DIVERSOS` em dois fundos |
| 2002 / 2003 / 2500 | `COTAS DO MES BENFEITORIAS`, `BENFEITORIAS RECEITAS`, `BENFEITORIAS DESPESAS` |
| 3002 / 3003 / 3500 | `COTAS DO MES FUNDO DE RESERVA`, `FUNDO DE RESERVA RECEITAS`, `FUNDO DE RESERVA DESPESAS` |
| 10003 / 10500 | `PORTA AUTOMATICA RECEITAS` / `PORTA AUTOMATICA DESPESAS` |

O padrão de codificação é `1xxxx` = CONTA CONDOMÍNIO, `2xxxx` = BENFEITORIAS, `3xxxx` = FUNDO DE RESERVA, `15xxx` = MANUTENÇÃO DE PINTURA, `19xxx` = SALÃO DE FESTAS, `10xxx`/`10500` = PORTA AUTOMÁTICA. **O código do prefixo já identifica o fundo** — informação que se perde quando tudo vira uma string de categoria.

### 6.2 Entre a planilha-resumo, o balancete e o extrato

| Planilha-resumo | Balancete | Extrato |
|---|---|---|
| `CONTA CONDOMINIO` | `CONTA CONDOMINIO` | `COTAS CONDOMINIAIS` (1002) |
| `BENFEITORIAS` | `CONTA BENFEITORIAS` | `COTAS DO MES BENFEITORIAS` (2002) |
| `FUNDO DE RESERVA` | `FUNDO DE RESERVA` | `COTAS DO MES FUNDO DE RESERVA` (3002) |
| `Mant. PINTURA` / `MANUT. PINTURA` | `MANUTENCAO DE PINTURA` | `COTAS DO MES MANUT. PINTURA` (15002) |
| `SALAO DE FESTAS` / `SALÃO DE FESTAS` | `SALAO DE FESTAS` | `COTAS DO MES SALAO DE FESTAS` (19002) |
| `APLICAÇÃO BANCO EXEMPLO` / `APLICACAO BANCO EXEMPLO` | — | `REND.APLIC.FINANC` (1026), `TRANSF. REGUL. ENTRE CONTAS` (1041) |
| `FDO P/TROCA TUBULACAO GAS` | — | `CONSERVACAO DE BOMBAS` (1564) / `1592 MANUT. EQ. GINASTICA` |

Os blocos do balancete usam rótulos próprios (`DESPESAS COM PESSOAL`, `CONCESSAO DE SERVICOS`, `REGUL. DESPESAS ENTRE CONTAS`, `MATERIAIS P/CONSERV. E MANUT.`) que **não existem** no extrato — 184 linhas de `balancete_comparativo_despesas.csv` ficaram como `CONTA_NAO_MAPEADA_*`.

### 6.3 55 códigos de conta sem rubrica (602 lançamentos = 5,3% do consolidado)

Os 20 maiores:

| Código | Descrição | Lançamentos |
|---|---|---|
| 1667 | DESPESA C/PESSOAL-TERCEIRIZADO | 72 |
| 1648 | LEITURA DE CONSUMOS | 49 |
| 15001 | CONDOMINOS EM ATRASO | 27 |
| 1561 | CONSERVACAO DE PISCINA | 26 |
| 1621 | MATERIAL DE LIMPEZA | 26 |
| 1099 | ANTECIPACOES | 25 |
| 2999 | COTAS RECEB.P/ANTECIPACAO | 25 |
| 3999 | COTAS RECEB P/ANTECIPACAO | 25 |
| 1592 | MANUT. EQ. GINASTICA | 23 |
| 15999 | COTAS RECEB.P/ANTECIPACAO | 21 |

Seguem mais 45 códigos com 1 a 18 lançamentos cada (custos processuais, honorários, certificação digital,ischenes etc.). Nenhum lançamento tem categoria por engano — são **faltas de mapeamento**, não erros de classificação.

### 6.4 Cahier de anotações dentro da planilha-resumo

21 linhas nas colunas H, I e J da planilha-resumo contêm valores digitados à mão, fora de qualquer rubrica ("TOTAL FUNDO RESERVA", "desc. IRRF", "gasto 4800.00", "credito 6560.00"). Não são rubricas — são anotações que se misturam às linhas de dados na mesma tabela.

---

## 7. Problemas técnicos encontrados (relevantes para o novo importador)

### 7.1 🔴 Os extratos de 2023-07 a 2024-06 são lidos de forma errada

Execução real do parser atual (`src\parser_extrato.py`) sobre `Extrato_2023_07.xls` produziu:

```
LancamentoExtrato(competencia='2023-07',
                   data_lancamento='RC.ATR.UN.000012 RC.00000012 V.10/06/23',   # <- era o histórico
                   unidade=None,                                                   # <- não extraiu a unidade
                   codigo_conta='1001',
                   descricao_conta='03/07/2023',                                   # <- era a data
                   historico_bruto='0',                                             # <- era o valor de débito
                   valor=995.00,                                                     # <- era o CRÉDITO
                   tipo='debito',                                                   # <- era crédito
                   ...)
```

Causa: o layout de 5 colunas sem a coluna "Descrição Conta" cai no ramo errado do parser. Consequência: **data errada, unidade não identificada, crédito tratado como débito, histórico perdido**. Isso afeta **12 arquivos, ~7.000 lançamentos**, ou seja, todo o histórico de 2023 e 2024. Nenhum desses dados chegou ao `extrato_consolidado.csv` (que começa em 2025-05) — o que explica por que o problema ficou oculto.

### 7.2 🔴 `extrato_2025-01.xlsx` não entra no pipeline

- `parser_extrato.py` lê com `engine="xlrd"`, que só suporta `.xls` → erro "Excel xlsx file; not supported".
- `file_indexer.py` / `file_renamer.py` classificam **qualquer `.xlsx`** como `PLANILHA_RESUMO`, então o arquivo de extrato é tratado como se fosse a planilha-resumo.
- Resultado: **janeiro/2025 não tem extrato na base consolidada**, apesar de o arquivo existir.

### 7.3 🟡 Balancete de 01/2025 existe mas está fora da pasta oficial

`Balancetes\balancete_2025-01.pdf` (e o `.xlsx` derivado) não estão em `data\renamed\`, e o `file_indexer` só varre `balancete_*.pdf` — então esse balancete nunca foi conciliado. O `balancete_status_conciliacao.csv` começa em 2025-07.

### 7.4 🟡 A consolidação perde a linha de origem

- `lancamentos_normalizados.csv` tem `arquivo_origem` + `linha_origem` ✅
- `extrato_consolidado.csv` tem `arquivo_origem`, mas **nenhuma coluna de linha** ❌ — e o nome do arquivo é repetido em `arquivo_origem` e `nome_arquivo`.
- Como auditoria exige rastreabilidade até a linha, isso precisa ser resolvido no novo modelo.

### 7.5 🟡 Colisão de identificador nas validações manuais

`data\manual_validations.csv` tem 5 linhas, todas com o **mesmo `id_registro` = `7fb9100cff21`**, mas com valores diferentes (15,50 / 1,75 / 11,50 / 15,50 / 160,50) e mesmo histórico `MUL.DECOB UN.000014 27/03/26 RB.3131865`.

Causa: `gerar_id_registro()` calcula MD5 de `competencia|unidade|codigo_conta|data_lancamento` **sem o valor**. Um mesmo evento com múltiplos lançamentos parciais (correção monetária fracionada) gera ids idênticos → a 4ª e a 5ª validação sobrescrevem as anteriores. As 5 linhas estão com `status_suspeita = pendente`, `usuario` vazio e `justificativa` vazia.

### 7.6 🟡 A renomeação automática não está funcionando

`logs\log_renomeacao.csv` tem 43 linhas e **todas com status `IGNORADO`** e a mensagem "Arquivo já existe com mesmo hash". O mecanismo de dedup por MD5 impede que versões re-exportadas (que mudam de hash) entrem, e o log mostra que nenhuma varredura recente conseguiu indexar arquivo novo.

### 7.7 🟡 `requirements.txt` incompleto

Declara apenas `pandas`, `openpyxl`, `xlrd`, `pyyaml`. O código real usa também `pdfplumber` (parsers de PDF), `streamlit` e `plotly` (app). Instalar só o `requirements.txt` quebra os parsers de balancete e caixa local.

### 7.8 🟡 Sem validação de schema nas tabelas de apoio

As planilhas de apoio têm cabecalhos que mudam de nome entre versões (`Descricao`/`Descrição`, `Conta Original`/`Conta Contábil`, `Valor (R$)`/`Valor`). O `src\utils.py` tem um mecanismo `ensure_columns`/`ensure_schema` com log de auditoria (`COLUMN_AUDIT_LOG`) justamente para isso, mas ele é aplicado apenas no pipeline do Streamlit — não nos scripts de linha de comando.

---

## 8. Linhas sem descrição / sem vínculo

| Situação | Quantidade (consolidado, 11.439 linhas) |
|---|---|
| Histórico vazio | **0** |
| Código de conta vazio | 0 |
| Descrição de conta vazia | 0 |
| Sem `categoria` (rubrica) | 602 (5,3%) |
| Sem `unidade` | 716 (6,3%) — lançamentos de condomínio, não de morador |
| Sem `documento` (RB/RC/CB) | 802 (7,0%) |
| Sem `data_documento` (vencimento) | 702 (6,1%) |
| Débito e crédito ambos preenchidos | 0 |
| Débito ou crédito negativo | 0 |
| Unidade fora da lista oficial das 72 | **0** (as 72 unidades detectadas batem com `unidades.yaml`) |

Sobre as unidades: as 72 unidades do condomínio aparecem, e `config\unidades.yaml` foi corrigido recentemente (commit "unidades.yaml agora reflete as 72 unidades oficiais — removeu 118,130,140,145,179; adicionou 14"). Os extratos de 2023-2024 citam 71 unidades distintas, **todas** dentro da lista oficial vigente.

**Ressalva sobre a lista oficial:** a lista de 72 pressupõe o padrão "andar + posição" (1º andar = 11,50,13,14). O extrato de 2023-07 traz `RC.DECOB 000013` e `RC.UN.000183` — este último está na lista oficial, mas o histórico também referencia unidades com numeração de 3 dígitos (`000033`) que se sobrepõem à lógica de "andar + posição" (33 = andar 3, posição 3). Qualquer modelo novo precisa guardar a unidade como **identificador do condomínio**, não como número solto.

---

## 9. Meses faltando

| Série | Cobertura | Lacunas |
|---|---|---|
| Extratos bancários | 2023-07 a 2024-06 (12) + 2025-05 a 2026-10 (18) + jan/2025 (xlsx) = **31 meses** | **2024-07 a 2025-04 — 10 meses sem extrato** |
| Balancetes da administradora | 2025-01 + 2025-05 a 2026-10 = **19** | **2025-02 a 2025-04 — 3 meses** |
| Conta de despesas locais (caixa local) | 2025-05 a 2026-10 = **18** | **2025-01 a 2025-04 — 4 meses** |
| Planilha-resumo | 05/2020 a 10/2026 = **78, sem lacuna** | — |
| Consolidação efetivamente gerada | 2025-05 a 2026-10 (18 competências) | 2023-07 a 2025-04 não foram consolidados |
| Conciliação balancete × extrato | 2025-07 a 2026-08 (14) | 2025-05, 2025-06, 2026-09, 2026-10 sem conciliação registrada |
| Faturas Concessionaria Energia | 07/2025, 08/2025, 10/2025, 09/2026 | 09/2025 a 06/2026 (10 meses) |
| Leituras de água/gás | 10/2026 (Concessionaria Agua + Concessionaria Gas) + 11/2025 e 01/2026 (gás) | série de leituras incompleta |

---

## 10. Caixa local

- 68 lançamentos conciliados com o extrato (por valor + data), 7 **sem correspondência** no extrato:
  - `SUPORTE FIBRA BUCHA ARTICULADO` 49,50 (08/2025)
  - `REMESSA DE NUMERARIO P/ DESPESAS LOCAIS` 49,50 (08/2025) — sem data no PDF
  - `COMPRA DE REFRIGERANTES, SUCOS E DOCES PARA O DIA` 151,50 (10/2025)
  - `COMPRA DE REFRIGERANTE, SUCOS E DOCES PARA O DIA` 258,50 (10/2025) — grafia quase idêntica à anterior, provável duplicata real
  - `REPOSICAO DE CAIXA LOCAL` 405,00 (10/2025), 1.750,00 e 1.250,00 (04/2026) — reposições que não foram encontradas no extrato
- Descrições truncadas no PDF ("COMPRA DE CAFÉ, AÇÚCAR PARA O CONDOMÍNIOE 02") — o texto é cortado na extração, não no original.
- O PDF traz **duas naturezas** de linha: a despesa ("COMPRA DE...") e a remessa ao caixa ("REMESSA DE NUMERARIO P/ DESPESAS LOCAIS", crédito). O saldo da conta local fica em 0 ao final do mês.
- Fornecedor/CNPJ/NF só existem quando há comprovante escaneado legível (páginas 2+): a extração por regex sobre texto renderizado de imagem é frágil — 62 das 68 linhas conciliadas estão com fornecedor/CNPJ/NF **vazios**.

---

## 11. Pontos que exigem decisão do usuário (não foram corrigidos)

1. **Escopo temporal da importação**: começar em 2025-05 (dado já validado) ou importar também 2023-07 a 2025-04 (exige corrigir o leitor do layout de 5 colunas)?
2. **Fundos e transferências internas**: modelar `fundo` (conta condomínio, benfeitorias, fundo de reserva, pintura, salão) como entidade, com o extrato marcando transferências internas — ou manter só rubricas?
3. **Inadimplência**: os 14 registros de `unidades_inadimplentes_presumidas.csv` são inferência por ausência. Confirmar inadimplência exige cruzar com o balancete (`RESUMO COTAS EM ABERTO`) e com `RESUMO DE INADIMPLÊNCIA`.
4. **Validação manual pendente**: as 5 linhas de `manual_validations.csv` estão com `status = pendente` e sem responsável. São da competência 2026-03, unidade 14.
5. **`despesas_a_esclarecer.xlsx`**: 35 despesas com "Classificacao Sugerida" preenchida — falta o aceite ou a recusa.
6. **`documento_criptografado.pdf`** está criptografado (AES) — definir se fica de fora ou se a senha é conhecida.
7. **Duplicatas de R$ 0,09** (correção monetária) não sinalizadas pelo app antigo — decidir se entram no novo modelo com marcação automática de duplicidade.

---

## 12. Como os achados acima se traduzem no modelo novo (sem implementar agora)

| Achado | Exigência para o modelo |
|---|---|
| 3 layouts de extrato + 1 `.xlsx` | Tabela de "fontes de importação" precisa guardar **formato/layout detectado**, e o parser precisa ser guiado por layout, não por tentativa-e-erro |
| Extrato 2023-2024 lido errado | Nenhum dado entra sem passar por uma conferência (staging) com prévia de contagem, soma e amostra por competência |
| Rastreabilidade perdida na consolidação | Todo lançamento guarda `fonte_id` + `linha_origem` + `hash_arquivo` + `aba` |
| 3 taxonomias diferentes (extrato / planilha / balancete) | Tabela de **rubricas** própria, com *aliases* por fonte, e mapeamento explícito por código de conta |
| Transferências internas entre fundos | temptedo de fundo/recurso na própria linha de lançamento, para eliminar dupla contagem no consolidado |
| 9 formatos de competência e 5 de data | Competência como chave canônica `YYYY-MM` + data de competência do lançamento separada da data de vencimento |
| Valores BR como texto | Todo valor gravado como `numeric(14,2)` no Postgres; a conversão BR acontece só na entrada, com teste por arquivo |
| Duplicatas com mesmo valor em meses diferentes | Chave de idempotência = hash de (competência, data, conta, documento, valor, sinal), **não** só valor+histórico |
| RLS e dados sensíveis por unidade | Anonimização/separação entre dado nominal de unidade e dado agregado, a decidir |
| 7 despesas de caixa local sem par no extrato | Staging precisa aceitar linhas órfãs (sem correspondência) sem rejeitar o arquivo inteiro |
