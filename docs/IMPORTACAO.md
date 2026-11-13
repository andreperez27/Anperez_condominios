# Proposta de importação — ANPEREZ CONDOMÍNIOS

**Data:** 11/11/2026
**Status:** proposta — nenhum script de importação foi escrito, nada foi instalado, nenhuma linha foi gravada em banco.
**Bases:** `docs\INVENTARIO_DADOS.md`, `docs\QUALIDADE_DADOS.md`, `docs\MODELO_DADOS.md`, decisões D7 (escopo), D8 (transferências internas), D10 (revisão humana obrigatória).

---

## 1. Princípios

| # | Princípio |
|---|---|
| I1 | **Nada vai para o banco sem sua aprovação.** O importador escreve em `staging_*`; só a RPC de aprovação move para `lancamentos`. |
| I2 | **Importação idempotente.** Reimportar o mesmo arquivo não muda nada; reimportar arquivo re-exportado acrescenta só o que é novo e atualiza o que mudou. |
| I3 | **O importador é guiado por layout**, não por tentativa-e-erro. A detecção é explícita e gravada. |
| I4 | **Toda linha carrega sua origem**: arquivo, hash, aba/página, linha, e o texto original. |
| I5 | **O importador nunca classifica por conta própria.** Ele *sugere* rubrica, fundo, unidade e transferência; a decisão é humana. |
| I6 | **O importador nunca descarta.** Duplicatas viram candidatas e entram na fila. |
| I7 | **Nenhum dado sai do computador.** Parsing local, banco do próprio projeto, sem serviço externo. |
| I8 | **Nada é executado sobre a pasta antiga.** O importador lê de uma pasta de trabalho, nunca escreve nela. |

---

## 2. Visão geral do fluxo

```
        ┌──────────────────────────────────────────────────────────────┐
        │ 1. DESCOBERTA        pasta de dados de origem (ignorada)    │
        │    • varre arquivos                                      │
        │    • calcula SHA-256                                     │
        │    • detecta layout pelo cabeçalho/conteúdo             │
        │    • detecta competência                                │
        │    • registra em fontes_importacao (idempotente)         │
        └───────────────┬──────────────────────────────────────────┘
                        │
        ┌───────────────▼──────────────────────────────────────────┐
        │ 2. PARSING           parser por layout (isolado)          │
        │    • extrato_v1 / v2 / v3 / xlsx_v1                      │
        │    • balancete_v1 (PDF, 3 seções)                        │
        │    • caixa_local_v1 (PDF, pág.1 = conta)                 │
        │    • planilha_resumo_v1 (série histórica)                │
        │    → devolve "linhas brutas" com nº da linha/página       │
        └───────────────┬──────────────────────────────────────────┘
                        │
        ┌───────────────▼──────────────────────────────────────────┐
        │ 3. NORMALIZAÇÃO   (determinístico, sem decisão)           │
        │    • data BR → date;  valor BR → numeric                │
        │    • competência canônica YYYY-MM                        │
        │    • chave_natural = SHA-256(tupla + '#' + occurrence)   │
        │    • occurrence = nº da linha idêntica no arquivo        │
        │    • sugere: rubrica, fundo, unidade, transferência       │
        │    • detecta: duplicatas candidatas                       │
        └───────────────┬──────────────────────────────────────────┘
                        │
        ┌───────────────▼──────────────────────────────────────────┐
        │ 4. STAGING      escrita em staging_* (idempotente)       │
        │    • unique (importacao_id, chave_natural)               │
        │    • unique (fonte_id, linha_origem, occurrence)       │
        │    • status: novo | duplicado_candidato | conflito | erro │
        └───────────────┬──────────────────────────────────────────┘
                        │
        ┌───────────────▼──────────────────────────────────────────┐
        │ 5. CONFERÊNCIA   painel web (auditor)                     │
        │    • por arquivo e por competência                       │
        │    • texto original x linha entendida                     │
        │    • totais do arquivo x bloco RESUMO do próprio extrato  │
        │    • pendências geradas                                  │
        └───────────────┬──────────────────────────────────────────┘
                        │
        ┌───────────────▼──────────────────────────────────────────┐
        │ 6. APROVAÇÃO      RPC atômica (SECURITY DEFINER)         │
        │    fn_aprovar_staging(...)                               │
        │    • grava lancamentos + rubricas + transferências        │
        │    • grava duplicatas candidatas + pendências             │
        │    • tudo em UMA transação                              │
        │    • audita quem, quando, o quê                          │
        └───────────────┬──────────────────────────────────────────┘
                        │
        ┌───────────────▼──────────────────────────────────────────┐
        │ 7. CONCILIAÇÃO   fn_reconciliar_competencia(...)          │
        │    extrato x balancete POR FUNDO E POR COMPETÊNCIA        │
        │    → atualiza status_competencia                         │
        └──────────────────────────────────────────────────────────┘
```

---

## 3. Etapa 1 — Descoberta

### 3.1 Pasta de trabalho

O importador lê de `dados_origem/` (ignorada pelo Git) — **nunca** de `C:\Users\andre\Desktop\condominio`. A cópia é feita por você (ou por um script de cópia explícito), e a pasta antiga é tratada como **somente leitura**.

Proposta: um script `scripts/copiar_origem.py` que **copia** (nunca move) os arquivos escolhidos da pasta antiga para `dados_origem/`, com log do que copiou (nome, hash, tamanho). Isso dá um ponto de partida sem risco para a origem.

### 3.2 Detecção de layout

Cada layout tem um detector com nome, versão e regra de reconhecimento. A detecção é feita **pelo conteúdo**, não pela extensão.

| Layout | Sinais de detecção | Arquivos na base |
|---|---|---|
| `extrato_v1` | `.xls`, 5 colunas, linha 3 = `Conta \| Data \| Histórico \| Débito \| Crédito`, coluna 0 com **código puro** (`1001`) | 12 (2023-07 a 2024-06) — **fora do escopo (D7)** |
| `extrato_v2` | `.xls`, 5 colunas, linha 3 = `Conta \| Data \| Histórico \| Débito \| Crédito`, coluna 0 com `código - DESCRIÇÃO` | 11 (2025-07 a 2026-05) |
| `extrato_v3` | `.xls`, 6 colunas, linha 3 = `Conta \| Descrição Conta \| Data \| Histórico \| Débito \| Crédito` | 7 (2025-05, 2025-06, 2026-06 a 2026-10) |
| `extrato_xlsx_v1` | `.xlsx`, aba `contaCorrente`, 5 colunas, linha 1 = `Conta Corrente` | 1 (extrato_2025-01.xlsx) — **fora do escopo (D7)** |
| `balancete_v1` | PDF, página 1 contém `Balancete Mensal` e `CONDOMINIO EXEMPLO` | 19 |
| `caixa_local_v1` | PDF, página 1 contém `Conta Despesas Locais` | 18 |
| `planilha_resumo_v1` | `.xlsx`, aba `resumo do saldo`, células `Saldo referente ao mês MM/AAAA` | 1 |
| `leitura_agua_v1` | `.xlsx`, cabeçalho `MES_REF \| BLOCO \| APTO \| HIDROMETRO` | 1 — fora do escopo contábil |
| `leitura_gas_v1` | `.xlsx`, aba `ExtratoIndividualizadoSemAjuste` | 2 — fora do escopo contábil |

⚠️ **Armadilha registrada:** `extrato_2025-01.xlsx` tem **extensão `.xlsx` e conteúdo de extrato**. Qualquer detecção baseada em extensão classifica como planilha — foi exatamente o que aconteceu no app antigo. A regra de detecção de `planilha_resumo_v1` exige a aba `resumo do saldo` **e** a presença de células `Saldo referente ao mês`; se não encontrar, o arquivo é classificado como "desconhecido" e vai para pendência, não para a planilha.

### 3.3 Detecção de competência

Por ordem de preferência:
1. Célula `Período | DE: dd/mm/aaaa | ATÉ: dd/mm/aaaa` no extrato → competência = mês de `ATÉ`.
2. `COMPETÊNCIA: mm/aaaa` em qualquer célula.
3. Nome do arquivo `..._YYYY-MM...`.
4. `Período dd/mm/aaaa até dd/mm/aaaa` no PDF (balancete e caixa local).

A competência detectada **não é aplicada automaticamente**: fica gravada na fonte e pode ser **corrigida na conferência** antes da aprovação. Isso importa porque o balancete de 2026-04 e o extrato de 2026-04 têm a mesma competência, mas o balancete vai de 01/04 a 30/04 enquanto o extrato do mesmo período vai até 30/04/2026 — e há casos em que a administradora manda o extrato com período desplazado (o log de renomeação do app antigo mostra `periodo_inicio 01/07/2025, periodo_fim 10/07/2025` para o extrato de 2025-07 — **período errado no arquivo original**!).

Esse caso concreto merece registro: o arquivo `extrato_2025-07.xls` declara `ATÉ: 31/07/2025` no cabeçalho, mas o log de renomeação antigo gravou `10/07/2025`. O novo importador lê o cabeçalho do arquivo, sempre, e **mostra** a competência detectada na conferência para você confirmar.

### 3.4 Idempotência de arquivo

```sql
unique (condominio_id, hash_sha256, layout)
```
- Arquivo com hash já cadastrado → `status = 'ignorado_duplicata'`, uma linha no log, nada mais acontece.
- Arquivo re-exportado (hash diferente, mesmo conteúdo lógico) → fonte nova; as linhas repetidas são reconhecidas pela tupla semântica e marcadas como `duplicado_candidato` **na conferência**, não como erro.

---

## 4. Etapa 2 — Parsing (um parser por layout)

### 4.1 Regra de ouro

> **Nenhum parser decide o que a linha significa.** Ele extrai o que está escrito, com o número da linha, e para. Classificar é etapa seguinte.

Cada parser devolve uma lista de "linhas brutas" com esta forma:

```python
@dataclass
class LinhaBruta:
    linha_origem: int          # nº da linha na planilha / página no PDF
    texto_origem: str          # a linha inteira, como está no arquivo
    colunas: dict[str, str]    # colunas já separadas, em texto
    pagina: int | None = None  # PDF
    aba: str | None = None     # planilha
```

### 4.2 Parser de extrato

Um parser, três variantes de coluna, porque **a diferença é só de onde fica cada campo**:

```python
LAYOUTS_EXTRATO = {
    "extrato_v1": dict(  # 2023-07 a 2024-06 — fora do escopo
        cols=5, data=1, historico=2, debito=3, credito=4,
        conta="col0_codigo", descricao=None,
    ),
    "extrato_v2": dict(  # "1001 - CONDOMINOS EM ATRASO" na col 0
        cols=5, data=1, historico=2, debito=3, credito=4,
        conta="col0_codigo_mais_descricao",
    ),
    "extrato_v3": dict(  # 6 colunas
        cols=6, data=2, historico=3, debito=4, credito=5,
        conta="col0_codigo", descricao="col1",
    ),
}
```

Cada layout tem:
- **Leitura da cabeça**: linhas 1–3 (título, período, cabeçalho). Validar o cabeçalho contra o esperado do layout; se não bater, o arquivo é classificado como **layout desconhecido** e vira pendência (não é processado às cegas).
- **Detecção do bloco RESUMO**: a linha `RESUMO - CONDOMINIO EXEMPLO` e as 4 linhas seguintes (`SALDO INICIAL`, `DÉBITO TOTAL`, `CRÉDITO TOTAL`, `SALDO FINAL`). Essas 4 linhas são lidas como **texto BR** (são texto!) e gravadas separadamente, **não** como lançamentos.
- **Linhas de lançamento**: tudo entre a linha 4 e o RESUMO, onde a coluna 0 casa o padrão de conta.
- **Linha em branco** antes do RESUMO é ignorada sem erro.

#### As 4 armadilhas do extrato, e como cada uma é tratada

| # | Armadilha | Tratamento no novo parser |
|---|---|---|
| A1 | **Layout v1 lido errado** (o bug do app antigo: data vira histórico, crédito vira débito, unidade não extraída) | Cada layout tem seu próprio mapa de colunas, **testado com fixture real**. O parser v1 fica fora do escopo (D7), mas o detector continua existindo — se um arquivo v1 aparecer, ele é detectado e **vira pendência**, não é processado errado em silêncio |
| A2 | **4 linhas de total em texto BR** (`56.870,00`) enquanto o corpo é numérico | Conversão por **tipo do valor da célula**, não por coluna: se a célula é `str`, aplica `parse_valor_bruto`; se é número, usa direto. O bloco RESUMO é lido antes de qualquer agregação |
| A3 | **Datas em `DD/MM/YY`** no vencimento dentro do histórico | `parse_vencimento` com `DD/MM/YY` → century explícito: anos de 2 dígitos são resolvidos pela janela da competência (2020–2049 → 20xx). Nunca `datetime.strptime` com `%y` puro, que tem o bug do "62" virar 2062 |
| A4 | **Mesmo valor + mesmo histórico em arquivos/competências diferentes** | A chave natural inclui documento, tipo e valor → linhas diferentes **não** colidem. A colisão real (mesma linha repetida) é reconhecida e vira **candidata a duplicata**, não exclusão |

#### Verificação obrigatória por arquivo (auto-teste do parser)

Antes de escrever qualquer linha em staging, o parser compara:

```
soma(créditos do corpo)  vs  "CRÉDITO TOTAL" do RESUMO
soma(débitos do corpo)   vs  "DÉBITO TOTAL"  do RESUMO
saldo_inicial + créditos - débitos  vs  "SALDO FINAL" do RESUMO
```

Se não bater (tolerância R$ 0,01), o arquivo é **bloqueado** e vira pendência `divergencia` — com o número da diferença. Isso é o que impede que um erro de leitura entre no banco silenciosamente. É o teste que teria pegado o bug do layout v1.

**Resultado esperado hoje (verificado na análise):** os 18 extratos em escopo fecham **exatamente** contra o próprio bloco RESUMO. Confirmado: 2025-05 creditos 101.950,00 / débitos 97.650,00 / saldo final 61.170,00 — batendo com o extrato.

### 4.3 Parser de balancete (PDF)

Extrai as 8 seções em ordem fixa:
1. `COMPOSIÇÃO DE ARRECADAÇÃO` (12 linhas + TOTAL)
2. `RESUMO DE ACORDOS`
3. `COMPOSIÇÃO RECEITAS ORDINÁRIAS` (13 linhas + TOTAL)
4. `COMPOSIÇÃO DESPESAS ORDINÁRIA` (quebra entre páginas 1 e 2 — **continuidade de seção entre páginas**)
5. `RECEBIMENTO DE CONTAS EXTRAORDINÁRIAS`
6. `DESPESAS DE CONTAS EXTRAORDINÁRIAS`
7. `RESUMO DE INADIMPLÊNCIA` + `RESUMO COTAS EM ABERTO`
8. `RESUMO FINANCEIRO` (o quadro por fundo, que é a base da conciliação)

Pontos de atenção:
- **A seção de despesas atravessa a quebra de página.** O parser precisa manter o "modo" (seção atual) entre as páginas — o app antigo já fazia isso, e a continuidade precisa ser testada.
- **Valores em texto BR com sinal negativo** (`-34.800,00`) → o sinal é preservado no texto original; a conversão para numérico vem na normalização.
- **Rótulos com acentuação variável**: `ANTECIPACOES` vs `ANTECIPAÇÕES`, `SALÃO` vs `SALAO`. A normalização de rótulo (sem acento, caixa alta, espaços colapsados) é feita na **etapa 3**, e o resultado é guardado como `alias_normalizado` **junto do texto original** — para a auditoria, o texto cru continua disponível.
- **`RESUMO COTAS EM ABERTO`** traz a unidade com **6 dígitos** (`000011`, `000013`, `000133`) — normaliza para `11`, `13`, `133` com a mesma regra do extrato.

### 4.4 Parser de caixa local (PDF com comprovantes escaneados)

- **Página 1**: a conta (`Data | Histórico | Débito | Crédito`, `Saldo Anterior`, lançamentos, total, `Saldo da Conta Despesas Locais`).
- **Páginas 2+**: **comprovantes escaneados** (imagens). O parser:
  1. extrai a página como imagem e grava como **anexo** (bucket privado), com `status = 'sugerido'`;
  2. tenta extrair fornecedor / CNPJ / número de NF / valor por regex sobre o texto renderizado;
  3. **sugere** a vinculação do anexo com o lançamento de mesmo valor (tolerância R$ 0,50, como no app antigo).

  ⚠️ A extração por regex sobre página escaneada é frágil: **62 das 68 linhas** conciliadas no app antigo ficaram com fornecedor/CNPJ/NF **vazios**. O parser novo registra o que conseguiu ler, marca o resto como pendência `documento_faltante`, e **nunca inventa** fornecedor nem CNPJ.

- **Natureza dupla das linhas**: a despesa ("COMPRA DE...") e a remessa ao caixa ("REMESSA DE NUMERARIO P/ DESPESAS LOCAIS", crédito). O saldo da conta local fecha em 0 ao final do mês — é um fundo de giro, e isso precisa estar explícito na rubrica (CAIXA_LOCAL) para a conciliação.

- **Truncamento de texto**: o PDF corta a descrição ("COMPRA DE CAFÉ, AÇÚCAR PARA O CONDOMÍNIOE 02"). O `texto_origem` guarda o que veio; a pendência registra o corte.

### 4.5 Parser da planilha-resumo (série histórica)

Lê os 78 blocos e gera **linhas de série histórica**, não lançamentos:
- Reconhece o cabeçalho do bloco (`DESCRIÇÃO | SALDO ANT. | CRÉDITOS | DÉBITOS | SALDO` ou `DESCRIÇÃO | SALDO ANT. | Aporte | Juros | SALDO`).
- Distingue o bloco `APLICAÇÃO BANCO EXEMPLO` (outro tipo: aporte/juros) e grava com `bloco = 'aplicacao_btg'`.
- Grava a **linha de origem** de cada rubrica.
- As **21 linhas de anotação** das colunas H/I/J (caderno à mão: "TOTAL FUNDO RESERVA", "desc. IRRF", "gasto 4800.00") **não** viram rubrica: vão para `serie_historica_anotacoes` com o texto e a linha de origem, e viram pendência do tipo `classificacao_sugerida`.
- 18 blocos (a partir de 07/2025) têm `SALDO FINAL` sem CRÉDITOS/DÉBITOS → gravados com esses dois campos nulos e **pendência** `divergencia` do tipo "fonte incompleta", para não parecer que o mês fecharia sem movimento.

---

## 5. Etapa 3 — Normalização

Determinística e testável. Cada regra tem um teste com o caso real.

| Regra | Entrada real | Saída |
|---|---|---|
| Data BR → `date` | `02/10/2026` | `2026-10-02` |
| Vencimento `DD/MM/YY` | `VC.10/10/26` | `2026-10-10` (janela 2020–2049 explícita) |
| Valor BR (texto) | `56.870,00` | `56870.00` |
| Valor numérico | `1750.00` | `1750.00` |
| Competência | `ATÉ: 31/10/2026` | `2026-10` |
| Unidade | `RC.UN.000012` | `33` (texto, sem zeros à esquerda) |
| Unidade (acordo) | `RC.DECOB 000061` | `61` |
| Unidade (isenção) | `VALOR REF.ISENCAO UNID. 000162` | `162` |
| Documento | `RB.00000015` | `53708659` |
| Referência | `RC.00000013` / `CB.00000016` | idem |
| Rótulo normalizado | `ANTECIPAÇÕES` / `SALÃO DE FESTAS` | `ANTECIPACOES` / `SALAO DE FESTAS` |

⚠️ **Unidade nunca por número solto.** As regras aceitam apenas padrões explícitos (`RC.UN.######`, `UN.######`, `UNID. ######`, `DECOB ######`, `ANTEC.UN.######`). Um "14" solto no texto **não** vira unidade — é regra herdada e testada do app antigo, e vale mantê-la.

⚠️ **Sem "número solto", mas com lista de unidades known.** Quando o padrão é explícito mas a unidade não existe em `unidades` (por exemplo, uma unidade removida do catálogo como 118, 130, 140, 145, 179), o lançamento é gravado com `unidade_id = NULL` e o **número original** guardado em `referencia_extraida`, e vira pendência `classificacao` do tipo "unidade desconhecida". Nunca se descarta a linha.

### 5.1 Sugestão de rubrica e fundo

Ordem de decisão (toda sugestão é marcada `sugerida`):
1. `contas_origem` do condomínio, se existir, com `rubrica_id` preenchido → sugestão direta.
2. `rubrica_aliases` por `fonte` + `alias` (+ `contexto`) → sugestão por rótulo.
3. Regra por palavra-chave no histórico (as 12 regras do `mapa_contas.yaml`) → sugestão com `confianca` menor.
4. Nada → **sem rubrica** + pendência `classificacao`.

A **fonte de verdade do fundo** é `contas_origem.fundo_id` (mapeamento explícito por código). O prefixo do código é só **fallback** para códigos novos, e com a ambiguidade `1`/`10`/`15`/`19` — por isso o fallback nunca substitui o mapeamento explícito.

### 5.2 Sugestão de transferência interna (sempre `sugerida`)

Ordem (nunca automática):
1. **Palavra-chave no histórico**: `TRANSFERENCIA`, `TRANSF.`, `APLICACAO`, `REPOSICAO`, `REMESSA DE NUMERARIO`, `TRANSFERENCIA DA CONTA APLICACAO`.
2. **Fundos diferentes + mesmo valor + mesma competência**.
3. **Contas de transferência** (`1041`, `1820`, `1821`).

O resultado é sempre `status = 'sugerida'` e vive em `staging_transacoes` até a conferência. Nada entra em `transferencias_internas` como `confirmada` sem ação humana. E, como definido em MODELO_DADOS §9.3, **mesmo que a sugestão exista e esteja errada, o consolidado não subtrai nada** — o padrão é `v_resultado_bruto`.

⚠️ **Caso Fornecedor Exemplo, para o parser não errar:** em 2026-05, `ISS NF-218 FORNECEDOR EXEMPLO` aparece como **crédito** em 3003 (FUNDO DE RESERVA) e como **débito** em 15501 (PINTURA) — mesmo valor (170,00), mesma NF. Isso **parece** transferência entre fundos, mas é reclassificação da mesma NF, e a competência também não bate (o crédito é de 05/05, o débito de 25/05). Por isso a regra de valor exige **mesma competência** e **ambos os lados classificados como transferência** (palavra-chave presente). Um ISS não tem palavra-chave de transferência → não vira sugestão. Esse caso vira **pendência** para você decidir.

### 5.3 Detecção de duplicatas candidatas

Gera pares, **sem excluir nada**. O número da ocorrência (calculado no parse) é o que permite que duas linhas **idênticas** no mesmo arquivo sejam **inseridas as duas** e ainda assim sinalizadas.

Critérios:

| Critério | O que casa | Quando acontece |
|---|---|---|
| `mesma_tupla_no_arquivo` | mesma tupla semântica (competência, conta, data, documento, tipo, valor, histórico normalizado) | a mesma linha repetida no arquivo (unidade 42 em 2025-09, `REPOSICAO DE CAIXA LOCAL` 1.250,00 em 2026-04, `COR.MON.DECOB 000032` 0,09) |
| `mesmo_documento` | mesmo `RB.`/`RC.`/`CB.` em linhas diferentes | o mesmo recibo lançado em duas linhas |
| `mesmo_valor_data_conta` | mesmo valor, mesma data, mesma conta, **documentos diferentes** | a categoria que exige cuidado: dois pagamentos iguais no mesmo dia podem ser legítimos (regra sua, requisito 4) |

**Como o número da ocorrência entra na chave (e por que isso resolve o problema):**

```
durante o parse do arquivo, em ordem de linha:
    para cada linha:
        tupla = hash(campos semânticos)
        numero_ocorrencia = quantas vezes essa tupla já apareceu antes NESTE arquivo
        chave_natural = sha256(tupla + '#' + numero_ocorrencia)
```

| Situação | Resultado |
|---|---|
| Duas linhas idênticas no mesmo arquivo | occurrence 1 e 2 → **chaves diferentes** → as duas entram, e o par vira candidata `mesma_tupla_no_arquivo` |
| Reimportação do mesmo arquivo | mesmas occurrences → mesmas chaves → `ON CONFLICT` atualiza, nada entra |
| Reexportação que remove a duplicata | a occurrence 1 continua sendo a occurrence 1 → não nasce chave nova |
| Dois pagamentos iguais no mesmo dia, documentos diferentes | tuplas **diferentes** → occurrence 1 e 1 → fatos distintos, e **não** viram duplicatas |

Cada par vai para `staging_duplicatas` e, após a aprovação, para `duplicatas_candidatas` com `status = 'pendente'`.

**Regra de detecção no importador:** a comparação de duplicatas usa a **tupla semântica** (sem a occurrence), nunca a `chave_natural`. Se usasse a `chave_natural`, as duas linhas idênticas teriam chaves diferentes e jamais seriam detectadas como duplicatas.

## 6. Etapa 4 — Staging (escrita idempotente)

```sql
create table public.staging_lancamentos (
  ...
  numero_ocorrencia  int not null default 1   -- nº da ocorrência da linha idêntica dentro do arquivo
  unique (importacao_id, chave_natural)
  unique (importacao_id, fonte_id, linha_origem, numero_ocorrencia)
);
```
- `ON CONFLICT (importacao_id, chave_natural) DO UPDATE` → reexecutar o mesmo arquivo **atualiza** a linha de staging em vez de duplicar.
- O `numero_ocorrencia` é calculado **durante o parse**, varrendo o arquivo em ordem e contando quantas vezes a mesma tupla já apareceu. É determinístico: reimportar o mesmo arquivo reproduz os mesmos números.
- O `importacao_id` é novo a cada execução, então a idempotência entre execuções vem da **chave natural** (tupla + occurrence) + do `unique (condominio_id, chave_natural)` de `lancamentos`.
- Como a occurrence é a posição da linha idêntica **dentro do arquivo**, a reimportação do mesmo arquivo reproduz as mesmas chaves. E uma reexportação que remova uma linha duplicada não cria chave nova: a occurrence 1 continua sendo a occurrence 1.
- Cada linha guarda `importacao_id`, `fonte_id`, `linha_origem`, `aba`, `pagina`, `texto_origem` — a rastreabilidade já existe no staging, antes da aprovação.

**Erros de parse** não abortam o arquivo: a linha entra com `status = 'erro_parse'`, mensagem descritiva, e o arquivo continua. O que aborta o arquivo é apenas a **falha da verificação de fechamento** contra o bloco RESUMO (§4.2).

---

## 7. Etapa 5 — Conferência (o painel)

Uma tela por arquivo, com:

### 7.1 Resumo do arquivo
```
extrato_2026-10.xls
  SHA-256: 9f2c…  ·  778 linhas  ·  layout extrato_v3  ·  competência 2026-10
  ✓ fechamento: créditos 208.250,00 = RESUMO 208.250,00
  ✓ fechamento: débitos 254.340,00 = RESUMO 254.340,00
  ✓ saldo: 195.850,00 + 208.250,00 − 254.340,00 = 149.760,00 = RESUMO
  768 novas  ·  2 duplicatas candidatas  ·  8 sem rubrica  ·  0 erros de parse
  [aprovar tudo]  [aprovar selecionadas]  [rejeitar]  [corrigir competência]
```

### 7.2 Conferência linha a linha
| Coluna | Conteúdo |
|---|---|
| origem | arquivo · linha 785 · coluna 6 |
| texto original | `254.340,00` (mostrado como no arquivo) |
| entendido | `Débito TOTAL` do bloco RESUMO → **não é lançamento** (exibido como total, não como linha) |
| rubrica sugerida | `—` + motivo |
| unidade | `—` |
| ação | aprovar / corrigir / rejeitar |

### 7.3 Ações disponíveis na conferência
- **Aprovar** linha, seleção ou arquivo inteiro.
- **Corrigir** a competência (quando o cabeçalho do arquivo está errado).
- **Corrigir** a rubrica e o fundo sugeridos (grava `contas_origem` se for um código novo; se for caso isolado, grava `lancamento_rubrica` como `confirmada`).
- **Corrigir** a unidade detectada.
- **Rejeitar** com motivo → gera pendência.
- **Marcar transferência interna** entre duas linhas (vinculando as duas pontas por `grupo_ref`).
- **Aceitar ou recusar** as duplicatas candidatas.
- **Reprocessar** com um layout diferente (quando a detecção errou).

Cada ação gera registro em `auditoria_log` com quem, quando e o antes/depois.

---

## 8. Etapa 6 — Aprovação (RPC atômica)

Uma única função faz tudo, em uma transação:

```sql
create or replace function public.fn_aprovar_staging(
    p_importacao_id uuid,
    p_staging_ids   uuid[],
    p_decisoes      jsonb default '{}'::jsonb
)
returns table (
    lancamentos_criados int,
    lancamentos_atualizados int,
    duplicatas_criadas int,
    pendencias_criadas int,
    transferencias_criadas int
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
...
begin
    if not (('auditor') = any(public.fn_papeis_do_usuario())) then
        raise exception 'papel insuficiente: apenas auditor pode aprovar importação';
    end if;

    -- 1. trava a importação para evitar aprovação concorrente
    perform 1 from public.importacoes
     where id = p_importacao_id and status = 'em_andamento'
       for update;

    -- 2. insere/atualiza lançamentos (idempotente pela chave natural)
    insert into public.lancamentos (...)
    select ... from public.staging_lancamentos s
     where s.importacao_id = p_importacao_id
       and s.id = any(p_staging_ids)
       and s.status <> 'erro_parse'
    on conflict (condominio_id, chave_natural)
    do update set ...;

    -- 3. grava a rubrica (sugerida ou confirmada) em lancamento_rubrica
    -- 4. cria grupos_transferencia + transferencias_internas (status 'confirmada' só das decisões explícitas)
    -- 5. cria duplicatas_candidatas
    -- 6. cria pendências
    -- 7. atualiza status_competencia para 'importado'
    -- 8. grava auditoria_log de cada linha aprovada
end;
$$;
```

**Por que uma RPC e não uma sequência de inserts:** se algo falhar no meio (uma linha com FK inválida, um conflito de chave), a transação inteira desfaz — não fica metade importada. Esse é o padrão do Anperez Money (RPCs atômicas para operações compostas) e é o que mantém a contabilidade confiável.

**Idempotência da aprovação:** chamar a RPC duas vezes com a mesma lista não duplica nada — o `ON CONFLICT` na chave natural resolve, e o `auditoria_log` registra a segunda chamada como "sem efeito".

---

## 9. Etapa 7 — Conciliação por fundo (corrigindo os falsos "divergente")

```sql
create or replace function public.fn_reconciliar_competencia(p_competencia_id uuid)
returns table (fundo_id uuid, status status_conciliacao, diferenca_creditos numeric, diferenca_debitos numeric)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- para cada fundo da competência:
    --   creditos_extrato(fundo)     = soma do extrato filtrado por fundo
    --   creditos_balancete(fundo)   = créditos da linha do fundo no RESUMO FINANCEIRO
    --   diferenca = balancete - extrato
    -- grava conciliacoes + conciliacao_detalhe
    -- se todas as diferezas do fundo forem 0 → 'conciliado', senão 'divergente'
    -- atualiza status_competencia da fonte 'extrato' e 'balancete'
end;
$$;
```

**A correção, em uma frase:** a comparação passa a ser **linha do balancete do fundo F × extrato do fundo F**, em vez de **linha do balancete da CONTA CONDOMÍNIO × extrato inteiro**.

Efeito nos dados reais (verificado na análise):

| Competência | Antes (código antigo) | Agora (por fundo) |
|---|---|---|
| 2025-07 | `DIVERGENTE`, créditos −12.820,00, débitos −8.500,00 | **conciliado**, 0,00 em todos os fundos |
| 2026-02 | `DIVERGENTE`, créditos −110.230,00, débitos −92.500,00 | **conciliado**, 0,00 |
| 2026-10 | `DIVERGENTE`, créditos −106.380,00, débitos −163.950,00 | **conciliado**, 0,00 |

As diferenças que existiam eram exatamente a soma dos **outros fundos** — dinheiro que se moveu dentro do condomínio, não dinheiro que sumiu. Com a comparação por fundo, elas desaparecem sem nenhum ajuste artificial.

**O que continua aparecendo como divergência real:** reclassificação. Exemplo — 2026-02, `NF-209 FORNECEDOR EXEMPLO` de R$ 92.500,00 está em `3500 FUNDO DE RESERVA DESPESAS` no extrato e em `MANUTENCAO DE PINTURA` no balancete. O valor bate (por isso o total fecha), mas a **rubrica** diverge. Isso aparece em `conciliacao_detalhe` como linha a linha, vira pendência do tipo `divergencia` com a sugestão de reclassificação — e é decisão sua.

⚠️ **Regra importante:** `fn_reconciliar_competencia` **não** altera nenhum lançamento. Ele calcula, grava o resultado e cria pendências. Reclassificar é ato separado (`fn_classificar_lancamento`), com rastro.

**Regra de promoção de status:** `importado → conciliado` só quando **todos** os fundos da competência fecharem com diferença ≤ R$ 0,01. `conciliado → fechado` é ato explícito do auditor.

---

## 10. Mapeamento da base antiga → novo modelo

### 10.1 Extratos bancários (18 arquivos)

| Arquivo | Competência | Layout | Destino | Tratamento manual |
|---|---|---|---|---|
| `extrato_2025-05.xls` | 2025-05 | v3 | staging → lancamentos | — |
| `extrato_2025-06.xls` | 2025-06 | v3 | idem | — |
| `extrato_2025-07.xls` | 2025-07 | v2 | idem | competência: verificar o cabeçalho (o log antigo gravou período errado) |
| … (idem até 2026-05) | | v2 | | |
| `extrato_2026-06.xls` | 2026-06 | v3 | idem | — |
| … (2026-07 a 2026-10) | | v3 | idem | — |

**Fora do escopo por decisão D7:** `Extratos_gestao_01\*` (12 arquivos, 2023-07 a 2024-06) e `extrato_2025-01.xlsx`. As competências correspondentes ficam com `status_competencia = 'sem_fonte'` e aparecem como pendência.

### 10.2 Balancetes (19 arquivos)

| Arquivo | Competência | Destino | Observação |
|---|---|---|---|
| `data\renamed\balancete_2025-05.pdf` … `2026-10.pdf` (18) | 2025-05 a 2026-10 | `conciliacoes` + `conciliacao_detalhe` | fonte da conciliação por fundo |
| `Balancetes\balancete_2025-01.pdf` | 2025-01 | idem | está **fora** da pasta oficial; o indexador antigo nunca pegou. Importar pela mesma via, com layout `balancete_v1` |
| `Balancetes\2026-04\balancete.pdf` | 2026-04 | idem | **duplicata** de `balancete_2026-04.pdf` (MD5 diferente, mesmo conteúdo) → detectada por competência+conteúdo; manter uma |

**Lacunas de balancete** (2025-02, 2025-03, 2025-04): ficam `sem_fonte` → pendência no painel.

### 10.3 Caixa local (18 arquivos)

| Arquivo | Destino | Tratamento |
|---|---|---|
| `data\renamed\despesas_locais_2025-05.pdf` … `2026-10.pdf` | staging (contas) + `anexos` (comprovantes) | As **7 despesas sem par no extrato** (item 10.5) entram como pendência `lancamento_orfao`, **não** como lançamento |
| `Balancetes\2026-04\caixa_local.pdf` | idem | duplicata de `despesas_locais_2026-04.pdf` |

### 10.4 Planilha-resumo (1 arquivo, 78 blocos)

| Arquivo | Destino | Tratamento |
|---|---|---|
| `planilha-resumo.xlsx` (raiz, 78 blocos, o mais recente) | `serie_historica_resumo` | ~420 linhas. As 21 anotações manuais → `serie_historica_anotacoes` + pendência. 18 blocos sem CRÉDITOS/DÉBITOS → gravados com nulos + pendência "fonte incompleta" |

**Não usar** as outras 3 cópias (`data\renamed\planilha_resumo.xlsx`, `data\raw\...`, `planilha-resumo-antiga.xlsx`) — são versões antigas/parciais. O importador deve pegar **a mais recente por hash** ou você escolher explicitamente na conferência.

### 10.5 Itens que exigem tratamento manual (inventário fechado)

| # | Item | Quantidade | Destino no modelo |
|---|---|---|---|
| 1 | Linhas de `lancamentos_normalizados.csv` (competência 2026-05, 672) | 672 | **Não importar.** O extrato de 2026-05 é a fonte; este CSV é derivado e seria uma segunda via do mesmo dado |
| 2 | `data\manual_validations.csv` | 5 | `pendencias` (tipo `validacao_manual`). **Não** aplicar automaticamente — as 5 estão com `status = pendente` e sem responsável |
| 3 | `despesas_a_esclarecer.xlsx` | 35 | `pendencias` (tipo `classificacao`) com a "Classificacao Sugerida" da planilha como sugestão |
| 4 | `caixa_local_sem_match.csv` | 7 | `pendencias` (tipo `lancamento_orfao`) |
| 5 | `itens_duplicados_unidade.csv` + 2 pares não sinalizados | 4 pares | `duplicatas_candidatas` (as duas linhas permanecem em `lancamentos`) |
| 6 | `contas_nao_mapeadas.csv` | 55 códigos | `contas_origem` com `rubrica_id` nulo + `pendencias` |
| 7 | `balancete_status_conciliacao.csv` (14 `DIVERGENTE`) | 14 | `pendencias` (tipo `divergencia`) → recalculadas por fundo na Etapa 7; as que sobreviverem ficam |
| 8 | `documento_criptografado.pdf` (criptografado) | 1 | `pendencias` (tipo `senha_necessaria`) |
| 9 | `NFs\NF_301_EXEMPLO_20260723.pdf`, `NFs\NF_302_EXEMPLO_20260630.pdf` | 2 | `documentos` + `anexos`, sem lançamento vinculado ainda (vincular por valor/data) |
| 10 | `Balancetes\2026-04\extrato_conta_2026-04.pdf` (extrato em PDF) | 1 | `fontes_importacao` com layout `extrato_pdf_v1` — **novo layout a criar**; ou simply registrar como documento |
| 11 | `Balancetes\2026-04\resumo_despesas_anual.pdf` | 1 | `documentos` (tipo `anexo`), fonte da série anual |
| 12 | `contas energia\*` (Concessionaria Energia) e faturas de água/gás | 10 | **Fora do escopo contábil da Fase 0.** Registrados como `fontes_importacao` com `status = 'detectado'` para quando o consumo por unidade entrar |
| 13 | `AGO_2026\`, `AGO_2026_campanha\` | ~120 | **Fora do escopo (Fase 2).** Não são tocados agora |

---

## 11. Idempotência — resumo dos mecanismos

| Nível | Mecanismo | Efeito |
|---|---|---|
| Arquivo | `unique (condominio_id, hash_sha256, layout)` | Mesmo arquivo nunca é importado 2 vezes |
| Arquivo re-exportado | tupla semântica + occurrence | As linhas repetidas viram `duplicado_candidato`; só o que é novo entra |
| Linha de staging | `unique (importacao_id, chave_natural)` + `unique (importacao_id, fonte_id, linha_origem, numero_ocorrencia)` | Reexecutar o importador atualiza, não duplica |
| Lançamento | `unique (condominio_id, chave_natural)` (tupla + occurrence) | Aprovação repetida é no-op |
| Aprovação | `fn_aprovar_staging` em transação | Falha no meio = rollback completo |
| Balancete | `unique (competencia_id, fundo_id)` em `conciliacoes` | Reconciliar 2 vezes não duplica |
| Série histórica | `unique (condominio_id, ano, mes, bloco, rubrica_alias)` | Reimportar a planilha atualiza |
| Fontes | `unique (condominio_id, hash_sha256, layout)` | — |

---

## 12. Onde roda o importador

| Opção | Prós | Contras |
|---|---|---|
| **🅰️ Script Python local (recomendado)** | Parsing pesado (xlrd/openpyxl/pdfplumber) roda offline; a pasta antiga nunca é exposta; o script é testável com pytest; o banco só recebe o staging | Precisa de Python instalado na sua máquina |
| 🅱️ Edge Function no Supabase | Roda perto do banco; sem Python local | PDF/Excel com OCR em Node é frágil; upload de 500 KB+ de arquivo por requisição; mais difícil de depurar |
| 🅲️ Híbrido: script local + Edge Function para o que é pequeno | Cada um na sua casa | Dois ambientes para manter |

**Recomendação: 🅰️.** O trabalho pesado é de parsing — e parsing local é mais fácil de testar e de iterar. O script conversa com o banco **apenas** para gravar `staging_*` e ler `contas_origem`/`rubricas` como referência. Ele **não** usa `service_role_key`: usa a credencial do role `app_importador`, que só escreve em staging. Assim, mesmo com o script comprometido, ele não consegue escrever em `lancamentos`.

---

## 13. Ferramentas e dependências

| Ferramenta | Uso | Observação |
|---|---|---|
| Python 3.11+ | importador | O ambiente atual tem 3.14 — ok |
| `xlrd` | ler `.xls` (old format) | já presente |
| `openpyxl` | ler `.xlsx` | já presente |
| `pdfplumber` | ler PDF (balancete, caixa local) | **precisa instalar** — não está no `requirements.txt` do app antigo |
| `pandas` | manipulação tabular | já presente |
| `pyyaml` | ler o mapa de rubricas em YAML | já presente |
| `pytest` | testes dos parsers com fixtures reais | já presente |
| `psycopg` (v3) | gravar no Supabase | **novo** — ou `supabase-py` |

**Nenhuma instalação foi feita.** Quando você aprovar, sugiro um `pyproject.toml` com `uv` (ou `requirements-dev.txt`) e um `uv.lock`/`requirements.txt` versionado, para que o ambiente seja reproduzível.

⚠️ **"Regras de parsing herdadas do app antigo"** (de `AGENTS.md` e dos 29 testes existentes) — a lista completa do que migrar como teste:
- `parse_unidade`: só padrões explícitos, nunca número solto;
- `parse_valor_bruto`: formato BR;
- `parse_vencimento`: `VC.`/`V.`/`VC ` com `DD/MM/YY`;
- `parse_competencia_from_periodo`: `MM/AAAA` → `YYYY-MM`;
- `parse_referencia_rb`: `RB.`/`RC.`;
- competência sempre `YYYY-MM`;
- CSV de saída sempre `utf-8-sig`.

Os testes do app antigo (`tests/test_parser_extrato.py`, `test_normalizacao.py`, `test_conciliacao.py` — 29 testes) são **reutilizáveis como ponto de partida** para os fixtures do importador novo. Recomendo copiá-los para `scripts/importacao/tests/` e adaptá-los.

---

## 14. Plano de execução da importação (quando aprovado)

| Passo | O que | Resultado verificável |
|---|---|---|
| 1 | `copiar_origem.py` — copia da pasta antiga para `dados_origem\` | log do que foi copiado (hash de cada arquivo) |
| 2 | `detect.py` — varre e classifica | relatório: N arquivos, N por layout, N competências |
| 3 | `parse_extrato.py` + fixtures | testes verdes nos 18 extratos; **cada arquivo fecha contra o próprio RESUMO** |
| 4 | `parse_balancete.py` | 19 balancetes com as 8 seções |
| 5 | `parse_caixa_local.py` | 18 contas + anexos das páginas 2+ |
| 6 | `parse_planilha_resumo.py` | 78 blocos → série histórica |
| 7 | `normalizar.py` + `classificar.py` | sugestões de rubrica/fundo/unidade/transferência/duplicata |
| 8 | `gravar_staging.py` | staging populado, idempotente |
| 9 | Painel de conferência (front) | você aprova linha a linha |
| 10 | `fn_aprovar_staging` | lançamentos gravados, com rastro |
| 11 | `fn_reconciliar_competencia` | conciliação por fundo, 18 competências conciliadas |
| 12 | Carga inicial de rubricas/unidades/fundos/aliases | 24 rubricas, 94 contas de origem, 72 unidades, ~120 aliases |

**Critério de sucesso do passo 3:** os 18 extratos em escopo fecham **exatamente** contra o próprio bloco RESUMO (créditos, débitos e saldo final). Se algum não fechar, o arquivo não vai para staging — vira pendência. Esse é o teste que impede que um bug de leitura (como o do layout v1) entre no banco em silêncio.

---

## 15. O que **não** está decidido

- Se o `dados_origem\` será uma **cópia** da pasta antiga (proposta) ou se o importador lerá direto da pasta antiga (não recomendado — leitura de rede pode falhar e a pasta é Read-Only por decisão sua).
- Se o `app_importador` usa `psycopg` direto ou `supabase-py` (recomendo `psycopg`, por performance e por permitir `ON CONFLICT`).
- Granularidade da conferência (linha a linha × por lote × por bloco de competência).
- Se a Fase 0 inclui o `config_visibilidade` com `leitor` em `fundo` (sim, por D10).
