# AGENTS.md — ANPEREZ CONDOMÍNIOS

Instruções para agentes que trabalham neste repositório.

---

## Idioma

- Responder sempre em **pt-BR**. Não responder em inglês sem pedido explícito.
- Escrever código, comentários, nomes de tabela/coluna e documentação em **português do Brasil**, sem acento e sem cedilha nos identificadores (`snake_case`).

---

## Estado atual

**Fase 0 — estrutura multi-condomínio e modelo de dados contábil.**

Implementado até agora:
- Repositório Git com `.gitignore` que bloqueia dados do condomínio.
- Migrations da Fase 0 (schema, papéis, RLS, views, RPCs, storage).
- Bateria de testes de segurança (pgTAP).

**Não** implementado ainda (fases futuras): importador Python, front React, obras/orçamentos/assembleias (Fase 2).

Documentação de referência: `docs\`. As decisões e o histórico estão em `docs\DIARIO_DE_BORDO.md`.

---

## Regras invioláveis

1. **Nunca escrever em `C:\Users\andre\Desktop\condominio`.** É a pasta de origem dos dados do condomínio, somente leitura.
2. **Nunca escrever em `C:\Users\andre\Desktop\Anperez_money`.** É referência de padrão, somente leitura. Não copiar credenciais nem lógica de negócio de lá.
3. **Nunca versionar dado do condomínio.** O `.gitignore` bloqueia `*.xls`, `*.xlsx`, `*.pdf`, `*.csv` globalmente, com exceção explícita para `docs\`, `supabase\migrations\`, `supabase\tests\` e `supabase\seed.sql`.
4. **Nunca commitar `.env.local`**, chave de `service_role` ou senha de role do Postgres.
5. **Nunca enviar dado do condomínio para serviço externo.** Parsing é local.
6. **Nunca criar tabela, função ou view sem:**
   - `enable row level security` **e** `force row level security` (tabelas de negócio);
   - `revoke` de `public`, `anon` e `authenticated` (revoke **triplo** — ver abaixo);
   - filtro de tenant explícito;
   - entrada na lista de verificação de grants (`supabase\tests\grants_publicos.test.sql`).

---

## Convenções de migration

**Uma migration, uma finalidade.** Nome: `AAAAMMDDHHMMSS_descricao_curta.sql`.

**Idempotência obrigatória** — a migration deve poder ser reaplicada:
- `create table if not exists`
- `create or replace function`
- `drop policy if exists` antes de `create policy`
- `revoke` e `drop ... if exists` são idempotentes por natureza

**Revoke triplo.** No Postgres, funções novas nascem com `EXECUTE` para `PUBLIC`. No Supabase, o ambiente mantém `execute` para `anon`/`authenticated` via *default privileges*. Revogar **só** de `public` não basta — foi testado no Anperez Money e não funcionou. O padrão é:

```sql
revoke all on function public.minha_funcao(uuid) from public;
revoke all on function public.minha_funcao(uuid) from anon;
revoke all on function public.minha_funcao(uuid) from authenticated;
grant  execute on function public.minha_funcao(uuid) to authenticated;
```

**Funções privilegiadas** (`SECURITY DEFINER`):
- `set search_path = public, pg_temp` — obrigatório
- owner = `app_owner` (role sem login, com `BYPASSRLS`)
- `revoke execute ... from public, anon` + `grant execute ... to authenticated`
- **filtro de tenant explícito** dentro da função
- papel avaliado **por condomínio** (`fn_e_membro(p_condominio_id, 'auditor')`)
- nada de SQL dinâmico (`execute format(...)`)

**Views agregadas:**
- `security_barrier = true`
- filtro de tenant explícito **dentro** da view (o RLS do dono não se aplica)
- nenhuma coluna de identificação

**Nenhuma migration contém dado de negócio.** Dado de configuração vai no `seed.sql`; dado real entra por importação.

---

## Como o papel é avaliado

Não existe `GRANT` separado por papel: todos os autenticados são `authenticated`. A separação é feita **dentro** de views e funções, sempre contra o condomínio da própria linha:

```sql
-- em policy
using (public.fn_e_membro(condominio_id, 'auditor'))

-- em função
if not public.fn_e_membro(p_condominio_id, 'auditor') then
    raise exception 'sem permissao' using errcode = '42501';
end if;
```

Helpers disponíveis (criados na migration de papéis):
- `fn_papeis_do_usuario(p_condominio_id uuid)` → `setof papel_membro`
- `fn_e_membro(p_condominio_id uuid, p_papel papel_membro)` → `boolean`
- `fn_condominios_do_usuario()` → `setof uuid`

---

## Fonte única de verdade por estado

Cada estado tem **um** dono. Não duplique colunas de estado.

| Estado | Onde mora |
|---|---|
| Classificação de um lançamento | `lancamento_rubrica.status` |
| Transferência interna | `transferencias_internas.status` |
| Duplicata | `duplicatas_candidatas.status` |
| Contestação | `contestacoes.status` |
| Competência por fonte | `status_competencia.status` |

Lançamento **sem** `grupo_transferencia_id` não é transferência interna — não existe estado `nao_aplicavel`.

---

## Idempotência da importação

`chave_natural = sha256(tupla_semantica + '#' + numero_ocorrencia)`.

- A **tupla** identifica o fato contábil (competência, conta, data, documento, tipo, valor, histórico normalizado).
- O **número da ocorrência** distingue linhas idênticas dentro do mesmo arquivo, para que duplicatas reais sejam **inseridas e marcadas** em vez de descartadas em silêncio pelo `unique`.
- A detecção de duplicatas compara a **tupla**, nunca a `chave_natural`.

---

## Testes

```bash
supabase test db          # roda a bateria de segurança (pgTAP)
```

**Qualquer falha de segurança quebra o build.** Os testes cobrem, entre outras coisas:
- leitor não faz `SELECT` em tabela de detalhe;
- leitor não chama função privilegiada;
- granularidade não permitida é recusada;
- nada vaza entre condomínios;
- importador não escreve em `lancamentos`;
- anexo bloqueado por padrão para o leitor;
- `v_resultado_bruto` não subtrai transferências;
- limiar mínimo de agregação suprime célula pequena;
- **lista de grants de `authenticated`/`anon` bate com a lista permitida** (teste de drift).

---

## Ao terminar uma tarefa

Atualizar `docs\DIARIO_DE_BORDO.md` com: data, o que foi feito, decisões tomadas e pendências. É o histórico do projeto e a fonte da verdade sobre por que as coisas são como são.
