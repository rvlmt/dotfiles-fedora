#!/usr/bin/env python3
"""Roda um comando com stdin vindo de um arquivo, num pty, entregando a entrada
CONFORME O PROMPT APARECE.

O `ptyfile.py` anterior escrevia todos os bytes de uma vez, antes de o shell
instalar o primeiro prompt. Num terminal de verdade o usuario digita depois de
ver a pergunta, e o shell que espera por isso. Escrever tudo de uma vez faz o
`read` do primeiro `read -rp` engolir a entrada inteira e o script sair logo em
seguida — o que se via como "o script nao imprime nada".

Aqui a entrada e entregue em fatias: cada vez que o pty fica em silencio por uma
fracao de segundo (isto e, o prompt foi pintado e o shell esta esperando), manda a
proxima linha. E o fim do arquivo vira EOF de verdade, fechando a entrada.
"""
import os
import pty
import select
import signal
import sys
import time

if len(sys.argv) < 3:
    sys.exit("uso: ptyfile2.py <arquivo-de-entrada> <comando> [args...]")

dados = open(sys.argv[1], "rb").read()
linhas = dados.splitlines(keepends=True)
cmd = sys.argv[2:]

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "dumb"
    os.execvp(cmd[0], cmd)

saida = b""
enviados = 0
silencio = 0.0          # segundos em que o pty nao devolveu nada
ultimo_envio = 0.0
ultimo_saida = time.time()   # quando o pty devolveu algo pela ultima vez
LIMITE = float(os.environ.get("PTYFILE_TIMEOUT", "90"))
fim = time.time() + LIMITE

while time.time() < fim:
    r, _, _ = select.select([fd], [], [], 0.15)
    if r:
        try:
            pedaco = os.read(fd, 65536)
        except OSError:
            break
        if not pedaco:
            break
        saida += pedaco
        silencio = 0.0
        ultimo_saida = time.time()
        continue

    # O pty esta em silencio: o prompt provavelmente foi pintado.
    silencio += 0.15
    if enviados < len(linhas) and silencio >= 0.25:
        try:
            os.write(fd, linhas[enviados])
        except OSError:
            break
        enviados += 1
        silencio = 0.0
        ultimo_envio = time.time()
        continue

    if enviados >= len(linhas):
        # Todas as respostas foram entregues e o pty calou. A carencia conta
        # desde a ultima SAIDA, e nao desde o ultimo envio.
        #
        # Este era o bug que matou um `setup.sh --only=base` no meio: contando
        # desde o envio, os 25s acabavam enquanto o `dnf upgrade` de 835 pacotes
        # ainda rodava, e o driver encerrava o filho. Medido na VM nova: apos o
        # driver abortar, mise, bun e o link do devcontainer estavam todos
        # ausentes — o que parecia falha do script era o harness matando o
        # processo. Um modulo longo produz saida de vez em quando, e e isso que
        # distingue "trabalhando" de "travado".
        if time.time() - ultimo_saida > float(os.environ.get("PTYFILE_IDLE", "240")):
            break

    if os.waitpid(pid, os.WNOHANG)[0]:
        # Drena o que sobrou no pty antes de sair.
        for _ in range(20):
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                break
            try:
                pedaco = os.read(fd, 65536)
            except OSError:
                break
            if not pedaco:
                break
            saida += pedaco
        break

try:
    os.kill(pid, signal.SIGTERM)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except OSError:
    pass

sys.stdout.write(saida.decode("utf-8", "replace"))
