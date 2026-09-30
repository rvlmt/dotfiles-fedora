#!/usr/bin/env bash
# Testa setup_opencode_service e setup_opencode_serve contra os estados que o
# instalador e o Tailscale podem deixar. HOME falso, systemctl e tailscale
# stubados: nada toca no host.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
S="$(mktemp -d "${TMPDIR:-/tmp}/serve-test.XXXXXX")"
rm -rf "$S"; mkdir -p "$S/home/.config/systemd/user" "$S/fakebin"

sed -n '/^setup_opencode_serve()/,/^}/p' "$REPO/setup.sh" > "$S/serve.sh"
sed -n '/^setup_opencode_service()/,/^}/p' "$REPO/setup.sh" > "$S/unit.sh"

printf '#!/bin/sh\necho "systemctl $*" >> "%s/systemctl.log"\n' "$S" > "$S/fakebin/systemctl"

# tailscale stub: TS_STATUS é a config atual; TS_FAIL força falha do serve.
cat > "$S/fakebin/tailscale" <<'EOF'
#!/bin/sh
[ -n "$TS_LOG" ] && echo "$*" >> "$TS_LOG"
if [ "$1" = "status" ] && [ "$2" != "--json" ]; then
  [ "$TS_DOWN" = "1" ] && exit 1
  exit 0
fi
if [ "$1" = "serve" ] && [ "$2" = "status" ]; then
  [ -f "$TS_STATE" ] && cat "$TS_STATE"
  exit 0
fi
if [ "$1" = "serve" ]; then
  [ "$TS_FAIL" = "1" ] && { echo "denied" >&2; exit 1; }
  printf '%s' "$TS_AFTER" > "$TS_STATE"
  exit 0
fi
exit 0
EOF
chmod +x "$S/fakebin/systemctl" "$S/fakebin/tailscale"
# sudo precisa executar de verdade: um stub /bin/true engoliria a chamada e
# faria o caminho de sucesso parecer funcionando.
printf '#!/bin/sh\nexec "$@"\n' > "$S/fakebin/sudo"
chmod +x "$S/fakebin/sudo"

falhas=0
# check <rótulo> <obtido> <esperado>
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FALHA %s (esperado=%q obtido=%q)\n' "$1" "$3" "$2"; falhas=1; fi; }
# conta ocorrencias num log; 0 se o log nao existir. Nao usa `|| echo 0`
# porque grep -c imprime 0 E sai != 0 quando nao casa, o que duplicaria a linha.
nlog() {
    local n=""
    [ -f "$1" ] && n="$(grep -c -- "$2" "$1" 2>/dev/null)"
    printf '%s' "${n:-0}"
}

D="$S/home/.config/systemd/user/opencode.service.d/10-bind.conf"
SERVE_LOOPBACK='|-- proxy https://127.0.0.1:49374/
|   tcp 127.0.0.1:49374'
SERVE_OUTRO='|-- proxy https://127.0.0.1:9999/
|   tcp 127.0.0.1:9999'

echo "== A. unit: instalador deixou 0.0.0.0, pin manda loopback =="
printf '[Unit]\nDescription=x\n\n[Service]\nType=simple\nExecStart=/bin/opencode serve --service --hostname 0.0.0.0 --port 49374\nRestart=on-failure\n' \
    > "$S/home/.config/systemd/user/opencode.service"
HOME="$S/home" PATH="$S/fakebin:$PATH" OPENCODE_BIND="127.0.0.1" OPENCODE_PORT="49374" OPENCODE_SERVE_PORT="443" OPENCODE_SERVE_PATH="/opencode" \
    bash -c "source '$S/unit.sh'; setup_opencode_service" >/dev/null 2>&1
check "reescreveu para loopback" "$(grep -c -- '--hostname 127.0.0.1 --port 49374' "$D")" "1"
check "preservou --service" "$(grep -c -- 'serve --service' "$D")" "1"

echo
echo "== B. serve: ja publicado, nao deve agir =="
L="$S/b.log"; : > "$L"; printf '%s' "$SERVE_LOOPBACK" > "$S/b.state"
out=$(HOME="$S/home" PATH="$S/fakebin:$PATH" TS_LOG="$L" TS_STATE="$S/b.state" TS_AFTER="$SERVE_LOOPBACK" \
      OPENCODE_BIND="127.0.0.1" OPENCODE_PORT="49374" OPENCODE_SERVE_PORT="443" OPENCODE_SERVE_PATH="/opencode" \
      bash -c "source '$S/serve.sh'; setup_opencode_serve" 2>&1); rc=$?
check "reporta ja publicado" "$(printf '%s' "$out" | grep -c 'já publicado')" "1"
check "nao chamou serve --bg" "$(nlog "$L" 'serve --bg')" "0"
check "retornou 0" "$rc" "0"

echo
echo "== C. serve: sem config, deve publicar e revalidar =="
L="$S/c.log"; : > "$L"
out=$(HOME="$S/home" PATH="$S/fakebin:$PATH" TS_LOG="$L" TS_STATE="$S/c.state" TS_AFTER="$SERVE_LOOPBACK" \
      OPENCODE_BIND="127.0.0.1" OPENCODE_PORT="49374" OPENCODE_SERVE_PORT="443" OPENCODE_SERVE_PATH="/opencode" \
      bash -c "source '$S/serve.sh'; setup_opencode_serve" 2>&1); rc=$?
check "publicou" "$(printf '%s' "$out" | grep -c 'publicado na tailnet')" "1"
check "usou --https=443" "$(nlog "$L" -- '--https=443')" "1"
check "alvo era loopback" "$(nlog "$L" 'http://127.0.0.1:49374')" "1"
check "revalidou e entrou no modo loopback" "$(printf '%s' "$out" | grep -c 'tcp 127.0.0.1:49374')" "1"
check "retornou 0" "$rc" "0"

echo
echo "== D. serve: outro servico publicado, nao pode sobrescrever =="
L="$S/d.log"; : > "$L"; printf '%s' "$SERVE_OUTRO" > "$S/d.state"
out=$(HOME="$S/home" PATH="$S/fakebin:$PATH" TS_LOG="$L" TS_STATE="$S/d.state" TS_AFTER="$SERVE_LOOPBACK" \
      OPENCODE_BIND="127.0.0.1" OPENCODE_PORT="49374" OPENCODE_SERVE_PORT="443" OPENCODE_SERVE_PATH="/opencode" \
      bash -c "source '$S/serve.sh'; setup_opencode_serve" 2>&1); rc=$?
check "recusou" "$(printf '%s' "$out" | grep -c 'Não sobrescrevi')" "1"
check "nao chamou serve --bg" "$(nlog "$L" 'serve --bg')" "0"
check "retornou 1" "$rc" "1"

echo
echo "== E. serve: tailscale desconectado =="
out=$(HOME="$S/home" PATH="$S/fakebin:$PATH" TS_LOG="$S/e.log" TS_STATE="$S/e.state" TS_AFTER="$SERVE_LOOPBACK" TS_DOWN=1 \
      OPENCODE_BIND="127.0.0.1" OPENCODE_PORT="49374" OPENCODE_SERVE_PORT="443" OPENCODE_SERVE_PATH="/opencode" \
      bash -c "source '$S/serve.sh'; setup_opencode_serve" 2>&1); rc=$?
check "pulou com aviso" "$(printf '%s' "$out" | grep -c 'pulei a publicação')" "1"
check "retornou 1" "$rc" "1"

echo
echo "== F. serve: falha do tailscale serve, mostra o comando =="
L="$S/f.log"; : > "$L"
out=$(HOME="$S/home" PATH="$S/fakebin:$PATH" TS_LOG="$L" TS_STATE="$S/f.state" TS_AFTER="$SERVE_LOOPBACK" TS_FAIL=1 \
      OPENCODE_BIND="127.0.0.1" OPENCODE_PORT="49374" OPENCODE_SERVE_PORT="443" OPENCODE_SERVE_PATH="/opencode" \
      bash -c "source '$S/serve.sh'; setup_opencode_serve" 2>&1); rc=$?
check "mostra comando manual" "$(printf '%s' "$out" | grep -c 'tailscale serve --bg --https=443')" "1"
check "retornou 1" "$rc" "1"

echo
[ "$falhas" -eq 0 ] && echo "TODAS AS VERIFICACOES PASSARAM" || { echo "HOUVE FALHAS"; exit 1; }
