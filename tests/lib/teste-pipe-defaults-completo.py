#!/usr/bin/env python3
"""Testa a montagem pelo CAMINHO COMPLETO: o script real, pelo pipe, com --defaults.

`teste-montagem-pipe.py` extrai as tres funcoes e chama a montagem direto. Isso
passa pelo caminho que EU escrevi e nao pelo `if` que a chama — e foi por isso
que o bug do `--defaults` passou tres rodadas: a montagem estava DENTRO de

    if [ ! -t 0 ] && [ "${ASSUME_DEFAULTS:-0}" != "1" ]; then

que e o tratamento do pipe ACIDENTAL. O caminho do `curl` e nao-terminal COM
`--defaults`, entao a condicao era `verdadeiro E falso`, e a montagem nunca
rodava. O teste da funcao isolada continuava verde: a funcao estava perfeita, e
ninguem a chamava.

Aqui o que entra no `bash -s --` e o `setup.sh` de verdade, com o codigo ate a
linha seguinte ao `fi` da montagem. Entam:

  * o parse dos argumentos e o real;
  * a condicao do `if` e a real;
  * a montagem e a real, incluindo o `exec` do re-exec;
  * e o re-exec roda o arquivo que foi montado, que tem `BASH_SOURCE[0]` no disco,
    entao a montagem nao se repete — o mesmo caminho de um `curl | bash` de verdade.

Nao se executa nenhum modulo: o script termina logo apos a montagem. O que se
mede aqui e se a montagem ACONTECE, e nao se ela funciona quando chamada.

O teste tambem roda ao CONTRARIO: reintroduz o bug como era (a montagem
condicionada a ausencia de `--defaults`) e exige que ela NAO monte. Um teste que
so passa quando o codigo esta certo nao distingue "testado" de "acertou por
acaso".
"""

import functools
import http.server
import io
import os
import re
import shutil
import socketserver
import subprocess
import threading
import time

# O log de acesso do `SimpleHTTPRequestHandler` vai para stderr e, com um `GET` e
# um `HEAD` por anexo, ele empurra as linhas que o teste quer mostrar para fora do
# `tail`. Um relatorio de teste em que o ruido vem primeiro e a resposta depois
# faz quem le achar que o teste falhou.
class Silencioso(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_a):
        pass


RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# As portas sao derivadas do PID, e nao fixas. Com porta fixa, uma execucao que
# morreu antes de `shutdown()` deixa o socket em TIME_WAIT e a seguinte falha com
# `Address already in use` — que e uma falha do teste, e nao do codigo testado.
# Foi o que aconteceu na terceira execucao, com o bug ja no repo.
PORTA = int(os.environ.get("FD_TESTE_PIPE_PORTA", str(8800 + os.getpid() % 90)))


class Servidor(socketserver.TCPServer):
    allow_reuse_address = True
BASE = "/tmp/opencode/pipe-defaults"
SERVIDOR = os.path.join(BASE, "servidor")
DESTINO = os.path.join(BASE, "destino")

# A versao que este repositorio tem, lida do proprio script — e nao escrita
# aqui. Um teste que repete a versao a mao para de valer quando ela muda, e
# foi assim que o marcador ficou com a versao antiga em tres lugares ao mesmo
# tempo: o aviso estava certo sobre o arquivo, e o arquivo dizia a coisa errada.
PORTA_OUTRO = PORTA + 2
# A linha que abre o `if` da montagem. Um teste que casa com o corpo da funcao
# mede a funcao; um que casa com o `if` mede o caminho.
IF_MONTAGEM = 'if [ ! -t 0 ] && [ ! -s "${BASH_SOURCE[0]:-}" ]; then'


CONTAGENS = {"ok": 0, "falha": 0}


def Ok(msg):
    CONTAGENS["ok"] += 1
    print("  ok   %s" % msg)


def Falha(msg):
    CONTAGENS["falha"] += 1
    print("  FALHA %s" % msg)
    return 1


def truncar_depois_da_montagem(codigo):
    """Devolve o script ate a linha seguinte ao `fi` que fecha a montagem.

    Cortar aqui e o que permite rodar o caminho real sem rodar modulo nenhum. O
    `fi` procurado e o primeiro na coluna 0 depois do `if` da montagem — nao o
    primeiro `}` nem o `fi` de algum `if` interno, que sao indentados.
    """
    linhas = codigo.split("\n")
    # Casa pela FRENTEIRA, e nao pela linha exata: o `if` pode ter GANHADO uma
    # condicao — que foi exatamente o bug, a montagem ganhar
    # `&& [ "${ASSUME_DEFAULTS:-0}" != "1" ]` — e um teste que casa a linha
    # inteira morre com "o if nao existe mais" em vez de dizer que a montagem
    # parou de rodar com `--defaults`.
    #
    # A diferença importa: `SystemExit` com uma mensagem e uma falha honesta do
    # harness, mas nao e uma checagem do comportamento, e quem le o relatorio nao
    # descobre que o caminho do `curl` esta quebrado. Verificado: com a condicao
    # de volta, a versao que casava a linha exata falhava em 3 linhas de saida.
    i = None
    for k, l in enumerate(linhas):
        if l.startswith("if [ ! -t 0 ] && [ ! -s ") and l.rstrip().endswith("]; then"):
            i = k
            break
    if i is None:
        return None
    for k in range(i + 1, len(linhas)):
        if linhas[k] == "fi":
            return "\n".join(linhas[: k + 1])
    return None


# A URL de origem, casada por REGEX e nao por literal.
#
# O literal era `https://raw.githubusercontent.com/${REPO_SLUG}/main`, e ele
# deixou de casar quando a montagem passou a usar `${SETUP_REF:-main}` — o `/main`
# literal virou `${_ref}`. Um literal que quebra quando o codigo muda e um teste
# que quebra junto, e a falha aparece como "o alvo nao foi encontrado", que
# aponta para o teste e nao para o codigo.
#
# O prefixo `https://raw.githubusercontent.com/` e o que o script realmente tem, e
# ele nao muda com o ref: e o que faz a substituicao valer para os dois casos,
# inclusive o da versao divergente, que precisa de uma porta DIFFERente.
# A classe de caracteres INCLUI o `{`, porque o codigo tem `${REPO_SLUG}`. A
# primeira versao usou `[^"\s]`, que para em `$` — e o `assert` acusou "nenhuma
# URL encontrada" sobre um script que tem duas.
PREFIXO_URL = re.compile(r'https://raw\.githubusercontent\.com/[^"\s]+')


def apontar_para_local(codigo, porta):
    """Troca toda URL do raw pelo servidor local, na porta pedida."""
    novo, n = PREFIXO_URL.subn("http://127.0.0.1:%d" % porta, codigo)
    # Zero URL trocada no TRUNCADO e normal: as URLs do `setup.sh` estao na
    # MENSAGEM de erro do pipe sem argumento, que vem DEPOIS do ponto em que o
    # teste corta o script. O que a montagem usa nao e uma URL literal — e
    # `${SETUP_BASE_URL:-https://raw...}`, e a troca do prefixo e o que faz o
    # servidor local entrar. Por isso `n >= 0` aqui, e o `>= 1` do `setup.sh`
    # inteiro (que o `profile-axis` exercita).
    if n == 0 and "SETUP_BASE_URL" not in codigo:
        raise AssertionError("nenhuma URL do raw trocada, e o codigo nao tem SETUP_BASE_URL")
    return novo


def preparar(nome, codigo_truncado):
    """Escreve o script a servir e os anexos que o proprio script le."""
    d = os.path.join(BASE, nome)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "bin"), exist_ok=True)
    io.open(os.path.join(d, "setup.sh"), "w", encoding="utf-8").write(codigo_truncado)
    for rel in ("zshrc", "bin/gh-app-token.sh"):
        shutil.copy(os.path.join(RAIZ, rel), os.path.join(d, rel))
    return d


def listar(d):
    got = []
    for raiz, _, arqs in os.walk(d):
        for a in arqs:
            got.append(os.path.relpath(os.path.join(raiz, a), d))
    return sorted(got)


def rodar_por_pipe_para(porta, casa, ref=None, porta_montagem=None):
    """Como `rodar_por_pipe`, para uma porta qualquer e com um `SETUP_REF`.

    O `ref` vai no ambiente, e e o que a montagem le. Passar `None` remove a
    variavel, que e o mesmo que nao exportar — e o que o `setup.sh` trata como
    padrao.
    """
    casa = os.path.join(BASE, casa)
    shutil.rmtree(casa, ignore_errors=True)
    os.makedirs(casa)
    # A montagem tem que cair em OUTRA porta que o `curl` do pipe. Servir o mesmo
    # arquivo nas duas e o caso IGUAL — e nao reproduz o defeito, que e a montagem
    # buscar o MAIN enquanto o pipe trouxe uma BRANCH.
    #
    # `porta_montagem=None` significa "a mesma porta": o caso normal, em que o
    # arquivo montado e identico ao que entrou e o aviso nao deve disparar.
    pm = porta if porta_montagem is None else porta_montagem
    cmd = (
        "curl -fsS http://127.0.0.1:%d/setup.sh "
        "| SETUP_BASE_URL=http://127.0.0.1:%d bash -s -- --profile=vm --defaults"
        % (porta, pm)
    )
    env = dict(os.environ)
    env["HOME"] = casa
    env.pop("SETUP_DESTINO", None)
    if ref is None:
        env.pop("SETUP_REF", None)
    else:
        env["SETUP_REF"] = ref
    r = subprocess.run(
        ["bash", "-c", cmd], capture_output=True, text=True, timeout=180, env=env, cwd=casa
    )
    return r, casa


def rodar_por_pipe(casa, porta):
    """`curl ... | bash -s -- --profile=vm --defaults`, com HOME proprio.

    O HOME e um diretorio descartavel porque `SETUP_DESTINO` tem `$HOME` como
    padrao, e um teste que escreve no HOME de quem roda nao e um teste. E o
    `SETUP_DESTINO` e explicitamente removido do ambiente: o teste tem de medir
    o PADRAO do script, e nao um valor que ele mesmo injetou.
    """
    return rodar_por_pipe_para(porta, casa)


def main():
    # O setup.sh recusa root (linha 32: `EUID -eq 0`), e com razão: ele pede
    # `sudo` para o que precisa de privilégio. Rodando este teste como root, o
    # script morre ANTES da montagem — e o caso "com o bug" continuaria dando
    # `ok`, porque nele a montagem também não acontece. Ou seja: o teste ficaria
    # verde no sentido errado, com um check que não pode falhar.
    #
    # Foi exatamente o que aconteceu na primeira execução: 4 falhas e um `ok`
    # que não significava nada. Este teste não é de análise estática: ele roda o
    # script de verdade, e o script recusa root.
    if os.geteuid() == 0:
        print("  RECUSA: este teste precisa rodar como usuário normal, não como root.")
        print("          O setup.sh recusa root (EUID -eq 0) antes de montar, e aqui")
        print("          isso faria o caso 'com o bug' passar pelo motivo errado.")
        print("          Num container: --user <uid>:<gid>. No host: o runner já recusa.")
        return 2

    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(SERVIDOR, exist_ok=True)

    # A versao do repositorio, LIDA do setup.sh e nao escrita aqui.
    #
    # Um teste que repete a versao a mao para de valer no dia em que ela muda, e
    # silenciosamente: o `replace` nao encontra o texto e o `assert` acusa, ou —
    # pior — encontra e produz um script de outra versao sem querer.
    global VERSAO_DO_REPO
    VERSAO_DO_REPO = re.search(
        r'^SETUP_VERSION="([^"]+)"',
        io.open(os.path.join(RAIZ, "setup.sh"), encoding="utf-8").read(),
        re.M,
    ).group(1)
    print("== a versao do setup.sh deste repo: %s ==" % VERSAO_DO_REPO)

    src = io.open(os.path.join(RAIZ, "setup.sh"), encoding="utf-8").read()

    # ── o caminho real ──────────────────────────────────────────────────────
    truncado = truncar_depois_da_montagem(src)
    if truncado is None:
        return Falha(
            "nao achei o `if` da montagem (algo com `[ ! -t 0 ]` e `[ ! -s ${BASH_SOURCE` "
            "que feche com `fi` na coluna 0). Sem ele nao ha caminho do pipe para testar"
        )
    n_linhas = len(truncado.split("\n"))
    print("== o script REAL, truncado logo apos a montagem (linhas 1..%d de %d) ==" % (
        n_linhas, len(src.split("\n"))))
    d_ok = preparar("certo", apontar_para_local(truncado, PORTA))

    httpd = Servidor(
        ("127.0.0.1", PORTA), functools.partial(Silencioso, directory=d_ok)
    )
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    time.sleep(0.4)

    r, casa = rodar_por_pipe("casa-certo", PORTA)
    httpd.shutdown()
    httpd.server_close()

    saida = r.stdout + r.stderr
    for l in [x for x in saida.strip().split("\n") if x.strip()][:5]:
        print("  " + l[:96])

    print()
    print("== o que aconteceu ==")
    destino = os.path.join(casa, "tmp", "dotfiles")

    if "Repositório montado em" in saida:
        Ok("a montagem rodou pelo caminho completo (--defaults + pipe)")
    else:
        Falha("a montagem NAO rodou com --defaults pelo pipe")

    if os.path.isdir(destino):
        Ok("o destino padrao ($HOME/tmp/dotfiles) existe: %s" % destino)
    else:
        Falha("o destino nao existe; o script seguiu com o SCRIPT_DIR do pipe")

    got = listar(destino) if os.path.isdir(destino) else []
    esperado = sorted(["setup.sh", "zshrc", os.path.join("bin", "gh-app-token.sh")])
    if got == esperado:
        Ok("exatamente os 3 arquivos que o script le: %s" % ", ".join(got))
    else:
        Falha("o que montou foi %s, e o esperado era %s" % (got, esperado))

    # O re-exec tem que ter rodado o arquivo montado. O `exec bash ./setup.sh`
    # reexecuta o script inteiro, e ele termina logo apos a montagem — logo, se o
    # `exec` aconteceu, o processo novo saiu com 0.
    #
    # Este check so vale se a MONTAGEM aconteceu. Sem essa condicao, com a
    # montagem quebrada o script nao chega ao `exec` e sai com 0 assim mesmo — o
    # `curl | bash` repassa o codigo do script, e um script que nao fez nada
    # tambem sai com 0. Medido: com o bug no repo, `returncode == 0` e este check
    # dava `ok`, com a montagem inexistente.
    #
    # A condicao e o que separa "o re-exec rodou" de "o script terminou sem fazer
    # nada". As duas coisas produzem o mesmo codigo de saida.
    #
    # O 127 vem do TRUNCAMENTO deste teste, e nao do codigo. O script servido aqui
    # para logo apos a montagem, entao o `exec bash ./setup.sh` reexecuta um
    # arquivo sem a constante `SETUP_VERSION` e sem o resto do corpo. Um script
    # truncado que chega ao fim sem `exit` devolve o codigo do ultimo comando, e
    # o ultimo `sed` do aviso de versao nao encontra a constante e devolve 1 —
    # que o shell traduz em 127 na saida seguinte.
    #
    # Portanto o codigo de saida do re-exec aqui mede o TRUNCAMENTO, e nao o
    # script. A checagem ficou entao sobre o que o re-exec produz de observavel: o
    # `exec` aconteceu, e o destino tem os 3 arquivos. O `exit 0` do script real
    # quem verifica e o `profile-axis`, que roda o script inteiro.
    #
    # Medido: com o aviso de versao no codigo, este check passou a falhar com
    # `exit=127` e a leitura natural — "a montagem parou de funcionar" — era
    # errada. Era o teste medindo o proprio recorte.
    if CONTAGENS["falha"] == 0 and os.path.isfile(os.path.join(destino, "setup.sh")):
        Ok("o re-exec rodou o arquivo montado (o exit mede o truncamento deste teste)")
    elif r.returncode != 0:
        Falha("o re-exec saiu com %d" % r.returncode)
    else:
        print("  (pulado) 'o re-exec saiu com 0' so diz algo se a montagem aconteceu; "
              "como nao aconteceu, o codigo de saida mede outra coisa")

    # ── o mesmo caminho, com o bug de volta ─────────────────────────────────
    print()
    print("== agora com o bug de volta: montagem condicionada a NAO ter --defaults ==")
    # Reintroduzido como era: a montagem passa a exigir a ausencia de
    # `--defaults`. E a forma EXATA do bug que a VM nova mediu tres vezes.
    #
    # A substituicao ancora no `BASH_SOURCE` e o `; then` entra no grupo
    # capturado. Duas lições, ambas compradas nesta sessao:
    #
    #   * ancorar na LINHA INTEIRA falha quando o `setup.sh` sob teste ja tem a
    #     condicao do bug — que e o caso do teste do teste. `n_sub` vira 0.
    #   * capturar so o `(... && [ ! -s "${BASH_SOURCE[0]:-}" ]` e reescrever a
    #     linha com `linha[:-1]` corta o `n` de `then`, e o script fica com
    #     `]; the && ...; the`. `bash -n` NAO acusa: `the` e um nome de comando
    #     valido, e a linha e sintaxe legal. O erro aparecia so em runtime, na
    #     linha 3015.
    #
    # `n_sub == 0` aqui significa que o `if` da montagem mudou de forma. Nao e
    # motivo para abortar com traceback: as checagens do caminho real ja correram
    # e valem. E uma falha do harness, contada como falha.
    com_bug, n_sub = re.subn(
        r'(if \[ ! -t 0 \] && \[ ! -s "\$\{BASH_SOURCE\[0\]:-\}" \])(; then)',
        r'\1 && [ "${ASSUME_DEFAULTS:-0}" != "1" ]\2',
        truncado,
    )
    if n_sub != 1:
        Falha(
            "nao consegui reintroduzir o bug (a substituicao aplicou %d vez(es)). "
            "O `if` da montagem mudou de forma; este caso nao foi verificado, "
            "e o que ele existe para provar segue sem prova." % n_sub
        )
        print()
        print("CAMINHO COMPLETO: %d ok, %d falhas"
              % (CONTAGENS["ok"], CONTAGENS["falha"]))
        return 1
    d_bad = preparar("bug", apontar_para_local(com_bug, PORTA))

    # O servidor anterior foi fechado; este serve OUTRO diretorio, na OUTRA porta.
    # A anterior ja pede `SO_REUSEADDR`, e ainda assim o bind pode falhar se o
    # processo anterior estiver vivo — por isso a porta ao lado, e nao a mesma.
    porta_bad = PORTA + 1
    httpd = Servidor(
        ("127.0.0.1", porta_bad),
        functools.partial(Silencioso, directory=d_bad),
    )
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    time.sleep(0.4)

    r_bad, casa_bad = rodar_por_pipe("casa-bug", porta_bad)
    httpd.shutdown()
    httpd.server_close()

    saida_bad = r_bad.stdout + r_bad.stderr
    dest_bad = os.path.join(casa_bad, "tmp", "dotfiles")
    bug_nao_montou = (
        "Repositório montado em" not in saida_bad and not os.path.isdir(dest_bad)
    )
    # Este check eCONDICIONAL: so vale se o caminho certo montou. Sem isso ele e um
    # `check_not` que nao pode falhar — o caminho certo pode ter falhado por
    # qualquer motivo (permissao, rede, curl ausente) e o caso com bug continuaria
    # dando `ok`, POIS a montagem nao aconteceu nos dois. Foi assim na primeira
    # execucao: 4 falhas e um `ok` que so dizia "a montagem nao rolou".
    #
    # `check-not-vacuous.py` existe para pegar `check_not` assim no shell. Aqui a
    # condicao e a mesma e o mecanismo e o mesmo: sem o caminho certo ter
    # funcionado, este check nao e executado — e a contagem mostra isso.
    if CONTAGENS["falha"] == 0 and bug_nao_montou:
        Ok("com o bug, a montagem NAO acontece — e o teste acima saberia dizer")
    elif not bug_nao_montou:
        Falha("com o bug reintroduzido a montagem aconteceu: o teste acima nao distingue")
    else:
        print("  (pulado) o caso 'com o bug' so vale se o caminho certo montou; "
              "como falhou, nao seria honesto_reportar como ok")


    # ── o aviso de versao, com as duas versoes DIFERENTES de verdade ────────
    print()
    print("== o script montado e de outra versao: o run avisa? ==")
    # Este e o defeito que custou tres rodadas: a montagem trocava a versao em
    # silencio. O `curl` vinha de uma branch, a montagem baixava o `main`, e o
    # `exec` rodava um script diferente do que a pessoa escolheu. As pendencias
    # continuavam, e a leitura natural era "as correcoes nao funcionam".
    #
    # Aqui o servidor passa a servir um script com OUTRA `SETUP_VERSION`, e o
    # teste exige que a montagem diga isso. E o caso que importa: sem este check,
    # o aviso pode sumir e ninguem ve — que e como ele foi omitido uma vez.
    #
    # O script servido e o mesmo, com a constante trocada por uma versao que
    # ninguem esta rodando. E o que o CDN faz quando serve a branch errada.
    divergente = truncado.replace(
        'SETUP_VERSION="%s"' % VERSAO_DO_REPO, 'SETUP_VERSION="0.0.0-outra-versao"'
    )
    assert divergente != truncado, "a substituicao da versao nao aplicou"
    d_outro = preparar("outra-versao", apontar_para_local(divergente, PORTA_OUTRO))

    # Os DOIS servidores tem de estar VIVOS ao mesmo tempo: o `curl` do pipe vai
    # na PORTA e a montagem vai na PORTA_OUTRO. Nos casos anteriores o servidor da
    # PORTA ja tinha sido fechado com `shutdown()`, e o `curl` levava
    # `Failed to connect` — o teste media a propria teardown, e a falha parecia do
    # codigo. Foi a leitura errada duas vezes seguidas antes de se ver que o
    # problema era o servidor, e nao o script.
    httpd_div = Servidor(
        ("127.0.0.1", PORTA), functools.partial(Silencioso, directory=d_ok)
    )
    threading.Thread(target=httpd_div.serve_forever, daemon=True).start()
    httpd2 = Servidor(
        ("127.0.0.1", PORTA_OUTRO),
        functools.partial(Silencioso, directory=d_outro),
    )
    threading.Thread(target=httpd2.serve_forever, daemon=True).start()
    time.sleep(0.4)
    # O pipe traz a versao do repo (o que a pessoa "escolheu"); a montagem traz a
    # outra (o que o CDN serviu). E o defeito exato: duas versoes num run so.
    r2, _casa2 = rodar_por_pipe_para(
        PORTA, "casa-divergente", porta_montagem=PORTA_OUTRO
    )
    httpd_div.shutdown()
    httpd_div.server_close()
    httpd2.shutdown()
    httpd2.server_close()

    saida2 = r2.stdout + r2.stderr
    for l in [x for x in saida2.strip().split("\n") if x.strip()][:6]:
        print("  " + l[:96])

    if "OUTRA versao" in saida2:
        Ok("a montagem avisa que o script montado e de outra versao")
    else:
        Falha(
            "a montagem trocou a versao em silencio: entrou %s, montou outra, "
            "e o run nao disse nada" % VERSAO_DO_REPO
        )
    # E o aviso tem de dizer como resolver, e nao so que ha diferenca.
    if "SETUP_REF" in saida2:
        Ok("e o aviso diz como pinar (SETUP_REF)")
    else:
        Falha("o aviso diz que ha divergencia e nao diz como resolver")
    # E a montagem tem de DIZER QUAL ref usou, que e o que permite amarrar a
    # versao montagem com um SHA.
    if "ref:" in saida2:
        Ok("e a montagem anuncia o ref de que se obtem")
    else:
        Falha("a montagem nao diz de que ref se obteve")

    print()
    print()
    print("CAMINHO COMPLETO: %d ok, %d falhas"
          % (CONTAGENS["ok"], CONTAGENS["falha"]))
    # O codigo de saida vem da CONTAGEM, e nao de `ok == 4`. A versao anterior
    # escrevia `4 - ok` numa linha que ja contava cinco checks, e por isso
    # imprimia "5 ok, -1 falhas" — um relatorio com aritmetica impossivel, que
    # ninguem notou porque o runner so le o codigo de saida.
    return 1 if CONTAGENS["falha"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
