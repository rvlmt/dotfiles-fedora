#!/usr/bin/env bash
# Exercita sync_device_keys_from_github com um feed FALSO: o que se testa é a
# lógica do bloco, não a rede. As chaves são REAIS (ssh-keygen), porque o
# relatório de revogação depende de `ssh-keygen -lf` ter fingerprint válido.
#
# Premissa que as versões anteriores deste teste erraram: o ~/.ssh da máquina
# contém SÓ a chave dela. Se as chaves de dispositivo também estiverem lá, o
# filtro de "chave própria" as trata como próprias e come o feed inteiro — que é
# o comportamento correto, e um teste que o escondia.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
set -uo pipefail

DK=$(mktemp -d)
trap 'rm -rf "$DK"' EXIT

GITHUB_KEYS_USER="tester"
GITHUB_KEYS_BEGIN="# >>> dotfiles-fedora: chaves de dispositivos (GitHub) >>>"
GITHUB_KEYS_END="# <<< dotfiles-fedora: chaves de dispositivos (GitHub) <<<"
YELLOW=""; GREEN=""; BLUE=""; NC=""

# Chaves de dispositivo: vivem SÓ no feed, nunca no .ssh da máquina.
for n in macbook iphone tablet; do
  ssh-keygen -q -t ed25519 -N "" -C "$n" -f "$DK/$n" >/dev/null 2>&1
done
# A chave da própria máquina: a única que vai para o .ssh.
ssh-keygen -q -t ed25519 -N "" -C "servidor" -f "$DK/self" >/dev/null 2>&1
# Uma chave local que o GitHub não conhece — o caso que impede o lockout.
ssh-keygen -q -t ed25519 -N "" -C "fora" -f "$DK/fora" >/dev/null 2>&1

fp() { ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'; }

curl() {
  local out=""
  while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
  [ -s "$DK/feed" ] || return 22
  cp "$DK/feed" "$out"
}

eval "$(awk '/^sync_device_keys_from_github\(\) \{/,/^\}$/' \
  "$REPO/setup.sh")"

HOME_FALSO="$DK/home"
reset_home() {
  rm -rf "$HOME_FALSO"
  mkdir -p "$HOME_FALSO/.ssh"
  cp "$DK/self.pub" "$HOME_FALSO/.ssh/"      # só a chave da máquina
  chmod 700 "$HOME_FALSO/.ssh"; chmod 600 "$HOME_FALSO/.ssh/self.pub"
}
feed_com() { : > "$DK/feed"; local a; for a in "$@"; do cat "$DK/$a" >> "$DK/feed"; done; }
ak() { echo "$HOME_FALSO/.ssh/authorized_keys"; }
run() { ( export HOME="$HOME_FALSO"; sync_device_keys_from_github 2>&1 | sed 's/^/    /' ); }
chaves_no_bloco() { [ -f "$(ak)" ] && grep -cE '^(ssh-|ecdsa-|sk-)' "$(ak)" || echo 0; }
tem() { [ -f "$(ak)" ] && grep -qF "$(awk '{print $2}' "$DK/$1.pub")" "$(ak)"; }

falhas=0
checar() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FALHA %s: esperado %s, obtido %s\n' "$1" "$3" "$2"; falhas=$((falhas+1)); fi; }

echo "== fixtures =="
for n in macbook iphone tablet self fora; do printf '  %-8s %s\n' "$n" "$(fp "$DK/$n.pub")"; done
echo

echo "== 1. primeira execucao, feed com 3 dispositivos + a chave do servidor =="
reset_home; feed_com macbook.pub iphone.pub tablet.pub self.pub
run
checar "as 3 chaves de dispositivo entraram"   "$(tem macbook && tem iphone && tem tablet && echo sim || echo nao)" "sim"
checar "a chave do servidor NAO entrou"        "$(tem self && echo entrou || echo nao)" "nao"
checar "3 chaves no bloco"                     "$(chaves_no_bloco)" "3"
checar "modo 600"                              "$(stat -c %a "$(ak)")" "600"
checar ".ssh 700"                              "$(stat -c %a "$HOME_FALSO/.ssh")" "700"
echo

echo "== 2. segunda execucao, mesmo feed: idempotente =="
antes=$(md5sum "$(ak)" | cut -d' ' -f1); mt=$(stat -c %Y "$(ak)")
# O `sleep` existe so para o arquivo poder ter um mtime DIFERENTE do que tinha, se
# o script o reescrever. E um segundo inteiro nao garante isso: a virada de segundo
# acontece na grade, e `sleep 1` pode sair no mesmo segundo em que entrou.
# Medido neste host e num container: `sleep 1.2` deu delta=0 nos DOIS.
#
# Entao o teste espera ate o segundo virar DE FATO, e so entao roda:
#
#     while [ "$(stat -c %Y AGORA)" = "$mt" ]; do sleep 0.2; ...; done
#
# Sem isso o check de mtime mede a grade de segundos, e nao o script: um run
# perfeitamente idempotente pode ser acusado de ter reescrito o arquivo. Era o
# que acontecia, com `sleep 1` — e a falha era do teste.
_agora="$(date +%s)"
_t=0
while [ "$_agora" = "$mt" ] && [ "$_t" -lt 25 ]; do
    sleep 0.2
    _agora="$(date +%s)"
    _t=$((_t + 1))
done
run >/dev/null
checar "conteudo nao mudou"   "$antes"          "$(md5sum "$(ak)" | cut -d' ' -f1)"
checar "mtime nao mudou"      "$mt"             "$(stat -c %Y "$(ak)")"
checar "3 chaves no bloco"    "$(chaves_no_bloco)" "3"
echo

echo "== 3. revogacao: o iPhone sai do GitHub =="
antes_tem=$(tem iphone && echo sim || echo nao)
feed_com macbook.pub tablet.pub self.pub
out=$(run); depois_tem=$(tem iphone && echo sim || echo nao)
checar "antes: iPhone estava"        "$antes_tem" "sim"
checar "depois: iPhone saiu"         "$depois_tem" "nao"
checar "2 chaves no bloco"           "$(chaves_no_bloco)" "2"
checar "o revogado foi reportado"    "$(printf '%s' "$out" | grep -q 'Revogadas agora' && echo sim || echo nao)" "sim"
echo "  revogadas reportadas: $(printf '%s' "$out" | grep -A2 'Revogadas' | sed 's/^/    /' | tr -d '\n' | cut -c1-120)"
echo

echo "== 4. revogacao de varias chaves de uma vez =="
reset_home; feed_com macbook.pub iphone.pub tablet.pub self.pub
run >/dev/null
checar "partiu de 3 no bloco" "$(chaves_no_bloco)" "3"
feed_com macbook.pub self.pub            # iphone e tablet sairam do GitHub
out=$(run)
checar "1 chave no bloco"                "$(chaves_no_bloco)" "1"
checar "o macbook continua"              "$(tem macbook && echo sim || echo nao)" "sim"
checar "iphone saiu"                     "$(tem iphone && echo nao || echo sim)" "sim"
checar "tablet saiu"                     "$(tem tablet && echo nao || echo sim)" "sim"
nrev=$(printf '%s' "$out" | grep -c 'SHA256:')
checar "as 2 revogadas foram reportadas" "$nrev" "2"
echo "  revogadas: $(printf '%s' "$out" | grep 'SHA256:' | sed 's/^ *//' | tr '\n' ' ' | cut -c1-100)"
echo

echo "== 5. uma chave FORA do bloco, que o GitHub nao conhece =="
reset_home; feed_com macbook.pub self.pub
run >/dev/null
cat "$DK/fora.pub" >> "$(ak)"        # chave que o GitHub nunca vai devolver
antes=$(md5sum "$(ak)" | cut -d' ' -f1)
feed_com macbook.pub tablet.pub self.pub   # e o GitHub mudou o que devolve
run >/dev/null
checar "a chave fora do GitHub sobreviveu" "$(tem fora && echo sim || echo nao)" "sim"
checar "o macbook continua"               "$(tem macbook && echo sim || echo nao)" "sim"
checar "o tablet novo entrou"             "$(tem tablet && echo sim || echo nao)" "sim"
checar "o arquivo mudou (block reescrito)" "sim" "$([ "$antes" = "$(md5sum "$(ak)" | cut -d' ' -f1)" ] && echo nao || echo sim)"
echo

echo "== 6. feed invalido: 404 em html =="
antes=$(md5sum "$(ak)" | cut -d' ' -f1)
printf '<html><body>404</body></html>\n' > "$DK/feed"
out=$(run)
checar "arquivo intacto"        "$antes" "$(md5sum "$(ak)" | cut -d' ' -f1)"
checar "avisa que nao tocou"    "$(printf '%s' "$out" | grep -q 'não foi tocado' && echo sim || echo nao)" "sim"
echo

echo "== 7. feed vazio (falha de rede) =="
: > "$DK/feed"
antes=$(md5sum "$(ak)" | cut -d' ' -f1)
out=$(run)
checar "arquivo intacto"        "$antes" "$(md5sum "$(ak)" | cut -d' ' -f1)"
checar "avisa que nao tocou"    "$(printf '%s' "$out" | grep -q 'não foi tocado' && echo sim || echo nao)" "sim"
echo

echo "== 8. feed so com a chave da propria maquina: nao esvazia o bloco =="
cp "$DK/self.pub" "$DK/feed"
antes=$(md5sum "$(ak)" | cut -d' ' -f1)
out=$(run)
checar "arquivo intacto"        "$antes" "$(md5sum "$(ak)" | cut -d' ' -f1)"
checar "avisa que nao ha o que fazer" "$(printf '%s' "$out" | grep -q 'própria máquina' && echo sim || echo nao)" "sim"
echo

echo "== 9. authorized_keys inexistente: cria do zero =="
rm -f "$(ak)"
feed_com macbook.pub self.pub
run >/dev/null
checar "criou o arquivo"    "$([ -f "$(ak)" ] && echo sim || echo nao)" "sim"
checar "1 chave de dispositivo" "$(chaves_no_bloco)" "1"
checar "modo 600"           "$(stat -c %a "$(ak)")" "600"
echo

echo "== 10. nenhum aviso do restorecon vaza para a saida =="
reset_home; feed_com macbook.pub self.pub
saida=$(run)
nwarn=$(printf '%s' "$saida" | grep -ci 'warning')
checar "sem 'Warning' na saida (encontrados: $nwarn)" "$nwarn" "0"

echo
if [ "$falhas" -eq 0 ]; then echo "DEVICE-KEYS: todas as checagens ok"
else echo "DEVICE-KEYS: $falhas falha(s)"; exit 1; fi
