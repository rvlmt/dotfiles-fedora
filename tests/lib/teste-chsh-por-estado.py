"""Exercita os TRES caminhos do bloco do chsh, com um `sudo`/`chsh` falsos.

O bloco que decide o shell de login tem tres saidas:

  A. ja e zsh          -> nao chama o chsh, e diz que ja e
  B. muda com sucesso  -> o chsh muda o passwd, e o bloco confirma lendo o passwd
  C. o chsh mente      -> o chsh sai com 0 mas NAO muda o passwd

O caso C e o que existia na VM: `chsh` sai com 0 sem mudar nada e o script
reportava sucesso. Ele nao se mede com um `chsh` de verdade, porque um `chsh` de
verdade depende de `/etc/passwd` do container e de privilegio — e o que se quer
medir aqui e a DECISAO do script, dada uma resposta do `chsh`.

Os fakes repassam `PATH` e comem flags: sem isso o falso `chsh` seria chamado
com `-s /usr/bin/zsh agent`, nao encontraria seu proprio diretorio e falharia
por um motivo que nao e o do teste. Ja aconteceu nesta sessao, quatro vezes.
"""

import os
import re
import shutil
import subprocess

# A raiz vem do lugar do script, e nao de um caminho fixo. Um caminho absoluto
# aqui faz o teste ler OUTRO checkout — ou nenhum, se o repositorio estiver em
# outro lugar, que e o caso de qualquer container ou VM onde ele nao esteja em
# `/home/rvlmt/...`. Foi assim na primeira execucao da suite no container: o
# arquivo nao foi encontrado e a falha pareceu do `setup.sh`.
RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE = "/tmp/opencode/chsh-teste"

# Cada cenario: o que o falso `chsh` faz, e a FRASE que o bloco tem de dizer.
#
# As frases sao as do `setup.sh`, nao as do harness. A primeira versao deste teste
# comparava `MUDOU_OK` / `CHSH_MENTIU` / `CHSH_FALHOU` — tokens que existiam
# apenas no bloco de teste local, e que o bloco REAL nao emite. Resultado: 0 ok e
# 5 falhas com o codigo certo, e o cenario A "falhou" mostrando a linha de
# sucesso — que era justamente a prova de que o ramo escolhido estava errado.
#
# Um teste que casa com o que o codigo DIZ mede o comportamento. Um que casa com
# um token do proprio harness mede o harness.
CENARIOS = [
    ("A. ja e zsh: o chsh nao pode ser chamado", "ja_zsh", "Shell de login ja e zsh"),
    ("B. o chsh muda o passwd de verdade", "muda", "Shell de login alterado para zsh"),
    ("C. o chsh sai com 0 e NAO muda nada (o caso da VM)", "mente", "mas o shell de login continua"),
    ("D. o chsh falha de verdade (saida diferente de zero)", "falha", "O chsh falhou"),
]
# E o que NAO pode aparecer em cada cenario. Sem isto o cenario A passaria com a
# linha de "alterado", e o C passaria com a de "ja e zsh": o `in` casa por
# substring, e "Shell de login" esta nas duas frases.
PROIBIDO = {
    "ja_zsh": "Shell de login alterado para zsh",
    "muda": "mas o shell de login continua",
    "mente": "Shell de login alterado para zsh",
    "falha": "Shell de login alterado para zsh",
}


def fakes(cenario):
    """Escreve `sudo`, `chsh` e `getent` falsos que se comportam como o cenario."""
    d = os.path.join(BASE, "fake")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    passwd = os.path.join(d, "passwd.txt")

    io_passwd = "/bin/bash"
    if cenario == "ja_zsh":
        io_passwd = "/usr/bin/zsh"
    with open(passwd, "w") as f:
        f.write("agent:x:1000:1000::/home/agent:%s\n" % io_passwd)

    chsh = {
        # sai com 0 e nao escreve no passwd: e o que o chsh real faz quando o
        # shell pedido ja e o do usuario
        "ja_zsh": "#!/bin/sh\nexit 0\n",
        "muda": "#!/bin/sh\nsed -i 's#:[^:]*$#:%s#' %s\nexit 0\n" % ("/usr/bin/zsh", passwd),
        "mente": "#!/bin/sh\nexit 0\n",
        "falha": "#!/bin/sh\necho 'chsh: Permission denied' >&2\nexit 1\n",
    }[cenario]

    with open(os.path.join(d, "chsh"), "w") as f:
        f.write(chsh)
    # `sudo` come os flags e execa o resto, como o sudo de verdade. Sem `exec`,
    # o falso sudo perderia o codigo de saida do chsh — e o teste mediria o sudo.
    with open(os.path.join(d, "sudo"), "w") as f:
        f.write('#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done\nexec "$@"\n')
    with open(os.path.join(d, "getent"), "w") as f:
        # `getent passwd agent` devolve a entrada INTEIRA; quem corta o campo 7 e
        # o bloco. Um falso que devolvesse o arquivo inteiro faria o
        # `cut -d: -f7` pegar a ultima linha do arquivo, e o bloco diria
        # "continua desconhecido" — uma frase que parece o ramo de problema e
        # seria o de sucesso. A primeira versao fazia isso.
        # O bloco chama `getent passwd "$(id -un)"` — e o PRIMEIRO argumento de
        # `getent` e o nome da base de dados (`passwd`), nao o do usuario. O falso
        # usava `$1` como nome, e por isso respondia sobre "passwd"; o `cut -d: -f7`
        # do bloco pegava o campo 7 dessa linha inventada e o bloco dizia
        # "continua desconhecido" — uma frase que PARECE o ramo de problema e era
        # o de sucesso. Medido nesta sessao, em duas versoes do falso.
        #
        # O nome vem do ULTIMO argumento, que e o que o bloco passa — e o
        # `for` em vez de `${!#}`, que e bash puro e o shebang e `/bin/sh`. Ja
        # aconteceu aqui: o falso devolvia string vazia e o bloco dizia
        # "desconhecido". Os fakes sao `#!/bin/sh` de proposito, para o teste
        # nao depender de um shell que o `setup.sh` nao exige. E o falso
        # responde para o nome que for pedido, e nao para um fixo: o `id -un` do
        # host e o nome de quem roda, e um teste que presume `agent` mede outra
        # maquina.
        f.write(
            '#!/bin/sh\n'
            'for a in "$@"; do nome="$a"; done\n'   # ultimo argumento = o usuario
            'grep "^$nome:" %s || echo "$nome:x:1000:1000::/home/$nome:$(cut -d: -f7 %s)"\n'
            % (passwd, passwd)
        )

    for n in ("chsh", "sudo", "getent"):
        os.chmod(os.path.join(d, n), 0o755)
    return d


def main():
    # O bloco real decide por `command -v zsh`, entao este teste precisa do zsh no
    # PATH. E um pre-requisito legitimo — o `setup.sh` instala o zsh ANTES desse
    # bloco, e o teste existe para o bloco, nao para a instalacao.
    #
    # Ainda assim, a primeira vez que a suite rodou num container sem zsh, os
    # quatro cenarios responderam "zsh nao instalado; o shell de login ficou como
    # estava" e o teste acusou as quatro frases esperadas. E o caminho de erro do
    # `setup.sh` funcionando: o teste nao media o que dizia medir. Falhar aqui, com
    # o pre-requisito nomeado, e melhor que medir outra coisa.
    if not any(
        os.access(os.path.join(d, "zsh"), os.X_OK)
        for d in os.environ.get("PATH", "").split(os.pathsep)
        if d
    ):
        print("  RECUSA: este teste precisa do zsh no PATH (o bloco mede o shell de login).")
        print("          Fedora: sudo dnf install -y zsh")
        return 2

    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(BASE)
    io_bloco = os.path.join(BASE, "bloco.sh")

    # O bloco REAL, extraido do setup.sh, para o exercitar e nao uma reescrita.
    src = open(os.path.join(RAIZ, "setup.sh"), encoding="utf-8").read()
    ini = src.find('    _shell_login() {')
    fim = src.find('\n    fi\n', src.find('_zsh_alvo', ini))
    if ini < 0 or fim < 0:
        print("  FALHA: nao achei o bloco do chsh no setup.sh")
        return 1
    real = src[ini : fim + len("\n    fi\n")]
    print("== o bloco real do setup.sh (linhas %d..%d) ==" % (
        src[:ini].count("\n") + 1, src[:fim].count("\n") + 1))
    # Tira a indentacao de 4 para caber no harness, e o `echo -e` de cor.
    corpo = "\n".join(l[4:] if l.startswith("    ") else l for l in real.split("\n"))
    corpo = re.sub(r'echo -e "\$\{[A-Z]+\}', 'echo "', corpo)
    corpo = corpo.replace("${NC}", "")
    with open(io_bloco, "w") as f:
        f.write(corpo + '\n')
    print("  %d linhas, com o `echo -e` de cor removido" % len(corpo.split("\n")))

    ok = 0
    falhas = 0
    for titulo, cenario, esperado in CENARIOS:
        d = fakes(cenario)
        env = dict(os.environ)
        env["PATH"] = d + ":/usr/bin:/bin"
        r = subprocess.run(
            ["bash", io_bloco, "/usr/bin/zsh"],
            capture_output=True, text=True, timeout=60, env=env,
        )
        # Os ramos que dao PROBLEMA escrevem em `>&2`, que e o certo: sao avisos.
        # Ler so o stdout e o que fez os cenarios C e D parecerem silenciosos — o
        # bloco dizia a coisa toda, e o teste nao via. As duas correntes entram na
        # verificacao porque o que importa e o que o bloco AFIRMA, e nao em qual
        # descriptor ele afirmou.
        saida = (r.stdout + r.stderr).strip()
        print()
        print("== %s ==" % titulo)
        for l in saida.split("\n"):
            print("  " + l[:92])
        if esperado in saida:
            print("  ok   o bloco disse: %s" % esperado)
            ok += 1
        else:
            print("  FALHA esperava '%s' e a saida nao tem isso" % esperado)
            falhas += 1
        proibido = PROIBIDO[cenario]
        if proibido in saida:
            print("  FALHA o bloco tambem disse '%s' — e o cenario nao permite" % proibido)
            falhas += 1
        # O caso A tem uma exigencia a mais: nao chamar o chsh. Com um `chsh` que
        # MUDASSE o passwd, o bloco poderia chamar e logo depois dizer "ja e zsh"
        # — e o `ok` acima nao pegaria isso, porque a frase e a mesma.
        if cenario == "ja_zsh" and "Shell de login atual:" in saida:
            print("  FALHA o bloco tentou mudar um shell que ja era o certo")
            falhas += 1

    print()
    print("CHSH: %d ok, %d falhas" % (ok, falhas))
    return 1 if falhas else 0


if __name__ == "__main__":
    raise SystemExit(main())
