#!/usr/bin/env bash
# Testa setup_opencode_service contra as duas variantes de unit que o instalador
# pode deixar, com HOME falso e systemctl stubado. Nada toca no host real.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
S="$(mktemp -d "${TMPDIR:-/tmp}/own-opencode-test.XXXXXX")"
rm -rf "$S"; mkdir -p "$S/home/.config/systemd/user" "$S/fakebin"

sed -n '/^setup_opencode_service()/,/^}/p' "$REPO/setup.sh" > "$S/func.sh"
printf '#!/bin/sh\necho "systemctl $*" >> "%s/systemctl.log"\n' "$S" > "$S/fakebin/systemctl"
chmod +x "$S/fakebin/systemctl"

# Unit no estado que o instalador deixa: loopback.
UNIT_LOOPBACK='[Unit]
Description=OpenCode shared background server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=PATH=/usr/bin
ExecStart=/home/tester/.opencode/bin/opencode serve --service --hostname 127.0.0.1 --port 4096
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=default.target'

# Unit sem --hostname/--port, para o caminho de append.
UNIT_BARE='[Unit]
Description=OpenCode shared background server

[Service]
Type=simple
ExecStart=/home/tester/.opencode/bin/opencode serve --service

[Install]
WantedBy=default.target'

rodar() {
    HOME="$S/home" PATH="$S/fakebin:$PATH" \
    GREEN='' YELLOW='' NC='' \
    OPENCODE_BIND="0.0.0.0" OPENCODE_PORT="49374" \
    bash -c "source '$S/func.sh'; setup_opencode_service"
}

falhas=0
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FALHA %s (esperado=%q obtido=%q)\n' "$1" "$3" "$2"; falhas=1; fi; }
D="$S/home/.config/systemd/user/opencode.service.d/10-bind.conf"

echo "== cenario 1: instalador deixou em loopback =="
printf '%s\n' "$UNIT_LOOPBACK" > "$S/home/.config/systemd/user/opencode.service"
rodar >/dev/null
check "reescreveu --hostname" "1" "$(grep -c 'ExecStart=/home/tester/.opencode/bin/opencode serve --service --hostname 0.0.0.0 --port 49374' "$D")"
check "resetou ExecStart antes" "1" "$(grep -c '^ExecStart=$' "$D")"
check "nao tocou nas outras diretivas" "0" "$(grep -cE 'Restart|TimeoutStopSec|Environment' "$D")"
echo "  -- 2a execucao (idempotencia)"
rodar | sed 's/^/    /'
check "drop-in: um ExecStart real, alem do reset" "1" "$(grep -cE '^ExecStart=.+' "$D")"
check "daemon-reload so na 1a" "1" "$(grep -c daemon-reload "$S/systemctl.log")"

echo
echo "== cenario 2: unit sem --hostname nem --port =="
printf '%s\n' "$UNIT_BARE" > "$S/home/.config/systemd/user/opencode.service"
rm -f "$D"
rodar >/dev/null
check "acrescentou as duas flags" "1" "$(grep -c 'serve --service --hostname 0.0.0.0 --port 49374' "$D")"

echo
echo "== cenario 3: unit ausente =="
rm -f "$S/home/.config/systemd/user/opencode.service" "$D"
out=$(rodar); check "nao faz nada e nao reclama" "" "$out"

echo
echo "== cenario 4: ExecStart ilegivel =="
printf '[Unit]\nDescription=x\n\n[Service]\nType=simple\n' > "$S/home/.config/systemd/user/opencode.service"
out=$(rodar 2>&1); check "avisa e retorna erro" "1" "$?"

echo
[ "$falhas" -eq 0 ] && echo "TODAS AS VERIFICACOES PASSARAM" || { echo "HOUVE FALHAS"; exit 1; }
