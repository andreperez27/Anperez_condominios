#!/usr/bin/env python3
# ============================================================================
# VARREDURA DE ENCODING — UTF-8 SEM BOM, SEM MOJIBAKE
# ============================================================================
# Por que existe: na Etapa 5 (12/11/2026) o docs/DEPLOY_REMOTO.md saiu com
# dupla codificaçao — `Get-Content -Raw` do Windows PowerShell 5.1 (sem
# `-Encoding`) leu o arquivo UTF-8 sem BOM como cp1252 e o
# `Set-Content -Encoding UTF8` regravou o mojibake (cada acento virou dois
# chars: A-til + cedilha quebrados etc.). Este script impede que isso volte
# a passar despercebido.
#
# O QUE ELE CONFERE, em todo arquivo de texto do repositorio:
#   1. é UTF-8 valido;
#   2. nao tem BOM;
#   3. nao tem assinatura de mojibake utf-8->cp1252->utf-8 (ver padrao de
#      bytes na constante ASSINATURAS abaixo);
#   4. .ps1 com char nao-ASCII é recusado (o PS 5.1 le .ps1 sem BOM como
#      ANSI — script de PowerShell tem de ser ASCII puro).
#
# Uso:  python supabase/tools/varre_encoding.py
# Sai com codigo != 0 se alguma regra for violada.
# ============================================================================

from __future__ import annotations

import io
import pathlib
import sys

try:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover
    pass

RAIZ = pathlib.Path(__file__).resolve().parents[2]
EXTENSOES = {".md", ".sql", ".py", ".ps1", ".yaml", ".yml", ".ts", ".json"}
IGNORAR = {".git", "node_modules", ".temp", ".opencode", "__pycache__", ".venv"}

# Assinaturas de mojibake, EM BYTES (UTF-8 do char corrompido):
#   a-til+cedilha quebrado = C3 83 C2 A7 etc.; travessao quebrado =
#   E2 82 AC C2 94 ("e-acute, euro, cedilha" — o padrao e sempre o char
#   original decomposto em bytes e re-interpreto como cp1252).
ASSINATURAS = [
    b"\xc3\x83\xc2\xa7", b"\xc3\x83\xc2\xa3", b"\xc3\x83\xc2\xa9",
    b"\xc3\x83\xc2\xad", b"\xc3\x83\xc2\xb3", b"\xc3\x83\xc2\xba",
    b"\xc3\x83\xc2\xa0", b"\xc3\x83\xc2\xa2", b"\xc3\x83\xc2\xaa",
    b"\xc3\x83\xc2\xaa", b"\xc3\x83\xe2\x80\x9d", b"\xc3\x82\xc2\xa0",
    b"\xe2\x82\xac\xc2\x9c", b"\xe2\x82\xac\xc2\x9d", b"\xe2\x82\xac\xc2\x94",
]


def main() -> int:
    arquivos = sorted(
        a for a in RAIZ.rglob("*")
        if a.is_file()
        and a.suffix.lower() in EXTENSOES
        and not any(p in IGNORAR for p in a.relative_to(RAIZ).parts)
    )
    if not arquivos:
        print("ERRO: nenhum arquivo de texto encontrado em", RAIZ)
        return 1

    falhas: list[str] = []

    for arq in arquivos:
        b = arq.read_bytes()
        rel = arq.relative_to(RAIZ).as_posix()

        if b[:3] == b"\xef\xbb\xbf":
            falhas.append(f"{rel}: tem BOM (regra do repo: UTF-8 SEM BOM)")

        try:
            s = b.decode("utf-8")
        except UnicodeDecodeError as e:
            falhas.append(f"{rel}: NAO e UTF-8 valido ({e})")
            continue

        achados = [(sig, b.count(sig)) for sig in ASSINATURAS if b.count(sig)]
        if achados:
            detalhe = "; ".join(f"{sig.hex(' ')} x{n}" for sig, n in achados)
            falhas.append(f"{rel}: mojibake de dupla codificaçao ({detalhe})")

        if arq.suffix.lower() == ".ps1":
            nao_ascii = sorted(set(c for c in s if ord(c) > 127))
            if nao_ascii:
                falhas.append(
                    f"{rel}: .ps1 com char nao-ASCII {nao_ascii[:6]} — "
                    f"o PowerShell 5.1 le .ps1 sem BOM como ANSI; "
                    f"script de PowerShell deve ser ASCII puro")

    print(f"Arquivos de texto verificados: {len(arquivos)}")

    if falhas:
        print()
        print(f"X {len(falhas)} problema(s) de encoding:")
        for f in falhas:
            print(f"   {f}")
        return 1

    print()
    print("OK: todos em UTF-8 valido, sem BOM, sem mojibake; .ps1 em ASCII puro.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
