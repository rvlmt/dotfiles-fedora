#!/usr/bin/env bash
# Roda a suíte e diz o que passou, o que falhou.
#
# O runner é deliberadamente burro: chama cada teste, guarda o status de saída, e
# imprime. Ele não interpreta a saída de ninguém. A razão está no `tests/README.md`:
# quatro scripts que seemed testes foram deixados de fora justamente porque imprimiam
# observações e saíam com 0 sempre — e um runner que "entende" os testes é um runner
# que passa verde quando eles não deveriam.
#
# A ordem é a do custo: o que é instantâneo primeiro, o que abre pty por último. Uma
# suíte que leva dez minutos não é uma que se roda antes de commitar, e o valor de uma
# suíte está em ela rodar antes do commit.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
cd "$REPO"

# Instantâneos, e sem pty.
RAPIDOS="test-device-keys.sh"
# Abrem pty, e por isso demoram. O `profile-axis-test.sh` é o mais longo: ele roda o
# `setup.sh` de verdade dezenas de vezes.
LENTOS="structure-test.sh profile-axis-test.sh"

falhas=0
total=0
resumo=""

echo "== suíte, em $(pwd)"
echo "== pty: $([ -e /dev/ptmx ] && echo disponível || echo AUSENTE — os testes lentos vão falhar)"
echo

for f in $RAPIDOS $LENTOS; do
    [ -f "$TEST_DIR/$f" ] || { echo "  $f  AUSENTE"; continue; }
    total=$((total + 1))
    printf '  %-26s ' "$f"
    out="$(timeout 2400 bash "$TEST_DIR/$f" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        n="$(printf '%s\n' "$out" | grep -oE '[0-9]+ ok' | tail -1)"
        [ -n "$n" ] && n="$n checagens"
        echo "ok${n:+  ($n)}"
    else
        falhas=$((falhas + 1))
        echo "FALHOU (rc=$rc)"
        printf '%s\n' "$out" | grep -iE 'falha|error' | head -5 | sed 's/^/      /'
    fi
done

echo
if [ "$falhas" -eq 0 ]; then
    echo "SUÍTE: $total arquivo(s), todos ok"
else
    echo "SUÍTE: $total arquivo(s), $falhas com falha"
fi
[ "$falhas" -eq 0 ]
