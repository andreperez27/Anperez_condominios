# ANPEREZ CONDOMÍNIOS

Sistema de análise e auditoria da contabilidade de condomínios.

**Fase atual:** Fase 0 — estrutura multi-condomínio e modelo de dados contábil.

---

## O que é

Aplicação para:

1. **Auditar** a contabilidade de um condomínio a partir dos documentos que a administradora entrega (extrato bancário, balancete mensal, conta de despesas locais) e da planilha-resumo de controle.
2. **Apoiar** a prestação de contas de um período: o modelo já nasce com o conceito de **competência** (período fechado) e de **fundo/recurso**, que são os objetos de trabalho de um síndico e de um conselho fiscal.
3. **Controlar a importação**: nada entra no banco sem passar por uma área de conferência e aprovação humana.

O modelo é **multi-condomínio desde a primeira migration**: o condomínio é a unidade central, com membros e papéis. Hoje há um condomínio; a estrutura já suporta vários.

---

## Papéis

| Papel | O que faz |
|---|---|
| `auditor` | Lê tudo, escreve, aprova importações, classifica lançamentos, decide duplicatas, confirma transferências internas, fecha competências |
| `leitor` | Somente leitura, **visão agregada** (por condomínio e por fundo). Sem acesso a linha de lançamento |
| `sindico` | Lê o próprio condomínio em nível nominal; **comenta e contesta**, mas não altera classificação |
| `conselho_fiscal` | Lê o próprio condomínio em nível nominal restrito; emite parecer |

O papel de negócio **não** é um privilégio de banco: todos os usuários autenticados são `authenticated` no Postgres, e a separação acontece dentro das views e funções, testando o papel **no condomínio da própria linha**.

---

## Estrutura

```
.
├── docs/                  # documentação de projeto (versionada)
│   ├── INVENTARIO_DADOS.md
│   ├── QUALIDADE_DADOS.md
│   ├── MODELO_DADOS.md
│   ├── SEGURANCA_RLS.md
│   ├── IMPORTACAO.md
│   ├── ESTRUTURA_REPO.md
│   └── DIARIO_DE_BORDO.md
├── supabase/
│   ├── config.toml
│   ├── seed.sql            # carga de configuração (fundos, rubricas, unidades, aliases)
│   ├── migrations/         # versionadas, em ordem cronológica
│   └── tests/              # testes de segurança (pgTAP)
├── front/                  # React + Vite (Fase 1)
├── scripts/                # Python: importador e testes
├── dados_origem/           # IGNORADO pelo Git — dados brutos do condomínio
└── dados_trabalho/         # IGNORADO pelo Git — staging e logs locais
```

---

## Regras de ouro

1. **Nenhum dado do condomínio vai para o Git.** O `.gitignore` bloqueia `*.xls`, `*.xlsx`, `*.pdf`, `*.csv` globalmente. Antes do primeiro commit, `git status` precisa mostrar zero arquivo de dado.
2. **Nenhuma chave no repositório.** `.env.local` é ignorado; `.env.example` só tem nomes de variáveis.
3. **Nenhum dado sai do computador.** Parsing local, banco do próprio projeto.
4. **Nada entra no banco sem aprovação humana.** O importador escreve só em `staging_*`; a entrada em `lancamentos` passa por RPC atômica.
5. **Duplicata não se descarta.** Linhas repetidas são marcadas como candidatas e decididas por humano.
6. **Classificação errada não esconde dinheiro.** O consolidado padrão (`v_resultado_bruto`) soma tudo; a visão líquida desconta apenas transferências **confirmadas**.
7. **Todo lançamento guarda a origem**: arquivo, hash, aba ou página e linha.

---

## Comandos

```bash
# ambiente local do Supabase
supabase start
supabase db reset
supabase test db

# verificação de que nenhum dado está versionado (roda no CI)
git ls-files | grep -Ei '\.(xls|xlsx|csv|pdf|db|sqlite|pem|key)$' && echo "ARQUIVO DE DADO VERSIONADO" && exit 1
```

---

## Documentação

Toda decisão de projeto está registrada em `docs/DIARIO_DE_BORDO.md`, com data, o que foi feito e o que foi decidido. As decisões de arquitetura estão em `docs/MODELO_DADOS.md` e `docs/SEGURANCA_RLS.md`.
