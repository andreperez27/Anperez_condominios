# Inventário de dados — ANPEREZ CONDOMÍNIOS

**Data da análise:** 11/11/2026
**Origem:** `C:\Users\andre\Desktop\condominio` (somente leitura — nada foi alterado, movido ou apagado)
**Escopo desta etapa:** Fase 0 (estrutura multi-condomínio) + parte contábil (extrato, balancete, caixa local, rubricas, competências, documentos)
**Fora do escopo desta análise:** obras, orçamentos, assembleias e campanha eleitoral (Fase 2). Aparecem aqui apenas como registro do que existe.

---

## 1. Panorama geral da pasta antiga

| Métrica | Valor |
|---|---|
| Total de arquivos (recursivo, incluindo `.git` e `__pycache__`) | 586 |
| Tamanho total | ~189 MB |
| Distribuição por tipo | 173 sem extensão / 87 `.pdf` / 75 `.xlsx` / 42 `.xls` / 41 `.pyc` / 38 `.py` / 38 `.csv` / 36 `.docx` / 11 `.md` / 10 `.png` / 2 `.zip` / 2 `.yaml` |
| Bancos SQLite / `.db` | **nenhum** — o app antigo é 100% baseado em arquivos (CSV/XLSX) |
| Repositório Git | sim, apenas em `app condominial/` (remote `github.com/andreperez27/app_condominial.git`, branch `master`, 37 arquivos versionados, árvore de trabalho com 12 arquivos modificados e vários não rastreados) |

Não há chaves, senhas ou tokens versionados. O `.gitignore` do app antigo já exclui `data/renamed/*.xls|xlsx|pdf`, `data/uploads/`, `logs/`, `output/*.csv` e `data/manual_validations.csv` — ou seja, os dados brutos já eram tratados como sensíveis.

---

## 2. Estrutura de nível superior

```
C:\Users\andre\Desktop\condominio\
├── app condominial\          # projeto Python/Streamlit (código + dados trabalhados)
├── Balancetes\               # balancetes da administradora (2025-01 e 2026-04)
├── contas energia\           # faturas Concessionaria Energia (2025-07 a 2026-09) + planilha de consumo
├── Extratos_gestao_01\       # extratos bancários 2023-07 a 2024-06
├── gestao1\                  # cópia da pasta acima + "planilha-resumo-antiga.xlsx"
├── AGO_2026_campanha\        # campanha eleitoral (não contábil)
└── ~25 arquivos soltos na raiz
```

### 2.1 `app condominial\` — o sistema atual

| Caminho | Conteúdo | Observação |
|---|---|---|
| `src\` | 11 módulos (`parser_extrato`, `parser_planilha`, `normalizacao`, `conciliacao`, `exportacao`, `models`, `utils`, `logging_config`, `main`, `analise_cobertura`) + `parsers\` (2) + `services\` (13) + `exporters\` (1) | É o código-fonte da lógica de negócio e do mapeamento contábil |
| `config\mapa_contas.yaml` | 4.464 B | Plano de rubricas: 41 códigos de conta → categoria, + 12 regras por palavra-chave, + 17 mapeamentos da planilha-resumo |
| `config\unidades.yaml` | 917 B | Lista oficial das 72 unidades (18 andares × 4) |
| `config\faturas_concessionaria.csv` | 90 B | **Só o cabeçalho** — arquivo vazio, sem dados |
| `data\raw\planilha-resumo.xlsx` | 131 KB | Cópia da planilha-resumo com 72 blocos mensais (05/2020 a 04/2026) |
| `data\renamed\` | 55 arquivos | Pasta "oficial": 18 extratos `.xls`, 18 balancetes `.pdf`, 18 despesas-locais `.pdf`, 1 `planilha_resumo.xlsx` (78 blocos, 05/2020 a 10/2026) |
| `data\uploads\` | vazio (`.gitkeep`) | Área temporária do uploader do Streamlit |
| `data\manual_validations.csv` | 1 KB, 5 linhas | Correções manuais do usuário (formato de 17 colunas) |
| `logs\log_renomeacao.csv` | 7,5 KB, 43 linhas | Registro da renomeação automática; **todas as 43 linhas com status `IGNORADO`** (hash duplicado) |
| `output\` | 41 arquivos | Artefatos gerados: `extrato_consolidado.csv` (2,5 MB / 11.439 linhas), `extrato_consolidado_condominio.xlsx` (891 KB), ~20 CSVs de auditoria, `conciliacao.xlsx`, PDFs de impressão |
| `Planilhas\` | 15 `.xlsx`/`.csv` | Planilhas de apoio: caixa local, hidráulica, Fornecedor Hidraulica, Fornecedor Pintura, despesas a esclarecer, piscina, material de limpeza, compra de água, água/gás por unidade, leituras, energia, orçamento de pintura, comparativo de energia |
| `Planilhas_backup_20261006\`, `Planilhas_backup_20261105\` | 13 arquivos cada | Duas cópias de segurança das planilhas de apoio |
| `planilhas enviadas pela administradoras\` | 2 `.xlsx` | Leituras da Concessionaria Agua (água) e Concessionaria Gas/CONCESSIONARIA GAS (gás) — arquivo original da administradora |
| `NFs\` | 2 PDFs | NF-e de fornecedores (Fornecedor Bombas, Fornecedor Engenharia) |
| `AGO_2026\` | ~60 arquivos | Atas de assembleia, anexos, documentos oficiais, relatórios, gráficos |
| `streamlit_app.py` | 123 KB | Dashboard principal |
| `scripts\` | 3 `.py` | `consolidar_extratos.py`, `consolidar_leituras.py`, `gerar_controle_pintura.py` |
| `tests\` | 3 arquivos | 29 testes cobrindo `utils`, `normalizacao`, `conciliacao` (sem cobertura de parsers de PDF e do consolidator) |
| `README.md`, `AGENTS.md` | 5,3 KB / 5,8 KB | Documentação do projeto e instruções para agentes |
| `requirements.txt` | 54 B | `pandas`, `openpyxl`, `xlrd`, `pyyaml` (incompleto: faltam `streamlit`, `plotly`, `pdfplumber`) |
| `app_antigo.zip`, `assembleia_2026.zip` | 77 MB / 27 MB | Cópias compactadas |

### 2.2 `Balancetes\`

| Arquivo | Tamanho | Período | Formato |
|---|---|---|---|
| `balancete_2025-01.pdf` | 21 KB | 01/2025 a 31/2025 | PDF, 3 páginas, texto extraível |
| `balancete_2025-01.xlsx` | 27 KB | 01/2025 | XLSX, abas "Table 1" e "Table 2" (extração do PDF) |
| `2026-04\balancete.pdf` | 21 KB | 01/04/2026 a 30/04/2026 | PDF, 3 páginas (duplicata de `data\renamed\balancete_2026-04.pdf`, MD5 diferente) |
| `2026-04\extrato_conta_2026-04.pdf` | 66 KB | 01/04/2026 a 30/04/2026 | PDF, 15 páginas — **extrato bancário em PDF** (formato da administradora, valores BR) |
| `2026-04\caixa_local.pdf` | 3,4 MB | 01/04/2026 a 30/04/2026 | PDF, 22 páginas — conta de despesas locais (página 1 = tabela, demais = comprovantes escaneados) |
| `2026-04\resumo_despesas_anual.pdf` | 27 KB | 05/2025 a 04/2026 | PDF, 3 páginas — resumo anual de despesas, 12 colunas (uma por mês) |

### 2.3 `contas energia\`

`Concessionaria Energia 07-2025.pdf` (685 KB), `Concessionaria Energia 08-2025.pdf` (685 KB), `Concessionaria Energia 09-2026.pdf` (885 KB), `Concessionaria Energia 10-2025.pdf` (628 KB) e `gastos_energia.xlsx` (17 KB, 18 linhas: mês + valor de energia). Série com lacuna: **faltam 09/2025 a 06/2026**.

### 2.4 `Extratos_gestao_01\` e `gestao1\`

12 arquivos `.xls` (60–81 KB cada) cobrindo **2023-07 a 2024-06**, um por mês, nome `Extrato_AAAA_MM.xls`.
`gestao1\` repete os mesmos 12 arquivos (11 idênticos por MD5; o de 2023-07 difere byte a byte, embora o conteúdo lido seja igual) e acrescenta `planilha-resumo-antiga.xlsx` (66 blocos, 05/2020 a 10/2025).

### 2.5 Arquivos soltos na raiz

| Arquivo | Tamanho | O que é |
|---|---|---|
| `planilha-resumo.xlsx` | 135 KB | **Planilha-resumo mais recente**: 78 blocos mensais (05/2020 a 10/2026) |
| `planilha-resumo_backup.xlsx` | 132 KB | Backup da anterior |
| `planilha-resumo-antiga.xlsx` | 38 KB | Planilha-resumo antiga: 66 blocos (05/2020 a 10/2025) |
| `Despesa_Geral_Condominio Exemplo.xlsx` | 36 KB | 2 abas: "Gastos Total" (251 linhas × 12 colunas, despesa × mês, 2025) e "Previsão" (84 linhas, 2026) |
| `extrato_2025-01.xlsx` | 29 KB | Extrato bancário de **01/2025** em XLSX (aba "contaCorrente", 601 linhas) |
| `extrato_gas_2025-11.xlsx` / `extrato_gas_2026-01.xlsx` | 320 KB cada | Extrato individualizado de gás (CONCESSIONARIA GAS), 94 linhas × 15 colunas, com metadados de administradora |
| `gas_2025-08.xlsx`, `projecao_controle_gas.xlsx`, `verificacao_gas.xlsx`, `ajuste_valor_gas.xlsx` | 24–156 KB | Análises de medição de gás por unidade |
| `fundo_benfeitorias.xlsx` | 12,6 KB | 2 abas: "Planilha1" (fundo de benfeitorias: valor por morador, total mensal, fundo total, uso) e "Planilha2" (impacto dos fundos na cota) |
| `gastos_nao_previstos.xlsx` | 13 KB | 12 gastos fora da previsão (data, valor, descrição) |
| `contas_energia.xlsx` / `contas_energia_teste.xlsx` | 15 KB cada | Memória de cálculo de fatura Concessionaria Energia (kWh, bandeiras tarifárias) |
| `boleto_conservacao.pdf` | 63 KB | Boleto da FORNECEDOR PISCINA (contrato de conservação) |
| `documento_criptografado.pdf` | 1,6 MB | **PDF criptografado (AES)** — não extraível sem senha |
| `documento_assembleia.docx`, `lista_assinaturas_age.docx` | 16–17 KB | Documentos de assembleia (Fase 2) |
| `app_antigo.zip`, `assembleia_2026.zip` | 77 MB / 27 MB | Backups compactados |

---

## 3. Estruturas das planilhas contábeis

### 3.1 Extrato bancário (`.xls` da administradora)

Existem **três layouts diferentes** no mesmo conjunto de arquivos. Isso é central para o importador:

**Layout 1 — 5 colunas, código sem descrição (2023-07 a 2024-06)**
```
1  Conta Corrente | CONDOMINIO EXEMPLO
2  Período | DE: | 01/07/2023 | ATÉ: | 31/07/2023
3  Conta | Data | Histórico | Débito | Crédito
4  1001 | 03/07/2023 | RC.ATR.UN.000012 RC.00000012 V.10/06/23 | 0 | 995.00
...
591 RESUMO - CONDOMINIO EXEMPLO
592 SALDO INICIAL | ... | 90.800,00      <- texto BR
593 DÉBITO TOTAL  | ... | 86.500,00      <- texto BR
594 CRÉDITO TOTAL | ... | 79.500,00      <- texto BR
595 SALDO FINAL   | ... | 83.800,00      <- texto BR
```
Sem coluna de descrição de conta. Este é o formato que **o parser atual interpreta errado** (ver QUALIDADE_DADOS.md, item 7.1).

**Layout 2 — 5 colunas, "código - descrição" na primeira coluna (2025-07 a 2026-05)**
```
3  Conta | Data | Histórico | Débito | Crédito
4  1001 - CONDOMINOS EM ATRASO | 01/07/2025 | RC.ATR.UN.000013 RC.00000013 V.10/06/25 | 0 | 1500.00
```

**Layout 3 — 6 colunas, código e descrição separados (2025-05, 2025-06 e 2026-06 a 2026-10)**
```
3  Conta | Descrição Conta | Data | Histórico | Débito | Crédito
4  1001 | CONDOMINOS EM ATRASO | 01/06/2026 | RC.ATR.UN.000014 RC.00000014 V.10/05/26 | 0 | 1250.00
```

Padrão comum a todos: cabeçalho em 3 linhas; bloco `RESUMO - CONDOMINIO EXEMPLO` no fim com 4 linhas de total (**em texto com formato brasileiro**, enquanto o corpo é numérico); linha em branco antes do RESUMO; nenhuma linha de cabeçalho repetida dentro do arquivo; sem linha de total por conta.

Histórico: campo único e livre, com convenções fixas que carregam toda a informação:
- `RC.UN.000012` — recebimento de cota da unidade 12 (6 dígitos com zero à esquerda; `RC.ATR.UN` = atraso; `RC.MLT.UN` = multa; `RC.DECOB 000061` = acordo/decoreb)
- `RB.00000015` / `RC.00000015` / `CB.00000016` — número do documento/referência bancária
- `VC.10/10/26` / `V.25/07/25` — vencimento em `DD/MM/YY`
- `ANTEC.UN.000017` — antecipação

### 3.2 Planilha-resumo (`planilha-resumo.xlsx`)

Uma única aba `resumo do saldo` com **78 blocos** de 7 a 10 linhas, um por mês, de 05/2020 a 10/2026, sem lacunas. Estrutura do bloco:

```
Saldo referente ao mês 05/2025          <- título do bloco
DESCRIÇÃO | SALDO ANT. | CRÉDITOS | DÉBITOS | SALDO   <- cabeçalho (muda de grafia ao longo do tempo)
CONTA CONDOMINIO | 43100.00 | 95200.00 | 88600.00 | 49700.00
FUNDO DE RESERVA | 3200.00  | 2990.00  | 3200.00  | 2990.00
SALAO DE FESTAS   | 9700.00  | 550.00   |          | 10250.00
BENFEITORIAS      | 800.00   | 3400.00  | 5800.00  | -1600.00
SALDO FINAL       | 56800.00 | 102000.00 | 97700.00 | 61100.00
DESCRIÇÃO | SALDO ANT. | Aporte | Juros | SALDO     <- segundo bloco do mês (aplicação BANCO EXEMPLO)
APLICAÇÃO BANCO EXEMPLO | 137000.00 | 3200.00 | 1100.00 | 141300.00
```

Pontos de atenção:
- O bloco de **Aplicação BANCO EXEMPLO** tem um cabeçalho diferente (`Aporte`/`Juros` em vez de `Crédito`/`Débito`) — é outro tipo de rubrica, não uma linha da conta.
- Colunas H, I e J são usadas como **caderno de anotações** (21 linhas com valores digitados à mão, ex.: "TOTAL FUNDO RESERVA", "desc. IRRF", "gasto/credito").
- A partir de **07/2025 as linhas `SALDO FINAL` perderam as colunas CRÉDITOS e DÉBITOS** (18 dos 78 blocos ficam sem esses dois valores).
- Rubricas presentes: `CONTA CONDOMINIO`, `FUNDO DE RESERVA`, `SALAO DE FESTAS`, `SALDO FINAL` (em todos os 78) + `BENFEITORIAS` (35), `APLICAÇÃO BANCO EXEMPLO` (31), `FDO P/TROCA TUBULACAO GAS` (15), `Mant. PINTURA` (11).
- Valores: ponto flutuante com ruído binário (`66211.40999999999`, `1019.4799999999999`).
- `renamed\planilha_resumo.xlsx` é a versão mais limpa (saldo 1019.48 sem ruído) e com 78 blocos.

### 3.3 Balancete da administradora (PDF)

3 páginas por competência, sempre com esta sequência:

- **Pág. 1:** cabeçalho (`Balancete Mensal / 0001 - CONDOMINIO EXEMPLO / Período DD/MM/YYYY até DD/MM/YYYY`), `COMPOSIÇÃO DE ARRECADAÇÃO` (12 linhas + TOTAL), `RESUMO DE ACORDOS`, `COMPOSIÇÃO RECEITAS ORDINÁRIAS` (13 linhas + TOTAL), início de `COMPOSIÇÃO DESPESAS ORDINÁRIA`
- **Pág. 2:** continuação das despesas ordinárias (7 linhas + TOTAL), `RECEBIMENTO DE CONTAS EXTRAORDINÁRIAS` (5 linhas + TOTAL), `DESPESAS DE CONTAS EXTRAORDINÁRIAS` (3 linhas + TOTAL), `RESUMO DE INADIMPLÊNCIA` (5 totais), `RESUMO COTAS EM ABERTO` (código de unidade com 6 dígitos + quantidade + valor + TOTAL)
- **Pág. 3:** `RESUMO FINANCEIRO` — quadro `DESCRIÇÃO | SALDO ANT. | CRÉDITOS | DÉBITOS | SALDO FINAL` com uma linha por fundo (CONTA CONDOMINIO, CONTA BENFEITORIAS, FUNDO DE RESERVA, MANUTENCAO DE PINTURA, SALAO DE FESTAS) e a linha `SALDO FINAL`; depois `SALDO CAIXA LOCAL EM DD/MM/YYYY` e `SALDO EM CONTAS BANCÁRIAS DO CONDOMÍNIO` (banco, agência/conta, valor)

Todos os valores em **texto com formato brasileiro** (`-34.800,00`) e despesas com sinal negativo.

### 3.4 Conta de despesas locais (PDF, "Conta Despesas Locais")

Página 1 traz a conta: `Período de: DD/MM/YYYY até DD/MM/YYYY`, `Data | Histórico | Débito | Crédito`, `Saldo Anterior`, os lançamentos, a linha de total e `Saldo da Conta Despesas Locais`. As páginas seguintes são **comprovantes escaneados** (imagens) — o parser tenta extrair fornecedor, CNPJ, número da NF e valor do comprovante por regex sobre o texto extraído, e casa o valor com o lançamento (tolerância de R$ 0,50).

### 3.5 Planilhas de apoio (relevantes para a contabilidade)

| Planilha | Abas | Formato |
|---|---|---|
| `lancamentos_caixa_local.xlsx` | 1 (108 linhas) | Data \| Descrição \| Valor \| Status \| Mês Ref. — com blocos por mês e totais; datas em `DD/MM/YYYY`, "Mês Ref." como datetime com hora `00:00:00` |
| `despesas_a_esclarecer.xlsx` | 1 (35 linhas) | 13 colunas: Data, Fornecedor, CNPJ/CPF, NF, Documento, Descricao, Valor, Conta Original, Classificacao Atual, Classificacao Sugerida, Houve Estorno?, Observacao, Fonte |
| `gastos_piscina_detalhado.xlsx` | 3 | Detalhado (46 linhas, 13 col.) + Resumo por Fornecedor (8) + Evolução Mensal |
| `material_limpeza_detalhado.xlsx` | 1 (39 linhas) | 9 colunas, coluna "Classificacao" com valores "A VERIFICAR"/"Classificacao correta" |
| `compra_agua_detalhado.xlsx` | 2 | "Compra de Agua" (NF, Data Lancamento, Competencia, Fornecedor, Rubrica, Valor) + "Comparativo Mensal" |
| `lancamentos_hidraulica.xlsx` | 1 (36 linhas) | Data \| NF \| Descrição \| Fornecedor \| Valor \| Parcela \| Categoria, com subtotais por NF |
| `lancamentos_hidraulica.xlsx` | 1 (25 linhas) | NF \| Data \| Descrição \| Valor \| Competência — competência em `abr/25`, `mai/25`, `jun/2025` (formato misto) |
| `lancamentos_pintura.xlsx` | 1 (101 linhas) | NF \| Data \| Serviço \| Valor NF \| ISS (5%) \| Total Líquido, com blocos mensais |
| `agua_gas_por_unidade.xlsx` | 3 | "AGUA por Unidade" e "GAS por Unidade": 72 unidades × 18 meses + Total + Média |
| `leituras_agua_gas.xlsx` | 3 | Leituras de água (Concessionaria Agua) e gás (Concessionaria Gas) com 3 blocos de 2026-10 e comparativo |
| `relatorio_energia.xlsx` | 3 | Contas Concessionaria Energia por período, com marcação "Gestao anterior"/"Gestao atual" |
| `comparativo_energia.xlsx` | 2 | Comparativo de energia entre gestões |
| `controle_pintura_orcamento.xlsx` | 3 | Orçamento/executado de 2 obras (Fase 2, mas com pagamentos que **também estão no extrato**) |

### 3.6 CSVs de saída relevantes (fontes secundárias, já tratadas)

| Arquivo | Linhas | Observação |
|---|---|---|
| `extrato_consolidado.csv` | 11.439 | **Extrato consolidado de 18 competências (2025-05 a 2026-10)**, 18 colunas, com `arquivo_origem`, `competencia`, `categoria`, `unidade`, `data_documento` |
| `lancamentos_normalizados.csv` | 672 | Uma competência (2026-05) já normalizada, 14 colunas, com `arquivo_origem` + `linha_origem` |
| `conciliacao.csv` | 499 | Extrato × planilha-resumo: 306 `apenas_no_extrato`, 184 `apenas_na_planilha`, 9 `divergente` |
| `balancete_resumo_financeiro.csv` / `balancete_status_conciliacao.csv` | 14 cada | 14 competências (2025-07 a 2026-08), todas marcadas `DIVERGENTE` |
| `contas_nao_mapeadas.csv` | 286 | Agregado por competência/conta: 55 códigos de conta sem categoria |
| `caixa_local_conciliado.csv` / `caixa_local_sem_match.csv` | 68 / 7 | Conciliação do caixa local por valor+data; 7 despesas sem par no extrato |
| `itens_duplicados_unidade.csv` | 1 | Sinalização de duplicidade (unidade 42, salão de festas, 09/2025) |
| `unidades_inadimplentes_presumidas.csv` | 14 | Inadimplência **presumida** (por ausência), não confirmada |
| `auditoria_espelho_unidade.csv` | 9.684 | Detalhamento por unidade com flags de duplicidade/suspeita |
| `investigacao_alertas.csv` | 1.174 | Alertas por gravidade/tipo |
| `valores_discrepantes_unidade.csv` | 646 | Comparação de cada valor contra a mediana histórica da unidade |
| `espelho_boleto.csv` / `espelho_boleto_consolidado.csv` | 24.079 / 1.229 | Esperado × pago por unidade e competência |
| `data\manual_validations.csv` | 5 | Ver QUALIDADE_DADOS.md, item 7.5 |

---

## 4. O que os scripts e o "banco" faziam

Não há banco de dados. Todo o "esquema" está em `src\models.py` (dataclasses) e no `config\mapa_contas.yaml`:

| Módulo | Responsabilidade |
|---|---|
| `parser_extrato.py` | Lê `.xls` (xlrd), detecta o período no cabeçalho, classifica cada linha por código de conta, extrai unidade/vencimento/referência do texto do histórico, monta o bloco RESUMO (4 totais) |
| `parser_planilha.py` | Lê só a aba `resumo do saldo` da planilha-resumo |
| `parsers\pdf_balancete_parser.py` | Extrai do balancete: composição de arrecadação, receitas/despesas ordinárias e extraordinárias, resumo de inadimplência, cotas em aberto, quadro do resumo financeiro, saldo de caixa local e saldos bancários — tudo por regex sobre o texto (sem OCR) |
| `parsers\pdf_despesas_locais_parser.py` | Extrai a conta de despesas locais da página 1 e tenta casar comprovantes (fornecedor/CNPJ/NF) das páginas seguintes por valor |
| `normalizacao.py` | Consolida resumos, separa recebíveis por unidade e categoria, gera resumo mensal por categoria |
| `conciliacao.py` | Compara extrato × planilha por competência e categoria, classificando em `conciliado`/`divergente`/`apenas_no_extrato`/`apenas_na_planilha` |
| `services\extrato_consolidator.py` | Reagrupa extratos por 6 "categorias de resumo" reproduzindo o balancete da administradora, carregando saldo de um mês para o outro a partir de `SALDOS_INICIAIS_RESUMO` fixos (balancete de 2025-05) |
| `services\balancete_matcher.py` | Concilia balancete × extrato (por linha do resumo financeiro e por categoria de receita/despesa) |
| `services\caixa_local_matcher.py` | Concilia o PDF de despesas locais com o extrato (por valor + data) e classifica subcategoria |
| `services\espelho_boleto.py` | Monta o espelho de boleto por unidade (esperado × pago), com classificação de competência e flags de duplicidade |
| `services\file_indexer.py` / `file_renamer.py` | Indexam e renomeiam arquivos por conteúdo, com **dedup por MD5**; o log mostra que a última varredura ignorou tudo |
| `services\unidade_classifier.py` / `unidade_validator.py` | Classifica as 72 unidades e valida os números detectados |
| `services\manual_validation.py` | Aplica correções manuais de `data\manual_validations.csv` (id = MD5 de 12 chars de competência\|unidade\|conta\|data) |
| `services\auditoria_investigativa.py` | Painel de alertas (consumo, reembolsáveis, variação de despesa, ranking de unidades) |
| `services\competencia_detector.py` | Detecta a competência por "COMPETÊNCIA:" ou pelo período no cabeçalho |
| `src\main.py` | CLI: modo único (`--extrato`) ou lote (`--input-dir`) |
| `src\utils.py` | Regras de parsing (`parse_unidade`, `parse_vencimento`, `parse_valor_bruto`, `parse_competencia_*`) e um "schema defensivo" (`ensure_columns`, `ensure_schema`) com log de auditoria de colunas |

**Regras de parsing que precisam ser preservadas na migração** (documentadas em `AGENTS.md` e validadas por 29 testes):
- Unidade só é reconhecida por padrão explícito (`RC.UN.######`, `UN.######`, `UNID. ######`, `DECOB ######`) — **nunca** número solto.
- Valor em formato BR (`158.380,00`) é tratado por `parse_valor_bruto`.
- Competência vem do cabeçalho "Período", no formato interno `YYYY-MM`.
- Vencimento vem do histórico, sempre com 2 dígitos de ano (`%d/%m/%y`).
- CSV de saída sempre em `utf-8-sig` (BOM) para abrir no Excel em pt-BR.

---

## 5. Resumo do que a Fase 0 + contabilidade vai precisar importar

| Fonte | Período | Formato | Volume |
|---|---|---|---|
| Extratos bancários | 2023-07 a 2026-10 (30 meses; **falta 2024-07 a 2025-04**) | `.xls` (3 layouts) + 1 `.xlsx` | ~15.000 lançamentos |
| Balancetes da administradora | 2025-01, 2025-05 a 2026-10 (19 meses; **faltam 2025-02 a 2025-04**) | PDF | 19 arquivos |
| Conta de despesas locais (caixa local) | 2025-05 a 2026-10 (18 meses) | PDF | 18 arquivos |
| Planilha-resumo | 05/2020 a 10/2026 (78 meses, sem lacunas) | XLSX, 1 aba | 78 blocos |
| Rubricas/plano de contas | — | YAML | 41 códigos + 12 regras por texto + 17 mapeamentos de planilha |
| Unidades | — | YAML | 72 |
| Notas fiscais | 2 (2026) | PDF | 2 arquivos |
| Faturas de concessionária | água/gás/luz | PDF/XLSX | consumo por unidade — fora do escopo contábil desta fase |

**Volume total de lançamentos na base atual:** 11.439 no consolidado (18 competências). Extrapolando para 30 competências de extrato: **~19.000 lançamentos**, mais ~2.000 de caixa local.
