import io, os, re, unicodedata

CJK = re.compile(
    r'[\u1100-\u11ff\u2e80-\u303f\u3040-\u30ff\u3130-\u318f'
    r'\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\ufe30-\ufe4f'
    r'\uff00-\uffef]'
)
# Full-width/half-width ja contam acima. Latin com acento e portugues sao legítimos.

achados = []
for raiz, _, arquivos in os.walk("."):
    if "/.git" in raiz:
        continue
    for arq in arquivos:
        caminho = os.path.join(raiz, arq)
        if not arq.endswith((".sh", ".md", ".json", ".toml")):
            continue
        try:
            t = io.open(caminho, encoding="utf-8").read()
        except Exception:
            continue
        for m in CJK.finditer(t):
            linha = t[:m.start()].count("\n") + 1
            achados.append((caminho, linha, m.group(0), unicodedata.name(m.group(0), "?")))

if achados:
    for c, l, ch, nome in achados:
        print("  %s:%d  %r  %s" % (c, l, ch, nome))
else:
    print("  nenhum caractere CJK em nenhum arquivo do repo")
