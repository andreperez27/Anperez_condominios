# Diário de bordo — ANPEREZ CONDOMÍNIOS

Registro cronológico das decisões, descobertas e perguntas em aberto do projeto.
Cada entrada registra: o que foi feito, o que foi decidido e o que ficou pendente.

---

## 2026-11-11 — Etapa 0: reconhecimento e investigação (Fase 0 + parte contábil)

### O que foi feito

**Leitura integral da pasta antiga** `C:\Users\andre\Desktop\condominio`, em modo somente leitura. Nada foi alterado, movido ou apagado lá dentro — nenhuma escrita, nenhuma renomeação, nenhum arquivo deletado. A verificação de integridade (hashes MD5 comparados entre as pastas duplicadas) também foi apenas de leitura.

Inventário completo: 586 arquivos, ~189 MB, incluindo o repositório Git do app anterior e caches `__pycache__`.

**Arquivos abertos e analisados** (amostragem estruturada, não leitura de tudo byte a byte):
- Os 18 extratos `.xls` de `data\renamed\` — os 3 layouts diferentes identificados, cabeçalho, bloco RESUMO, contagem de linhas
- Os 12 extratos `.xls` de `Extratos_gestao_01\` (2023-07 a 2024-06)
- `extrato_2025-01.xlsx`
- As 4 versões distintas da planilha-resumo (`planilha-resumo.xlsx` na raiz, `data\renamed\planilha_resumo.xlsx`, `data\raw\...`, `planilha-resumo-antiga.xlsx` na raiz) — 78 blocos mensais
- 3 balancetes em PDF (2025-01, 2025-07, 2026-04) e `extrato_conta_2026-04.pdf` e `caixa_local.pdf`
- `config\mapa_contas.yaml`, `config\unidades.yaml`, `config\faturas_concessionaria.csv`
- Todo o código de `src\` (parsers, services, exporters) e os 3 arquivos de teste
- Os 38 CSVs de `output\` e `data\`
- As 15 planilhas de apoio de `Planilhas\` (estrutura de abas e cabeçalhos)
- `README.md`, `AGENTS.md`, `.gitignore`, `requirements.txt`, histórico Git do app anterior

**Verificações por reexecução** (não só leitura de arquivo): rodei o parser de extrato real sobre 4 arquivos (2023-07, 2025-01, 2025-07, 2026-10) e os parsers de PDF sobre 3 documentos para confirmar o comportamento real. Também reprocessei extratos e balancetes para reconciliar os totais.

**Documentos produzidos:**
- `docs/INVENTARIO_DADOS.md` — inventário completo com período, formato e tamanho de cada item, e a estrutura detalhada de cada planilha/PDF
- `docs/QUALIDADE_DADOS.md` — relatório de inconsistências (apenas relato, sem correção)

### Descobertas que mudam o desenho do projeto

1. **Os totais do extrato e do balancete batem exatamente** nas 18 competências comparáveis (R$ 0,00 de diferença em créditos e débitos). O relatório antigo marcava 14 meses como `DIVERGENTE` porque comparava a linha `CONTA CONDOMINIO` do balancete contra o total de todos os créditos do extrato, sem eliminar as transferências entre os próprios fundos do condomínio. **A divergência é artefato de cálculo, não erro da administradora.** Isso muda a prioridade: o problema central não é "conferir se os números batem", e sim "classificar corretamente e eliminar dupla contagem de transferências internas".

2. **O parser atual lê errado os extratos de 2023-07 a 2024-06** (12 arquivos, ~7.000 lançamentos): data vira histórico, crédito vira débito, unidade não é extraída. Confirmei executando o parser. Esses dados nunca entraram no consolidado (que começa em 2025-05), o que escondia o problema.

3. **Existem 3 layouts diferentes de extrato bancário** no mesmo conjunto de arquivos, e um 4º arquivo em `.xlsx` que o pipeline não lê (`extrato_2025-01.xlsx`, janeiro/2025). Um importador novo precisa ser guiado por layout detectado, não por tentativa-e-erro.

4. **Rastreabilidade se perde na consolidação**: `lancamentos_normalizados.csv` guarda `arquivo_origem` + `linha_origem`; `extrato_consolidado.csv` guarda só o nome do arquivo. Auditoria exige a linha de origem.

5. **O mesmo código de conta aparece com nomes diferentes** (MULTAS em 5 códigos, CONDOMINOS EM ATRASO em 5 fundos, CONSUMO DE AGUA como receita e como despesa) e **as três fontes têm taxonomias diferentes** (extrato: 94 códigos; planilha-resumo: 8 rubricas; balancete: rótulos próprios). Daí a necessidade de uma tabela de rubricas com aliases por fonte.

6. **O prefixo do código de conta já identifica o fundo** (1xxxx = CONTA CONDOMÍNIO, 2xxxx = BENFEITORIAS, 3xxxx = FUNDO DE RESERVA, 15xxx = PINTURA, 19xxx = SALÃO). Modelar isso como atributo do lançamento resolve boa parte do problema da dupla contagem.

7. **Não há banco de dados** em lugar nenhum da pasta antiga. Todo o "esquema" está em dataclasses Python + um YAML de rubricas.

8. **Não há nomes de moradores em nenhum arquivo contábil** — as unidades são identificadas só por número (11 a 184). O dado sensível é a associação unidade ↔ situação financeira (inadimplência, consumo, valor pago). Isso é o que a LGPD protege aqui.

9. **Um PDF está criptografado** (`documento_criptografado.pdf`, AES) e um arquivo do `log_renomeacao.csv` tem 43 linhas todas com status `IGNORADO` (o dedup por MD5 está barrando arquivos re-exportados).

### Decisões do usuário (11/11/2026) — primeira rodada

| # | Pergunta | Decisão |
|---|---|---|
| D7 | Escopo temporal da importação (Q1) | **Só 2025-05 em diante** — 18 competências, 11.439 lançamentos. A lacuna de 2024-07 a 2025-04 fica registrada como pendência para uma fase futura; o leitor do layout de 5 colunas sem "Descrição Conta" não será reescrito agora |
| D8 | Transferências entre fundos (Q2) | **Campo "fundo" no lançamento + marcação "interno"**. O consolidado soma por fundo e nunca duplica. É o que explica as diferenças que o app antigo reportava como divergência |
| D9 | Unidade no modelo (Q3) | **Entidade `unidades`**, com chave (condomínio, número, andar, posição, ativa), referenciada pelo lançamento |
| D10 | Visão do leitor / LGPD | **Somente agregados por condomínio e por fundo para o leitor** nesta primeira versão. O RLS deve ser escrito de forma que **liberar o nominal por unidade no futuro seja só uma mudança de política, sem alteração de schema**. O auditor (o próprio usuário) continua vendo tudo |

---

## 2026-11-11 — Etapa 1: itens 3 a 6 (modelo, segurança, importação, repositório)

### O que foi feito

Continued **em modo de planejamento**. Nenhum repositório, projeto Supabase, migration, script ou código de aplicação foi criado. A pasta antiga continua intocada. Os quatro documentos foram escritos a partir do que a Etapa 0 apurou, sem nenhuma nova leitura de dados.

**Documentos produzidos:**
- `docs/MODELO_DADOS.md` — 22 seções: esquema completo com campos, chaves, enums, índices, views, funções e o mapeamento da base antiga para o modelo novo
- `docs/SEGURANCA_RLS.md` — papéis, matriz de privilégios, as duas variantes de RLS para comparação, checklist de função privilegiada, tratamento LGPD e dos anexos
- `docs/IMPORTACAO.md` — o fluxo de 7 etapas, os parsers por layout, a verificação de fechamento, a RPC atômica de aprovação e o inventário do que exige tratamento manual
- `docs/ESTRUTURA_REPO.md` — árvore de pastas completa, `.gitignore`, convenção de migrations, ordem de criação em 13 passos
- `docs/DIARIO_DE_BORDO.md` — esta entrada

### Decisões do usuário (11/11/2026) — segunda rodada

| # | Assunto | Decisão |
|---|---|---|
| D11 | Competências sem balancete ou sem caixa local | Modelar como **"sem fonte"**, uma lacuna sinalizada que aparece como **pendência no painel** — nunca como mês vazio. Cada competência tem **status por fonte**: `sem_fonte` → `importado` → `conciliado` → `fechado` |
| D12 | `documento_criptografado.pdf` (criptografado) | **Fica fora por enquanto.** Registrar como **pendência de obter uma cópia sem senha** |
| D13 | Validações manuais e despesas "a esclarecer" | **Não são detalhe de dados.** Modelar uma **tabela de pendências/achados** com origem, lançamento ligado, status e anotação — porque é o núcleo da auditoria |
| D14 | Fundo | **Entidade própria**, com o prefixo do código de conta — não texto solto no lançamento |
| D15 | Transferências internas | Continuam **visíveis**: as duas pontas ligadas por identificador de grupo, lista própria (`transferencias_internas`), e a marcação "interno" **passa pela conferência antes de valer**. Regra de ouro: **classificação errada não pode esconder dinheiro real do consolidado** |
| D16 | Rubricas | **Aliases por fonte** (extrato / planilha-resumo / balancete). Classificação de cada lançamento com estado **`sugerida` ou `confirmada`** |
| D17 | Duplicatas | **Não descartar automaticamente.** Dois pagamentos iguais no mesmo dia podem ser legítimos → sinalizar como **candidatas** e deixar para o usuário decidir |
| D18 | Rastreabilidade | Todo lançamento guarda **arquivo de origem, hash, aba ou página e linha** — sem exceção |
| D19 | Importador | **Guiado por detecção de layout** (3 layouts de extrato, balancete PDF, caixa local PDF com comprovantes escaneados como anexos), com **área de conferência antes de gravar**. **Idempotente** |
| D20 | Conciliação | Extrato × balancete calculada **por fundo e por competência**, corrigindo a lógica que gerou os falsos "divergente" |
| D21 | Planilha-resumo (2020–2026, 78 meses) | **Avaliar importar como série histórica agregada em tabela separada**, sem lançamentos — para termos tendência de longo prazo mesmo com o extrato só a partir de 2025-05 |

### Decisões de modelagem que eu tomei (para revisar)

| # | Decisão | Alternativa descartada |
|---|---|---|
| D22 | `v_resultado_bruto` (soma tudo) é o **padrão**; `v_resultado_liquido` (desconta transferências **confirmadas**) é a derivada | Consolidado único já l?quido — com ele, erro de classificação esconderia dinheiro |
| D23 | `chave_natural` inclui **documento + tipo + valor**, não só data+valor | Chave por data+valor fundiria dois pagamentos legítimos iguais |
| D24 | Classificação por lançamento (`lancamento_rubrica`), não só por código de conta | O caso Fornecedor Exemplo mostra a mesma conta (1647) com naturezas diferentes |
| D25 | Série da planilha-resumo em **tabela própria** (`serie_historica_resumo`), sem virar lançamento | Lançamento sintético por mês — não há documento nem linha por trás |
| D26 | `unidade.numero` como **texto** (o extrato usa `UN.000033`, a planilha `000013`) | Integer — perderia o zero à esquerda original |
| D27 | Importador com role próprio (`app_importador`), **sem `SELECT` em `lancamentos`** | Usar `service_role_key` — daria poder de escrita em produção ao script |
| D28 | Garantia de "leitor só vê agregado" vem da **revogação de privilégio**, não do RLS | Só policy de RLS — o RLS filtra linha, não calcula agregado; e o privilégio padrão do Supabase deixaria o vazamento virar metadado |

### Correções de 11/11/2026 (antes da aprovação final)

Você pediu 10 correções nos documentos de modelo e segurança. Todas foram aplicadas; `SEGURANCA_RLS.md` foi reescrito por inteiro e `MODELO_DADOS.md` teve as seções afetadas reescritas.

| # | Pedido | Como foi resolvido |
|---|---|---|
| C1 | Como cada usuário Supabase assume o papel de aplicação | **Fluxo padrão**: o login emite JWT com `role: authenticated`; o papel de negócio vem de `membros`, consultado em tempo de consulta por helpers `SECURITY DEFINER`. **Descoberta crucial**: no fluxo padrão **não existe `GRANT` separado para o leitor** — leitor e auditor são o mesmo role. Por isso a garantê foi reestruturada: `authenticated` **não tem `GRANT` de tabela alguma** em detalhe, e a diferença7ão leitor × auditor acontece **dentro** das views e funções. Matriz completa de REVOKE/GRANT em SEGURANCA_RLS §3.2 |
| C2 | Papel sempre avaliado por condomínio | `fn_papeis_do_usuario(p_condominio_id uuid)` substitui a versão global; `fn_e_membro(p_condominio_id, p_papel)` é o atalho booleano usado nas policies. Todas as policies, funções e views foram reescritas para testar o papel contra o **condomínio da própria linha**. Um síndico com papéis em dois condomínios tem visibilidade independente em cada um |
| C3 | FORÇE ROW LEVEL SECURITY × `app_owner` | **Resolvido explicitamente**: `app_owner` recebe `BYPASSRLS` (explícito, não herdado do default), as tabelas usam `FORCE ROW LEVEL SECURITY`, e o **filtro de tenant é manual e obrigatório** em cada função e view de `app_owner`. Documentado por que as outras três alternativas não funcionam — em especial que FORCE sem BYPASSRLS faria a view agregada herdar o filtro e o leitor veria zero agregados. Alternativa mais defensiva (tabela de resumo materializada) registrada como plano B |
| C4 | `fn_resumo` reescrito | Reescrito em plpgsql válido, com granularidade vinda de `config_visibilidade` (por condomínio e papel) e **sem checagem fixa de papel no código**. Honra o parâmetro `p_granularidade`, valida contra `granularidade_ordem` (fundo &lt; rubrica &lt; unidade), e aplica o **limiar mínimo de agregação** (padrão 5, configurável por condomínio e papel) **somente** a agregações apoiadas em dado ligado a unidade. Linhas suprimidas voltam com `suprimido = true` e valores `NULL` (não R$ 0,00, que pareceria "não houve gasto") |
| C5 | Número da ocorrência na `chave_natural` | `chave_natural = sha256(tupla_semantica + '#' + numero_ocorrencia)`, com o número da ocorrência calculado **durante o parse**, varrendo o arquivo em ordem. Agora as duas linhas idênticas do arquivo (unidade 42 em 2025-09) têm chaves **diferentes** e as duas entram — e são marcadas como candidatas. A idempotência na reimportação permanece, porque a occurrence é determinística. Critério de duplicata renomeado para `mesma_tupla_no_arquivo` |
| C6 | Fonte única de verdade do estado da transferência | Removidas as colunas `eh_transferencia_interna` e `status_transferencia` do `lancamentos`. O estado vive **só** em `transferencias_internas.status`. O enum perdeu o valor `nao_aplicavel` (lançamento sem transferência simplesmente não tem `grupo_transferencia_id`). Toda consulta usa a mesma expressão |
| C7 | Anexos bloqueados por padrão, liberação por anexo | `anexos.liberado_para_leitor` + `liberado_em` + `liberado_por`. A policy de storage agora consulta `fn_anexo_acessivel(name)`, que dá acesso pleno a auditor/síndico/conselho e ao leitor **somente** o anexo individualmente liberado. `fn_liberar_anexo_para_leitor` é a única via de mudança, e a liberação é auditada |
| C8 | Síndico comenta e contesta; `acesso_log` de todas as escritas e leituras do leitor | Nova entidade `contestacoes` (com `status` `aberta`/`em_analise`/`acolhida`/`rejeitada`), `fn_contestar_lancamento` e `fn_responder_contestacao`. O síndico **não** classifica — `fn_classificar_lancamento` é exclusiva do auditor. `acesso_log` gravado por **trigger genérico em toda escrita** e pela própria `fn_resumo` em toda leitura agregada. **Limite honesto registrado**: não existe trigger de `SELECT` no Postgres, então a leitura *nominal do auditor* depende de `pgaudit` — pendência em aberto |
| C9 | Bateria de testes de segurança | **40 cenários (T01–T40)** em SEGURANCA_RLS §11, com 5 personas (`leitor_cond_a`, `auditor_cond_a`, `leitor_cond_b`, `sindico_cond_a`, `app_importador`). Cobrem: `SELECT` direto em tabela de detalhe, `count(*)`, `INSERT`/`UPDATE` direto, chamada de função sem permissão, granularidade não permitida, leitura de agregados de outro condomínio, `v_lancamentos` com papel insuficiente, importador tentando escrever em `lancamentos`, storage com anexo não liberado e liberado, bruto vs líquido, e o limiar de agregação. Regra do CI: falha de qualquer cenário quebra o build |
| C10 | Revisão de redação e coluna duplicada | Corrigidos: coluna `creditos` duplicada no SQL da §1.3, `tomo_movimento` (digitado errado) no `fn_resumo`, `Privilégioio`, `a juicy`, `have`, `decisively`, `2transferências`, `doano`, `deundy`, `mais_objects`, `the aggregated`, `recebenaturezas` e a palavra truncada na §8.3. Verificação automática de caracteres estranhos em todos os `.md` |

**Também ajustados:** `IMPORTACAO.md` (etapa 3 e 4 do fluxo, seção 5.3 reescrita com a tabela de ocorrência, idempotência) e `ESTRUTURA_REPO.md` (migrations 10, 12 e 14 atualizadas; §5.4 com a bateria de 40 cenários).

### Novas decisões de modelagem (para revisar)

| # | Decisão | Alternativa descartada |
|---|---|---|
| D29 | `authenticated` **não tem `GRANT`** em nenhuma tabela de detalhe; toda leitura passa por view ou função | Manter `GRANT SELECT` e deixar o RLS filtrar (o leitor veria zero linhas, mas manteria o privilégio e a proteção passaria a depender de cada policy estar correta) |
| D30 | `app_owner` com `BYPASSRLS` **explícito** + `FORCE RLS` nas tabelas + filtro de tenant manual | Depender do default "owner ignora RLS" (frágil: um `ALTER TABLE ... OWNER TO postgres` muda o comportamento) |
| D31 | A liberação do nominal continua sendo **um UPDATE** em `config_visibilidade`, agora por condomínio e papel | Fixar o papel no código da função (exigiria alterar código para cada condomínio) |
| D32 | Limiar mínimo de agregado??o como **coluna de `config_visibilidade`**, suprimindo valores e sinalizando com `suprimido` | Não aplicar limiar (risco de célula pequena) ou suprimir a linha inteira (o front não saberia que houve dado) |
| D33 | `contestacoes` como entidade própria, e não como anotação dentro da pendência | Anexar a contestação à pendência (o síndico contesta um **lançamento**, não uma pendência; e a resposta do auditor precisa de estado próprio) |
| D34 | Número da ocorrência entra na `chave_natural` e **não** num campo separado | Campo `numero_ocorrencia` sem entrar na chave — aí o `unique` continuaria descartando a 2â linha idêntica em sil?ncio |

### Recomendações que precisam da sua escolha

1. **RLS — escolha entre as duas variantes** (SEGURANCA_RLS §4 e §5):
   - **🅰 Variante A (recomendada):** função agregadora `SECURITY DEFINER` que verifica o papel **no condomínio pedido** e a granularidade **na configuração**. Liberar o nominal no futuro = **UPDATE de 1 linha** em `config_visibilidade`.
   - **🅱 Variante B:** views agregadas com `security_barrier` + `GRANT` por view. Liberar o nominal = criar 1 view e dar `GRANT`.
   - Minha proposta final: **A como espinha dorsal + as views simples do B para os relatórios fixos**.
2. **Caminho do Anperez Money** — para casar nomes de roles, helpers, formato das policies e convenção de RPC com o que você já usa. Não fui procurar sozinho.
3. **Limiar mínimo de agregação**: o padrão 5 está bom, ou prefere 3 ou 10?
4. **`acesso_log`**: retenção de 1 ano, 5 anos, ou o prazo do condomínio?
5. **`pgaudit`** está disponível no seu plano do Supabase? Sem ele, a leitura nominal do auditor não fica no `acesso_log` (as escritas e as leituras do leitor ficam).
6. **Anexos em lote**: liberação por anexo (proposta) ou por competência?
7. **Síndico**: pode comentar/contestar (implementado). Pode **anexar** documento ao contest? (não implementado).

### Estado atual

### Estado atual

- Etapas 0 e 1 concluídas, com revisão pré-aprovação: **6 documentos de projeto** em `docs\`.
- **Nada foi criado** em `G:\Anperez_Condominios` além da pasta `docs\` — sem repositório, sem Supabase, sem migrations, sem código.
- Aguardando aprovação final para começar a criação (sequência de 13 passos em `ESTRUTURA_REPO.md` §8).

---

## 2026-11-12 — Etapa 2: Build dos passos 1 a 3 (repositório, ambiente, migrations)

### O que foi feito

**Passo 1 — Repositório.**
- `git init` em `G:\Anperez_Condominios`, branch `main`.
- `.gitignore` com **negativa global de formato de dado** (`*.xls`, `*.xlsx`, `*.pdf`, `*.csv`) + exceção explícita para `docs/`, `supabase/migrations/`, `supabase/tests/` e `supabase/seed.sql`; chaves (`.env*`, `*.pem`, `*service_role*`); `dados_origem/` e `dados_trabalho/`; caches de Python e Node.
- `README.md` e `AGENTS.md` com as convenções do projeto e as armadilhas do Supabase descobertas na implementação.
- `front/public/logo.png` movido da raiz para a estrutura do front.

**Passo 2 — Ambiente Supabase local.**
- Docker Desktop + Supabase CLI 2.107.0, PostgreSQL 17.6, container `supabase_db_anperez_condominios`.
- `supabase/config.toml` com `project_id = "anperez_condominios"` (identificador **local**; o projeto remoto é `aejuoiwxzzsxmhhizwau`).
- `supabase/bootstrap/00-zerar_privilegios_padrao.sql` — roda como `supabase_admin` porque é o único papel que pode zerar os *default privileges* do schema `auth` e do `supabase_admin`.
- `supabase/bootstrap/reset_local.ps1` — orquestra: espera o banco → zera privilégios → instala `pgtap`/`pgcrypto` → carrega o seed.
- `supabase/seed.sql` — **só configuração fictícia**: 1 condomínio, 7 fundos, 31 rubricas, 55 aliases, 19 contas de origem, 72 unidades, 4 políticas de visibilidade, retenção de 12 meses. **Zero dado real.**

**Passo 3 — Migrations base com papéis e RLS.**
- **16 migrations**, aplicadas do zero com `supabase db reset` sem erro.
- 35 tabelas, 14 views agregadas, 38 funções, 53 policies de RLS, 26 enums, 2 roles de aplicação.
- Bateria de segurança com **53 testes (T01–T46)**, todos verdes.

### O teste pedido no passo 1: BYPASSRLS funciona

> "Teste logo no passo 1 se o Supabase permite criar o role `app_owner` com BYPASSRLS."

**Resposta: SIM.** Verificado em 11/11/2026 no ambiente local:

```sql
create role app_owner nologin bypassrls;
-- CREATE ROLE
select rolname, rolbypassrls, rolcanlogin from pg_roles where rolname = 'app_owner';
--  app_owner | t | f
```

O plano B (usar o `postgres` como dono) **não foi necessário**. O `app_owner` foi criado na migration `00200` e é o owner de todas as funções e views privilegiadas.

⚠️ **A consequência dessa escolha é central:** com `BYPASSRLS`, o `app_owner` **ignora** as policies. O filtro de tenant dentro de cada função e view **não é redundante** — é a única proteção. Por isso `fn_papeis_do_usuario(p_condominio_id)`, `fn_e_membro(p_condominio_id, p_papel)` e `fn_condominios_do_usuario()` existem e são usados em todas as policies e funções.

### Os dois ajustes pedidos antes de gerar as migrations

**Ajuste 1 — revogação de privilégios para objetos futuros.** ✅ Implementado, com uma descoberta: os *default privileges* que importam são os do `supabase_admin` (o `postgres` não é superuser no Supabase local, e `postgres` não pode alterar os dele — `permission denied to change default privileges`). A revogação ficou no **bootstrap**, executado como `supabase_admin`, cobrindo tabelas, funções e sequências.

**Ajuste 2 — teste de drift de grants.** ✅ Implementado em `supabase/tests/05_drift_grants.test.sql` (T41–T46): lista os grants reais de `authenticated` e `anon` e compara com a **lista permitida**; falha o build se houver diferença. Também verifica que `anon` não tem nenhum privilégio, que nenhuma função `SECURITY DEFINER` é executável por `anon`, e que nenhum *default privilege* concede acesso.

### Decisões do usuário aplicadas

| # | Decisão | Como ficou |
|---|---|---|
| D35 | RLS: combinação **A + B** | Função agregadora `fn_resumo` (granularidade pela configuração) **+** views agregadas para os relatórios fixos. O leitor não tem `SELECT` em tabela de detalhe alguma |
| D36 | Limiar padrão **5**, configurável | `config_visibilidade.limiar_minimo_unidades`, por condomínio e por papel. Auditor = 0 (não precisa de proteção de célula); leitor = 5 |
| D37 | `acesso_log` com **retenção configurável, começando em 12 meses** | `config_retencao_acesso.meses_retencao` + `fn_purgar_acesso_log` |
| D38 | Anexos liberados **um a um** | `anexos.liberado_para_leitor` + `fn_liberar_anexo_para_leitor` (só auditor) + `fn_anexo_acessivel` (consultada pela policy de storage) |
| D39 | **Sem anexo em contestação** por enquanto | `contestacoes` aponta para lançamento/pendência/documento, sem anexo |
| D40 | O Anperez Condomínios tem **projeto Supabase próprio** (`aejuoiwxzzsxmhhizwau`) | O Anperez Money (`hcajvnvivngggikmxlbx`) **não foi tocado**: nenhuma migration, nenhuma tabela, nenhuma credencial copiada. Só a leitura de migrations, helpers e convenção de RPC, em modo leitura |

### Descobertas técnicas (o que a implementação ensinou)

Estas não estavam no desenho e estão documentadas em `SEGURANCA_RLS.md` §16:

1. **O `search_path` da sessão no Supabase local é `"$user", public, extensions` — sem `auth`.** Um `auth.uid()` usado dentro de um `INSERT` pode ser resolvido no contexto do statement, e a coluna vira NULL (`null value in column "usuario_id"`). Solução: helper `public.fn_usuario_atual()` lendo o claim do JWT direto do GUC.
2. **O helper precisa ser `VOLATILE`, não `STABLE`** — função `STABLE` é avaliada pelo planner no início da query, e o claim trocado no meio do teste invalida o snapshot.
3. **`FORCE ROW LEVEL SECURITY` subjects o `postgres` às policies** (ele tem `BYPASSRLS`, mas FORCE o subjeita). Por isso os helpers de teste têm owner = `app_owner`.
4. **A revogação de funções (`fn_revogar_funcoes_publicas`) tira os grants dos helpers** — eles precisam ser re-concedidos depois de cada revogação. O sintoma é `permission denied for function ...` **dentro** da função.
5. **O pgTAP usa `$$` como delimitador de string**, que colide com o `$$` do SQL interno. Os testes usam a tag `$fn$...$fn$` e qualificam as funções com `extensions.`.
6. **`set_config(..., true)` (local) não sobrevive à troca de role** — o helper de teste usa escopo de sessão.
7. **8 RPCs faziam `INSERT` em `auditoria_log` sem a coluna `usuario_id`** (NOT NULL) — erro só em runtime. Corrigido, e agora há verificação.

### Resultado da bateria de segurança

```
=== 01_leitor_tabela_detalhe.test.sql ===     OK: 14 teste(s)
=== 02_granularidade_limiar.test.sql ===      OK: 11 teste(s)
=== 03_isolamento_condominios.test.sql ===    OK:  7 teste(s)
=== 04_papeis_importador_anexos.test.sql ===  OK: 15 teste(s)
=== 05_drift_grants.test.sql ===              OK:  6 teste(s)
========================================
Total de testes: 53
BUILD OK
```

Cenários cobertos: SELECT direto em tabela de detalhe (leitor, importador), contagem, INSERT/UPDATE direto, chamada de função privilegiada sem papel, granularidade não permitida, granularidade inexistente, limiar suprimindo e não suprimindo, log de leitura, isolamento entre condomínios, usuário sem vínculo, papel do síndico (lê/contesta/não classifica), contestação cross-tenant, importador sem acesso a produção, anexo bloqueado/liberado, bruto × líquido, lista de grants, privilégio padrão.

### Estado atual

- **Passos 1, 2 e 3 concluídos e reproduzíveis.** O ciclo `db reset` → `bootstrap` → `run_tests` roda do zero com 53/53 verdes.
- **Nada foi aplicado no projeto Supabase remoto** (`aejuoiwxzzsxmhhizwau`). O `supabase link` exige `SUPABASE_ACCESS_TOKEN` ou a senha do banco remoto — **não foi executado**.
- **O Anperez Money não foi tocado.** Nenhuma migration, tabela, credencial ou lógica de negócio foi copiada de lá. Só migrations, helpers e convenção de RPC foram lidos.
- **Nenhum dado do condomínio foi lido ou gravado.** O seed é 100% fictício; o importador (Fase 1) ainda não existe.

### Pendências para a Fase 1

1. `supabase link --project-ref aejuoiwxzzsxmhhizwau` e `db push` das 16 migrations (precisa de `SUPABASE_ACCESS_TOKEN` ou senha do banco remoto).
2. Criar `scripts/importacao/` (parsers por layout, normalização, gravação do staging).
3. Criar `front/src/` (dashboard agregado, conferência de importação, pendências).
4. Decidir o `SUPABASE_ACCESS_TOKEN` do ambiente remoto — e onde ele fica.
5. `pgaudit`: está disponível no plano? Sem ele, a leitura nominal do auditor não entra no `acesso_log`.

---

## 2026-11-12 — Etapa 3: prontidão do push, teste e2e real, roteiro remoto e plano da Fase 1

### O que foi feito

**1. Varredura de dado sensível (relatada, nada apagado).**

Varri `docs\` e todos os arquivos versionados atrás de dado real, cruzando com a pasta antiga (somente leitura).

| Categoria | Resultado |
|---|---|
| **Nome real de fornecedor/pessoa** | ✅ **nenhum** nos arquivos do projeto |
| **Número real de nota fiscal** | ⚠️ **3 números** citados nos docs: `NF-209`, `NF-218`, `NF-230` (em `IMPORTACAO.md`, `MODELO_DADOS.md`, `QUALIDADE_DADOS.md`) |
| **Valor monetário real** | ⚠️ **40 valores** reais citados nos docs (de 2.814 distintos no extrato consolidado antigo). Ex.: R$ 92.500,00, R$ 85.000,00, R$ 2.950,00, R$ 1.250,00, R$ 185,00, R$ 170,00 |
| **Nome de arquivo de dado** | ⚠️ **115** nomes de arquivo da pasta antiga citados (extratos, balancetes, planilhas, NFs, atas) |
| **CPF/CNPJ de pessoa** | ✅ **nenhum** |
| **Binário** | 1: `front/public/logo.png` (logo do projeto, 1,6 MB, é marca — não dado) |

⚠️ **A avaliação (para sua decisão):** os 40 valores e os 3 números de NF **não identificam morador** — são valores de despesa do condomínio (obra de pintura, piscina, caixa local) e já estão descritos de forma agregada nos documentos de projeto. **Mas** são dado real do condomínio, e o repositório vai para o GitHub. Como o repositório é **privado** e o `.gitignore` bloqueia os arquivos, isso é aceitável — **desde que o repositório não vire público**. Deixei isso explícito no roteiro de implantação.

**2. Comandos de push preparados (NÃO executados).**

```bash
git remote add origin https://github.com/andreperez27/Anperez_condominios.git
git ls-files | grep -Ei '\.(xls|xlsx|xlsm|csv|pdf|db|sqlite|pem|key)$' && echo "PARE" || echo "OK"
git push -u origin main
```

⚠️ **Antes do push, confirme que o repositório está PRIVADO.** O `.gitignore` impede que um arquivo *novo* de dado entre, mas não remove o que já foi commitado — e o histórico guarda todas as versões.

**3. `fn_usuario_atual()` × formato real do PostgREST.**

Confirmei no banco: o `auth.uid()` oficial do Supabase lê **dois** GUCs, nesta ordem:
1. `request.jwt.claim.sub` (GUC dedicado)
2. `request.jwt.claims` (GUC com o **JSON inteiro** do JWT)

O helper `fn_usuario_atual()` **replica exatamente** essa lógica (mesma ordem, mesmo `coalesce`, mesmo `nullif`). **Confirmado em funcionamento real** pelo e2e: o `usuario_id` gravado no `auditoria_log` via REST é **exatamente** o `sub` do JWT do auditor que fez a chamada.

Reforçei o helper com o `nullif` explícito no primeiro GUC (igual ao `auth.uid()` oficial) e documentei a comparação lado a lado.

**4. Teste de ponta a ponta com token real — `supabase/tests/e2e_rest.py`.**

**33/33 verificações verdes.** O teste **não** usa `set local role` nem GUCs simulados: faz **login de verdade** pela API de autenticação (GoTrue), pega o JWT e chama as funções e views pelo **endpoint REST**, como o front faria.

Cenários cobertos:

| # | Cenário | Resultado |
|---|---|---|
| 1–3 | Login por senha de 3 usuários (leitor A, auditor A, leitor B) | ✅ JWT traz `sub` = id do usuário |
| 4 | Leitor → `SELECT` em `lancamentos` | ✅ **HTTP 403** |
| 5 | Leitor → `SELECT` em `unidades` | ✅ HTTP 403 |
| 6 | Leitor → `SELECT` em `acesso_log` | ✅ HTTP 403 |
| 7–9 | Leitor → lê `v_resumo_competencia_fundo`, `v_cobertura_competencias`, `v_resultado_bruto` | ✅ HTTP 200, **sem coluna de unidade** |
| 10 | Leitor → `fn_resumo` com `'fundo'` | ✅ HTTP 200 |
| 11 | Leitor → `fn_resumo` com `'unidade'` | ✅ **HTTP 403** — "granularidade unidade nao permitida (permitida ate fundo)" |
| 12 | Leitor do A → `fn_resumo` do condomínio B | ✅ **HTTP 403** |
| 13 | Leitor → `fn_lancamentos` | ✅ HTTP 403 |
| 14 | Leitor → `fn_aprovar_staging` | ✅ HTTP 403 |
| 15–17 | Auditor → `fn_lancamentos`, detalhe com `unidade_id`, `fn_resumo` com `'unidade'` | ✅ HTTP 200 |
| 18–20 | Leitor do B → não vê o condomínio A (view, função, contestar) | ✅ **HTTP 403** / vazio |
| 21–23 | `anon` → tabela, view, função | ✅ **HTTP 401** |
| 24 | Auditor → `fn_atualizar_visibilidade` grava `usuario_id` correto | ✅ via `fn_auditoria_log` |
| 25–27 | Leitor → log de auditoria e log de acesso | ✅ HTTP 403 |

O e2e foi **integrado ao runner** (`run_tests.ps1`), então `supabase db reset` → bootstrap → runner agora dá **86 testes** (53 pgTAP + 33 e2e).

**5. DOIS BUGS REAIS DE SEGURANÇA encontrados e corrigidos.**

O e2e expôs o que a bateria pgTAP não pegava: **9 RPCs validavam a EXISTÊNCIA do registro ANTES de validar o PAPEL do chamador.**

```
antes:  leitor → fn_aprovar_staging(uuid_aleatorio)
        → "importacao inexistente" (P0002)
depois: leitor → fn_aprovar_staging(uuid_aleatorio)
        → "somente auditor pode aprovar importacao" (42501) → HTTP 403
```

**Por que isso é uma falha de segurança:** o tipo de erro **revela se o registro existe** — permite enumerar importações, lançamentos, duplicatas, transferências, contestações e anexos por id, mesmo sem permissão. E como o PostgREST traduz `42501 → HTTP 403` mas `P0002 → HTTP 500`, o também era observável na resposta.

Corrigido em **9 RPCs** (`fn_aprovar_staging`, `fn_classificar_lancamento`, `fn_decidir_duplicata`, `fn_confirmar_transferencia`, `fn_reconciliar_competencia`, `fn_contestar_lancamento`, `fn_responder_contestacao`, `fn_liberar_anexo_para_leitor` e `fn_atualizar_visibilidade`): agora o papel é avaliado **antes** da existência, e a inexistência devolve **o mesmo erro** de falta de permissão.

**6. Leitura de log por função, não por SELECT direto.**

O e2e mostrou que o `auditoria_log` era inacessível a **todos** por SELECT direto — inclusive o auditor, o que contradizia a matriz de privilégios do `MODELO_DADOS.md`. Adicionei `fn_auditoria_log` e `fn_acesso_log`:privileged, filtrando por papel. O leitor continua recebendo **403** (não lista vazia), e o auditor lê o log pela função.

**7. `docs\DEPLOY_REMOTO.md`** — roteiro de implantação remota, com:
- as **5 diferenças** entre local e hospedado (D1–D5);
- o **teste do passo 1**: se o `postgres` hospedado pode criar role com `BYPASSRLS` (com o **plano B** detalhado: `postgres` como dono, com os 3 pontos de edição e a tabela de impacto);
- o **bootstrap remoto** (o que o `postgres` PODE fazer — e o que ele **não** pode: zerar os default privileges do `supabase_admin`, conceder no schema `auth`);
- `db push` com **dry-run** (`supabase db diff --linked`), a ordem de aplicação e a tabela de dependências;
- validação pós-push: **teste de drift de grants** (T41–T46) e **e2e com usuários reais**;
- o que configurar no painel: cadastro público **desativado**, schemas expostos (`public` apenas — **não** `auth`), região, pooler, storage, e o que **não** configurar (analytics/Sentry com dado em trânsito);
- checklist de aceite e a lista do que **não** fazer.

**8. `docs\PLANO_FASE1.md`** — plano (sem código) da Fase 1:
- ordem de construção em **11 etapas**, do esqueleto à série histórica;
- fixtures **sintéticas** para os 8 layouts (geradas por script — **nenhum arquivo real no repositório**);
- a regra de ouro: **dado real só no Supabase local**, com o passo decisivo de `db reset` + reimportação como teste de determinismo;
- a tela mínima de conferência;
- a primeira conciliação por fundo, com o critério de aceite (diferença R$ 0,00 por fundo, e as pendências restantes sendo todas de rubrica);
- riscos e sequências de entrega em 7 sprints.

### Decisões do usuário registradas

| # | Decisão |
|---|---|
| D41 | Repositório remoto: https://github.com/andreperez27/Anperez_condominios.git |
| D42 | Projeto Supabase remoto: `aejuoiwxzzsxmhhizwau` |
| D43 | O usuário executa `supabase login`, `link` e `db push` no próprio terminal — **nenhum token ou senha deve ser pedido ou usado por mim** |
| D44 | Logo em `front/public/logo.png` está correto |
| D45 | `pgaudit` será verificado no painel |

### Estado atual

- **86 testes verdes** (53 pgTAP + 33 e2e com token real).
- **Dois bugs de segurança corrigidos** (ordem papel/existência em 9 RPCs; leitura de log por função).
- **2 documentos novos**: `DEPLOY_REMOTO.md` e `PLANO_FASE1.md`.
- **Nada foi aplicado no remoto.** O `supabase link` **não** foi executado (não tenho token, e você vai executá-lo).
- **Nenhum dado real** foi lido, copiado ou gravado. A pasta antiga segue com 586 arquivos e 0 modificados.
- **O Anperez Money segue intocado** (0 arquivos modificados).

### Pendências

1. **A varredura encontrou dado real nos docs** (40 valores, 3 números de NF, 115 nomes de arquivo). Confirme que o repositório remoto é **privado** — ou me diga se prefere que eu sanitize os docs antes do push.
2. **Rodar o teste do §3.1 do roteiro** (o `postgres` hospedado cria role com `BYPASSRLS`?) e me passar a saída. Se falhar, ativo o plano B.
3. **Rodar o bootstrap remoto** (§3.2) e me passar a saída — especialmente o passo 3 (conceder no schema `auth`), que é esperado que **falhe**.
4. **`pgaudit`** — me avise quando verificar no painel.

---

## 2026-11-12 — Etapa 4: correções no roteiro de implantação e endurecimento da bateria

### Contexto

O usuário leu o `DEPLOY_REMOTO.md` e o `PLANO_FASE1.md` e aprovou o plano da Fase 1
(primeira competência 2026-10, CLI antes de tela, copiar 1 extrato + 1 balancete,
uma competência só, aprovação só do usuário). Pediu 7 correções objetivas no roteiro
e nos scripts, e mandou **parar para revisão** depois de rodar a bateria local.

### O que foi feito

**1. Teste de drift de grants (T41–T46) reescrito como autocontido.**

O arquivo `supabase/tests/05_drift_grants.test.sql` foi reescrito do zero:

- **Não depende mais de `00_preparacao.test.sql`** — não cria usuário, não cria
  condomínio, não insere/altera/apaga nada. É só `SELECT`.
- **Não depende de pgtap** — usa SQL puro com `RAISE EXCEPTION`, para poder rodar
  no remoto com o mesmo arquivo.
- **Lê a lista permitida do próprio banco**, na tabela nova
  `public.config_grants_permitidos` (migration `20261111001600`), em vez de tê-la
  hardcoded no arquivo de teste.
- Roda **no local e no remoto sem adaptação**.

O runner (`supabase/tests/run_tests.ps1`) foi ajustado: os `.test.sql` com pgtap
continuam numa bateria, e o teste de drift passou a ser uma bateria separada de
verificações autocontidas (contadas por `NOTICE: OK`).

**2. Nova migration `20261111001600_fase0_lista_grants_permitidos.sql`.**

Cria `public.config_grants_permitidos` (tabela de **configuração**, não de dado de
condomínio) com a lista do que `anon` e `authenticated` **podem** ter: `SELECT` em
2 tabelas de configuração (`granularidade_ordem`, `perfis`) + a própria
`config_grants_permitidos`, e em 14 views agregadas. `anon` não tem **nada**.

Isso inverte a dependência: antes a lista vivia no seed de teste; agora vive numa
migration versionada, é auditável por SQL, e o teste de drift lê dela.

A tabela tem RLS ligado e forçado, `revoke` triplo (`public`, `anon`,
`authenticated`) e `grant select` apenas para `authenticated`.

**3. §5.1 do roteiro corrigido** — não manda mais rodar `00_preparacao.test.sql`
no remoto (ele criaria usuários com a senha fixa `teste12345` em produção). O
bloco agora mostra só o `05_drift_grants.test.sql`, com o pooler em modo sessão.

**4. §3.1 do roteiro corrigido** — acrescentada a verificação do `rolbypassrls` do
role `postgres` **hospedado**, antes de qualquer decisão de plano, com a leitura
do resultado em tabela (`t` → plano A; `f` → plano B). O **plano B ficou
condicional**: ele só vale se o `postgres` hospedado tiver `rolbypassrls = true`.
Se não tiver, o `postgres` não pode ser o dono de objetos privilegiados (com
`FORCE ROW LEVEL SECURITY` o owner se sujeita às próprias policies, e as funções
`SECURITY DEFINER` passariam a depender delas — exatamente o que o modelo evita).
 nesse caso, as saídas são B1 (pedir ao Supabase), B2 (`supabase_admin` como owner)
ou B3 (recuar as funções privilegiadas). A frase "superuser-ish" foi removida.

**5. Criação do `app_owner` idempotente** (migration `20261111000200`).

O roteiro pede que o role seja criado **antes** do `db push` (para testar se o
ambiente permite `BYPASSRLS`). A migration agora:

- se o role não existe → `create role app_owner nologin bypassrls`;
- se existe **sem** `bypassrls` → `alter role app_owner bypassrls`, e, se o
  ambiente não permitir, levanta exceção com a mensagem apontando o **plano B**
  (com o caminho do §3.1 do roteiro);
- se existe **com** `bypassrls` → não faz nada.

Ou seja: reaplicar a migration nunca falha por causa do role, e o atributo
`BYPASSRLS` fica **garantido** (sem ele, as funções privilegiadas dependeriam das
policies — o que o modelo evita).

**6. Bootstrap remoto (`01-zerar_privilegios_remoto.sql`)** — o
`alter default privileges` do `postgres` passou a ser **sem** `in schema public`
(a forma sem cláusula de schema vale para todos os schemas — é o default do role;
com a cláusula, valeria só para `public` e um objeto criado em outro schema
herdaria o acesso). Acrescentada a **conferência em `pg_default_acl`**, que mostra
o estado depois dos revokes e marca com ⚠️ qualquer ACL que ainda conceda
`anon=`/`authenticated=`.

**7. §4.2 e §4.3 do roteiro corrigidos.**

- O **dry-run nativo existe**: confirmado em `supabase db push --help` (CLI
  2.107.0) → `--dry-run    Print the migrations that would be applied, but don't
  actually apply them.` O roteiro agora manda usar `supabase db push --linked
  --dry-run` (a afirmação anterior de que o CLI 2.x não tem dry-run estava errada).
- **`--include-all` retirado da primeira aplicação**: ele reaplica migrations já
  registradas no histórico remoto e mascararia a ordem real de aplicação. A
  §4.3 duplicada foi removida.
- `supabase db diff --linked` ficou como comparação extra (opcional).

**8. §5.3 do roteiro reescrita** — três acréscimos:

- **Pooler em modo SESSÃO (porta 5432)**, com a justificativa: no modo transação
  (6543) cada comando do `psql` roda em transação distinta, o `set_config` de
  sessão (o claim do JWT) pode ir para uma conexão e o comando seguinte para
  outra, e DDL/`DROP` são recusados.
- **Senhas fortes e exclusivas por usuário** no remoto (a `teste12345` do
  ambiente local não pode ir para produção), com a instrução de criar os
  usuários no painel com "Auto Confirm User" ligado.
- **Limpeza obrigatória ao final**: SQL para remover membros, unidades, condomínios
  e políticas de visibilidade de teste; apagar os 3 usuários no painel; e a
  conferência final (`auth.users` de teste = 0, condomínios de teste = 0,
  `public.lancamentos` = 0 — nenhum lançamento real deve ter subido).

**9. Comandos adaptados para PowerShell** — o roteiro inteiro foi convertido: os
`cd /c/Anperez_Condominios` viraram `Set-Location G:\Anperez_Condominios`, os
blocos ```bash viraram ```powershell, `export DATABASE_URL` virou
`$env:DATABASE_URL`, os `psql "$DATABASE_URL"` viraram `psql $env:DATABASE_URL`,
os `grep -Ei` viraram `Select-String -Pattern`, e os `&& echo` viraram
`if/else` com `Write-Host`. Não sobrou nenhum bloco bash nem nenhum `grep` no
documento.

### Retomada (12/11/2026) — revisão das 7 correções

O pedido das 7 correções foi reenviado. Na auditoria, **duas alterações do §3.1
tinham se perdido** (o script que as aplicava abortou antes de gravar o arquivo):

- o §3.1 ficou **sem a verificação do `rolbypassrls` do `postgres` hospedado**;
- o §3.1 ficou **sem a marcação de que o plano B só vale com `BYPASSRLS`**;
- o §5.1 ficou sem a lista explícita do que o teste de drift **não** faz.

Corrigido e **verificado por um verificador automatizado** (37 checagens sobre o
documento e os scripts, depois refinado para 45 com distinção entre *menção em
prosa* e *comando que executa*):

| Item | Verificação |
|---|---|
| 1 | O drift não depende de pgtap, não cria usuário, não cria dado (só `SELECT`), não invoca `00_preparacao`, e lê a lista do próprio banco. O §5.1 tem **um único** comando `psql` — o do drift — e manda **não** rodar `00_preparacao` |
| 2 | O §3.1 checa `rolbypassrls` do `postgres`, tem a tabela de leitura do resultado (`t`→A, `f`→B), marca o plano B como **CONDICIONAL** e traz as saídas B1/B2/B3. A frase "superuser-ish" não existe mais no documento |
| 3 | A migration `00200` cria o `app_owner` só se não existir, garante `bypassrls` e, se o ambiente negar, aponta o plano B |
| 4 | Os dois bootstraps revogam nas **duas formas** (global e `in schema public`) e têm a conferência em `pg_default_acl` |
| 5 | O §4.2 usa o `--dry-run` nativo; o §4.3 aplica `supabase db push --linked` **sem** `--include-all`; nenhum comando do documento usa a flag |
| 6 | O §5.3 tem pooler em modo sessão (5432) com a justificativa do 6543, senhas fortes, limpeza obrigatória (SQL + painel + conferência) |
| 7 | Caminho `G:\Anperez_Condominios`, `Set-Location`, zero bloco `bash`, zero `grep -Ei`, zero `export DATABASE_URL` |

### Decisões técnicas

| # | Decisão |
|---|---|
| D46 | A lista de grants permitidos passa a ser **dado versionado** (migration), não seed de teste. Motivo: só assim o teste de drift roda no remoto sem depender de nada |
| D47 | O teste de drift é **SQL puro com `RAISE EXCEPTION`**, sem pgtap. Motivo: pgtap não está instalado no projeto hospedado, e o teste precisa ser executável lá |
| D48 | O `alter default privileges` do bootstrap é feito **sem** `in schema public`, por valer para todos os schemas |
| D49 | O `app_owner` criado manualmente antes do `db push` é corrigido pela migration (ganho de `bypassrls`), não apenas tolerado |
| D50 | Dry-run nativo do CLI (`--dry-run`) passa a ser o mecanismo oficial de conferência antes do `db push`; `--include-all` fica proibido na primeira aplicação |
| D51 | Toda função criada pelo projeto (inclusive os helpers de teste) precisa do **revoke triplo** (`public`, `anon`, `authenticated`). Função que herda o `EXECUTE` do `PUBLIC` é alcançável pelo `anon` |
| D52 | O teste de drift é uma **bateria autocontida à parte**, fora do pgTAP: assim ele roda no remoto sem instalar extensão nem criar usuário |
| D53 | Os default privileges são revogados nas **duas formas** (global e `in schema public`), porque o Postgres aplica as duas entradas a um objeto novo |
| D54 | O T46 confere apenas o escopo do projeto (`public` + entrada global). Schemas do Supabase (`supabase_functions`) ficam fora: revogá-los quebraria as Edge Functions |

### Achados do novo teste de drift (e correções)

O teste de drift, ao ser reescrito como autocontido, **pagou o custo**:

1. **`config_grants_permitidos` acusada como "SOBRA o privilégio"** — a própria
   tabela da lista ainda não estava na lista. Corrigido: ela é configuração
   legítima e entrou na lista permitida.
2. **Default privileges do `supabase_admin`** — acusados pelo T46 (concedem
   `anon`/`authenticated` em tabelas, funções e sequências). É exatamente o
   que o bootstrap resolve; o teste passa depois dele.
3. **Falha real de privilégio nos helpers de teste** — `test_cond_a()` e
   `test_cond_b()` (criados por `00_preparacao.test.sql`) tinham o `EXECUTE`
   herdado do `PUBLIC`, ou seja, o `anon` (não logado) podia chamá-los e
   descobrir o id do condomínio de teste. Corrigido com o **revoke triplo**
   (`public`, `anon`) e `grant execute ... to app_owner` (o `app_owner` é o dono
   das funções `SECURITY DEFINER` de teste, que chamam esses helpers).
4. **Contagem errada no runner** — o PowerShell embrulha a saída de stderr do
   `psql` em `ErrorRecord`, e a formatação padrão injeta a palavra "ERROR"
   mesmo quando o teste passou. O runner agora converte com `.ToString()` e
   conta `^NOTICE: OK` / `^ERROR`.
5. **Default privileges: são DUAS entradas, não uma** — o Postgres guarda os
   default privileges em uma entrada **global** (sem cláusula de schema) e
   outra **por schema** (`in schema public`), e as duas são aplicadas a um
   objeto novo. Revogar só a global **não** limpa a entrada por schema.
   Por isso os dois bootstraps (local e remoto) agora revogam **nas duas
   formas**. O T46 passou a conferir as duas (namespace `public` **ou** a
   entrada global), com o scope explícito: schemas do próprio Supabase
   (ex.: `supabase_functions`) ficam de fora, porque revogar os default
   privileges deles quebraria as Edge Functions.

### Estado atual

- **87 testes verdes**, **BUILD OK**:
  - 47 pgTAP (`00_preparacao` + 4 baterias),
  - 7 verificações autocontidas de drift de grants,
  - 33 e2e (API REST com token real).
- **17 migrations** (era 16).
- **7 correções de segurança** cobertas por verificação: lista real × lista
  permitida, T41 (nenhuma tabela de detalhe com privilégio), T43 (`anon` sem
  privilégio nenhum no `public`), T44 (`anon` não executa função pública),
  T45 (`anon` não executa `SECURITY DEFINER` pública), T46 (nenhum default
  privilege concede acesso a `anon`/`authenticated`).
- O teste de drift agora **acumula todas as falhas** numa única exceção (em vez
  de parar na primeira), então uma execução contra o remoto mostra a lista
  completa do que está errado.
- **Teste negativo do drift (feito de propósito, e revertido):**
  - `grant select on public.lancamentos to authenticated` → o teste acusou
    `[T41] lancamentos / authenticated / SELECT`;
  - `create table public.teste_deriva` + `grant select to authenticated` → o
    teste acusou `[LISTA PERMITIDA x LISTA REAL] teste_deriva / authenticated
    / SELECT (SOBRA o privilegio)`.
  Ou seja: o teste **não** é vacuoso — detecta o drift nos dois sentidos.
- **Nada foi aplicado no remoto.** O `supabase link` continua não executado; o
  roteiro continua sendo executado por você, no seu terminal.

### Pendências

1. **Varredura de dado real nos docs (prioridade):** a varredura encontrou **40
   valores reais**, **3 números de NF** (109, 118, 130) e **115 nomes de arquivo
   reais** citados nos documentos. Nada disso foi para o remoto, e o
   `.gitignore` bloqueia `*.xls`, `*.xlsx`, `*.pdf`, `*.csv` — mas **os docs são
   a exceção explícita**. Antes do `git push`, confirme se o repositório remoto é
   **privado** ou me mande sanitizar os docs.
2. **Saída do §3.1 no projeto hospedado:** o `select rolname, rolsuper,
   rolbypassrls, rolcanlogin from pg_roles where rolname in (...)`. Preciso
   dela para confirmar o plano A (ou ativar o B).
3. **Saída do bootstrap remoto (§3.2):** em especial o **passo 3**, que é
   esperado que **falhe** (conceder no schema `auth`).
4. **`pgaudit`** — me avise quando verificar no painel.
---
## 2026-11-12 - Etapa 5: ajustes do teste remoto (plano A, T46 com escopo, REVOKE explicito, auditor estatico)

**Gatilho:** o usuario rodou a verificacao do §3.1 no projeto hospedado
(`aejuoiwxzzsxmhhizwau`) e pediu 4 ajustes. Resultado do teste remoto:

- `postgres` hospedado: `rolbypassrls = true`, `rolsuper = false`;
- `app_owner` criado com sucesso no remoto (nologin, bypassrls, sem super)
  => **plano A CONFIRMADO; plano B NAO e necessario**;
- `pg_default_acl` remoto: **nenhum default global** (todos por schema).
  Defaults que concedem acesso a `anon`/`authenticated`: `postgres` em
  `public` (tabelas/funcoes/sequences) e `supabase_admin` em `public`,
  `graphql`, `graphql_public`. Defaults de `storage`, `graphql`,
  `graphql_public` sao internos da plataforma — nao alterar.

**Decisoes:**

| #  | Decisao |
|---|---|
| D55 | Os defaults do `supabase_admin` sao **risco residual aceito**: ele nao cria nenhum dos nossos objetos (migrations rodam como `postgres`) e o T42 continua conferindo os GRANTS REAIS. Ajusta-los exigiria o Dashboard |
| D56 | Toda migration que cria objeto passa a ter **REVOKE explicito na propria migration** ("defesa em profundidade"): o objeto nasce fechado, sem depender de varredura dinamica posterior |
| D57 | A regra do D56 e imposta por **auditor estatico** (`supabase/tests/audita_migrations.py`), que falha o build: varre as migrations e exige revoke de `anon`+`authenticated` (e `public` nas funcoes) na mesma migration que cria o objeto |
| D58 | O T46 tem **escopo parametrizado** (`estrito` = local: postgres + supabase_admin + app_owner; `postgres` = remoto: so postgres + app_owner), passado por variavel psql `-v escopo_t46` |
| D59 | Defaults dos schemas internos da plataforma (`storage`, `graphql`, `graphql_public`, `supabase_functions`) **nao sao alterados** em nenhum ambiente |
| D60 | Desativar o `pg_graphql` no painel virou **passo opcional** do roteiro (§7.7): o app nao usa GraphQL |

**Ajustes feitos:**

1. **Migration 01400 (RPCs):** 16 revokes explicitos inseridos (assinaturas
   qualificadas `public.`), logo apos a varredura dinamica, com comentario
   explicando a defesa em profundidade.
2. **Migration 00260:** `fn_usuario_atual` ganhou `authenticated` no revoke
   (antes so `public, anon` — o auditor acusou).
3. **Migration 01000:** `fn_purgar_acesso_log` (SECURITY DEFINER que APAGA
   log!) e `fn_log_escrita` ganharam revoke+grant explicitos na secao GRANTS.
   **Janela real de exposicao fechada:** ate entao o fechamento da
   `fn_purgar_acesso_log` so acontecia na migration 01200, posterior.
4. **Auditor estatico criado:** `supabase/tests/audita_migrations.py` —
   18 migrations, 77 objetos verificados, PASSANDO. Tambem proibe GRANT a
   `anon` em qualquer migration.
5. **T46 com escopo:** `05_drift_grants.test.sql` — cabecalho documentando o
   por que (o `postgres` hospedado nao pode alterar default privileges de
   outro papel), bloco psql `\if :{?escopo_t46}` +
   `set_config('app.t46_escopo',...)`, filtro
   `pg_get_userbyid(d.defaclrole) = any(v_papeis)`.
6. **Bootstrap remoto (01-zerar_privilegios_remoto.sql):** conferencia do §6
   reescrita com as 3 categorias — limpo / risco residual aceito /
   schema interno da plataforma. Comentario do §1 alinhado. Sintaxe
   validada localmente em transacao com rollback.
7. **DEPLOY_REMOTO.md:** §0.1 com o resultado da verificacao remota (plano A
   confirmado), D1 marcado como resolvido, §3.1 marcado como executado (plano
   B arquivado como registro), §3.2 alinhado, §5.1 com o comando
   `-v escopo_t46=postgres` e a tabela do escopo, §7.7 novo (pg_graphql
   opcional).
8. **Runner:** `run_tests.ps1` agora roda a auditoria estatica antes do e2e
   (conta como 1 verificacao).

**Enigma do `%s` no RAISE NOTICE (resolvido):** o T46 imprimia
`escopo estritos` (um `s` a mais). NAO e artefato do PowerShell: no
`RAISE` do PL/pgSQL o placeholder e o `%` **sozinho**; `%s` imprime o valor
seguido do `s` literal. Ja o `format()` usa `%s` mesmo. Corrigido o
`raise notice` do T46 para `(escopo %)`. Prova: `raise notice 'W %', v`
imprime certo; `raise notice 'X %s', v` imprime valor + `s`.

**Estado atual:**

- **88 testes verdes, BUILD OK** (47 pgTAP + 7 drift + 1 auditoria estatica
  + 33 e2e);
- 18 migrations, EOL conferido (repo CRLF; LF solto e CR orfao da insercao
  no 01400 corrigidos);
- Nada aplicado no remoto alem do `app_owner` (feito manualmente, coberto
  pela migration idempotente 00200).

**Pendencias:**

1. **REVISAO DO ROTEIRO PELO USUARIO antes de qualquer execucao no remoto**
   (db push, bootstrap remoto, seed).
2. Varredura de dado real nos docs (valores R$, NFs 109/118/130, nomes de
   arquivo) — confirmar repositorio privado ou sanitizar.
3. `pgaudit` — verificar no painel.
4. Sincronizar a copia do roteiro em `C:\Users\andre\.opencode\plan\`.
---
## 2026-11-12 - Etapa 6: recuperaçao de encoding, limpeza do e2e testada, roteiro a 18 migrations

**Gatilho:** o usuario leu o DEPLOY_REMOTO.md e encontrou dupla codificaçao
UTF-8 (padrao: a-til+cedilha, e-agudo+euro, etc.). Pediu 4 correçoes antes de executar qualquer coisa
no remoto.

### 1. Como o arquivo foi corrompido (CAUSA EXATA)

No fim da Etapa 5, a reordenaçao do §7.7 foi feita com PowerShell:

```powershell
$t = Get-Content "docs\DEPLOY_REMOTO.md" -Raw        # <-- AQUI
Set-Content "docs\DEPLOY_REMOTO.md" -Value $t2 -NoNewline -Encoding UTF8
```

- O arquivo era UTF-8 **sem BOM**. O `Get-Content -Raw` do **Windows
  PowerShell 5.1, sem `-Encoding`, le arquivos sem BOM como ANSI (cp1252)**.
  O texto entrou na memoria JA corrompido (cada byte UTF-8 virou um char
  cp1252).
- O `Set-Content -Encoding UTF8` gravou de volta o mojibake — e ainda
  adicionou BOM.
- Resultado: dupla codificaçao UTF-8 -> cp1252 -> UTF-8.

**REGRA (para valer daqui em diante):**

> Escrever arquivos SEMPRE em UTF-8 sem BOM. No Windows PowerShell 5.1,
> NUNCA usar `Get-Content`/`Set-Content` para ler/regravar arquivo de texto
> sem BOM: o `Get-Content` sem `-Encoding` le como cp1252 e corrompe. Para
> editar arquivo existente: ou o agente usa as ferramentas de arquivo (que
> preservam UTF-8), ou Python `open(..., 'rb'/'wb')` com decodificaçao
> UTF-8 explicita. Se for inevitavel usar PowerShell, usar
> `-Encoding UTF8` no Set-Content **e** `Get-Content -Encoding UTF8` (ou
> `-Raw -Encoding utf8`) — e conferir com varredura depois.

Como a recuperaçao foi feita: cada char do arquivo corrompido nasceu de UM
byte cp1252; mapeando char -> byte cp1252 (controles C1 0x80-0x9F por
identidade, como o .NET faz) e decodificando o resultado como UTF-8, o
texto original voltou integralmente (nenhum char perdido). Conferido por
assoinatura de bytes (0 mojibake) e por marcadores das ediçoes da Etapa 5.

**Lição sobre detecção:** o detector de round-trip
(`s.encode('cp1252').decode('utf-8')`) FALHA quando o texto corrompido
contem controles C1 (o encode cp1252 estoura antes de fechar o round-trip).
O detector confiavel é a **varredura de assinaturas de bytes** (ex.:
`C3 83 C2 A7` = "a-til+cedilha"). As duas tecnicas ficam documentadas em
`supabase/tools/varre_encoding.py` (a rodar com Python puro, sem deps).

### 2. Varredura de encoding em TODO o repositorio

- **42 arquivos de texto** (.md, .sql, .py, .ps1, .json) varridos: só o
  `docs/DEPLOY_REMOTO.md` estava corrompido (77 "a-til+cedilha", 169 "a-til+a-til", 78 "a-til+e-agudo",
  26 "a-til+i-agudo", 44 "a-til+o-agudo", 9 "a-til+u-agudo"...) — **e a copia sincronizada em
  `C:\Users\andre\.opencode\plan\DEPLOY_REMOTO.md`**. Ambos recuperados.
- Os outros 41 estao em UTF-8 sem BOM, sem mojibake. Nada corrompido
  no Git ainda (`07c861c` levou o arquivo corrompido, mas a recuperaçao
  vem antes do proximo commit).
- **seed.sql: 100% ASCII** (convençao do projeto: nomes de dados sem
  acento — "Condominio Residencial Exemplo" etc.). **Migrations: acentos
  so em COMENTARIOS** (cabecalhos "MIGRATION 002 — FASE 0: CONDOMINIOS"),
  nunca em identificadores, labels de enum ou dado. **Banco local
  conferido: 100% ASCII** em fundos, rubricas, aliases, contas, enums e
  unidades. Nao existe nome com acento que possa ir corrompido ao banco.
- **.ps1 com acento e sem BOM**: o PS 5.1 tambem le script sem BOM como
  ANSI (comentarios/strings viram mojibake na execuçao). Como a regra é
  UTF-8 sem BOM, `reset_local.ps1` e `run_tests.ps1` foram
  **transliterados para ASCII puro** (so comentarios e mensagens).

### 3. Limpeza do §5.3.5 testada no local (2 bugs reais encontrados)

Rodou-se e2e 33/33 e a limpeza do roteiro, como escrita. Resultado:

1. **Bug 1:** `delete from unidades` violou `lancamentos.unidade_id` (NO
   ACTION) — o e2e cria 14 lançamentos apontando para unidades.
2. **Bug 2:** apagar o condominio direto tambem viola
   `lancamento_rubrica.fundo_id -> fundos` e
   `fontes_importacao.competencia_id -> competencias` (NO ACTION): o
   CASCADE apaga os pais em ordem indefinida, com os filhos ainda vivos.

**Correção (nova ordem FK-segura, testada):** membros -> negocio de folha
para raiz (anexos, conciliaçao, classificaçao, transferencias, duplicatas,
documentos, contestaçoes, pendencias, lançamentos, grupos, staging,
importaçoes/fontes, status/competencias, série, contas, aliases, rubricas,
fundos, unidades, config) -> **logs** (`auditoria_log` e `acesso_log`, por
condominio E por usuario de teste) -> convites -> condominios por ultimo.
Depois: apagar os 3 usuarios no painel (`perfis -> auth.users` é CASCADE e
nada mais referencia os perfis).

**Conferencia final no local (TUDO 0):** usuarios de teste em auth.users,
perfis, membros, condominios de teste, unidades, config_visibilidade,
lancamentos, anexos, **auditoria_log (0)** e **acesso_log (0)** — sem
rastro, sem FK quebrada. O §5.3.5 do roteiro foi reescrito com a ordem
correta, o aviso de ordem, e a conferencia final inclui os dois logs.
§5.4 ganhou o item "limpeza com rastro zero, inclusive logs".

### 4. Roteiro e checklist a 18 migrations; §7.1 ajustado

- §0, §4.4 (tabela ganhou a linha 18 `01600_lista_grants_permitidos`) e
  §5.4 atualizados para **18 migrations**.
- §7.1: "Password strength" (minimo 12 caracteres) marcado como **controle
  principal**; "Leaked password protection" marcado como **"se disponivel
  no plano"** (proteçao complementar).

**Estado atual:** **89 testes verdes, BUILD OK** (47 pgTAP + 7 drift +
1 auditoria estatica de migrations + 1 varredura de encoding + 33 e2e) —
a varredura de encoding entrou no runner (`run_tests.ps1`), com o
varredor versionado em `supabase/tools/varre_encoding.py`. Roteiro
recuperado e sincronizado com a copia em `C:\Users\andre\.opencode\plan\`.

**Pendencias:** (mantidas da Etapa 5) revisao do roteiro antes de executar
no remoto; varredura de dado real nos docs; pgaudit no painel.
---
## 2026-11-12 - Etapa 7: matriz view x papel e funcao x papel (LOCAL), 2 RPCs que nunca funcionaram + 3 mitigacoes; limiar/granularidade nas views; bateria a 220

**Gatilho:** o db push no remoto foi aplicado (18 migrations, conferido pelo
usuario). Antes de usar o remoto, montaram-se as matrizes view x papel e
funcao x papel no LOCAL com dados ficticios completos, automatiza-las na
bateria, avaliar o revoke do SELECT de config_grants_permitidos, documentar —
e parar para revisao. Nada foi aplicado no remoto.

### 1. Fixture da matriz (00_preparacao)

Nova funcao `test_criar_fixture_matriz()` (chamavel pelo runner apos as
fixtures lancamentos/cond_b): persona conselho_fiscal (conselho@condA.test),
2 pendencias (uma ligada a unidade 11), 2 conciliacoes (CC divergente com
observacao; BENF conciliada), 2 contestacoes (sindico e auditor), 2 linhas
de serie historica, status_competencia com observacao. Idempotente.

### 2. Matriz view x papel (14 views, 6 personas) — resultado medido

Linhas devolvidas (dados ficticios do fixture):

| View | leitor | auditor | sindico | conselho | leitor B | sem vinculo |
|---|---|---|---|---|---|---|
| v_resumo_competencia_fundo | 2 | 2 | 2 | 2 | 0 | 0 |
| v_resumo_competencia_rubrica | 0 (gate) | 3 | 3 | 3 | 0 | 0 |
| v_resultado_bruto | 1 | 1 | 1 | 1 | 0 | 0 |
| v_resultado_liquido | 1 | 1 | 1 | 1 | 0 | 0 |
| v_resultado_liquido_por_fundo | 1 | 1 | 1 | 1 | 0 | 0 |
| v_cobertura_competencias | 4 (obs. NULL) | 4 | 4 | 4 | 4 (obs. NULL) | 0 |
| v_conciliacao | 2 (obs. NULL) | 2 | 2 | 2 | 0 | 0 |
| v_pendencias_resumo | 2 | 2 | 2 | 2 | 0 | 0 |
| v_serie_historica | 0 (gate) | 2 | 2 | 2 | 0 | 0 |
| v_importacao_resumo | 1 | 1 | 1 | 1 | 1 | 0 |
| v_transferencias_internas | 0 | 1 | 0 | 1 | 0 | 0 |
| v_duplicatas_candidatas | 0 | 1 | 0 | 0 | 0 | 0 |
| v_lancamentos_com_duplicata | 0 | 14 | 0 | 0 | 0 | 0 |
| v_contestacoes | 0 | 2 | 2 | 2 | 0 | 0 |

Observacoes finais:
- o leitor NAO recebe linha de detalhe nem coluna de unidade; as 4 views de
  detalhe devolvem 0 linhas para ele;
- o observacao (texto livre do auditor) chegava ao leitor em v_conciliacao
  e v_cobertura_competencias ("unidade 11 nao enviou extrato") — vazamento
  corrigido (so papel nominal ve);
- o limiar era IGNORADO nas views (a celula Multas, 2 unidades, R$ 30,00,
  chegava ao leitor mesmo com limiar 5) — corrigido;
- v_resumo_competencia_rubrica e v_serie_historica expostas ao leitor mesmo
  com granularidade_max = 'fundo' — corrigido (gate de granularidade).

### 3. Matriz funcao x papel (21 funcoes executaveis por authenticated) — achados

Dois RPCs estavam quebradas para QUALQUER chamador (o caminho feliz nunca
executou em ambiente nenhum) e uma escrita nao tinha permissao:

1. **fn_aprovar_staging** — literais de enum sem cast em INSERT ... SELECT
   ("criterio is of type criterio_duplicata but expression is of type
   text"): a importacao NUNCA funcionou. VALUES coerciona literal; SELECT
   nao. Corrigido com casts explicitos.
2. **fn_reconciliar_competencia** — "on conflict (competencia_id, fundo_id)"
   ambiguo vs RETURNS TABLE; e coalesce(diferenca_creditos, 0) no UPDATE
   comparava a VARIAVEL de retorno (NULL) em vez da coluna. Corrigido com
   "on conflict on constraint conciliacoes_unica" e qualificadores c.
3. **fn_registrar_pendencia** — SEM nenhuma validacao de papel: qualquer
   autenticado gravava pendencia em QUALQUER condominio (escrita
   cross-tenant). Agora exige auditor no condominio pedido.
4. **fn_responder_contestacao** — typo "entidad" no INSERT em auditoria_log:
   42703 para qualquer chamador. Corrigido.
5. **fn_gerar_url_anexo** — (a) id inexistente devolvia P0002, enumerando
   existencia de anexo; agora 42501 uniforme. (b) chamava
   storage.create_signed_url(), funcao que NAO EXISTE no schema storage
   (URLs assinadas sao da Storage API, fora do Postgres). Reescrita como
   porteiro: valida a permissao, registra o acesso e devolve o CAMINHO; a
   URL assinada sera criada no front pelo supabase-js (a policy de
   storage.objects ja autoriza). Contrato muda (returns text = caminho) —
   aceito porque nao ha front ainda; revisar no desenvolvimento.
6. Todas reforcadas com papel ANTES da existencia: papel insuficiente recebe
   SEMPRE 42501, inclusive com ids falsos (regra de uniformidade, sem vazar
   existencia de registro).

### 4. Correcoes em migrations novas (nenhuma migration antiga editada)

- 20261112001700_fase0_rpc_permissao.sql: itens 1-5 acima.
- 20261112001800_fase0_views_limiar.sql: gate de granularidade
  (rubrica/serie), limiar lido de config_visibilidade nas colunas de
  dinheiro (0 < unidades < limiar -> NULL + suprimido=true), observacao so
  para papel nominal. Create or replace preserva as colunas e adiciona
  qtd_unidades/suprimido nas views de dinheiro; "create or replace" das
  views, com REVOKE/GRANT reemitidos.
- 20261112001900_fase0_revoga_grants_permitidos.sql: authenticated sem
  NENHUM privilegio na config_grants_permitidos (a 016 ganhou a remocao da
  linha e do grant para builds do zero). O drift continua lendo como
  postgres; a policy foi apagada.
- 01600 editada para build limpo (remove linha + policy + grant).

### 5. Automatizacao — bateria a 220

- 06_matriz_views.test.sql (55 verificacoes): as 14 views x 6 personas,
  com o limiar testado (auditor limiar 5 temporario -> celula Multas
  suprimida; restaurado limiar 0), observacao mascarada para o leitor,
  cross-tenant B, sem vinculo, e colunas de v_pendencias_resumo.
- 07_matriz_funcoes.test.sql (76 verificacoes): as 21 funcoes x 6 personas,
  incluindo erro uniforme para papel insuficiente com id falso, e os
  caminhos felizes (fn_aprovar_staging, fn_reconciliar_competencia,
  fn_gerar_url_anexo, fn_responder_contestacao passam apos as correcoes).
- 00_preparacao.test.sql: test_criar_fixture_matriz() (grants refeitos para
  pendencias/conciliacoes/contestacoes/status_competencia/serie) e runner
  atualizado.
- Resultado: 220 verdes, BUILD OK (55+76 pgTAP + drift 7 + auditoria de
  migrations + encoding + 33 e2e).

### 6. Teste remoto colatil — 05_drift_grants_remoto.sql

Versao T41-T46 com ESCOPO FIXO no T46 (postgres + app_owner), SEM variaveis
do psql, somente leitura (uma tabela TEMPORARIA de sessao), resultado em
tabela ok/falha por teste + tabela de resumo. Testavel localmente (rodou 6/6
ok). Documentado no DEPLOY_REMOTO.md §5.1.1 (SQL Editor) — §5.1.2 mantem o
psql como alternativa.

### 7. Seed FORA do remoto (decisao do usuario, 12/11/2026)

- §4.5 reescrito: o seed NUNCA sobe; o condominio real + membros entram por
  um script de inicio separado, quando o importador estiver validado no
  local.
- §5.2/§5.3 adiados (sem dados no remoto); §1.2 e §8 (fluxo rapido)
  atualizados; checklist §5.4 sem a linha de seed e com "21 migrations".
- Tabela §4.4: migrations 19, 20, 21 adicionadas (21 no total).

### 8. Documentacao

- SEGURANCA_RLS.md: nova secao §3.5 (matrizes medidas, correcoes,
  limitacoes e esclarecimentos); §3.2 com a linha de rubrica atualizada.
- DIARIO_DE_BORDO.md: esta entrada.

### 9. Em aberto (decisao do usuario; NAO alterado sem revisar)

- Sindico x v_transferencias_internas: view restringe a auditor+conselho;
  o §3.4 diz "R (proprio)" — decidir a superficie desejada.
- Conselho x duplicatas: o §3.4 aponta "fn_duplicatas", que nao existe;
  a view e auditor-only. Decidir.
- Contestacoes visiveis a auditor+sindico+conselho (todos os papeis
  nominais) — comportamento atual, registrado.
- fn_gerar_url_anexo mudou o contrato (devolve caminho): revisar no
  desenvolvimento do front (createSignedUrl + policy de storage).
- Varredura de dado real nos docs (42 valores R$, 3 NFs, 160 nomes) —
  ainda pendente de decisao.

### Estado atual

220 verdes, BUILD OK. Remoto: nada aplicado nesta etapa. As 3 novas
migrations (01700, 01800, 01900) ficam locais ate a revisao do usuario —
a opcao de aplicar depois e o push do usuario, pelo runbook do §4.
---
## 2026-11-13 - Etapa 8: decisoes dos 4 pontos em aberto + protecao ESTRUTURAL contra funcao quebrada; auditoria das migrations 01700/01800/01900; bateria a 267

**Gatilho:** o usuario decidiu os 4 pontos em aberto da Etapa 7 e pediu duas
coisas novas: (5) uma protecao estrutural para que funcao com caminho feliz
quebrado nao passe mais na bateria; (6) revisao com auditor estatico das 3
migrations novas, com prova de idempotencia. Nada foi aplicado no remoto.

### 1. As 4 decisoes, aplicadas no documento

1. **Sindico continua sem ver v_transferencias_internas.** O §3.4 do
   SEGURANCA_RLS.md foi corrigido para refletir o codigo (a view e restrita
   a auditor + conselho fiscal) e a linha marca "reavaliar quando o papel
   sindico for ativado".
2. **Conselho continua sem ver duplicatas.** A referencia a "fn_duplicatas"
   (funcao que nunca existiu) saiu do documento; a superficie real (view,
   auditor-only) esta escrita, marcada "a liberar quando o papel for
   ativado".
3. **Contestacoes visiveis a todos os papeis nominais: aceito** como
   comportamento intencional — nota na tabela do §3.4.
4. **fn_gerar_url_anexo: novo contrato aceito** (porteiro: valida o papel,
   registra o acesso, devolve o caminho; a URL assinada nasce na Storage
   API). A limitacao ficou documentada como **E10** (etapa de anexos): o
   acesso do leitor a anexo so entra no acesso_log se passar pela funcao; a
   Storage API pode ser chamada direto e nesse caminho o acesso nao e
   registrado. A policy de storage.objects continua autorizando — o que
   falta e a trilha de auditoria (decisao na etapa de anexos).

### 2. Item 5 — protecao estrutural (08_cobertura_funcoes.test.sql)

O caso que motivou: fn_aprovar_staging e fn_reconciliar_competencia estavam
quebradas desde a criacao e a bateria passava — nenhum teste exercitava o
CAMINHO FELIZ delas.

Regras novas (arquivo 08, roda depois da bateria, como postgres):
1. TODA funcao de producao do schema public precisa de um caso: caminho
   feliz + negacao. Funcao nova sem caso => BUILD QUEBRADO. A lista de
   exclusao e explicita (test_*, fn_log_escrita, fn_purgar_acesso_log e os
   fn_revogar_* — que sao de migration).
2. O caminho feliz precisa EXECUTAR: prova dupla (resultado da chamada +
   pg_stat_user_functions).
3. A negacao precisa devolver o mesmo erro de permissao (42501) ou, nas
   funcoes de leitura sem permissao negativa, o resultado vazio/false.

Instrumentacao: o runner liga `track_functions = 'all'` (ALTER SYSTEM, no
superuser local supabase_admin — o postgres local NAO e superuser) antes da
bateria, zera os contadores, e desliga no fim.

Limitacoes do pgstat (medidas e documentadas no proprio arquivo): chamada
que termina em ERRO nao entra em pg_stat_user_functions; transacao que
ABORTA descarta as stats pendentes. Por isso a prova de "sucesso" vem das
stats e a de "negacao" vem do SQLSTATE capturado — e por isso os blocos do
arquivo sao separados (o que prova a execucao COMMITTA antes do bloco que
pode levantar a excecao final).

Validacao negativa da propria protecao (local, 13/11/2026):
- quebrar fn_usuario_atual => o build acusa o caminho feliz E a propagacao;
- criar funcao nova sem caso => o build acusa "funcao sem caso de cobertura";
- restaurar => build verde.

### 3. Item 6 — auditoria das migrations 01700/01800/01900

- Auditor estatico (audita_migrations.py): 21 migrations, 90 objetos com
  REVOKE explicito de anon/authenticated (e de public, nas funcoes) — OK.
- Idempotencia: as 3 migrations foram reaplicadas e o snapshot textual do
  schema public (definicoes + grants, 92 linhas) ficou IDENTICO (hash
  igual, zero diferencas). A verificacao virou automatica no runner
  (secao "idempotencia"): reaplica e compara — build quebrado se mudar.
- Grants conferidos no banco: as 5 funcoes da 01700 e as 8 views da 01800
  tem REVOKE de public/anon/authenticated e GRANT apenas para authenticated;
  anon nao tem NADA; PUBLIC nao tem nada; a 01900 nao concede nada.

### 4. Achado colateral: o runner corrompia acentos dos arquivos

A verificacao de idempotencia falhou na primeira tentativa porque o
PowerShell 5.1 escreve texto no pipe na codificacao do console (ANSI) e o
Get-Content sem -Encoding le como ANSI: todo acento dos arquivos SQL
virava "?" no banco. Nao quebrava logica (eram comentarios), mas quebrava a
comparacao de definicoes. Corrigido: os arquivos agora vao ao banco por
`docker cp` + `psql -f` (bytes integros); o pipe ficou so para SQL inline
ASCII. Os regexes do runner tambem foram ajustados para o prefixo
"psql:<arquivo>:<linha>:" que o psql emite com -f.

### 5. Estado

- Bateria: **267 verdes, BUILD OK** (55+76 pgTAP das matrizes + 47 pgTAP
  antigos + 7 drift + 1 auditoria de migrations + 1 varredura de encoding +
  33 e2e + 45 cobertura de funcoes + 1 idempotencia + 1 instrumentacao).
- Documentacao: SEGURANCA_RLS.md §3.4 (decisoes), §3.5.4/§3.5.5 (decisoes
  + E10), §11.5 (cobertura estrutural), §11.6 (idempotencia) e checklist
  §12 (gate de granularidade/limiar nas views, observacao so para papel
  nominal, caso de cobertura obrigatorio).
- Remoto: nada aplicado. As 3 migrations da Etapa 7 continuam locais ate a
  revisao do usuario.

### 6. Pendencias

- **E10 (etapa de anexos)**: fechar a trilha de auditoria do acesso do
  leitor a anexos (hoje so passa pela fn_gerar_url_anexo; chamada direta da
  Storage API nao e registrada).
- Reavaliar sindico x transferencias e conselho x duplicatas quando esses
  papeis forem ativados.
- Varredura de dado real nos docs (42 valores R$, 3 NFs, 160 nomes de
  arquivo) — ainda pendente de decisao.
- Revisao do usuario antes de qualquer coisa no remoto.
---
## 2026-11-13 - Etapa 9: sanitizacao do repositorio (valores, NFs, nomes de arquivo, razoes sociais) e reescrita do historico

**Gatilho:** antes de qualquer push ao GitHub, o usuario pediu a sanitizacao
definitiva do repositorio e do historico. Nada foi enviado a servico externo;
nada foi empurrado; nenhum remote foi configurado.

### 1. Backup do historico (PRIMEIRO, antes de tocar em qualquer arquivo)

```
C:\Users\andre\.opencode\backups\anperez_condominios-HISTORICO-ORIGINAL-20261113-131552.bundle
```

- Fora do repositorio e fora de qualquer pasta sincronizada com nuvem
  (o OneDrive do perfil fica em C:\Users\andre\OneDrive; o bundle NAO esta
  la de proposito — ele contem o dado real).
- `git bundle create ... --all` + `git bundle verify`: "The bundle records a
  complete history" (2 refs: main e HEAD; 1,72 MB).
- Junto dele ficaram as ferramentas da sanitizacao (ver §6).

### 2. Metodo: minerar antes de trocar

Nao troquei nada "no olho". O caminho foi:

1. **Mineria**: extrai do repo todo numero monetario (BR e plano), numero de
   NF, nome de arquivo e razao social; classifica como real/ficticio pela
   frequencia (valor que aparece tambem em migrations/tests/seed e do
   fixture sintetico; valor que so aparece nos docs veio do dado real).
   Resultado: 220 candidatos a valor real, 213 nomes de arquivo distintos,
   20 entidades (condominio, fornecedores, banco, concessionarias).
2. **Mapa** de equivalencias ficticias coerentes (197 chaves).
3. **Aplicacao** em todo arquivo de texto do repo (docs, seed, migrations,
   testes, ferramentas) e nas copias sincronizadas em `plan\`.
4. **Verificador** independente (patterns do dado real) rodado em 3 camadas.

### 3. O que foi substituido (476 ocorrencias em 13 arquivos)

⚠️ **Este registro NAO reproduz os valores reais** — citar o valor original
aqui o colocaria de volta no repositorio. A lista completa dos padroes
substituidos esta na ferramenta, **fora do repo**, em
`C:\Users\andre\.opencode\backups\sanitiza.py`.

| Categoria | Virou |
|---|---|
| Valor monetario real (caso de nota fiscal, parcela de piscina, reposicao de caixa, correcao monetaria, soma das transferencias) | valor plausivel do mesmo porte, sem relacao com o original |
| Valor dos blocos de exemplo (planilha-resumo, extrato) | valores redondos com a **mesma aritmetica** do bloco original |
| Numero de nota fiscal (3 no total, mais as que apareciam em lista) | `NF-2xx` / `Doc-2xx` (distincao entre elas preservada: a logica do doc depende de "mesma NF em duas contas") |
| Nome de arquivo com o nome do condominio (`..._condominio_...`) | `extrato_AAAA-MM.xls` |
| Nome de arquivo com fornecedor ou concessionaria | `concessionaria_energia_AAAA-MM.pdf`, `fornecedor_*.xlsx` |
| Nome de arquivo de planilha-resumo e de balancete | `planilha-resumo.xlsx`, `balancete_AAAA-MM.pdf` |
| Razao social do condominio | `CONDOMINIO EXEMPLO` |
| Razao social de fornecedor / concessionaria / banco | `FORNECEDOR EXEMPLO`, `CONCESSIONARIA ENERGIA/GAS/AGUA`, `BANCO EXEMPLO` |
| Referencia de documento no historico do extrato | `RC.ATR.UN.0000xx` + `RC.000000xx` |
| Unidade citada como exemplo (fora da faixa do fixture) | `unidade 42`, `unidade 17` |

**A aritmetica dos exemplos foi preservada de proposito** (o doc ainda fecha):
- planilha-resumo: saldo anterior + creditos - debitos = saldo, nas cinco linhas
  do bloco (todas batem ao centavo);
- extrato: saldo inicial - debito total + credito total = saldo final;
- tabela de divergencias: a composicao por fundo soma exatamente a diferenca
  declarada, nas quatro linhas da tabela.

**Ficaram de fora (e por que):** os valores do fixture sintetico (1.000,00,
30,00, 50,00, 1.030,00 e companhia — precisam bater com os testes); as
tolerancias do sistema (0,00 / 0,01 / 0,50); numeracao de secao, versao de
Python, contagem de linhas e tamanho de arquivo (metadado estrutural, sem
identificador); os codigos de conta do plano (rubricas e fundos sao as
mesmas do seed ficticio); o nome do app antigo (software, nao dado).

### 4. Bug encontrado no caminho (e corrigido)

A primeira aplicacao reescreveu **todos** os arquivos de CRLF para LF
(`read_text` traduz CRLF->LF na leitura) — o diff passou a mostrar 5.783
linhas alteradas em vez de 240. Corrigido lendo com `newline=""` e
reescrevendo igual; o diff ficou minimo e as quebras de linha foram
preservadas. Vale a regra: **qualquer edicao em lote de arquivo versionado
precisa preservar a fin de linha** (o repo e CRLF).

### 5. Reescrita do historico (item 3 do pedido)

Sem remote, o historico foi reescrito a partir do estado sanitizado, com um
**commit raiz** e arvore atual:

```powershell
git checkout --orphan sanitizado
git add -A
git commit -m "ANPEREZ CONDOMINIOS - Fase 0 (historico reiniciado com estado sanitizado) ..."
git branch -D main
git branch -m sanitizado main
git reflog expire --expire=now --all
git gc --prune=now --aggressive
```

Resultado: `git log --oneline` mostra **1 commit** (7252e22) e o banco de
objetos tem **64 objetos = 64 alcancaveis** (nenhum objeto orfao do
historico antigo sobreviveu).

### 6. Prova: varredura em 3 camadas (tudo zero)

1. **Arvore de trabalho**: 0 ocorrencias (o verificador achava 503 no
   arquivo original — o detector funciona).
2. **Patch de todo o historico** (`git log --all -p`): 0 ocorrencias.
3. **Todos os blobs do banco do git** (64 objetos, 54 blobs): 0 ocorrencias.
   - Exclusao: o blob binario do `logo.png` — sequencias de letras num PNG
     aparecem por acaso nos bytes, e nao sao dado.

**As ferramentas nao foram versionadas de proposito**: o verificador
contem a LISTA dos valores reais — versiona-la seria colocar o dado real
de volta no repo. Ficaram em
`C:\Users\andre\.opencode\backups\` (varre_dado_real.py, sanitiza.py,
mina_valores.py), junto do bundle.

### 7. Bateria

**267 verdes, BUILD OK** com o repositorio sanitizado (o seed e as
migrations mudaram: o alias da aplicacao financeira no seed passou a
`APLICACAO BANCO EXEMPLO`, e os comentarios das migrations com o valor real
foram ajustados) — com
`supabase db reset` + bootstrap + `run_tests.ps1` do zero.

### 8. Estado e comandos prontos (NAO executados)

- Repositorio: 1 commit raiz, arvore sanitizada, **sem remote** (nao ha
  `git remote -v`), nada empurrado.
- O bundle com o historico original contem dado real: ele NAO deve ir para
  nuvem nem para o GitHub.

Proximos passos (para quando o usuario autorizar):

```powershell
# 1. conferir que nao ha remote e que o estado esta limpo
git remote -v
git status --short
git log --oneline

# 2. (opcional, recomendado) conferir de novo antes de publicar
python C:\Users\andre\.opencode\backups\varre_dado_real.py G:\Anperez_Condominios

# 3. configurar o remote PRIVADO e publicar
git remote add origin https://github.com/andreperez27/Anperez_condominios.git
git ls-files | Select-String -Pattern '\.(xls|xlsx|xlsm|csv|pdf|db|sqlite)$'
git push -u origin main

# 4. conferir no GitHub que o repositorio esta PRIVATE antes do push
#    (Settings > General > Danger Zone > "Change repository visibility")
```

### 8.1 PUBLICACAO (13/11/2026, depois da sanitizacao)

O usuario confirmou que o repositório está **PRIVADO** e passou a URL; a
publicação foi feita com o conteudo sanitizado:

```powershell
git remote add origin https://github.com/andreperez27/Anperez_condominios.git
git ls-remote origin          # autenticou; repositorio remoto estava VAZIO
git push -u origin main       # * [new branch] main -> main
```

Resultado no remoto: `refs/heads/main` = `bbac3c7` (2 commits: a raiz
sanitizada e o diario), **54 arquivos**, **nenhum arquivo de dado**, e o
**bundle nao publicado**.

Prova de que o que foi publicado esta limpo: a arvore foi extraida do
proprio `origin/main` (`git archive`) e varrida — **0 ocorrencias** de
valor, NF, nome de arquivo, razao social ou referencia de documento reals
(o patch do historico publicado tambem: 0).

O bundle com o historico ORIGINAL **nao foi para o GitHub** — ele contem o
dado real e continua em `C:\Users\andre\.opencode\backups\`, esperando uma
copia em disco externo.

### 9. Pendencias

- O bundle com o historico original precisa de uma copia em disco externo
  (ele contem dado real; nao deve ficar so nesta maquina).
- Varredura de dado real nos docs: **concluida** nesta etapa (os 42
  valores, 3 NFs e os nomes de arquivo foram trocados por equivalentes
  ficticios coerentes).
- As 3 migrations da Etapa 7 (01700, 01800, 01900) continuam locais,
  aguardando revisao para irem ao remoto.
- E10 (trilha de auditoria do acesso a anexos) e as decisoes de papel do
  §3.5.4 seguem em aberto.
