#!/usr/bin/env python3
"""Acha `check_not` que nao podem falhar.

Um `check_not "descricao" "TEXTO"` passa quando a saida NAO contem TEXTO. Se TEXTO
nao existe em lugar nenhum do codigo, a checagem e sempre verdadeira: ela conta
como uma das checagens, ocupa o relatorio, e nao mede nada. Um membro
que nao pode falhar e pior do que a ausencia dele, porque ele compra a sensacao de
cobertura sem pagar por ela.

O caso real, medido: o script imprime o banner `==> OpenDesign`, e a checagem
proibia `==> OpenDesign (nativo)` — o sufixo de modo simplesmente nao existe. As
duas assercoas "passavam" enquanto a cobertura que elas fingiam medir nao rodava.

A regra e estreita de proposito. Um "o texto proibido precisa existir no codigo" em
geral daria falsos positivos: `RANDOM`, `urandom` e `date +%d%m` sao coisas que o
script NAO deve usar, e legitimamente nao aparecem. O que denuncia o bug e a
palavra chave: a string proibida e uma VARIACAO com sufixo de uma mensagem que o
script emite de verdade. E isso que a regra procura, e nada mais.
"""

import io
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))  # .../tests/lib
REPO = os.path.dirname(os.path.dirname(AQUI))        # a raiz do repo


def sem_sufixo(texto):
    """Tira o sufixo entre parenteses no fim: 'X (nativo)' -> 'X'."""
    return re.sub(r"\s*\([^()]*\)\s*$", "", texto).strip()


def main():
    teste = os.path.join(REPO, "tests", "profile-axis-test.sh")
    setup = os.path.join(REPO, "setup.sh")
    if not (os.path.exists(teste) and os.path.exists(setup)):
        print("    (setup.sh ou o teste nao estao aqui; nada a verificar)")
        return 0

    t = io.open(teste, encoding="utf-8").read()
    src = io.open(setup, encoding="utf-8").read()

    proibidas = re.findall(r'check_not\s+"[^"]*"\s+"([^"]*)"', t)

    # Variacao com sufixo de uma mensagem que o script emite: nao pode falhar.
    quase = [x for x in proibidas if x and x not in src and sem_sufixo(x) in src]
    for q in quase:
        print("    FALHA um check_not nao pode falhar: proibe %r, e o script" % q)
        print("          emite %r — o sufixo nao existe, entao a checagem e" % sem_sufixo(q))
        print("          sempre verdadeira e conta como cobertura sem medir nada.")

    # E o caso geral, reportado a parte para nao virar ruido: a string proibida nao
    # aparece em lugar nenhum. Pode ser legitimo (`RANDOM` e o script nao deve
    # usar), entao e aviso, e nao falha.
    inexistentes = [x for x in proibidas if x and x not in src and x not in quase]
    if inexistentes:
        print("    (aviso: %d check_not cuja string nao aparece no setup.sh —" % len(inexistentes))
        print("     normalmente e o certo, quando o texto e o que o script NAO deve usar)")

    if not quase:
        print("    nenhum check_not que seja variacao de uma mensagem real")
    return 1 if quase else 0


if __name__ == "__main__":
    sys.exit(main())
