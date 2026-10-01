#!/usr/bin/env bash
# Roda a suíte — e recusa fora de uma sandbox.
#
# ── Por que este guard existe ────────────────────────────────────────────────
#
# A suíte foi rodada no host de desenvolvimento, e o host tem `opencode.service` e
# `hermes-dashboard.service`: serviços de verdade, de uma pessoa. Dois dos scripts
# que entraram na suite fazem `systemctl --user stop` nesses servicos, e por isso
# foram deixados de fora (ver `tests/fora/LEIA-ME.md`).
#
# Mas "deixei de fora os dois piores" nao e uma garantia: e uma lembranca, e
# lembranca nao sobrevive a um agente novo, nem a um teste escrito daqui a seis
# meses. Um teste que quebra o sistema inteiro nao e um teste — e um ataque ao
# ambiente que o executa.
#
# Por isso o guard e ESTRUTURAL: sem sandbox detectada, o runner nao roda. Nao e um
# aviso, e nao e uma linha de comentario que alguem pode nao ler.
#
# A override existe porque "nao roda" sem saida e um beco: quem provisiona de fato
# numa VM descartavel precisa de um caminho. Ela e explicita, avisa, e o nome diz o
# que ela e.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"

_dentro_de_sandbox() {
    [ -e /run/.containerenv ] && return 0        # podman
    [ -e /.dockerenv ] && return 0               # docker
    case "$(systemd-detect-virt 2>/dev/null)" in
        podman | docker | lxc | qemu | kvm | libvirt | rkt | systemd-nspawn) return 0 ;;
    esac
    return 1
}

if ! _dentro_de_sandbox; then
    {
        echo
        echo "  SUITE RECUSADA: esta maquina nao e uma sandbox."
        echo
        printf '  host:    %s\n' "$(hostname)"
        printf '  chassis: %s\n' "$(hostnamectl status 2>/dev/null | sed -n 's/.*Chassis: *//p' | cut -c1-24)"
        printf '  IPs:     %s\n' "$(ip -4 -o addr show scope global 2>/dev/null | awk '{printf "%s ", $4}')"
        echo
        echo "  A suite executa o setup.sh de verdade. Ela precisa de um ambiente"
        echo "  descartavel porque alguns scripts de teste usam systemctl --user em"
        echo "  servicos reais, e numa maquina de trabalho isso para o que a pessoa"
        echo "  esta usando."
        echo
        echo "  Como rodar, em ordem de preferencia:"
        echo
        echo "    1. num container, com o repo montado:"
        echo "         podman run --rm -it -v \"$REPO:/repo:Z\" -w /repo \\"
        echo "             docker.io/library/fedora:44 ./tests/run.sh"
        echo
        echo "    2. numa VM descartavel, como a de agentes."
        echo
        echo "    3. se for uma VM descartavel mesmo, e voce aceita o risco:"
        echo "         FD_TESTS_UNSAFE=1 ./tests/run.sh"
        echo
        echo "  A opcao 3 existe para nao ser um beco, e ela avisa. Ela nao e o"
        echo "  caminho padrao, e nunca deve ser o caminho de uma maquina de trabalho."
        echo
    } >&2
    exit 2
fi

if [ "${FD_TESTS_UNSAFE:-0}" = "1" ]; then
    echo "== AVISO: override de sandbox ativa. Confirme que esta maquina e descartavel. =="
fi

cd "$REPO"
# ── O runner ────────────────────────────────────────────────────────────────
#
# Deliberadamente burro: chama cada teste, guarda o status de saída, imprime. Não
# interpreta a saída de ninguém. Um runner que "entende" os testes é um runner
# que fica verde quando eles não deveriam — e foi isso que aconteceu com os
# scripts que ficaram em `tests/fora/`.
#
# A ordem é a do custo: o que é instantâneo primeiro, o que abre pty por último.
# Uma suíte que leva dez minutos não é uma que se roda antes de commitar.

# Instantâneos, e sem pty.
RAPIDOS="test-device-keys.sh"
# Abrem pty, e por isso demoram. O `profile-axis-test.sh` é o mais longo: roda o
# `setup.sh` de verdade dezenas de vezes.
LENTOS="structure-test.sh lib/teste-montagem-pipe.py profile-axis-test.sh"

falhas=0
total=0

echo "== suíte, em $(pwd) (sandbox: $(systemd-detect-virt 2>/dev/null || echo container))"
echo "== pty: $([ -e /dev/ptmx ] && echo disponível || echo AUSENTE — os testes lentos vão falhar)"
echo

for f in $RAPIDOS $LENTOS; do
    [ -f "$TEST_DIR/$f" ] || { echo "  $f  AUSENTE"; continue; }
    total=$((total + 1))
    printf '  %-26s ' "$f"
    # O interpretador segue o tipo do arquivo. A lista e heterogenea de proposito
    # — o teste da montagem e python porque extrair funcao de um script bash sem
    # escaping e mais seguro em python, e forcar `bash` num .py daria um erro de
    # sintaxe que parece o script estar quebrado.
    case "$f" in
        *.py) _int=python3 ;;
        *)    _int=bash ;;
    esac
    out="$(timeout 2400 "$_int" "$TEST_DIR/$f" 2>&1)"
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
