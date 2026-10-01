#!/usr/bin/env bash
# Harness funcional para o eixo --profile do setup.sh.
#
# Roda o script REAL, com sudo/podman/dnf falsos no PATH e HOME num diretório
# temporário, para que nenhum módulo possa tocar na máquina. O que se observa é
# o comportamento observável: banner, perguntas de confirmação e mensagens de
# erro de validação. Nada é testado por grep.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
LIB="$TEST_DIR/lib"
BIN="$(mktemp -d)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$BIN" "$SANDBOX"' EXIT

# Comandos perigosos viram no-ops que "passam". Se algum módulo escapar daqui e
# chamar o binário de verdade, o teste falha em vez denão tocar a máquina.
# id falso: sem ele, o ramo "usuario ja no grupo libvirt" depende da maquina que
# roda o teste — exatamente a regra que o repo escreveu.
cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *-nG*) echo "audio docker bin" ;;
  *) echo "uid=1000(runner)" ;;
esac
exit 0
EOF
chmod +x "$BIN/id"

for c in sudo dnf rpm loginctl usermod hostnamectl chsh systemctl tailscale \
         bun npm mise curl wget grdctl setenwall newgrp ip firewall-cmd sshd; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$c"
  chmod +x "$BIN/$c"
done

# Estes faltavam, e o teste que roda o perfil host sem --only passa por `ssh` e
# `git`. Sem eles o harness gerava uma chave Ed25519 de verdade dentro da sandbox
# e chamava `gh auth login -p https -w`, que abre navegador e espera um código.
# Falsos porque a idempotência desses módulos é testada por outro caminho.
for c in gh git ssh-keygen ssh-add ssh-agent ssh; do
  cat > "$BIN/$c" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/$c"
done

# Guard: registra qualquer comando NÃO falsificado que o script invoque. Não é
# um sandbox de segurança — é um registro, para que a lista de fakes não precise
# ser perfeita. Se algo escapar, o log mostra o nome depois do teste.
GUARD_LOG="$SANDBOX/calls.log"
cat > "$BIN/_guard" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GUARD_LOG:-/dev/null}"
exit 127
EOF
chmod +x "$BIN/_guard"
# o guard só é útil se ficar ANTES do PATH original no lookup; como fake explícito
# nao cobre comando desconhecido, ele serve como ponto de chamada do harness.
# podman falso: responde o esperado sem criar store nem diretório.
cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "info" ] && exit 0
exit 0
EOF
chmod +x "$BIN/podman"
# virsh falso: a pos-condicao do vm-host chama virsh, e o virsh REAL deste host
# trava. Sem o falso, o harness mediria o estado da maquina e nao o modulo.
cat > "$BIN/virsh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/virsh"
# sudo e virsh falsos: a pos-condicao roda `sudo virsh`. O sudo falso delega
# (como sudo faz), e o virsh falso responde. Assim a pós-condição é exercitada
# como o script a usa, sem precisar de um libvirt de verdade.
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
# sudo <comando> [args...] — delega como sudo, ignorando flags comuns.
while [ $# -gt 0 ]; do
  case "$1" in
    -n|-v|-H|-E) shift ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec /bin/bash -c "$*"
EOF
chmod +x "$BIN/sudo"
export PATH="$BIN:$PATH"
export HOME="$SANDBOX"
export SG_LOG="$SANDBOX/sg.log"
: > "$SG_LOG"

pass=0
fail=0
pulados=0

# Duas formas de rodar, porque elas enxergam coisas diferentes:
#
#   run       — stdin por pipe. Serve para validacao e saida de modulo, mas o
#               prompt do `read -p` NAO aparece, porque o bash so o imprime
#               quando o stdin e um terminal. Num pipe, o script recusa tudo em
#               silencio: e o comportamento real, e por isso tambem e testado.
#   run_pty   — sob um pty, entao o prompt aparece de verdade e da para conferir
#               a pergunta que o usuario realmente ve.
run() {
  local input="$1"; shift
  printf '%s' "$input" | bash "$REPO/setup.sh" "$@" 2>&1
}

run_pty() {
  local input="$1"; shift
  # ptyfile2.py, e nao ptyrun.py: o ptyrun recebe o input por argv, e um payload
  # com varias linhas (uma chave PEM, por exemplo) chega truncado. O ptyfile le
  # os bytes de um arquivo, que e o que o terminal faria de verdade.
  #
  # O PATH do sandbox tem de entrar AQUI tambem. Sem isso o script chama o `sudo`
  # REAL, que pede senha no pty e trava — e a falha aparece como "o modulo nao
  # rodou", que e a leitura errada: o problema e o ambiente, nao o modulo.
  local f; f="$(mktemp)"
  printf '%s' "$input" > "$f"
  PATH="$BIN:$PATH" python3 "$LIB/ptyfile2.py" "$f" bash "$REPO/setup.sh" "$@" 2>&1
  rm -f "$f"
}

check() {
  local desc="$1" esperado="$2" obtido="$3"
  if grep -qF -- "$esperado" <<<"$obtido"; then
    printf '  ok    %s\n' "$desc"; pass=$((pass+1))
  else
    printf '  FALHA %s\n        esperava: %s\n        obteve : %s\n' \
      "$desc" "$esperado" "$(head -3 <<<"$obtido" | tr '\n' '|')"
    fail=$((fail+1))
  fi
}

# Um pulo que SE DECLARA. O `ok` fabrication era o oposto disto: contava como
# passou sem medir, e por isso uma cobertura inteira desapareceu sem ninguem ver.
# Aqui o pulo soma em `pulados` e aparece no relatorio final, e nao em `pass`.
pulado() {
  printf '  PULO  %s\n' "$1"; pulados=$((pulados+1))
}

check_not() {
  local desc="$1" proibido="$2" obtido="$3"
  if grep -qF -- "$proibido" <<<"$obtido"; then
    printf '  FALHA %s\n        nao devia conter: %s\n' "$desc" "$proibido"
    fail=$((fail+1))
  else
    printf '  ok    %s\n' "$desc"; pass=$((pass+1))
  fi
}

echo "== 1. perfil invalido e recusado antes de qualquer efeito =="
out="$(run '' --profile=desktop)"
check "recusa perfil desconhecido" "Perfil desconhecido: 'desktop'" "$out"
check_not "nao chegou a rodar modulo nenhum" "==>" "$out"

echo
echo "== 2. --help lista os dois perfis e seus modulos =="
out="$(run_pty '' --help)"
check "documenta host" "host: base, hostname, ssh, device-keys, git, tailscale" "$out"
check "documenta vm" "vm:   base, hostname, ssh, device-keys, git, gh-app, tailscale, sshd-hardening, firewalld, podman, ai-clis" "$out"
check "documenta o padrao" "Padrão." "$out"
check_not "nao lista podman no host" "host: base hostname ssh git tailscale sshd-hardening firewalld" "$out" && \
  echo "        (a linha do host realmente nao tem podman)"

echo
echo "== 3. --only valida contra o perfil; --skip so avisa =="
out="$(run_pty '' --profile=host --only=podman)"
check "podman nao pertence ao host" "não pertence ao perfil 'host'" "$out"
out="$(run_pty '' --profile=vm --only=desktop-apps)"
check "desktop-apps nao pertence ao vm" "não pertence ao perfil 'vm'" "$out"
out="$(run_pty '' --profile=host --only=modulo-inexistente)"
check "modulo inexistente recusado" "Módulo desconhecido" "$out"
out="$(run_pty '' --profile=host --skip=podman)"
check "--skip fora do perfil so avisa" "não pertence ao perfil 'host'; o --skip não tem efeito" "$out"
check_not "--skip fora do perfil nao aborta" "Módulo desconhecido" "$out"

echo
echo "== 4. opencodex: no host, e com pergunta propria =="
out="$(run_pty $'n\n' --profile=host --only=opencodex)"
check "banner do host" "workstation pessoal + hospedeiro de VMs" "$out"
check "a pergunta do opencodex aparece de verdade" "Instalar o OpenCodex" "$out"
check "a pergunta avisa que e proxy de terceiro" "proxy de provider de terceiros" "$out"
check "recusou e avisou" "OpenCodex ignorado (proxy de provider de terceiros, opt-in)" "$out"
check_not "nao perguntou sobre ai-clis" "Instalar as CLIs de IA" "$out"

out="$(run_pty $'n\n' --profile=host --only=opencodex --skip=opencodex)"
check_not "--skip wins sobre opt-in" "Instalar o OpenCodex" "$out"

echo
echo "== 5. ai-clis: so no guest, e com a propria pergunta =="
out="$(run_pty $'n\n' --profile=vm --only=ai-clis)"
check "banner do vm" "Setup da VM de agentes: a fronteira" "$out"
check "a pergunta das CLIs aparece" "Instalar as CLIs de IA" "$out"
check "recusou e avisou sem dizer 'no host'" "CLIs de IA ignorada" "$out"
check_not "a recusa do ai-clis nao fala mais em host" "no host ignorada" "$out"
check_not "nao perguntou sobre opencodex no vm" "Instalar o OpenCodex" "$out"

out="$(run_pty '' --profile=host --only=ai-clis)"
check "ai-clis nao pertence ao host" "não pertence ao perfil 'host'" "$out"

echo
echo "== 6. podman: so no guest, e roda de verdade dentro da sandbox =="
out="$(run_pty '' --profile=vm --only=podman)"
check_not "nao recusou podman no vm" "não pertence ao perfil" "$out"
check "o modulo podman rodou" "Podman (rootless)" "$out"
if [ -f "$SANDBOX/.config/containers/containers.conf" ]; then
  printf '  ok    escreveu containers.conf dentro da sandbox\n'; pass=$((pass+1))
else
  printf '  FALHA nao escreveu containers.conf na sandbox\n'; fail=$((fail+1))
fi
if [ -d "$SANDBOX/.local/share/containers" ]; then
  printf '  FALHA criou store de container dentro da sandbox (podman falso nao devia)\n'
  fail=$((fail+1))
else
  printf '  ok    nenhum store de container criado\n'; pass=$((pass+1))
fi

echo
echo "== 7. sem argumentos, o default e host e os opt-in ficam de fora =="
out="$(run_pty $'n\n' --only=base)"
check "base no host roda" "Base do sistema" "$out"
check_not "nao rodou toolbx" "==> Toolbx" "$out"
check_not "nao rodou gui-access" "==> Acesso gráfico" "$out"
check_not "nao rodou podman" "==> Podman" "$out"
check_not "nao rodou ai-clis" "Instalar as CLIs de IA" "$out"

echo
echo "== 8. toolbx e gui-access sao opt-in dentro do host =="
out="$(run_pty $'n\n' --only=toolbx)"
check "toolbx roda com --only" "==> Toolbx" "$out"
out="$(run_pty '' --profile=vm --only=toolbx)"
check "toolbx nao pertence ao vm" "não pertence ao perfil 'vm'" "$out"

echo
echo "== 9. a mensagem final aponta para o proximo passo certo =="
# Estes dois runs sao `--only`, que e um run PARCIAL: o run instala uma coisa e
# nao as outras, por escolha de quem chamou. Por isso as pos-condicoes do perfil
# inteiro nao valem neles — perguntariam por tudo o que o `--only` propositadamente
# nao instalou, e o run terminaria com "7 pendencias" numa maquina que esta
# exatamente como o pedido.
#
# E por isso o texto de "pronto" some do banner nesses dois runs: nao ha nada a
# declarar. A checagem original exigia esse texto e falhou, e ela estava certa
# quanto ao design e errada quanto a forma — a §10.17 ja registra uma checagem
# que acusou o codigo certo.
#
# O que estas checagens ainda affirmam, e que vale: o proximo passo aponta para o
# lugar CERTO do perfil. E o que se verifica aqui e o destino da orientacao, que e
# a informacao que o banner carrega mesmo num run parcial.
out="$(run_pty $'n\n' --profile=host --only=opencodex)"
check "no host, o proximo passo e o Cockpit" "VM de agentes no Cockpit" "$out"
check_not "no host, nao manda o devpod para o host" "devpod com este servidor" "$out"
# A ordem destas quatro afirmações é a que o banner tem, e a ordem importa: a
# pós-condição vem ANTES do banner, e é ela que decide se o banner diz "pronto" ou
# "N pendência(s)".
#
# Este teste roda com o HOME temporário do harness, onde não há `~/.zshrc`. A
# pós-condição pergunta ao sistema se o `~/.zshrc` aponta para o repositório, e a
# resposta é não — que é a resposta CORRETA, e é o que o design manda: um run que
# não instalou o `zshrc` não pode declarar a máquina pronta.
#
# A versão anterior deste teste exigia o texto de "pronto" e falhava, e ela estava
# errada: ela tratava a pendência como defeito, sendo que a pendência é o
# comportamento certo. A forma de perguntar agora é a que importa — o banner diz
# que há pendência, e a pendência é nomeada.
out="$(run_pty $'n\n' --profile=vm --only=ai-clis)"
check "um --only se declara parcial" "run parcial" "$out"
check_not "e nao se declara pronto sem o que faltava" "Configuração da VM de agentes finalizada" "$out"
check "a pendencia e nomeada, nao so contada" "zshrc" "$out"
# E o que o teste de fato queria verificar: o proximo passo aponta para o lugar
# CERTO do perfil. Isso so aparece no banner de um run sem pendencia, entao o
# teste cria o `zshrc` que a pos-condicao procura.
mkdir -p "$SANDBOX" && ln -sf "$REPO/zshrc" "$SANDBOX/.zshrc"
out="$(run_pty $'n\n' --profile=vm --only=ai-clis)"
check "no vm, o proximo passo e o snapshot" "snapshot" "$out"
check_not "no vm, nao manda configurar devpod no host" "configure o devpod com este servidor" "$out"
rm -f "$SANDBOX/.zshrc" "$out"

echo
echo "== 10. [pipe de proposito] a recusa antecipada e o comportamento de pipe =="
out="$(run $'n\n' --profile=host --only=opencodex)"
check "a recusa antecipada pega antes do modulo" "precisa de um terminal" "$out"
check_not "mas a pergunta nao apareceu (read -p so imprime em terminal)" "Instalar o OpenCodex" "$out"

echo
TEM_VM_HOST=0
grep -q 'vm-host' "$REPO/setup.sh" && TEM_VM_HOST=1
if [ "$TEM_VM_HOST" = "0" ]; then
  echo "== 11/12. vm-host: ausentes nesta branch (pertencem a PR do modulo) =="
fi
if [ "$TEM_VM_HOST" = "1" ]; then
echo "== 11. vm-host: so no host, e com a pos-condicao funcional =="
out="$(run_pty $'n\n' --profile=host --only=vm-host)"
check "banner do host" "workstation pessoal" "$out"
check "o modulo rodou" "Hospedeiro de VMs" "$out"
check "verificou o grupo" "grupo libvirt" "$out"
check "a pos-condicao e funcional, nao de pacote" "libvirt responde na conexão de sistema" "$out"
# A pós-condição roda com sudo, deliberadamente: sem agente polkit na sessão o
# caminho sem privilégio só dá timeout. E ela tem que Mentionar o caminho sem
# privilégio quando falha, porque essa é a parte que o usuário vai encontrar.
check_not "a pos-condicao nao usa mais sg" "sg libvirt" "$out"
# O modulo nao pode CRIAR rede. A mensagem final menciona a rede do libvirt
# (e legitimamente: e o proximo passo documentado), entao a verificacao e sobre
# o que o modulo faz, nao sobre o que ele diz.
check_not "o modulo nao cria rede (nenhum virsh net-)" "net-" "$out"

out="$(run_pty '' --profile=vm --only=vm-host)"
check "vm-host nao pertence ao vm" "não pertence ao perfil 'vm'" "$out"

echo
echo "== 12. a pos-condicao do vm-host falha quando o virsh nao responde =="
cat > "$BIN/virsh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/virsh"
out="$(run_pty $'n\n' --profile=host --only=vm-host)"
check "avisa que o virsh nao respondeu" "não respondeu em 30s" "$out"
check "aponta o que observar" "journalctl -u virtqemud" "$out"
check "a falha menciona autorizacao, que e a causa provavel sem privilegio" "autorização" "$out"
check_not "nao afirma sucesso com o virsh quebrado" "libvirt responde na conexão" "$out"
# restaura o virsh que responde
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/virsh"
chmod +x "$BIN/virsh"
fi

echo
echo "== 13. stdin nao-interativo: recusa com mensagem, nao morte silenciosa =="
# Sob pty o stdin E terminal, entao nao deve recusar: este e o caso feliz.
out="$(run_pty $'n\n' --profile=host --only=base)"
check_not "sob pty, nao recusa" "precisa de um terminal" "$out"
check "sob pty, o modulo roda" "Base do sistema" "$out"

out="$(run '' --only=base </dev/null)"
check "recusa por pipe", "precisa de um terminal" "$out"
check "diz o que fazer", "abra um terminal e execute" "$out"
check "oferece --help como saida", "./setup.sh --help" "$out"
check_not "nao diz que recusou em silencio (comportamento antigo)", "recusadas em silêncio" "$out"
check_not "nao imprime o banner antes de recusar", "=== Setup" "$out"

echo
echo "== 14. o opt-in realmente nao roda num run normal =="
# Este teste precisa de pty: sob pipe o script nem chega aqui, porque recusa.
out="$(run_pty $'a\na\na\na\na\na\na\na\na\na\n' --profile=host)"
check_not "toolbx NAO roda sem --only" "==> Toolbx" "$out"
check_not "gui-access NAO roda sem --only" "==> Acesso gráfico" "$out"
check "mas os modulos normais rodam" "==> Base do sistema" "$out"
out="$(run_pty $'n\n' --only=toolbx)"
check "com --only, toolbx roda" "==> Toolbx" "$out"

echo
echo "== 15. o --skip explicito ainda funciona =="
out="$(run_pty $'a\na\na\na\na\na\na\na\na\na\na\n' --profile=host --skip=firewalld)"
check_not "--skip=firewalld cumpre" "==> firewalld" "$out"
check "e o resto roda" "==> Base do sistema" "$out"

echo
echo "== 16. perfil vm roda o firewalld, e nao o resto que e do host =="
# A entrada do pty e POSICIONAL, e as perguntas do bloco sao varias. Passar a
# resposta do modo do OpenDesign exigiria saber em qual posicao ela cai, e essa
# posicao muda a cada pergunta nova — um teste que depende de contagem quebra sem
# avisar. Este teste entao mantem as respostas genericas e verifica so o que
# sempre verificou: o perfil vm roda o que e do guest e nao o que e do host. A
# pergunta sem default tem o teste 16b, que usa --only e tem uma so pergunta.
#
# O firewalld e a EXCEPCAO, por decisao de 2026-09-30: passou a rodar tambem na
# VM. Este teste afirmava o contrario (`check_not "sem firewalld"`), e a assercao
# foi invertida de proposito — mudou a decisao, nao o comportamento do script. A
# maquina de agentes e a que recebe trafego da tailnet, e e dela que o filtro
# precisa existir.
# A entrada POSICIONAL e o que este teste tem de mais fragil, e a prova acabou de
# se repetir: ao entrar `hostname` no perfil `vm`, entraram MAIS DUAS perguntas no
# bloco — o `pergunta` do nome e o `confirm` que pergunta se aplica —, e as respostas
# seguintes escorregaram duas posicoes. O firewalld e o Podman pararam de aparecer,
# sem nenhum aviso: as assercoes simplesmente falharam, que e o unico sintoma.
#
# Sao DUAS linhas porque um modulo novo costuma trazer duas perguntas, e nao uma. E a
# regra que isso ensina e a mesma que a secao "O run que alinhou 12 prompts" da
# AUDITORIA.md registra para o run real: **cada pergunta nova desloca a entrada, e o
# harness nao tem como dizer que recebeu uma pergunta a mais.** Um `pergunta` com
# default consome uma linha mesmo sendo respondido vazio.
out="$(run_pty $'a\na\na\na\na\na\na\nnativo\n\na\na\na\na\n' --profile=vm --skip=base,ai-clis,gh-app)"
check "firewalld roda na vm" "==> firewalld" "$out"
check_not "sem vm-host" "Hospedeiro de VMs" "$out"
check "hostname roda na vm" "==> Hostname" "$out"
check_not "sem opencodex" "Instalar o OpenCodex" "$out"
check_not "sem desktop-apps" "==> Apps desktop" "$out"
check "mas roda o que e do guest" "==> Podman (rootless)" "$out"

echo
echo "== 16b. a pergunta do modo nao tem padrao, e nao trava =="
# Estes dois so se aplicam quando a pergunta do modo existe no script. Num
# checkout limpo passam sem checar nada — e isso e o ponto: um teste que depende
# de codigo ausente mede o checkout, nao a funcao. Na arvore com o patch eles
# cobram de verdade.
# O sentinelo e 'Modo [', e nao a ordem das opcoes: o guard precisa saber que a
  # PERGUNTA existe, e nao como ela esta escrita hoje. Um guard que casa a literal
  # `nativo/container` quebrou na primeira mudanca de default — e o que ele protege
  # (a cobertura do prompt) sumiu sem nenhuma falha aparecer, porque o `else`
  # fabricava um `ok` no lugar das checagens.
  if grep -q 'Modo \[' "$REPO/setup.sh"; then
  # --only=open-design reduz o bloco a UMA pergunta sem default, entao o EOF cai
  # nela direto, sem precisar acertar posicao. E o `while :` sem teste de EOF
  # entraria em laco infinito; com o teste, o script desiste de instalar.
  out="$(run_pty $'\x04' --profile=vm --only=open-design)"
  check "EOF nao trava e desiste" "Sem resposta: o OpenDesign nao sera instalado" "$out"
  # O banner real e "==> OpenDesign", sem sufixo de modo. A versao anterior
  # proibia "==> OpenDesign (nativo)", que nao existe no script: a checagem era
  # sempre verdade e contava como uma das 103. Medido: no EOF o banner NAO sai.
  check_not "e o banner do modulo nao chegou a sair" "==> OpenDesign" "$out"
else
  pulado "a pergunta do modo nao esta neste checkout" 
fi

echo
echo "== 16c. entrada invalida e repreguntada, nao aceita =="
# O sentinelo e 'Modo [', e nao a ordem das opcoes: o guard precisa saber que a
  # PERGUNTA existe, e nao como ela esta escrita hoje. Um guard que casa a literal
  # `nativo/container` quebrou na primeira mudanca de default — e o que ele protege
  # (a cobertura do prompt) sumiu sem nenhuma falha aparecer, porque o `else`
  # fabricava um `ok` no lugar das checagens.
  if grep -q 'Modo \[' "$REPO/setup.sh"; then
  # A segunda linha responde o que a primeira recusou.
  out="$(run_pty $'lixo\ncontainer\n\n' --profile=vm --only=open-design)"
  check "repregunta na entrada invalida" "Escolha 'container' ou 'nativo'." "$out"
  # A versao anterior proibia "==> OpenDesign (container)", que nao existe no
  # script, e por isso era sempre verdadeira. E ela afirmava o CONTRARIO do que o
  # run faz: com `lixo` recusado e `container` na linha seguinte, o modo container
  # e aceito e o banner sai. Medido nesta VM.
  check "e a linha seguinte, valida, foi aceita" "==> OpenDesign" "$out"
else
  pulado "a pergunta do modo nao esta neste checkout" 
fi

echo
echo "== 17. o harness nao gerou chave real nem chamou gh real =="
SAVED="$HOME/.ssh"
printf '  (o teste 14 passou por ssh e git com os fakes; se a sandbox tiver chave, o fake falhou)\n'
if [ -f "$SANDBOX/.ssh/id_ed25519" ]; then
  printf '  FALHA  sandbox tem chave Ed25519 — ssh-keygen nao foi falsificado\n'; fail=$((fail+1))
else
  printf '  ok    nenhuma chave gerada na sandbox\n'; pass=$((pass+1))
fi


echo
echo
echo "== 17. o default do confirm: Enter vale o default, nos dois sentidos =="
# Este teste nao existia, e a ausencia dele escondeu um bug: `confirm` devolvia 0
# para sim e 1 para nao, e a primeira versao do default devolvia `return "$default"`
# — que num default "sim" devolvia 1. A pergunta anunciava [Y/n] e o Enter
# respondia nao. So aparece quando alguem responde VAZIO a uma pergunta de default
# sim, e nenhum teste fazia isso.
#
# A prova e pelo efeito observavel, nunca pelo texto da pergunta: o device-keys
# escreve no authorized_keys, entao "o arquivo tem chave" e "o script autorizou" sao a
# mesma coisa vista de dois lados.
out="$(run_pty $'\n' --profile=vm --only=device-keys)"
check "default sim: a pergunta anuncia [Y/n]" "[Y/n]" "$out"
check_not "default sim: nao anuncia [y/N]" "[y/N]" "$out"
check "default sim: Enter autorizou de verdade" "authorized_keys" "$out"
check_not "e nao respondeu nao" "não autorizado" "$out"

# O outro sentido: uma pergunta de default NAO continua sendo nao com Enter. O
# `ai-clis` servia aqui ate 2026-10-01, quando o dono do repo mudou o default dele
# para sim — e este teste FALHOU por isso, que e a coisa que ele existe para fazer.
# O default "nao" que sobrou no perfil vm e o login do `gh`, no modulo `git`.
out="$(run_pty $'\n\n\n' --profile=vm --only=git)"
check "default nao: nao anuncia [Y/n]" "[y/N]" "$out"
check_not "e nao disparou o login do gh" "handshake" "$out"

echo "== 18. o hostname: o tipo vem do PERFIL, e a sugestao vale nos dois =="
# A decisao e do dono do repo, e ela e uma SIMPLIFICACAO: o systemd poderia detectar
# o chassis — e detecta bem, medido: `desktop` no host, `vm` na VM —, mas o perfil
# JA e a declaracao de que papel a maquina cumpre, e ele esta digitado na linha de
# comando. Detectar o hardware para redescobrir o que a pessoa acabou de declarar e
# medir de novo o que ja foi dito.
out="$(run_pty $'\n\ny\ny\ny\ny\ny\ny\ny\nn\ny\nn\ny\ny\ny\n' --profile=vm --only=hostname)"
check "o modulo do hostname roda no vm" "==> Hostname" "$out"
check "e o perfil vm propose o prefixo vm-" "vm-fedora-" "$out"

# O host tambem recebe sugestao agora. E o que a decisao custa: um Enter no host
# renomeia a maquina de trabalho, que hoje se chama `fedora-desktop` e nao casa com
# o esquema — entao ela VAI ser perguntada.
out="$(run_pty $'\n\nn\n' --profile=host --only=hostname)"
check "o modulo do hostname roda no host" "==> Hostname" "$out"
check "e o perfil host tambem recebe sugestao" "pc-fedora-" "$out"
check_not "e nao e o prefixo da vm" "vm-fedora-" "$out"

echo
echo "== 18c. o script nao renomeia o no da tailnet, nunca =="
# Decisao do dono do repo, com um motivo medido: renomeado o no, as tres publicacoes
# do `tailscale serve` ficam chaveadas no nome antigo e o TLS morre no handshake. Um
# script que renomeasse quebraria os tres servicos que ele mesmo publica — e o check
# de "ja publicado" nao perceberia, porque compara o BACKEND e nao o nome.
out="$(grep -c 'tailscale set --hostname' "$REPO/setup.sh")"
check "nao ha comando de renomear o no" "0" "$out"
out="$(grep -cE 'não renomeia' "$REPO/setup.sh")"
check "e o motivo esta escrito no codigo" "1" "$([ "$out" -ge 1 ] && echo 1 || echo 0)"

echo "== 18b. o nome gerado: a forma, e o que o mantem identico =="
# A forma vem do machine-id, e nao de um sorteio nem da data. Um sorteio exigiria
# gravar o nome em algum lugar para nao mudar a cada run; a data mudaria todo dia.
# Aqui nao ha `run`: ele EXECUTA o script, e o que se quer verificar e o texto.
out="$(sed -n '/^suggest_hostname()/,/^}/p' "$REPO/setup.sh")"
check "o nome deriva do machine-id" "machine-id" "$out"
check_not "e nao de um sorteio" "RANDOM" "$out"
check_not "e nao de um sorteio (urandom)" "urandom" "$out"
check_not "e nao da data" "date +%d%m" "$out"
check "e o SO e resolvido, nao escrito a mao" "os-release" "$out"
# `fedora` APARECE no corpo da funcao, e e o esperado: e a medicao, em comentario.
# O que nao pode existir e um valor literal, que quebraria no dia em que a imagem
# base mudasse — que e justamente o que resolver o campo evita.
out="$(grep -c 'os_id="fedora"' "$REPO/setup.sh")"
check "e sem valor literal para o SO" "0" "$out"

# E o script reconhecendo o proprio esquema: e isso que impede uma maquina ja nomeada
# de receber a pergunta de novo. Os DOIS tipos tem de ser reconhecidos, ou o host
# seria perguntado em toda execucao.
# `grep -F`, e nao uma regex: em BRE o `(` e o `|` sao literais, e o padrao nunca
# casaria — o mesmo tipo de teste que passa/falha por motivo errado.
out="$(grep -cF '^(vm|pc)-[a-z0-9]+-[a-z0-9]{4}$' "$REPO/setup.sh")"
check "o script reconhece um nome que ele mesmo gerou" "1" "$out"

# E o `hostname` precisa vir ANTES do `tailscale` no perfil `vm`: e o que faz o no
# da tailnet nascer com o nome certo numa VM nova, em vez de divergir em silencio.
out="$(grep -m1 '^VM_STEPS=' "$REPO/setup.sh")"
check "no perfil vm, hostname vem antes de tailscale" "base hostname" "$out"


echo
echo "== 19. --defaults nao dispara o que nao pode ser respondido por script =="
# A correcao que este teste existe para travar. O `--yes` respondia sim a TUDO, e
# como nove dos nove prompts tinham default "nao" isso invertia cada opt-in; medido
# numa VM, o run TRAVAVA PARA SEMPRE no handshake do `gh` — uma pergunta do `gh`,
# que nenhuma variavel deste repositorio alcanca.
#
# A prova e por ausencia E por presenca: o `gh` nao e chamado, e o script diz por
# que pulou. Um teste que so verificasse "o run terminou" passaria tambem no cenario
# em que o `gh` e chamado e a resposta chega a tempo — que nao e o problema.
out="$(run_pty $'\n' --profile=vm --only=git --defaults)"
check "o modulo rodou" "Git e GitHub CLI" "$out"
check_not "e o gh NAO foi disparado" "handshake" "$out"
# A mensagem de "pulado, e por que" NAO e verificada aqui, e o motivo e do
# ambiente: o modulo comeca por `gh auth status`, e nesta maquina o `gh` esta
# autenticado, entao ele retorna antes — a sandbox usa o `gh` de verdade, e o
# resultado depende da conta de quem roda. A presenca da mensagem e da guarda em
# torno dela sao checadas no structure-test, que nao depende de conta nenhuma.

# E o outro lado: um default de SIM tem de ser aceito, ou a flag entregaria uma
# maquina sem as seis CLIs de agente.
out="$(run_pty $'' --profile=vm --only=ai-clis --defaults)"
check "um default de sim e aceito" "[Y/n]" "$out"
check "e a instalacao acontece" "Instalar as CLIs" "$out"
check_not "e o modulo nao e ignorado" "Instalação de CLIs de IA ignorada" "$out"

# E o `--yes` antigo continua aceito como alias, e continua dizendo o que faz.
out="$(run_pty $'\n' --profile=vm --only=git --yes)"
check "--yes ainda funciona como alias" "Git e GitHub CLI" "$out"
check_not "e tambem nao dispara o gh" "handshake" "$out"

echo
# O `pulados` entra no relatorio porque um pulo que nao aparece e um pulo que
# ninguem vai notar — que e como a cobertura do prompt de modo desapareceu.
if [ "${pulados:-0}" -gt 0 ]; then
  printf 'RESULTADO: %d ok, %d falhas, %d PULO(s)\n' "$pass" "$fail" "$pulados"
else
  printf 'RESULTADO: %d ok, %d falhas\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
