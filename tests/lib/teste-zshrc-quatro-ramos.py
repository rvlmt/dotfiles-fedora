#!/usr/bin/env python3
"""Exercita os QUATRO ramos de `link_zshrc`, com o bloco real do setup.sh.

O `link_zshrc` decide entre quatro estados de `~/.zshrc`, e a decisão é feita por
`-e` e `-L` — dois testes que dão respostas diferentes para um symlink quebrado:

    -e  segue o link: verdadeiro só se o DESTINO existe
    -L  o link existe como link: verdadeiro mesmo sem destino

Por isso um link quebrado satisfaz `-L` e nunca `-e`, e o `elif [ -e ] || [ -L ]`
que existia antes tratava as duas coisas como uma só: perguntava antes de
sobrescrever um arquivo que não tinha conteúdo. Com `--defaults`, o default é
*não*, e a pergunta virava uma pendência permanente sobre um link que não
apontava para lugar nenhum.

Os quatro estados, e o que cada um tem de ser:

| estado | o que o script tem de fazer |
|---|---|
| não existe | criar o link |
| link correto | não mexer |
| **link quebrado** | **repor o link** — não há conteúdo a perder |
| arquivo de verdade | perguntar, e `--defaults` mantém |

O quarto caso é o que `--defaults` protege, e o terceiro é o que ele não devia
proteger. A diferença é ter conteúdo ou não.
"""

import os
import re
import shutil
import subprocess

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE = "/tmp/opencode/zshrc-teste"

VERDE = "\\033[0;32m"
AMARELO = "\\033[1;33m"
NC = "\\033[0m"


def bloco_real():
    """Extrai `link_zshrc` do setup.sh, e tira a indentacao e a cor."""
    src = open(os.path.join(RAIZ, "setup.sh"), encoding="utf-8").read()
    ini = src.index("link_zshrc() {")
    fim = src.index("\n}\n", ini)
    corpo = src[ini : fim + 3]
    # O harness roda o bloco na coluna 0; a cor sai porque `echo -e` num terminal
    # sem TTY ja vira lixo, e o que importa aqui e o TEXTO.
    corpo = "\n".join(
        l[4:] if l.startswith("    ") else l for l in corpo.split("\n")
    )
    corpo = re.sub(r'echo -e "\$\{[A-Z]+\}', 'echo "', corpo)
    corpo = re.sub(r"echo -e \"", 'echo "', corpo)
    corpo = corpo.replace("${NC}", "").replace("${VERDE}", VERDE).replace("${AMARELO}", AMARELO)
    return corpo


CASOS = [
    ("A. ~/.zshrc nao existe", "ausente", "agora aponta para"),
    ("B. ja e um link para este repositorio", "correto", "já aponta para este repositório"),
    ("C. link QUEBRADO (o caso da VM)", "quebrado", "estava quebrado"),
    ("D. arquivo de verdade, --defaults mantem", "arquivo", "mantido como está"),
]


def montar(caso, casa):
    """Cria o estado inicial do HOME e devolve o caminho do zshrc da maquina."""
    home = os.path.join(casa, "home")
    src = os.path.join(casa, "repo")
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home)
    os.makedirs(src, exist_ok=True)
    alvo_real = os.path.join(src, "zshrc")
    with open(alvo_real, "w") as f:
        f.write("# zshrc do repo\n")

    dest = os.path.join(home, ".zshrc")
    if caso == "ausente":
        pass
    elif caso == "correto":
        os.symlink(alvo_real, dest)
    elif caso == "quebrado":
        # `/home/agent/zshrc`: o que a VM tinha. O destino nao existe.
        os.symlink(os.path.join(home, "zshrc"), dest)
    elif caso == "arquivo":
        with open(dest, "w") as f:
            f.write("# zshrc da pessoa\n")
    return home, src, dest, alvo_real


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(BASE)

    corpo = bloco_real()
    io_bloco = os.path.join(BASE, "bloco.sh")
    with open(io_bloco, "w") as f:
        f.write(corpo + '\nlink_zshrc\n')

    ok = 0
    falhas = 0
    for titulo, caso, esperado in CASOS:
        casa = os.path.join(BASE, caso)
        home, src, dest, alvo_real = montar(caso, casa)
        env = dict(os.environ)
        env["HOME"] = home
        env["SCRIPT_DIR"] = src
        env["CONFIRM_ZSHRC_OVERWRITE"] = "0"   # o default: nao
        r = subprocess.run(
            ["bash", io_bloco], capture_output=True, text=True, timeout=60, env=env
        )
        saida = (r.stdout + r.stderr).strip()

        print()
        print("== %s ==" % titulo)
        for l in [x for x in saida.split("\n") if x.strip()][:4]:
            print("  " + l[:92])

        # O estado DEPOIS, e nao a frase. A frase e o que o script diz que fez.
        estado_ok = True
        if caso in ("ausente", "correto", "quebrado"):
            if not os.path.islink(dest):
                print("  FALHA ~/.zshrc nao e um symlink")
                estado_ok = False
            elif os.readlink(dest) != alvo_real:
                print("  FALHA aponta para %s, e o certo e %s" % (os.readlink(dest), alvo_real))
                estado_ok = False
            elif not os.path.exists(dest):
                print("  FALHA o link aponta para um destino INEXISTENTE — e o bug original")
                estado_ok = False
            else:
                print("  ok   ~/.zshrc e um symlink QUE FUNCIONA para %s" % alvo_real)
        else:  # arquivo
            if os.path.islink(dest):
                print("  FALHA virou symlink; --defaults tem de manter o arquivo da pessoa")
                estado_ok = False
            else:
                with open(dest) as f:
                    txt = f.read()
                if "# zshrc da pessoa" not in txt:
                    print("  FALHA o conteudo mudou: %r" % txt[:40])
                    estado_ok = False
                else:
                    print("  ok   o arquivo da pessoa foi mantido intacto")

        if esperado not in saida:
            print("  FALHA a frase esperada era %r" % esperado)
            estado_ok = False
        if estado_ok:
            ok += 1
        else:
            falhas += 1

    print()
    print("ZSHRC: %d ok, %d falhas" % (ok, falhas))
    return 1 if falhas else 0


if __name__ == "__main__":
    raise SystemExit(main())
