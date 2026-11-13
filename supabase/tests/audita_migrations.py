#!/usr/bin/env python3
# ============================================================================
# AUDITORIA ESTÁTICA DAS MIGRATIONS — REVOKE EXPLÍCITO
# ============================================================================
# REGRA DE OURO
# -------------
# Toda tabela, view, função ou sequência criada por uma migration precisa
# receber, **na mesma migration**, um REVOKE explícito de `anon` e
# `authenticated` (e de `public`, no caso das funções — que nascem com
# EXECUTE para PUBLIC).
#
# Por que "na mesma migration"? Porque a garantia não pode depender de um
# passo separado: nem de uma varredura dinâmica, nem de lembrar de rodar
# um script depois. O objeto nasce fechado, no mesmo lugar onde nasce.
#
# E por que importa? A varredura dinâmica (`fn_revogar_funcoes_publicas`,
# `fn_revogar_tabelas_publicas`) cobre o estado atual — mas ela depende de
# o helper existir, estar íntegro e ser chamado. Um REVOKE explícito não
# depende de nada. Se alguém criar uma tabela nova e esquecer o revoke,
# este auditorium falha o build.
#
# O QUE ESTE SCRIPT FAZ
# ---------------------
# 1. Varre TODAS as migrations e coleta os objetos criados por cada uma.
# 2. Para cada objeto, exige um REVOKE explícito com `anon` e
#    `authenticated` na MESMA migration.
# 3. Exige que nenhuma migration conceda privilégio a `anon`.
# 4. Sai com código ≠ 0 se alguma regra for violada.
#
# Uso:  python supabase/tests/audita_migrations.py
# ============================================================================

from __future__ import annotations

import pathlib
import re
import sys

# O console do Windows usa cp1252 por padrão: força UTF-8 para não quebrar
# na hora de imprimir os acentos e os marcadores.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover
    pass

RAIZ = pathlib.Path(__file__).resolve().parents[2]
DIR_MIGRATIONS = RAIZ / "supabase" / "migrations"

# ---------------------------------------------------------------------------
# Padrões de criação de objetos
# ---------------------------------------------------------------------------
RE_CREATE = {
    "tabela": re.compile(
        r"^\s*create\s+(?:unlogged\s+|temporary\s+|temp\s+)?table\s+"
        r"(?:if\s+not\s+exists\s+)?(?:public\.)?\"?(\w+)\"?",
        re.IGNORECASE | re.MULTILINE),
    "view": re.compile(
        r"^\s*create\s+(?:or\s+replace\s+)?(?:materialized\s+)?view\s+"
        r"(?:if\s+not\s+exists\s+)?(?:public\.)?\"?(\w+)\"?",
        re.IGNORECASE | re.MULTILINE),
    "funcao": re.compile(
        r"^\s*create\s+(?:or\s+replace\s+)?function\s+"
        r"(?:public\.)?\"?(\w+)\"?\s*\(",
        re.IGNORECASE | re.MULTILINE),
    "sequencia": re.compile(
        r"^\s*create\s+sequence\s+(?:if\s+not\s+exists\s+)?"
        r"(?:public\.)?\"?(\w+)\"?",
        re.IGNORECASE | re.MULTILINE),
}

# Um REVOKE explícito:  revoke all on [tipo] <objeto> [(args)] from <roles>
RE_REVOKE = re.compile(
    r"^\s*revoke\s+all\s+on\s+(?:table|view|materialized\s+view|sequence|function)?\s*"
    r"(?:public\.)?\"?(?P<obj>\w+)\"?\s*(?:\([^;]*?\))?\s*from\s+(?P<roles>[^;]+);",
    re.IGNORECASE | re.MULTILINE)

# Qualquer GRANT para `anon` é proibido em qualquer migration.
RE_GRANT_ANON = re.compile(
    r"^\s*grant\s+[^;]*?\s+to\s+[^;]*?\banon\b[^;]*?;",
    re.IGNORECASE | re.MULTILINE)


def revokes_de(texto: str) -> dict[str, set[str]]:
    """Mapa objeto -> conjunto de papéis revokeados, segundo o arquivo."""
    mapa: dict[str, set[str]] = {}
    for m in RE_REVOKE.finditer(texto):
        obj = m.group("obj").lower()
        roles = {r.strip().lower() for r in m.group("roles").split(",")}
        mapa.setdefault(obj, set()).update(roles)
    return mapa


def main() -> int:
    arquivos = sorted(DIR_MIGRATIONS.glob("*.sql"))
    if not arquivos:
        print("ERRO: nenhuma migration encontrada em", DIR_MIGRATIONS)
        return 1

    falhas: list[str] = []
    total_objetos = 0

    for arq in arquivos:
        texto = arq.read_text(encoding="utf-8")
        revokes = revokes_de(texto)

        # 3. Nenhum GRANT para `anon`
        for m in RE_GRANT_ANON.finditer(texto):
            linha = texto[:m.start()].count("\n") + 1
            falhas.append(
                f"{arq.name}:{linha}: GRANT para `anon` é proibido -> {m.group(0).strip()}")

        for tipo, rx in RE_CREATE.items():
            for m in rx.finditer(texto):
                nome = m.group(1).lower()
                total_objetos += 1
                linha = texto[:m.start()].count("\n") + 1
                roles = revokes.get(nome, set())

                faltando = [r for r in ("anon", "authenticated") if r not in roles]
                if faltando:
                    falhas.append(
                        f"{arq.name}:{linha}: {tipo} `public.{nome}` sem REVOKE explícito "
                        f"de {', '.join(faltando)} NA PRÓPRIA MIGRATION")
                    continue

                # Funções nascem com EXECUTE para PUBLIC: o revoke de `public`
                # é obrigatório (sem ele, o `anon` executa pela via PUBLIC).
                if tipo == "funcao" and "public" not in roles:
                    falhas.append(
                        f"{arq.name}:{linha}: função `public.{nome}` sem REVOKE de `public` "
                        f"(função nasce com EXECUTE para PUBLIC)")

    print(f"Migrations auditadas: {len(arquivos)}")
    print(f"Objetos criados com REVOKE explícito verificado: {total_objetos}")

    if falhas:
        print()
        print(f"✗ {len(falhas)} violação(ões) da regra do REVOKE explícito:")
        print()
        for f in falhas:
            print(f"   {f}")
        print()
        return 1

    print()
    print("✓ Todo objeto criado por migration tem REVOKE explícito de anon, "
          "authenticated (e de public, nas funções).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
