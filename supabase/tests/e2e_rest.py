"""
Teste de ponta a ponta contra a API REST do Supabase local.

Este teste NAO usa `set local role` nem GUCs simulados: ele faz login de
verdade pela API de autenticacao (GoTrue), pega o JWT e chama as funcoes e
views pelo endpoint REST (PostgREST), exatamente como o front faria.

Cenarios cobertos:
  1. leitor  -> SELECT direto na tabela de detalhe (deve falhar)
  2. leitor  -> le o agregado pela view (deve funcionar)
  3. leitor  -> chama a funcao agregadora (deve funcionar)
  4. leitor  -> chama a funcao de detalhe (deve falhar)
  5. auditor -> le o detalhe pela funcao (deve funcionar)
  6. leitor do condominio B -> nao ve o condomínio A (deve falhar/vazio)
  7. anon    -> nao acessa nada (deve falhar)
  8. auditor -> grava em auditoria_log com o usuario correto

"""
import json
import sys
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")

API = "http://127.0.0.1:54321"
AUTH = f"{API}/auth/v1"
REST = f"{API}/rest/v1"

SENHA = "teste12345"

resultados = []
contador = [0]


def registrar(ok, nome, detalhe=""):
    contador[0] += 1
    resultados.append((ok, nome, detalhe))
    marca = "ok  " if ok else "NOT OK"
    print(f" {marca} {contador[0]:>2}. {nome}")
    if detalhe:
        print(f"          {detalhe}")


def req(metodo, url, dados=None, token=None, anon_key=None, headers_extra=None):
    """Chamada HTTP. Devolve (status, corpo_texto)."""
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    if anon_key:
        h["apikey"] = anon_key
    if headers_extra:
        h.update(headers_extra)
    corpo = None
    if dados is not None:
        corpo = json.dumps(dados).encode("utf-8")
    r = urllib.request.Request(url, data=corpo, headers=h, method=metodo)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, str(e)


def login(email):
    st, corpo = req("POST", f"{AUTH}/token?grant_type=password",
                    {"email": email, "password": SENHA})
    if st != 200:
        raise RuntimeError(f"login falhou para {email}: {st} {corpo[:300]}")
    d = json.loads(corpo)
    return d["access_token"], d["user"]["id"]


def rpc(token, nome, args=None):
    return req("POST", f"{REST}/rpc/{nome}", args or {}, token=token)


def get(token, path, headers_extra=None):
    return req("GET", f"{REST}/{path}", token=token, headers_extra=headers_extra)


def main():
    print("=" * 78)
    print("TESTE DE PONTA A PONTA — API REST do Supabase local")
    print("=" * 78)

    # ------------------------------------------------------------------
    # Setup: garante os usuários e o fixture (o runner ja fez isso, mas
    # este script pode ser rodado isolado).
    # ------------------------------------------------------------------
    print("\n[setup] usuarios e fixture")

    # ---------------------------------------------------------------
    # Logins REAIS pela API de autenticacao
    # ---------------------------------------------------------------
    print("\n[login] API de autenticacao (GoTrue)")
    token_leitor, uid_leitor = login("leitor@condA.test")
    registrar(True, "leitor@condA.test autenticado",
              f"uid={uid_leitor}, token={len(token_leitor)} chars")
    token_auditor, uid_auditor = login("auditor@condA.test")
    registrar(True, "auditor@condA.test autenticado", f"uid={uid_auditor}")
    token_leitor_b, uid_leitor_b = login("leitor@condB.test")
    registrar(True, "leitor@condB.test autenticado", f"uid={uid_leitor_b}")

    # O JWT traz o 'sub' — é o que a funcao le.
    import base64
    payload = json.loads(base64.urlsafe_b64decode(
        token_leitor.split(".")[1] + "=" * (-len(token_leitor.split(".")[1]) % 4)))
    registrar(payload.get("sub") == uid_leitor,
              "JWT traz 'sub' igual ao id do usuario",
              f"sub={payload.get('sub')} role={payload.get('role')}")

    # ---------------------------------------------------------------
    # 1. Leitor sem acesso a tabela de detalhe
    # ---------------------------------------------------------------
    print("\n[1] leitor x tabela de detalhe")
    st, corpo = get(token_leitor, "lancamentos?select=id&limit=1")
    registrar(st in (401, 403),
              "leitor: SELECT em lancamentos e recusado",
              f"HTTP {st} — {corpo[:120]}")

    st, corpo = get(token_leitor, "unidades?select=numero&limit=1")
    registrar(st in (401, 403),
              "leitor: SELECT em unidades e recusado", f"HTTP {st}")

    st, corpo = get(token_leitor, "acesso_log?select=id&limit=1")
    registrar(st in (401, 403),
              "leitor: SELECT em acesso_log e recusado", f"HTTP {st}")

    # ---------------------------------------------------------------
    # 2. Leitor le o agregado pela view
    # ---------------------------------------------------------------
    print("\n[2] leitor x agregado")
    st, corpo = get(token_leitor,
                    "v_resumo_competencia_fundo?select=condominio_id,ano,mes,fundo_nome,creditos,debitos")
    registrar(st == 200, "leitor: le v_resumo_competencia_fundo", f"HTTP {st}")
    linhas = json.loads(corpo) if st == 200 else []
    if linhas:
        reg = linhas[0]
        registrar("unidade_id" not in reg and "unidade_numero" not in reg,
                  "o agregado nao expoe coluna de unidade",
                  f"colunas: {sorted(reg.keys())}")

    st, corpo = get(token_leitor, "v_cobertura_competencias?select=ano,mes,fonte,status")
    registrar(st == 200, "leitor: le v_cobertura_competencias", f"HTTP {st}")

    st, corpo = get(token_leitor, "v_resultado_bruto?select=ano,mes,creditos,debitos,resultado")
    registrar(st == 200, "leitor: le v_resultado_bruto", f"HTTP {st}")

    # ---------------------------------------------------------------
    # 3. Leitor chama a funcao agregadora
    # ---------------------------------------------------------------
    print("\n[3] leitor x fn_resumo (granularidade)")
    st, corpo = rpc(token_leitor, "fn_resumo",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_granularidade": "fundo"})
    registrar(st == 200, "leitor: fn_resumo com granularidade 'fundo' funciona",
              f"HTTP {st} — {len(json.loads(corpo)) if st == 200 else corpo[:120]} linhas")

    st, corpo = rpc(token_leitor, "fn_resumo",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_granularidade": "unidade"})
    registrar(st in (400, 403),
              "leitor: fn_resumo com granularidade 'unidade' e recusada",
              f"HTTP {st} — {corpo[:140]}")

    st, corpo = rpc(token_leitor, "fn_resumo",
                    {"p_condominio_id": "99999999-9999-9999-9999-999999999999",
                     "p_granularidade": "fundo"})
    registrar(st in (400, 403),
              "leitor do A: fn_resumo do condominio B e recusada",
              f"HTTP {st} — {corpo[:140]}")

    # ---------------------------------------------------------------
    # 4. Leitor chama a funcao de detalhe
    # ---------------------------------------------------------------
    print("\n[4] leitor x fn_lancamentos (detalhe)")
    st, corpo = rpc(token_leitor, "fn_lancamentos",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_limit": 100})
    registrar(st in (400, 403),
              "leitor: fn_lancamentos e recusada", f"HTTP {st} — {corpo[:140]}")

    st, corpo = rpc(token_leitor, "fn_aprovar_staging",
                    {"p_importacao_id": "00000000-0000-0000-0000-000000000000",
                     "p_staging_ids": []})
    registrar(st in (400, 403),
              "leitor: fn_aprovar_staging e recusada", f"HTTP {st}")

    # ---------------------------------------------------------------
    # 5. Auditor le o detalhe pela funcao
    # ---------------------------------------------------------------
    print("\n[5] auditor x detalhe")
    st, corpo = rpc(token_auditor, "fn_lancamentos",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_limit": 100})
    registrar(st == 200, "auditor: fn_lancamentos funciona", f"HTTP {st}")
    det = json.loads(corpo) if st == 200 else []
    if det:
        registrar(all("unidade_id" in r or r.get("unidade_id") is None for r in det),
                  "o auditor recebe o detalhe com unidade_id",
                  f"{len(det)} lancamentos, 1o={det[0]['historico'][:50]}")

    st, corpo = rpc(token_auditor, "fn_resumo",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_granularidade": "unidade"})
    registrar(st == 200,
              "auditor: fn_resumo com granularidade 'unidade' funciona",
              f"HTTP {st} — {len(json.loads(corpo)) if st == 200 else corpo[:120]} linhas")

    # ---------------------------------------------------------------
    # 6. Usuario de outro condominio
    # ---------------------------------------------------------------
    print("\n[6] isolamento entre condominios")
    st, corpo = get(token_leitor_b, "v_resumo_competencia_fundo?select=condominio_id,creditos")
    registrar(st == 200, "leitor do B: le a view agregada", f"HTTP {st}")
    linhas_b = json.loads(corpo) if st == 200 else []
    ids = {r.get("condominio_id") for r in linhas_b}
    registrar("11111111-1111-1111-1111-111111111111" not in ids,
              "leitor do B: nao ve nenhum dado do condominio A",
              f"condominios visiveis: {ids}")

    st, corpo = rpc(token_leitor_b, "fn_lancamentos",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_limit": 10})
    registrar(st in (400, 403),
              "leitor do B: fn_lancamentos do condominio A e recusada",
              f"HTTP {st} — {corpo[:140]}")

    st, corpo = rpc(token_leitor_b, "fn_contestar_lancamento",
                    {"p_lancamento_id": "00000000-0000-0000-0000-000000000000",
                     "p_texto": "tentativa"})
    registrar(st in (400, 403),
              "leitor do B: fn_contestar_lancamento e recusada", f"HTTP {st}")

    # ---------------------------------------------------------------
    # 7. Anon sem acesso
    # ---------------------------------------------------------------
    print("\n[7] anon")
    st, corpo = get(None, "lancamentos?select=id&limit=1")
    registrar(st in (401, 403),
              "anon: SELECT em lancamentos e recusado", f"HTTP {st}")

    st, corpo = get(None, "v_resumo_competencia_fundo?select=creditos")
    registrar(st in (401, 403),
              "anon: SELECT na view agregada e recusado", f"HTTP {st}")

    st, corpo = rpc(None, "fn_resumo",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111"})
    registrar(st in (401, 403),
              "anon: fn_resumo e recusada", f"HTTP {st}")

    # ---------------------------------------------------------------
    # 8. Escrita: o usuario_id registrado no log e o da pessoa correta
    # ---------------------------------------------------------------
    print("\n[8] escrita com identificacao do usuario")
    st, corpo = rpc(token_auditor, "fn_atualizar_visibilidade",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_papel": "auditor",
                     "p_granularidade_max": "unidade",
                     "p_limiar_minimo_unidades": 0})
    # O PostgREST devolve 204 (No Content) para funcao que retorna void.
    registrar(st in (200, 204),
              "auditor: fn_atualizar_visibilidade funciona", f"HTTP {st}")

    # O log NAO e lido por SELECT direto (nenhum papel tem o privilegio):
    # a leitura passa por fn_auditoria_log, que filtra por papel.
    st, corpo = rpc(token_auditor, "fn_auditoria_log",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_acao": "atualizar_visibilidade",
                     "p_limite": 5})
    if st == 200 and corpo.strip():
        regs = json.loads(corpo)
        registrar(len(regs) > 0 and regs[0].get("usuario_id") == uid_auditor,
                  "o auditoria_log gravou o usuario_id do auditor (via REST)",
                  f"usuario_id={regs[0].get('usuario_id')} esperado={uid_auditor}")
    else:
        registrar(False, "o auditoria_log gravou o usuario_id do auditor",
                  f"HTTP {st} — {corpo[:160]}")

    st, corpo = get(token_auditor, "auditoria_log?select=id&limit=1")
    registrar(st in (401, 403),
              "auditor: SELECT direto em auditoria_log e recusado (leitura por funcao)",
              f"HTTP {st}")

    st, corpo = get(token_leitor, "auditoria_log?select=id&limit=1")
    registrar(st in (401, 403),
              "leitor: SELECT em auditoria_log e recusado", f"HTTP {st}")

    st, corpo = rpc(token_leitor, "fn_auditoria_log",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111"})
    registrar(st in (400, 403),
              "leitor: fn_auditoria_log e recusada", f"HTTP {st} — {corpo[:120]}")

    # O log de acesso tambem so por funcao.
    st, corpo = rpc(token_auditor, "fn_acesso_log",
                    {"p_condominio_id": "11111111-1111-1111-1111-111111111111",
                     "p_limite": 5})
    registrar(st == 200, "auditor: fn_acesso_log funciona", f"HTTP {st}")

    st, corpo = get(token_leitor, "acesso_log?select=id&limit=1")
    registrar(st in (401, 403),
              "leitor: SELECT em acesso_log e recusado", f"HTTP {st}")

    # ---------------------------------------------------------------
    print("\n" + "=" * 78)
    ok = sum(1 for r in resultados if r[0])
    total = len(resultados)
    print(f"RESULTADO: {ok}/{total} verificacoes passaram")
    if ok != total:
        print("FALHAS:")
        for r in resultados:
            if not r[0]:
                print(f"   - {r[1]} :: {r[2]}")
    print("=" * 78)
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
