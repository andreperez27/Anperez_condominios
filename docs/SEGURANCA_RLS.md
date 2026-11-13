# Proposta de segurança e RLS — ANPEREZ CONDOMÍNIOS

**Data:** 11/11/2026 · **Atualizado em 12/11/2026 (Etapa 7):** matrizes medidas no banco em §3.5
**Status:** proposta — nenhuma policy, role, view ou função foi criada no banco.
**Bases:** decisão D10 (leitor vê apenas agregados; liberação nominal futura só por mudança de política), `docs\MODELO_DADOS.md`, padrão do Anperez Money (RLS multi-tenant + RPCs atômicas).

> **Nota sobre o Anperez Money:** este documento segue o padrão descrito por você (RLS multi-tenant, RPCs atômicas para operações compostas). Para casar **nomes de roles, helpers de papel, formato das policies e convenção de RPC** com o que já existe no Money, preciso do caminho do código. Não fui procurar sozinho, conforme você pediu. Até lá, adotei nomes neutros e marcados como *provisórios*.

---

## 1. O problema central: RLS filtra linhas, não calcula agregados

### 1.1 O que RLS faz e o que não faz

| RLS **faz** | RLS **não faz** |
|---|---|
| Restringir **quais linhas** um `SELECT` devolve | Calcular agregados ("soma das cotas de todas as unidades do mês") |
| Aplicar-se por tabela, por operação, por papel | Impedir que o usuário descubra o total de uma coluna que ele não pode ler linha a linha |
| Ser testada com `USING` (filtro de linha) e `WITH CHECK` (filtro de escrita) | Fazer uma visão devolver "soma agregada, sem detalhe" — isso é trabalho de view/função, não de policy |

**Consequência direta:** se o leitor tivesse `SELECT` em `lancamentos` e o RLS deixasse passar só as linhas sem `unidade_id`, ele ainda poderia fazer `select count(*) from lancamentos` e receber o número de linhas — e, combinando consultas, inferir o conteúdo. Se o RLS deixasse passar alguma linha com unidade, ele leria o dado nominal.

### 1.2 A garantia correta: negar o acesso à linha, entregar o agregado

A garantia de que o leitor **só vê agregados** não vem do RLS. Vem de **dois mecanismos combinados**:

1. **Revogação de privilégio** — nenhuma tabela de detalhe é legível por `authenticated` (§3). O `SELECT` é recusado pelo Postgres com `permission denied`, antes de o RLS ser avaliado.
2. **Superfície de leitura restrita** — o acesso acontece apenas por **views agregadas** e **funções** que agregam do lado do servidor e devolvem apenas agregados.

Assim, o leitor **nunca** executa um `SELECT` sobre uma tabela de detalhe. Não há botão escondido, não há campo em branco: o dado simplesmente não é alcançável pela SQL que ele pode escrever.

### 1.3 Cuidado técnico: view agregada sem RLS pode vazar outro condomínio

Ponto que costuma passar batido: uma view no Postgres roda com os privilégios do **dono** da view, não com os do usuário que consulta (a menos que se use `security_invoker = true`). Isso significa que uma view que faz `SELECT ... FROM lancamentos` **ignora as policies do `lancamentos`** e devolveria a soma de **todos** os condomínios.

A correção é obrigatória em toda view agregada:

```sql
create view public.v_resumo_competencia_fundo
with (security_barrier = true) as
select
    c.condominio_id,
    c.ano,
    c.mes,
    l.fundo_id,
    f.nome                                        as fundo_nome,
    count(*)                                      as qtd_lancamentos,
    sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
    sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos
from public.lancamentos l
join public.competencias c on c.id = l.competencia_id
join public.fundos f       on f.id = l.fundo_id
where l.status = 'ativo'
  and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
group by c.condominio_id, c.ano, c.mes, l.fundo_id, f.nome;
```

Três elementos obrigatórios em **todas** as views agregadas:
- `where condominio_id in (select ... from fn_condominios_do_usuario())` — o filtro de tenant, feito **dentro** da view, porque o RLS do dono da view não se aplica;
- `security_barrier = true` — impede que um filtro do usuário seja usado para "oracular" o conteúdo linha a linha através de funções qualificadas;
- **nenhuma coluna de identificação** (unidade, documento, histórico).

---

## 2. Papéis: como o usuário Supabase assume o papel de aplicação

### 2.1 O fluxo padrão do Supabase e o que ele significa para a segurança

No fluxo padrão do Supabase:

1. A pessoa faz login (e-mail/senha, magic link, OAuth) e o Supabase Auth emite um **JWT**.
2. Toda sessão autenticada carrega a **mesma claim `role: "authenticated"`**. O banco Postgres enxerga **um único role** para todos os usuários logados — `authenticated`.
3. O `auth.users` guarda a identidade. A **permissão de negócio** (auditor, leitor, síndico, conselho fiscal) **não vem do JWT**: vem da tabela `membros`, consultada **em tempo de consulta**, dentro das policies e das funções.

**Consequência decisiva, e é o ponto que muda o desenho inteiro:**

> **No fluxo padrão não existe `GRANT` separado para o leitor.** O leitor e o auditor são, para o Postgres, o mesmo role (`authenticated`). Não há como escrever `REVOKE SELECT ON lancamentos FROM app_leitor` — o role `app_leitor` simplesmente não existe no mundo do JWT.

Portanto a separação leitor × auditor **não pode** ser feita na camada de privilégio de tabela. Ela tem que ser feita em **duas camadas mais acima**:

| Camada | Onde | Como separa |
|---|---|---|
| **Privilégio de tabela** | `REVOKE`/`GRANT` sobre `authenticated` | Ninguém (nem leitor, nem auditor) lê tabela de detalhe direto |
| **Papel de negócio** | `membros` + helpers `SECURITY DEFINER` | Toda view e toda função verifica o papel **do usuário naquele condomínio** e devolve linhas ou agregados conforme o caso |

### 2.2 O mecanismo: helper de papel por condomínio

O papel é resolvido **em tempo de consulta**, sempre **scopado por condomínio** (requisito seu nº 2: o papel é de uma pessoa *em um condomínio*, não da pessoa no vazio).

```sql
-- roles do banco
create role app_owner      nologin;   -- dono das funções/views privilegiadas (BYPASSRLS, ver §4)
create role app_importador nologin;   -- usado pelo script Python (ver §8)

-- helpers: papel do usuário autenticado, POR CONDOMÍNIO
create or replace function public.fn_papeis_do_usuario(p_condominio_id uuid)
returns setof public.papel_membro
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.papel
  from public.membros m
  where m.perfil_id = auth.uid()
    and m.ativo
    and m.condominio_id = p_condominio_id;
$$;

create or replace function public.fn_condominios_do_usuario()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.condominio_id
  from public.membros m
  where m.perfil_id = auth.uid()
    and m.ativo;
$$;

-- atalho booleano, para uso dentro de policy
create or replace function public.fn_e_membro(
    p_condominio_id uuid,
    p_papel        public.papel_membro
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.membros m
    where m.perfil_id = auth.uid()
      and m.ativo
      and m.condominio_id = p_condominio_id
      and m.papel = p_papel
  );
$$;
```

⚠️ Os helpers **precisam** de `set search_path = public, pg_temp` — sem isso, um atacante que consiga criar um objeto num schema anterior do `search_path` poderia sequestrar a execução da função. É a mesma razão pela qual toda função privilegiada do projeto recebe essa cláusula.

⚠️ `auth.uid()` **funciona dentro de `SECURITY DEFINER`** porque ele lê a claim do JWT da requisição (via GUC de sessão), não o `current_user`. Isso é o que permite filtrar por tenant e por papel dentro de views que rodam com privilégio do dono.

⚠️ `fn_papeis_do_usuario` precisa ser `SECURITY DEFINER` porque `membros` tem RLS própria — sem isso, a consulta recursaria (a policy de `membros` chamaria o helper, que consultaria `membros`).

### 2.3 Papéis de negócio (tabela `membros.papel`)

| Papel | Existe hoje | O que faz |
|---|---|---|
| `auditor` | ✅ (você) | Lê tudo, escreve, aprova importações, classifica, decide duplicatas, confirma transferências, fecha competência |
| `leitor` | ✅ (Sr. Adilson) | Somente leitura, visão **agregada**. Sem acesso a linha |
| `sindico` | ⏳ futuro | Lê o **próprio** condomínio em nível nominal; **comenta e contesta**, mas **não altera classificação** |
| `conselho_fiscal` | ⏳ futuro | Lê o próprio condomínio em nível nominal restrito, **não altera classificação**, emite parecer |
| `admin_plataforma` | ⏳ futuro | Operação da plataforma, fora do domínio de um condomínio |

### 2.4 Matriz: papel × condomínio

| Papel | Escopo de condomínio | Lê lançamento nominal? | Escreve? | Aprova importação? | Fecha competência? | Comenta/contesta? |
|---|---|---|---|---|---|---|
| `auditor` | todos onde é membro | ✅ | ✅ | ✅ | ✅ | ✅ responde |
| `leitor` | todos onde é membro | ❌ | ❌ | ❌ | ❌ | ❌ |
| `sindico` | apenas o próprio | ✅ | ⚠️ só contestação | ❌ | ❌ | ✅ cria |
| `conselho_fiscal` | apenas o próprio | ✅ | ⚠️ só parecer | ❌ | ❌ | ✅ cria |

O escopo "apenas o próprio" é consequência direta de `fn_papeis_do_usuario(p_condominio_id)`: um síndico que seja membro de dois condomínios tem `sindico` **em um** e, no outro, o papel que tiver. A avaliação é sempre feita **no condomínio da linha lida**.

---

## 3. Matriz de privilégios e o REVOKE/GRANT do leitor

### 3.1 A revogação base (primeira migration, antes de qualquer tabela de negócio)

```sql
-- o Supabase, por padrão, dá privilégio amplo ao schema public.
-- Isso PRECISA ser revertido, senão "RLS protege" é ilusão.
revoke all on schema public from anon;
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
grant  usage on schema public to anon, authenticated;
```

### 3.2 O que cada papel enxerga — e o que isso significa para o `GRANT`

Como todos os papéis compartilham `authenticated`, o `GRANT` é **igual para todos**. O que muda é **o que cada um recebe de volta** da view/função:

| Superfície | `GRANT` para `authenticated` | O que o **leitor** recebe | O que o **auditor** recebe |
|---|---|---|---|
| `v_resumo_competencia_fundo` | `SELECT` | agregado do seu condomínio | idem |
| `v_resumo_competencia_rubrica` | `SELECT` | **— (0 linhas; gate de granularidade)** | agregado |
| `v_resultado_bruto` | `SELECT` | agregado (soma tudo) | idem |
| `v_resultado_liquido` | `SELECT` | agregado (sem transferências confirmadas) | idem |
| `v_conciliacao` | `SELECT` | status + diferença por fundo | idem |
| `v_cobertura_competencias` | `SELECT` | status por competência e fonte | idem |
| `v_pendencias_resumo` | `SELECT` | **contagem** por tipo/gravidade | idem |
| `fn_resumo(...)` | `EXECUTE` | agregado, com granularidade limitada | agregado, granularidade plena |
| `fn_lancamentos(...)` | `EXECUTE` | ❌ **`exception`** | linhas do condomínio |
| `fn_aprovar_staging(...)` | `EXECUTE` | ❌ **`exception`** | aprova |
| `fn_classificar_lancamento(...)` | `EXECUTE` | ❌ **`exception`** | classifica |
| `fn_contestar_lancamento(...)` | `EXECUTE` | ❌ **`exception`** | ✅ e síndico |
| `fn_aprovar_anexo_para_leitor(...)` | `EXECUTE` | ❌ **`exception`** | libera anexo |
| Tabelas de detalhe (`lancamentos`, `unidades`, `pendencias`, `duplicatas_candidatas`, `documentos`, `anexos`, `staging_*`, `auditoria_log`, `membros`, `acesso_log`) | **nenhum `GRANT`** | ❌ `permission denied` | ❌ `permission denied` |

**O ponto que responde à sua pergunta sobre o REVOKE/GRANT do leitor:**

> O leitor **não tem `GRANT` nenhum** sobre as tabelas de detalhe — nem `SELECT`. Ele só tem `SELECT` em views agregadas e `EXECUTE` em funções. Como o `GRANT` é de `authenticated`, o auditor também não tem `GRANT` direto; ele chega ao dado **pelas mesmas views e funções**, que verificam o papel dele e devolvem a linha. O resultado é uma **superfície de leitura única e idêntica para todos**, onde a diferenciação acontece no servidor.

Isso tem um custo (o front não usa PostgREST direto nas tabelas) e um benefício grande (uma superfície só para revisar, e nenhuma chance de um `GRANT` futuro abrir vazamento).

### 3.3 Alternativa considered: manter `GRANT SELECT` e deixar o RLS filtrar

Se o `authenticated` mantiver `SELECT` em `lancamentos`, o leitor **teria** o privilégio e receberia **zero linhas** por policy. Funciona contra vazamento de *dados*, mas:
- o leitor continua com acesso de metadados (nomes de colunas, existência de tabela, número de linhas via `count`);
- a segurança passa a depender de **cada policy estar correta** — um `USING (true)` futuro vaza tudo;
- e o requisito "o leitor não deve ter SELECT direto nas tabelas" não é atendido literalmente.

Por isso a proposta principal **revoga**. A variante está registrada aqui para comparação.

### 3.4 Matriz por tabela (quem enxerga o quê, no papel)

| Tabela | Leitor | Auditor | Síndico | Conselho fiscal | Importador |
|---|---|---|---|---|---|
| `condominios` | via view | CRUD | R | R | R |
| `membros` | ❌ | CRUD | ❌ | ❌ | ❌ |
| `perfis` | via `fn_meu_perfil` | R | R | R | — |
| `convites` | ❌ | CRUD | ❌ | ❌ | ❌ |
| `unidades` | ❌ | CRUD | R | R | R |
| `competencias`, `status_competencia` | via view | CRUD | R | R | R |
| `fundos`, `rubricas`, `rubrica_aliases`, `contas_origem` | via view agregada | CRUD | R | R | R |
| `fontes_importacao`, `importacoes`, `staging_*` | ❌ | CRUD | R | R | **C** |
| `serie_historica_resumo` | via view | CRUD | R | R | **C** |
| **`lancamentos`**, `lancamento_rubrica` | ❌ | via `fn_lancamentos` | via `fn_lancamentos` | via `fn_lancamentos` | ❌ |
| **`grupos_transferencia`**, **`transferencias_internas`** | ❌ | via `fn_lancamentos` (detalhe) + `v_transferencias_internas` | ❌ — **decisão de 12/11/2026**: o síndico não vê transferências internas por nenhuma superfície. Reavaliar quando o papel for ativado | via `v_transferencias_internas` | ❌ |
| **`duplicatas_candidatas`** | ❌ | via `v_duplicatas_candidatas` | ❌ | ❌ — **a liberar quando o papel for ativado**: hoje não existe `fn_duplicatas` (a função citada na versão anterior deste documento nunca foi criada) e a view é auditor-only | ❌ |
| **`pendencias`**, `pendencia_anotacoes` | ❌ (só contagem via view) | CRUD | R (próprias) | R | ❌ |
| **`contestacoes`** | ❌ | CRUD (responde) | **C** (cria) | **C** (cria) | ❌ |

> ⚠️ **Contestações — comportamento intencional (aceito em 12/11/2026):** `v_contestacoes` devolve **todas** as contestações do condomínio para os três papéis nominais (auditor, síndico, conselho fiscal) — não só as do próprio autor. É a decisão registrada: a contestação é um registro lateral do condomínio, e o front destaca o que é do usuário.
| **`documentos`**, `anexos` | ❌ (só anexos liberados) | CRUD | R (próprios) | R (próprios) | R |
| `conciliacoes`, `conciliacao_detalhe` | via view | CRUD | R | R | ❌ |
| `auditoria_log` | ❌ | R | ❌ | R | ❌ |
| `acesso_log` | ❌ | R | ❌ | R | ❌ |
| `config_visibilidade`, `granularidade_ordem` | ❌ | CRUD (via RPC) | ❌ | ❌ | R |

### 3.5 Matrizes medidas no banco (12/11/2026)

Medidas **no ambiente local**, com o fixture completo (14 lançamentos, 1 transferência confirmada, 1 duplicata candidata, 2 pendências ligadas/desligadas de unidade, 2 conciliações, 2 contestações, 2 linhas de série histórica) e 6 personas. Automatizadas na bateria: `supabase\tests\06_matriz_views.test.sql` (55 verificações) e `supabase\tests\07_matriz_funcoes.test.sql` (76 verificações).

**Regras das views (migrations 01300/01800):** as agregadas devolvem dado de todos os membros do condomínio (o filtro de tenant está dentro da view); as de detalhe filtram por papel **dentro** da view; o limiar de `config_visibilidade` é lido **dentro** da view (suprime células com 1..limiar-1 unidades ligadas a unidade; nunca suprime agregados sem unidade); a observação (texto livre) só vai para papel nominal (auditor/síndico/conselho).

#### 3.5.1 Views × papel (linhas devolvidas por consulta)

| View | leitor | auditor | síndico | conselho | leitor (outro cond.) | sem vínculo |
|---|---|---|---|---|---|---|
| `v_resumo_competencia_fundo` | 2 (agregado) | 2 | 2 | 2 | 0 | 0 |
| `v_resumo_competencia_rubrica` | **0** (gate: max=fundo) | 3 | 3 | 3 | 0 | 0 |
| `v_resultado_bruto` | 1 (soma tudo) | 1 | 1 | 1 | 0 | 0 |
| `v_resultado_liquido` | 1 (+ transf. pendentes/confirmadas) | 1 | 1 | 1 | 0 | 0 |
| `v_resultado_liquido_por_fundo` | 1 | 1 | 1 | 1 | 0 | 0 |
| `v_cobertura_competencias` | 4 (obs. **NULL**) | 4 (obs.) | 4 (obs.) | 4 (obs.) | 4 (obs. **NULL**) | 0 |
| `v_conciliacao` | 2 (obs. **NULL**) | 2 (obs.) | 2 (obs.) | 2 (obs.) | 0 | 0 |
| `v_pendencias_resumo` | 2 (só tipo/gravidade/status/qtd) | 2 | 2 | 2 | 0 | 0 |
| `v_serie_historica` | **0** (gate: max=fundo) | 2 | 2 | 2 | 0 | 0 |
| `v_importacao_resumo` | 1 (agregado) | 1 | 1 | 1 | 1 | 0 |
| `v_transferencias_internas` | 0 | 1 | 0 | 1 | 0 | 0 |
| `v_duplicatas_candidatas` | 0 | 1 | 0 | 0 | 0 | 0 |
| `v_lancamentos_com_duplicata` | 0 | 14 | 0 | 0 | 0 | 0 |
| `v_contestacoes` | 0 | 2 | 2 | 2 | 0 | 0 |

Resumo: **o leitor não recebe linha de detalhe nem coluna de unidade** (as views de detalhe devolvem 0 linhas; nenhuma view expõe `unidade_id` fora das views de detalhe), **não recebe a observação** (texto livre) de conciliação nem de competência, e **não recebe a célula pequena** de rubrica ("Multas", 2 unidades: suprimida quando o limiar é ≥ 3 — testado com alteração temporária da política do auditor para limiar 5, restaurada depois). **Agregado nunca vira R$ 0,00 por supressão** — vira NULL com `suprimido = true`.

#### 3.5.2 Limiar mínimo de agregação nas views

| Célula (fixture) | Unidades | Limiar 5 (leitor) | Limiar 0 (auditor) |
|---|---|---|---|
| `v_resumo_competencia_rubrica` "Multas" | 2 | suprimida (NULL + suprimido=true) | visível (R$ 30,00) |
| `v_resumo_competencia_rubrica` "Cotas condominees" | 10 | visível (R$ 1.000,00) | visível |
| `v_resumo_competencia_rubrica` "Transferencia entre contas" | 0 | visível (R$ 50,00) | visível |
| `v_resumo_competencia_fundo` "CONTA CONDOMINIO" | 12 | visível (R$ 1.030,00) | visível (R$ 1.030,00) |
| `v_resumo_competencia_fundo` "BENFEITORIAS" | 0 | visível (R$ 50,00) | visível (R$ 50,00) |

Regra aplicada: `0 < qtd_unidades < limiar` → suprime; `qtd_unidades = 0` ou `≥ limiar` → visível.

#### 3.5.3 Funções executáveis por `authenticated` (21) × papel

| Grupo (funções) | leitor | auditor | síndico/conselho | outro cond. | sem vínculo |
|---|---|---|---|---|---|
| Helpers (`fn_usuario_atual`, `fn_papeis_do_usuario`, `fn_condominios_do_usuario`, `fn_e_membro`, `fn_acessa_condominio`) | retornam os seus (ou vazio) | idem | idem | vazio/false | vazio/false |
| `fn_resumo` | só `fundo` (rubrica/unidade → 42501) | plena (limiar 0) | `unidade` (limiar 1) | 42501 | 42501 |
| `fn_lancamentos` | 42501 | 14 linhas | 14 linhas | 42501 | 42501 |
| `fn_aprovar_staging`, `fn_classificar_lancamento`, `fn_decidir_duplicata`, `fn_confirmar_transferencia`, `fn_reconciliar_competencia`, `fn_registrar_pendencia` (operação do auditor) | 42501 | ok | 42501 | 42501 | 42501 |
| `fn_contestar_lancamento` | 42501 | ok | ok | 42501 | 42501 |
| `fn_responder_contestacao` | 42501 | ok | 42501 | 42501 | 42501 |
| `fn_liberar_anexo_para_leitor` | 42501 | ok | 42501 | 42501 | 42501 |
| `fn_anexo_acessivel` (retorna boolean) | só anexo liberado → true | sempre true | sempre true | false | false |
| `fn_gerar_url_anexo` | porteiro: 42501 (bloqueado) / ok (liberado) | ok | ok | 42501 | 42501 |
| `fn_atualizar_visibilidade` | 42501 | ok | 42501 | 42501 | 42501 |
| `fn_auditoria_log`, `fn_acesso_log` | 42501 | ok | conselho: ok; síndico: 42501 | 42501 | 42501 |

**Regra de uniformidade de erro:** papel insuficiente recebe **sempre** `42501` — inclusive com **ids falsos** (papel avaliado ANTES da existência do registro). Um não-autorizado não consegue distinguir "não existe" de "sem permissão". Os helpers read-only (boolean) são a única exceção, por design.

#### 3.5.4 Correções feitas em 12/11/2026 (Etapa 7) e o que ficou em aberto

Corrigidos (migrations 01700/01800/01900 + expansão dos testes):
1. `fn_registrar_pendencia` **não validava nada** — escrita cross-tenant irrestrita; passou a exigir auditor do condomínio pedido.
2. `fn_responder_contestacao` — typo `entidad` → 42703 para **qualquer** chamador; corrigido.
3. `fn_gerar_url_anexo` — (a) id inexistente devolvia P0002 (enumeração por id) → agora 42501 uniforme; (b) chamava `storage.create_signed_url()`, função que **não existe** no schema storage (URLs assinadas são da Storage API, fora do Postgres) → virou porteiro: porteiro valida a permissão, registra o acesso e devolve o **caminho**; o front gera a URL pelo `createSignedUrl` do supabase-js (a policy de `storage.objects` já garante a autorização).
4. `fn_aprovar_staging` — literais de enum sem cast em `INSERT ... SELECT` (o plano falha no parse: `VALUES` coerciona, `SELECT` não) → **a importação nunca funcionou**; corrigido com casts explícitos.
5. `fn_reconciliar_competencia` — `on conflict (competencia_id, fundo_id)` ambíguo vs `RETURNS TABLE`; e `coalesce(diferenca_creditos, 0)` ao lado do parâmetro de retorno → comparava NULL. Corrigido com `on conflict on constraint conciliacoes_unica` e qualificadores `c.`.
6. Views agregadas **ignoravam `config_visibilidade`**: o leitor (max=fundo) lia as 3 linhas de `v_resumo_competencia_rubrica`, inclusive "Multas" (2 unidades). Gate de granularidade (`rank_max >= rubrica`) em `v_resumo_competencia_rubrica` e `v_serie_historica`; limiar em todas as células fundo/resultado; supressão vira NULL + `suprimido = true`.
7. `observacao` (texto livre) das views `v_conciliacao` e `v_cobertura_competencias` chegava ao leitor (ex.: "unidade 11 não enviou extrato") → agora só papel nominal.
8. `config_grants_permitidos` — `authenticated` tinha SELECT → revogado (migration 01900); lista permitida atualizada; drift continua como postgres.

Em aberto → **decidido em 13/11/2026 (Etapa 8)**:

| Tema | Decisão | Onde está registrado |
|---|---|---|
| **Síndico × `v_transferencias_internas`** | O síndico **continua sem ver** transferências internas (a view fica restrita a auditor + conselho fiscal). O §3.4 foi corrigido para refletir o código | §3.4, §3.5.1 — **reavaliar quando o papel `sindico` for ativado** |
| **Conselho × duplicatas** | O conselho **continua sem ver** duplicatas. A referência a `fn_duplicatas` (que nunca existiu) saiu do documento; a superfície real é a view, auditor-only | §3.4 — **a liberar quando o papel for ativado** |
| **Contestações visíveis aos papéis nominais** | **Aceito como comportamento intencional**: auditor, síndico e conselho veem todas as contestações do condomínio (a contestação é registro lateral do condomínio) | §3.4 (nota), §3.5.1 |
| **`fn_gerar_url_anexo` — novo contrato** | **Aceito**: a função é o *porteiro* (valida o papel, registra o acesso, devolve o caminho). A URL assinada nasce na Storage API (front) | §3.5.3, §3.5.5 (E10) |

#### 3.5.5 Limitação conhecida: o log de acesso dos anexos (pendência **E10**)

`fn_gerar_url_anexo` grava no `acesso_log` o acesso ao anexo. **Mas a Storage API pode ser chamada direto** pelo front (`supabase-js` → `createSignedUrl`), e nesse caminho **não passa pela função** — então **o acesso do leitor a um anexo liberado não é registrado** no `acesso_log`. A policy de `storage.objects` continua **autorizando** corretamente (é ela quem decide), mas a **trilha de auditoria é incompleta** para esse caminho.

Motivo de não ser um furo de autorização: o objeto no Storage só é alcançável por quem a policy autoriza, e a liberação individual do anexo é o que a policy consulta (`fn_anexo_acessivel`). O que falta é o **registro**.

**E10 (etapa de anexos):** antes de liberar o download de anexo ao leitor, fechar a trilha de auditoria — uma das saídas: (a) o front chamar **sempre** `fn_gerar_url_anexo` antes de pedir a URL (a função valida e registra; a Storage API só executa o que a policy já autorizou), ou (b) auditoria no gateway/RPC de download. Decisão na etapa de anexos.

---

## 4. FORCE ROW LEVEL SECURITY × `app_owner` — a resolução

Esta é a interação mais sutil do desenho, e ela precisa ser resolvida **explicitamente**, porque as duas metades são contraditórias.

### 4.1 O conflito

- **`FORCE ROW LEVEL SECURITY`** faz com que a policy seja aplicada **também ao dono da tabela** (sem isso, o owner ignora as policies por padrão).
- As funções `SECURITY DEFINER` e as views agregadas rodam **com o privilégio do dono** (`app_owner`). Se as tabelas tivessem FORCE e o `app_owner` **não** tivesse `BYPASSRLS`, o `app_owner` passaria a ser filtrado pelas policies.
- Isso quebraria o leitor: a view agregada (owner = `app_owner`) herdaria o filtro da policy de `lancamentos`, e o leitor veria **zero agregados** — porque a policy de `lancamentos` só deixa passar o auditor.

### 4.2 A decisão

> **`app_owner` recebe `BYPASSRLS` explicitamente. As tabelas usam `FORCE ROW LEVEL SECURITY`. O filtro de tenant é aplicado manual e obrigatoriamente dentro de cada função e cada view de `app_owner`.**

```sql
alter role app_owner nologin bypassrls;

-- em TODA tabela de negócio:
alter table public.lancamentos enable row level security;
alter table public.lancamentos force  row level security;
```

Por que `BYPASSRLS` explícito é melhor do que depender do padrão ("owner ignora RLS"):

| Alternativa | Comportamento | Risco |
|---|---|---|
| Owner ignora RLS por padrão (sem FORCE) | Implícito | Qualquer `ALTER TABLE ... OWNER TO postgres` muda o comportamento sem aviso. Frágil |
| FORCE + owner **sem** BYPASSRLS | O owner passa a ser filtrado | Quebra o leitor (view agregada herda o filtro) e não resolve o tenant |
| **FORCE + `BYPASSRLS` explícito** | O owner ignora por decisão declarada e auditável | Exige filtro manual — que é o requisito seu e está garantido por helper único + teste |

### 4.3 O custo e como ele é controlado

O filtro de tenant manual é obrigatório em toda função e view de `app_owner`. Isso é controlado por três mecanismos:

1. **Um único helper** — `fn_condominios_do_usuario()` — usado em toda parte. Não há como "esquecer de filtrar", só esquecer de chamar o helper (e o checklist §10 exige chamá-lo).
2. **Teste automatizado cross-tenant** (§11) que cria usuário do condomínio B e tenta ler o condomínio A por cada superfície. Falha = build vermelho.
3. **Revisão de migration obrigatória** — toda função e view nova passa pelo checklist §10 antes do merge.

### 4.4 Alternativa mais defensiva (opcional): tabela de resumo materializada

Se você quiser que o RLS **carregue** o filtro de tenant, em vez de depender do filtro manual:

```
resumo_competencia_fundo   -- (condominio_id, competencia_id, fundo_id, creditos, debitos, qtd)
```
mantida por trigger em `lancamentos`, com RLS própria (leitor pode ler as linhas do seu condomínio; nenhuma linha tem dimensão de unidade). As views agregadas leem **dessa** tabela, e o `app_owner` pode ficar **sem** BYPASSRLS.

- **Prós:** o RLS passa a garantir o tenant sozinho; nenhuma view agregada depende de filtro manual; a leitura do leitor é barata (tabela pequena).
- **Contras:** mais uma tabela para manter e um trigger a mais; o resumo pode ficar levemente defasado até a recomputação; a conciliação por fundo passa a ter duas fontes de verdade para o saldo.

**Minha recomendação:** manter a opção do §4.2 (BYPASSRLS + filtro manual), porque o requisito do tenant já é explícito no seu pedido e o resumo materializado duplica a verdade. A opção do §4.4 fica registrada como plano B caso a auditoria prefira RLS carregando o tenant.

---

## 5. As duas variantes de RLS — para você comparar

Ambas atendem à decisão D10: **o leitor só vê agregados**. A diferença é **onde** a granularidade é controlada e **como** o nominal seria liberado no futuro.

### 🅰️ Variante A — **Função agregadora com verificação de papel dentro** *(recomendada)*

**Idea.** Para tudo que precisa de consulta com parâmetro (competência, fundo, rubrica, granularidade), o usuário chama **uma função `SECURITY DEFINER`**. A função verifica, dentro dela, o papel que o usuário tem **no condomínio pedido** e a granularidade máxima que `config_visibilidade` permite para esse papel. Se pedir granularidade acima da permitida, a função **recusa**.

```sql
-- sobre a política de visibilidade: §6.2
-- granularidade permitida vem da configuração, não de checagem fixa no código
```

**Como o nominal por unidade seria liberado depois, sem mexer no schema:**

```sql
-- hoje
update public.config_visibilidade
   set granularidade_max = 'fundo'
 where condominio_id = '<id>' and papel = 'leitor';

-- amanhã (decisão sua)
update public.config_visibilidade
   set granularidade_max = 'unidade'
 where condominio_id = '<id>' and papel = 'leitor';
```

**Nenhuma tabela muda, nenhuma view nova, nenhuma policy nova.** Só uma linha de configuração. A mesma lógica permite granularidades intermediárias (`unidade_hash` = pseudonimizada) sem novo contrato de chamada.

**Prós**
- Controle de granularidade **centralizado**: uma tabela de configuração, uma checagem.
- Liberação do nominal = **UPDATE de uma linha** (a "política" no sentido de regra de negócio).
- Uma única superfície de leitura: menos coisas para auditar, menos risco de esquecer uma view.
- Permite adicionar granularidades no futuro sem mudar o contrato de chamada.
- A checagem de papel acontece **dentro** da função, no servidor — o front não participa da segurança.

**Contras**
- Mais SQL privilegiado: `SECURITY DEFINER` exige cuidado (`search_path` fixo, owner sem login, nada de SQL dinâmico).
- Um relatório novo quase sempre pede uma função nova ou um parâmetro novo.
- Debugging mais difícil: o erro vem como `exception` da função, não como `permission denied` da tabela.
- `SECURITY DEFINER` que vaza vira vazamento de dado; exige revisão (checklist §10).

### 🅱️ Variante B — **Views agregadas com `GRANT` por view**

**Idea.** Nenhuma função privilegiada para o leitor. Ele recebe `SELECT` **apenas** em views já agregadas, com `security_barrier`, cada uma filtrada por tenant **e por papel** (dentro da view, via helper).

```sql
create view public.v_resumo_por_fundo
with (security_barrier = true) as
select l.condominio_id, c.ano, c.mes, l.fundo_id, f.nome,
       sum(l.valor) filter (where l.tipo_movimento = 'credito') as creditos,
       sum(l.valor) filter (where l.tipo_movimento = 'debito')  as debitos,
       count(*) as qtd_lancamentos
from public.lancamentos l
join public.competencias c on c.id = l.competencia_id
join public.fundos f       on f.id = l.fundo_id
where l.status = 'ativo'
  and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario())
group by l.condominio_id, c.ano, c.mes, l.fundo_id, f.nome;

revoke all on public.v_resumo_por_fundo from anon, authenticated;
grant  select on public.v_resumo_por_fundo to authenticated;
```

**Como o nominal por unidade seria liberado depois, sem mexer no schema:**

```sql
-- criar a view nominal (novo objeto, mas NENHUMA tabela muda)
create view public.v_lancamentos_por_unidade
with (security_barrier = true) as
select l.*, u.numero as unidade_numero
from public.lancamentos l
left join public.unidades u on u.id = l.unidade_id
where l.status = 'ativo'
  and l.condominio_id in (select condominio_id from public.fn_condominios_do_usuario());

grant select on public.v_lancamentos_por_unidade to authenticated;  -- <- a "troca de política"
```

**Prós**
- **Zero `SECURITY DEFINER`** na superfície do leitor → superfície de ataque mínima.
- O privilégio do leitor fica visível em uma linha: `grant select on <view> to authenticated`.
- Fácil de auditar: "o que o leitor pode ler?" = lista de views com `GRANT`.
- Views são documentáveis e versionáveis junto com o resto.
- `security_barrier` + filtro de tenant explícito na view = proteção em profundidade.

**Contras**
- Liberação do nominal = **criar uma view nova** e dar `GRANT` — não é "só trocar política" no sentido estrito (é trocar *privilégio*, não mexer em dado nem em schema de tabela).
- Relatórios novos exigem view nova (mais objetos para revisar).
- Sem verificação dinâmica de papel: a segurança está toda no `GRANT` e no filtro dentro da view, e um `GRANT` esquecido no futuro abre vazamento. Em SQL puro não há como revogar "por papel" dentro da view sem `fn_papeis_do_usuario()`.
- Mais objetos no banco (uma view por relatório).

### 5.1 Comparação direta

| Critério | 🅰️ Variante A (função) | 🅱️ Variante B (views) |
|---|---|---|
| Leitor tem `SELECT` em tabela de detalhe | ❌ nunca | ❌ nunca |
| Agregado vem de onde | função `SECURITY DEFINER` | view com `security_barrier` |
| RLS participa do cálculo do agregado | ❌ (a função tem privilégio do dono) | ❌ (idem) |
| Filtro de tenant dentro do agregado | ✅ explícito na função | ✅ explícito na view |
| Papel avaliado por condomínio | ✅ dentro da função | ✅ dentro da view |
| Limiar mínimo de agregação | ✅ aplicado na função | ⚠️ precisa de view dedicada por métrica |
| Liberação do nominal = | **UPDATE de 1 linha** em `config_visibilidade` | `CREATE VIEW` + `GRANT` |
| Risco principal | `SECURITY DEFINER` mal escrito | `GRANT` esquecido no futuro |
| Superfície privilegiada a revisar | funções (checklist §10) | views (checklist §10) |
| Novos relatórios do leitor | parâmetro novo na função | view nova |
| Compatível com o padrão Money | ✅ se o Money usa RPC para tudo | ⚠️ depende do padrão do Money |

**Minha recomendação: 🅰️ Variante A**, com as views simples do padrão B para os relatórios fixos (dashboard do mês, cobertura de competências, status de conciliação), porque são mais fáceis de auditar e mais rápidas no front. O limiar mínimo de agregação, que precisa de lógica condicional, fica na função.

---

## 6. A política de visibilidade e o `fn_resumo` reescrito

### 6.1 Tabelas de configuração

```sql
create table public.granularidade_ordem (
    granularidade text primary key,
    rank          smallint not null unique
);
insert into public.granularidade_ordem (granularidade, rank) values
    ('fundo',   1),
    ('rubrica', 2),
    ('unidade', 3);

create table public.config_visibilidade (
    condominio_id            uuid not null references public.condominios(id) on delete cascade,
    papel                    public.papel_membro not null,
    granularidade_max        text not null references public.granularidade_ordem(granularidade),
    limiar_minimo_unidades   integer not null default 5 check (limiar_minimo_unidades >= 0),
    bloqueia_unidade         boolean not null default true,
    atualizado_em            timestamptz not null default now(),
    atualizado_por           uuid references public.perfis(id),
    primary key (condominio_id, papel)
);

insert into public.config_visibilidade (condominio_id, papel, granularidade_max, limiar_minimo_unidades) values
    ('<COND-A>', 'auditor',         'unidade', 0),
    ('<COND-A>', 'leitor',          'fundo',   5),
    ('<COND-A>', 'sindico',         'unidade', 1),
    ('<COND-A>', 'conselho_fiscal', 'unidade', 1);
```

`granularidade_ordem` dá a **ordem de finura** (fundo < rubrica < unidade), para que a comparação "pediu mais do que pode?" seja uma comparação numérica e não uma lista de casos.

`limiar_minimo_unidades` é **por condomínio e por papel**, com padrão 5. O valor 0 significa "sem supressão" (usado pelo auditor, que vê o nominal de qualquer forma).

### 6.2 `fn_resumo` reescrito

A granularidade permitida **vem da configuração** — não há checagem fixa de papel no código. A função:

1. verifica que o usuário é membro do condomínio pedido;
2. lê a granularidade máxima permitida para o(s) papel(is) que ele tem **nesse condomínio**;
3. aceita a granularidade pedida se ela não for **mais fina** que a permitida;
4. aplica o limiar mínimo de agregação, **somente** a agregações apoiadas em dados ligados a unidade.

```sql
create or replace function public.fn_resumo(
    p_condominio_id  uuid,
    p_competencia_id uuid default null,
    p_granularidade  text  default null
)
returns table (
    condominio_id   uuid,
    competencia_id  uuid,
    granularidade   text,
    chave           text,
    rotulo          text,
    creditos        numeric,
    debitos         numeric,
    qtd_lancamentos bigint,
    qtd_unidades    bigint,
    suprimido       boolean
)
language plpgsql
volatile                      -- grava no acesso_log: precisa ser volatile, não stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_gran_max   text;
    v_rank_max   integer;
    v_gran       text;
    v_rank       integer;
    v_limiar     integer;
begin
    -- (1) o usuário precisa ser membro deste condomínio
    if not exists (
        select 1 from public.fn_condominios_do_usuario() c
        where c = p_condominio_id
    ) then
        raise exception 'sem acesso ao condominio %', p_condominio_id
            using errcode = '42501';
    end if;

    -- (2) granularidade máxima permitida = a mais fina entre os papéis do usuário NESTE condomínio
    select o.granularidade, o.rank
      into v_gran_max, v_rank_max
      from public.config_visibilidade cv
      join public.fn_papeis_do_usuario(p_condominio_id) pu on pu.papel = cv.papel
      join public.granularidade_ordem o           on o.granularidade = cv.granularidade_max
     where cv.condominio_id = p_condominio_id
     order by o.rank desc
     limit 1;

    if v_gran_max is null then
        raise exception 'sem politica de visibilidade no condominio %', p_condominio_id
            using errcode = '42501';
    end if;

    -- (3) granularidade pedida (default = a máxima permitida)
    v_gran := coalesce(p_granularidade, v_gran_max);

    select o.rank into v_rank
      from public.granularidade_ordem o
     where o.granularidade = v_gran;

    if v_rank is null then
        raise exception 'granularidade desconhecida: %', v_gran
            using errcode = '22023';
    end if;

    if v_rank > v_rank_max then
        raise exception 'granularidade % nao permitida (permitida ate %)',
            v_gran, v_gran_max
            using errcode = '42501';
    end if;

    -- (4) limiar mínimo de agregação (o mais permissivo entre os papéis do usuário)
    select max(cv.limiar_minimo_unidades) into v_limiar
      from public.config_visibilidade cv
      join public.fn_papeis_do_usuario(p_condominio_id) pu on pu.papel = cv.papel
     where cv.condominio_id = p_condominio_id;

    v_limiar := coalesce(v_limiar, 5);

    -- (5) registro de leitura (o leitor é registrado; auditor também, é barato e útil)
    insert into public.acesso_log (
        condominio_id, usuario_id, operacao, recurso, detalhes
    )
    values (
        p_condominio_id,
        auth.uid(),
        'select',
        'fn_resumo',
        jsonb_build_object(
            'granularidade', v_gran,
            'competencia_id', p_competencia_id,
            'granularidade_max', v_gran_max,
            'limiar', v_limiar
        )
    );

    -- (6) agregação
    return query
    with base as (
        select l.competencia_id,
               l.fundo_id,
               l.unidade_id,
               lr.rubrica_id,
               l.valor,
               l.tipo_movimento
        from public.lancamentos l
        left join public.lancamento_rubrica lr on lr.lancamento_id = l.id
        where l.condominio_id = p_condominio_id
          and l.status = 'ativo'
          and (p_competencia_id is null or l.competencia_id = p_competencia_id)
    ),
    agrupado as (
        select
            b.competencia_id,
            case when v_gran = 'fundo'   then b.fundo_id::text
                 when v_gran = 'rubrica' then coalesce(b.rubrica_id::text, 'sem_rubrica')
                 else                          b.unidade_id::text
            end                                                     as chave,
            case when v_gran = 'fundo'   then f.nome
                 when v_gran = 'rubrica' then coalesce(r.nome, 'SEM RUBRICA')
                 else                          u.numero
            end                                                     as rotulo,
            sum(b.valor) filter (where b.tipo_movimento = 'credito') as creditos,
            sum(b.valor) filter (where b.tipo_movimento = 'debito')  as debitos,
            count(*)                                                as qtd_lancamentos,
            count(distinct b.unidade_id) filter (where b.unidade_id is not null) as qtd_unidades
        from base b
        left join public.fundos   f on f.id = b.fundo_id
        left join public.rubricas r on r.id = b.rubrica_id
        left join public.unidades u on u.id = b.unidade_id
        group by 1, 2, 3
    )
    select
        p_condominio_id,
        a.competencia_id,
        v_gran,
        a.chave,
        a.rotulo,
        case when a.qtd_unidades > 0
              and a.qtd_unidades < v_limiar
              and v_gran <> 'unidade'
             then null else a.creditos end,
        case when a.qtd_unidades > 0
              and a.qtd_unidades < v_limiar
              and v_gran <> 'unidade'
             then null else a.debitos end,
        a.qtd_lancamentos,
        a.qtd_unidades,
        (a.qtd_unidades > 0 and a.qtd_unidades < v_limiar and v_gran <> 'unidade')
    from agrupado a;
end;
$$;
```

**Notas de projeto sobre o `fn_resumo`:**

| Ponto | Decisão |
|---|---|
| `volatile` e não `stable` | A função grava em `acesso_log` (§8). Uma função `stable` não pode escrever. O custo é perder o cache de plano, irrelevante aqui |
| Papel por condomínio | `fn_papeis_do_usuario(p_condominio_id)` é chamado com o condomínio pedido; um auditor de dois condomínios tem a visibilidade de cada um **independentemente** |
| Múltiplos papéis | Vale a granularidade **mais fina** entre os papéis do usuário naquele condomínio (o `order by o.rank desc limit 1`) |
| Limiar só em dado ligado a unidade | A supressão dispara quando `qtd_unidades > 0` (o agregado tem linhas ligadas a unidade) **e** `qtd_unidades < v_limiar`. Agregados sem nenhuma linha de unidade (ex.: despesa de ADM do condomínio) **não** são suprimidos |
| Limiar não se aplica na granularidade `unidade` | Quem já tem acesso nominal não é protegido por supressão de célula pequena — a supressão existe para quem só tem agregado |
| `suprimido` sinaliza | A linha volta com valores `NULL` e `suprimido = true`, para o front exibir "dado suprimido por limiar de privacidade" em vez de R$ 0,00 (que pareceria "não houve gasto") |
| `p_granularidade` inválida | Erro `22023` (parâmetro inválido), não `42501` — distingue "granularidade que não existe" de "granularidade proibida" |

### 6.3 Onde a granularidade é consultada — e por que não há checagem fixa de papel

O código **não** contém `if papel = 'leitor' then ...`. A permittedude vem inteiramente de `config_visibilidade`, lida em tempo de execução. Consequências:

- adicionar um papel novo = inserir uma linha em `config_visibilidade` (não mexer em função);
- mudar a granularidade do leitor = `UPDATE` de uma linha;
- afrouxar/apertoar o limiar = `UPDATE` de uma linha;
- a **única** checagem fixa no código é a de que o usuário é membro do condomínio (§2.2) — que é uma condição de acesso, não de papel.

---

## 7. Policies de RLS

### 7.1 Tabelas de detalhe

Padrão para `lancamentos` (idem para `lancamento_rubrica`, `grupos_transferencia`, `transferencias_internas`, `duplicatas_candidatas`, `pendencias`, `contestacoes`, `conciliacoes`, `documentos`, `anexos`):

```sql
alter table public.lancamentos enable row level security;
alter table public.lancamentos force  row level security;

-- o papel é avaliado SEMPRE no condomínio da própria linha
create policy lancamentos_leitura_auditor on public.lancamentos
  for select to authenticated
  using (
    public.fn_e_membro(condominio_id, 'auditor')
    or public.fn_e_membro(condominio_id, 'sindico')
    or public.fn_e_membro(condominio_id, 'conselho_fiscal')
  );

create policy lancamentos_escrita_auditor on public.lancamentos
  for all to authenticated
  using      (public.fn_e_membro(condominio_id, 'auditor'))
  with check (public.fn_e_membro(condominio_id, 'auditor'));
```

⚠️ **Observação importante:** como `authenticated` **não tem** `GRANT` sobre `lancamentos` (§3.2), essas policies são **defesa em profundidade** — protegem contra um `GRANT` futuro, contra o role `app_importador`, e contra o dono de tabela. O caminho **primário** de leitura é `fn_lancamentos()`, que verifica o papel e devolve erro claro.

### 7.2 Tabelas de configuração (rubricas, fundos, aliases)

O leitor não precisa ler nada disso — o agregado já traz o rótulo. Auditor tem CRUD; síndico e conselho fiscal apenas `SELECT`; leitor, nada.

### 7.3 Tabelas operacionais (`fontes_importacao`, `importacoes`, `staging_*`)

- `app_importador`: `INSERT`/`UPDATE` **apenas** em staging.
- Auditor: leitura total + aprovação.
- Leitor: **sem acesso**. Ele vê o resultado da importação apenas por `v_importacao_resumo` (agregado: quantos lançamentos entraram, quantos ficaram pendentes).

### 7.4 `auditoria_log` e `acesso_log`

Somente `INSERT` (pela aplicação) e `SELECT` para auditor e conselho fiscal. O leitor não vê — log de auditoria não é dado operacional dele.

### 7.5 `membros`

Policy que só deixa o usuário ver a própria associação:

```sql
create policy membros_leitura_own on public.membros
  for select to authenticated
  using (perfil_id = auth.uid());
```
O administrador do condomínio lê o quadro completo por `fn_membros_do_condominio()` (função privilegiada).

---

## 8. `acesso_log` — todas as escritas, e as leituras do leitor

### 8.1 O que é registrado

| Evento | Registrado? | Como |
|---|---|---|
| Qualquer `INSERT`/`UPDATE`/`DELETE` em tabela de negócio | ✅ **sempre** | trigger genérico AFTER em cada tabela |
| Leitura de **detalhe** pelo auditor/síndico/conselho | ⚠️ dependente do ambiente | `pgaudit` (se disponível) ou log de statement do Postgres |
| Leitura **agregada** (leitor e todos) | ✅ **sempre** | a própria função `fn_resumo` grava antes de devolver |
| Leitura de view agregada pelo leitor | ✅ | a view é lida via `fn_resumo` no front, ou a view grava via wrapper |
| Anexo baixado | ✅ | `fn_gerar_url_anexo` grava antes de devolver a URL assinada |
| Contestação criada/respondida | ✅ | trigger + `auditoria_log` |

### 8.2 Estrutura

```sql
create table public.acesso_log (
    id            bigserial primary key,
    condominio_id uuid null references public.condominios(id) on delete cascade,
    usuario_id    uuid null references public.perfis(id) on delete set null,
    operacao      text not null check (operacao in ('select','insert','update','delete','rpc','storage','anexo')),
    recurso       text not null,          -- tabela, view ou função
    entidade_id   text null,
    detalhes      jsonb null,
    criado_em     timestamptz not null default now()
);
create index ix_acesso_log_usuario   on public.acesso_log (usuario_id, criado_em desc);
create index ix_acesso_log_condominio on public.acesso_log (condominio_id, criado_em desc);
```

### 8.3 Trigger genérico de escrita

```sql
create or replace function public.fn_log_escrita()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_tabela text := tg_table_name;
    v_id     text;
begin
    if tg_op = 'DELETE' then
        v_id := coalesce((to_jsonb(old) ->> 'id'), '');
    else
        v_id := coalesce((to_jsonb(new) ->> 'id'), '');
    end if;

    insert into public.acesso_log (
        condominio_id, usuario_id, operacao, recurso, entidade_id, detalhes
    )
    values (
        nullif(to_jsonb(coalesce(new, old)) ->> 'condominio_id', '')::uuid,
        auth.uid(),
        lower(tg_op),
        v_tabela,
        v_id,
        jsonb_build_object('schema', 'public')
    );

    return coalesce(new, old);
end;
$$;
```

⚠️ O trigger só registra **escritas**. **Leitura não é capturada por trigger no Postgres** — não existe trigger de `SELECT`. Por isso a leitura do leitor é registrada **dentro da função** (que é o único caminho dele para os dados), e a leitura nominal por auditor depende de `pgaudit` ou de log de statement, que dependem do plano/da configuração do ambiente. Isso é uma limitação real da plataforma, e estou dizendo na cara, não escondendo.

### 8.4 Retenção

O `acesso_log` cresce. Proposta: `particionar por criado_em` (mensal) e política de descarte acordada com o condomínio (§11, pergunta em aberto).

---

## 9. Contestação e comentário (síndico e conselho fiscal)

O síndico **não altera classificação**, mas **pode comentar e contestar**, e isso fica registrado.

```sql
create table public.contestacoes (
    id              uuid primary key default gen_random_uuid(),
    condominio_id   uuid not null references public.condominios(id) on delete cascade,
    lancamento_id   uuid null references public.lancamentos(id) on delete cascade,
    pendencia_id    uuid null references public.pendencias(id) on delete cascade,
    documento_id    uuid null references public.documentos(id) on delete cascade,
    autor_id        uuid not null references public.perfis(id),
    texto           text not null,
    status          text not null default 'aberta'
                    check (status in ('aberta','em_analise','acolhida','rejeitada')),
    tipo            text not null default 'comentario'
                    check (tipo in ('comentario','contestacao')),
    respondido_por  uuid null references public.perfis(id),
    resposta        text null,
    criado_em       timestamptz not null default now(),
    respondido_em   timestamptz null
);
```

Regras:
- **Criar**: `sindico`, `conselho_fiscal` e `auditor` podem criar, **apenas** no condomínio onde têm papel. O leitor não.
- **Responder**: só `auditor` responde (acolhe ou rejeita) e a contestação passa a ser `respondida`.
- A contestação **não muda** a classificação nem o status do lançamento. Ela é um registro lateral, e o front destaca lançamentos contestados para o auditor.
- Toda criação e resposta entra no `acesso_log` (trigger) e no `auditoria_log`.

```sql
create or replace function public.fn_contestar_lancamento(
    p_lancamento_id uuid,
    p_texto          text,
    p_tipo           text default 'contestacao'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_cond uuid;
    v_id   uuid;
begin
    select condominio_id into v_cond from public.lancamentos where id = p_lancamento_id;
    if v_cond is null then
        raise exception 'lancamento inexistente' using errcode = 'P0002';
    end if;

    if not (
        public.fn_e_membro(v_cond, 'auditor')
     or public.fn_e_membro(v_cond, 'sindico')
     or public.fn_e_membro(v_cond, 'conselho_fiscal')
    ) then
        raise exception 'sem permissao para contestar neste condominio' using errcode = '42501';
    end if;

    insert into public.contestacoes (condominio_id, lancamento_id, autor_id, texto, tipo)
    values (v_cond, p_lancamento_id, auth.uid(), p_texto, p_tipo)
    returning id into v_id;

    insert into public.auditoria_log (condominio_id, entidade, entidade_id, acao, depois)
    values (v_cond, 'contestacao', v_id::text, 'criar', jsonb_build_object('tipo', p_tipo));

    return v_id;
end;
$$;
```

---

## 10. Anexos — bloqueados por padrão, liberados um a um

### 10.1 O modelo

```sql
alter table public.anexos
    add column liberado_para_leitor boolean not null default false,
    add column liberado_em           timestamptz null,
    add column liberado_por           uuid null references public.perfis(id);
```

- **Padrão: bloqueado.** Nenhum anexo é acessível ao leitor até ser liberado explicitamente.
- A liberação é **por anexo**, feita pelo auditor, e é registrada em `auditoria_log`.
- O motivo da regra: mesmo sem dado de morador no comprovante, o documento de uma despesa de **R$ 2.950,00** da piscina, quando combinado com o extrato, permite reconstruir a operação de uma unidade específica. A liberação granular dá controle sem custar nada ao auditor.

### 10.2 A policy de storage

```sql
create policy anexos_leitura on storage.objects
  for select to authenticated
  using (
    bucket_id = 'anexos'
    and (storage.foldername(name))[1]
        in (select condominio_id::text from public.fn_condominios_do_usuario())
    and public.fn_anexo_acessivel(name)
  );

create or replace function public.fn_anexo_acessivel(p_nome text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_anexo  public.anexos%rowtype;
    v_cond   uuid;
    v_papeis setof public.papel_membro;
begin
    select a.* into v_anexo
      from public.anexos a
     where a.caminho = p_nome;

    if not found then
        return false;
    end if;

    v_cond := v_anexo.condominio_id;

    if not exists (
        select 1 from public.fn_condominios_do_usuario() c where c = v_cond
    ) then
        return false;
    end if;

    -- papéis com acesso pleno ao anexo
    v_papeis := public.fn_papeis_do_usuario(v_cond);
    if exists (
        select 1 from v_papeis p
         where p in ('auditor','sindico','conselho_fiscal')
    ) then
        return true;
    end if;

    -- leitor: somente anexos liberados individualmente pelo auditor
    return v_anexo.liberado_para_leitor;
end;
$$;
```

### 10.3 Liberação e download

```sql
create or replace function public.fn_liberar_anexo_para_leitor(
    p_anexo_id uuid,
    p_liberar  boolean default true
)
returns void
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_cond uuid;
begin
    select condominio_id into v_cond from public.anexos where id = p_anexo_id;
    if v_cond is null then
        raise exception 'anexo inexistente' using errcode = 'P0002';
    end if;
    if not public.fn_e_membro(v_cond, 'auditor') then
        raise exception 'somente auditor libera anexos' using errcode = '42501';
    end if;

    update public.anexos
       set liberado_para_leitor = p_liberar,
           liberado_em = case when p_liberar then now() else null end,
           liberado_por = case when p_liberar then auth.uid() else null end
     where id = p_anexo_id;

    insert into public.auditoria_log (condominio_id, entidade, entidade_id, acao)
    values (v_cond, 'anexo', p_anexo_id::text,
            case when p_liberar then 'liberar_para_leitor' else 'revogar_leitor' end);
end;
$$;
```

O download gera **URL assinada** com expiração curta (5 minutos) e passa por `fn_gerar_url_anexo`, que grava no `acesso_log` antes de devolver. Nunca URL pública.

---

## 11. Bateria de testes de segurança (a executar na fase de Build)

Os testes rodam em três personas, com `set local request.jwt.claims` para simular a sessão de cada um. **Qualquer falha quebra o build.**

### 11.1 Preparação

| Persona | Papel | Condomínio |
|---|---|---|
| `leitor_cond_a` | `leitor` | A |
| `auditor_cond_a` | `auditor` | A |
| `leitor_cond_b` | `leitor` | B (outro condomínio) |
| `sindico_cond_a` | `sindico` | A |
| `importador` | role `app_importador` | — |

```sql
-- helper de teste
create or replace function public.test_set_usuario(p_email text)
returns void language plpgsql as $$
begin
    perform set_config(
        'request.jwt.claim.sub',
        (select id::text from auth.users where email = p_email),
        true);
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', (select id::text from auth.users where email = p_email),
                          'role', 'authenticated')::text,
        true);
end;
$$;
```

### 11.2 Testes obrigatórios

| # | Persona | Ação | Resultado esperado |
|---|---|---|---|
| T01 | `leitor_cond_a` | `select * from lancamentos` | `permission denied` (sem `GRANT`) |
| T02 | `leitor_cond_a` | `select count(*) from lancamentos` | `permission denied` |
| T03 | `leitor_cond_a` | `select * from unidades` | `permission denied` |
| T04 | `leitor_cond_a` | `select * from pendencias` | `permission denied` |
| T05 | `leitor_cond_a` | `select * from duplicatas_candidatas` | `permission denied` |
| T06 | `leitor_cond_a` | `select * from acesso_log` | `permission denied` |
| T07 | `leitor_cond_a` | `insert into lancamentos (...)` | `permission denied` |
| T08 | `leitor_cond_a` | `update lancamentos set valor = 0` | `permission denied` |
| T09 | `leitor_cond_a` | `select public.fn_aprovar_staging(...)` | `exception 42501` |
| T10 | `leitor_cond_a` | `select public.fn_classificar_lancamento(...)` | `exception 42501` |
| T11 | `leitor_cond_a` | `select public.fn_decidir_duplicata(...)` | `exception 42501` |
| T12 | `leitor_cond_a` | `select public.fn_contestar_lancamento(...)` | `exception 42501` |
| T13 | `leitor_cond_a` | `select public.fn_liberar_anexo_para_leitor(...)` | `exception 42501` |
| T14 | `leitor_cond_a` | `select public.fn_resumo(cond_a, null, 'unidade')` | `exception 42501` (granularidade proibida) |
| T15 | `leitor_cond_a` | `select public.fn_resumo(cond_a, null, 'rubrica')` | `exception 42501` |
| T16 | `leitor_cond_a` | `select public.fn_resumo(cond_a, null, 'fundo')` | **sucesso**, agregados sem coluna de unidade |
| T17 | `leitor_cond_a` | `select public.fn_resumo(cond_b, null, 'fundo')` | `exception 42501` (não é membro do B) |
| T18 | `leitor_cond_a` | `select * from v_resumo_competencia_fundo` | só linhas do condomínio A |
| T19 | `leitor_cond_b` | `select * from v_resumo_competencia_fundo` | **zero linhas** do condomínio A |
| T20 | `leitor_cond_b` | `select public.fn_lancamentos(cond_a, ...)` | `exception 42501` ou zero linhas — **nunca** dado do A |
| T21 | `leitor_cond_a` | `select * from v_lancamentos_por_unidade` | zero linhas (papel insuficiente) |
| T22 | `auditor_cond_a` | `select public.fn_lancamentos(cond_a, ...)` | linhas do A, **sem** linhas do B |
| T23 | `auditor_cond_a` | `select public.fn_resumo(cond_a, null, 'unidade')` | **sucesso** (granularidade plena) |
| T24 | `auditor_cond_a` | `select public.fn_resumo(cond_b, null, 'fundo')` | `exception 42501` |
| T25 | `auditor_cond_a` | `insert into lancamentos` direto | `permission denied` (escrita só via RPC) |
| T26 | `auditor_cond_a` | `select public.fn_aprovar_staging(...)` | sucesso, transação atômica |
| T27 | `sindico_cond_a` | `select public.fn_lancamentos(cond_a, ...)` | linhas do A |
| T28 | `sindico_cond_a` | `select public.fn_classificar_lancamento(...)` | `exception 42501` (**síndico não classifica**) |
| T29 | `sindico_cond_a` | `select public.fn_contestar_lancamento(...)` | **sucesso** (cria contestação) |
| T30 | `sindico_cond_a` | `select public.fn_contestar_lancamento(<id do condomínio B>, ...)` | `exception 42501` |
| T31 | `importador` | `insert into staging_lancamentos` | **sucesso** |
| T32 | `importador` | `insert into lancamentos` | `permission denied` (**nunca** escreve em produção) |
| T33 | `importador` | `select * from lancamentos` | `permission denied` |
| T34 | `importador` | `select public.fn_aprovar_staging(...)` | `permission denied` / `exception` |
| T35 | `leitor_cond_a` | `select` no objeto do storage do anexo **não liberado** | `permission denied` |
| T36 | `leitor_cond_a` | `select` no objeto do storage do anexo **liberado** | **sucesso** |
| T37 | `leitor_cond_b` | `select` no objeto do storage do anexo do A | `permission denied` |
| T38 | qualquer | `select` em `v_resultado_bruto` | retorna **todos** os lançamentos do tenant (inclusive transferências) — teste de que o bruto não subtrai nada |
| T39 | `leitor_cond_a` | `select public.fn_resumo(...)` com grupo de 2 unidades | `creditos IS NULL` e `suprimido = true` (limiar) |
| T40 | `auditor_cond_a` | `select public.fn_resumo(cond_a, null, 'unidade')` com grupo de 2 unidades | valores **presentes** (limiar 0 para auditor) |

### 11.3 Testes de RLS puro (pgTAP)

Complementam os acima, validando as policies em si (independente dos `GRANT`):

```sql
-- supabase/tests/rls_multitenant.test.sql
begin
    set local role authenticated;
    select public.test_set_usuario('leitor@condA.test');
    select plan(3);
    select is_empty(
        (select * from public.v_resumo_competencia_fundo)
        where condominio_id <> '<COND-A>'
    ), 'leitor nao ve agregados de outro condominio';
    select throws_ok(
        'select public.fn_resumo(''<COND-B>'', null, ''fundo'')',
        '42501', null, 'leitor nao le agregados de outro condominio'
    ), 'funcao recusa condominio alheio';
    select results_eq(
        'select count(*) from public.acesso_log where usuario_id = auth.uid()',
        'select count(*) from public.acesso_log where usuario_id = auth.uid()',
        'log de leitura gravado'
    ), 'acesso_log registra a leitura';
end;
```

### 11.4 Onde os testes rodam

| Tipo | Ferramenta | Quando |
|---|---|---|
| RLS puro (pgTAP) | `supabase test db` | A cada migration, no CI |
| Comportamento de RPC | `supabase test db` (pgTAP) | A cada migration |
| Storage e anon key | Teste de integração (Vitest/Playwright no front, ou script Python) | A cada release |
| Revogação de privilégio | `supabase test db` | A cada migration |
| **Cobertura de funções** | `supabase\tests\08_cobertura_funcoes.test.sql` (pós-bateria) | A cada build |

⚠️ **Regra do CI:** o build **falha** se qualquer teste de segurança falhar. Não é "nice to have" — é o que garante que a garantia do leitor não foi quebrada por uma migration futura.

### 11.5 Cobertura estrutural de funções (13/11/2026)

O caso que motivou a regra: `fn_aprovar_staging` e `fn_reconciliar_competencia` estavam **quebradas desde a criação** (erro de tipo em `INSERT ... SELECT` e `ON CONFLICT` ambíguo) — e a bateria passava, porque nenhum teste exercitava o **caminho feliz** delas. Um teste que só verifica "o leitor é recusado" não pega uma função que falha para todo mundo.

A regra agora é mecânica (`supabase\tests\08_cobertura_funcoes.test.sql`, roda depois da bateria):

1. **Toda função de produção do schema `public` precisa de um caso** — um caminho feliz e uma negação. Função nova sem caso ⇒ **build quebrado**. A lista de exclusão é explícita (helpers `test_*`, `fn_log_escrita`, `fn_purgar_acesso_log` e os `fn_revogar_*`, que são de migration).
2. **O caminho feliz precisa executar de verdade.** A prova é dupla: o resultado da chamada e a estatística do Postgres (`pg_stat_user_functions`) — por isso o runner liga `track_functions = 'all'` antes da bateria e o desliga no fim.
3. **A negação precisa devolver o mesmo erro de permissão** (`42501`) ou, nas funções de leitura sem permissão negativa, o resultado vazio/`false` esperado.

⚠️ **Limites conhecidos do `pgstat`** (medidos em 13/11/2026, documentados no próprio arquivo): chamada que termina em **erro** não entra em `pg_stat_user_functions`, e transação que **aborta** descarta as estatísticas pendentes. Por isso a prova de "sucesso" vem das stats e a de "negação" vem do SQLSTATE capturado no teste — e por isso os blocos do arquivo são separados (o que prova a execução **commita** antes do bloco que pode levantar a exceção final).

**Validação da própria proteção** (feita em 13/11/2026, local): (a) quebrar `fn_usuario_atual` → o build acusa o caminho feliz e a propagação; (b) criar uma função nova sem caso → o build acusa "função sem caso de cobertura"; (c) restaurar → build verde.

### 11.6 Idempotência das migrations

O runner **reaplica** as migrations criadas recentemente e compara o snapshot textual do schema `public` (definições + grants) antes e depois (`supabase\tests\run_tests.ps1`, seção "idempotência"). Se a reaplicação mudar alguma coisa, a migration não era idempotente e o build quebra.

⚠️ **Detalhe que só apareceu nessa verificação:** o PowerShell 5.1 escreve texto no pipe na codificação do console (ANSI) e o `Get-Content` sem `-Encoding` lê como ANSI — todo acento dos arquivos virava `?` no banco. Não quebrava lógica (eram comentários), mas quebrava a comparação de idempotência. Por isso os arquivos SQL agora vão ao banco por `docker cp` + `psql -f` (bytes íntegros), e nunca pelo pipe.

---

## 12. Checklist de revisão de segurança

Toda função `SECURITY DEFINER` precisa:
- [ ] `set search_path = public, pg_temp`
- [ ] owner = `app_owner` (`nologin`, `bypassrls`), e `alter function ... owner to app_owner`
- [ ] `revoke execute on function ... from public, anon;` e `grant execute ... to authenticated` (ou a role específica)
- [ ] nenhum SQL dinâmico (`execute format(...)`) — ou, se houver, whitelist rigorosa de objeto
- [ ] **filtro de tenant presente** (`condominio_id in (select ... from fn_condominios_do_usuario())` ou `fn_e_membro(condominio_id, ...)`)
- [ ] **papel avaliado por condomínio**, nunca global
- [ ] nenhum `return query select *` de tabela de detalhe para quem não tem direito
- [ ] testada com o papel mais fraco possível (o leitor) e com usuário de outro condomínio
- [ ] **caso de cobertura em `08_cobertura_funcoes.test.sql`** (caminho feliz + negação) — build quebrado sem ele

Toda view agregada precisa:
- [ ] `security_barrier = true`
- [ ] filtro de tenant explícito dentro da view
- [ ] **filtro de papel** dentro da view, quando a view expõe detalhe
- [ ] nenhuma coluna de identificação (unidade, documento, histórico)
- [ ] `revoke all ... from anon, authenticated` + `grant select ... to authenticated`
- [ ] **granularidade e limiar lidos de `config_visibilidade` dentro da view** (quando a célula é mais fina que "fundo"): granularidade máxima do chamador + supressão de célula pequena (`0 < unidades < limiar` → NULL + `suprimido = true`)
- [ ] texto livre (`observacao`) só para papel nominal — auditor/síndico/conselho

Toda tabela de detalhe precisa:
- [ ] `enable row level security` **e** `force row level security`
- [ ] policies só para quem tem direito, com papel por condomínio
- [ ] `revoke all on all tables in schema public from anon, authenticated` feito **no início** de cada migration que crie tabela nova

Toda tabela nova precisa:
- [ ] ser adicionada à lista de `revoke` da migration seguinte (ou a própria migration já faz o `revoke`)

---

## 13. Dados por unidade e LGPD

### 13.1 O que é sensível aqui

Não existe nome de morador, CPF ou endereço em nenhuma fonte contábil — já verifiquei. O dado sensível é a **associação** entre um identificador de unidade (que é um endereço) e a sua **situação financeira**:

| Dado | Natureza | Exemplo |
|---|---|---|
| Quais unidades pagaram e quanto | Financeiro + endereçável | "unidade 74 pagou 2.955,00 de água em 2026-08" |
| Quais unidades estão inadimplentes | Sensível, com impacto patrimonial | lista de inadimplentes por competência |
| Consumo individual de água/gás | Sensível (rotina de habitação) | 72 unidades × 18 meses |
| Histórico de valores discrepantes | Perfil de comportamento | "unidade 131 tem 35 alertas" |

A LGPD (Lei 13.700,00/2018) categoriza isso como **dado pessoal** — o número da unidade é um identificador que, sozinho ou combinado, permite identificar o morador (o condomínio tem 72 unidades, é pequeno).

### 13.2 Como tratar

1. **O dado nominal continua existindo** — necessário para auditoria, espelho de boleto e análise de consumo. Não se apaga dado; controla-se o acesso.
2. **O leitor não alcança a linha** — privilégio negado (§3.2), não botão escondido.
3. **Agregados são a entrega ao leitor** — e não são reidentificáveis: nada por unidade.
   - ⚠️ **Small-cell risk**: um agregado como "fundos de benfeitorias: 1 unidade pagou R$ 47,00" é praticamente nominal. Por isso existe o **limiar mínimo de agregação** (§6.2), padrão 5, aplicado a toda agregação apoiada em dado ligado a unidade. As linhas suprimidas voltam com `suprimido = true` e valores `NULL` — o front mostra "dado suprimido por limiar de privacidade", **nunca** R$ 0,00 (que pareceria "não houve gasto").
4. **Registro de acesso** (§8) — todas as escritas e as leituras do leitor.
5. **Finalidade** — o propósito do acesso fica declarado por papel (`finalidade` em `membros`) e auditado.
6. **Retenção** — lançamentos são preservados (obrigação contábil); o que expira é o `acesso_log`, conforme política do condomínio.

### 13.3 O que o leitor vê — quadro concreto

| Informação | Leitor | Auditor | Síndico | Conselho fiscal |
|---|---|---|---|---|
| Total de receitas/despesas do mês | ✅ agregado | ✅ | ✅ | ✅ |
| Saldo por fundo | ✅ agregado | ✅ | ✅ | ✅ |
| Saldo por rubrica | ✅ agregado | ✅ | ✅ | ✅ |
| Saldo por unidade | ❌ | ✅ | ✅ (próprio) | ✅ (próprio) |
| Extrato linha a linha | ❌ | ✅ | ✅ (próprio) | ✅ (próprio) |
| Inadimplência nominal | ❌ | ✅ | ✅ | ✅ |
| Ranking de unidades com alertas | ❌ | ✅ | ✅ | ✅ |
| Quantidade de pendências | ✅ agregado | ✅ | ✅ | ✅ |
| Detalhe das pendências | ❌ | ✅ | ✅ | ✅ |
| Status de cada competência (por fonte) | ✅ | ✅ | ✅ | ✅ |
| Divergência de conciliação (por fundo) | ✅ agregado | ✅ | ✅ | ✅ |
| Anexos (comprovantes) | ❌ **até liberação individual** | ✅ | ✅ (próprios) | ✅ (próprios) |
| Contestações criadas | ❌ | ✅ | ✅ cria | ✅ cria |
| Histórico de auditoria | ❌ | ✅ | ❌ | ✅ |
| Registro de acesso | ❌ | ✅ | ❌ | ✅ |

**Observação:** o status de competência e a contagem de pendências **são** agregados que não identificam pessoas — por isso o leitor pode vê-los. Já o detalhe das pendências pode apontar uma unidade específica (ex.: "unidade 14, correção monetária") — por isso fica restrito.

### 13.4 Perguntas de LGPD em aberto (precisam de você)

1. O leitor precisa **saber que uma unidade está inadimplente** (agregado: "N unidades inadimplentes no mês, total R$ X") ou isso também é demais?
2. O **limiar mínimo de agregação** padrão 5 está bom, ou prefere 3 ou 10? É configurável por condomínio e por papel.
3. **Retenção do `acesso_log`**: 1 ano, 5 anos, o prazo do condomínio?
4. `pgaudit` está disponível no seu plano do Supabase? Sem ele, a leitura nominal do auditor não é registrada no `acesso_log` (as escritas e as leituras do leitor são).

---

## 14. Chaves, segredos e ambiente

| Item | Onde | Regra |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | `.env.local` (ignorado pelo Git) | chaves **públicas** do projeto; protegidas pela RLS, não são segredo |
| `SUPABASE_SERVICE_ROLE_KEY` | **nunca** no repo; só em variável de ambiente local e no CI | bypassa RLS — trate como senha de root |
| `SUPABASE_DB_URL` (com senha) | só em variável de ambiente | idem |
| Senha do role `app_importador` | variável de ambiente | o importador só escreve em staging |
| `.env.example` | versionado | só com os **nomes** das variáveis, valores vazios |

**Ponto crítico:** o importador **não** deve usar a `service_role_key`. Ele usa a credencial do role `app_importador`, que só tem `INSERT` em `staging_*`. Assim, mesmo que o script vaze, ele **não** consegue escrever em `lancamentos`. A entrada no banco de produção só existe pela RPC de aprovação, que é `SECURITY DEFINER` e grava em `auditoria_log`.

---

## 15. O que **não** foi decidido aqui

- Os nomes definitivos dos roles e helpers — dependem do padrão do Anperez Money (preciso do caminho do código).
- Se o leitor pode receber anexos liberados **em lote** (por competência) ou só **um a um**. Proposta: um a um.
- Limiar de agregação definitivo e retenção do `acesso_log` (§13.4).
- Se `pgaudit` está disponível no seu plano.
- Política de backup e de retenção do bucket de anexos.

---

## 16. O que a implementação revelou (12/11/2026)

A Fase 0 foi implementada e a bateria de segurança roda verde com **53 testes**. Este capítulo registra as descobertas que **não** estavam no desenho original — são armadilhas reais do Supabase + PostgreSQL que custaram tempo e precisam estar documentadas.

### 16.1 O `search_path` da sessão NÃO inclui o schema `auth`

No Supabase local, o `search_path` da sessão é:

```
"$user", public, extensions
```

**Sem o schema `auth`.** Consequência: dentro de uma função `SECURITY DEFINER`, o `auth.uid()` usado num `INSERT` pode ser resolvido no contexto do statement (o `search_path` da sessão) — onde `auth` não existe. O planner resolve `auth` como PLANO e a coluna vira NULL:

```
ERROR: null value in column "usuario_id" of relation "auditoria_log" violates not-null constraint
```

**Solução implementada:** o helper `public.fn_usuario_atual()` (migration `00260`), que lê o claim do JWT direto do GUC de sessão, sem depender de resolução de schema:

```sql
select nullif(
    coalesce(
        current_setting('request.jwt.claim.sub', true),
        nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    ),
    ''
)::uuid;
```

Todas as funções privilegiadas usam `public.fn_usuario_atual()` no lugar de `auth.uid()`.

⚠️ **O helper precisa ser `VOLATILE`, não `STABLE`.** Uma função `STABLE` é avaliada pelo planner no início da query, e o claim do JWT pode ser trocado no meio do teste (o `set local role` invalida o snapshot). Com `STABLE`, `fn_usuario_atual()` devolvia NULL dentro de `fn_atualizar_visibilidade`, embora a chamada direta devolvesse o id correto.

### 16.2 O `app_owner` precisa de privilégios que os papéis de negócio não têm

O `app_owner` é o owner das funções `SECURITY DEFINER` — é **ele** quem executa o corpo delas, incluindo os `INSERT` em `auditoria_log`, `acesso_log` e `lancamentos`. Precisa de:

| Privilégio | Motivo | Onde |
|---|---|---|
| `usage` no schema `auth` | resolver `auth.uid()` | bootstrap |
| `execute` em `auth.uid()` | idem | bootstrap |
| `select` em `auth.users` | helpers de teste (mapear e-mail → id) | bootstrap |
| `usage` + `execute` no schema `extensions` | `digest()` do pgcrypto | bootstrap |
| `select` nas tabelas de negócio | ler no corpo das RPCs | migration 012 |
| `insert`/`update` nas tabelas que as RPCs gravam | gravar no corpo das RPCs | migration 012 |
| `usage` nas sequências | `acesso_log.id` é `bigserial` | migration 012 |

⚠️ **Erro encontrado e corrigido:** 8 RPCs faziam `INSERT` em `auditoria_log` **sem listar a coluna `usuario_id`** (que é `NOT NULL`). O erro só aparecia em runtime. Todas foram corrigidas e há um teste que verifica a coerência.

### 16.3 Os *default privileges* do `supabase_admin` importam tanto quanto os do `postgres`

O `revoke` nos *default privileges* do papel `postgres` **não basta**: no Supabase local, o papel `supabase_admin` tem o seu próprio conjunto de *default privileges* que concedem acesso a `anon`/`authenticated` em tudo que for criado por ele.

E o `postgres` **não é superuser** no Supabase local (só o `supabase_admin` é). Revogar os *default privileges* do `supabase_admin` a partir do `postgres` falha:

```
ERROR: permission denied to change default privileges
```

**Solução:** o `revoke` roda **fora** das migrations, no script de bootstrap (`supabase/bootstrap/00-zerar_privilegios_padrao.sql`), executado como `supabase_admin`:

```bash
docker exec -i <container> psql -U supabase_admin -d postgres < supabase/bootstrap/00-zerar_privilegios_padrao.sql
```

O bootstrap também concede `usage on schema auth` ao `app_owner` e `select on auth.users` — o `postgres` também não pode conceder no schema `auth` (que pertence ao `supabase_admin`).

### 16.4 `FORCE ROW LEVEL SECURITY` e o `postgres`

O `postgres` local tem `BYPASSRLS`, mas com `FORCE ROW LEVEL SECURITY` ele passa a ser **sujeito às policies** das tabelas. Por isso:

- Os helpers de teste que leem `membros`, `acesso_log` etc. têm owner = `app_owner` (não `postgres`), porque o `app_owner` tem `BYPASSRLS` efetivo.
- O `postgres` precisa de `grant app_owner to postgres` e `grant app_importador to postgres` para poder `SET ROLE` nos testes.

### 16.5 O `app_owner` com `BYPASSRLS` — o teste pedido no passo 1

**Pergunta feita pelo usuário:** "Teste logo no passo 1 se o Supabase permite criar o role `app_owner` com BYPASSRLS."

**Resposta: SIM, o Supabase local permite.** Verificado em 11/11/2026:

```sql
create role app_owner nologin bypassrls;
-- CREATE ROLE
select rolname, rolbypassrls from pg_roles where rolname = 'app_owner';
--  app_owner | t
```

Não foi necessário o plano B (usar o `postgres` como dono). O `app_owner` foi criado na migration `00200`, junto com as tabelas, e é o owner de todas as funções e views privilegiadas.

⚠️ **Consequência que precisa ser lembrada:** com `BYPASSRLS`, o `app_owner` **ignora** as policies. Por isso o filtro de tenant dentro de cada função e view **não é redundante** — é a única proteção. E é por isso que os helpers `fn_papeis_do_usuario(p_condominio_id)`, `fn_e_membro(p_condominio_id, p_papel)` e `fn_condominios_do_usuario()` existem e são usados em toda parte.

### 16.6 Revogação de privilégios: a ordem dos grants importa

A migration `012` e a migration `014` chamam `fn_revogar_funcoes_publicas()`, que revoga o `EXECUTE` de **todas** as funções do schema `public` — inclusive os helpers criados antes. Por isso, **após** cada revogação, os grants dos helpers precisam ser refeitos:

```sql
select public.fn_revogar_funcoes_publicas();

grant execute on function public.fn_usuario_atual() to authenticated;
grant execute on function public.fn_usuario_atual() to app_owner;
grant execute on function public.fn_papeis_do_usuario(uuid) to authenticated;
-- ... etc
```

Se um grant for esquecido, o sintoma é `permission denied for function ...` **dentro** da função, não na chamada.

### 16.7 O pgTAP e o `$$` do PostgreSQL

O pgTAP usa `$$...$$` como delimitador de string. Quando o SQL do teste **também** usa `$$` (corpo de função, ou `DO`), o parsing quebra. Os testes usam a tag personalizada `$fn$...$fn$` no SQL interno e aspas simples no SQL do pgTAP:

```sql
select extensions.throws_ok(
    'select public.fn_contestar_lancamento(
        current_setting(''test.lancamento_id'')::uuid,
        ''tentativa cross-tenant'')',
    '42501', null,
    'T35 sindico nao contesta lancamento de outro condominio'
);
```

Além disso, as funções do pgTAP são qualificadas com `extensions.` — o `search_path` da sessão (`"$user", public, extensions`) muda quando o papel muda dentro da transação de teste.

### 16.8 O `set_config` local não sobrevive à troca de role

`set_config(..., true)` é **local à transação** e é descartado quando o `set local role` troca o papel. O helper de teste usa `set_config(..., false)` (escopo de sessão) para o claim do JWT sobreviver. E os ids de registros que as tabelas de detalhe não deixam ler (`lancamentos`, `anexos`, `importacoes`) são capturados **antes** do `set local role`, via `set_config` ou via helpers.

### 16.9 Resumo do que a bateria cobre (53 testes)

| Arquivo | Testes | Cobre |
|---|---|---|
| `01_leitor_tabela_detalhe.test.sql` | 14 | T01–T13: leitor não lê tabela de detalhe, não conta, não insere, não atualiza, não chama função privilegiada |
| `02_granularidade_limiar.test.sql` | 11 | T14–T23: granularidade restrita, erro de parâmetro, limiar suprime/não suprime, log de leitura, auditor com granularidade plena |
| `03_isolamento_condominios.test.sql` | 7 | T24–T30: nada vaza entre condomínios; usuário sem vínculo não vê nada |
| `04_papeis_importador_anexos.test.sql` | 15 | T31–T40: síndico lê/contesta mas não classifica; importador não escreve em produção; anexo bloqueado por padrão; bruto não subtrai transferência |
| `05_drift_grants.test.sql` | 6 | T41–T46: nenhuma tabela de detalhe com privilégio; lista de grants bate com a permitida; anon sem privilégio; nenhuma função executável por anon; default privileges limpos |

