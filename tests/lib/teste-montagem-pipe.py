#!/usr/bin/env python3
"""Testa a montagem do setup.sh pelo caminho por pipe, sem escaping no meio.

As versoes anteriores deste teste eram bash com `sed` dentro de heredoc, e
escapar o `${REPO_SLUG}` atravessando tres camadas foi a origem de quatro
rodadas perdidas: o `sed` nao casava, o teste falhava, e a falha parecia da
montagem. Aqui nao ha escaping — o texto e escrito em Python e procurado
literalmente.

O que se testa: o script inteiro entra pela entrada padrao (como num
`curl | bash`), monta-se em disco, traz os anexos que ELE LE, e nao traz o resto
do repositorio.
"""

import http.server
import io
import os
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import time

# A raiz vem do lugar do script, nao de um caminho fixo: o teste roda dentro do
# repositorio, e um caminho absoluto aqui faria o teste medir OUTRO checkout — ou
# nenhum, se a arvore estivesse em outro lugar. Foi assim que a primeira versao
# deste teste mediu zero arquivos e nao disse nada.
RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PORTA = int(os.environ.get("FD_TESTE_PORTA", "8741"))
SERVIDOR = "/tmp/opencode/http6"
DESTINO = "/tmp/opencode/destino6"

# As tres funcoes, extraidas do script real. Um teste que REESCREVE a funcao
# testa a reescrita: as versoes anteriores deste teste divergiram do original
# duas vezes, e uma delas tinha o filtro circular.
FUNCOES = ["_anexos_necessarios", "_baixar_anexo", "_se_colocar_no_disco_e_reexecutar"]


def extrair(caminho, nome):
    """Pega uma funcao do script, da linha dela ate o fecha-chave no nivel 0."""
    linhas = io.open(caminho, encoding="utf-8").read().split("\n")
    ini = None
    for i, l in enumerate(linhas):
        if l.startswith(nome + "() {"):
            ini = i
            break
    if ini is None:
        return None
    for j in range(ini + 1, len(linhas)):
        if linhas[j] == "}":
            return "\n".join(linhas[ini : j + 1])
    return None


def servir():
    for p in (SERVIDOR, DESTINO):
        shutil.rmtree(p, ignore_errors=True)
    os.makedirs(os.path.join(SERVIDOR, "bin"), exist_ok=True)

    # O script SERVIDO aponta para o servidor local. Sem isto, a montagem tenta a
    # URL real e o repositorio privado devolve uma pagina de erro — a montagem
    # falha com a mensagem CORRETA e a causa ERRADA, que e o pior par posible.
    src = io.open(os.path.join(RAIZ, "setup.sh"), encoding="utf-8").read()
    alvo = "https://raw.githubusercontent.com/${REPO_SLUG}/main"
    if alvo not in src:
        print("  ALERTA: o alvo da URL nao foi encontrado no setup.sh.")
        print("          a montagem vai tentar a URL real e o teste falha pelo motivo errado.")
    srv = src.replace(alvo, "http://127.0.0.1:%d" % PORTA)
    io.open(os.path.join(SERVIDOR, "setup.sh"), "w", encoding="utf-8").write(srv)

    for rel in ("zshrc", "bin/gh-app-token.sh"):
        shutil.copy(os.path.join(RAIZ, rel), os.path.join(SERVIDOR, rel))

    corpo = ["set -uo pipefail", 'REPO_SLUG="rvlmt/dotfiles-fedora"']
    faltou = []
    for f in FUNCOES:
        corpo.append(extrair(os.path.join(RAIZ, "setup.sh"), f) or "")
        if corpo[-1] == "":
            faltou.append(f)
    if faltou:
        print("  FALHOU ao extrair: %s" % ", ".join(faltou))
        return False

    # A montagem real termina em `exec bash ./setup.sh`, que lancaria o script
    # inteiro. Aqui o exec vira um relatorio, DENTRO da funcao.
    txt = "\n".join(corpo)
    txt, n = re.subn(
        r"^(\s*)exec bash \./setup\.sh .*$",
        r'\1echo "MONTADO em $destino_dir ($n anexo(s) alem do setup.sh)"; '
        r'echo "RE-EXEC com: [${args[*]}]"; return 0',
        txt,
        flags=re.M,
    )
    if n == 0:
        print("  FALHOU: nao achei o `exec bash ./setup.sh` para substituir.")
        return False
    io.open(os.path.join(SERVIDOR, "so-mecanica.sh"), "w", encoding="utf-8").write(txt)

    # O "pipeline": as funcoes + a chamada, tudo lido da entrada padrao.
    pipeline = (
        "set -uo pipefail\n"
        'MECANICA="$1"; DESTINO="$2"; URL="$3"; shift 3\n'
        '. "$MECANICA"\n'
        '_se_colocar_no_disco_e_reexecutar "$URL" "$DESTINO" "$@"\n'
    )
    io.open(os.path.join(SERVIDOR, "pipeline.sh"), "w", encoding="utf-8").write(pipeline)
    return True


def main():
    if not servir():
        return 1

    handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(
        *a, directory=SERVIDOR, **k
    )
    httpd = socketserver.TCPServer(("127.0.0.1", PORTA), handler)
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    time.sleep(0.4)

    print("== o script INTEIRO entra pela entrada padrao, como num 'curl | bash' ==")
    cmd = (
        "cat %s/pipeline.sh | bash -s -- %s/so-mecanica.sh %s http://127.0.0.1:%d "
        "--profile=vm --defaults" % (SERVIDOR, SERVIDOR, DESTINO, PORTA)
    )
    r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=120)
    for l in (r.stdout + r.stderr).strip().split("\n")[:6]:
        print("  " + l[:96])

    httpd.shutdown()

    print()
    print("== o que ficou no destino ==")
    if not os.path.isdir(DESTINO):
        print("  NAO MONTOU")
        return 1
    got = []
    for raiz, _, arqs in os.walk(DESTINO):
        for a in arqs:
            got.append(os.path.relpath(os.path.join(raiz, a), DESTINO))
    for g in sorted(got):
        print("  " + g)

    print()
    n_repo = len(
        subprocess.run(["git", "ls-files"], cwd=RAIZ, capture_output=True, text=True).stdout.split()
    )
    print("  o repositorio tem %d arquivo(s) versionado(s)" % n_repo)

    lixos = [g for g in got if g.split("/")[0] in
             ("tests", "AUDITORIA.md", "README.md", "AGENTS.md", "ARQUITETURA.md",
              "pos-instalacao.md", "ROLLBACK.md")]
    if lixos:
        print("  LIXO no destino: %s" % ", ".join(lixos))
    else:
        print("  ok  nenhum lixo: so o que o script le")

    esperado = {"setup.sh", "zshrc", os.path.join("bin", "gh-app-token.sh")}
    if set(got) == esperado:
        print("  ok  exatamente os 3 arquivos que o setup.sh le do repositorio")
        return 0
    print("  DIVERGENCIA: esperava %s" % sorted(esperado))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
