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
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

if len(sys.argv) < 3:
    sys.exit("uso: ptyfile2.py <arquivo-de-entrada> <comando> [args...]")

# O tamanho do pty e FIXADO, e nao herdado do terminal de quem roda.
#
# `pty.fork()` copia o winsize do terminal atual. O `setup.sh` escreve varias
# linhas por bloco, e o terminal quebra a linha conforme a largura; com um pty
# estreito a saida ganha mais quebras, o pty devolve mais bytes, e o `run_pty`
# capta uma forma diferente da mesma coisa. O efeito observado na suite, num
# container sem terminal: a saida parava em "Nome completo para o Git" e quatro
# checks acusavam modulos que nem tinham comecado — o pty e o ambiente, e a leitura
# apontava para o `setup.sh`.
#
# E o mesmo principio da regra da suite: um teste que depende da conta, do
# terminal e do cwd de quem roda nao mede o codigo, mede a pessoa.
COLS = int(os.environ.get("PTYFILE_COLS", "120"))
LINES = int(os.environ.get("PTYFILE_LINES", "400"))

dados = open(sys.argv[1], "rb").read()
linhas = dados.splitlines(keepends=True)
cmd = sys.argv[2:]

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "dumb"
    os.execvp(cmd[0], cmd)

# No PAIS, logo depois do fork: o filho ja pode ter saido, mas o winsize do pty
# ainda pode ser ajustado enquanto ele nao leu nada. `TIOCSWINSZ` aqui, e nao no
# filho, porque o filho nao tem o `fd` do pty.
try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", LINES, COLS, 0, 0))
except OSError:
    pass

saida = b""
enviados = 0
silencio = 0.0          # segundos em que o pty nao devolveu nada
ultimo_envio = 0.0
ultimo_saida = time.time()   # quando o pty devolveu algo pela ultima vez
# O `LIMITE` conta a VIDA do run, e nao o silencio — e o loop so termina por ele
# enquanto o pty esta produzindo. Por isso ele precisa ser generoso: um modulo
# longo (o `base` faz `dnf upgrade` de 835 pacotes) passa dos 90s default com o
# pty ativo, e o driver encerra o filho no meio.
#
# Medido nesta sessao, num container: com `PTYFILE_TIMEOUT` no default, quatro
# checks falhavam todos no MESMO ponto — a saida parava no banner e na primeira
# pergunta, e os modulos que vinham depois nunca apareciam. O `check` acusava
# "`==> firewalld` nao rodou"; o que acontecia e o driver matando o processo, e o
# sintoma e indistinguivel do modulo ter falhado. Com `PTYFILE_TIMEOUT=600` os
# mesmos quatro checks passaram.
#
# O `IDLE` (240s sem saida) continua sendo o parametro que distingue "trabalhando"
# de "travado", e e ele que deve derrubar um processo pendurado. O `LIMITE` e so
# um teto de seguranca, e por isso e alto.
LIMITE = float(os.environ.get("PTYFILE_TIMEOUT", "1800"))
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
