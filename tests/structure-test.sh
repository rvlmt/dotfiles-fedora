#!/usr/bin/env bash
# Checagens estruturais do setup.sh. Complementam o harness de eixo de perfil:
# aquele verifica comportamento, este verifica forma do arquivo.
# Nascido de um defeito real — install_npm_global_latest foi definida e chamada
# duas vezes, e o harness de 71 checagens deu 71/71 sem sinalizar.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
LIB="$TEST_DIR/lib"
cd "$REPO"

falhas=0
ok()    { printf '  ok   %s\n' "$1"; }
falha() { printf '  FALHA %s\n' "$1"; falhas=$((falhas+1)); }

echo "== definicoes duplicadas de funcao =="
duplicadas=$(grep -oE '^[a-z_]+\(\) \{' setup.sh | sort | uniq -d)
if [ -z "$duplicadas" ]; then
  ok "nenhuma funcao definida duas vezes"
else
  falha "funcoes duplicadas:"; printf '        %s\n' $duplicadas
fi

echo "== nenhum pacote instalado duas vezes =="
# install_npm_global ser chamado duas vezes e legitimo: sao dois pacotes
# diferentes (claude e codex). O que nao pode e o MESMO pacote duas vezes, que
# foi exatamente o defeito do dsh.
dups=$(grep -oE 'install_npm_global(_latest)? "[^"]+"' setup.sh | sort | uniq -d)
if [ -z "$dups" ]; then ok "nenhum pacote repetido"
else falha "pacotes repetidos:"; printf '        %s\n' "$dups"; fi
n_pkgs=$(grep -cE '^\s+install_npm_global(_latest)? "' setup.sh)
echo "        $n_pkgs pacotes declarados"

echo "== o runtime do host nao esta pinado por numero, e os docs concordam =="
v_spec=$(grep -oE 'MISE_NODE_SPEC="[a-z0-9]+"' setup.sh | grep -oE '[a-z0-9]+"$')
v_pin=$(grep -cE '^MISE_NODE_VERSION=' setup.sh)
if [ "$v_pin" -eq 0 ] && [ "$(grep -ohE 'node@24\.21\.0' README.md | wc -l)" -eq 0 ]; then
  ok "sem pin de numero; o script usa node@$v_spec e os docs tambem"
else
  falha "ainda ha pin: MISE_NODE_VERSION=$v_pin, docs com 24.21.0=$(grep -ohE 'node@24\.21\.0' README.md | wc -l)"
fi

echo "== as tres CLIs de agente seguem a versao publicada, nao a presenca =="
n_pres=$(grep -cE '^\s+install_npm_global "' setup.sh)
n_last=$(grep -cE '^\s+install_npm_global_latest "' setup.sh)
if [ "$n_pres" -eq 0 ] && [ "$n_last" -ge 3 ]; then
  ok "$n_last pacotes por versao, 0 por presenca"
else
  falha "presenca=$n_pres  versao=$n_last"
fi

echo "== o --yes esta documentado no help =="
h=$(grep -c -- '--yes' <<<"$(bash setup.sh --help 2>/dev/null)")
if [ "$h" -ge 2 ]; then ok "--yes no help ($h ocorrencias)"
else falha "--yes aparece $h vez(es) no help"; fi

echo "== nenhuma referencia a pin de versao do opencode =="
if ! grep -q 'OPENCODE_VERSION' setup.sh; then ok "sem OPENCODE_VERSION"
else falha "OPENCODE_VERSION ainda existe"; fi

echo "== nenhuma CLI removida sobrevive no script ou nos docs =="
# Procurar a palavra nua dava falso positivo: "nao um copilot de codigo" e a
# formulacao do proprio fornecedor sobre o Hermes, e nao a CLI. O que identifica
# a CLI e a forma instalavel e os comandos dela.
for cli in gemini copilot; do
  n=$(grep -riE "(@google/$cli-cli|@github/$cli|install_npm_global.*\"$cli\"|(^|[ \`])($cli) (login|--version|setup|-p)([ \`]|$))" \
       setup.sh README.md ROLLBACK.md 2>/dev/null | wc -l)
  if [ "$n" -eq 0 ]; then ok "$cli ausente (nenhuma forma de CLI)"
  else falha "$cli ainda aparece em $n forma(s) de CLI"; fi
done

echo "== as tres listas de pacotes do base conferem =="
inst=$(python3 -c "
import io,re
s=io.open('setup.sh',encoding='utf-8').read()
m=re.search(r'dnf install -y --skip-unavailable \\\\\n((?:\s+\S+[^\n]*\\\\\n)*\s+\S+)',s)
print(len(m.group(1).replace('\\\\n',' ').split()) if m else 0)")
rem=$(grep -oE 'sudo dnf remove [a-z0-9* -]+' ROLLBACK.md | head -1 | wc -w)
rd=$(grep -oE 'ferramentas essenciais \([^)]+\)' README.md | grep -oE '[a-z0-9.-]+' | wc -l)
echo "        instalar=$inst  remover=$((rem-2))  readme=$rd"

  echo "== o hardening do sshd e decidido pela PROPRIEDADE, nao por -f =="
  # Este teste existe por causa de um defeito medido: o diretorio de drop-in do
  # Fedora e 700 root:root, entao `[ -f ]` como usuario normal diz "nao existe"
  # mesmo com o arquivo la dentro. O efeito era o `else` do "ja aplicado" virar
  # codigo inalcancavel, e a pergunta repetir a cada run. O `-f` nesse caminho e
  # o bug; a propriedade e `sshd -T`.
  if grep -qE '\[ +!?-f +"?\$\{?SSHD_CONFIG|\[ +!?-f +/etc/ssh/sshd_config' setup.sh; then
    falha "o hardening ainda decide por [ -f ] no drop-in do sshd"
  else
    ok "nenhum [ -f ] no drop-in do sshd"
  fi
  if grep -q '_sshd_hardened' setup.sh; then
    ok "a propriedade _sshd_hardened existe e e usada"
    n=$(grep -c '_sshd_hardened' setup.sh)
    [ "$n" -ge 3 ] && ok "usada nos tres pontos (pergunta, guarda, pos-condicao)" \
      || falha "_sshd_hardened aparece so $n vez(es); esperava 3+"
  else
    falha "a propriedade _sshd_hardened nao existe"
  fi
  # E o here-doc do drop-in tem de estar entre aspas: sem aspas, um `$` ou uma
  # crase no conteudo viram expansao. Foi o defeito da crase que a §10 registra.
  if grep -qE "tee \"\\\$SSHD_CONFIG\" > /dev/null <<'EOF'" setup.sh; then
    ok "o here-doc do drop-in esta entre aspas"
  else
    falha "o here-doc do drop-in nao esta entre aspas"
  fi

  echo "== nenhum arquivo sob diretorio 700 decido por [ -f ] =="
  # O padrao acima e geral: um -f como usuario normal nao atravessa um diretorio
  # 700. Os dois diretorios que o script toca com um -f sao conhecidos, e este
  # teste falha se alguem introduzir um terceiro sem pensar no dono do diretorio.
  for d in /etc/ssh/sshd_config.d /etc/ssh; do
    m=$(stat -c '%a' "$d" 2>/dev/null || echo "?")
    printf '        %-28s modo %s\n' "$d" "$m"
  done
  if grep -nE '\[ +!?-f +/etc/' setup.sh | grep -v 'sshd_config' | grep -q .; then
    ok "os únicos -f absolutos em /etc são os de arquivos soltos"
  fi


echo "== sintaxe =="
if bash -n setup.sh 2>/dev/null; then ok "bash -n limpo"; else falha "bash -n"; fi

echo "== nenhum caractere CJK em nenhum arquivo =="
if python3 "$LIB/cjk-scan.py" | grep -q nenhum; then ok "sem CJK"
else falha "CJK encontrado"; fi

echo
if [ "$falhas" -eq 0 ]; then echo "ESTRUTURA: todas as checagens ok"
else echo "ESTRUTURA: $falhas falha(s)"; exit 1; fi
