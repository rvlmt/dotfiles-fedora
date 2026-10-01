#!/usr/bin/env python3
"""O que um repo publico revelaria, medido no arquivo e no historico.

Fiz esse caminho com heuristicas e errei: um `grep` por `PRIVATE KEY` acusou
`setup.sh` e `tests/structure-test.sh`, e as duas ocorrencias sao PADROES de
casamento, nao chaves — o script casa a linha `BEGIN` para detectar um paste
truncado, e a checagem estrutural procura segredo justamente para acusar. O
diagnostico reportou o objeto errado, que e a falha mais cara que existe aqui.

Por isso a pergunta nao e "o nome PRIVATE KEY aparece" e sim "existe material
criptografico de verdade": a chave tem corpo, e o corpo e base64 com a estrutura
de um bloco PEM. Alem disso, valores de alta entropia, que e o que distingue uma
senha de uma frase em portugues.
"""

import io
import math
import os
import re
import subprocess

# Tres niveis: tests/lib/<este arquivo>. Com dois, isto da `tests/`, que nao tem
# .git — e `git ls-files` ali devolve VAZIO, sem erro. O script reportava "nenhum
# segredo encontrado" having measured zero files. Um diagnostico que reporta zero
# sem ter medido nada e o pior resultado possivel: e verde, e esta errado.
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Um cabecalho PEM de verdade, E o corpo que vem depois dele. Sem o corpo, o que
# sobra e um padrao de casamento — foi exatamente o falso positivo.
PEM = re.compile(
    r"-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----\s*\n"
    r"((?:[A-Za-z0-9+/=]{40,}[ \t]*\n){3,})"
    r"-----END \1PRIVATE KEY-----"
)

# Tokens com formato proprio: casar por formato nao gera falso positivo, porque
# ninguem escreve "ghp_" seguido de 36 caracteres alfanumericos numa frase.
GH = re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")

# AWS, Slack e JWT. O JWT aparece naturalmente em documentacao de oauth, entao
# e reportado separado para nao virar alarme.
OUTROS = re.compile(
    r"\b(AKIA[0-9A-Z]{16}"
    r"|xox[baprs]-[A-Za-z0-9-]{10,}"
    r"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b"
)

# Atribuicoes que valem como segredo, e nao como variavel. O filtro e o valor
#ter uma senha literal depois do `=`.
SENHA = re.compile(
    r"(?i)\b(password|senha|secret|token|api[_-]?key)\b\s*[=:]\s*[\"']?([^\"'\s$}{]{8,})"
)

# Palavras que, mesmo em atribuicao, sao placeholders e nao segredo.
PLACEHOLDER = re.compile(
    r"(?i)^(x{3,}|\*{3,}|\.\.\.|<[^>]*>|seu[-_ ]|your[-_ ]|changeme|exemplo|"
    r"placeholder|example|dummy|teste|fake|foo|bar|senha|password|secret|token|"
    r"a|o|no|na|de|do|da|none|null|true|false|yes|no|\d+)$"
)


def entropia(s):
    """Bits por caractere. Senha alta; frase em portugues, baixa."""
    if not s:
        return 0.0
    contagem = {}
    for c in s:
        contagem[c] = contagem.get(c, 0) + 1
    h = 0.0
    for n in contagem.values():
        p = n / len(s)
        h -= p * math.log2(p)
    return h


def versionados():
    r = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True)
    return [os.path.join(REPO, f) for f in r.stdout.split() if f]


def main():
    problemas = []
    arquivos = versionados()
    if not arquivos:
        print("ERRO: git ls-files nao devolveu nada em %s." % REPO)
        print("      Ou o caminho do repo esta errado, ou nao ha nada versionado.")
        print("      'Nenhum segredo encontrado' aqui seria mentira, e nao resultado.")
        return 2
    print("Medindo %d arquivo(s) versionado(s) em %s\n" % (len(arquivos), REPO))

    print("== 1. material PEM de verdade: cabecalho E corpo ==")
    n = 0
    for caminho in arquivos:
        try:
            t = io.open(caminho, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in PEM.finditer(t):
            n += 1
            ln = t[: m.start()].count("\n") + 1
            rel = os.path.relpath(caminho, REPO)
            print("  ACHADO %s:%d  (%s, %d bytes de corpo)"
                  % (rel, ln, m.group(1), len(m.group(2))))
            problemas.append("PEM em %s" % rel)
    if n == 0:
        print("  nenhum. As ocorrencias de 'PRIVATE KEY' sao padroes de casamento.")

    print()
    print("== 2. tokens de servico, casados por formato ==")
    n = 0
    for caminho in arquivos:
        try:
            t = io.open(caminho, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in GH.finditer(t):
            n += 1
            rel = os.path.relpath(caminho, REPO)
            ln = t[: m.start()].count("\n") + 1
            print("  ACHADO %s:%d  %s...%s" % (rel, ln, m.group(1)[:8], m.group(1)[-4:]))
            problemas.append("token GitHub em %s" % rel)
    if n == 0:
        print("  nenhum token com formato de GitHub.")

    print()
    print("== 3. AWS, Slack e JWT (o JWT pode ser exemplo de documentacao) ==")
    n = 0
    for caminho in arquivos:
        try:
            t = io.open(caminho, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in OUTROS.finditer(t):
            n += 1
            rel = os.path.relpath(caminho, REPO)
            ln = t[: m.start()].count("\n") + 1
            print("  ACHADO %s:%d  %s..." % (rel, ln, m.group(1)[:10]))
            problemas.append("token de servico em %s" % rel)
    if n == 0:
        print("  nenhum.")

    print()
    print("== 4. senha literal em atribuicao (so o que tem alta entropia) ==")
    n = 0
    for caminho in arquivos:
        try:
            t = io.open(caminho, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for ln_i, linha in enumerate(t.split("\n"), 1):
            if linha.lstrip().startswith("#"):
                continue
            for m in SENHA.finditer(linha):
                valor = m.group(2)
                if PLACEHOLDER.match(valor) or entropia(valor) < 3.2:
                    continue
                n += 1
                rel = os.path.relpath(caminho, REPO)
                print("  ACHADO %s:%d  %s=%.24s..." % (rel, ln_i, m.group(1), valor))
                problemas.append("senha em %s:%d" % (rel, ln_i))
    if n == 0:
        print("  nenhuma senha literal de alta entropia fora de comentario.")

    print()
    print("== 5. o que um repo publico mostraria, e isso e escolha sua ==")
    for rotulo, padrao in [
        ("dominio da tailnet", r"sawfish-banjo\.ts\.net"),
        ("login do GitHub", r"\brvlmt\b"),
        ("portas internas", r":(8443|8444|8445|7456|9119)\b"),
        ("URL do device-keys", r"rvlmt\.keys"),
    ]:
        total = 0
        arquivos_com = 0
        for caminho in arquivos:
            try:
                t = io.open(caminho, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            c = len(re.findall(padrao, t))
            if c:
                total += c
                arquivos_com += 1
        print("  %-22s %4d ocorrencia(s) em %d arquivo(s)" % (rotulo + ":", total, arquivos_com))

    print()
    if problemas:
        print("BLOQUEADO: %d achado(s) que nao deveriao ir para um repo publico:" % len(problemas))
        for p in problemas:
            print("  - %s" % p)
        return 1
    print("Nenhum segredo encontrado no que esta versionado.")
    print("O que restaria publico e convencao e endereco interno — isso e decisao sua,")
    print("nao um segredo, e o dominio da tailnet so e alcancavel por quem esta nela.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
