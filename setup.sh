#!/usr/bin/env bash
# setup.sh versão: 2026.10.03-e952827+pull-serve
set -eo pipefail

# Onde este script está em disco. Quando ele roda por pipe, `BASH_SOURCE[0]` é
# "bash" e este diretório é o de quem executou — que não é de onde o script veio.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A URL de origem, e o nome do repositório. Só é usada quando o script precisa se
# obter, e por isso fica vazia no caminho normal: um repositório clonado não deve
# depender de rede para rodar.
# Para onde o script se coloca quando chega por pipe. Um lugar só, e fora do
# `~/Developer`: o que se guarda ali é o material de instalação, e `~/Developer`
# é para código que a pessoa maintaina. Se o script só baixou o `setup.sh` e os
# dois anexos, não há repositório ali — e fingir que há, criando uma pasta com
# nome de projeto, é a forma de deixar lixo com cara de coisa importante.
SETUP_DESTINO="${SETUP_DESTINO:-$HOME/tmp/dotfiles}"

# A URL de origem. Vazio no caminho normal: um repositório clonado não deve
# depender de rede para rodar, e a única coisa que precisa de rede é o caminho por
# pipe, que é o que descobre a si mesmo.
SETUP_ORIGIN=""
REPO_SLUG="rvlmt/dotfiles-fedora"

# A versão deste script, impressa no banner e na ÚLTIMA linha do arquivo.
#
# A segunda ocorrência não é redundância: o `raw.githubusercontent.com` ja serviu
# versão velha desta URL quatro vezes nesta mesma sessão, e a forma de descobrir
# que rodou o script errado é conferir a última linha do que foi baixado. Uma
# constante impressa no banner ajuda quem le a tela; a linha no fim do arquivo
# ajuda quem tem o arquivo na mão e não a tela.
#
# A primeira linha do arquivo também carrega a versão, para o caso de o
# mecanismo que lê o arquivo cortar o fim — o que o `bash` FAZ, quando lê pela
# entrada padrão em fatias: um script de 265 KB que faz `exec` é lido só até o
# ponto da troca de processo.
SETUP_VERSION="2026.10.03-e952827+pull-serve"

# A última linha do arquivo. Ela é um comentário, então o shell nunca a executa:
# serve para ser lida, não para rodar.
# setup.sh versão: 2026.10.03-e952827+pull-serve

# Este script é para o servidor Fedora Workstation que roda os ambientes de
# execução dos coding agents (host de containers Podman/devpod, acessado a
# partir do Mac via Tailscale). A versão macOS fica no repo irmão "dotfiles".
if [[ "$(uname -s)" != "Linux" ]] || ! command -v dnf &> /dev/null; then
    echo "Este script é só para Fedora/Linux (precisa do dnf). Sistema detectado: $(uname -s) — use o repo 'dotfiles' (setup.sh) no Mac." >&2
    exit 1
fi

if [ "$EUID" -eq 0 ]; then
    echo "Não execute este script como root ou com 'sudo ./setup.sh'!" >&2
    echo "Execute './setup.sh' diretamente como seu usuário normal. O script solicitará sudo quando necessário." >&2
    exit 1
fi


GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Defaults pessoais — este é um dotfiles de uso individual (não um template
# genérico pra terceiros clonarem), então faz sentido fixar aqui em vez de
# perguntar toda vez. O e-mail é o noreply do GitHub (público por design,
# não expõe o e-mail real). Ainda dá pra sobrescrever por variável de
# ambiente ou digitando outra coisa no prompt.
DEFAULT_GIT_NAME="rvlmt"
DEFAULT_GIT_EMAIL="80988467+rvlmt@users.noreply.github.com"

# App ID da GitHub App que é a identidade de máquina da VM. É um IDENTIFICADOR,
# não uma credencial: aparece em claro no payload do JWT e na URL do app, e o
# próprio GitHub o trata como não-secreto. Fica como default pelo mesmo motivo que
# a identidade Git e as portas do OpenCode ficam: este script é de uso individual,
# e perguntar o número a cada reexecução só atrapalha.
#
# A PRIVATE KEY não tem default, e não vai ter. Segredo não tem valor padrão.
DEFAULT_GH_APP_ID="5098816"

# Conta cujas chaves públicas de dispositivos são autorizadas a entrar por SSH
# nesta máquina. A URL é derivada desta, para trocar de conta ser uma edição.
#
# Isto INVERTE uma decisão que o README registrava: o acesso por SSH não deve
# depender da segurança de nenhuma conta externa. A partir daqui o GitHub entra
# na cadeia de confiança — quem controla a conta controla a lista de quem entra.
# O que limita o estrago: o bloco é gerenciado e reescrito a cada execução, e
# linhas fora dele (uma chave local que o GitHub não tem) ficam intocadas. A
# revogação passa a ser indireta e diferida: remove-se a chave no GitHub, e ela
# perde o acesso na próxima vez que este módulo rodar. Ver o README.
GITHUB_KEYS_USER="rvlmt"

# Delimitadores do bloco gerenciado. Só o que está ENTRE eles é reescrito.
GITHUB_KEYS_BEGIN="# >>> dotfiles-fedora: chaves de dispositivos (GitHub) >>>"
GITHUB_KEYS_END="# <<< dotfiles-fedora: chaves de dispositivos (GitHub) <<<"

# Runtime do host. Quem fornece Node/npm no host é o mise — o pacote nodejs do
# dnf não é instalado de propósito, para que o runtime do host não dependa da
# versão que o Fedora decidir empacotar. Ver README, "Runtime Node no host".
#
# Nenhum dos dois é pinado por NÚMERO. Um pin fixo tem um custo que só aparece
# tarde: se a versão sair do registro, `mise install` falha, e como a chamada não
# tem `|| true` o módulo `base` inteiro cai sem dizer qual versão não existia
# mais. Acompanhar a última troca esse modo de falha por um que não existe.
#
# O Node usa o alias `lts`, e não `latest`: `lts` é a linha de suporte estendido,
# que é a que o runtime do host quer — um `latest` de Node traz major novo com
# frequência e o mise resolve o alias para a major atual. Medido: `node@lts` e
# `node@24` resolvem ambos para a mesma versão, e `@latest` NÃO é alias no mise
# (devolve vazio).
#
# O `devcontainer-cli` não tem alias nenhum no mise — `ls-remote` devolve vazio
# para `@latest` e para `@lts` — então a última versão real é lida do registro
# em `ensure_host_node`, e a constante abaixo é o fallback quando o registro não
# responde.
MISE_NODE_SPEC="lts"
MISE_DEVCONTAINER_FALLBACK="0.89.0"
MISE_BIN_PATH="$HOME/.local/bin/mise"
MISE_SHIMS_PATH="$HOME/.local/share/mise/shims"

# Canal e versão do OpenCode.
#
# São dois instaladores em URLs diferentes: a linha 1 fica em `opencode.ai/install`
# e a linha 2 em `opencode.ai/v2/install`. O "latest" do primeiro é a linha 1.x —
# foi o que instalou a v1 numa VM de agentes, e a v1 não tem o subcomando `service`
# que o próprio script usa em `apply_opencode_password` para definir a senha do
# servidor. Separar as duas URLs é o que impede a divergência entre máquinas.
#
# A versão é pinada como o mise e o Dev Container CLI: para subir o pin, altera o
# número e o commit diz por quê. A 2.0.18 é a `latest` do canal `latest` quando isto
# foi escrito, e o instalador a busca como `@opencode/cli-linux-x64`.
OPENCODE_INSTALL_URL="https://opencode.ai/v2/install"
OPENCODE_LATEST_URL="https://opencode.ai/update/api/latest/cli/npm"

# Endereço e porta do servidor do OpenCode no host, declarados aqui para que um
# host novo reproduza o mesmo estado — o instalador do opencode cria a unit sem
# consultar estas escolhas.
#
# O servidor escuta só em loopback. O acesso remoto de outros pontos da tailnet
# é feito por `tailscale serve` com HTTPS, declarado logo abaixo e aplicado por
# setup_opencode_serve. A regra, válida para qualquer serviço do host que precise
# de acesso remoto: escutar em loopback e expor pela tailnet. Escutar em
# `0.0.0.0` foi descartado porque incluía a interface WiFi local, alcançável por
# qualquer máquina da mesma rede, e sem TLS.
# Estes dois NÃO são variáveis de ambiente do opencode. Medido no binário de
# 203 MB: `OPENCODE_BIND` tem zero ocorrências, e `OPENCODE_PORT` também. A v2
# não conhece nenhuma das duas, em v1 nem em v2. São os valores que nós
# aplicamos com `opencode service set hostname|port`, que é o mecanismo real.
# Mantidos aqui porque duas funções precisam deles: a unit e a publicação.
# ---------------------------------------------------------------- Hermes
# Dashboard do Hermes, NATIVO — `hermes dashboard` é um subcomando da CLI, então a
# UI não precisa de container nenhum. Isso removeu a imagem de 2,81 GB e os 919 MB
# de estado do container, e é a única forma de a unit ser do systemd de usuário.
#
# A senha NÃO vai para o config em claro. Entra o hash scrypt, gerado pelo próprio
# código do Hermes; o texto puro fica num arquivo 600 do usuário, e no
# `config.yaml` nunca. Ver `setup_hermes_dashboard`, que também tem de remover a
# chave `password` que o `hermes config set` deja para trás.
HERMES_DASH_PORT="9119"
HERMES_SERVE_PORT="8445"
HERMES_DASH_USER="hermes"
HERMES_PW_FILE="$HOME/.config/hermes/dashboard-password"
HERMES_INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"
# Onde o instalador OFICIAL deixa a arvore: `INSTALL_DIR` tem como padrao
# `$HERMES_HOME/hermes-agent` (medido no install.sh, linha 79). Antes este script
# clonava para ~/Hermes-Agent e montava o symlink a mao — o caminho oposto ao que
# a documentacao prescreve, e que deixava o `pm` sem pin.
HERMES_CLI_DIR="$HOME/.hermes/hermes-agent"
    # A versão NÃO é fixada aqui, e o motivo não é preferência: é a INTERFACE do
    # instalador. O caminho de atualização dele busca
    # `git fetch origin "+refs/heads/$BRANCH:..."` (install.sh, linha 477), com o
    # prefixo `refs/heads/` escrito no código — então a entrada é uma branch, e
    # só uma branch. Passando a release `v2026.9.24` medido:
    # `fatal: couldn't find remote ref refs/heads/v2026.9.24`, e o instalador
    # falha com "git fetch failed". Ver a medição completa em `setup_hermes_cli`.
    #
    # Três coisas que valem registrar, porque elas se confundem com facilidade:
    #
    #   * a release `v2026.9.24` é uma tag ANOTADA (objeto `e3dd27ee`) que aponta
    #     para o commit `f97608f1`, e esse commit carrega SÓ essa tag — nenhuma
    #     `rc`. Release e release candidate são linhas distintas, não nomes
    #     diferentes para a mesma coisa.
    #   * o `main` está 4908 commits NA FRENTE da release. Seguir o `main` entrega
    #     mais do que a release, e é o default do instalador.
    #   * o pin que existia, `rc.14-v0.21.5`, entregava o commit `ec243785e`, que
    #     carrega aquela tag e o gêmeo `abandoned-rc.14-v0.21.5` — que é como o
    #     upstream aposenta uma rc sem apagar o nome original. Ou seja: não era a
    #     release, era uma release candidate, 19 rcs atrás, já marcada como
    #     abandonada.
    #
    # A regra de "ler o NOME INTEIRO da tag" segue valendo, e é a razão de isto ter
    # sido pego antes: a `rc.9` foi instalada primeiro por ter lido a tag da imagem
    # do container, sem olhar o prefixo `abandoned-`.

# ---------------------------------------------------------------- Hermes dashboard
# NATIVO tambem. O `hermes dashboard` e um subcomando da CLI, entao a UI nao
# precisa de container nenhum — e isso removeu 2,81 GB de imagem e os 9xx MB de
# estado do bind mount, que ainda por cima era do subuid.
#
# O TARGET de escuta e o IP DA TAILNET, nunca 127.0.0.1. Medido: o
# should_require_auth() devolve True para o IP da tailnet e False para o
# loopback, entao em loopback o portao simplesmente nao existe. E a consequencia
# de usar o IP e que o servico fica alcancavel direto, em HTTP sem TLS.
HERMES_DASH_UNIT="$HOME/.config/systemd/user/hermes-dashboard.service"

# O nome do no vem do DNSName do `tailscale status --json`, e NAO de
# `tailscale dnsname` — que nao existe nesta versao e responde "unknown
# subcommand", fazendo o $(...) virar vazio. Duas consequencias, ambas medidas:
#   o DNSName vem COM PONTO FINAL, que precisa sair;
#   e o HostName do no e "fedora", nao "fedora-vm". Sao nomes diferentes, e o
#     `tailscale serve` usa o DNSName.
# Com o hostname vazio, o public_url fica "https://:8445" e o middleware
# _is_accepted_host() REJEITA com 400 todo Host que nao seja o IP ligado — o que
# inclui o /login, e faz a tela parecer quebrada.
#
# Achei a causa olhando /proc/<pid>/environ, que mostrava a variavel com o host
# vazio. E o erro se disfarca de outra coisa: `pkill -f "hermes dashboard"` nao
# mata o processo, porque o binario reempacota o comando em
# `python3 -I -c "..." dashboard --host ... --port ...`. O processo velho ficava
# escutando, e toda medicao media ele em vez do novo.
# Funcao COMUM a dois modulos, e o nome precisa dizer isso. A primeira versao se
# chamava _hermes_dnsname e o OpenDesign tambem a usava: rodar o OpenDesign sem
# o bloco do Hermes carregado dava "command not found", e o efeito foi uma unit
# com `OD_ALLOWED_ORIGINS=https://:8444` — hostname vazio, exatamente o defeito
# que a funcao existe para evitar. Um nome que declara o dono vira uma dependencia
# invisivel, e o erro so aparece no arquivo gerado, muito depois do ponto.
_tailnet_dnsname() {
    tailscale status --json 2>/dev/null | python3 -c "
import json, sys
print(json.load(sys.stdin).get('Self', {}).get('DNSName', '').rstrip('.'))" 2>/dev/null
}

# Mata o dashboard pelo que o PROCESSO mostra, e nao pelo que o comando diz.
_hermes_dash_pids() {
    pgrep -f -- "--port $HERMES_DASH_PORT" 2>/dev/null
}

# ---------------------------------------------------------------- OpenDesign
# DOIS modos, e eles nao sao dois ramos de uma coisa so. Nao compartilham
# pre-requisito nenhum, e foi por isso que viraram dois modulos em vez de um
# `if`:
#
#   NATIVO     node do mise, pnpm via corepack, libatomic, e ~1,5 GB de
#              `pnpm install` seguido de build do daemon e do web. Em troca, os
#              agentes do host EXECUTAM: medido, 7 disponiveis contra 0 no
#              container.
#   CONTAINER  nada alem da imagem. Em troca, nenhuma CLI do host executa dentro
#              — `opencode` e `agy` sao ELF glibc e a imagem e Alpine.
#
# O que decide o preco de cada um, e o que a pergunta do bloco de inicial
# precisa deixar claro:
#
#   O NATIVO PRECISA escutar no IP DA TAILNET, nao no loopback. O daemon tem um
#   carve-out que dispensa o token quando o peer e loopback, e o `tailscale serve`
#   faz proxy de localhost para localhost — em loopback a senha NAO SERIA
#   conferida. Medido: em 127.0.0.1 o `/api/agents` devolve 200 sem credencial; no
#   IP da tailnet devolve 401. E a consequencia: o servico fica alcancavel
#   direto, em HTTP sem TLS, na porta interna.
#
#   O CONTAINER nao tem esse preco: a bridge faz o peer ser o gateway, o carve-out
#   nao pega, e o servico so existe atras do `serve`, com TLS.
OPENDESIGN_MODE=""                 # native | container, decidido na pergunta
OPENDESIGN_PORT="7456"
OPENDESIGN_IMAGE="ghcr.io/nexu-io/od@sha256:587a992857d0f8b71011e4bc55c5851e33ef9fc4c169fc17e6447700ac428f22"
# ==============================================================================
# O registro do que este run não conseguiu fazer
# ==============================================================================
#
# Isto fica aqui em cima, e não com as pós-condições no fim, porque é usado nos
# dois lugares: os módulos registram pendências **enquanto rodam** — o do Tailscale
# é o caso, e é o que acontece numa VM nova — e as pós-condições no fim leem a
# mesma lista para dizer o que não prestou.
#
# A ordem importa e eu já a fiz ao contrário: com a lista definida perto do fim,
# o `provision_tailscale` a usaria antes dela existir. Em bash isso não dá erro
# de sintaxe, dá `_FALHAS` vazia — que é o modo de falha mais caro possível,
# porque o run reporta "pronto" e não há ninguém para dizer que não.
#
# Um contador, e nao um `set -e`. O `set -e` decide por POSICAO: o mesmo
# `return 1` aborta o run num lugar e so marca falha em outro. Um contador nao
# aborta nada, ele conta — e quem aborta, se quiser, e o fim do script, com o
# codigo de saida, uma vez, com a lista do que ficou para tras.
_FALHAS=()
_FALHAS_TXT=""

_registrar_falha() {
    _FALHAS+=("$1")
    [ -z "$_FALHAS_TXT" ] && _FALHAS_TXT="$1" || _FALHAS_TXT="$_FALHAS_TXT; $1"
}

_registrar_ok() {
    [ -n "$1" ] && echo -e "  ${GREEN}✓ $1${NC}"
    return 0
}

OPENDESIGN_SRC="$HOME/Developer/open-design"
# O modo nativo compila de fonte, entao precisa do clone. A URL estava no README
# e NAO no script, que imprimia um placeholder e parava — medido: o passo parava
# com "git clone <url-do-open-design>" numa maquina limpa. O repositorio resolve
# (medido com `git ls-remote` da propria VM).
OPENDESIGN_REPO_URL="https://github.com/nexu-io/open-design.git"
# A raiz do build E o proprio clone. Antes existia uma pasta paralela,
# `~/Developer/open-design-native-root`, criada para nao colidir com o clone — que
# e o caminho que a documentacao e os exemplos do proprio OpenDesign esperam. O
# nome provisorio foi registrado em tres lugares como "para a proxima instalacao",
# e a proxima instalacao chegou: mover a raiz e trivial numa maquina que ainda nao
# rodou nada, e caro numa que ja roda. Entao a raiz passou a ser o clone.
#
# Consequencia que precisa ser respeitada em `_setup_open_design_native`: com
# ROOT == SRC, o symlink de `apps/web/out` apontaria para o proprio destino, um
# laco. O guard la existe por causa desta linha, e nao e removivel numa
# leitura apressada.
OPENDESIGN_ROOT="$OPENDESIGN_SRC"
OPENDESIGN_SERVE_PORT="8444"
OPENDESIGN_DEPLOY_DIR="$OPENDESIGN_ROOT/apps/daemon"
OPENDESIGN_WEB_DIR="$OPENDESIGN_SRC/apps/web/out"
OPENDESIGN_UNIT="$HOME/.config/systemd/user/open-design.service"
# O nome que o `tailscale serve` usa e o DNSName do no, e ele NAO e o hostname da
# maquina: no nó medido, `hostname` da `fedora-vm` e o DNSName termina em
# `.sawfish-banjo.ts.net`. Montar a URL com o hostname produz um public_url que o
# OAuth nao reconhece, e o sintoma e redirect_uri_mismatch.
HERMES_PUBLIC_URL="${HERMES_PUBLIC_URL:-}"   # resolvido em _tailnet_dnsname, nao no topo

OPENCODE_HOST="127.0.0.1"
OPENCODE_PORT="49374"
OPENCODE_BIN="$HOME/.opencode/bin/opencode"

# Publicação na tailnet, em porta HTTPS dedicada.
#
# Porta própria, e não prefixo de caminho, por dois motivos independentes:
#
# 1. Isolamento de origem. Porta diferente É origem diferente, então cookies,
#    localStorage e CSP não são compartilhados com o que estiver na 443. Prefixo
#    de caminho mantém a mesma origem e não isola nada.
# 2. O OpenCode não tolera ser servido fora da raiz. A SPA sobe em qualquer path,
#    mas as chamadas de API em caminho absoluto caem na raiz do host, onde não há
#    handler, e a interface quebra com "Unrecognised route!". Só a raiz da própria
#    origem funciona.
#
# A 443 fica reservada: é o slot para o serviço que você quiser ter mais à mão.
OPENCODE_SERVE_PORT="8443"

# Senha padrão do servidor do OpenCode. É o NOME do serviço, como `hermes` no
# dashboard do Hermes: a convenção é a mesma, e a §6 da auditoria registra as
# duas. Ela aparece entre colchetes no prompt, como o e-mail do GitHub, e um
# Enter a aceita.
OPENCODE_DEFAULT_PASSWORD="opencode"

# Preenche GIT_NAME/GIT_EMAIL: pula o prompt se já vierem do ambiente
# (pré-exportados), senão pergunta com o default sugerido entre colchetes
# (Enter aceita, digitar outra coisa sobrescreve só nesta execução).
prompt_git_identity() {
    if [ -z "$GIT_NAME" ]; then
        pergunta "Nome completo para o Git [$DEFAULT_GIT_NAME]: " GIT_NAME
        GIT_NAME="${GIT_NAME:-$DEFAULT_GIT_NAME}"
    fi
    if [ -z "$GIT_EMAIL" ]; then
        pergunta "E-mail (Git e SSH) [$DEFAULT_GIT_EMAIL]: " GIT_EMAIL
        GIT_EMAIL="${GIT_EMAIL:-$DEFAULT_GIT_EMAIL}"
    fi
}

# Lê uma resposta do operador, e degrada de forma explícita sob `--yes`.
#
# Sem esta função, um `read` em EOF devolve 1 e o `set -e` aborta o script — que
# é o que fazia a recusa de "precisa de um terminal" existir. Com `--yes` não há
# terminal, então TODO `read` que sobraria abortaria o script no meio, e a flag
# seria exatamente a promessa que não cumpre.
#
# A degradação é "vazio", e cada chamador já tem um default para o vazio: a
# identidade do Git cai no default, o App ID no default declarado, o hostname
# mantém o atual. É a mesma semântica de responder "só enter", que é o que a
# pessoa teria feito.
pergunta() {
    local prompt="$1" varname="$2"
    if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
        printf -v "$varname" '%s' ""
        return 0
    fi
    read -rp "$prompt" "$varname" || printf -v "$varname" '%s' ""
}

confirm() {
    local prompt="$1"
    # O default é o SEGUNDO argumento, e não uma coisa implícita, porque "por
    # padrão" e "sempre" são decisões diferentes e o script precisa dizer qual das
    # duas está fazendo. `confirm "..."` sem o segundo argumento continua sendo NÃO,
    # que é o comportamento de todos os call sites que não pensaram no assunto —
    # nenhum deles mudou de comportamento por esta assinatura aceitar um argumento
    # a mais.
    local default="${2:-0}"
    local reply
    local sufixo="[y/N]"
    [ "$default" = "1" ] && sufixo="[Y/n]"
    # `ASSUME_DEFAULTS` é inicializado aqui, e não na linha de argumentos, porque esta
    # função é definida antes dela e a chamadora de `confirm` mais acima já
    # precisa do valor. Sob `set -u`, ler a variável antes de existir aborta o
    # script — e a checagem aqui é o que evita isso.
    #
    # ⚠️ **A flag responde o DEFAULT, e isso é uma inversão de semântica medida.**
    #
    # Antes ela respondia SIM a tudo. E como **nove dos nove** prompts deste script
    # tinham default "não", "responder sim a tudo" era o mesmo que **inverter cada
    # opt-in**. Medido numa VM provisionada, com `--yes`:
    #
    #     ==> Git e GitHub CLI
    #     Iniciando handshake com o GitHub via navegador...
    #     ? Authenticate Git with your GitHub credentials? (Y/n)
    #
    # e o run **parou ali para sempre**. A pergunta é do `gh`, não deste script, e
    # nenhuma variável de ambiente deste repositório chega nela. Antes de chegar
    # nesse ponto, `--yes` já tinha invertido: travar a senha do root, instalar o
    # proxy do OpenCodex, sobrescrever o `~/.zshrc` e exigir uma senha para o
    # servidor do OpenCode.
    #
    # A regra agora é a que o nome diz: **`--defaults` aceita todos os defaults**.
    # E os defaults são escolhidos para que "default" signifique "provisionar": o que
    # está na lista de passos do perfil tem default sim, e o que é entrada para um
    # serviço externo ou destruição de credencial tem default não. Uma coisa que não
    # pode ser respondida por script — o handshake do `gh` — nunca chega a ser
    # perguntada, porque o prompt que a dispararia já tem default não.
    if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
        echo -e "${prompt} ${GREEN}[--defaults: aceitando o padrão ($sufixo)]${NC}"
        # O `return` é o INVERSO do default, porque `confirm` devolve 0 para sim e 1
        # para não. Escrever isso com aritmética é o que produziu o bug anterior —
        # `return "$default"` devolvia 1 num default de "sim" — então fica escrito.
        if [ "$default" = "1" ]; then return 0; fi
        return 1
    fi
    # O sufixo diz o que o Enter faz, e dizer errado é pior que não dizer: um
    # `[y/N]` com default "não" e um `[Y/n]` com default "sim" são a mesma
    # pergunta com respostas opostas. Ele foi calculado acima, porque a mensagem da
    # flag precisa dele também.
    read -rp "$prompt $sufixo " reply
    # Enter vazio vale o default declarado. Sem estas duas linhas o default seria
    # decorativo: o `read` devolveria string vazia, a comparação abaixo cairia em
    # "não", e um `[Y/n]` aceitaria o não — o oposto do que a pergunta anuncia.
    #
    # O `return` é o INVERSO do default, e essa inversão é a parte que passou
    # batido na primeira versão: `confirm` devolve 0 para sim e 1 para não, então
    # `return "$default"` devolvia 1 num default de "sim" — e a pergunta anunciava
    # `[Y/n]` enquanto um Enter respondia não. Nenhum teste pegou, porque nenhum
    # teste respondia vazio a uma pergunta de default sim. Corrigido, e o teste
    # que faltava foi escrito.
    if [ -z "$reply" ]; then
        [ "$default" = "1" ] && return 0
        return 1
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

# O sshd JÁ está endurecido? A pergunta é pela CONFIG EFETIVA, e não pelo arquivo.
#
# A versão anterior testava `[ ! -f /etc/ssh/sshd_config.d/99-dotfiles-hardening.conf ]`,
# e esse teste é **sempre verdadeiro** nesta imagem. Medido na VM:
#
#   /etc/ssh/sshd_config.d   drwx------ root:root     ← modo 700
#   99-dotfiles-hardening.conf  -rw-r--r-- root:root  ← legível por todos
#
#   [ -f ... ] como usuário  -> FALSO     (o que o script testava)
#   sudo test -f ...         -> VERDADEIRO
#   ls ...  como usuário     -> "Permission denied"
#
# O bloqueio está na TRAVESSIA do diretório, não no arquivo: um `-f` como usuário
# normal não consegue resolver o caminho e diz que não existe. A imagem do Fedora 44
# traz esse diretório em 700, então a consequence foi dupla e nenhuma das duas
# reclamava: a pergunta do hardening repetia a cada run mesmo já aplicado, e o
# `else` que dizia "já aplicado" era código inalcançável — o módulo reescrevia o
# drop-in e recarregava o sshd em toda execução.
#
# `sshd -T` imprime a configuração já resolvida, que é a PROPRIEDADE. E é imune à
# permissão porque responde com `sudo -n`: sem senha, e sem pausar o script.
#
# `-n` é o que torna isto usável onde o `sudo -v` ainda NÃO rodou, que é o bloco de
# perguntas: sem `-n` isto abriria uma segunda pausa para senha no meio do roteiro.
#
# E aqui está a parte que é preciso saber, porque a primeira versão deste comentário
# dizia o contrário: no bloco de perguntas o timestamp do `sudo` está frio, `sudo -n`
# falha, e a função devolve falso — então **a pergunta continua aparecendo em toda
# execução**, mesmo com o hardening já aplicado. Medido: a pergunta aparece, e o
# módulo em seguida responde "já endurecido, nada a fazer".
#
# O que a propriedade conserta é o que importava: antes, o `[ -f ]` mentia, o módulo
# reescrevia o drop-in e recarregava o `sshd` em CADA run. O resto que fica é o
# atrito de um prompt a mais, e ele é o preço de uma decisão de dono do repo: fazer a
# pergunta também depender do estado exigiria subir o `sudo -v` para antes dela, o
# que muda o lugar em que a senha é pedida. Isso é escolha de quem provisiona, e não
# uma coisa que um agente mude em silêncio.
_sshd_hardened() {
    local _t
    _t="$(sudo -n sshd -T 2>/dev/null)" || return 1
    printf '%s\n' "$_t" | grep -qx 'passwordauthentication no' || return 1
    printf '%s\n' "$_t" | grep -qx 'permitrootlogin no'
}


# O nome de uma máquina: `<perfil>-<os>-<4 do machine-id>`.
#
# As três camadas são o que o nome afirma: **que papel** a máquina cumpre, **de que
# sistema**, e **qual delas**. Medido: perfil `vm` + `ID=fedora` + `machine-id` que
# começa com `c104` → `vm-fedora-c104`.
#
# A camada do papel vem do PERFIL, e essa foi uma simplificação deliberada. A
# alternativa seria detectar o chassis — e o systemd faz isso bem, o que é notável:
# medido, `hostnamectl status` diz `desktop` nesta máquina e `vm` na VM, e o
# `systemd-detect-virt` diz `none` e `qemu`. Duas razões para não ir por aí:
#
#   * a detecção é um **número de especificação** (o DMI `chassis_type` é 13 aqui,
#     All-in-One) ou uma linha de texto com **rótulo traduzido e emoji** — e o
#     `hostnamectl status` real é `Chassis: desktop 🖥️`, que precisa de parsing para
#     virar `desktop`;
#   * e o motivo que decide: o perfil **é** a declaração de que papel a máquina
#     cumpre, e ele já é digitado na linha de comando. Detectar o hardware para
#     redescobrir o que a pessoa acabou de declarar é medir de novo o que já foi
#     dito, e o nome passa a discordar do perfil quando os dois divergem — que é a
#     classe de defeito que esta seção do repo existe para evitar.
#
# O `DDMM` que estava na proposta inicial saiu por não acrescentar nada sobre um id
# que já é único, e por mudar com o dia — o que faria um re-run no dia seguinte
# propor outro nome para uma máquina que já está correta. O `os` é **resolvido** e
# não escrito à mão, para que uma mudança de imagem base apareça no nome em vez de
# ficar escondida atrás de um literal.
#
# Por que o `machine-id` e não um sorteio: um nome sorteado precisa ser gravado em
# algum lugar para não mudar a cada run, e esse lugar seria estado que só existe na
# máquina. O id é determinístico — dois runs dão o mesmo nome, com nada gravado.
# `product_uuid`, que seria o identificador natural por ser o do hypervisor, é
# **ausente** nas duas máquinas: `cat /sys/class/dmi/id/product_uuid` não existe.
#
# A ressalva é a de qualquer coisa derivada do `machine-id`: uma imagem **clonada**
# copia o id junto, e duas máquinas do mesmo template recebem o mesmo nome. Por isso
# o módulo confere a tailnet e avisa se outro nó já estiver com ele.
suggest_hostname() {
    local kind os_id mid
    case "$PROFILE" in
        vm)   kind="vm" ;;
        host) kind="pc" ;;
        *)    kind="maq" ;;
    esac
    # O SO vem de /etc/os-release, e não de um literal.
    os_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
    os_id="$(printf '%s' "$os_id" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
    [ -n "$os_id" ] || os_id="linux"
    mid="$(cat /etc/machine-id 2>/dev/null || true)"
    # 4 caracteres do INÍCIO do machine-id.
    mid="${mid:0:4}"
    [ -n "$mid" ] || mid="semid"
    printf '%s-%s-%s' "$kind" "$os_id" "$mid"
}
# Caminho do mise sem depender do PATH do shell que executou este script.
mise_bin() {
    if command -v mise &> /dev/null; then
        command -v mise
        return 0
    fi
    if [ -x "$MISE_BIN_PATH" ]; then
        printf '%s' "$MISE_BIN_PATH"
        return 0
    fi
    return 1
}

# Coloca os shims do mise no PATH do processo atual. Preferimos shims a
# "mise activate bash" porque eles funcionam também onde não há shell
# interativo — inclusive serviço systemd, que nunca lê ~/.bashrc. Cada shim
# consulta a config do diretório em que é chamado, então continuam respeitando
# um .tool-versions/mise.toml local do projeto.
prepend_mise_shims() {
    [ -d "$MISE_SHIMS_PATH" ] || return 0
    case ":$PATH:" in
        *":$MISE_SHIMS_PATH:"*) return 0 ;;
    esac
    export PATH="$MISE_SHIMS_PATH:$PATH"
}

# Instala o mise se faltar. Idempotente.
ensure_mise() {
    if mise_bin &> /dev/null; then
        echo -e "${YELLOW}mise já instalado.${NC}"
        return 0
    fi
    echo "Instalando mise (gerenciador de versões de runtime)..."
    curl -fsSL https://mise.run | sh
    if mise_bin &> /dev/null; then
        echo -e "${GREEN}✓ mise instalado.${NC}"
        return 0
    fi
    echo -e "${YELLOW}mise foi instalado mas não apareceu em $MISE_BIN_PATH.${NC}" >&2
    return 1
}

# Garante mise com Node e Dev Container CLI pinados e expõe os shims no PATH do
# processo atual. Este é o único caminho de Node/npm do host: o ai-clis tem
# fallback pra "npm install -g" e as CLIs de agente resolvem
# "#!/usr/bin/env node", então precisam de um Node no PATH durante a execução.
ensure_host_node() {
    ensure_mise
    prepend_mise_shims
    local mise_bin_path dc_ver node_ver
    mise_bin_path="$(mise_bin)"

    # O mise não tem alias para o devcontainer-cli, então a última versão real é
    # lida do registro. A última LINHA do `ls-remote` é a maior: o mise lista em
    # ordem. Sem rede o registro falha e o fallback declarado no topo entra, que é
    # preferível a derrubar o `base` inteiro por causa disso.
    dc_ver="$(timeout 60 "$mise_bin_path" ls-remote devcontainer-cli 2>/dev/null | tail -1 | tr -d '\r')"
    [ -n "$dc_ver" ] || dc_ver="$MISE_DEVCONTAINER_FALLBACK"

    node_ver="$(timeout 60 "$mise_bin_path" ls-remote "node@$MISE_NODE_SPEC" 2>/dev/null | tail -1 | tr -d '\r')"
    [ -n "$node_ver" ] || node_ver="$MISE_NODE_SPEC"

    "$mise_bin_path" install "node@$MISE_NODE_SPEC" "devcontainer-cli@$dc_ver"
    # `use -g` sem `--pin`. O motivo, medido numa VM limpa, é mais específico do
    # que se supunha: o que decide o que fica gravado NÃO é o `--pin`, é a forma
    # do argumento.
    #
    # Medido, com o `~/.config/mise/config.toml` resultante:
    #
    #     [tools]
    #     devcontainer-cli = "0.89.0"
    #     node = "lts"
    #
    # Ou seja: um ALIAS (`lts`) é gravado como alias, e um NÚMERO explícito é
    # gravado como número. O `--pin` não é o que transforma um em outro. Passar
    # `node@lts` é o que preserva o alias, e é por isso que a máquina continua
    # acompanhando: cada execução re-resolve o `lts` e reescreve a linha.
    #
    # O `install` acima resolve e instala `24.21.0`, e por isso o aviso dele —
    # "installed but not activated — they are not in any config file" — é
    # ESPERADO: `install` não ativa, `use` ativa. As duas chamadas são uma função
    # só, e trocar a ordem deixaria o runtime instalado e não ativado.
    "$mise_bin_path" use -g "node@$MISE_NODE_SPEC" "devcontainer-cli@$dc_ver"
    prepend_mise_shims
    echo -e "${GREEN}✓ Runtime do host: node@$node_ver (lts), devcontainer-cli@$dc_ver${NC}"
}

# Link ~/.local/bin/devcontainer → shim do mise. ~/.local/bin já está no PATH
# do shell, então isso dá um atalho curto que também funciona fora de shell
# interativo, cenário em que "mise activate" não se aplica. Atenção: por ser
# shim, dentro de um repositório com mise.toml/.tool-versions próprios ele
# resolve o runtime daquele diretório — use a forma "mise exec ... --" do
# README quando o pin do host importar.
link_devcontainer_cli() {
    local shim="$MISE_SHIMS_PATH/devcontainer"
    local dest="$HOME/.local/bin/devcontainer"
    if [ ! -x "$shim" ]; then
        echo -e "${YELLOW}Shim do devcontainer CLI ausente em $shim; pulei o link.${NC}" >&2
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$shim" ]; then
        echo -e "${GREEN}✓ ~/.local/bin/devcontainer já aponta para o shim do mise.${NC}"
        return 0
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        local backup
        backup="$dest.backup.$(date +%Y%m%d%H%M%S)"
        mv "$dest" "$backup"
        echo -e "${YELLOW}~/.local/bin/devcontainer anterior salvo em $backup${NC}"
    fi
    ln -s "$shim" "$dest"
    echo -e "${GREEN}✓ ~/.local/bin/devcontainer → shim do mise.${NC}"
}

# Ativa o mise em shells bash interativos. Bloco idempotente, com marcador
# próprio para não duplicar em re-execuções do setup.
activate_mise_in_shell() {
    local bashrc="$HOME/.bashrc"
    local marker='# >>> mise (runtime do host) >>>'
    if [ ! -f "$bashrc" ]; then
        echo -e "${YELLOW}~/.bashrc não existe; pulei a ativação do mise.${NC}" >&2
        return 1
    fi
    if grep -qF "$marker" "$bashrc"; then
        echo -e "${GREEN}✓ mise já ativado em ~/.bashrc.${NC}"
        return 0
    fi
    {
        printf '\n%s\n' "$marker"
        printf '# Node/npm do host vêm daqui (pins em setup.sh), não do dnf.\n'
        printf 'if [ -d "%s" ]; then\n' "$MISE_SHIMS_PATH"
        printf '    export PATH="%s:$PATH"\n' "$MISE_SHIMS_PATH"
        printf 'fi\n'
        printf '# <<< mise (runtime do host) <<<\n'
    } >> "$bashrc"
    echo -e "${GREEN}✓ mise ativado em ~/.bashrc (vale no próximo shell, ou com 'source ~/.bashrc').${NC}"
}

# O instalador do agy cria antigravity-cli-daemon.service, que executa o MCP
# HeroUI como filho "npm exec". Serviço systemd não lê ~/.bashrc, então sem um
# drop-in ele continuaria usando o npm do dnf — justamente o pacote que a
# política de runtime quer remover do host. Drop-in é a forma suportada de
# ajustar o PATH sem editar o unit, e sobrevive a atualização do instalador.
# Não reiniciamos o serviço aqui: reiniciar pode cortar uma sessão de agente em
# andamento, então isso fica como passo manual.
setup_agy_service_path() {
    local unit="$HOME/.config/systemd/user/antigravity-cli-daemon.service"
    local dropin_dir="$HOME/.config/systemd/user/antigravity-cli-daemon.service.d"
    local dropin="$dropin_dir/10-mise-path.conf"
    if [ ! -f "$unit" ]; then
        return 0
    fi
    local expected="[Service]
Environment=\"PATH=$MISE_SHIMS_PATH:$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin\""
    mkdir -p "$dropin_dir"
    if [ -f "$dropin" ] && [ "$(cat "$dropin")" = "$expected" ]; then
        echo -e "${GREEN}✓ PATH do antigravity-cli-daemon já aponta pros shims do mise.${NC}"
        return 0
    fi
    printf '%s\n' "$expected" > "$dropin"
    systemctl --user daemon-reload 2>/dev/null || true
    echo -e "${GREEN}✓ Drop-in de PATH do antigravity-cli-daemon criado.${NC}"
    echo -e "${YELLOW}  Aplique com: systemctl --user restart antigravity-cli-daemon${NC}"
}

# Deixa quem administra o host escolher a senha do servidor do OpenCode, em vez
# de depender da aleatória que o instalador gera.
#
# Não há como passar a senha por stdin: `opencode service set` recebe o valor em
# argv. O histórico do shell NÃO é afetado, porque aqui o valor é lido de stdin e
# nunca é digitado como argumento; em troca ele fica visível no `ps` por um
# instante, para processos do mesmo usuário. Em host de usuário único isso é
# aceitável, mas é o motivo de a leitura ser silenciosa e de o valor ser apagado
# da variável assim que usado.
#
# O servidor lê a senha no start, então o serviço precisa ser reiniciado depois
# para a troca valer.
# Aplica a senha lida no bloco de perguntas. Só aplicar, nunca ler: a leitura
# acontece uma vez, no começo, para que o script não pare no meio do caminho. Ver o
# bloco de confirmações antecipadas.
apply_opencode_password() {
    local oc="${OPENCODE_BIN:-}"
    if [ -z "$oc" ] || [ ! -x "$oc" ]; then
        echo -e "${YELLOW}Binário do OpenCode não encontrado; pulei a senha.${NC}" >&2
        return 1
    fi

    if [ "${OPENCODE_PASSWORD_SET:-}" != "1" ] || [ -z "${OPENCODE_PASSWORD:-}" ]; then
        echo -e "${YELLOW}Mantida a senha atual.${NC}"
        unset OPENCODE_PASSWORD
        return 0
    fi

    if ! "$oc" service set password "$OPENCODE_PASSWORD"; then
        unset OPENCODE_PASSWORD
        echo -e "${YELLOW}Não consegui definir a senha.${NC}" >&2
        return 1
    fi
    unset OPENCODE_PASSWORD
    echo -e "${GREEN}✓ Senha do OpenCode definida.${NC}"
    echo -e "${YELLOW}  Aplique com: systemctl --user restart opencode${NC}"
}

# Declara no `tailscale serve` a publicação do servidor do OpenCode, para que o
# acesso remoto de outros pontos da tailnet exista sem abrir porta no host.
#
# Idempotente por comparação de texto, e não por JSON: o formato da saída de
# `tailscale serve status` muda entre versões do Tailscale, então a verificação
# é deliberadamente tolerante e a função **revalida depois de agir**. Se a
# premissa de formato estiver errada, a revalidação mostra o estado real em vez
# de o script afirmar sucesso.
#
# Não sobrescreve config de outro serviço: se já houver algo publicado, o script
# avisa e deixa a decisão para quem administra o host.
setup_opencode_serve() {
    local target="${OPENCODE_HOST}:${OPENCODE_PORT}"

    if ! command -v tailscale &> /dev/null; then
        echo -e "${YELLOW}Tailscale ausente; pulei a publicação do OpenCode.${NC}" >&2
        return 1
    fi
    if ! tailscale status >/dev/null 2>&1; then
        echo -e "${YELLOW}Tailscale não conectado; pulei a publicação do OpenCode.${NC}" >&2
        return 1
    fi

    local current
    current="$(tailscale serve status 2>/dev/null || true)"

    local url="https://<host>.<tailnet>.ts.net:$OPENCODE_SERVE_PORT"

    if printf '%s' "$current" | grep -qF -- "$target"; then
        echo -e "${GREEN}✓ OpenCode já publicado na tailnet (:$OPENCODE_SERVE_PORT → $target).${NC}"
        return 0
    fi
    if printf '%s' "$current" | grep -qE 'https?://|proxy'; then
        echo -e "${YELLOW}Já existe serviço publicado no Tailscale e não é o OpenCode:${NC}"
        printf '%s\n' "$current" | sed 's/^/    /'
        echo -e "${YELLOW}  Não sobrescrevi. Para publicar o OpenCode, revise o que está acima.${NC}"
        return 1
    fi

    # Sem prefixo de caminho: o app só funciona na raiz da própria origem.
    if sudo tailscale serve --bg --https="$OPENCODE_SERVE_PORT" "http://$target"; then
        echo -e "${GREEN}✓ OpenCode publicado na tailnet (:$OPENCODE_SERVE_PORT → $target).${NC}"
        echo -e "${YELLOW}  Acesse por $url, com certificado do Tailscale.${NC}"
    else
        echo -e "${YELLOW}Não consegui publicar via tailscale serve.${NC}" >&2
        echo -e "${YELLOW}  Publicar manualmente: sudo tailscale serve --bg --https=$OPENCODE_SERVE_PORT http://$target${NC}"
        return 1
    fi

    # Revalidação: confirma o que o Tailscale realmente passou a servir.
    local after
    after="$(tailscale serve status 2>/dev/null || true)"
    if printf '%s' "$after" | grep -qF -- "$target"; then
        printf '%s\n' "$after" | sed 's/^/    /'
    else
        echo -e "${YELLOW}  Revise com 'tailscale serve status': o alvo esperado ($target) não apareceu.${NC}"
        return 1
    fi
}

# O instalador do opencode cria a unit opencode.service. Ela é estado de host
# sem dono no padrão: um `setup.sh` em um host novo não reproduziria o ajuste de
# escuta, e o servidor voltaria a ficar em loopback. Por isso a escuta é
# declarada aqui, por drop-in: sobrevive a uma reescrita do instalador e não
# encosta nas outras diretivas que ele define (PATH, Restart, TimeoutStopSec).
#
# A flag `--service` é preservada de propósito, e é obrigatório que seja. A senha
# do servidor não é opcional no OpenCode v2: com `--service` ela vem de
# ~/.config/opencode/service.json e é estável entre restarts; sem a flag, o
# servidor gera uma senha aleatória efêmera a cada start e a registra no journal,
# o que invalida as credenciais já salvas no navegador a cada reinício.
# `OPENCODE_SERVER_PASSWORD` e `UnsetEnvironment` não desligam a autenticação,
# apenas escolhem a fonte do valor.
# Instala a CLI do Hermes NATIVA, pelo instalador que a propria documentacao
# prescreve — o "Quick Install" do README upstream e uma linha de `curl | bash`.
#
# Nativa por necessidade e nao por preferencia: o binario `opencode` e o `agy` que
# o OpenDesign usa como agentes sao ELF glibc, e o container do OpenDesign e
# Alpine. Ver a secao do README sobre o muro de libc nos dois sentidos.
setup_hermes_cli() {
    if ! command -v curl &> /dev/null || ! command -v git &> /dev/null; then
        echo -e "${YELLOW}curl ou git ausente; pulei a CLI do Hermes.${NC}" >&2
        return 1
    fi

    # libatomic: sem ela o node pinado do pm morre com "error while loading
    # shared libraries: libatomic.so.1" e o install falha na verificacao. Nem o
    # setup-hermes.sh nem o README do upstream mencionam a dependencia — e ela
    # EXISTE dentro do container Alpine e nao existe no host, que e o mesmo muro
    # de libc do OpenDesign no sentido inverso. O modulo `base` a instala; este
    # guarda existe para quem roda `--only=hermes-cli` sem o `base`.
    if [ ! -e /usr/lib64/libatomic.so.1 ]; then
        echo -e "${YELLOW}Falta a libatomic, e o install do Hermes vai falhar sem ela.${NC}" >&2
        echo -e "${YELLOW}  Instale com: sudo dnf install -y libatomic${NC}" >&2
        return 1
    fi

    # ── SEM PIN DE VERSÃO, e a interface do instalador é a razão ─────────────
    #
    # A pergunta natural é "seguir a latest RELEASE em vez do main", e ela foi
    # medida antes de ser respondida. Não dá, e o motivo é do instalador:
    #
    #   * no caminho de ATUALIZAÇÃO ele busca
    #     `git fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"`
    #     (install.sh, linha 477). O prefixo `refs/heads/` está ESCRITO no
    #     código, então a entrada é uma branch e só uma branch. Medido
    #     passando a release `v2026.9.24`: `fatal: couldn't find remote ref
    #     refs/heads/v2026.9.24`, e o instalador falha com "git fetch failed".
    #   * no caminho de INSTALAÇÃO NOVA ele usa `git clone --branch`, e aí uma
    #     tag SERIA aceita. O que torna a opção pior, e não melhor: ela funciona
    #     na primeira vez e quebra na segunda. Um pin que funciona uma vez é uma
    #     armadilha, não uma escolha.
    #
    # Medido também o que a release e o `main` são: `v2026.9.24` é uma tag
    # ANOTADA (objeto `e3dd27ee`) que aponta para o commit `f97608f1`, e esse
    # commit carrega SÓ essa tag — nenhuma `rc`. São linhas distintas, e o
    # `main` está 4908 commits NA FRENTE da release. Seguir o `main` entrega mais
    # do que a release, e é o default do instalador.
    #
    # E o pin que existia antes (`rc.14-v0.21.5`) entregava o quê: um commit
    # (`ec243785e`) que carrega aquela tag e o gêmeo `abandoned-rc.14-v0.21.5` —
    # que é como o upstream aposenta uma rc sem apagar o nome — e que não é a
    # release. Release candidate, 19 rcs atrás, marcada como abandonada. É a
    # razão de a regra ser "sem pin", e não "outra tag".
    #
    # Então: o comando documentado, sem `--branch`. Quem decide a versão é o
    # instalador, que é o que a documentação quer.
    #
    # A idempotência também não pode mais ser por tag, porque não há tag: passa a
    # ser o `git fetch` do instalador, e o script só reporta. A verificação por
    # ESTADO que valia a pena — o launcher responde — continua no fim.
    # A idempotência é por COMMIT, contra `origin/main` — e não é um pin, é a
    # comparação que o próprio instalador faria. Medido: sem esta checagem, uma
    # segunda execução consecutiva refazia "Installing dependencies" e "Building
    # the hermes command and apps" — o build inteiro do TUI e da web UI, que é a
    # parte cara, em uma máquina que já está no lugar.
    #
    # Comparar o commit local com `origin/main` depois de um `fetch` é o que faz o
    # "já está na latest" sem fixar versão nenhuma. Se o `fetch` falhar — sem rede,
    # por exemplo — a comparação não acontece e o instalador roda, que é o
    # desfecho seguro: instalar não é o que quebra, ficar desatualizado é.
    if [ -d "$HERMES_CLI_DIR/.git" ] && command -v git &> /dev/null; then
        if git -C "$HERMES_CLI_DIR" fetch -q origin main 2>/dev/null; then
            local _head _main
            _head="$(git -C "$HERMES_CLI_DIR" rev-parse HEAD 2>/dev/null)"
            _main="$(git -C "$HERMES_CLI_DIR" rev-parse origin/main 2>/dev/null)"
            if [ -n "$_head" ] && [ "$_head" = "$_main" ]; then
                echo -e "${YELLOW}Hermes já no main; pulando o instalador.${NC}"
                local v0
                v0="$("$HOME/.local/bin/hermes" --version 2>&1 | head -1)"
                case "$v0" in
                    *Hermes*) echo -e "${GREEN}✓ CLI do Hermes: $v0${NC}" ;;
                    *) echo -e "${YELLOW}A CLI não respondeu: ${v0:-sem saída}${NC}" >&2; return 1 ;;
                esac
                echo -e "${GREEN}  Home da CLI: ~/.hermes · Home do dashboard: ~/Developer/.hermes (não compartilham)${NC}"
                return 0
            fi
            echo -e "${BLUE}Instalando ou atualizando o Hermes (o main mudou)…${NC}"
        else
            echo -e "${BLUE}Instalando ou atualizando o Hermes pelo instalador oficial…${NC}"
            echo -e "${YELLOW}  Não consegui buscar o main; o instalador roda mesmo assim.${NC}" >&2
        fi
    else
        echo -e "${BLUE}Instalando o Hermes pelo instalador oficial…${NC}"
    fi
    if [ -x "$HOME/.local/bin/hermes" ] && [ -d "$HERMES_CLI_DIR/.git" ]; then
        echo -e "${BLUE}  (já há uma instalação; o instalador faz o update para a main)${NC}"
    fi

    # O comando DOCUMENTADO, sem uma palavra trocada. A única flag é o
    # `--non-interactive`, e ela é OBRIGATÓRIA:
    #
    #   --non-interactive  Os estágios `setup` e `gateway` do instalador leem
    #     /dev/tty e só se pulam quando /dev/tty NÃO abre. O setup.sh roda sob
    #     pty, então /dev/tty abre, o instalador espera o assistente e TRAVA PARA
    #     SEMPRE. Sem a flag este passo não termina. (Medido: o instalador
    #     documenta `--skip-setup` como o mesmo efeito.)
    #
    # E o download do corepack, se houver, é prompt `[Y/n]` — o mesmo que trava
    # o build do OpenDesign, tratado lá com COREPACK_ENABLE_DOWNLOAD_PROMPT.
    curl -fsSL "$HERMES_INSTALL_URL" \
        | COREPACK_ENABLE_DOWNLOAD_PROMPT=0 bash -s -- --non-interactive || {
        echo -e "${YELLOW}O instalador do Hermes falhou; a saída está acima.${NC}" >&2
        return 1
    }

    # O instalador publica o launcher em `~/.local/bin` pela propria
    # `source_completion`. O symlink que este script montava apontava para o clone
    # antigo em `~/Hermes-Agent`, que o caminho oficial nao usa — entao ele saiu.
    #
    # O instalador tambem tentaria anexar uma linha de PATH no `~/.zshrc`. Ele
    # NAO vai: o proprio `append_shell_path` guarda com
    # `^[[:space:]]*([^#[:space:]].*)?PATH=.*\.local/bin` (medido no install.sh,
    # linha 679) e a linha 11 do zshrc versionado ja casa com ela. O detalhe
    # importa porque `~/.zshrc` aqui e symlink para o arquivo do repositorio: sem
    # essa guarda, o instalador escreveria DENTRO do arquivo versionado.
    mkdir -p "$HOME/.local/bin"

    # Verificar por ESTADO: o link existe e responde. `command -v` nao basta,
    # porque o launcher importa o pacote e um Python errado passa pelo link.
    local v
    v="$("$HOME/.local/bin/hermes" --version 2>&1 | head -1)"
    case "$v" in
        *Hermes*) echo -e "${GREEN}✓ CLI do Hermes: $v${NC}" ;;
        *)
            echo -e "${YELLOW}A CLI do Hermes não respondeu: ${v:-sem saída}${NC}" >&2
            return 1
            ;;
    esac
    echo -e "${GREEN}  Home da CLI: ~/.hermes · Home do dashboard: ~/Developer/.hermes (não compartilham)${NC}"

    # Dois homes, e estao registrados porque e a pegadinha que vem depois: o
    # nativo e ~/.hermes, o container e ~/Developer/.hermes (do subuid).
    if [ -f "$HOME/.hermes/auth.json" ]; then
        local providers
        providers="$(python3 -c "
import json
try: print(len(json.load(open('$HOME/.hermes/auth.json')).get('providers') or []))
except Exception: print('?')" 2>/dev/null)"
        if [ "$providers" = "0" ]; then
            echo -e "${YELLOW}  A CLI está sem provider: conecta e não gera. Defina com: hermes model${NC}"
        fi
    fi
    return 0
}

# Declara e sobe o dashboard do Hermes como SERVICO de usuario. Sem container e
# Publica o dashboard do Hermes na tailnet, em :8445.
#
# A MEDICAO QUE MOTIVOU ESTA FUNCAO: o modulo declarava e ligava o dashboard, e a
# unit recebia `HERMES_DASHBOARD_PUBLIC_URL=https://<dns>:8445` -- e NADA
# publicava essa porta. O `HERMES_SERVE_PORT` aparecia no arquivo de senha e na
# unit, e em nenhum `tailscale serve`. Resultado: o dashboard respondia no IP da
# tailnet, e o link que ele mesmo anunciava nao existia.
#
# Idempotente por comparacao de texto, como os outros dois, e revalida depois de
# agir: o formato de `tailscale serve status` muda entre versoes do Tailscale.
#
# O guarda aqui e POR PORTA, e nao "ja existe alguma coisa publicada". Os outros
# dois publicam o mesmo host, e um guarda global faria o segundo se recusar a
# publicar por causa do primeiro.
setup_hermes_serve() {
    local dns ip target
    dns="$(_tailnet_dnsname)"
    ip="$(tailscale ip -4 2>/dev/null | head -1)"
    [ -n "$ip" ] || { echo -e "${YELLOW}Sem IP de tailnet; pulei a publicação do Hermes.${NC}" >&2; return 1; }
    # O dashboard escuta no IP DA TAILNET, e nao em loopback: e o host interno
    # da UI do Hermes, e o `serve` e o proxy. Medido nesta VM: `127.0.0.1:9119`
    # recusa, e `<ip-tailnet>:9119` devolve 200 em /login.
    target="$ip:$HERMES_DASH_PORT"

    if ! command -v tailscale &> /dev/null; then
        echo -e "${YELLOW}Tailscale ausente; pulei a publicação do Hermes.${NC}" >&2
        return 1
    fi

    local current
    current="$(tailscale serve status 2>/dev/null || true)"

    if printf '%s' "$current" | grep -qF -- "$target"; then
        echo -e "${GREEN}✓ Hermes já publicado na tailnet (:$HERMES_SERVE_PORT → $target).${NC}"
        return 0
    fi
    # So reclama se a MESMA porta ja estiver ocupada por outra coisa.
    if printf '%s' "$current" | grep -qF ":$HERMES_SERVE_PORT"; then
        echo -e "${YELLOW}A porta :$HERMES_SERVE_PORT já está publicada por outro serviço:${NC}"
        printf '%s\n' "$current" | sed 's/^/    /'
        echo -e "${YELLOW}  Não sobrescrevi.${NC}" >&2
        return 1
    fi

    if ! sudo tailscale serve --bg --https="$HERMES_SERVE_PORT" "http://$target"; then
        echo -e "${YELLOW}Não consegui publicar o Hermes na tailnet.${NC}" >&2
        echo -e "${YELLOW}  Manualmente: sudo tailscale serve --bg --https=$HERMES_SERVE_PORT http://$target${NC}" >&2
        return 1
    fi

    # Revalidar depois de agir: se a premissa de formato da linha acima estiver
    # errada, isto mostra o estado real em vez de o script afirmar sucesso.
    local after
    after="$(tailscale serve status 2>/dev/null || true)"
    if printf '%s' "$after" | grep -qF -- "$target"; then
        echo -e "${GREEN}✓ Hermes publicado na tailnet (:$HERMES_SERVE_PORT → $target).${NC}"
        echo -e "${GREEN}  https://$dns:$HERMES_SERVE_PORT${NC}"
        return 0
    fi
    echo -e "${YELLOW}  O 'serve' aceitou o comando, mas o alvo não aparece no status:${NC}" >&2
    printf '%s\n' "$after" | sed 's/^/    /' >&2
    return 1
}

# sem sudo.
setup_hermes_dashboard() {
    local dns ip
    dns="$(_tailnet_dnsname)"
    ip="$(tailscale ip -4 2>/dev/null | head -1)"
    if [ -z "$dns" ] || [ -z "$ip" ]; then
        echo -e "${YELLOW}Sem DNSName ou IP de tailnet; pulei o dashboard do Hermes.${NC}" >&2
        return 1
    fi
    if [ ! -x "$HOME/.local/bin/hermes" ]; then
        echo -e "${YELLOW}CLI do Hermes ausente; rode o módulo hermes-cli primeiro.${NC}" >&2
        return 1
    fi

    # A senha: hash scrypt, e NUNCA texto puro no config. O `hermes config set`
    # tem dois defeitos aqui, ambos medidos:
    #   1. grava `password` EM CLARO e mascara a saida como *** — o *** e
    #      cosmético, e o arquivo fica 644;
    #   2. gravar `password_hash` NAO remove o `password` que ja existia: os dois
    #      convivem, e a precedencia faz o texto claro ganhar.
    # Entao a ordem e: grava o hash, e remove a chave em claro. E o hash sai do
    # codigo do proprio Hermes, rodado com o PYTHONPATH montado a partir do cache
    # do uv — que e onde o pm guarda os wheels descompactados, ja que ele nao cria
    # venv nenhum.
    local hash
    hash="$(_hermes_scrypt_hash "$HERMES_DASH_PASSWORD")"
    if [ -z "$hash" ]; then
        echo -e "${YELLOW}Não consegui gerar o hash scrypt; pulei o dashboard.${NC}" >&2
        return 1
    fi
    "$HOME/.local/bin/hermes" config set dashboard.basic_auth.username "$HERMES_DASH_USER" >/dev/null
    "$HOME/.local/bin/hermes" config set dashboard.basic_auth.password_hash "$hash" >/dev/null
    chmod 600 "$HOME/.hermes/config.yaml" 2>/dev/null || true
    _hermes_drop_plaintext_password "$HOME/.hermes/config.yaml"

    # O texto claro da senha vai para um arquivo 600 do usuario, e é o unico lugar
    # onde ele existe: o `config.yaml` recebe so o hash, e o `***` que o
    # `hermes config set` imprime é cosmético. Sem este arquivo a senha é
    # irrecuperável — e o `HERMES_PW_FILE` era declarado aqui e nunca lido, que é
    # como o arquivo existia na VM sem ter sido o script a cria-lo.
    #
    # O arquivo é ESCREITO INTEIRO, com URL, usuário e senha, e não apenas a senha
    # numa linha. A versão que estava na VM foi montada à mão e carregava também
    # avisos operacionais; um `printf` de uma linha só apagaria essa informação sem
    # substituí-la por nada. Gerar o arquivo completo faz dele um derivado do
    # estado real — a URL vem do DNSName do nó, não de um texto decorado — e faz
    # este trecho ser a fonte da verdade em vez de um artefato solto.
    if [ -n "$HERMES_DASH_PASSWORD" ]; then
        ( umask 077; mkdir -p "$(dirname "$HERMES_PW_FILE")" )
        {
            printf '# Dashboard do Hermes — gerado por setup.sh. Não versionar.\n'
            printf '\n'
            printf 'URL      https://%s:%s\n' "$(_tailnet_dnsname)" "$HERMES_SERVE_PORT"
            printf 'usuario  %s\n' "$HERMES_DASH_USER"
            printf 'senha    %s\n' "$HERMES_DASH_PASSWORD"
            printf '\n'
            printf 'O config do Hermes guarda só o hash scrypt. Este arquivo é a\n'
            printf 'única cópia do texto claro; a senha padrão é a mesma que o nome\n'
            printf 'do serviço, então é adivinhável por quem conheça a convenção.\n'
        } > "$HERMES_PW_FILE"
        chmod 600 "$HERMES_PW_FILE"
        echo -e "${GREEN}  Senha do dashboard: $HERMES_PW_FILE (600).${NC}"
    fi

    if grep -qE '^[[:space:]]+password:[[:space:]]' "$HOME/.hermes/config.yaml" 2>/dev/null; then
        echo -e "${YELLOW}Ainda há senha em claro no config do Hermes.${NC}" >&2
        return 1
    fi

    # here-doc com aspas, e nao string com "aspas duplas": o comentario do
    # --skip-build abaixo tem aspas duplas, e isso FECHA a string do shell — o
    # resto da unit vira comando e o ExecStart nunca chega ao arquivo. Foi
    # exatamente o que aconteceu, e o `systemctl start` falhava sem dizer por que.
    # `|| true` e obrigatorio: `read -d ''` procura um byte NUL, nao o acha, e
    # devolve 1 no EOF. Com `set -e` na linha 2 do script, isso ABORTA a
    # execucao — e como aborta no meio de uma funcao, o chamador so ve a
    # unit faltando, sem nenhuma mensagem. Medido: este modulo nunca
    # completou em nenhuma maquina; a unit do dashboard so existia porque
    # tinha sido escrita a mao. O mesmo vale para a unit do OpenDesign.
    read -r -d '' expected <<UNIT_EOF || true
[Unit]
Description=Dashboard do Hermes (nativo, gerado por dotfiles-fedora)
After=network-online.target

[Service]
Type=simple
# O diretorio de trabalho e a raiz do clone do instalador OFICIAL. Antes
# apontava para ~/Hermes-Agent, que era a arvore do caminho montado a mao e nao
# existe mais desde que o modulo hermes-cli usa o instalador oficial.
# SEM CRASE NESTE COMENTARIO: o here-doc deste bloco nao tem aspas, e num
# here-doc sem aspas a CRASE e substituicao de comando. Um comentario com
# crase vira execucao — e o sintoma e o shell tentando rodar a palavra do
# comentario, nao um erro de sintaxe. Medido: a unit falhava com
# "hermes-cli: command not found" e "~/Hermes-Agent: No such file or directory".
WorkingDirectory=$HERMES_CLI_DIR
Environment=HERMES_DASHBOARD_PUBLIC_URL=https://$dns:$HERMES_SERVE_PORT
Environment=PATH=$HOME/.local/bin:$HOME/.hermes/tools/bin:/usr/local/bin:/usr/bin:/bin
# --skip-build porque o web_dist ja foi construido no primeiro start. Sem ele, o
# dashboard refaz um "recovery build" da UI a cada boot, e a espera nao parece
# espera.
ExecStart=$HOME/.local/bin/hermes dashboard --host $ip --port $HERMES_DASH_PORT --skip-build --no-open
Restart=always
RestartSec=5
# Os tres codigos de saida, com os nomes de sysexits.h. Sao os mesmos que a unit
# do gateway (hermes gateway install) escreve, e o Hermes avisa quando a do
# dashboard nao os tem. Medido nesta maquina: com a porta ocupada, o processo
# devolve 75 e sai em 2,3s.
#   75 = EX_TEMPFAIL — drenagem graciosa; o systemd DEVE reiniciar
#   78 = EX_CONFIG   — recusa deliberada (--port que o dono nao pode servir);
#                      o systemd NAO deve reiniciar, senao e laco infinito sem
#                      nada escutando na porta de entrada
# Sem o 78, um 78 sob Restart=always vira crash-loop. Sem o 75 e o
# SuccessExitStatus, um 75 parece sucesso e o servico nao volta.
SuccessExitStatus=75
RestartForceExitStatus=75
RestartPreventExitStatus=78

[Install]
WantedBy=default.target
UNIT_EOF

    ( umask 077; mkdir -p "$(dirname "$HERMES_DASH_UNIT")" )
    local _atual=""
    [ -f "$HERMES_DASH_UNIT" ] && _atual="$(cat "$HERMES_DASH_UNIT")"
    if [ "$_atual" != "$expected" ]; then
        ( umask 077; printf '%s\n' "$expected" > "$HERMES_DASH_UNIT" )
        chmod 600 "$HERMES_DASH_UNIT"
        echo -e "${GREEN}✓ Unit do dashboard criada.${NC}"
    fi

    # Quem estiver escutando, sai antes — e pelo PID que o ss mostra, nao por
    # `pkill -f "hermes dashboard"`, que nao casa com o cmdline real.
    local pid
    for pid in $(_hermes_dash_pids); do
        kill "$pid" 2>/dev/null || true
    done
    sleep 3

    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable hermes-dashboard.service >/dev/null 2>&1 || true
    if ! loginctl show-user "$(id -un)" 2>/dev/null | grep -qi "Linger=yes"; then
        echo -e "${YELLOW}Linger desligado: o dashboard não sobe no boot.${NC}" >&2
        echo -e "${YELLOW}  Habilite com: sudo loginctl enable-linger $(id -un)${NC}" >&2
    fi
    systemctl --user restart hermes-dashboard.service >/dev/null 2>&1 || {
        echo -e "${YELLOW}Não consegui subir o dashboard.${NC}" >&2
        return 1
    }

    local i
    for i in $(seq 1 30); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://$ip:$HERMES_DASH_PORT/" 2>/dev/null)" != "000" ] && break
        sleep 5
    done

    # Verificar por ESTADO, e o estado que decide sao DUIS: o /login tem de
    # responder 200 (e nao 400), porque 400 e o sinal de public_url com hostname
    # vazio; e o portao tem de segurar, provado por um 401 na API sem cookie.
    local login api
    login="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://$ip:$HERMES_DASH_PORT/login" 2>/dev/null)"
    api="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://$ip:$HERMES_DASH_PORT/api/sessions" 2>/dev/null)"

    if [ "$login" = "400" ]; then
        echo -e "${YELLOW}/login respondeu 400: o public_url está sem hostname.${NC}" >&2
        echo -e "${YELLOW}  O nome vem de 'tailscale status --json' (Self.DNSName), via${NC}" >&2
        echo -e "${YELLOW}  _tailnet_dnsname. 'tailscale dnsname' nao existe nesta versao.${NC}" >&2
        return 1
    fi
    if [ "$login" = "200" ]; then
        echo -e "${GREEN}✓ Página de login servida (200).${NC}"
    else
        echo -e "${YELLOW}/login respondeu $login, e o esperado era 200.${NC}" >&2
    fi
    if [ "$api" = "401" ]; then
        echo -e "${GREEN}✓ Portão de pé: a API devolve 401 sem cookie.${NC}"
    else
        echo -e "${YELLOW}A API devolveu $api sem cookie, e o esperado era 401.${NC}" >&2
        echo -e "${YELLOW}  O portão depende do BIND, nao do public_url: em loopback${NC}" >&2
        echo -e "${YELLOW}  o should_require_auth() devolve False e nao ha login nenhum.${NC}" >&2
        return 1
    fi
    unset HERMES_DASH_PASSWORD
    echo -e "${GREEN}✓ Dashboard nativo em $ip:$HERMES_DASH_PORT.${NC}"

    # Publicar NAO é opcional aqui, e é a última coisa que faltava: a unit acima
    # recebe `HERMES_DASHBOARD_PUBLIC_URL=https://<dns>:8445`, e sem o `serve` esse
    # link não existe — o dashboard so responderia no IP cru da tailnet, sem TLS.
    #
    # A falha da publicação não derruba o dashboard: um dashboard no ar e
    # inacessível pelo link ainda é melhor do que nenhum dashboard, e o motivo da
    # falha sai na saída.
    setup_hermes_serve \
        || echo -e "${YELLOW}O dashboard está no ar mas não foi publicado na tailnet.${NC}" >&2
    return 0
}



# Gera o hash scrypt usando o codigo do PROPRIO Hermes, que e a unica forma de o
# hash casar com o que o dashboard verifica depois.
#
# A invocacao mudou com o instalador oficial, e a antiga aponta para dois
# caminhos que nao existem mais. Medido numa VM limpa:
#
#   - `~/Hermes-Agent` era a arvore do clone no caminho MONTADO A MAO. O
#     instalador oficial deixa em `~/.hermes/hermes-agent`.
#   - o `PYTHONPATH` era uma lista de `~/.hermes/cache/uv/archive-v0/<hash>/`,
#     com `find | head -1` — e esse cache tem 106 entradas, das quais a primeira
#     em ordem alfabetica e `referencing-0.37.0`, um pacote sem relacao nenhuma.
#     Apontar para um archive arbitrario e esperar que o import funcione e a
#     definicao de deducao em vez de medicao.
#
# O que funciona, e foi medido: o `python3` do SISTEMA com o `PYTHONPATH` apontado
# para a raiz do clone. O modulo `hash_password` so precisa de `hashlib` e
# `secrets`, que sao da stdlib, entao ele importa sem nenhuma dependencia
# instalada. O `python` dos tools do Hermes, por contraste, NAO serve: medido
# `ModuleNotFoundError: No module named 'httpx'`.
#
# A forma segue o que o proprio docstring da funcao prescreve:
#
#   python -c "from plugins.dashboard_auth.basic import hash_password; print(...)"
#
# E `basic` e um PACOTE (`__init__.py`), nao um `basic.py` — o que o caminho de
# import ja refletia corretamente, e o que fez o erro parecer outro.
#
# O `[ -z "$pp" ] && return 0` antigo devolvia SUCESSO quando nao achava nada, e o
# chamador tratava hash vazio como falha. "Nao achei" nao e "deu certo": aqui a
# ausencia sai como falha, e o chamador ja diz o que fazer.
_hermes_scrypt_hash() {
    local pw="$1"
    [ -d "$HERMES_CLI_DIR/plugins" ] || return 1
    PYTHONPATH="$HERMES_CLI_DIR" python3 -c "
import sys
from plugins.dashboard_auth.basic import hash_password
print(hash_password(sys.argv[1]))" "$pw" 2>/dev/null | tail -1
}

# Remove a chave `password` do bloco basic_auth, deixando o password_hash. O
# `config set` nao faz isso, e sem isso a precedencia do plugin faz o texto
# claro ganhar sobre o hash que acabamos de gravar.
_hermes_drop_plaintext_password() {
    local f="$1"
    [ -f "$f" ] || return 0
    python3 - "$f" <<'PYEOF' 2>/dev/null
import io, re, sys
p = sys.argv[1]
lines = io.open(p, encoding="utf-8").read().split("
")
out, dentro = [], False
for l in lines:
    if re.match(r"^\s*basic_auth:\s*$", l):
        dentro = True
        out.append(l)
        continue
    if dentro and re.match(r"^\S", l):
        dentro = False
    if dentro and re.match(r"^\s+password:\s", l):
        continue
    out.append(l)
io.open(p, "w", encoding="utf-8").write("
".join(out))
PYEOF
}

# O dashboard do Hermes — o container em :9119, publicado em :8445 — foi
# REMOVIDO por decisão de projeto: a máquina fica só com a CLI nativa
# (`setup_hermes_cli`). O que motivou, medido:
#
#   A CLI nativa é a única que roda. O binário `opencode` e o `agy` que o
#   OpenDesign usa como agentes são ELF glibc, e o container do OpenDesign é
#   Alpine; dentro dele nenhuma CLI do host executa. A dashboard em container não
#   compartilhava estado com a CLI de qualquer jeito — `~/Developer/.hermes` contra
#   `~/.hermes` — então configurar provider num não aparecia no outro.
#
# O estado do dashboard foi PRESERVADO, não apagado: `~/Developer/.hermes` com
# 7138 arquivos e 919 MB, mais uma cópia em `~/Developer/.hermes-backup-*`. Os dois
# são do subuid e só se leem de dentro de um container, que é o mesmo custo de
# antes — e vale saber que um backup nesse regime só se restaura por container.
#
# Para trazer de volta, o que faltaria reverter: o `podman run` com o digest
# pinado, o `:Z` no bind, e `sudo tailscale serve --bg --https=8445`.

# A escolha da pergunta e o que decide qual dos dois modulos roda. Um `if/else`
# dentro de um modulo so seria uma mentira: os dois procedimentos nao tem
# pre-requisito em comum, e a consequencia de cada um e diferente.
# ⚠️ O valor do modo é `nativo`, em português, e é isso que a pergunta produz
# (medido: o `case` da pergunta aceita `nativo | container`, e o `--yes` escreve
# `nativo` na mão). Aqui comparava com `native`, em inglês — que nunca casa.
#
# A falha era SILENCIOSA por construção: `|| return 0` trata "não é o meu modo" como
# sucesso, e o modo errado também caía nele. O despacho do fluxo principal chamava
# esta função, ela devolvia 0 sem fazer nada, e o `|| echo` do despacho nunca
# reclamava. Medido: o módulo imprimia a linha `==> OpenDesign` e saía, sem clone,
# sem build, sem unit — e sem uma única mensagem.
#
# Um guarda de modo que erra a grafia é o pior tipo de bug: ele não falha, ele
# finge que não é o momento dele.
setup_open_design() {
    [ "$OPENDESIGN_MODE" = "nativo" ] || return 0
    _setup_open_design_native
}

setup_open_design_container() {
    [ "$OPENDESIGN_MODE" = "container" ] || return 0
    _setup_open_design_container
}

# Um por maquina. Os dois disputam a MESMA porta interna, e a consequencia de
# deixar isso acontecer nao e um erro visivel: o segundo sobe, o primeiro
# continua com o processo no ar mas sem escutar, e a publicacao continua
# respondendo pelo que tinha ficado primeiro. Recusar aqui deixa o conflito explicito.
_open_design_exclusive() {
    local outro
    # O mesmo cuidado do dispatcher acima: o valor do modo é `nativo`.
    if [ "$OPENDESIGN_MODE" = "nativo" ]; then
        outro="container"
        podman container exists open-design 2>/dev/null && {
            echo -e "${YELLOW}Ja existe um container do OpenDesign nesta maquina.${NC}" >&2
            echo -e "${YELLOW}  Os dois modos disputam a porta $OPENDESIGN_PORT. Remova um:${NC}" >&2
            echo -e "${YELLOW}    podman rm -f open-design${NC}" >&2
            return 1
        }
    else
        outro="nativo"
        if [ -f "$OPENDESIGN_DEPLOY_DIR/dist/cli.js" ] && \
           curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$OPENDESIGN_PORT/api/health" 2>/dev/null; then
            # Desligar, e nao recusar. O script e o dono da unit — ele a cria e a
            # habilita — e o modo novo passou a ser o container, entao manter o
            # nativo no ar e manter uma porta ocupada por um servico que ninguem
            # pediu. Recusar aqui tornava o default novo num beco: numa maquina que
            # ja rodou o nativo, todo run futuro falhava neste ponto.
            #
            # Desabilitar tambem, e nao so parar: `enabled` sobrevive a um reboot, e
            # um nativo que volta sozinho no proximo boot e a mesma disputa de
            # novo, sem ninguem perto para ver.
            #
            # A unidade fica no disco. Apagar seria perder o que o script escreveu
            # e, com ele, o caminho de volta para o modo nativo — que continua
            # valendo e e a escolha de quem prefere as CLIs do host disponiveis
            # dentro. Parar e desabilitar remove o conflito e preserva a opcao.
            echo -e "${YELLOW}Ja existe um OpenDesign nativo rodando. Desligando: os dois modos${NC}" >&2
            echo -e "${YELLOW}  disputam a porta $OPENDESIGN_PORT, e o modo desta maquina agora e o container.${NC}" >&2
            if systemctl --user disable --now open-design.service; then
                echo -e "${YELLOW}  ✓ nativo parado e desabilitado. A unit continua no disco, caso queira${NC}" >&2
                echo -e "${YELLOW}    o modo nativo: 'systemctl --user enable --now open-design'.${NC}" >&2
                echo -e "${YELLOW}  O serve em :8444 aponta para a porta do container agora, entao o tailnet${NC}" >&2
                echo -e "${YELLOW}  deixa de responder ate o container subir. Isso e o esperado neste intervalo.${NC}" >&2
            else
                # Aqui nao ha o que recuperar: sem o nativo desligado, a porta
                # continua ocupada e o container nao sobe. Dizer o que deu errado
                # e melhor que devolver sucesso com o modulo pulado.
                echo -e "${RED}  ✗ nao consegui desligar o nativo. O container NAO vai subir nesta maquina.${NC}" >&2
                echo -e "${RED}    systemctl --user disable --now open-design.service${NC}" >&2
                return 1
            fi
        fi
    fi
    return 0
}

# ------------------------------------------------------------------ nativo
# Publica o OpenDesign nativo na tailnet, em :8444.
#
# O alvo é o LOOPBACK, e não o IP da tailnet — e isso não é preferência. A
# documentação do projeto exige: "connector endpoints (Composio, GitHub OAuth)
# also require the daemon to receive requests over loopback", e o comentário do
# próprio daemon diz que "the loopback bypass exists for the localhost desktop UI
# which has no proxy in the path". Publicar direto no IP da tailnet inverteria
# os dois efeitos: a ESCRITA passaria a levar 403 (o carve-out é por peer de
# loopback) e a LEITURA passaria a exigir o token, que está desligado.
#
# Idempotente por comparação de texto, revalidando depois de agir, e com guarda
# POR PORTA — pelos mesmos motivos do `setup_hermes_serve`, e porque os três
# serviços vivem no mesmo host: uma guarda global faria o segundo se recusar por
# causa do primeiro.
setup_open_design_serve() {
    local dns target
    dns="$(_tailnet_dnsname)"
    target="127.0.0.1:$OPENDESIGN_PORT"

    if ! command -v tailscale &> /dev/null; then
        echo -e "${YELLOW}Tailscale ausente; pulei a publicação do OpenDesign.${NC}" >&2
        return 1
    fi

    local current
    current="$(tailscale serve status 2>/dev/null || true)"

    if printf '%s' "$current" | grep -qF -- "$target"; then
        echo -e "${GREEN}✓ OpenDesign já publicado na tailnet (:$OPENDESIGN_SERVE_PORT → $target).${NC}"
        return 0
    fi
    if printf '%s' "$current" | grep -qF ":$OPENDESIGN_SERVE_PORT"; then
        echo -e "${YELLOW}A porta :$OPENDESIGN_SERVE_PORT já está publicada por outro serviço:${NC}"
        printf '%s\n' "$current" | sed 's/^/    /'
        echo -e "${YELLOW}  Não sobrescrevi.${NC}" >&2
        return 1
    fi

    if ! sudo tailscale serve --bg --https="$OPENDESIGN_SERVE_PORT" "http://$target"; then
        echo -e "${YELLOW}Não consegui publicar o OpenDesign na tailnet.${NC}" >&2
        echo -e "${YELLOW}  Manualmente: sudo tailscale serve --bg --https=$OPENDESIGN_SERVE_PORT http://$target${NC}" >&2
        return 1
    fi

    local after
    after="$(tailscale serve status 2>/dev/null || true)"
    if printf '%s' "$after" | grep -qF -- "$target"; then
        echo -e "${GREEN}✓ OpenDesign publicado na tailnet (:$OPENDESIGN_SERVE_PORT → $target).${NC}"
        echo -e "${GREEN}  https://$dns:$OPENDESIGN_SERVE_PORT${NC}"
        return 0
    fi
    echo -e "${YELLOW}  O 'serve' aceitou o comando, mas o alvo não aparece no status:${NC}" >&2
    printf '%s\n' "$after" | sed 's/^/    /' >&2
    return 1
}

# O clone do OpenDesign, compartilhado pelos dois modos.
#
# Ele vivia dentro de `_setup_open_design_native`, e o modo container nao tinha
# clone nenhum: comecava em `local D="$OPENDESIGN_SRC/deploy"` e seguia, como se o
# repositorio ja estivesse na mao. Numa maquina nova ele nao esta, e o modulo
# falhava com "Falta .../deploy/docker-compose.yml" — que aponta para um arquivo
# e nao para a ausencia do clone que o produziria.
#
# Os dois modos precisam do repositorio: o nativo compila de fonte, e o container
# le o `deploy/docker-compose.yml` de dentro dele. O que e do nativo sozinho e o
# `pnpm install` do build, e esse continua onde estava.
_garantir_clone_open_design() {
    if [ -d "$OPENDESIGN_SRC/.git" ]; then
        return 0
    fi
    echo -e "${BLUE}  Clonando o OpenDesign (modo $OPENDESIGN_MODE)…${NC}"
    mkdir -p "$(dirname "$OPENDESIGN_SRC")"
    if ! git clone -q --depth 1 "$OPENDESIGN_REPO_URL" "$OPENDESIGN_SRC"; then
        # `rm -rf` de um clone parcial: sem isso o proximo run acha o diretorio e
        # pula o clone, e falha depois num `pnpm` que nao existe — o sintoma de um
        # clone malformado no lugar do sintoma do clone que falhou.
        rm -rf "$OPENDESIGN_SRC"
        echo -e "${YELLOW}Não consegui clonar o OpenDesign de $OPENDESIGN_REPO_URL.${NC}" >&2
        return 1
    fi
    return 0
}

_setup_open_design_native() {
    _open_design_exclusive || return 1

    # build deps. libatomic nao e opcional e nao vem no Fedora: sem ela o node
    # pinado do pnpm morre com "error while loading shared libraries" — a mesma
    # dependencia que o install do Hermes tambem exige.
    if [ ! -e /usr/lib64/libatomic.so.1 ]; then
        echo -e "${YELLOW}Falta a libatomic, que o build precisa.${NC}" >&2
        echo -e "${YELLOW}  Instale com: sudo dnf install -y libatomic${NC}" >&2
        return 1
    fi

    # O node vem do mise e o pnpm do corepack; nenhum dos dois esta no PATH de
    # uma sessao nao interativa, entao o PATH e montado a mao e nao esperado.
    #
    # O caminho NAO e fixado numa versao. Antes era `.../node/24.21.0/bin`, que e
    # um fato de UMA maquina e nao do repositorio: uma VM nova com outra patch
    # faria o script devolver 1 sem explicacao util. O mise grava o `current` como
    # link simbolico, entao e ele que diz qual node esta em uso.
    local nb="$HOME/.local/share/mise/installs/node/current/bin"
    [ -x "$nb/node" ] || {
        local _nb
        _nb=$(ls -1d "$HOME"/.local/share/mise/installs/node/*/bin 2>/dev/null | sort -V | tail -1)
        [ -n "$_nb" ] && [ -x "$_nb/node" ] && nb="$_nb"
    }
    [ -x "$nb/node" ] || { echo -e "${YELLOW}node do mise ausente; pulei o OpenDesign.${NC}" >&2; return 1; }
    export PATH="$nb:$HOME/.opencode/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
    # ⚠️ SEM ESTA VARIÁVEL O PASSO TRAVA. Medido: o `pnpm install` para e escreve
    #
    #     ! Corepack is about to download .../pnpm-10.33.2.tgz
    #     ? Do you want to continue? [Y/n]
    #
    # e espera. Num `setup.sh` não há ninguém para responder, então o módulo
    # ficaria pendurado até o próximo passo falhar por tempo. Foi o que aconteceu
    # na primeira execução na VM limpa: o run "terminou" sem instalar nada, e o
    # driver de pty do teste matou o processo esperando o Y/n.
    #
    # O download é a versão que o PRÓPRIO projeto declara, então a resposta é
    # conhecida antes de a pergunta existir. Ver o comentário abaixo, que corrige
    # uma afirmação errada sobre o corepack.
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    #
    # ESTE COMENTARIO ESTAVA ERRADO, e a correcao importa mais que o texto.
    #
    # Ele afirmava que o corepack NAO honrava o
    # `"packageManager": "pnpm@10.33.2"` do projeto, e que por isso quem mandava
    # era o `pnpm@latest` ativado aqui. **Medi no lugar errado**: rodei
    # `pnpm --version` e li 12.8.1 -- fora do repositorio. Dentro dele:
    #
    #     fora do repo:   12.8.1    (o default global que este passo ativa)
    #     dentro do repo: 10.33.2   (o que o projeto declara)
    #
    # O corepack honra a declaracao, e e por isso que o `pnpm install` PAROU
    # pedindo para baixar a 10.33.2, e nao a 12.x. Consequencias:
    #
    #   * o `corepack prepare pnpm@latest` abaixo e INUTIL para este projeto: o
    #     projeto fixa o dele, e a declaracao sempre ganha dentro do repo;
    #   * o "salto de major" que a decisao sobre acompanhar a ultima versao
    #     supunha NAO ACONTECE aqui. O build roda em 10.33.2, contra o lockfile
    #     `9.0`, como sempre;
    #   * o que de fato trava e o PROMPT de download do corepack, que pergunta
    #     `[Y/n]` na primeira vez e, num script, fica esperando para sempre.
    #
    # Por isso `COREPACK_ENABLE_DOWNLOAD_PROMPT=0` no export acima: o corepack
    # baixa a versao que o projeto declara sem perguntar. Um instalador nao pode
    # parar para perguntar algo cuja resposta ele ja sabe.
    #
    # O `prepare` fica, e serve ao que for rodado FORA do clone -- o `pnpm` de uso
    # pessoal da maquina. Ele nao afeta o build do OpenDesign, e o comentario acima
    # deixa isso explicito para quem for mexer aqui.
    # Nao ha pnpm global nesta maquina, e essa e a REGRA aplicada: o consumidor do
    # pnpm e o PROJETO, que declara a propria versao em
    # `"packageManager": "pnpm@10.33.2"`, e o corepack baixa a que for pedida.
    #
    # O que saiu, e por que:
    #
    #   * `corepack prepare pnpm@latest --activate` — INUTIL aqui. Medido: dentro
    #     do repo o corepack usa a versao declarada, nao a global. Ele so servia ao
    #     pnpm de uso pessoal, e esta VM nao tem uso pessoal.
    #   * `corepack enable pnpm` — tambem desnecessario. O `enable` cria o shim no
    #     PATH global para o pnpm de linha de comando; dentro do repo o corepack
    #     ja resolve a versao declarada sem shim nenhum.
    #
    # O que fica, e e o que de fato consome:
    #
    #   * `COREPACK_ENABLE_DOWNLOAD_PROMPT=0`, no export acima — o corepack
    #     pergunta `[Y/n]` na primeira vez, e num `setup.sh` nao ha quem responda.
    #     Sem esta variavel o modulo trava. A resposta e conhecida antes da
    #     pergunta, porque a versao e a que o projeto declara.
    #   * a checagem de que o pnpm EXISTE, com a versao que o BUILD vai usar, lida
    #     de dentro do repo — que e a informacao que importa, e nao a global.

    # `corepack enable` VOLTOU, e a razao de ter saidido esta escrita aqui para
    # ninguem tira de novo.
    #
    # A PR #72 removeu esta linha alegando que era desnecessaria, porque o
    # corepack resolve a versao declarada DENTRO do repo mesmo sem o shim global.
    # A medição estava certa. A conclusão estava errada, e o erro foi de método:
    # eu removi um passo DOCUMENTADO sem que nenhuma medição contradição a
    # documentação. E a documentação diz, no `CONTRIBUTING.md` do próprio projeto:
    #
    #     corepack enable           # selects the pinned pnpm from packageManager
    #
    # e repete em dois lugares do README: `corepack enable && pnpm install`.
    #
    # O que o passo faz tem nome no projeto: ele SELECIONA o pnpm fixado no
    # `packageManager`. Sem ele, a resolucao funciona por um caminho lateral do
    # corepack, que e o que a medicao encontrou -- e um caminho lateral nao e o
    # que a documentacao prescreve, mesmo que funcione hoje.
    #
    # A regra e a do inicio desta sessao: a documentacao da aplicacao vem antes da
    # medicao propria. Eu medi o objeto certo e ignorei o manual.
    #
    # O `corepack prepare pnpm@latest` NAO volta: ele fixava um pnpm global, e o
    # projeto declara o seu, entao o global nao e consumidor de nada aqui. Essa
    # parte da PR #72 continua certa.
    corepack enable pnpm >/dev/null 2>&1

    # A versao que o BUILD vai usar, lida de dentro do clone, que e onde o build
    # roda. Fora do repo o corepack devolve o default global — e foi exatamente
    # isso que a PR #73 corrigiu: o numero que este passo anunciava era o global,
    # enquanto o build usava o do projeto.
    local pnpm_ver
    pnpm_ver="$(cd "$OPENDESIGN_SRC" 2>/dev/null && pnpm --version 2>/dev/null | tail -1)"
    if [ -z "$pnpm_ver" ] && [ -d "$OPENDESIGN_SRC" ]; then
        echo -e "${YELLOW}Nao consegui o pnpm dentro do clone; o build do OpenDesign vai falhar.${NC}" >&2
        echo -e "${YELLOW}  Verifique: cd $OPENDESIGN_SRC && pnpm --version${NC}" >&2
        return 1
    fi
    echo -e "${BLUE}  pnpm em uso: $pnpm_ver${NC}"

    # O repo e clonado aqui, mas pela rotina compartilhada: o modo container
    # precisa dele tambem, e ele nao tinha clone nenhum.
    _garantir_clone_open_design || return 1

    if [ ! -d "$OPENDESIGN_SRC/node_modules" ]; then
        echo -e "${BLUE}Instalando as dependencias (a etapa longa, ~1,5 GB)…${NC}"
        ( cd "$OPENDESIGN_SRC" && pnpm install --frozen-lockfile ) || {
            echo -e "${YELLOW}O pnpm install falhou; a saida esta acima.${NC}" >&2; return 1; }
    fi

    # O build do web estoura o HEAP do V8, e nao a RAM: medido numa maquina com
    # 7,7 GiB de RAM e 7,7 GiB de swap LIVRES, com dmesg sem OOM, e o frame 2 da
    # pilha era `node::OOMErrorHandler`. Duas alavancas, porque o Next cria um
    # worker por CPU e cada um tem heap proprio.
    if [ ! -d "$OPENDESIGN_SRC/apps/web/out" ]; then
        echo -e "${BLUE}Compilando o daemon e o web…${NC}"
        ( cd "$OPENDESIGN_SRC" && pnpm --filter @open-design/daemon build ) || {
            echo -e "${YELLOW}O build do daemon falhou.${NC}" >&2; return 1; }
        ( cd "$OPENDESIGN_SRC/apps/web" && \
          NODE_OPTIONS=--max-old-space-size=3072 taskset -c 0-3 pnpm build ) || {
            echo -e "${YELLOW}O build do web falhou.${NC}" >&2; return 1; }
    fi

    # `pnpm deploy --legacy --prod` ACHATA o pacote na raiz do output. O daemon,
    # nao: `resolveProjectRoot` faz path.resolve(daemonDir, '../..') e assume
    # <projeto>/apps/daemon/dist, que e o layout do container. Achato, o
    # PROJECT_ROOT sobe um nivel a mais, o STATIC_DIR cai fora, e o sintoma e
    # `Cannot GET /` com a API respondendo normalmente.
    #
    # E o sintoma MASCARADO quando o token esta ligado: o portao de auth
    # responde 401 antes da rota, entao o 404 some. So `/` SEM credencial
    # revela — e por isso que a verificacao final e feita assim.
    if [ ! -f "$OPENDESIGN_DEPLOY_DIR/dist/cli.js" ]; then
        echo -e "${BLUE}Montando o arvore de deploy no layout que o daemon espera…${NC}"
        mkdir -p "$OPENDESIGN_ROOT/apps" || return 1
        rm -rf "$OPENDESIGN_DEPLOY_DIR"
        ( cd "$OPENDESIGN_SRC" && pnpm --filter @open-design/daemon deploy --legacy --prod \
            "$OPENDESIGN_DEPLOY_DIR" ) || {
            echo -e "${YELLOW}O deploy falhou.${NC}" >&2; return 1; }
    fi
    # O `out` do web e a propria saida do build, que ja vive em
    # `$OPENDESIGN_SRC/apps/web/out`. A raiz do build E o clone agora, entao os dois
    # caminhos sao o mesmo diretorio: criar o symlink aqui produziria
    # `apps/web/out -> apps/web/out`, um laco que o shell segue e nunca resolve.
    # O guard compara os dois e so cria o link quando sao diferentes, que e o caso
    # de uma raiz paralela — ver OPENDESIGN_ROOT.
    if [ "$OPENDESIGN_ROOT" != "$OPENDESIGN_SRC" ]; then
        mkdir -p "$OPENDESIGN_ROOT/apps/web"
        rm -f "$OPENDESIGN_ROOT/apps/web/out"
        ln -sfn "$OPENDESIGN_WEB_DIR" "$OPENDESIGN_ROOT/apps/web/out"
    fi

    # A origem que o browser vai usar: é a da publicação, e precisa estar na
    # lista de permitidos porque o navegador chama /api de outra origem que não
    # é a que serviu o HTML.
    #
    # Ela vem ANTES do .env porque o .env a consome, e a ordem aqui não é
    # detalhe. Com `set -u`, usar uma variável antes da linha que a define aborta
    # com "unbound variable" — e o modo silencioso desse script é o que dói: o
    # `.env` sai VAZIO, o daemon sobe com o auth ligado, e o sintoma aparece
    # muito depois, como um 401 que ninguém liga a esta linha.
    local origin="https://$(_tailnet_dnsname):$OPENDESIGN_SERVE_PORT"

    # O alvo é LOOPBACK, e não o IP da tailnet. É o que a documentação do projeto
    # exige: "connector endpoints (Composio, GitHub OAuth) also require the daemon
    # to receive requests over loopback", resolvido no Linux por
    # `docker-compose.linux.yml` com `network_mode: host`. O motivo está num
    # comentário do próprio daemon: "the loopback bypass exists for the localhost
    # desktop UI which has no proxy in the path".
    local ip="127.0.0.1"

    # O `.env` do nativo fica na raiz da árvore, não no deploy, porque é
    # configuração desta instalação e não da imagem.
    #
    # `OD_DISABLE_API_AUTH=1` é o escape hatch que o próprio
    # `deploy/.env.example` do projeto descreve: "deployments whose reverse proxy
    # already authenticates every request before it reaches the daemon". E
    # `docs/deployment/docker.md` condiciona: "only when that proxy already
    # authenticates every request and the daemon is not directly exposed". As duas
    # condições são verdadeiras aqui — o `tailscale serve` termina TLS e
    # autentica pela tailnet, e o daemon só escuta em loopback, então não há
    # caminho direto até ele.
    #
    # As duas decisões andam juntas, e a tabela é a consequência:
    #
    #   bind em loopback  -> a ESCRITA passa (peer de loopback) e a LEITURA
    #                        dispensa o token pelo mesmo carve-out
    #   bind na tailnet   -> a LEITURA exige token e a ESCRITA leva 403
    #
    # Não há modo nativo com os dois e o token como único portão. O container é o
    # único onde os dois funcionam, porque o gateway do podman conta como
    # loopback DENTRO dele.
    local envf="$OPENDESIGN_ROOT/.env"

    # Este `.env` é o SEGREDO exposto, e a medição é que decide onde a correção
    # vai. No clone do upstream:
    #
    #   deploy/.env   ->  coberto por `deploy/.gitignore:2:.env`   (o modo container)
    #   .env (raiz)   ->  NÃO coberto: `git check-ignore` não devolve nada, e o
    #                     `git status` mostra `?? .env`             (o modo nativo)
    #
    # A correção vai para `.git/info/exclude`, e não para o `.gitignore`: aquele é
    # estado local do clone, nunca é commitado, e não suja um arquivo que pertence
    # ao upstream e que o próximo `git pull` pode conflitar. É o jeito padrão de
    # ignorar um arquivo local num clone que não é seu.
    if git -C "$OPENDESIGN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        grep -qxF '/.env' "$OPENDESIGN_ROOT/.git/info/exclude" 2>/dev/null \
            || printf '/.env\n' >> "$OPENDESIGN_ROOT/.git/info/exclude"
    fi

    ( umask 077
      cat > "$envf" <<ODENV
OD_API_TOKEN=$OPENDESIGN_TOKEN
OD_ALLOWED_ORIGINS=$origin
OD_DISABLE_API_AUTH=1
OD_CODEX_SANDBOX=
ODENV
    )
    chmod 600 "$envf"

    # Pós-condição, verificada por ESTADO: o arquivo tem o token dentro, então ele
    # não pode aparecer como `?? .env` para o próximo `git add -A`. Confere com o
    # `check-ignore`, que pergunta ao git, e não com a linha que o script acabou de
    # imprimir — um log sem o efeito ao lado não prova que algo rodou.
    if git -C "$OPENDESIGN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        if git -C "$OPENDESIGN_ROOT" check-ignore -q .env; then
            echo -e "${GREEN}  ✓ o .env da raiz tem o token dentro e está coberto: não aparece no status.${NC}"
        else
            echo -e "${YELLOW}  AVISO: o .env da raiz tem o token dentro e NÃO está coberto.${NC}" >&2
            echo -e "${YELLOW}  Não dê commit com 'git add -A' neste clone antes de resolver.${NC}" >&2
        fi
    fi

    # A unit de usuario, e nao nohup: sem ela o processo nao volta depois de um
    # reboot, que e o mesmo buraco que a unit do opencode teve.
    # here-doc com aspas, e nao string com "aspas duplas": um comentario com
    # $' ou " ABRE e FECHA a string, e o resto da unit vira comando — foi o que
    # aconteceu aqui, e o ExecStart nunca chegava ao arquivo. Ver o mesmo
    # comentario em setup_hermes_dashboard.
    # `|| true` e obrigatorio: `read -d ''` procura um byte NUL, nao o acha, e
    # devolve 1 no EOF. Com `set -e` na linha 2 do script, isso ABORTA a
    # execucao — e como aborta no meio de uma funcao, o chamador so ve a
    # unit faltando, sem nenhuma mensagem. Medido: este modulo nunca
    # completou em nenhuma maquina; a unit do dashboard so existia porque
    # tinha sido escrita a mao. O mesmo vale para a unit do OpenDesign.
    read -r -d '' expected <<UNIT_EOF || true
[Unit]
Description=OpenDesign nativo (gerado por dotfiles-fedora)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$OPENDESIGN_ROOT
EnvironmentFile=$envf
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=192
Environment=HOME=$HOME
Environment=OD_BIND_HOST=$ip
Environment=OD_PORT=$OPENDESIGN_PORT
Environment=OD_WEB_PORT=$OPENDESIGN_PORT
Environment=OD_ALLOWED_ORIGINS=$origin
Environment=PATH=$nb:$HOME/.opencode/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$nb/node $OPENDESIGN_DEPLOY_DIR/dist/cli.js --no-open
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT_EOF

    ( umask 077; mkdir -p "$(dirname "$OPENDESIGN_UNIT")" )
    local _atual=""
    [ -f "$OPENDESIGN_UNIT" ] && _atual="$(cat "$OPENDESIGN_UNIT")"
    if [ "$_atual" != "$expected" ]; then
        ( umask 077; printf '%s\n' "$expected" > "$OPENDESIGN_UNIT" )
        chmod 600 "$OPENDESIGN_UNIT"
        echo -e "${GREEN}✓ Unit do OpenDesign criada.${NC}"
    fi
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable open-design.service >/dev/null 2>&1 || true
    if ! loginctl show-user "$(id -un)" 2>/dev/null | grep -qi "Linger=yes"; then
        echo -e "${YELLOW}Linger desligado: a unit nao sobe no boot.${NC}" >&2
        echo -e "${YELLOW}  Habilite com: sudo loginctl enable-linger $(id -un)${NC}" >&2
    fi

    local was_active=0
    systemctl --user is-active open-design.service >/dev/null 2>&1 && was_active=1
    if [ "$was_active" = "1" ]; then
        systemctl --user restart open-design.service >/dev/null 2>&1
    else
        systemctl --user start open-design.service >/dev/null 2>&1
    fi
    unset OPENDESIGN_TOKEN

    # Verificar por ESTADO, e o estado que decide e a UI, medida SEM credencial
    # e COM. Sem credencial tem de ser 401: e assim que se prova que o token
    # segura, e que nao ha carve-out em acao.
    local i up ui
    for i in $(seq 1 36); do
        up="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://$ip:$OPENDESIGN_PORT/api/health" 2>/dev/null)"
        [ "$up" != "000" ] && break
        sleep 5
    done
    ui="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$ip:$OPENDESIGN_PORT/" 2>/dev/null)"

    # O estado que decide agora e a UI servida, e nao o token: com
    # OD_DISABLE_API_AUTH=1 a API responde 200 sem credencial, por desenho. E o
    # 404 continua sendo o sinal de STATIC_DIR fora do lugar.
    if [ "$ui" = "200" ]; then
        echo -e "${GREEN}✓ UI servida (200) em loopback, com o auth delegado ao ${NC}"
        echo -e "${GREEN}  proxy: OD_DISABLE_API_AUTH=1 e a rota de escrita passa por peer de loopback.${NC}"
    else
        echo -e "${YELLOW}A UI respondeu $ui.${NC}" >&2
        if [ "$ui" = "404" ]; then
            echo -e "${YELLOW}  404 com a API de pe: o STATIC_DIR saiu do lugar. Confira o layout${NC}" >&2
            echo -e "${YELLOW}  $OPENDESIGN_ROOT/apps/web/out.${NC}" >&2
        fi
        return 1
    fi
    echo -e "${GREEN}✓ OpenDesign nativo em loopback:$OPENDESIGN_PORT.${NC}"
    # Publicar NÃO é opcional: sem o `serve`, o modo nativo fica alcançável só
    # pelo IP cru da tailnet, em HTTP sem TLS, e a rota de escrita perde o
    # carve-out de loopback. A falha da publicação não derruba o daemon, que já
    # está no ar e verificado; o motivo sai na saída.
    setup_open_design_serve \
        || echo -e "${YELLOW}O OpenDesign está no ar mas não foi publicado na tailnet.${NC}" >&2
    return 0
    return 0
}



# ---------------------------------------------------------------- container
_setup_open_design_container() {
    _open_design_exclusive || return 1

    if ! command -v podman &> /dev/null; then
        echo -e "${YELLOW}Podman ausente; pulei o OpenDesign.${NC}" >&2; return 1
    fi
    # Sem o provider de compose, `podman compose` responde "looking up compose
    # provider failed" — e nenhum dos dois modos de container existe.
    if ! podman compose version >/dev/null 2>&1; then
        echo -e "${YELLOW}Falta o provider de compose.${NC}" >&2
        echo -e "${YELLOW}  Instale com: sudo dnf install -y podman-compose${NC}" >&2
        return 1
    fi

    # O clone ANTES de qualquer uso dele. Este modo nao tinha clone algum, e o
    # `Falta .../docker-compose.yml` que ele reclamava era consequencia, e nao
    # causa: o arquivo nao existia porque o repositorio nunca tinha sido clonado.
    # A mensagem continuaria correta e continuaria apontando para o lugar errado.
    _garantir_clone_open_design || return 1

    local D="$OPENDESIGN_SRC/deploy"
    [ -f "$D/docker-compose.yml" ] || {
        echo -e "${YELLOW}Falta $D/docker-compose.yml depois de clonar.${NC}" >&2
        echo -e "${YELLOW}  O repositorio foi baixado mas nao tem deploy/: ${NC}" >&2
        echo -e "${YELLOW}  git -C $OPENDESIGN_SRC log --oneline -1${NC}" >&2
        return 1; }

    # A origem da tailnet na lista de permitidos. A base do compose JA tem a
    # linha certa (OD_ALLOWED_ORIGINS <- OPEN_DESIGN_ALLOWED_ORIGINS); o que
    # falta e o valor. Sem ele a pagina carrega, a API morre com 403, e o
    # navegador acusa cross-origin sem explicar nada.
    local origin="https://$(_tailnet_dnsname):$OPENDESIGN_SERVE_PORT"
    local envf="$D/.env"

    # O upstream documenta `cp .env.example .env` e depois colar o token. O script
    # escrevia o arquivo DO ZERO, e isso descartava cinco das oito chaves do
    # template (OPEN_DESIGN_PORT, OPEN_DESIGN_MEM_LIMIT, NODE_OPTIONS,
    # OPEN_DESIGN_DISABLE_API_AUTH, OD_CODEX_SANDBOX) — o mesmo efeito de trocar o
    # arquivo por um de três linhas. Medido no clone: o template tem 8 chaves, e o
    # que o script escrevia tinha 3.
    #
    # Regerar do template a cada execução, em vez de só quando o arquivo não
    # existe, é deliberado: `git pull` que trouxer uma chave nova no template
    # precisa chegar no `.env`. O arquivo é gerado, e a fonte é o template; quem
    # editar à mão edita um arquivo que a próxima execução reescreve.
    #
    # A excessão é o token: um token já escrito que ainda vale é preservado quando
    # esta execução não tem um novo. Sem isso, rodar o script pulando o passo do
    # token apagaria um token em uso — o modo idempotente destruindo a credencial
    # em vez de preservá-la.
    _od_token_anterior=""
    if [ -f "$envf" ]; then
        _od_token_anterior="$(sed -n 's/^OD_API_TOKEN=//p' "$envf" | head -1)"
    fi
    _od_token_novo="$OPENDESIGN_TOKEN"
    [ -n "$_od_token_novo" ] || _od_token_novo="$_od_token_anterior"

    if [ -f "$D/.env.example" ]; then
        cp "$D/.env.example" "$envf"
    else
        echo -e "${YELLOW}  Falta $D/.env.example; escrevo só o que o script sabe.${NC}" >&2
    fi
    ( umask 077
      cat > "$envf" <<ODENV
OD_API_TOKEN=$_od_token_novo
OPEN_DESIGN_ALLOWED_ORIGINS=$origin
OPEN_DESIGN_IMAGE=$OPENDESIGN_IMAGE
ODENV
    )
    chmod 600 "$envf"
    echo "  origem permitida: $origin"

    # O override LOCAL, e nao o `docker-compose.linux.yml` do upstream: aquele
    # nao funde com a base porque `OD_PORT` e int num arquivo e texto no outro, e
    # o podman-compose recusa ("can't merge value of [OD_PORT] of type int and
    # str").
    #
    # E a lista de volumes PRECISA repetir `open_design_data:/app/.od`: o
    # podman-compose SUBSTITUI a lista do servico em vez de acrescentar, entao um
    # override que so soma os host-bins faz o volume de dados sumir do merge — e a
    # recreate seguinte comeca com o estado vazio.
    cat > "$D/docker-compose.local.yml" <<'ODLOCAL'
# Override LOCAL, escrito por dotfiles-fedora. Nao faz parte do upstream.
#
# O `docker-compose.linux.yml` do upstream traz os mounts das CLIs do host e o
# PATH que as aponta, mas nao funde com a base: OD_PORT e int na base e texto no
# override, e o podman-compose recusa a fusao.
#
# O `,z` no fim do mount nao e opcional. Sem ele os mounts ficam legiveis mas o
# container leva `Permission denied`, porque os rotulos SELinux do host nao servem
# para um container: medido, ~/.local/bin e gconf_home_t e ~/.opencode/bin e
# user_tmp_t. As permissoes Unix sao 755 e nao sao o motivo. `z` e nao `Z` porque o
# host tambem usa esses diretorios.
#
# ATENCAO: a lista de volumes SUBSTITUI a da base. `open_design_data:/app/.od`
# tem que estar aqui, senao o estado do OpenDesign some no merge.
services:
  open-design:
    environment:
      PATH: /mnt/host-local-bin:/mnt/host-opencode:/usr/local/bin:/usr/bin:/bin
    volumes:
      - open_design_data:/app/.od
      - ${HOME}/.local/bin:/mnt/host-local-bin:ro,z
      - ${HOME}/.opencode/bin:/mnt/host-opencode:ro,z
ODLOCAL

    # `--no-build` e obrigatorio: a base traz `image:` e `build:` juntos, o que e
    # normal para quem desenvolve do repo, e sem a flag o Podman tenta COMPILAR DA
    # FONTE — uma operacao longa com aparencia legitima.
    # O `pull` ANTES do `up`, e e o passo que faltava.
    #
    # O upstream documenta o deploy em duas linhas:
    #
    #     OPEN_DESIGN_IMAGE=... docker compose pull
    #     OPEN_DESIGN_IMAGE=... docker compose up -d --no-build
    #
    # O script so fazia a segunda. Com a imagem fixada por DIGEST
    # (`ghcr.io/nexu-io/od@sha256:...`), o `up` nao tem de onde tirar a imagem se
    # ela nao estiver na store local — e o Podman nao resolve digest por conta
    # propria. O sintoma e o `compose up` falhar falando de uma imagem que ele
    # deveria ter baixado.
    #
    # O `pull` tambem separa as duas falhas: se a imagem nao baixa, o erro e de
    # rede ou de registro e nomeia a imagem; se o `up` falha, e de compose. Sem
    # o pull, os dois se confundem num mesmo erro de `up`.
    #
    # O `--quiet` e porque o progresso de uma imagem de centenas de MB dwarfs o
    # resto da saida do modulo. Um erro de pull continua aparecendo: o `--quiet`
    # cala o progresso, nao a mensagem do registro.
    #
    # O `--ignore-pull-failures` NAO esta aqui de proposito. Se a imagem nao
    # baixou, subir o container e o pior resultado possivel — um container criado
    # que falha no primeiro request, com o run_reportando sucesso.
    ( cd "$D" && podman compose -f docker-compose.yml -f docker-compose.local.yml \
        pull --quiet ) || {
    echo -e "${YELLOW}Nao consegui baixar a imagem do OpenDesign.${NC}" >&2
    echo -e "${YELLOW}  imagem: $OPENDESIGN_IMAGE${NC}" >&2
    echo -e "${YELLOW}  Verifique a rede e o acesso anonimo ao ghcr.io:${NC}" >&2
    echo -e "${YELLOW}  podman pull $OPENDESIGN_IMAGE${NC}" >&2
    return 1; }

    ( cd "$D" && podman compose -f docker-compose.yml -f docker-compose.local.yml \
        up -d --no-build ) || {
        echo -e "${YELLOW}O compose up falhou; a saida esta acima.${NC}" >&2; return 1; }
    unset OPENDESIGN_TOKEN

    local i st
    for i in $(seq 1 36); do
        st="$(podman inspect open-design --format '{{.State.Health.Status}}' 2>/dev/null)"
        [ "$st" = "healthy" ] && break
        sleep 10
    done
    st="$(podman inspect open-design --format '{{.State.Health.Status}}' 2>/dev/null)"
    if [ "$st" = "healthy" ]; then
        echo -e "${GREEN}✓ Container do OpenDesign healthy.${NC}"
    else
        echo -e "${YELLOW}O container ficou $st, e nao healthy.${NC}" >&2
        echo -e "${YELLOW}  A causa costuma estar no COMECO do log, nao no fim.${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}✓ OpenDesign em container, so atras do serve, com TLS.${NC}" >&2
    echo -e "${YELLOW}  Nenhuma CLI do host roda dentro: sao ELF glibc e a imagem e Alpine.${NC}" >&2

    # A publicacao na tailnet, que este modo NAO fazia.
    #
    # `setup_open_design_serve` so era chamada no fim do modo NATIVO. O modo
    # container — que e o DEFAULT — chegava ao `return 0` sem nunca publicar, e a
    # pos-condicao do run perguntava pelo estado de qualquer jeito. O resultado era
    # uma pendencia "nao publicado na tailnet em :8444" que este modo nunca tinha
    # tentado resolver: um relato de uma omissao que ele nunca podia cometer.
    #
    # E a MESMA forma do bug do clone, que tambem so vivia no modo nativo. Dois
    # passos que o modo container nao tinha, e nenhum dos dois apareceria numa
    # maquina ja provisionada no modo nativo.
    #
    # O alvo e `127.0.0.1:$OPENDESIGN_PORT`, e a imagem do container faz bind
    # nele. O `serve` e quem da TLS e quem restringe a origem; o container expoe
    # HTTP em loopback e nao deve ser alcancado de fora sem essa etapa.
    #
    # A falha nao derruba o modulo: o container esta no ar e verificado, e sem a
    # publicacao ele ainda esta acessivel por loopback. O motivo sai na saida.
    setup_open_design_serve \
        || echo -e "${YELLOW}O OpenDesign está no ar mas não foi publicado na tailnet.${NC}" >&2
    return 0
}

setup_opencode_service() {
    # A v2 do opencode NÃO cria unit nenhuma. `opencode service start` executa
    # `opencode serve --service` como filho detached, com stdio ignorado e unref —
    # medido na VM: o processo aparece com ppid=1 e o systemd responde "does not
    # belong to any loaded unit". Sem unit, o processo não volta depois de um
    # reboot, e nada no padrão o recria.
    #
    # A unit é portanto DECLARADA aqui, e não lida de um instalador. Ela chama
    # `service start` em vez de `serve` em primeiro plano, e isso é uma escolha
    # com um custo conhecido: `service start` cria o filho desacoplado, então a
    # unit não é dona do processo — ela só o inicia. A alternativa seria
    # `opencode serve --hostname ... --port ...`, que é um processo de verdade
    # sob controle do systemd, mas que ignora ~/.config/opencode/service.json e
    # portanto exige a senha por variável de ambiente em vez do arquivo.
    local unit="$HOME/.config/systemd/user/opencode.service"
    local dir="$HOME/.config/systemd/user"

    if [ ! -x "$OPENCODE_BIN" ]; then
        echo -e "${YELLOW}Binário do opencode ausente ($OPENCODE_BIN); pulei a unit.${NC}" >&2
        return 1
    fi

    # Lido ANTES dos `service set`: eles param o serviço, e é essa informação que
    # decide entre `restart` e `start` no fim da função.
    local _was_active=0
    systemctl --user is-active opencode.service >/dev/null 2>&1 && _was_active=1

    # A escuta e a senha vivem no service.json, e é o que mantém a senha estável
    # entre restarts: o código reaproveita a guardada e só gera uma quando não
    # existe. `service set` é idempotente por conta própria — ele para o serviço,
    # grava, e o próximo start pega. Por isso não há comparação de arquivo aqui.
    "$OPENCODE_BIN" service set hostname "$OPENCODE_HOST" >/dev/null 2>&1 || {
        echo -e "${YELLOW}Não consegui fixar o hostname do opencode em $OPENCODE_HOST.${NC}" >&2
        return 1
    }
    "$OPENCODE_BIN" service set port "$OPENCODE_PORT" >/dev/null 2>&1 || {
        echo -e "${YELLOW}Não consegui fixar a porta do opencode em $OPENCODE_PORT.${NC}" >&2
        return 1
    }

    # Type=oneshot porque `service start` RETORNA na hora: ele cria o filho e sai.
    # Uma unit Type=simple ficaria ocioso e o systemd a reiniciaria em loop
    # achando que o processo morreu. RemainAfterExit segura o estado "ativo".
    local expected="[Unit]
Description=Servidor do OpenCode (gerado por dotfiles-fedora)
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$OPENCODE_BIN service start
ExecStop=$OPENCODE_BIN service stop
TimeoutStartSec=120

[Install]
WantedBy=default.target"

    ( umask 077; mkdir -p "$dir" )
    if [ -f "$unit" ] && [ "$(cat "$unit")" = "$expected" ]; then
        systemctl --user daemon-reload 2>/dev/null || true
    else
        printf '%s\n' "$expected" > "$unit"
        chmod 600 "$unit"
        systemctl --user daemon-reload 2>/dev/null || true
        echo -e "${GREEN}✓ Unit do OpenCode criada ($unit).${NC}"
    fi

    # Habilitar é o que faz o serviço subir no boot. E depende de LINGER: sem ele
    # o systemd de usuário não existe fora de uma sessão, e um `enable` não sobe
    # nada. Medido na VM: Linger=yes, habilitado pelo módulo podman.
    systemctl --user enable opencode.service >/dev/null 2>&1 || true

    # Deixar o serviço DE PÉ. Os dois `service set` acima PARAM o servidor antes de
    # gravar — é assim que o opencode garante que o próximo start pega a config
    # nova. Quem chamou esta função e não levantar nada depois encontra o serviço
    # derrubado, e foi exatamente o que aconteceu no teste: a unit ficou enabled e
    # inactive, e a publicação na tailnet respondeu 502 com o backend fora.
    #
    # `restart` quando já estava no ar, `start` quando não estava. Num unit
    # Type=oneshot com RemainAfterExit, um `start` em algo já ativo é no-op — e a
    # config nova não chegaria ao processo.
    if [ "$_was_active" = "1" ]; then
        systemctl --user restart opencode.service >/dev/null 2>&1 \
            && echo -e "${GREEN}✓ OpenCode reiniciado com a escuta nova.${NC}" \
            || echo -e "${YELLOW}Não consegui reiniciar o OpenCode.${NC}" >&2
    else
        systemctl --user start opencode.service >/dev/null 2>&1 \
            && echo -e "${GREEN}✓ OpenCode no ar ($OPENCODE_HOST:$OPENCODE_PORT).${NC}" \
            || echo -e "${YELLOW}Não consegui subir o OpenCode.${NC}" >&2
    fi
    if ! loginctl show-user "$(id -un)" 2>/dev/null | grep -qi "Linger=yes"; then
        echo -e "${YELLOW}Linger está desligado: a unit do OpenCode não vai subir no boot.${NC}" >&2
        echo -e "${YELLOW}  Habilite com: sudo loginctl enable-linger $(id -un)${NC}" >&2
    fi
    echo -e "${GREEN}✓ OpenCode: escuta $OPENCODE_HOST:$OPENCODE_PORT, unit habilitada e no ar.${NC}"
}

# Instala um pacote npm global (via Bun se disponível, com fallback pra npm), idempotente.
# Instala um pacote npm global acompanhando a versão publicada mais recente.
#
# Existe separada da install_npm_global porque aquela decide por PRESENÇA do
# binário, e presença não é versão: uma máquina que rodou o módulo uma vez fica
# presa na primeira versão que caiu, para sempre. Aqui a pergunta é feita ao
# registro, e o instalador só roda quando a resposta difere do que está em disco.
#
# O JSON do registro tem megabytes, e `sed` sobre ele seria frágil — a chave
# `"latest"` reaparece em outros lugares do documento, e o primeiro casamento
# depende de onde a chave aparecer. Por isso a extração é feita com o próprio
# Node, que este módulo já tem no PATH: prepend_mise_shims roda antes, e
# ensure_host_node instala o runtime se faltar. Pedir JSON a um programa que
# entende JSON é mais barato que tentar adivinhar a posição da chave.
install_npm_global_latest() {
    local package="$1" bin_name="$2"
    local registry="https://registry.npmjs.org/$(printf '%s' "$package" | sed 's#/#%2F#')"
    local latest=""
    if command -v node &> /dev/null; then
        latest=$(curl -fsSL --max-time 30 "$registry" 2>/dev/null | node -e '
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  try {
    const v = JSON.parse(s)["dist-tags"] && JSON.parse(s)["dist-tags"].latest;
    if (v) console.log(v);
  } catch (e) {}
});' 2>/dev/null | head -1)
    fi
    if [ -z "$latest" ]; then
        # Sem o registro não há como saber se o que está instalado é o mais novo.
        # Reaplicar o instalador às cegas rebaixaria uma instalação mais recente
        # para uma mais antiga, e isso é pior do que estar desatualizado.
        echo -e "${YELLOW}Não consegui consultar a versão publicada de $package; o que está instalado foi mantido.${NC}" >&2
        echo -e "${YELLOW}  Registro: $registry${NC}" >&2
        return 0
    fi
    local have=""
    if command -v "$bin_name" &> /dev/null; then
        have=$("$bin_name" --version 2>/dev/null | tr -d '\r' | awk '{ $1=$1; print }' || echo "")
        have="${have##* }"
        have="${have#v}"
    fi
    if [ -n "$have" ] && [ "$have" = "$latest" ]; then
        echo -e "${YELLOW}$bin_name $have já é a versão publicada mais recente; pulando.${NC}"
        return 0
    fi
    if [ -n "$have" ]; then
        echo -e "${YELLOW}$bin_name $have instalado; a mais recente é $latest. Atualizando.${NC}"
    fi
    if command -v bun &> /dev/null; then
        bun add -g "$package" || npm install -g "$package"
    elif command -v npm &> /dev/null; then
        npm install -g "$package"
    else
        echo -e "${YELLOW}Nem Bun nem npm encontrados para instalar $package.${NC}" >&2
        return 0
    fi
    if command -v "$bin_name" &> /dev/null; then
        echo -e "${GREEN}✓ $bin_name $latest.${NC}"
    else
        echo -e "${YELLOW}Aviso: $package instalado, mas o comando '$bin_name' não foi encontrado no PATH.${NC}" >&2
    fi
    unset registry latest have
}

# Autoriza nesta máquina as chaves públicas de dispositivos que o GitHub reúne.
#
# O bloco entre GITHUB_KEYS_BEGIN e GITHUB_KEYS_END é reescrito inteiro a cada
# execução; TUDO fora dele é preservado. Isso é deliberado, e é o que impede o
# pior modo de falha possível deste módulo. Medido: o authorized_keys do host tem
# uma chave (`SHA256:TQzAbv1QICo`) que NÃO existe no GitHub — é a chave de um
# Mac. Se este módulo tratasse o arquivo como espelho do GitHub, tiraria essa
# chave e trancaria fora o aparelho que hoje entra. O GitHub é a fonte do BLOCO,
# não do arquivo.
#
# A revogação é real, mas indireta e diferida: sai-se a chave da conta, e ela perde
# o acesso na próxima execução deste módulo. Não há como remover acesso antes disso
# por este caminho.
sync_device_keys_from_github() {
    local ak="$HOME/.ssh/authorized_keys"
    local url="https://github.com/${GITHUB_KEYS_USER}.keys"
    local feed; feed=$(mktemp) || return 1

    if ! curl -fsSL --max-time 30 "$url" -o "$feed" 2>/dev/null; then
        rm -f "$feed"
        echo -e "${YELLOW}Não consegui baixar $url; o authorized_keys não foi tocado.${NC}" >&2
        return 1
    fi

    # Valida ANTES de escrever. Um `>>` cego numa resposta que não é a lista de
    # chaves — 404, html de proxy, corpo vazio, download parcial — escreveria lixo
    # no arquivo que decide quem entra na máquina, e o sshd leria esse lixo sem
    # reclamar de nada. O filtro é também o que separa chave de não-chave.
    local limpo="$feed.limpo"
    grep -E '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com) ' "$feed" \
        > "$limpo" 2>/dev/null || true
    if [ ! -s "$limpo" ]; then
        rm -f "$feed" "$limpo"
        echo -e "${YELLOW}A resposta de $url não tem nenhuma chave pública; o authorized_keys não foi tocado.${NC}" >&2
        return 1
    fi

    # Tira as chaves que são desta própria máquina. O módulo `ssh` registra a chave
    # do servidor no GitHub com `gh ssh-key add`, então o feed traz a chave do
    # servidor DE VOLTA. Deixá-la seria o servidor autorizar a si mesmo a entrar
    # nele: inofensivo, e sem propósito nenhum.
    local blobs="" pk selfn=0
    for pk in "$HOME"/.ssh/*.pub; do
        [ -f "$pk" ] || continue
        blobs="$blobs $(awk 'NF >= 2 { print $2 }' "$pk" 2>/dev/null)"
    done
    if [ -n "$(printf '%s' "$blobs" | tr -d ' ')" ]; then
        local semself="$feed.semself"
        # Duas passadas, de propósito. A versão anterior mandava o awk inteiro
        # para stdout e tirava a contagem com `tail -1`, mas NADA era gravado em
        # $semself — o arquivo nunca existia, a contagem dava zero, e a função
        # caía no "nada a fazer" em toda máquina. Um módulo que faz nada e
        # reporta sucesso é pior do que um que falha: parece configurado.
        #
        # A contagem vai numa passada à parte porque, na mesma, ela contaminaria o
        # arquivo de chaves com uma linha numérica que o sshd leria sem reclamar.
        awk -v self="$blobs" '
            BEGIN { n = split(self, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1 }
            $2 in s { next }
            { print }
        ' "$limpo" > "$semself"
        selfn=$(awk -v self="$blobs" '
            BEGIN { n = split(self, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1 }
            $2 in s { r++ }
            END { print r + 0 }
        ' "$limpo")
        if [ "$(grep -c '' "$semself" 2>/dev/null || echo 0)" -gt 0 ]; then
            limpo="$semself"
        else
            # Sobrou nada depois de tirar a chave da própria máquina: a conta não tem
            # chave de dispositivo. Apagar o bloco deixaria a máquina sem o que tem.
            rm -f "$feed" "$limpo" "$semself"
            echo -e "${YELLOW}Todas as chaves de $GITHUB_KEYS_USER são desta própria máquina; nada a fazer.${NC}"
            return 0
        fi
    fi

    local n_final
    n_final=$(grep -c '' "$limpo" 2>/dev/null || echo 0)

    # Bloco novo. Sem timestamp de propósito: um carimbo de data mudaria o conteúdo a
    # cada execução, e a comparação de "já atualizado" nunca casaria — o arquivo
    # seria reescrito à toa, a cada rodada.
    local bloco; bloco=$(mktemp) || { rm -f "$feed" "$limpo"; return 1; }
    {
        printf '%s\n' "$GITHUB_KEYS_BEGIN"
        printf '# %s chave(s) de github.com/%s. Nao edite este bloco: o modulo device-keys o reescreve.\n' \
            "$n_final" "$GITHUB_KEYS_USER"
        cat "$limpo"
        printf '%s\n' "$GITHUB_KEYS_END"
    } > "$bloco"

    # Extrai o bloco atual, se existir.
    local atual; atual=$(mktemp) || { rm -f "$feed" "$limpo" "$bloco"; return 1; }
    if [ -e "$ak" ]; then
        awk -v b="$GITHUB_KEYS_BEGIN" -v e="$GITHUB_KEYS_END" '
            $0 == b { dentro = 1 }
            dentro   { print }
            $0 == e { dentro = 0 }
        ' "$ak" > "$atual" 2>/dev/null || true
    else
        : > "$atual"
    fi

    if [ -e "$ak" ] && cmp -s "$bloco" "$atual"; then
        rm -f "$feed" "$limpo" "$bloco" "$atual"
        echo -e "${GREEN}✓ authorized_keys já está com as $n_final chave(s) de github.com/$GITHUB_KEYS_USER.${NC}"
        [ "$selfn" -gt 0 ] 2>/dev/null && \
            echo -e "${YELLOW}  $selfn chave(s) da própria máquina omitidas.${NC}"
        return 0
    fi

    # Quem saiu. Revogação que ninguém vê não é revogação: a diferença entre o bloco
    # antigo e o novo é o que o operador precisa ler para saber se a remoção que
    # fez no GitHub chegou aqui.
    local revogadas=""
    if [ -s "$atual" ]; then
        local fpa fpn
        fpa=$(mktemp); fpn=$(mktemp)
        grep -E '^(ssh-|ecdsa-|sk-)' "$atual" > "$fpa.tmp" 2>/dev/null && mv "$fpa.tmp" "$fpa" || : > "$fpa"
        grep -E '^(ssh-|ecdsa-|sk-)' "$bloco" > "$fpn.tmp" 2>/dev/null && mv "$fpn.tmp" "$fpn" || : > "$fpn"
        revogadas=$(ssh-keygen -lf "$fpa" 2>/dev/null | awk '{print $2}' | sort -u > "$fpa.fp"
                    ssh-keygen -lf "$fpn" 2>/dev/null | awk '{print $2}' | sort -u > "$fpn.fp"
                    comm -23 "$fpa.fp" "$fpn.fp" | tr '\n' ' ')
        rm -f "$fpa" "$fpn" "$fpa.tmp" "$fpn.tmp" "$fpa.fp" "$fpn.fp"
    fi

    # Reconstrói: tudo que está fora do bloco, na ordem original, mais o bloco novo.
    local novo; novo=$(mktemp) || { rm -f "$feed" "$limpo" "$bloco" "$atual"; return 1; }
    if [ -e "$ak" ]; then
        awk -v b="$GITHUB_KEYS_BEGIN" -v e="$GITHUB_KEYS_END" '
            $0 == b { dentro = 1; next }
            dentro   { if ($0 == e) dentro = 0; next }
            { print }
        ' "$ak" > "$novo" 2>/dev/null || true
    fi
    if [ -s "$novo" ] && [ -n "$(tail -c 1 "$novo" 2>/dev/null)" ]; then
        printf '\n' >> "$novo"
    fi
    cat "$bloco" >> "$novo"

    local dir="$HOME/.ssh"
    ( umask 077; mkdir -p "$dir" )
    # So reescreve quando o conteudo MUDA. O `mv` incondicional deixava o mtime do
    # authorized_keys advancedo em todo run, mesmo com o arquivo identico — e o
    # teste de idempotencia (medido nesta sessao, no container) acusava
    # "mtime nao mudou: esperado N, obtido N+1" num run cujo conteudo estava
    # certo. A leitura que a maquina faz e a do sshd, e o sshd nao cares de mtime;
    # quem cares e quem vigia mudancas no arquivo — e um arquivo reescrito a cada
    # execucao sem mudanca parece mudanca onde nao houve.
    #
    # O `cmp` compara o conteudo byte a byte. Com conteudo igual, o arquivo fica
    # como esta, e o `chmod`/`restorecon` do ramo de dentro ainda correm: eles
    # consertam o que precisa ser consertado (modo, contexto SELinux) sem mudar o
    # conteudo nem o mtime.
    #
    # E o `cmp` NAO pode estar com o erro escondido. Medido nesta sessao, num
    # container sem `diffutils`: `cmp` nao existe, `cmp -s ... 2>/dev/null` devolve
    # "nao zero" — o mesmo codigo de "os arquivos diferem" — e o `if` caia no ramo
    # de reescrever. O arquivo era identico e mesmo assim era reescrito, que e o
    # exato defeito que esta mudanca veio corrigir. Um `2>/dev/null` em volta de
    # uma comparacao transforma "a ferramenta nao esta" em "o conteudo mudou", e
    # as duas coisas levam a caminhos opostos.
    #
    # Sem `cmp`, a comparacao e feita por hash, que e o que o proprio modulo ja usa
    # para o conteudo. Sem nenhuma das duas, o arquivo e reescrito — que e o
    # comportamento seguro, e nao uma comparacao silenciosamente falsa.
    _mudar=1
    _igual=1
    if [ -e "$ak" ]; then
        if command -v cmp >/dev/null 2>&1; then
            cmp -s "$novo" "$ak" || _igual=0
        else
            _h1=$(md5sum < "$novo" 2>/dev/null | cut -d" " -f1)
            _h2=$(md5sum < "$ak" 2>/dev/null | cut -d" " -f1)
            [ -n "$_h1" ] && [ "$_h1" = "$_h2" ] || _igual=0
        fi
    else
        _igual=0
    fi
    if [ "$_igual" -eq 1 ]; then
        _mudar=0
        rm -f "$ak.novo"
    fi
    if { [ "$_mudar" -eq 0 ] || { cat "$novo" > "$ak.novo" 2>/dev/null && mv "$ak.novo" "$ak" 2>/dev/null; }; }; then
        chmod 700 "$dir" 2>/dev/null || true
        chmod 600 "$ak" 2>/dev/null || true
        # SELinux está Enforcing nas duas máquinas, e contexto errado no
        # authorized_keys faz o sshd recusar a chave com "bad permissions", sem
        # explicar o motivo. Medido: `restorecon` sem sudo relabela corretamente
        # arquivo do próprio usuário, então este passo não precisa de privilégio.
        # O aviso "no default label" do restorecon sai em STDOUT, nao em stderr, entao
        # sem redirecionar os dois ele vaza para a saida do modulo.
        command -v restorecon &> /dev/null && restorecon "$ak" > /dev/null 2>&1
        echo -e "${GREEN}✓ authorized_keys: bloco de $n_final chave(s) de github.com/$GITHUB_KEYS_USER atualizado.${NC}"
        if [ "$selfn" -gt 0 ] 2>/dev/null; then
            echo -e "${YELLOW}  $selfn chave(s) da própria máquina omitidas, para o servidor não se autorizar a si mesmo.${NC}"
        fi
        if [ -n "$(printf '%s' "$revogadas" | tr -d ' ')" ]; then
            echo -e "${YELLOW}  Revogadas agora (saíram do GitHub e perderam o acesso):${NC}"
            printf '%s\n' "$revogadas" | tr ' ' '\n' | grep . | sed 's/^/    /'
        fi
        echo -e "${YELLOW}  Chaves fora do bloco não foram tocadas.${NC}"
    else
        rm -f "$ak.novo"
        echo -e "${YELLOW}Não consegui reescrever o authorized_keys; o arquivo atual está intacto.${NC}" >&2
    fi

    rm -f "$feed" "$limpo" "$bloco" "$atual" "$novo"
}

install_npm_global() {
    local package="$1" bin_name="$2"
    if command -v "$bin_name" &> /dev/null; then
        echo -e "${YELLOW}$bin_name já instalado, pulando.${NC}"
        return
    fi
    if command -v bun &> /dev/null; then
        bun add -g "$package" || npm install -g "$package"
    elif command -v npm &> /dev/null; then
        npm install -g "$package"
    else
        echo -e "${YELLOW}Nem Bun nem npm encontrados para instalar $package.${NC}"
        return
    fi
    if command -v "$bin_name" &> /dev/null; then
        echo -e "${GREEN}✓ $bin_name instalado.${NC}"
    else
        echo -e "${YELLOW}Aviso: $package instalado, mas o comando '$bin_name' não foi encontrado no PATH.${NC}"
    fi
}

# CLIs de IA disponíveis via npm/Bun ou script oficial (instaladas no host se confirmado).
install_common_ai_clis() {
    # Bun é o caminho primário; o mise entra como fallback de npm e como
    # runtime das CLIs com "#!/usr/bin/env node".
    prepend_mise_shims
    if ! command -v bun &> /dev/null && ! mise_bin &> /dev/null; then
        echo -e "${YELLOW}Nem Bun nem mise instalados; instalando o runtime do host.${NC}"
        ensure_host_node
        activate_mise_in_shell || true
        link_devcontainer_cli || true
        prepend_mise_shims
    fi

    local npm_prefix_bin=""
    if command -v npm &> /dev/null; then
        npm_prefix_bin="$(npm config get prefix 2>/dev/null)/bin"
    fi
    export PATH="$HOME/.bun/bin:$npm_prefix_bin:$HOME/.local/bin:$PATH"

    # As três agent CLIs seguem a versão publicada mais recente, e não por
    # uniformidade estética. A pergunta que `install_npm_global` faz é PRESENÇA do
    # binário, e presença não é versão: uma máquina que rodou o módulo uma vez
    # fica presa na primeira versão que caiu, para sempre, e nada no repositório
    # avisa. `claude` e `codex` eram as duas que ainda usavam presença.
    install_npm_global_latest "@anthropic-ai/claude-code" "claude"
    install_npm_global_latest "@openai/codex" "codex"
    # DeepSeek Harness. O README o descreve como developer preview com
    # "COMPATIBILITY-BREAKING CHANGES" explícito, e a documentação oficial só
    # mostra `npx`. O `npm install -g` abaixo é o mesmo caminho que as outras
    # cinco usam, e é o que torna o binário `dsh` utilizável sem baixar o
    # pacote inteiro a cada invocação. A escolha de acompanhar a versão
    # publicada mais recente é deliberada: um pacote em preview que muda de
    # forma incompatível entre versões é o pior candidato possível para um pin
    # entre versões é o pior candidato possível para um pin que ninguém reverte.
    # O pacote não declara `engines` em nenhuma das versões publicadas, então o
    # requisito (^22.19 ou >=24) não é imposto pelo npm e depende do pin do mise.
    install_npm_global_latest "@deepseek-ai/dsh" "dsh"

    if command -v cursor-agent &> /dev/null; then
        echo -e "${YELLOW}cursor-agent já instalado, pulando.${NC}"
    else
        curl https://cursor.com/install -fsS | bash
        echo -e "${GREEN}✓ Cursor Agent CLI instalado.${NC}"
    fi

    # A URL vem de OPENCODE_INSTALL_URL, declarada no topo. O instalador da linha
    # 1, noutra URL, é o que fazia a v1 ser instalada e depois faltar o subcomando
    # `service`. O `--version` vai depois do `--`, que é como o instalador da
    # opencode recebe os próprios argumentos.
    #
    # NÃO há pin de versão. O que existe é a comparação com o endpoint público
    # que o próprio instalador consulta (`OPENCODE_LATEST_URL`): o script instala a
    # v2 mais nova que existir, e não reinstala nada quando já está nela. Um pin
    # fixo resolveria o problema errado — deixaria a máquina presa numa versão
    # para sempre, que é o defeito que o guard por existência do binário escondia.
    #
    # A major é travada em 2 de propósito. O endpoint reporta `channel: latest` e
    # hoje esse canal é o branch v2, mas o script não deve atravessar major por
    # conta própria: se a v3 subir para lá, para e avisa em vez de trocar.
    #
    # A idempotência é conferida no caminho, e não com `command -v`: o binário fica
    # em `~/.opencode/bin`, que o PATH exportado acima não inclui, então num shell
    # não-interativo o `command -v` é falso e o instalador rodaria toda vez. Como há
    # pin, e o instalador da v2 perdeu o early-exit que a v1 tinha, sem isto cada
    # execução rebaixaria o tarball.
    #
    # O `--no-modify-path` impede o instalador de anexar
    # `export PATH=~/.opencode/bin:$PATH` no rc. Ele casa a linha por `grep -Fxq`, e
    # a linha do zshrc versionado tem um prefixo `[ -d … ] &&`, que não casa — então
    # sem esta flag o instalador escreveria dentro do arquivo versionado, através do
    # symlink. Quem é dono do PATH interativo é o zshrc do repo, não o instalador.
    local oc_latest=""
    if command -v curl &> /dev/null; then
        oc_latest=$(curl -fsSL --max-time 20 "$OPENCODE_LATEST_URL" 2>/dev/null \
            | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -1)
    fi
    if [ -z "$oc_latest" ]; then
        # Sem o endpoint não há como saber se o que está instalado é o mais novo,
        # e reaplicar o instalador às cegas rebaixaria uma instalação mais recente
        # para uma mais antiga. Deixar como está é a única escolha que não regride.
        echo -e "${YELLOW}Não consegui consultar a versão mais recente do opencode; o que está instalado foi mantido.${NC}" >&2
        echo -e "${YELLOW}  Endpoint: $OPENCODE_LATEST_URL${NC}" >&2
    else
        local oc_major="${oc_latest%%.*}"
        if [ "$oc_major" != "2" ]; then
            # O canal `latest` deixou de ser o branch v2. Instalar seria trocar de
            # major por decisão de script, e isso é do dono da máquina.
            echo -e "${YELLOW}O canal do opencode agora aponta para a major ${oc_major}, e este script só instala a 2.${NC}" >&2
            echo -e "${YELLOW}  Versão publicada: ${oc_latest} — nada foi instalado nem alterado.${NC}" >&2
        else
            # A normalização espelha a do instalador (check_version): último campo
            # separado por espaço, sem o 'v' inicial. Sem isso, "2.0.18" e "v2.0.18"
            # seriam sempre diferente e o script reinstalaria toda vez.
            local oc_have=""
            if [ -x "$OPENCODE_BIN" ]; then
                # O `awk` colapsa espaço interno e apara as pontas. Sem ele, uma
                # saída com espaço à direita sobra vazia depois de `##* ` — e
                # `oc_have` vazio é indistinguível de "não instalado", o que faria
                # o script reinstalar em toda execução sem nunca convergir.
                oc_have=$("$OPENCODE_BIN" --version 2>/dev/null | tr -d '\r' | awk '{ $1=$1; print }' || echo "")
                oc_have="${oc_have##* }"
                oc_have="${oc_have#v}"
            fi
            if [ -n "$oc_have" ] && [ "$oc_have" = "$oc_latest" ]; then
                echo -e "${YELLOW}opencode ${oc_have} já é a v2 mais recente; pulando.${NC}"
            else
                [ -n "$oc_have" ] \
                    && echo -e "${YELLOW}opencode ${oc_have} instalado; a mais recente é ${oc_latest}. Atualizando.${NC}"
                curl -fsSL "$OPENCODE_INSTALL_URL" \
                    | bash -s -- --no-modify-path --version "$oc_latest"
                echo -e "${GREEN}✓ Open Code (anomalyco/opencode, canal v2) em ${oc_latest}.${NC}"
            fi
        fi
    fi
    unset oc_latest oc_major oc_have

    if command -v agy &> /dev/null; then
        echo -e "${YELLOW}agy (Antigravity CLI) já instalado, pulando.${NC}"
    else
        curl -fsSL https://antigravity.google/cli/install.sh | bash
        echo -e "${GREEN}✓ Antigravity CLI (agy) instalado.${NC}"
    fi

    # O daemon do agy roda "npm exec" fora de shell interativo, então precisa do
    # PATH do mise explicitado no serviço. Ver setup_agy_service_path. Está na
    # lista de baixo porque `mkdir -p` e a escrita do drop-in abortam o módulo sob
    # `set -e` se falharem, e um drop-in não escrito não invalida as CLIs.
    setup_agy_service_path \
        || echo -e "${YELLOW}Drop-in de PATH do agy não foi escrito; o daemon pode não achar o runtime.${NC}" >&2

    # A unit do opencode é criada pelo instalador sem consultar o padrão, então a
    # escuta é declarada aqui. Ver setup_opencode_service.
    # As quatro chamadas abaixo são o mesmo padrão: um passo que pode não ser
    # completável *agora*, e cujo insucesso não invalida o que já foi instalado.
    # `apply_opencode_password` devolve 1 quando não há binário, e
    # `setup_opencode_serve` devolve 1 quando o Tailscale ainda não está instalado —
    # o que é a situação normal de quem roda `--only=ai-clis` antes do módulo
    # `tailscale`. Sem o `||`, o `set -e` do topo do script transforma "deixei para
    # depois" em "abortei o módulo inteiro". O que se perde é o resto do
    # provisionamento — a publicação na tailnet, o módulo `zshrc` que vem depois, e a
    # mensagem final —, não as seis CLIs, que já estão instaladas quando estas quatro
    # rodam.
    # Esta função só devolve 1 quando não consegue ler o `ExecStart` da unit, ou
    # quando o binário apontado por ele não é executável. A ausência da unit
    # devolve 0, e quem a cria é o instalador do opencode acima — não um módulo
    # deste script.
    setup_opencode_service \
        || echo -e "${YELLOW}Não consegui ler o ExecStart da unit do OpenCode, ou o binário não é executável; o drop-in de escuta ficou por aplicar.${NC}" >&2

    # A senha do servidor é obrigatória; deixamos quem administra escolher em vez
    # de ficar com a aleatória do instalador. O valor foi lido no bloco de
    # perguntas, e a variável é apagada assim que é aplicada. Ver
    # apply_opencode_password.
    if [ "${CONFIRM_OPENCODE_PASSWORD:-}" = "1" ]; then
        apply_opencode_password \
            || echo -e "${YELLOW}Senha do OpenCode não foi alterada; a do instalador foi mantida.${NC}" >&2
    fi

    # Publicação na tailnet depois da unit, porque o alvo do proxy tem de existir
    # para o tailscale serve ter o que publicar. Ver setup_opencode_serve.
    setup_opencode_serve \
        || echo -e "${YELLOW}Publicação na tailnet pendente; rode o módulo 'tailscale' e depois repita.${NC}" >&2
}

# Instala a CLI do OpenCodex (@bitkyc08/opencodex) via Bun ou npm.
install_opencodex() {
    if command -v bun &> /dev/null; then
        echo "Instalando via Bun..."
        bun add -g @bitkyc08/opencodex || npm install -g @bitkyc08/opencodex
    elif command -v npm &> /dev/null; then
        echo "Instalando via npm..."
        npm install -g @bitkyc08/opencodex
    else
        echo -e "${YELLOW}Nem Bun nem npm encontrados para instalar o OpenCodex.${NC}"
        return
    fi

    prepend_mise_shims
    local npm_prefix_bin=""
    if command -v npm &> /dev/null; then
        npm_prefix_bin="$(npm config get prefix 2>/dev/null)/bin"
    fi
    export PATH="$HOME/.bun/bin:$npm_prefix_bin:$PATH"

    if command -v ocx &> /dev/null; then
        echo -e "${GREEN}✓ OpenCodex CLI (ocx) instalado com sucesso.${NC}"
        echo -e "Para iniciar o proxy OpenCodex, execute no seu terminal: ${GREEN}ocx start${NC}"
    else
        echo -e "${YELLOW}Aviso: O comando 'ocx' não foi encontrado no PATH.${NC}"
    fi
}

# Gera (se não existir) uma chave SSH Ed25519 e garante que o ssh-agent a carregue.
generate_ssh_key() {
    local email="$1"
    local ssh_key="$HOME/.ssh/id_ed25519"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [ ! -f "$ssh_key" ]; then
        ssh-keygen -t ed25519 -C "$email" -f "$ssh_key" -N ""
        eval "$(ssh-agent -s)"
        ssh-add "$ssh_key"
        echo -e "${GREEN}✓ Chave Ed25519 criada.${NC}"
    else
        echo -e "${YELLOW}Chave SSH já existe em $ssh_key.${NC}"
    fi
}

# Configura git --global e autentica o GitHub CLI, enviando a chave pública se necessário.
configure_git_and_gh() {
    local git_name="$1" git_email="$2" key_title="$3"
    local ssh_key="$HOME/.ssh/id_ed25519"

    git config --global user.name "$git_name"
    git config --global user.email "$git_email"
    git config --global init.defaultBranch main
    git config --global pull.rebase false

    if ! command -v gh &> /dev/null; then
        echo -e "${YELLOW}GitHub CLI (gh) não encontrado.${NC}"
        return
    fi

    if gh auth status &> /dev/null; then
        echo -e "${GREEN}✓ GitHub CLI já autenticado.${NC}"
        return
    fi

    # Login de pessoa é opt-in, e a razão é concreta: a GitHub App já dá identidade
    # de máquina para a API que os agentes usam, e quem roda o `gh` à mão pode
    # preferir não colocar um token de conta dentro da fronteira. Quem não quiser
    # não responde nada nesta pergunta, e o módulo segue sem autenticar o `gh`.
    if [ "${CONFIRM_GH_LOGIN:-0}" != "1" ]; then
        # A distinção é entre "ninguém pediu" e "a flag pediu que não". Sem ela, o
        # primeiro run de uma máquina nova deixa o módulo pulado sem explicação, e
        # "pulei" e "esqueci" são leituras diferentes do mesmo log.
        if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
            echo -e "${YELLOW}Login de pessoa pulado: --defaults aceitou o default 'não' desta pergunta.${NC}"
            echo -e "${YELLOW}  É o default certo — este passo é entrada para um serviço externo, e é${NC}" >&2
            echo -e "${YELLOW}  justamente a pergunta que o --yes antigo invertia e que travava o run no${NC}" >&2
            echo -e "${YELLOW}  handshake do gh. Se quiser, é o passo 1 do 'pos-instalacao.md'.${NC}" >&2
        else
            echo -e "${YELLOW}Login de pessoa não solicitado: 'gh' segue sem token próprio.${NC}"
        fi
        echo -e "${YELLOW}  A API dos agentes continua coberta pela GitHub App, pelo wrapper 'gh-app'.${NC}"
        echo -e "${YELLOW}  Consequência: a chave SSH desta máquina NÃO é registrada no GitHub, porque${NC}" >&2
        echo -e "${YELLOW}  registrar chave é um endpoint de usuário (POST /user/keys) e um token de${NC}" >&2
        echo -e "${YELLOW}  instalação da App não o alcança. Para clonar e dar push por SSH, registre a${NC}" >&2
        echo -e "${YELLOW}  chave uma vez, de uma máquina que já tenha o 'gh' autenticado:${NC}" >&2
        echo -e "${YELLOW}    gh ssh-key add ~/.ssh/id_ed25519.pub --title '<esta VM>'${NC}" >&2
        return
    fi

    if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
        # O default é SIM no host, e mesmo assim o handshake NÃO acontece aqui.
        # `gh auth login -w` abre o navegador e espera: é a única pausa
        # condicional que sobrou no script, e foi exatamente onde o `--yes` antigo
        # travou para sempre. Um default que trava não é um default, é um beco —
        # então o que o operador precisa fazer depois é escrito, e ele decide
        # quando. Provisionar não significa abrir um navegador sozinho.
        echo -e "${YELLOW}Login de pessoa: aceito como default, mas o handshake precisa de você.${NC}"
        echo -e "${YELLOW}  Rode, quando quiser e com a sua conta:${NC}" >&2
        echo -e "${YELLOW}    gh auth login -p https -w -s admin:public_key,read:user,user:email${NC}" >&2
        echo -e "${YELLOW}  (o device code também funciona sem navegador: acrescente -c)${NC}" >&2
        return
    fi

    echo -e "${YELLOW}Iniciando handshake com o GitHub via navegador...${NC}"
    gh auth login -p https -w -s admin:public_key,read:user,user:email

    if [ -f "$ssh_key.pub" ]; then
        local gh_ssh_err
        gh_ssh_err="$(mktemp)"
        if gh ssh-key add "$ssh_key.pub" --title "$key_title" 2>"$gh_ssh_err"; then
            echo -e "${GREEN}✓ Chave SSH enviada ao GitHub.${NC}"
        elif grep -qi "already in use" "$gh_ssh_err"; then
            echo -e "${YELLOW}Chave SSH já estava cadastrada no GitHub.${NC}"
        else
            echo -e "${YELLOW}⚠ Falha ao enviar chave SSH ao GitHub: $(cat "$gh_ssh_err")${NC}"
        fi
        rm -f "$gh_ssh_err"
    fi
}

# Cria/atualiza o link simbólico ~/.zshrc → <repo>/zshrc. CONFIRM_ZSHRC_OVERWRITE
# já vem decidido pelo bloco de confirmações antecipadas no início do script,
# então este módulo nunca pergunta nada no meio da execução.
link_zshrc() {
    local zshrc_src="$SCRIPT_DIR/zshrc"
    local zshrc_dest="$HOME/.zshrc"

    if [ -L "$zshrc_dest" ] && [ "$(readlink "$zshrc_dest")" = "$zshrc_src" ]; then
        echo -e "${GREEN}✓ ~/.zshrc já aponta para este repositório.${NC}"
    elif [ -L "$zshrc_dest" ] && [ ! -e "$zshrc_dest" ]; then
        # Symlink QUEBRADO: o nome existe, o destino não.
        #
        # Este caso estava sendo tratado como "já existe um ~/.zshrc seu, não toco".
        # É a leitura errada, e ela vem de como o teste é escrito: `[ -e ] || [ -L ]`
        # junta as duas coisas, e um symlink quebrado satisfaz só o segundo. O
        # resultado é que o script pede confirmação para "sobrescrever" algo que não
        # tem conteúdo — e o `--defaults` recusa, porque o default aqui é *não*.
        #
        # Medido nesta VM: `~/.zshrc` → `/home/agent/zshrc`, que não existe. É o
        # rastro do bug da montagem (§10.18), em que o `SCRIPT_DIR` era o `$HOME` e
        # o link apontava para `$HOME/zshrc`. O run seguinte declarava pendência
        # "nao aponta para o zshrc deste repositorio" sobre um link que não apontava
        # para lugar nenhum — e o conserto é repondo o link, não perguntando.
        #
        # Por que não há backup: um symlink quebrado não tem conteúdo a preservar.
        # Salvar o nome seria guardar um ponteiro para o vazio, e o backup seria
        # ele próprio inútil. E por que isso NÃO é mudar o default: o default
        # protege um `~/.zshrc` com conteúdo, e aqui não há conteúdo nenhum. A
        # pergunta continua valendo para o arquivo de verdade, uma linha abaixo.
        # O alvo antigo e lido ANTES do `ln`: depois de repor o link, o
        # `readlink` devolve o novo, e a mensagem diria "estava quebrado para
        # /home/agent/tmp/dotfiles/zshrc" — que e o destino bom, e nao o quebrado.
        local alvo_antigo
        alvo_antigo="$(readlink "$zshrc_dest" 2>/dev/null || echo '?')"
        ln -sfn "$zshrc_src" "$zshrc_dest"
        echo -e "${GREEN}✓ ~/.zshrc estava quebrado (→ $alvo_antigo), agora aponta para $zshrc_src${NC}"
        echo -e "${YELLOW}  Nada foi perdido: o link antigo não tinha destino, e por isso não há backup.${NC}" >&2
    elif [ -e "$zshrc_dest" ]; then
        if [ "$CONFIRM_ZSHRC_OVERWRITE" = "1" ]; then
            local backup
            backup="$zshrc_dest.backup.$(date +%Y%m%d%H%M%S)"
            mv "$zshrc_dest" "$backup"
            echo -e "${YELLOW}~/.zshrc anterior salvo em $backup${NC}"
            ln -s "$zshrc_src" "$zshrc_dest"
            echo -e "${GREEN}✓ ~/.zshrc agora aponta para $zshrc_src${NC}"
        else
            echo -e "${YELLOW}~/.zshrc mantido como está.${NC}"
        fi
    else
        ln -s "$zshrc_src" "$zshrc_dest"
        echo -e "${GREEN}✓ ~/.zshrc agora aponta para $zshrc_src${NC}"
    fi
}

# Módulos disponíveis, na ordem em que rodam. Esta lista é a união de tudo o
# script sabe fazer; o que roda é decidido pelo perfil (ver PROFILE_STEPS).
ALL_STEPS="base hostname ssh device-keys git podman gh-app tailscale sshd-hardening firewalld vm-host toolbx gui-access desktop-apps ai-clis opencodex hermes-cli hermes-dashboard open-design open-design-container zshrc"

# Módulos por camada. A regra é uma só: **um módulo mora no perfil da camada que
# o executa.** Ver ARQUITETURA.md, "O plano dos perfis".
#
#   host — workstation pessoal com GUI e hospedeiro de VMs. Tem libvirt e
#          cockpit, e é dono do próprio firewall. Não tem container: quem roda
#          container é o guest.
#   vm   — a fronteira. Tem Podman rootless, as CLIs de agente e o servidor do
#          OpenCode. É alcançada por SSH e não expõe nada na LAN.
#
# O que é comum aos dois fica nos dois, idêntico — é a maior parte do script.
HOST_STEPS="base hostname ssh device-keys git tailscale sshd-hardening firewalld vm-host toolbx gui-access desktop-apps opencodex zshrc"
VM_STEPS="base hostname ssh device-keys git gh-app tailscale sshd-hardening firewalld podman ai-clis hermes-cli hermes-dashboard open-design open-design-container zshrc"

# Opcionais dentro do próprio perfil: não rodam por padrão mesmo sem --only.
OPT_IN_STEPS="toolbx gui-access"

usage() {
    cat <<EOF
Uso: ./setup.sh [--profile=host|vm] [--only=modulo1,modulo2] [--skip=modulo1,modulo2] [--defaults]

Perfis:
  host   Workstation pessoal com GUI e hospedeiro de VMs. Padrão.
  vm     A VM de agentes: Podman rootless, CLIs de agente, servidor do OpenCode.
         Use dentro da VM, não no host.

  --profile=vm            Escolhe a camada. Sem --profile, assume host.

Módulos:
  --only=modulo1,modulo2   Roda apenas os módulos listados, dentro do perfil.
  --skip=modulo1,modulo2  Roda o perfil inteiro, exceto os módulos listados.
    --defaults               Aceita TODOS os defaults, para rodar sem terminal. É o que
                            torna o provisionamento não interativo. Um default de "sim"
                            instala; um de "não" pula. Os defaults são escolhidos para
                            que "default" signifique "provisionar": o que está na lista
                            de passos do perfil instala, e o que seria entrada para um
                            serviço externo — ou destruir uma credencial — não.
    --yes, -y                Alias de --defaults. O nome antigo significava "responde
                            sim a TUDO", e como nove dos nove prompts tinham default
                            "não", isso invertia cada opt-in: media que travava para
                            sempre no handshake do gh, que e uma pergunta DELE e nao
                            deste script.
                            Usa a senha padrão do dashboard (e a diz), deixa a
                            senha do OpenCode ser a aleatória do instalador, e
                            instala o OpenDesign no modo CONTAINER.
                            A GitHub App fica inativa: a private key é um
                            segredo que existe fora da máquina.
                            Sem esta flag, um Enter não instala nada.

Módulos de cada perfil:
  host: ${HOST_STEPS// /, }
  vm:   ${VM_STEPS// /, }

${OPT_IN_STEPS// / e } são opt-in: ficam fora da execução normal e só rodam
com --only. ai-clis e opencodex são de terceiros e perguntam antes de agir.
EOF
}

PROFILE="host"
ONLY=""
SKIP=""
ASSUME_DEFAULTS=0
for arg in "$@"; do
    case "$arg" in
        --profile=*) PROFILE="${arg#*=}" ;;
        --only=*) ONLY="${arg#*=}" ;;
        --skip=*) SKIP="${arg#*=}" ;;
        --defaults|--yes|-y) ASSUME_DEFAULTS=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Argumento desconhecido: $arg" >&2
            usage
            exit 1
            ;;
    esac
done

case "$PROFILE" in
    host) PROFILE_STEPS="$HOST_STEPS" ;;
    vm) PROFILE_STEPS="$VM_STEPS" ;;
    *)
        echo "Perfil desconhecido: '$PROFILE'. Use --profile=host ou --profile=vm." >&2
        exit 1
        ;;
esac

# --only é validado contra o perfil, e --skip não. A assimetria é deliberada:
# pedir um módulo que a camada não tem é um erro de quem pediu, e falhar alto
# evita instalar Podman no host só porque alguém typou. Pular um módulo que a
# camada não tem é inocuo, então --skip apenas avisa.
validate_only() {
    local step
    [ -z "$ONLY" ] && return
    for step in ${ONLY//,/ }; do
        if [[ " $ALL_STEPS " != *" $step "* ]]; then
            echo "Módulo desconhecido em --only: '$step'" >&2
            usage
            exit 1
        fi
        if [[ " $PROFILE_STEPS " != *" $step "* ]]; then
            echo "'$step' não pertence ao perfil '$PROFILE'." >&2
            echo "  No perfil '$PROFILE' existem: ${PROFILE_STEPS// /, }" >&2
            echo "  Se você quer esta camada, rode com o outro perfil." >&2
            exit 1
        fi
    done
}
validate_only

validate_skip() {
    local step
    [ -z "$SKIP" ] && return
    for step in ${SKIP//,/ }; do
        if [[ " $ALL_STEPS " != *" $step "* ]]; then
            echo "Módulo desconhecido em --skip: '$step'" >&2
            usage
            exit 1
        fi
        if [[ " $PROFILE_STEPS " != *" $step "* ]]; then
            echo -e "${YELLOW}  Aviso: '$step' não pertence ao perfil '$PROFILE'; o --skip não tem efeito.${NC}" >&2
        fi
    done
}
validate_skip

# Pertencência ao perfil vem antes de --only/--skip: um módulo que a camada não
# tem não roda, aconteça o que acontecer com os refinamentos.
in_profile() {
    [[ " $PROFILE_STEPS " == *" $1 "* ]]
}

# toolbx e gui-access são opt-in dentro do perfil host: só rodam se pedidos via
# --only. Isso NÃO é expressado como SKIP implícito. A versão anterior usava
# `SKIP="$OPT_IN_STEPS"` com a lista separada por espaço, e o matcher de
# should_run compara por vírgula — então o padrão nunca casava, e os dois módulos
# rodavam num run normal, contrariando o que o README e o ARQUITETURA dizem.
# Testar a pertencia direto remove o formato duplo, que era a origem do bug.
is_opt_in() {
    local step="$1" other
    for other in $OPT_IN_STEPS; do
        [ "$other" = "$step" ] && return 0
    done
    return 1
}

# Pertencência ao perfil vem antes de --only/--skip: um módulo que a camada não
# tem não roda, aconteça o que acontecer com os refinamentos. E o opt-in só cede
# a --only — declará-lo opcional e deixá-lo no caminho normal seria declarar uma
# coisa e fazer outra.
should_run() {
    local step="$1"
    in_profile "$step" || return 1
    # O --skip vence sempre, mesmo que o módulo também esteja no --only. Sem
    # esta checagem antes, o `return` dentro do `if [ -n "$ONLY" ]` impedia o
    # --skip de ser lido, e "--only=X --skip=X" rodava X. Uma exclusão explícita
    # nunca é anulada por um refinamento de conjunto.
    if [ -n "$SKIP" ] && [[ ",$SKIP," == *",$step,"* ]]; then
        return 1
    fi
    if [ -n "$ONLY" ]; then
        [[ ",$ONLY," == *",$step,"* ]]
        return $?
    fi
    # Opt-in só cede a --only. Declará-lo opcional e deixá-lo no caminho normal
    # seria declarar uma coisa e fazer outra.
    if is_opt_in "$step"; then
        return 1
    fi
    return 0
}

# ==============================================================================
# Quando este script chega por pipe, ele se escreve em disco e segue
# ==============================================================================
#
# A forma de instalar um repositório de dotfiles com um comando só é esta: a
# pessoa digita o `curl | bash`, o script é lido pela entrada padrão em vez de
# vir de um arquivo, e a única coisa que ele pode fazer é se colocar no disco.
#
# Recusar seria a resposta comfortable, e estaria errada. O motivo original da
# recusa — o script pergunta coisas e o `read` morre no fim da entrada — continua
# valendo, e é por isso que ela SÓ vale sem `--defaults`. Com a flag, não há
# pergunta a fazer, e o caminho por pipe é legítimo.
#
# Sem a flag e por pipe, o script se obtém, avisa que a partir daqui ele é
# interativo, e recusa a continuar se não houver terminal. Essa é a parte que não
# se negocia: um script que pergunta e não tem onde receber a resposta morre no
# meio, e morrer no meio sem mensagem é o pior desfecho possível.
#
# Os anexos vêm junto porque este script os lê, e a lista é EXTRAÍDA do próprio
# script em vez de escrita à mão: uma lista escrita à mão desatualiza em silêncio
# quando o script ganha uma dependência nova, e ninguém percebe até uma VM nova
# falhar num módulo.

# Os arquivos que este script lê de `$SCRIPT_DIR`, além dele mesmo. Deriva do
# código de propósito — é a mesma lista que a checagem estrutural confere, e as
# duas leem a mesma fonte.
# A lista vem do CÓDIGO, e não de uma lista escrita à mão. A diferença importa:
# uma lista à mão desatualiza em silêncio quando o script ganha uma dependência
# nova, e ninguém percebe até uma VM nova falhar num módulo.
#
# E o filtro é `\$SCRIPT_DIR/`, que é o caminho de um ARQUIVO. O mesmo script usa
# `$SCRIPT_DIR` para diretório também, e um diretório não é algo para baixar.
# O filtro e por EXTENSAO, e eu comecei com um que pegava so `*.algo` — o que
# perdeu o `zshrc`, que nao tem extensao. Um filtro por FORMATO DE NOME e um
# palpite sobre o que o script usa, e a lista resultante e silenciosamente
# incompleta: o `setup.sh` baixa dois anexos, baixa um, e o modulo do `zshrc`
# falha depois.
#
# O filtro certo e por CONTEUDO: pegamos toda referencia a `$SCRIPT_DIR` e
# descartamos as que, no proprio repositorio, sao DIRETORIO. A lista continua
# vindo do codigo, e agora vem inteira.
# O segundo argumento e o `setup.sh` BAIXADO. Ler `${BASH_SOURCE[0]}` funciona no
# caminho por pipe, porque o script E o arquivo lido — mas isso e uma coincidencia
# do caso, e nao uma propriedade: num teste que copia esta funcao para outro
# arquivo, a lista volta vazia e parece um bug da funcao. Passar o caminho
# explicitamente deixa a dependencia visivel e o comportamento igual nos dois casos.
# O segundo argumento e o `setup.sh` BAIXADO; o terceiro e a URL base.
#
# O filtro de existencia olha para a URL, e nao para o destino — e essa troca e
# a correcao de um bug que era CIRCULAR: a funcao aceitava um anexo so se ele ja
# estivesse no destino, que e justamente o arquivo que ainda nao existe. A lista
# saia vazia, o script se montava sozinho, e o modulo do `zshrc` falhava depois
# com "arquivo ausente" — um sintoma que aponta para o modulo, e nao para a
# montagem, que e a forma mais cara de um erro aparecer no lugar errado.
#
# Ler `${BASH_SOURCE[0]}` em vez do caminho passado tambem funciona no script
# real, porque ele E o arquivo lido. Mas isso e coincidencia do caso, nao
# propriedade: um teste que copia a funcao para outro arquivo tem a lista vazia e
# parece um bug da funcao. Passar o caminho explicitamente torna a dependencia
# visivel e o comportamento igual nos dois casos.
_anexos_necessarios() {
    local quem="$1" url_base="$2" rel
    grep -oE '\$SCRIPT_DIR/[a-zA-Z0-9/._-]+' "$quem" 2>/dev/null \
        | sort -u | sed 's|^\$SCRIPT_DIR/||' | while read -r rel; do
            [ -n "$rel" ] || continue
            # Um HEAD evita baixar um anexo que nao existe e descobrir so no 404.
            # `curl -fI` devolve codigo diferente de zero para um 404, que e o que
            # importa aqui.
            if curl -fsI "$url_base/$rel" >/dev/null 2>&1; then
                printf '%s\n' "$rel"
            fi
        done
}

# Uma URL de raw que devolveu HTML em vez do arquivo não pode passar: o script
# receberia uma página e a executaria. O `curl -f` não pega isso, porque a
# resposta é 200.
_baixar_anexo() {
    local rel="$1" destino="$2" url="$3"
    # O `Content-Type` e a pergunta certa, e a checagem do conteudo do arquivo e a
    # errada de um jeito que so aparece aqui: o proprio filtro procurava
    # `<!DOCTYPE html|<html` no arquivo baixado, e a LINHA DO FILTRO ESTAVA NELE.
    # O script se rejeitava — a montagem nunca passava, e o sintoma era
    # "não consegui baixar o setup.sh" com um `GET 200` no log do servidor.
    #
    # Um `raw` de repositorio privado devolve uma pagina HTML, e o curl -f nao
    # pega: a resposta e 200. O que distingue a pagina do arquivo e o tipo
    # declarado, e e isso que se pergunta.
    local ctype
    ctype="$(curl -fsSLI "$url" 2>/dev/null | tr -d '\r' \
        | sed -n 's/^[Cc]ontent-[Tt]ype:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"
    case "${ctype:-}" in
        text/html | application/xhtml+xml*)
            return 1 ;;
    esac

    if ! curl -fsSL "$url" -o "$destino" 2>/dev/null; then
        return 1
    fi
    # Estado, nao confianca: o arquivo chegou, e agora e preciso ver se tem o que
    # um arquivo tem. O `-s` pega o caso do corpo vazio, que o `-f` nao pega.
    [ -s "$destino" ] || { rm -f "$destino"; return 1; }
    return 0
}

# Coloca o script e seus anexos no disco, e re-executa dali. O `exec` substitui o
# processo, então o script só roda uma vez de verdade: sem ele, o script original
# continuaria depois do download, com o `SCRIPT_DIR` apontando para o lugar
# errado.
_se_colocar_no_disco_e_reexecutar() {
    local url_base="$1" destino_dir="$2"
    shift 2
    local args=("$@")

    mkdir -p "$destino_dir" || return 1

    # O script primeiro: sem ele, os anexos não têm quem os use.
    if ! _baixar_anexo "setup.sh" "$destino_dir/setup.sh" "$url_base/setup.sh"; then
        echo "ERRO: não consegui baixar o setup.sh de $url_base/setup.sh" >&2
        echo "      O repositório precisa estar PÚBLICO para o caminho por pipe funcionar:" >&2
        echo "      um repositório privado devolve uma página de erro, não o arquivo." >&2
        return 1
    fi
    chmod 0755 "$destino_dir/setup.sh" 2>/dev/null || true

    # Agora os anexos. A lista vem do script que acabou de chegar, e não de uma
    # lista escrita aqui — que é o que a mantém verdadeira sem manutenção.
    local n=0 rel destino
    for rel in $(_anexos_necessarios "$destino_dir/setup.sh" "$url_base"); do
        destino="$destino_dir/$rel"
        mkdir -p "$(dirname "$destino")" || return 1
        if _baixar_anexo "$rel" "$destino" "$url_base/$rel"; then
            chmod 0755 "$destino" 2>/dev/null || true
            n=$((n + 1))
        else
            # Um anexo que falta é um módulo que vai falhar depois, com uma
            # mensagem que aponta para o sintoma. Melhor dizer agora e nomear o
            # arquivo.
            echo "ERRO: não consegui baixar o anexo '$rel'." >&2
            echo "      Ele é lido por este script, e sem ele um módulo falha depois." >&2
            return 1
        fi
    done

    echo "Repositório montado em $destino_dir ($n anexo(s) além do setup.sh)." >&2
    echo "A partir daqui o script é interativo." >&2
    echo

    cd "$destino_dir" || return 1
    # `exec` substitui o processo, entao o script so roda uma vez de verdade. O
    # `SCRIPT_DIR` do processo novo sai do caminho do arquivo que ele leu — e
    # esse e o diretorio certo, ao contrario do `BASH_SOURCE` do script original.
    exec bash ./setup.sh "${args[@]}"
}

# Recusa antecipada quando o stdin não é um terminal.
#
# As perguntas usam `read -rp`, que o bash só imprime quando o stdin é terminal.
# E `read` devolve 1 no fim da entrada; como algumas dessas leituras estão fora de
# um contexto `&&`, o `set -e` aborta o script — sem mensagem, com código 1, e
# depois do banner. Ou seja: um run por pipe morre no meio em vez de recusar.
#
# A escolha é recusar aqui, com mensagem, e não "seguir com o default". Seguir
# produziria um provisionamento parcial e silencioso, que é pior que não rodar.
#
# `--yes` é a exceção, e a exceção é explícita: com a flag, a recusa não acontece
# porque não há pergunta a fazer. O que muda com a flag, e o que NÃO muda:
#
#   --defaults responde o DEFAULT DECLARADO de cada pergunta, não "sim" para
#   tudo — a distinção é o que esta flag existe para corrigir. Ele usa a senha
#   padrão do dashboard (e a diz), deixa a senha do OpenCode ser a aleatória do
#   instalador, e instala o OpenDesign no modo CONTAINER, que é o único ponto em
#   que ele escolhe por conta própria. O login de pessoa do gh fica aceito no
#   host, mas o handshake NAO acontece: `gh auth login -w` abre o navegador e
#   espera, e foi onde o --yes antigo travava. A GitHub App fica INATIVA, porque
#   a private key é um segredo que existe fora da máquina e um App ID inventado
#   marcaria o módulo como configurado sem funcionar.
#
# O default continua sendo NÃO. Sem a flag, um Enter não instala nada.
# Sem `--defaults` e sem terminal, há dois casos que precisam de respostas
# diferentes, e confundi-los custou um dia de trabalho.
#
# O caso BOM é o pipe de propósito: `curl ... | bash`. O script chegou pela
# entrada padrão, não tem onde se ler, e a única coisa que pode fazer é se colocar
# no disco. Recusar aqui seria recusar o caminho de instalação mais direto que
# existe, e sem motivo: o script tem a URL, tem o `curl`, e tem o que fazer.
#
# O caso MAU é o pipe sem propósito: `./setup.sh < /dev/null` em CI, um
# redirecionamento qualquer. Aqui o script está no disco e a recusa vale — ele
# perguntaria coisas e o `read` morreria no fim da entrada, sem mensagem, no meio.
#
# A diferença entre os dois é uma, e é verificável: de onde o script veio.
# ── Veio por pipe? O script não está no disco: ele se coloca no disco. ──────
#
# ESTE `if` fica ANTES do do pipe acidental, e é separado dele. A montagem
# estava dentro do tratamento do pipe acidental, que é condicional a
# `--defaults` — e o caminho do `curl` é não-terminal COM `--defaults`, então a
# condição nunca era verdadeira e a montagem nunca rodava.
#
# O motivo de a montagem ser necessária em qualquer caso é que `SCRIPT_DIR` é o
# diretório de onde a pessoa digitou, quando o script vem de um pipe. E
# `SCRIPT_DIR` não é cosmético: o módulo do `zshrc` faz `ln -s "$SCRIPT_DIR/zshrc"`
# e o `gh-app` instala `"$SCRIPT_DIR/bin/gh-app-token.sh"`. Com o `SCRIPT_DIR`
# errado, os dois fabricam caminhos que não existem, e o primeiro deixa um symlink
# quebrado na máquina.
if [ ! -t 0 ] && [ ! -s "${BASH_SOURCE[0]:-}" ]; then
    _url_base="https://raw.githubusercontent.com/${REPO_SLUG}/main"
    if [ -n "$SETUP_ORIGIN" ]; then
        _url_base="https://raw.githubusercontent.com/${SETUP_ORIGIN}/main"
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERRO: este script veio por pipe e não achou o 'curl' para se obter." >&2
        echo "      Num Fedora novo o curl vem de fábrica; se não veio:" >&2
        echo "      sudo dnf install -y curl" >&2
        exit 1
    fi
    if ! _se_colocar_no_disco_e_reexecutar "$_url_base" "$SETUP_DESTINO" "$@"; then
        # A montagem FALHOU, e sem isto o script continuaria: os módulos usariam um
        # `SCRIPT_DIR` que é o diretório de onde a pessoa digitou, e o módulo do
        # `zshrc` criaria um symlink quebrado em `$HOME`. Medido na VM nova.
        echo "ERRO: não consegui me montar no disco, e sem isso os módulos" >&2
        echo "      usariam um caminho errado. A saída acima diz o motivo." >&2
        exit 1
    fi
    exit 1
fi

# ── O script está no disco e a entrada não é terminal: pipe acidental ───────
#
# Sem `--defaults` e sem terminal, há dois casos que precisam de respostas
# diferentes, e confundi-los custou um dia de trabalho.
#
# O caso BOM é o pipe de propósito: `curl ... | bash`. O script chegou pela
# entrada padrão, não tem onde se ler, e a única coisa que pode fazer é se colocar
# no disco — o que o `if` acima já fez.
#
# O caso MAU é o pipe sem propósito: `./setup.sh < /dev/null` em CI. Aqui o
# script está no disco e a recusa vale — ele perguntaria coisas e o `read` morreria
# no fim da entrada, sem mensagem, no meio.
if [ ! -t 0 ] && [ "${ASSUME_DEFAULTS:-0}" != "1" ]; then
    if [ -f "${BASH_SOURCE[0]}" ] && [ -s "${BASH_SOURCE[0]}" ]; then
        echo "Este script precisa de um terminal: ele pergunta coisas antes de agir." >&2
        echo "" >&2
        echo "stdin não é um terminal (pipe, redirecionamento ou CI), e este script está" >&2
        echo "no disco — então o pipe é acidental. O comportamento seria morrer no meio," >&2
        echo "sem aviso, em vez de recusar — por isso a recusa é aqui." >&2
        echo "" >&2
        echo "Para rodar de verdade: abra um terminal e execute './setup.sh'." >&2
        echo "Para rodar sem interação (pipe ou CI): './setup.sh --defaults'." >&2
        echo "Para inspecionar sem rodar: './setup.sh --help'." >&2
        exit 1
    fi

    # Veio pela entrada padrão: este é o caminho de instalação. Se a URL de
    # origem é conhecida, ele se obtém; se não é, diz como chamá-lo.
    #
    # E antes: veio por pipe SEM nenhum argumento? Essa é a combinação perigosa,
    # e ela é mais provável do que parece. `curl -fsSL URL | bash` é a forma que
    # todo mundo escreve e ela FUNCIONA — o script inteiro roda, com o perfil
    # `host`. Numa VM de agentes, isso provisiona a camada da máquina de trabalho
    # e não a da fronteira, sem aviso e com exit 0.
    #
    # A causa é do bash: sem o `-s`, o primeiro argumento depois do pipe vira nome
    # de arquivo. Então `| bash --profile=vm` morre com "No such file or
    # directory" — erro visível —, e `| bash` sem nada roda errado — erro
    # invisível. O segundo é o que precisa de defesa.
    if [ "$#" -eq 0 ] && [ -z "${SETUP_ORIGIN:-}" ]; then
        echo "Este script veio por pipe sem nenhum argumento, e isso instala o perfil" >&2
        echo "'host' — a camada da máquina de trabalho, não a da VM de agentes." >&2
        echo "" >&2
        echo "Para uma VM de agentes, o comando completo é:" >&2
        echo "" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/main/setup.sh \\"
        echo "    | bash -s -- --profile=vm --defaults" >&2
        echo "" >&2
        echo "O '-s --' não é decoração: sem ele, '--profile=vm' vira nome de arquivo" >&2
        echo "e o bash morre. E sem '--' os argumentos somem, e o perfil vira 'host'." >&2
        echo "" >&2
        echo "Se a intenção era provisionar esta máquina de trabalho, siga com:" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/main/setup.sh \\"
        echo "    | bash -s -- --profile=host" >&2
        exit 1
    fi

    _url_base="https://raw.githubusercontent.com/${REPO_SLUG}/main"
    if [ -n "$SETUP_ORIGIN" ]; then
        _url_base="https://raw.githubusercontent.com/${SETUP_ORIGIN}/main"
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERRO: este script veio por pipe e não achou o 'curl' para se obter." >&2
        echo "      Num Fedora novo o curl vem de fábrica; se não veio:" >&2
        echo "      sudo dnf install -y curl" >&2
        exit 1
    fi
    if ! _se_colocar_no_disco_e_reexecutar "$_url_base" "$SETUP_DESTINO" "$@"; then
        # A montagem FALHOU, e sem isto o script continuava: o `ln -s` do modulo
        # do `zshrc` usava o `SCRIPT_DIR` do script ORIGINAL — que, vindo de um
        # pipe, e o diretorio de onde a pessoa digitou. O resultado medido na VM
        # nova foi um `~/.zshrc` apontando para `/home/agent/zshrc`, que nao
        # existe, e nenhum `setup.sh` em lugar nenhum do disco.
        #
        # Um modulo que instala um symlink para um caminho que o proprio script
        # fabricou e um modulo que cria lixo permanente. Falhar em voz alta e
        # melhor que seguir assumindo que deu certo.
        echo "ERRO: não consegui me montar no disco, e sem isso os módulos" >&2
        echo "      usariam um caminho errado. A saída acima diz o motivo." >&2
        exit 1
    fi
    exit 1
fi

case "$PROFILE" in
    host) echo -e "${BLUE}=== Setup do Fedora Workstation: workstation pessoal + hospedeiro de VMs ===${NC}\n" ;;
    vm) echo -e "${BLUE}=== Setup da VM de agentes: a fronteira ===${NC}\n" ;;
esac

# A versão, logo abaixo do banner. Ela está na PRIMEIRA e na ÚLTIMA linha do
# arquivo também, e nos dois lugares por um motivo que a experiência mostrou: o
# `raw` do GitHub já serviu versão velha desta URL, e a forma de saber qual
# script rodou é ler a versão de um lado ou do outro.
#
# Quem tem a tela lê esta linha. Quem tem o arquivo — porque o `curl` falhou, ou
# porque quer conferir antes de rodar — lê a última linha.
echo -e "${BLUE}setup.sh ${SETUP_VERSION}${NC}\n"

if should_run "git" || should_run "ssh"; then
    prompt_git_identity
fi

# Pede a App ID e a private key, e grava num par de arquivos 600.
#
# A chave é lida linha a linha num laço, e não com um `read` único, porque um PEM
# tem várias linhas: um `read` pegaria só a primeira e o resto viraria comando do
# shell. O laço para no marcador `-----END ... PRIVATE KEY-----` e tem um teto de
# linhas, para não ficar esperando para sempre se o paste vier truncado.
#
# A chave é guardada em arquivo, e não em variável que atravesse o script: o
# objetivo de não travar o terminal no meio é que o operador possa sair de perto,
# e um segredo em memória durante toda a execução seria a contrapartida disso. O
# arquivo é 600 e nunca entra no repositório.
GH_APP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-app"
GH_APP_KEY_FILE="$GH_APP_DIR/private-key.pem"
GH_APP_ID_FILE="$GH_APP_DIR/app-id"

prompt_github_app() {
    # `--yes` NÃO pode preencher isto, e o motivo não é limitação do script: a
    # private key é um segredo que existe fora da máquina. Inventar um App ID
    # deixaria o módulo "configurado" sem nada funcionando, que é o pior desfecho
    # possível — o `gh` voltaria a pedir login e o relatório diria que está tudo
    # certo. Então o módulo fica INATIVO, e isso é dito.
    if [ "${ASSUME_DEFAULTS:-0}" = "1" ] && [ ! -s "$GH_APP_KEY_FILE" ]; then
        echo -e "${YELLOW}GitHub App pulada (--defaults).${NC}"
        echo -e "  A private key é um segredo que existe fora da máquina, e um App ID"
        echo -e "  inventado deixaria o módulo marcado como configurado sem funcionar."
        echo -e "  O módulo fica inativo e o \`gh\` volta a pedir login. Para ativar:"
        echo -e "    ./setup.sh --profile=vm --only=gh-app"
        return 1
    fi
    echo -e "${BLUE}GitHub App — identidade da máquina no GitHub${NC}"
    echo -e "  É o que permite abrir PR, escrever issue e comentar sem token de conta."
    echo -e "  A App precisa estar instalada nos repositórios que a VM vai tocar."
    # Em branco mantém o que já está em disco. Sem isto toda reexecução exigiria
    # colar a chave de novo, e o pior efeito seria silencioso: com a App já
    # configurada e o prompt pulado, o módulo não reinstala nem revalida os
    # executáveis, e o relatório mente sobre o estado real da máquina.
    local app_id="" key="" linha
    if [ -s "$GH_APP_KEY_FILE" ] && [ -s "$GH_APP_ID_FILE" ]; then
        echo -e "  Já há uma App configurada. Em branco mantém; qualquer outro valor substitui."
        pergunta "  App ID: " app_id
        if [ -z "$app_id" ]; then
            echo -e "${GREEN}  Mantida a App já configurada em $GH_APP_DIR.${NC}"
            return 0
        fi
    else
        pergunta "  App ID [${DEFAULT_GH_APP_ID}]: " app_id
        app_id="${app_id:-$DEFAULT_GH_APP_ID}"
        if [ -z "$app_id" ]; then
            echo -e "${YELLOW}  Sem App ID: o módulo gh-app fica inativo e o gh exigirá login.${NC}"
            return 1
        fi
    fi

    echo -e "  Cole a private key inteira. A leitura é muda: o conteúdo não é ecoado, mas"
    echo -e "  cada ponto abaixo é uma linha que entrou, para você ver o paste chegando."
    echo -e "  Para desistir, Ctrl-D. Linha em branco não cancela: um paste traz uma antes"
    echo -e "  do bloco, e tratar isso como cancelamento quebraria o paste."
    local limite=60 n=0 viu_begin=0
    while IFS= read -r -s linha; do
        n=$((n + 1))
        # Linha vazia é ignorada, em qualquer posição, por duas razões que importam.
        # A primeira é o \r de um CRLF: o tty tem ICRNL ligado, então cada linha do
        # paste chega partida em duas, e sem isto o arquivo sairia com linhas vazias
        # no meio — que o openssl recusa. A segunda é a linha vazia que um paste
        # traz ANTES do bloco, que um cancelamento por "primeira linha vazia"
        # transformaria em falha. Um PEM de verdade não tem linha em branco, então
        # ignorar é seguro.
        [ -z "$linha" ] && continue
        key+="$linha"$'\n'
        printf '.'
        # Só os marcadores são notados, nunca o conteúdo: é o bastante para dizer
        # "o paste não chegou" de "chegou truncado", que são falhas diferentes.
        case "$linha" in *"-----BEGIN "*"PRIVATE KEY-----"*) viu_begin=1 ;; esac
        # O casamento é por substring de propósito: com *bracketed paste*, o
        # terminal entrega o bloco inteiro como UMA linha com newlines embutidos, e
        # nesse caso a única forma de achar o fim é procurar o marcador dentro dela.
        case "$linha" in
            *"-----END "*"PRIVATE KEY-----") break ;;
        esac
        limite=$((limite - 1))
        if [ "$limite" -le 0 ]; then
            printf '\n'
            echo -e "${YELLOW}  Li ${n} linhas e não vi -----END ... PRIVATE KEY-----." >&2
            if [ "$viu_begin" = "0" ]; then
                echo -e "${YELLOW}  Também não vi -----BEGIN ... PRIVATE KEY-----, o que significa${NC}" >&2
                echo -e "${YELLOW}  que o paste não chegou ao prompt. Cole a chave INTEIRA, do${NC}" >&2
                echo -e "${YELLOW}  BEGIN ao END, e espere os pontos aparecerem.${NC}" >&2
            else
                echo -e "${YELLOW}  Vi o BEGIN, então o paste entrou mas ficou truncado. Cole de novo.${NC}" >&2
            fi
            unset key linha
            return 1
        fi
    done
    printf '\n'

    # Higiene, não correção: medido, o `openssl` ACEITA um PEM cujas linhas terminam
    # em CR. Isto é para o arquivo ficar canônico, e cobre também o CR que ficaria
    # no MEIO de `$linha` se o paste chegasse como uma leitura única.
    key="${key//$'\r'/}"

    if [ -z "$key" ]; then
        echo -e "${YELLOW}  Sem private key: o módulo gh-app vai ficar inativo.${NC}" >&2
        return 1
    fi

    # Valida **antes** de gravar. Sem isto, um Ctrl-D no meio do paste deixaria um
    # arquivo truncado em disco com a App marcada como configurada, e o "gravados"
    # seria mentira. A validação é local e não usa API.
    # `openssl` é dependência dura deste passo E do helper. Sem esta checagem, uma
    # máquina sem o pacote produz "command not found", que com o erro suprimido
    # virava "a chave que você colou é inválida" — uma acusação falsa contra quem
    # colou, causada por uma dependência ausente. Aconteceu numa VM real.
    if ! command -v openssl &>/dev/null; then
        echo -e "${YELLOW}  'openssl' não está instalado, então a chave não pode ser validada.${NC}" >&2
        echo -e "${YELLOW}  Instale com 'sudo dnf install openssl' e rode o módulo de novo;${NC}" >&2
        echo -e "${YELLOW}  a chave não foi gravada.${NC}" >&2
        unset key app_id linha
        return 1
    fi

    # Valida num arquivo temporário, e o temporário vai embora. Uma versão anterior
    # guardava a captura em `rejected.pem` para eu poder inspecionar por que o
    # openssl recusava: turned out a chave estava boa e o openssl não estava
    # instalado. Era uma segunda cópia de uma chave privada em disco, existindo
    # só por causa de um erro meu — e uma superfície de ataque que não compensa
    # nenhum diagnóstico. A mensagem do próprio openssl é o diagnóstico certo.
    local PROV; PROV=$(mktemp)
    printf '%s' "$key" > "$PROV"
    if ! PROV_ERR=$(openssl pkey -in "$PROV" -noout 2>&1); then
        rm -f "$PROV"; unset key app_id linha
        echo -e "${YELLOW}  O openssl recusou a chave colada; nada foi gravado.${NC}" >&2
        echo -e "${YELLOW}  O openssl disse: ${PROV_ERR}" >&2
        echo -e "${YELLOW}  Os pontos acima devem mostrar ~28 linhas. Se apareceram poucas,${NC}" >&2
        echo -e "${YELLOW}  o paste não chegou inteiro — cole do BEGIN ao END.${NC}" >&2
        return 1
    fi

    # `umask` num subshell, e não aqui: um `umask 077` nesta função mudaria o umask
    # do processo do setup.sh inteiro, e todo arquivo criado depois na VM nasceria
    # 600 por efeito colateral de uma função de prompt.
    ( umask 077
      mkdir -p "$GH_APP_DIR"
      install -m 600 /dev/null "$GH_APP_KEY_FILE"
      install -m 600 /dev/null "$GH_APP_ID_FILE" )
    printf '%s' "$key" > "$GH_APP_KEY_FILE"
    printf '%s' "$app_id" > "$GH_APP_ID_FILE"
    rm -f "$PROV"
    unset key app_id linha
    echo -e "${GREEN}  App ID e private key gravados em $GH_APP_DIR (600).${NC}"
    return 0
}

provision_tailscale() {
    if ! command -v tailscale &> /dev/null; then
        # Repo oficial + dnf install, em vez de "curl | sh": o instalador oficial
        # da Tailscale faz exatamente isso por baixo dos panos, mas preferimos
        # ser explícitos aqui — sem rodar um script remoto como root a cada vez,
        # e com verificação GPG nativa do dnf nos pacotes.
        TAILSCALE_REPO_URL="https://pkgs.tailscale.com/stable/fedora/tailscale.repo"
        sudo dnf config-manager addrepo --from-repofile="$TAILSCALE_REPO_URL"
        sudo dnf install -y tailscale
        echo -e "${GREEN}✓ Tailscale instalado.${NC}"
    else
        echo -e "${YELLOW}Tailscale já instalado.${NC}"
    fi

    sudo systemctl enable --now tailscaled

    if ! sudo tailscale status &> /dev/null; then
        # Sem --ssh de propósito: o Tailscale SSH exige reautenticação
        # interativa via navegador sempre que a política da tailnet tiver
        # "action: check" nos grants de ssh (o default da maioria das
        # tailnets) — quebra qualquer ferramenta que não sabe abrir um
        # navegador (Codex Desktop, devpod não-interativo, etc.), e tem
        # aviso oficial de incompatibilidade com SELinux enforcing no
        # Fedora. O acesso SSH de verdade já é coberto pelo módulo
        # sshd-hardening (só chave, sem senha) + firewalld (sshd só na
        # interface tailscale0) — sem depender de reautenticação alguma.
        if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
            # A máquina não está conectada, e `tailscale up` abre o navegador e
            # ESPERA. Deixar isso aqui era o mesmo modo de falha que travou o
            # `--yes` antigo no handshake do `gh`, agora no módulo que dá acesso
            # à máquina: numa VM nova este é o caminho que o run sempre pega.
            #
            # A saída é a dos outros passos de terceiro: fazer o que dá e
            # escrever o que falta, com o comando. Um run não interativo não tem
            # navegador, e não tem conta — e a conexão depende dos dois.
            #
            # Não é uma falha do run: é uma pendência, e a pós-condição que
            # publica na tailnet vai reportá-la por estado. O run acaba dizendo
            # "1 pendência" em vez de "pronto", que é a verdade.
            echo -e "${YELLOW}Tailscale instalado; falta entrar na tailnet.${NC}" >&2
            echo -e "${YELLOW}  Este passo precisa de um navegador e da sua conta, então o${NC}" >&2
            echo -e "${YELLOW}  --defaults não o faz. Rode, quando quiser:${NC}" >&2
            echo -e "${YELLOW}    sudo tailscale up${NC}" >&2
            echo -e "${YELLOW}  Sem isso a VM não entra na tailnet, e as publicações em :8443${NC}" >&2
            echo -e "${YELLOW}  :8444 e :8445 ficam sem caminho. Todo o resto do run segue.${NC}" >&2
            _registrar_falha "Tailscale instalado mas nao conectado: rode 'sudo tailscale up'"
            return 0
        fi
        echo -e "${YELLOW}Rodando 'tailscale up' — abra o link exibido para autenticar.${NC}"
        sudo tailscale up
    else
        echo -e "${GREEN}✓ Tailscale já conectado.${NC}"
    fi
}

# ==============================================================================
# Confirmações antecipadas — tudo que pergunta é perguntado aqui, no começo, pra
# você poder sair de perto do terminal depois e o script rodar até o fim sem parar
# no meio esperando resposta.
#
# Cobre hoje: identidade Git, hostname, `sshd-hardening`, `ai-clis`, a senha do
# servidor do OpenCode, e o `tailscale up` (que precisa de pausa porque a URL só
# existe quando ele roda, e roda logo abaixo, depois do `sudo -v`).
#
# A ÚNICA pausa condicional que sobrou é o `gh auth login -w`, dentro do módulo
# `git`: é uma definição de função, então aparece aqui no arquivo, mas executa
# durante o provisionamento. Ela só acontece **se** a pergunta do login de pessoa
# for respondida com `y`. Responder nada deixa o `gh` sem token próprio, com a
# GitHub App cobrindo a API que os agentes usam.
#
# Os dois convivem de propósito: o `gh` puro tem login de pessoa, o `gh-app` tem
# identidade de máquina. Ligar o `GH_TOKEN` no módulo `git` tiraria a pausa sem
# perguntar nada, e não está feito.
# ==============================================================================
CURRENT_HOSTNAME=""
NEW_HOSTNAME=""
CONFIRM_HOSTNAME=""
if should_run "hostname"; then
    CURRENT_HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname)"
    # No perfil `vm` o default deixa de ser "manter o atual" e passa a ser um nome
    # gerado. A razão de o `host` manter o comportamento antigo é a mesma do
    # hardening: na VM este script é a história inteira da máquina, e um hostname
    # que distingue uma VM da outra é o que torna o nome útil; no host o nome é
    # escolha de quem usa a máquina, e um Enter continua significando "não mexe".
    # A sugestão vale para os DOIS perfis, e o que decide é se o hostname atual JÁ é
    # um nome gerado por este script. Reconhecer o esquema é o que torna o passo
    # idempotente, e reconhecer
    # e **não perguntar** são coisas diferentes — a primeira versão deste bloco
    # reconhecia e perguntava assim mesmo, porque o `pergunta` estava fora do
    # if/else, e o resultado foi o pior dos dois: numa máquina já nomeada a
    # pergunta aparecia com a palavra "manter", a resposta vazia caía no `pergunta`
    # como se fosse um nome, e o `confirm` seguinte oferecia aplicar "1234" como
    # hostname.
    NEW_HOSTNAME_SUGGESTED=""
    if printf '%s' "$CURRENT_HOSTNAME" | grep -qE '^(vm|pc)-[a-z0-9]+-[a-z0-9]{4}$'; then
        echo "Hostname atual: $CURRENT_HOSTNAME  —  já é um nome gerado por este script; mantido."
    else
        NEW_HOSTNAME_SUGGESTED="$(suggest_hostname)"
        echo "Hostname atual: $CURRENT_HOSTNAME  —  o padrão deste repo é um nome próprio"
        pergunta "Novo hostname [$NEW_HOSTNAME_SUGGESTED]: " NEW_HOSTNAME
        NEW_HOSTNAME="${NEW_HOSTNAME:-$NEW_HOSTNAME_SUGGESTED}"
    fi
    # A pergunta acima JÁ É a decisão, e ela tem o mesmo formato das de identidade
    # (1-2): o default entre colchetes, e o Enter o aplica. Havia uma segunda
    # pergunta — "Alterar o hostname para X?" — que não decidia nada: quem
    # respondia a primeira com o nome padrão já tinha dito sim, e quem digitasse um
    # nome próprio também. Ela existia só para ter um lugar onde o default pudesse
    # ser "não", e o efeito era o oposto do pretendido: sob `--defaults` ela aceitava
    # o "não" e a VM nova ficava com o nome que o hypervisor deu, que é justamente
    # o que este passo existe para trocar.
    if [ -n "$NEW_HOSTNAME" ] && [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
        CONFIRM_HOSTNAME=1
    else
        NEW_HOSTNAME=""
        CONFIRM_HOSTNAME=0
    fi
fi

CONFIRM_DEVICE_KEYS=""
if should_run "device-keys"; then
    # Default SIM, e o motivo é medido: a fonte é `https://github.com/<conta>.keys`,
    # que é um arquivo PÚBLICO do GitHub — sem token, sem GitHub App, sem `gh`
    # autenticado. Medido nesta VM: HTTP 200, 405 bytes, 5 chaves ed25519.
    #
    # Eu havia dito o contrário ("depende da sua chave privada"), e o `authorized_keys`
    # da VM estava vazio só porque eu nunca tinha rodado este módulo. Um diagnóstico
    # que aponta a dependência errada é pior que nenhum: leva a uma conclusão
    # errada sobre o que é preciso para o script rodar.
    #
    # A pergunta continua existindo, e o default é o que a torna "por padrão" em
    # vez de "sempre": quem não quiser digita "n", e nada é tocado.
    confirm "Autorizar nesta máquina as chaves de dispositivos que o GitHub reúne (github.com/${GITHUB_KEYS_USER}.keys, arquivo público)? O bloco gerenciado é reescrito a cada execução, e chaves fora dele ficam intocadas" 1 \
        && CONFIRM_DEVICE_KEYS=1
fi

CONFIRM_SSHD_HARDENING=""
# A pergunta e a autoridade e' o modulo, que roda depois do `sudo -v` e decide pela
    # propriedade. Aqui o `sudo -n` ainda nao tem timestamp, entao este teste cai
    # para "nao endurecido" e a pergunta aparece mesmo ja HAVENDO sido aplicada — o
    # atrito de um prompt, e nada mais. Ver `_sshd_hardened`.
    if should_run "sshd-hardening" && ! _sshd_hardened; then
    # Default SIM **na VM**, e NÃO no host. A assimetria é deliberada e é a diferença
    # entre as duas máquinas, não uma inconsistência de escrita:
    #
    #   * na VM, este script é a história inteira. A senha do SSH é a credencial mais
    #     exposta que a máquina tem, e o `sshd-hardening` é o módulo que existe para
    #     desligá-la. Deixar o default em "não" significava que a proteção só
    #     acontecia se alguém lembrasse de responder "y" numa lista de prompts.
    #   * no host, é a máquina de todo dia, e desligar o login por senha é uma
    #     decisão sobre o modo como a pessoa trabalha. O prompt continua, e continua
    #     sem default.
    #
    # Em nenhum dos dois o module depende da resposta para não trancar ninguém: quem
    # protege é o guard `[ ! -s authorized_keys ]` lá no módulo, que pula se não há
    # chave. E o `device-keys` agora é default, e vem ANTES na lista — então na VM o
    # arquivo já está populado quando esta pergunta é feita.
    _sshd_default=0
    [ "$PROFILE" = "vm" ] && _sshd_default=1
    confirm "Desabilitar login por senha via SSH (só chave pública a partir daqui)?$( [ "$_sshd_default" = "1" ] && echo " A VM só tem chave." )" "$_sshd_default" \
        && CONFIRM_SSHD_HARDENING=1
fi

# Existe um usuário não-root que consiga entrar? Pergunta feita SEM sudo, de
# propósito: o bloco de perguntas roda ANTES do `sudo -v` mais abaixo, e qualquer
# leitura privilegiada aqui abriria uma segunda pausa para senha no meio do
# roteiro — o oposto do motivo de as perguntas ficarem todas no começo.
# `/etc/passwd` é legível por todo mundo, então a resposta sai sem privilégio.
have_login_user() {
    awk -F: '$3 >= 1000 && $7 !~ /(nologin|false)$/ { c++ } END { exit !(c > 0) }' /etc/passwd
}

CONFIRM_LOCK_ROOT=""
if should_run "sshd-hardening"; then
    if have_login_user; then
        confirm "Travar a senha do root (passwd -l)? O root deixa de autenticar por senha. sudo a partir do seu usuário continua igual, e a volta por console continua valendo." \
            && CONFIRM_LOCK_ROOT=1
    else
        # A máquina não tem por onde entrar além do root. Travar agora seria
        # exatamente o lockout que o resto do módulo existe para evitar.
        echo -e "${YELLOW}Travar o root: pulado, não há usuário não-root com shell de login nesta máquina.${NC}"
    fi
fi

CONFIRM_AI_CLIS=""
if should_run "ai-clis"; then
    confirm "Instalar as CLIs de IA (Claude Code, Codex, Cursor Agent, Open Code, Antigravity, DeepSeek Harness) nesta máquina? (opcional, já rodam nos devcontainers)" 1 && CONFIRM_AI_CLIS=1
fi

# A senha do servidor do OpenCode é perguntada sempre que o módulo `ai-clis` for
# aprovado, inclusive numa máquina nova em que o OpenCode ainda não está
# instalado: o instalador roda DEPOIS deste bloco, então condicionar a pergunta à
# existência do binário a faria sumir justamente na primeira execução, e o host
# ficaria com a senha aleatória do instalador.
#
# O valor em si é lido no momento do uso, porque segurar um segredo numa variável
# durante o script inteiro é pior do que travar o terminal uma vez.
CONFIRM_OPENCODE_PASSWORD=""
OPENCODE_PASSWORD=""
OPENCODE_PASSWORD_SET=0
if [ "$CONFIRM_AI_CLIS" = "1" ]; then
    confirm "Definir uma senha de sua preferencia para o servidor do OpenCode? (a senha e obrigatoria; em branco mantem a que o instalador gerar)" 1 && CONFIRM_OPENCODE_PASSWORD=1
    if [ "$CONFIRM_OPENCODE_PASSWORD" = "1" ]; then
        if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
            # A senha padrão é `opencode`, o nome do serviço — a mesma convenção do
            # dashboard do Hermes (`hermes`) e a mesma que a §6 da auditoria já
            # registra para as duas. E é a MESMA convenção do e-mail do GitHub: o
            # campo traz o valor entre colchetes, e um Enter o aceita.
            #
            # A versão anterior fazia o oposto, com um argumento que parecia bom: um
            # segredo escolhido em silêncio é um segredo que ninguém muda, e por isso
            # `--yes` deixava a senha aleatória do instalador. O problema é que
            # responder "sim" ao prompt e cair num `pergunta` que não lê devolve
            # VAZIO, e uma senha vazia é pior que uma senha adivinhável. Entre as
            # duas, a adivinhável é a que ao menos é declarada, é a mesma das outras
            # duas senhas do repo, e pode ser trocada com um comando.
            #
            # A alternativa seria devolver a senha ALEATÓRIA do instalador, que é o
            # que a versão anterior fazia — e aí o `--defaults` não honors a resposta
            # que deu.
            OPENCODE_PASSWORD="$OPENCODE_DEFAULT_PASSWORD"
            OPENCODE_PASSWORD_SET=1
            echo -e "  ${GREEN}--defaults: senha do servidor = '${OPENCODE_DEFAULT_PASSWORD}'.${NC}"
            echo -e "  É o nome do serviço, a mesma convenção de 'hermes' no dashboard."
            echo -e "  Troque depois com: opencode service set password"
        else
            echo -e "${BLUE}Senha do servidor do OpenCode${NC}"
            echo -e "  Ela é obrigatória: o servidor sempre liga basic auth em /api/*."
            if [ -f "$HOME/.config/opencode/service.json" ]; then
                echo -e "  Em branco, mantém a senha atual de ~/.config/opencode/service.json."
            else
                echo -e "  Em branco, aceita a senha aleatória que o instalador vai gerar."
            fi
            read -r -s -p "  Senha nova (vazio = manter): " OPENCODE_PASSWORD
            echo
            OPENCODE_PASSWORD_SET=1
        fi
    fi
fi

# A senha do dashboard do Hermes é perguntada no bloco de confirmações
# antecipadas, como a do opencode, e pelo mesmo motivo: o script não pode parar
# no meio do caminho para travar o terminal.
#
# A senha do Hermes é lida AQUI, mas o container recebe só o hash scrypt. O valor
# bruto é gravado num arquivo 600 e apagado da variável assim que usado.
# O modo do OpenDesign e perguntado sempre que qualquer um dos dois modulos pode
# rodar, e SEM padrao. Um padrao implicito seria uma escolha de arquitetura
# tomada em nome de quem nao foi perguntado — e a escolha aqui tem consequencia
# real e oposta em cada ramo: o nativo tem os agentes e expoe a porta interna, o
# container tem o TLS e nao tem agente nenhum.
#
# O token vai na MESMA pergunta, e pela razao de sempre: e segredo, e o script
# nao pode parar no meio do caminho para travar o terminal.
OPENDESIGN_TOKEN=""
OPENDESIGN_TOKEN_SET=0
if should_run "open-design" || should_run "open-design-container"; then
    echo -e "${BLUE}OpenDesign${NC}"
    echo -e "  Dois modos, com consequencias opostas. Medido nesta maquina:"
    echo -e "    ${GREEN}nativo${NC}    7 agentes disponiveis (opencode, agy, hermes, claude, codex...)"
    echo -e "              precisa escutar no IP da tailnet, entao expoe a $OPENDESIGN_PORT em HTTP sem TLS"
    echo -e "    ${YELLOW}container${NC} so existe atras do serve, com TLS, e nenhuma CLI do host roda dentro"
    echo
    if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
        # `--defaults` não tem como perguntar, e escolhe o modo CONTAINER. A
        # escolha é defendível porque o container é o modo com TLS e sem porta
        # interna exposta, que é o default certo para uma máquina de fronteira.
        #
        # Ela só é segura porque o passo `podman` agora instala o
        # `podman-compose`: sem esse provider, `podman compose` falha e este
        # default entregaria uma VM que não sobe. Foi medido nesta VM antes da
        # correção, e a ordem é o ponto — o pré-requisito vem antes do default.
        OPENDESIGN_MODE="container"
        echo -e "  ${GREEN}--defaults: instalando o modo CONTAINER (TLS, sem porta interna exposta).${NC}"
        echo -e "  ${GREEN}  Para o modo nativo, com as CLIs do host disponíveis dentro: responda 'n'.${NC}"
    else
    while :; do
        if ! read -r -p "  Modo [container/nativo]: " OPENDESIGN_MODE; then
            # EOF, e nao resposta invalida. A distincao importa: com entrada
            # invalida o loop repregunta, mas em EOF o `read` falha para sempre e
            # um `while :` sem este teste trava o script indefinidamente. Sem
            # padrao declarado, a saida correta em EOF e NAO INSTALAR.
            echo
            echo -e "${YELLOW}  Sem resposta: o OpenDesign nao sera instalado.${NC}" >&2
            OPENDESIGN_MODE=""
            break
        fi
        # Enter devolve vazio, e vazio é o default declarado: `container`. Sem
        # esta linha, apertar Enter cairia no `*)` e repreguntaria, o que faria do
        # default uma ilusão: o texto entre colchetes diria container e o
        # comportamento não faria.
        [ -n "$OPENDESIGN_MODE" ] || OPENDESIGN_MODE="container"
        OPENDESIGN_MODE="$(printf '%s' "$OPENDESIGN_MODE" | tr '[:upper:]' '[:lower:]')"
        case "$OPENDESIGN_MODE" in
            container | nativo) break ;;
            *) echo -e "${YELLOW}  Escolha 'container' ou 'nativo'.${NC}" ;;
        esac
    done
    read -r -s -p "  OD_API_TOKEN (vazio = gerar um): " OPENDESIGN_TOKEN
    fi
    echo
    OPENDESIGN_TOKEN_SET=1
    # Token vazio gera um, e é o que `--yes` faz: `openssl rand -hex 32` não tem
    # nada a perguntar. O token só importa se o auth estiver ligado, e no modo
    # nativo ele não está — o portão é o `tailscale serve`.
    [ -z "$OPENDESIGN_TOKEN" ] && OPENDESIGN_TOKEN="$(openssl rand -hex 32)"
    # A mensagem é por modo, e ela dizia só do nativo. No modo container o token
    # É a credencial da API — é o que o `deploy/.env` carrega para o daemon.
    if [ "$OPENDESIGN_MODE" = "container" ]; then
        echo -e "  token do daemon: gerado (no container ele É a credencial da API, e vai para o deploy/.env)"
    else
        echo -e "  token do daemon: gerado (não é usado no modo nativo; o portão é o serve)"
    fi
fi

HERMES_DASH_PASSWORD=""
HERMES_DASH_PASSWORD_SET=0
# A pergunta é condicionada ao PASSO, não a um `CONFIRM_HERMES` que nada
# definia: medido, `CONFIRM_HERMES` era lido aqui e não tinha nenhuma atribuição
# em todo o script, então `HERMES_DASH_PASSWORD` ficava vazio e a senha nunca era
# perguntada. O padrão é o do `gh-app` mais abaixo — sem y/N, porque a pergunta É
# a senha, e responder vazio tem o mesmo desfecho de responder não.
if should_run "hermes-dashboard"; then
    echo -e "${BLUE}Senha do dashboard do Hermes${NC}"
    echo -e "  Ela substitui o login do Nous Portal: com a senha definida o dashboard"
    echo -e "  não registra nada no Portal, e o erro de redirect_uri_mismatch não ocorre."
    echo -e "  ${YELLOW}ATENÇÃO: a senha provisoria do padrão e a mesma que o nome do serviço.${NC}"
    echo -e "  Ela é adivinhável por quem conheça a convenção, e o que ela protege é a"
    echo -e "  separação entre uma pessoa da tailnet e a sua sessão — não a máquina."
    if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
        # `--yes` assume a senha padrão, e DIZ qual é. Uma senha escolhida em
        # silêncio é uma senha que ninguém vai saber depois; o que o script grava
        # é o hash, e o texto claro só existe no arquivo 600 que ele gera.
        HERMES_DASH_PASSWORD="$HERMES_DASH_USER"
        echo -e "  ${GREEN}--defaults: usando a senha padrão '$HERMES_DASH_USER'.${NC}"
        echo -e "  ${YELLOW}Ela é a mesma que o nome do serviço. Troque depois.${NC}"
    else
        read -r -s -p "  Senha (vazio = a provisoria '$HERMES_DASH_USER'): " HERMES_DASH_PASSWORD
        echo
        [ -z "$HERMES_DASH_PASSWORD" ] && HERMES_DASH_PASSWORD="$HERMES_DASH_USER"
    fi
    HERMES_DASH_PASSWORD_SET=1
fi

# A App é perguntada sempre, e não com um y/N: a private key É a pergunta. Um
# "quer configurar?" seguido de "cole a chave" é atrito em duplicidade, e a
# resposta já está no que o operador colar. Se ele colar vazio, o módulo fica
# inativo e o `gh` volta a pedir login — que é o mesmo desfecho de responder não.
if should_run "gh-app"; then
    CONFIRM_GH_APP=0
    prompt_github_app && CONFIRM_GH_APP=1 || true
fi

# O login de pessoa do `gh` tem a MESMA semântica da App, pelo motivo oposto: lá a
# chave é a pergunta, aqui responder nada é a resposta. A ordem importa — a
# pergunta do login vem depois da App, porque quem só quer identidade de máquina
# não deve ver um pedido de token de conta antes de decidir isso.
if should_run "git"; then
    CONFIRM_GH_LOGIN=0
    # SIM no host, NÃO na vm, e a assimetria é o ponto: são ALTERNATIVAS, não um
    # par. A fronteira tem identidade de máquina (a App) e não precisa de um token
    # de conta dentro dela; o host é a máquina de uma pessoa, e é dela que sai o
    # token. Deixar as duas como default não fazia duas opções — fazia a máquina
    # ter duas identidades ao mesmo tempo, e o `gh` sem saber qual das duas
    # responder.
    if [ "$PROFILE" = "host" ]; then
        confirm "Autenticar o 'gh' com login de pessoa? (Enter = sim; esta máquina é a de uma pessoa)" 1 && CONFIRM_GH_LOGIN=1
    else
        confirm "Autenticar o 'gh' com login de pessoa? (Enter = não; a GitHub App cobre a API desta máquina)" 0 && CONFIRM_GH_LOGIN=1
    fi
fi

# O opencodex tem a própria pergunta, separada da do ai-clis, e a separação é o
# ponto: ele não é uma CLI local como as seis do ai-clis, é um proxy universal de
# provider que fica no caminho das requisições de modelo. Instalar em silêncio o
# que tem mais superfície, no módulo que pergunta sobre o que tem menos, era a
# incoerência. Também fica só no perfil host: lá serve o uso pessoal de Codex e
# Claude Code, e os agentes dentro da VM não o recebem — cada um usa a credencial
# do provider direto.
CONFIRM_OPENCODEX=""
if should_run "opencodex"; then
    confirm "Instalar o OpenCodex (ocx), um proxy de provider de terceiros que fica no caminho das requisições de modelo? (opt-in)" && CONFIRM_OPENCODEX=1
fi

CONFIRM_ZSHRC_OVERWRITE=0
if should_run "zshrc" \
    && { [ -e "$HOME/.zshrc" ] || [ -L "$HOME/.zshrc" ]; } \
    && [ "$(readlink "$HOME/.zshrc" 2>/dev/null)" != "$SCRIPT_DIR/zshrc" ]; then
    confirm "Já existe um ~/.zshrc. Substituir por um link para este repositório (o atual será salvo como backup)?" && CONFIRM_ZSHRC_OVERWRITE=1
fi

# O script tem vários "sudo" espalhados, e o "dnf upgrade" do módulo base
# pode demorar o suficiente pra expirar o timestamp de sudo cacheado — aí o
# próximo comando sudo trava esperando senha de novo no meio do script sem
# aviso. Isso já aconteceu numa execução real. Pedimos a senha uma vez aqui
# e mantemos o cache "quente" em background até o script terminar.
  #
  # ⚠️ `--yes` remove as perguntas DO SCRIPT, e não as do `sudo`. Medido: sem
  # terminal, `sudo -v` falha com "um terminal é necessário para ler a senha", e a
  # flag não muda isso. É uma limitação do `sudo`: ele lê a senha de um terminal,
  # e um pipe não é um terminal.
  #
  # A saída é dizer o que fazer, em vez de deixar o erro cru do `sudo` no meio do
  # log. O caminho simples é validar o sudo ANTES, num terminal — o timestamp é
  # exatamente o que este script quer manter quente. As alternativas são
  # `NOPASSWD` para o `dnf` da distro, ou um askpass.
  if ! sudo -v 2>/dev/null; then
      if [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
          echo -e "${YELLOW}Não consegui validar o sudo sem terminal.${NC}" >&2
          echo -e "${YELLOW}  O --defaults tira as perguntas do script, não as do sudo.${NC}" >&2
          echo -e "${YELLOW}  Antes de rodar, valide o sudo num terminal: sudo -v${NC}" >&2
          echo -e "${YELLOW}  (alternativas: NOPASSWD para o dnf, ou um askpass)${NC}" >&2
          exit 1
      fi
      sudo -v
  fi
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# A única pausa do script fica aqui, imediatamente depois de `sudo -v` e antes de
# qualquer módulo. O `tailscale up` precisa de pausa porque a URL de autenticação
# só existe quando ele roda, e ele precisa do pacote instalado — por isso a
# instalação vai junto, e é por isso que a chamada mora depois do `sudo -v` e não
# no meio do bloco de perguntas. Se o módulo `tailscale` for pulado, a pausa também
# é pulada. Em reexecução, com o nó já autenticado, `provision_tailscale` não
# pausa. Ver provision_tailscale.
if should_run "tailscale"; then
    provision_tailscale
fi

# ==============================================================================
# Base do sistema (dnf update + ferramentas essenciais de linha de comando)
# ==============================================================================
if should_run "base"; then
    echo -e "\n${BLUE}==> Base do sistema${NC}"
    sudo dnf upgrade --refresh -y
    # --skip-unavailable: um pacote ausente/indisponível (nome mudou, repo
    # específico da versão do Fedora, etc.) não deve travar a instalação dos
    # outros — instala o que der e avisa o que ficou de fora.
    # dnf5-plugins traz o "dnf config-manager" usado mais abaixo (tailscale,
    # brave) — este script assume DNF5 (padrão desde o Fedora 41); numa
    # instalação em versão anterior (DNF4), troque por dnf-plugins-core e
    # ajuste os "config-manager addrepo --from-repofile=" pra
    # "config-manager --add-repo".
    # `tar` não é usado por este script, mas é exigido por dois dos instaladores
    # que ele chama: o mise, logo abaixo em `ensure_host_node`, que extrai com
    # `tar --no-same-owner -xf`; e o Zed, no módulo `desktop-apps`, que extrai com
    # `tar -xzf`. O bun NÃO é um deles — ele descompacta com `unzip`, e `unzip`
    # já está na lista acima.
    #
    # O que justifica o pacote é essa dependência, e não uma afirmação sobre o que
    # uma imagem do Fedora traz ou não traz: o script chama instaladores que
    # precisam de `tar`, então quem chama é quem instala. Medido numa VM de
    # agente: o `base` morria dentro do instalador do mise, e `tar` não estava
    # instalado.
    # REGRA: TODO PACOTE DECLARA QUEM O CONSOME. Se ninguem declara, ele sai.
    #
    # A lista anterior carregava `tree`, `tmux`, `zellij`, `ripgrep`, `fd-find`,
    # `btop` e `wget`: medido, a UNICA ocorrencia de cada um desses nomes no script
    # inteiro era a propria lista de pacotes. Nenhum e invocado, nenhum instalador
    # deste repo o exige, e a VM de agentes nao tem uso pessoal — e uma maquina de
    # servico. Um pacote sem consumidor e entulho que se paga em download e imagem.
    #
    # A regra tem duas metades, e a segunda e a que impede a lista de inflar de
    # novo: quando o consumidor e um INSTALADOR EXTERNO, isso e dito na linha. E o
    # caso do `tar` e do `unzip`, que o script nao chama — quem chama e o mise e o
    # Bun, dentro dos instaladores que o proprio modulo `base` executa. A lista
    # cresceu a primeira vez porque o `base` morria dentro do instalador do mise sem
    # o `tar` (medido), e o `unzip` veio junto porque o Bun descompacta com ele em
    # vez de `tar -xzf`.
    #
    # Consumo por este script, medido por contagem de invocacao fora de comentario:
    #
    #   git 17x   gh 15x   jq 12x   openssl 13x   curl 26x   dnf 27x
    #   dnf5-plugins: o `config-manager` do tailscale, do brave e do vscode
    #   libatomic / libX11: o build do OpenDesign e o `pm` do Hermes
    #
    # E o que saiu, com a medicao: `tree`, `tmux`, `zellij`, `ripgrep`, `fd-find`,
    # `btop`, `wget`. Ferramentas de leitura convenience para pessoa, numa maquina
    # que nao tem pessoa.
    sudo dnf install -y --skip-unavailable \
        git gh jq curl openssl \
        dnf5-plugins \
        tar unzip \
        libatomic libX11
    # ⚠️ "não vem no Fedora" era verdade para uma imagem e falsa para outra:
    # medido numa Fedora 44 Workstation Edition recém-criada, as DUAS já vêm
    # instaladas. A afirmação honesta é que depende da imagem — e é por isso que
    # estão na lista do `base`, e não num passo opcional que se pode pular.
    #
    # `libatomic` e `libX11` não são enfeite. O `pm` do Hermes — o provisionador
    # que o instalador oficial usa para trazer o uv pinado e o runtime — baixa
    # binários para a máquina-alvo, e os dois que ele baixava medidos nesta VM
    # faltavam no host: sem eles o node pinado morre com "error while loading
    # shared libraries". Nenhum dos dois vem numa imagem mínima do Fedora, e
    # nenhum instalador menciona a dependência. Antes eles apareciam como DOIS
    # `return 1` no meio do caminho, exigindo um `sudo` manual em dois lugares —
    # e o `libX11` não era verificado em lugar nenhum.
    echo -e "${GREEN}✓ Pacotes base instalados.${NC}"

    if ! command -v bun &> /dev/null; then
        curl -fsSL https://bun.sh/install | bash
        echo -e "${GREEN}✓ Bun instalado.${NC}"
    else
        echo -e "${YELLOW}Bun já instalado.${NC}"
    fi

    # Node/npm do host vêm do mise, não do dnf. O Bun já traz as CLIs de agente,
    # mas o fallback "npm install -g" do ai-clis e as CLIs com
    # "#!/usr/bin/env node" precisam de um Node no PATH, e o mise é o que
    # garante esse Node com versão pinada — independente da versão que o
    # Fedora decidir empacotar. Também é o que fornece o Dev Container CLI.
    ensure_host_node
    # Conveniências de ergonomia (PATH no shell e atalho do CLI): se falharem,
    # o host continua utilizável, então não abortamos o setup por causa delas.
    activate_mise_in_shell || true
    link_devcontainer_cli || true
fi

# ==============================================================================
# Hostname
# ==============================================================================
if should_run "hostname"; then
    echo -e "\n${BLUE}==> Hostname${NC}"
    if [ -z "$NEW_HOSTNAME" ]; then
        echo -e "${YELLOW}Hostname mantido como '$CURRENT_HOSTNAME'.${NC}"
    elif [ "$CONFIRM_HOSTNAME" != "1" ]; then
        echo -e "${YELLOW}Alteração de hostname ignorada.${NC}"
    elif printf '%s' "$NEW_HOSTNAME" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' \
         && [ "${#NEW_HOSTNAME}" -le 63 ]; then
        # Valida ANTES do `set-hostname`, porque depois já é tarde: o nome entra no
        # registro do sistema, e um nome ruim deixa a máquina mais difícil de
        # alcançar — é por ele que a tailnet e o SSH se apresentam. As regras são as
        # do RFC 1123 que o systemd aplica: até 63 caracteres (64 com o ponto
        # final), sem ponto, sem espaço. O `hostnamectl` aceita maiúscula, e ver
        # `suggest_hostname` para por que mesmo assim não geramos maiúscula.
        if sudo hostnamectl set-hostname "$NEW_HOSTNAME"; then
            echo -e "${GREEN}✓ Hostname definido como: $NEW_HOSTNAME${NC}"
        else
            echo -e "${YELLOW}O hostnamectl recusou '$NEW_HOSTNAME'.${NC}" >&2
        fi
    else
        echo -e "${YELLOW}Hostname inválido, não aplicado: '$NEW_HOSTNAME'.${NC}" >&2
        echo -e "${YELLOW}  Só minúsculas, dígitos e hífen, sem ponto, até 63 caracteres.${NC}" >&2
    fi

    # ── A tailnet: relatório, e nunca ação ────────────────────────────────
    #
    # O hostname do SO alimenta o nome do nó na tailnet, mas SÓ enquanto o nó não
    # está conectado. Medido nesta VM: o hostname do SO e o `HostName` do nó eram
    # ambos `fedora-vm-mini` — e uma vez conectado, trocar o hostname do SO NÃO
    # renomeia o nó.
    #
    # Este módulo **não renomeia o nó**, e a decisão é do dono do repo, com um
    # motivo que a medição impõe: renomeado o nó, as três publicações do
    # `tailscale serve` ficam chaveadas no nome ANTIGO, o `tailscaled` pede
    # certificado para um nome que o nó não responde, e o TLS morre no handshake
    # com `tlsv1 alert internal error (592)` — sem mensagem que aponte a causa. O
    # próprio README traz o procedimento completo de republicação. Um script que
    # renomeasse o nó quebraria os três serviços que ele mesmo publica, e o
    # check de "já publicado" não perceberia: ele compara o BACKEND
    # (`100.94.102.114:9119`), não o nome, e portanto passaria em cima da
    # publicação quebrada.
    #
    # A filosofia fecha a conta: este script é de provisionar uma vez e virar
    # desnecessário. Numa máquina nova o Tailscale ainda não existe quando este módulo
    # roda — ele é a posição 2, e o `tailscale` é a 7 —, então não há o que renomear:
    # o `tailscale up` posterior já pega o hostname novo. Numa máquina já
    # provisionada, o nome do nó é um estado que a pessoa administra, e o script não
    # mexe nele.
    #
    # O que sobra é o RELATO, e ele é estado, não opinião: os dois nomes, lado a
    # lado, e o preço de reconciliá-los, com o README como fonte do procedimento.
    if command -v tailscale &> /dev/null && tailscale status &> /dev/null 2>&1; then
        _self="$(tailscale status --json 2>/dev/null | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('Self', {}).get('HostName', ''))
except Exception: pass" 2>/dev/null)"
        if [ -n "$NEW_HOSTNAME" ] && [ -n "$_self" ] && [ "${_self%,}" != "${NEW_HOSTNAME%,}" ]; then
            echo -e "${YELLOW}  O nó na tailnet se chama '${_self%,}' e o SO se chama '${NEW_HOSTNAME}'.${NC}"
            echo -e "${YELLOW}  São dois nomes diferentes de propósito: o Tailscale copiou o do SO quando${NC}"
            echo -e "${YELLOW}  conectou, e este script não renomeia nós. Medido: a divergência sozinha não${NC}"
            echo -e "${YELLOW}  quebra nada — as três portas continuam respondendo.${NC}"
            echo -e "${YELLOW}  Se um dia os dois precisarem ser o mesmo, o procedimento e o preco${NC}"
            echo -e "${YELLOW}  estão no README, na secao da armadilha do nome defasado.${NC}"
        fi
        unset _self

        if [ -n "$NEW_HOSTNAME" ]; then
            _colisao="$(tailscale status --json 2>/dev/null | ALVO="$NEW_HOSTNAME" python3 -c "
import json, os, sys
alvo = os.environ.get('ALVO', '').rstrip('.').lower()
try: peers = json.load(sys.stdin).get('Peer') or {}
except Exception: peers = {}
print(','.join(p.get('HostName', '') for p in peers.values()
                if p.get('HostName', '').rstrip('.').lower() == alvo))" 2>/dev/null)"
            if [ -n "$_colisao" ]; then
                echo -e "${YELLOW}  ⚠️ Outro nó da tailnet já se chama '${_colisao%,}' — este nome colide.${NC}" >&2
                echo -e "${YELLOW}     A causa provável é uma imagem CLONADA: o machine-id vai junto, e é${NC}" >&2
                echo -e "${YELLOW}     dele que vem o sufixo. Compare com: cat /etc/machine-id${NC}" >&2
            fi
            unset _colisao
        fi
    else
        echo -e "${YELLOW}  Tailscale ainda não conectou; ele vai pegar o hostname novo ao subir.${NC}"
    fi
    mkdir -p "$HOME/Developer"
    mkdir -p "$HOME/Developer"
fi

# ==============================================================================
# Chave SSH Ed25519 + Git/GitHub CLI
# ==============================================================================
if should_run "ssh"; then
    echo -e "\n${BLUE}==> SSH (Ed25519)${NC}"

    # Este módulo é o do SERVIDOR, e não só o da chave de cliente. Medido numa VM
    # Fedora recém-criada: o `sshd` não está no ar, a porta 22 dá "connection
    # refused", e a única entrada é o console. Como o módulo `ssh` é o primeiro
    # do perfil `vm` depois do `base`, é aqui que o serviço precisa subir — e
    # subir cedo é o que permite ao `sshd-hardening` desligar a senha sem risco.
    #
    # O `sshd-hardening` também faz isto, e a duplicação é deliberada: ele roda
    # depois e cobre o caso de alguém rodar `--only=sshd-hardening`. A segunda
    # chamada cai no `is-active` e não faz nada.
    if ! systemctl is-active sshd &> /dev/null; then
        sudo systemctl enable --now sshd \
            && echo -e "${GREEN}✓ sshd no ar e habilitado no boot.${NC}" \
            || echo -e "${YELLOW}Não consegui subir o sshd.${NC}" >&2
    else
        echo -e "${YELLOW}sshd já está rodando.${NC}"
    fi

    generate_ssh_key "$GIT_EMAIL"

    SSH_CONFIG="$HOME/.ssh/config"
    if [ ! -f "$SSH_CONFIG" ] || ! grep -q "Host github.com" "$SSH_CONFIG"; then
        cat <<EOF >> "$SSH_CONFIG"
Host github.com
  AddKeysToAgent yes
  IdentityFile ~/.ssh/id_ed25519
EOF
        chmod 600 "$SSH_CONFIG"
        echo -e "${GREEN}✓ ~/.ssh/config configurado para github.com.${NC}"
    else
        echo -e "${YELLOW}~/.ssh/config já possui uma entrada para github.com.${NC}"
    fi
fi

if should_run "device-keys"; then
    echo -e "\n${BLUE}==> Chaves de dispositivos (GitHub)${NC}"
    if [ "${CONFIRM_DEVICE_KEYS:-}" = "1" ]; then
        sync_device_keys_from_github \
            || echo -e "${YELLOW}Chaves de dispositivos pendentes; o authorized_keys ficou como estava.${NC}" >&2
    else
        echo -e "${YELLOW}Chaves de dispositivos: não autorizado.${NC}"
    fi
fi

if should_run "git"; then
    echo -e "\n${BLUE}==> Git e GitHub CLI${NC}"
    configure_git_and_gh "$GIT_NAME" "$GIT_EMAIL" "$(hostname)"
fi

# ==============================================================================
# Podman rootless (motor de isolamento dos workspaces por projeto)
# ==============================================================================
if should_run "podman"; then
    echo -e "\n${BLUE}==> Podman (rootless)${NC}"
    # `podman-docker` NÃO é instalado, de propósito. Ele cria um comando `docker`
    # que é atalho para o podman, e é exatamente isso que faz uma ferramenta que
    # espera Docker escolher o engine sem que ninguém perceba. O fluxo do repo
    # passa o engine explícito, então o shim só adicionaria uma forma de o
    # provider escolher errado — e a regra de não ter volume/credencial
    # compartilhada pressupõe que o engine é o que o padrão dice que é.
    sudo dnf install -y --skip-unavailable podman slirp4netns fuse-overlayfs

    # O `podman-compose` e o PROVIDER de `podman compose`, e sem ele o comando
    # falha: medido nesta VM antes desta linha, `podman compose version` devolvia
    # "looking up compose provider failed", e o script so resolvia isso mandando o
    # operador instalar o pacote a mao. Isso e o que torna o modo container default
    # seguro: o pre-requisito passa a ser do script, e nao um passo manual que
    # alguém esquece numa VM nova e só descobre quando o `compose up` falha.
    if ! command -v podman-compose &> /dev/null; then
        sudo dnf install -y podman-compose || {
            echo -e "${YELLOW}  podman-compose não instalado; o modo container do OpenDesign vai falhar.${NC}" >&2
        }
    fi
    if rpm -q podman-docker >/dev/null 2>&1; then
        echo -e "${YELLOW}  podman-docker está instalado e cria um atalho 'docker'.${NC}"
        echo -e "${YELLOW}  Não é removido aqui (não é decisão deste módulo); o padrão é não tê-lo.${NC}"
    fi

    # `podman.socket` desligado: nada expõe a API do engine por TCP ou socket.
    # É o que permite rodar o Dev Container CLI com --docker-path podman sem
    # reabrir uma superfície de rede. Sem isto, um `podman system service` ou um
    # cliente que procure o socket acha o caminho aberto.
    sudo systemctl disable --now podman.socket 2>/dev/null || true
    if systemctl is-enabled --quiet podman.socket 2>/dev/null; then
        echo -e "${YELLOW}Aviso: podman.socket continua habilitado; a exposição de API do engine segue aberta.${NC}"
    else
        echo -e "${GREEN}✓ podman.socket desabilitado.${NC}"
    fi

    # Garante subuid/subgid pro seu usuário (necessário pra containers rootless
    # mapearem UIDs dentro do container sem privilégio real no host).
    if ! grep -q "^$USER:" /etc/subuid 2>/dev/null; then
        sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 "$USER"
        echo -e "${GREEN}✓ subuid/subgid configurados para $USER.${NC}"
    else
        echo -e "${YELLOW}subuid/subgid já configurados para $USER.${NC}"
    fi

    # Mantém containers rootless vivos mesmo sem sessão de login ativa
    # (essencial pra sobreviver a desconexões de SSH/Tailscale).
    sudo loginctl enable-linger "$USER"
    echo -e "${GREEN}✓ Linger habilitado para $USER (containers sobrevivem ao logout).${NC}"

    # userns=keep-id: sem isso, um processo rodando como "root" dentro de um
    # container rootless vira um UID alto sem privilégio no host (via
    # subuid/subgid acima) — e não consegue escrever em bind-mounts que
    # pertencem ao seu usuário real (ex.: arquivos de projeto nos
    # devcontainers do devpod). keep-id mapeia seu UID/GID reais pra dentro
    # do container também.
    CONTAINERS_CONF="$HOME/.config/containers/containers.conf"
    mkdir -p "$(dirname "$CONTAINERS_CONF")"
    if [ ! -f "$CONTAINERS_CONF" ]; then
        printf '[containers]\nuserns = "keep-id"\n' > "$CONTAINERS_CONF"
        echo -e "${GREEN}✓ userns=keep-id configurado em $CONTAINERS_CONF.${NC}"
    elif ! grep -q '^\s*userns\s*=' "$CONTAINERS_CONF"; then
        if grep -q '^\[containers\]' "$CONTAINERS_CONF"; then
            sed -i '/^\[containers\]/a userns = "keep-id"' "$CONTAINERS_CONF"
        else
            printf '\n[containers]\nuserns = "keep-id"\n' >> "$CONTAINERS_CONF"
        fi
        echo -e "${GREEN}✓ userns=keep-id configurado em $CONTAINERS_CONF.${NC}"
    else
        echo -e "${YELLOW}userns já configurado em $CONTAINERS_CONF, mantendo como está.${NC}"
    fi

    podman info &> /dev/null && echo -e "${GREEN}✓ Podman funcional.${NC}" || \
        echo -e "${YELLOW}Aviso: 'podman info' falhou — pode ser necessário reiniciar a sessão.${NC}"
fi

# ==============================================================================
# GitHub App — identidade da máquina para a API do GitHub
# ==============================================================================
# Instala o helper que troca a private key por um token de instalação, e valida
# que o par funciona chamando a API de verdade. A validação é a pós-condição:
# helper instalado não prova nada; o que prova é a API respondendo.
#
# Nada de token em disco aqui. O token vive uma hora, e quem o usa é o wrapper
# `gh-app`, que o obtém, roda um comando e o descarta. Este módulo usa o `--check`,
# que não escreve nada e deixa o token morrer com o processo.
if should_run "gh-app"; then
    echo -e "\n${BLUE}==> GitHub App${NC}"
    if [ "${CONFIRM_GH_APP:-0}" != "1" ]; then
        echo -e "${YELLOW}Inativo: App ID ou private key não foram informados.${NC}"
        echo -e "${YELLOW}  O 'gh' vai pedir login no navegador quando for usado.${NC}"
    else
        # `install` falha se o diretório não existir, e o `set -e` transforma isso
        # em fim de script. O `base` costuma ter criado `~/.local/bin`, mas pode ter
        # sido pulado com `--skip`.
        mkdir -p "$HOME/.local/bin"
        install -m 0755 "$SCRIPT_DIR/bin/gh-app-token.sh" "$HOME/.local/bin/gh-app-token"
        echo -e "${GREEN}✓ Helper em ~/.local/bin/gh-app-token.${NC}"

        # O caminho ABSOLUTO do `gh` de verdade, resolvido ANTES de escrever
        # qualquer wrapper. A razão é a recorrência: o shim que este módulo
        # instala chama o `gh` real, e o wrapper `gh-app` também — e se os dois
        # usarem `command gh`, cada um vai encontrar o OUTRO e chamar de volta em
        # recursão. Assar o caminho absoluto nos dois é o que fecha isso, e
        # resolve de quebra uma fragilidade que já existia: o wrapper dependia de o
        # `~/.local/bin` estar no PATH, e o comentário dele registra que isso já
        # deu "command not found" numa máquina real.
        _real_gh=""
        if command -v gh &> /dev/null; then
            _real_gh="$(command -v gh)"
        elif [ -x /usr/bin/gh ]; then
            _real_gh="/usr/bin/gh"
        fi
        if [ -z "$_real_gh" ] || [ "$_real_gh" = "$HOME/.local/bin/gh" ]; then
            # O segundo caso é o shim que uma execução anterior desta mesma máquina
            # já deixou no PATH. Sem esta checagem, `command -v gh` devolveria o
            # shim e o wrapper passaria a invocar ele mesmo para sempre.
            _real_gh="/usr/bin/gh"
        fi
        if [ ! -x "$_real_gh" ]; then
            echo -e "${YELLOW}  Não achei o binário do gh em lugar nenhum; a App fica instalada${NC}" >&2
            echo -e "${YELLOW}  mas sem o wrapper. Instale o 'gh' e rode o módulo de novo.${NC}" >&2
        fi

        # O wrapper obtém um token por comando e o descarta. Não vai para o shell rc
        # de propósito: mintar a cada shell aberto seria uma chamada de API por
        # terminal e manteria a credencial viva na sessão. O `--meta` deixa o
        # wrapper reaproveitar o token enquanto ele vale, o que evita a troca a cada
        # comando sem transformar a credencial em estado permanente.
        cat > "$HOME/.local/bin/gh-app" <<'WRAPPER'
#!/usr/bin/env bash
# Roda um comando do `gh` com o token de instalação da GitHub App.
set -euo pipefail
# Caminho absoluto: sem ele, se `~/.local/bin` não estiver no PATH a chamada dá
# "command not found" e a mensagem do wrapper culparia a App à toa.
HELPER="$HOME/.local/bin/gh-app-token"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/gh-app"
# `umask` antes do `mkdir`, para o diretório do cache não ficar 755.
( umask 077; mkdir -p "$CACHE_DIR" )
TOKEN="$CACHE_DIR/token"
META="$CACHE_DIR/token.meta"

if [ ! -s "$TOKEN" ] || [ ! -s "$META" ]; then
    obtem=1
elif [ "$(jq -r '.expires_at_epoch // 0' "$META" 2>/dev/null || echo 0)" -le "$(( $(date +%s) + 60 ))" ]; then
    obtem=1
else
    obtem=0
fi

if [ "$obtem" = "1" ]; then
    if ! "$HELPER" --out "$TOKEN" --meta "$META" >/dev/null; then
        echo "gh-app: nao obtive token. A App esta instalada e o par App ID + chave e valido?" >&2
        exit 69
    fi
fi

GH_TOKEN="$(cat "$TOKEN")" exec "__REAL_GH__" "$@"
WRAPPER
        # O placeholder só é trocado aqui, na hora de gravar: um `sed` sobre o
        # arquivo inteiro poderia atingir uma linha de comentário que fala do
        # caminho, e o resultado seria silenciosamente errado.
        sed -i "s|__REAL_GH__|$_real_gh|g" "$HOME/.local/bin/gh-app"
        chmod 0755 "$HOME/.local/bin/gh-app"

        echo -e "${BLUE}Validando a App contra a API (não é checagem de arquivo)${NC}"
        if GH_APP_KEY="$GH_APP_KEY_FILE" GH_APP_ID="$(cat "$GH_APP_ID_FILE")" \
           "$HOME/.local/bin/gh-app-token" --check; then
            echo -e "${GREEN}✓ App validada contra a API.${NC}"
            echo -e "${YELLOW}  Neste perfil (vm) o 'gh' puro passa a usar a App, sem wrapper.${NC}"
        # ── O shim de `gh`, e SO no perfil `vm` ────────────────────────────
        #
        # O sintoma que ele resolve é medido e é comum: um agente roda `gh pr
        # create`, pega o `gh` de verdade, que não tem token, e falha — sem nenhuma
        # pista de que existe uma App instalada na máquina. A identidade estava num
        # comando de nome diferente (`gh-app`), e caminho que precisa ser lembrado
        # não é caminho.
        #
        # A Documentação do GitHub CLI responde se existe jeito melhor, e a
        # resposta é que `gh auth login` NÃO tem login como App: os métodos são o
        # fluxo web (OAuth de pessoa) e `--with-token` (PAT). O jeito documentado
        # para um token que não vem do login é a variável `GH_TOKEN`, e a
        # documentação é explícita que ela tem **precedência sobre as credenciais
        # guardadas**. Ou seja: injetar `GH_TOKEN` não é contorno, é o mecanismo.
        #
        # POR QUE SÓ NO `vm`, e por que isso é uma decisão e não uma restrição:
        #
        #   * `vm` — a identidade é da MÁQUINA. Um token por comando, com o
        #     App como fonte, é o que a fronteira quer, e o token expira sozinho.
        #   * `host` — a identidade é da PESSOA, e o login de pessoa já funciona.
        #     Um shim aqui sobrescreveria esse login, porque `GH_TOKEN` tem
        #     precedência. Trocaria o que a pessoa espera pelo que a máquina
        #     presume.
        #
        # E é por isso que o shim cai no `case` do perfil, e não num `if [ -f ]`
        # de "já instalei": rodar `--profile=vm` num host deixaria o shim para
        # sempre, e o perfil é a única coisa que sabe qual máquina é esta.
        if [ "$PROFILE" = "vm" ] && [ -n "$_real_gh" ]; then
            cat > "$HOME/.local/bin/gh" <<SHIM
#!/usr/bin/env bash
# \`gh\` com a identidade da GitHub App desta VM.
#
# Este shim existe porque a identidade da máquina vivia num comando de nome
# diferente, e um \`gh pr create\` sem token falhava sem explicar por quê. A
# Documentação do GitHub CLI diz que o caminho é \`GH_TOKEN\`, com precedência
# sobre credenciais guardadas — então o \`gh\` puro passa a funcionar sem que
# ninguém precise saber que a App existe.
#
# Sem App configurada, ou com o token expirado, ele delega ao \`gh\` de verdade
# sem token nenhum: é o comportamento de uma máquina sem identidade de máquina.
set -uo pipefail

WRAPPER="$HOME/.local/bin/gh-app"
REAL_GH="__REAL_GH__"

if [ -x "$WRAPPER" ]; then
  exec "$WRAPPER" "\$@"
fi

exec "$REAL_GH" "\$@"
SHIM
            sed -i "s|__REAL_GH__|$_real_gh|g" "$HOME/.local/bin/gh"
            chmod 0755 "$HOME/.local/bin/gh"
            echo -e "${GREEN}✓ Shim de 'gh' em ~/.local/bin/gh — só neste perfil (vm).${NC}"
            echo -e "${GREEN}  'gh pr create' passa a usar a App, sem wrapper e sem token na mão.${NC}"
        elif [ "$PROFILE" = "host" ]; then
            echo -e "${GREEN}✓ Sem shim de 'gh' neste perfil: o login de pessoa é a identidade${NC}"
            echo -e "${GREEN}  do host, e um shim sobrescreveria ele (GH_TOKEN tem precedência).${NC}"
        fi

        else
            echo -e "${YELLOW}A App não respondeu como esperado. Verifique se o par App ID + chave${NC}" >&2
            echo -e "${YELLOW}está certo e se a App está instalada em ao menos um repositório.${NC}" >&2
        fi
    fi
fi

# ==============================================================================
# Tailscale (rede segura entre o Mac e este servidor, sem exposição pública)
# ==============================================================================
# Instala, habilita e autentica o Tailscale. Vive numa função porque é chamada de
# dois lugares: do bloco de perguntas, para que a pausa do `tailscale up` aconteça
# uma vez e cedo; e do módulo, que reexecuta por idempotência. A segunda chamada
# encontra o nó já autenticado e não pausa.

if should_run "tailscale"; then
    echo -e "\n${BLUE}==> Tailscale${NC}"
    provision_tailscale
fi

# ==============================================================================
# Hardening do sshd (chave apenas, sem senha)
# ==============================================================================
if should_run "sshd-hardening"; then
    echo -e "\n${BLUE}==> Hardening do sshd${NC}"

    # ⚠️ ESTE ERA O PRIMEIRO BLOQUEIO NUMA VM REALMENTE LIMPA, e ele é medido.
    #
    # Numa Fedora recém-criada o `sshd` NÃO está no ar: a porta 22 responde
    # "connection refused" — não filtrada — e o `tailscale ping` funciona, ou
    # seja, os pacotes chegam e a máquina recusa porque não há ouvinte. A única
    # forma de entrar era o console, para um `systemctl enable --now sshd` à mão.
    #
    # A causa é que este script nunca sobe o serviço. O módulo `ssh` gera a chave e
    # mexe no `~/.ssh/config`; o `sshd-hardening` escreve a config do servidor e
    # fazia só um `reload` — que falha num serviço parado. O resultado era sshd
    # configurado e nunca iniciado, sem caminho de entrada, e sem nenhuma mensagem
    # reclamando.
    #
    # O `enable --now` vai ANTES do hardening, por dois motivos. O primeiro é
    # óbvio: sem serviço no ar não há SSH. O segundo é o que o lockout evita: a
    # linha seguinte desabilita `PasswordAuthentication`, e se o `enable` viesse
    # depois, a janela entre os dois seria um serviço no ar com senha ligada —
    # breve, mas existente. Subir primeiro garante que, no momento em que a senha
    # é desligada, a chave já é o único caminho.
    #
    # `--now` e não `enable` sozinho: `enable` só marca para o próximo boot, e numa
    # VM que acabou de provisionar isso não acontece até o próximo reinício.
    if ! systemctl is-active sshd &> /dev/null; then
        if sudo systemctl enable --now sshd; then
            echo -e "${GREEN}✓ sshd no ar e habilitado no boot (não estava rodando).${NC}"
        else
            echo -e "${YELLOW}Não consegui subir o sshd; sem ele não há acesso por SSH.${NC}" >&2
            echo -e "${YELLOW}  Tente no console: sudo systemctl enable --now sshd${NC}" >&2
        fi
    else
        echo -e "${YELLOW}sshd já está rodando.${NC}"
    fi

    SSHD_CONFIG="/etc/ssh/sshd_config.d/99-dotfiles-hardening.conf"
    # A condição é a PROPRIEDADE, não a existência do arquivo. Ver `_sshd_hardened`:
    # o diretório de drop-in do Fedora é 700 root:root, então `[ -f ]` como usuário
    # normal diz "não existe" mesmo com o arquivo lá dentro, e o `else` deste bloco
    # era código inalcançável — o módulo reescrevia o drop-in e recarregava o sshd
    # em toda execução, sem reclamar.
    if ! _sshd_hardened; then
          # Desabilitar PasswordAuthentication sem ter nenhuma chave em
          # authorized_keys já cadastrada te tranca pra fora via SSH de vez.
          #
          # ESTE COMENTÁRIO ESTAVA ERRADO e dizia o contrário. Ele afirmava que "o
          # script não popula esse arquivo", e foi escrito antes de o módulo
          # `device-keys` existir. Hoje o script popula, e por padrão: o módulo baixa
          # o arquivo público `https://github.com/<conta>.keys` e reescreve o bloco
          # gerenciado, preservando tudo o que está fora dele. Ver
          # `sync_device_keys_from_github`.
          #
          # O guard abaixo é o que protege, e continua sendo a coisa que importa: se
          # o `device-keys` falhou — sem rede, feed vazio, conta sem chaves —, o
          # arquivo fica como estava e o hardening pula com aviso. A pergunta é a
          # segunda camada, não a que evita o lockout.
        if [ ! -s "$HOME/.ssh/authorized_keys" ]; then
            echo -e "${YELLOW}~/.ssh/authorized_keys vazio ou inexistente — desabilitar login por senha deixaria a máquina sem entrada. Pulando.${NC}" >&2
        elif [ "$CONFIRM_SSHD_HARDENING" = "1" ]; then
            # Aspas no here-doc: PasswordAuthentication e PermitRootLogin não têm `$`
            # nem crase, e um here-doc SEM aspas expande os dois. Foi exatamente o
            # defeito da crase que a §10 da auditoria registra, e o certo é não
            # depender de o conteúdo não ter nada especial hoje.
            sudo tee "$SSHD_CONFIG" > /dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
            if sudo systemctl reload sshd; then
                # Pós-condição: o reload pode ter sido aceito e a config não ter
                # entrado em vigor. `systemctl reload` devolve 0 se o serviço
                # recarregou, e o sshd recusa uma config inválida continuando com a
                # anterior — sem este teste, o "✓" abaixo seria uma afirmação sem
                # base, que é a forma mais comum de um script mentir.
                if _sshd_hardened; then
                    echo -e "${GREEN}✓ sshd endurecido (login por senha desabilitado).${NC}"
                else
                    echo -e "${YELLOW}O reload foi aceito, mas a config efetiva continua com senha habilitada.${NC}" >&2
                    echo -e "${YELLOW}  Confira com: sudo sshd -T | grep -i passwordauthentication${NC}" >&2
                    echo -e "${YELLOW}  E com: sudo sshd -t   (aponta o erro de sintaxe, se houver)${NC}" >&2
                fi
            else
                echo -e "${YELLOW}O reload do sshd falhou; a config anterior continua valendo.${NC}" >&2
                echo -e "${YELLOW}  A sintaxe é checada com: sudo sshd -t${NC}" >&2
            fi
        else
            echo -e "${YELLOW}Hardening do sshd ignorado.${NC}"
        fi
    else
        echo -e "${YELLOW}✓ sshd já endurecido (PasswordAuthentication no, PermitRootLogin no) — nada a fazer.${NC}"
    fi

    # A senha do root é uma credencial sem propósito numa máquina em que se entra
    # por chave: ela não é caminho para nada que o sudo não cubra. Travá-la remove
    # a credencial; deixá-la mais forte apenas a conserva, e é o que uma persistência
    # pós-compromisso tenta primeiro.
    #
    # A guarda de "existe usuário que entra" foi feita no bloco de perguntas. Aqui
    # só resta não refazer trabalho: `passwd -S` devolve L para senha travada, e
    # essa é a única leitura privilegiada, agora que o `sudo -v` já passou.
    if [ "${CONFIRM_LOCK_ROOT:-}" = "1" ]; then
        _rs=$(sudo passwd -S root 2>/dev/null | awk '{print $2}')
        if [ "$_rs" = "L" ]; then
            echo -e "${YELLOW}Senha do root já está travada, pulando.${NC}"
        elif [ -z "$_rs" ]; then
            # Estado desconhecido. Assumir que está travada pouparia um trabalho, e
            # assumir que não está travaria uma máquina sem querer. Nenhuma das duas
            # é segura, então não se mexe.
            echo -e "${YELLOW}Não consegui ler o estado da senha do root; nada foi alterado.${NC}" >&2
        else
            if sudo passwd -l root > /dev/null 2>&1; then
                echo -e "${GREEN}✓ Senha do root travada.${NC}"
            else
                echo -e "${YELLOW}Não consegui travar a senha do root.${NC}" >&2
            fi
        fi
        unset _rs
    fi
fi

# ==============================================================================
# firewalld: instalar, subir, e VERIFICAR que sobrou caminho de entrada.
#
# Este módulo roda nos DOIS perfis, e passou a rodar na VM em 2026-09-30. Antes ele
# era só do host, e era aí que marcava `tailscale0` como `trusted`.
# ==============================================================================
if should_run "firewalld"; then
    echo -e "\n${BLUE}==> firewalld${NC}"
    sudo dnf install -y firewalld
    sudo systemctl enable --now firewalld

    # ── O que este módulo NÃO faz mais, e por quê ────────────────────────────
    #
    # Ele marcava `tailscale0` na zona `trusted`, que libera TODO tráfego da
    # interface. Foi removido por decisão do dono do repo, e a direção é a que o
    # `ARQUITETURA.md` propunha desde o começo: a zona `trusted` é "o elo errado da
    # cadeia" porque aceita tráfego que nada pediu.
    #
    # A premissa que sustentava a marcação era que a tailnet já autentica quem
    # entra, e por isso a zona não acrescentaria risco. A medição diz que a
    # markação também não acrescentava NADA: a publicação nas portas 8443-8445
    # funciona porque a zona default do Fedora abre `1025-65535/tcp`, e não porque a
    # interface estivesse em `trusted`. Tirar a marcação não tirou nada — e é
    # por isso que a remoção é segura em vez de ser um risco novo.
    #
    # Quem QUER a marcação, agora, é uma decisão de fora do provisionamento, e o
    # comando está no ARQUITETURA.md e no aviso abaixo. Uma marcação que o script
    # aplica sozinho é uma marcação que ninguém revisou.
    echo -e "${YELLOW}  A interface tailscale0 fica na zona padrão do firewalld, sem marcação.${NC}"
    echo -e "${YELLOW}  Para marcá-la como confiável, à mão: sudo firewall-cmd --zone=trusted --change-interface=tailscale0 --permanent && sudo firewall-cmd --reload${NC}"

    # ── Pós-condição: sobrou caminho de entrada? ──────────────────────────────
    #
    # A propriedade, não o estado do serviço. `active` no firewalld não diz nada
    # sobre conseguir entrar na máquina — e o motivo de a pós-condição existir é
    # medido, não hipotético: o primeiro bloqueio numa VM limpa foi o `sshd` nunca
    # subir, que é a mesma classe de defeito, e o jeito de descobrir foi ficar sem
    # entrada. Um firewall recém-abilitado é exatamente o componente que pode
    # fechar o caminho que a pessoa usava para entrar.
    #
    # A pergunta é "a zona em que a tailscale0 caiu permite ssh?", e não "o
    # firewalld está ligado?", porque a segunda é respondida por `systemctl` e a
    # primeira é a que importa. É também a verificação que o ARQUITETURA.md nomeia
    # para o guest: "`tailscale0` caiu numa zona que permite `ssh` — que é o que
    # garante que o Mac consegue entrar".
    #
    # Sem `tailscale0` — Tailscale ainda não autenticou, ou não está instalado — não
    # há o que verificar, e isso NÃO é falha: a interface ainda não existe.
    if ! command -v firewall-cmd &> /dev/null; then
        echo -e "${YELLOW}  firewall-cmd ausente; não consegui verificar o caminho de entrada.${NC}" >&2
    elif ! ip link show tailscale0 &> /dev/null; then
        echo -e "${YELLOW}  tailscale0 ainda não existe (Tailscale não conectou?); a zona será verificada no próximo run.${NC}"
    else
        _fw_zone="$(sudo firewall-cmd --get-zone-of-interface=tailscale0 2>/dev/null || true)"
        # `--get-zone-of-interface` devolve VAZIO — e não um nome de zona — quando a
        # interface não tem amarração própria e herda a default. Medido nesta VM.
        # Ler isso como zona nenhuma daria um aviso falso em toda máquina que não
        # tenha a marcação, que é o novo estado normal.
        [ -z "$_fw_zone" ] && _fw_zone="$(sudo firewall-cmd --get-default-zone 2>/dev/null || true)"
        _fw_zone="${_fw_zone:-desconhecida}"

        if [ "$_fw_zone" = "desconhecida" ]; then
            echo -e "${YELLOW}  Não consegui ler a zona da tailscale0; verifique o acesso a SSH à mão.${NC}" >&2
        else
            unset _rs
            _rs="$(sudo firewall-cmd --zone="$_fw_zone" --service=ssh --query-port=22 2>/dev/null || true)"
            if [ "$_rs" = "yes" ]; then
                echo -e "${GREEN}  ✓ Zona da tailscale0: '$_fw_zone', e ela permite ssh.${NC}"
            else
                # A lista de serviços, não só a consulta por porta: a zona pode
                # liberar o 22 pelo serviço `ssh` OU pela porta, e as duas coisas
                # servem. Uma delas estar presente já é caminho de entrada.
                unset _rs
                _rs="$(sudo firewall-cmd --zone="$_fw_zone" --list-services 2>/dev/null | tr ' ' '\n' | grep -cx ssh || true)"
                unset _sv
                _sv="$(sudo firewall-cmd --zone="$_fw_zone" --list-ports 2>/dev/null | tr ' ' '\n' | grep -cE '^(22|22-)|(^|-)22/' || true)"
                if [ "$_rs" != "0" ] || [ "$_sv" != "0" ]; then
                    echo -e "${GREEN}  ✓ Zona da tailscale0: '$_fw_zone', e ela permite ssh.${NC}"
                else
                    echo -e "${YELLOW}  ⚠️ A zona '$_fw_zone' da tailscale0 NÃO parece permitir ssh.${NC}" >&2
                    echo -e "${YELLOW}    Se você entrou por senha, ela acabou de ser desligada. Para desfazer:${NC}" >&2
                    echo -e "${YELLOW}      sudo firewall-cmd --zone=$_fw_zone --add-service=ssh --permanent && sudo firewall-cmd --reload${NC}" >&2
                fi
            fi
        fi
        unset _fw_zone _rs _sv
    fi
    echo -e "${YELLOW}  Revise 'sudo firewall-cmd --list-all' e feche manualmente qualquer porta que não devia estar aberta.${NC}"
fi

# ==============================================================================
# Hospedeiro de VMs: libvirt + Cockpit
# ==============================================================================
#
# O host hospeda a VM de agentes, e o Cockpit é onde ela é criada e gerenciada.
# Este módulo é o **corte mínimo**: pacotes, grupo e socket. Ele não declara a
# rede do libvirt.
#
# A rede fica de fora de propósito. Duas razões, e a segunda é a que pesa:
#
# 1. O default do libvirt resolve até existir medição, e medir exige uma VM real
#    que ainda não existe.
# 2. Declarar a rede exige saber **quais serviços o host vai expor**, e essa
#    lista não está escrita. A regra do host é uma porta por serviço, então
#    qualquer rede declarada agora seria um invariante que se quebra a cada
#    serviço novo — e seria declarado contra um palpite.
#
# A postura de rede do host é pendência, não base. Ver ARQUITETURA.md.
if should_run "vm-host"; then
    echo -e "\n${BLUE}==> Hospedeiro de VMs (libvirt + Cockpit)${NC}"
    sudo dnf install -y --skip-unavailable \
        libvirt-daemon libvirt-client virt-install qemu-kvm cockpit-machines

    # O grupo libvirt dá acesso à conexão de sistema do libvirt. Sem ele, o
    # Cockpit não lista VM nenhuma e o virsh só conecta em qemu:///session.
    if id -nG | tr ' ' '\n' | grep -qx libvirt; then
        echo -e "${GREEN}✓ Usuário já está no grupo libvirt.${NC}"
    else
        sudo usermod -aG libvirt "$USER"
        echo -e "${GREEN}✓ Usuário adicionado ao grupo libvirt.${NC}"
        echo -e "${YELLOW}  Vale no próximo login: abra um shell novo antes de esperar ver VMs no Cockpit.${NC}"
    fi

    sudo systemctl enable --now cockpit.socket

    # Pós-condição: a propriedade, não a lista de pacotes.
    #
    # Testa **com sudo**, e essa escolha é deliberada. O caminho sem privilégio
    # depende de o polkit conseguir autorizar, e o autorização sem diálogo só
    # acontece para root ou para quem está no grupo `libvirt` — e o grupo só
    # chega ao processo no login seguinte. Pior: se a sessão não tem agente
    # polkit capaz de mostrar um diálogo, o pedido simplesmente espera e o
    # servidor desiste. Isso faria a pós-condição acusar falha num libvirt
    # perfeitamente saudável, por um motivo que não é do libvirt.
    #
    # Verificar como root testa a coisa que a pós-condição afirma: que o stack
    # de containers do host está no ar. A question de "eu, como usuário, já
    # tenho acesso" é real e é a nota abaixo.
    if timeout 30 sudo virsh -c qemu:///system list --all >/dev/null 2>&1; then
        echo -e "${GREEN}✓ libvirt responde na conexão de sistema.${NC}"
    else
        echo -e "${YELLOW}Aviso: 'virsh -c qemu:///system' não respondeu em 30s.${NC}"
        echo -e "${YELLOW}  O que observar primeiro: 'sudo journalctl -u virtqemud -n 30'.${NC}"
        echo -e "${YELLOW}  Se ainda assim falhar só sem privilégio, provavelmente é autorização:${NC}"
        echo -e "${YELLOW}  o grupo libvirt só vale no próximo login, e sessão sem agente polkit${NC}"
        echo -e "${YELLOW}  capaz de diálogo não consegue autorizar nada.${NC}"
    fi
fi

# ==============================================================================
# Toolbx (opcional) — sandbox Podman rápida fora do contexto de um projeto/devpod
# ==============================================================================
if should_run "toolbx"; then
    echo -e "\n${BLUE}==> Toolbx${NC}"
    sudo dnf install -y toolbox
    echo -e "${GREEN}✓ Toolbox instalado. Uso: 'toolbox create' + 'toolbox enter'.${NC}"
fi

# ==============================================================================
# Acesso gráfico (opcional) — GNOME Remote Desktop nativo (RDP), sem RustDesk
# ==============================================================================
if should_run "gui-access"; then
    echo -e "\n${BLUE}==> Acesso gráfico (GNOME Remote Desktop)${NC}"
    if ! command -v grdctl &> /dev/null; then
        sudo dnf install -y gnome-remote-desktop
    fi
    grdctl rdp enable
    grdctl rdp disable-view-only
    echo -e "${YELLOW}Defina uma credencial de RDP com: grdctl rdp set-credentials <usuario> <senha>${NC}"
    echo -e "${YELLOW}Conecte do Mac usando um cliente RDP (ex: cask 'windows-app' ou 'royal-tsx') apontando pro IP Tailscale deste servidor.${NC}"
fi

# ==============================================================================
# Apps desktop (equivalente ao Brewfile do Mac, com o que tem fonte oficial
# real pra Linux/Fedora — nem tudo do Brewfile tem porte, ver comentários).
# ==============================================================================
if should_run "desktop-apps"; then
    echo -e "\n${BLUE}==> Apps desktop${NC}"

    # VS Code — repo oficial da Microsoft.
    if ! command -v code &> /dev/null; then
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        printf '[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
            | sudo tee /etc/yum.repos.d/vscode.repo > /dev/null
        sudo dnf install -y --skip-unavailable code
    fi

    # Google Chrome — RPM oficial do Google já auto-registra o repo dele
    # pra updates futuros via dnf, sem precisar do dance --add-repo/DNF5.
    if ! command -v google-chrome-stable &> /dev/null; then
        sudo dnf install -y --skip-unavailable https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
    fi

    # Brave — repo oficial deles.
    if ! command -v brave-browser &> /dev/null; then
        sudo rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
        sudo dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
        sudo dnf install -y --skip-unavailable brave-browser
    fi

    # Zed — script de instalação oficial deles (mesmo padrão usado pras CLIs de IA).
    if ! command -v zed &> /dev/null; then
        curl -f https://zed.dev/install.sh | sh
    fi

    # Antigravity IDE — repo rpm oficial do Google (antigravity.google/download/linux).
    # O Brewfile lista dois casks separados ("antigravity" e "antigravity-ide"),
    # mas ambos apontam pro mesmo produto (Antigravity, a IDE agêntica do
    # Google) — o rpm oficial abaixo cobre os dois, não há dois apps distintos
    # a instalar no Fedora.
    if ! command -v antigravity &> /dev/null; then
        # ⚠️ `gpgcheck=0` é uma EXCEÇÃO, e é a única neste script: os outros dois
        # repositórios importam a chave antes (`rpm --import` da Microsoft e da
        # Brave), e este não pode.
        #
        # Medido: o repo do Google não publica chave. `antigravity.repo` e
        # `antigravity-rpm.repo` respondem 404, o `repomd.xml` não declara
        # `gpgkey`, e a chave do Google não está no keyring do host — que tem
        # só a do Fedora e a da Tailscale. Não há URL de chave para importar sem
        # inventá-la, e inventar uma quebraria a instalação.
        #
        # O custo é real e fica registrado: os pacotes deste repo são aceitos sem
        # verificação de assinatura. O módulo é do perfil `host` e não entra no
        # perfil `vm`, então isto não afeta a reprodução da VM de agentes. Se o
        # Google passar a publicar a chave, este é o primeiro lugar a arrumar.
        sudo tee /etc/yum.repos.d/antigravity.repo > /dev/null <<'EOF'
[antigravity-rpm]
name=Antigravity RPM Repository
baseurl=https://us-central1-yum.pkg.dev/projects/antigravity-auto-updater-dev/antigravity-rpm
enabled=1
gpgcheck=0
EOF
        sudo dnf makecache
        sudo dnf install -y --skip-unavailable antigravity
    fi

    # Cursor — AppImage oficial. O antigo link "downloader.cursor.sh" ficou
    # instável (relatos de DNS falhando e de servir builds desatualizadas no
    # fórum oficial) — o endpoint atual e documentado pelo próprio Cursor é
    # essa API, que redireciona pro AppImage mais recente. Sem repo dnf
    # oficial, então baixa e deixa executável em ~/.local/bin.
    if ! command -v cursor &> /dev/null; then
        mkdir -p "$HOME/.local/bin"
        curl -fsSL "https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable" -o "$HOME/.local/bin/cursor.AppImage"
        chmod +x "$HOME/.local/bin/cursor.AppImage"
        ln -sf "$HOME/.local/bin/cursor.AppImage" "$HOME/.local/bin/cursor"
    fi

    # OpenCode Desktop — RPM oficial deles, download direto (opencode.ai/download).
    if ! command -v opencode-desktop &> /dev/null; then
        sudo dnf install -y --skip-unavailable https://opencode.ai/download/stable/linux-x64-rpm
    fi

    # Transmission — já está nos repositórios oficiais do Fedora, sem repo extra.
    sudo dnf install -y --skip-unavailable transmission-gtk

    # Ghostty — NÃO tem repositório oficial do Fedora nem do próprio projeto;
    # só existe via COPR (repositório de terceiros/comunidade). Deixa de fora
    # do "instala tudo por padrão" por ser third-party — habilite manualmente
    # se quiser: sudo dnf copr enable scottames/ghostty && sudo dnf install ghostty
    echo -e "${YELLOW}Ghostty não incluso automaticamente (só existe via COPR de terceiros) — instale manualmente se quiser, ver comentário no script.${NC}"

    echo -e "${GREEN}✓ Apps desktop instalados.${NC}"
    echo -e "${YELLOW}Checados um a um contra fonte oficial (não instalados aqui, por motivo):${NC}"
    echo -e "${YELLOW}  • Sem versão pra Linux, confirmado oficialmente, sem alternativa real: Adobe Creative Cloud; Raycast (sem planos, oficial); OpenUsage (exclusivo macOS 15+); OrbStack (virtualização específica de Apple Silicon — Podman já cobre o papel); Rectangle (usa API do macOS — GNOME já tem tiling nativo, Super+setas); Arc (nunca suportou Linux, e está em modo manutenção desde a Atlassian comprar a empresa); AppCleaner e Pearcleaner (limpam resíduos de apps desinstalados no modelo de 'bundle' do macOS — no Fedora, 'dnf remove'/'dnf autoremove' já cuida disso via o próprio gerenciador de pacotes, não existe o problema que eles resolvem).${NC}"
    echo -e "${YELLOW}  • Têm app oficial pra Linux, mas SEM Fedora/rpm ainda (não dá pra instalar aqui de forma confiável): Claude Desktop (Anthropic — só .deb, Ubuntu/Debian); ChatGPT Desktop (OpenAI — tem rpm oficial pro Fedora 43/44 em chatgpt.com/download, mas está em preview com bug conhecido de verificação de assinatura — instale manualmente se quiser, considerando isso).${NC}"
    echo -e "${YELLOW}  • Oficial só via Docker/Podman Compose (não é um app desktop nativo): Open Design — veja o quickstart oficial deles, já que você tem Podman configurado.${NC}"
    echo -e "${YELLOW}  • devpod tem binário Linux oficial, mas não precisa aqui — ele roda do lado Mac controlando este servidor, não o contrário.${NC}"
    echo -e "${YELLOW}  • Sem app oficial do fabricante, só opção NÃO-oficial/não-verificada de terceiros (decisão sua instalar, é software de terceiros reimplementando algo proprietário — nenhuma instalada automaticamente): GitHub Desktop (Flatpak io.github.shiftey.Desktop, fork shiftkey/desktop); Notion (Flatpak so.notion.Notion, wrapper não-oficial); Figma (Flatpak io.github.Figma_Linux.figma_linux, wrapper não-oficial); Spotify (Flatpak com.spotify.Client — 'Unverified' no Flathub, é empacotamento comunitário do binário oficial, não mantido pela Spotify); Termius (Flatpak com.termius.Termius — Flathub avisa explicitamente que não é afiliado/suportado pela Termius Corporation); FontBase (AppImage oficial em fontba.se/downloads/linux, sem link 'sempre atual' estável pra automatizar aqui); Surfshark (sem suporte oficial a Fedora — só Debian/Ubuntu/Mint; Flathub/Snap não é mantido pela Surfshark).${NC}"
fi

# ==============================================================================
# CLIs de IA (guest apenas — é onde os agentes rodam; no host elas não têm papel)
# ==============================================================================
if should_run "ai-clis"; then
    echo -e "\n${BLUE}==> CLIs de IA${NC}"
    if [ "$CONFIRM_AI_CLIS" = "1" ]; then
        install_common_ai_clis
    else
        echo -e "${YELLOW}Instalação de CLIs de IA ignorada (rodam dentro dos devcontainers, por projeto).${NC}"
    fi
fi

# ==============================================================================
# OpenCodex CLI (@bitkyc08/opencodex) — router para modelos de IA
# ==============================================================================
if should_run "opencodex"; then
    echo -e "\n${BLUE}==> OpenCodex${NC}"
    if [ "$CONFIRM_OPENCODEX" = "1" ]; then
        install_opencodex
    else
        echo -e "${YELLOW}OpenCodex ignorado (proxy de provider de terceiros, opt-in).${NC}"
    fi
fi

# ==============================================================================
# CLI do Hermes, dashboard e OpenDesign
# ==============================================================================
#
# ⚠️ ESTES TRÊS BLOCOS FORAM ADICIONADOS DEPOIS. As funções `setup_hermes_cli`,
# `setup_hermes_dashboard`, `setup_open_design` e `setup_open_design_container`
# existiam, completas, e NÃO ERAM CHAMADAS DE LUGAR NENHUM. Medido: zero
# chamadas fora da definição, e nenhum bloco `if should_run "hermes-…"` no fluxo
# principal. O bloco de perguntas em 2319 perguntava o modo do OpenDesign e
# guardava o token, e o script seguia para o fim sem instalar nada.
#
# O efeito era invisível numa máquina já montada — os três serviços foram
# instalados à mão nesta VM, e a mão não aparece no log do script. Numa máquina
# limpa o resultado era silencioso e errado: o script terminava com sucesso
# tendo perguntado sobre o OpenDesign e não o having instalado.
#
# É o caso mais perigoso de divergência entre o que um script parece fazer e o
# que ele faz, porque nenhum dos dois lados reclama.
#
# A ordem não é arbitrária. O OpenDesign detecta os agentes pelo PATH, e o
# `hermes` é um deles (medido: 7 agentes, um deles `hermes`), então a CLI do
# Hermes precisa estar ANTES do OpenDesign — senão o daemon lista seis em vez de
# sete. E o dashboard usa a CLI, então vem logo depois dela.

if should_run "hermes-cli"; then
    echo -e "\n${BLUE}==> CLI do Hermes${NC}"
    if ! setup_hermes_cli; then
        echo -e "${YELLOW}CLI do Hermes não ficou pronta; o dashboard e o OpenDesign dependem dela.${NC}" >&2
    fi
fi

if should_run "hermes-dashboard"; then
    echo -e "\n${BLUE}==> Dashboard do Hermes${NC}"
    if ! command -v hermes &> /dev/null; then
        echo -e "${YELLOW}CLI do Hermes ausente; rode o módulo hermes-cli primeiro.${NC}" >&2
    elif ! setup_hermes_dashboard; then
        echo -e "${YELLOW}Dashboard do Hermes não subiu; a unit foi declarada mesmo assim.${NC}" >&2
    fi
fi

# O modo vem da pergunta do bloco de inicialização. Sem resposta — EOF, ou o
# operador pulou o passo com `--only` — não há o que despachar, e a resposta
# correta é não instalar, que é o mesmo desfecho de responder "não".
if should_run "open-design" || should_run "open-design-container"; then
    echo -e "\n${BLUE}==> OpenDesign${NC}"
    case "${OPENDESIGN_MODE:-}" in
        nativo)
            setup_open_design || echo -e "${YELLOW}OpenDesign nativo não completou; ver a saída acima.${NC}" >&2
            ;;
        container)
            setup_open_design_container || echo -e "${YELLOW}OpenDesign em container não completou; ver a saída acima.${NC}" >&2
            ;;
        *)
            echo -e "${YELLOW}OpenDesign: nenhum modo escolhido, não instalei.${NC}"
            ;;
    esac
fi

# ==============================================================================
# O zsh é o shell de login padrão do host, então o zshrc versionado é quem é dono
# do PATH interativo: mise, bun, ~/.local/bin e ~/.opencode/bin. O bloco em
# ~/.bashrc cobre apenas os contextos bash restantes (su -, shell não interativo).
if should_run "zshrc"; then
    echo -e "\n${BLUE}==> zsh como shell de login${NC}"
    sudo dnf install -y --skip-unavailable zsh zsh-autosuggestions zsh-syntax-highlighting
    link_zshrc
    # ── o shell de login, medido pelo ESTADO e nao pelo `&&` do `chsh` ────────
    #
    # Medido no container, com um usuario de teste:
    #
    #     $ chsh -s /bin/bash tester     # o shell que ele JA tinha
    #     Changing shell for tester.
    #     chsh: Shell not changed.
    #     exit=0
    #
    # O `chsh` sai com 0 QUANDO NAO MUDOU NADA. E o `man` diz "0 se a operacao
    # deu certo, 1 se falhou" — o que, para quem le, parece "0 = shell trocado".
    # Com o `&&` do jeito antigo, o script imprimia
    #
    #     ✓ Shell padrão alterado para zsh
    #
    # depois de um `chsh` que tinha dito "Shell not changed.". Foi assim que o
    # log mentiu na VM nova: a mensagem de sucesso estava lá, e o shell não tinha
    # mudado. `&&` so protege quando a ferramenta usa o codigo de saida para
    # distinguir "fiz" de "nao tinha nada a fazer" — e o `chsh` nao distingue.
    #
    # E o guard antigo comparava `$SHELL`, que e o shell do PROCESSO (herdado de
    # quem abriu a sessao), nao o shell de LOGIN do usuario. Sao coisas diferentes:
    # o `$SHELL` pode ja ser o zsh com o passwd ainda em bash, ou o contrario.
    # Quem responde "qual e o shell de login" e a entrada do passwd, e ela e
    # legivel sem privilegio.
    _shell_login() { getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7; }
    _zsh_alvo="$(command -v zsh || true)"
    if [ -z "$_zsh_alvo" ]; then
        echo -e "${YELLOW}zsh nao instalado; o shell de login ficou como estava.${NC}" >&2
    else
        _shell_atual="$(_shell_login)"
        if [ "$_shell_atual" = "$_zsh_alvo" ]; then
            echo -e "${GREEN}✓ Shell de login ja e zsh (${_zsh_alvo}).${NC}"
        else
            echo -e "${BLUE}  Shell de login atual: ${_shell_atual:-desconhecido}${NC}"
            if sudo chsh -s "$_zsh_alvo" "$(id -un)"; then
                # O `chsh` nao serve como prova: ele sai com 0 sem mudar nada.
                # A prova e a entrada do passwd DEPOIS.
                if [ "$(_shell_login)" = "$_zsh_alvo" ]; then
                    echo -e "${GREEN}✓ Shell de login alterado para zsh (${_zsh_alvo}); efeito no proximo login.${NC}"
                else
                    # `$(_shell_login)`, e nao `${_shell_login:-desconhecido}`: os
                    # parenteses sao a chamada da funcao. Com chaves, isso e
                    # expansao de uma variavel cujo NOME e o valor da funcao — e o
                    # resultado e a string "desconhecido", sempre. A frase saia
                    # "`continua desconhecido`" mesmo com o shell a vista, o que e
                    # pior que nao dizer nada: aponta para o lugar errado.
                    echo -e "${YELLOW}O chsh disse que foi, mas o shell de login continua $(_shell_login).${NC}" >&2
                    echo -e "${YELLOW}  Verifique: getent passwd $(id -un)${NC}" >&2
                fi
            else
                echo -e "${YELLOW}O chsh falhou (saida diferente de zero); o shell de login continua ${_shell_atual:-desconhecido}.${NC}" >&2
                echo -e "${YELLOW}  O zsh precisa estar em /etc/shells para o chsh aceitar.${NC}" >&2
            fi
        fi
    fi
fi

# O que falta depois do provisionamento, dito no fim e não no meio. As seis CLIs de
# agente são instaladas pelo módulo `ai-clis` mas não são autenticadas por ele: cada
# uma tem o próprio login, e nenhuma delas é coberta por este script.
#
# O que é verificado aqui é factual e restrito: o binário existe, e existe um
# diretório de configuração. **Presença de configuração não é prova de
# autenticação** — nenhuma CLI expõe um subcomando estável de "estado da
# autenticação", e inventar um seria pior que dizer que não se sabe. O que o
# relatório faz é apontar o que existe e o que não existe, e dizer onde autenticar.
if should_run "ai-clis"; then
    echo -e "\n${BLUE}==> CLIs de agente: o que ainda falta${NC}"
    _falta=0
    while IFS='|' read -r _cli _dir; do
        [ -z "$_cli" ] && continue
        # ⚠️ O `command -v` sozinho produz um FALSO NEGATIVO aqui, e medido: o
        # relatório dizia "opencode: binário ausente" no mesmo módulo que tinha
        # acabado de instalar o opencode, de ligá-lo e de publicá-lo. O binário
        # estava lá — `opencode v2.0.19` respondeu — mas `command -v` é falso
        # porque `~/.opencode/bin` não está no PATH de uma sessão não interativa,
        # e o único fallback era `~/.bun/bin`, onde o opencode nunca é instalado.
        #
        # A correção é perguntar aos DOIS lugares onde os instaladores deste
        # script depositam as CLIs: o Bun (`~/.bun/bin`) e o instalador do
        # opencode (`~/.opencode/bin`). Um relatório que afirma que algo falta
        # quando existe é pior do than um que não afirma nada.
        _bin=""
        for _cand in "$(command -v "$_cli" 2>/dev/null)" \
                     "$HOME/.bun/bin/$_cli" \
                     "$HOME/.opencode/bin/$_cli"; do
            [ -n "$_cand" ] && [ -x "$_cand" ] && { _bin="$_cand"; break; }
        done
        if [ -z "$_bin" ]; then
            printf '  %-14s %-22s %s\n' "$_cli" "binário ausente" "rode o módulo ai-clis"
            _falta=1
        elif [ -e "$HOME/$_dir" ]; then
            printf '  %-14s %-22s %s\n' "$_cli" "config presente" "confirme com: $_cli --help"
        else
            printf '  %-14s %-22s %s\n' "$_cli" "sem config" "autentique com: $_cli"
            _falta=1
        fi
    done <<'CLI_LIST'
claude|.claude
codex|.codex
cursor-agent|.cursor-agent
agy|.agy
opencode|.config/opencode
CLI_LIST
    if [ "$_falta" = "1" ]; then
        echo -e "${YELLOW}  As CLIs acima sem config ou sem binário ainda não estão prontas para uso.${NC}"
    fi
    unset _cli _dir _bin _falta _cand
fi


# ==============================================================================
# As pós-condições: o que este run NAO conseguiu fazer
# ==============================================================================
#
# O run dizia "Configuração finalizada" e saía com `exit 1`. As duas frases
# juntas eram uma contradição, e a segunda não tinha relação com a primeira: o
# `exit 1` vinha do `set -e` reagindo ao `return 1` de um módulo, por acidente de
# posição, e não de um resumo. Quem lesse o banner não saberia o que tinha
# falhado, e um `exit 0` também não — que foi como o primeiro run nesta VM
# morreu no meio, em 8 de 15 módulos, e pareceu sucesso.
#
# Cada função abaixo pergunta ao sistema se a coisa EXISTE. Nenhuma delas
# confere o log: o log é o que o script disse, e o estado é o que a máquina tem.
# São as duas coisas diferentes, e só a segunda serve para provar.
#
# A lista é curta de propósito. Ela cobre o que, se faltar, deixa a máquina
# imprestável para o uso para que ela existe — um agente de fronteira sem porta,
# sem identidade no GitHub, ou com o container parado não é uma máquina
# configurada, é uma que parece configurada.

# --- o servidor do OpenCode: a fronteira depende dele para o agente falar com
# --- o host. Sem ele, todo agente que abre o servidor nao conecta.
_od_server_presente() {
    if systemctl --user is-active --quiet opencode.service 2>/dev/null; then
        _registrar_ok "servidor do OpenCode no ar (opencode.service active)"
    else
        _registrar_falha "o servidor do OpenCode nao esta no ar (opencode.service)"
    fi
}

# --- o container do OpenDesign: o modo padrao desta maquina. Um container que
# --- existe mas nao esta `up` e pior que nenhum, porque o serve aponta para ele.
_od_container_presente() {
    if [ "$OPENDESIGN_MODE" != "container" ]; then
        return 0
    fi
    if podman container exists open-design 2>/dev/null; then
        if [ "$(podman inspect -f '{{.State.Status}}' open-design 2>/dev/null)" = "running" ]; then
            _registrar_ok "container do OpenDesign rodando"
        else
            _registrar_falha "o container do OpenDesign existe mas nao esta rodando"
        fi
    else
        _registrar_falha "o container do OpenDesign nao existe (o modo padrao e container)"
    fi
}

# --- a identidade da maquina no GitHub: sem ela, nenhum agente consegue criar
# --- PR, e a fronteira perde a razao de existir. Mas a App e opt-in por
# --- decisao do dono, entauso sua ausencia e NOTA e nao FALHA.
_gh_identidade_presente() {
    if [ -x "$HOME/.local/bin/gh-app" ] || [ -x "$HOME/.local/bin/gh-app-token" ]; then
        _registrar_ok "identidade de maquina no GitHub instalada (gh-app)"
    else
        echo -e "  ${YELLOW}nota: sem identidade de maquina no GitHub.${NC}"
        echo -e "  ${YELLOW}  A App e opt-in — a private key e um segredo que existe fora da maquina.${NC}"
        echo -e "  ${YELLOW}  Para ativar: ./setup.sh --profile=vm --only=gh-app${NC}"
    fi
}

# --- a publicacao na tailnet: e o que torna a VM alcancavel sem abrir porta.
_od_publicado() {
    local p="$1" o que="$2"
    if tailscale serve status 2>/dev/null | grep -q ":$p"; then
        _registrar_ok "publicado na tailnet em :$p (${o} que)"
    else
        _registrar_falha "nao publicado na tailnet em :$p (${o} que)"
    fi
}

# --- o secret: um arquivo de senha 777 e uma porta aberta, e o motivo de o
# --- guard de sandbox existir. O default do script e `hermes`, que e adivinhavel.
_hermes_secret_presente() {
    if systemctl --user is-active --quiet hermes-dashboard.service 2>/dev/null; then
        _registrar_ok "dashboard do Hermes no ar"
    else
        _registrar_falha "o dashboard do Hermes nao esta no ar"
    fi
}

# --- o zshrc: o dono do PATH interativo. Sem ele, bun, os shims do mise e o
# --- opencode nao estao no PATH de um shell de login, e a sintoma e um comando
# --- que existe mas "nao e encontrado".
_zshrc_presente() {
    local alvo
    alvo="$(readlink -f "$HOME/.zshrc" 2>/dev/null || true)"
    if [ -n "$alvo" ] && [ -f "$alvo" ]; then
        _registrar_ok "zshrc do repositorio em uso (~/.zshrc -> ${alvo##*/})"
    else
        _registrar_falha "~/.zshrc nao aponta para o zshrc deste repositorio"
    fi
}

_rodar_pos_condicoes() {
    # Um `--only` instala uma coisa e NAO as outras, por escolha de quem chamou.
    # Verificar a maquina inteira reportaria como pendencia tudo o que o run
    # proposadamente deixou de fora — e o run parcial terminaria com "7 pendencias"
    # numa maquina que esta exatamente como o `--only` pediu.
    #
    # A regra: `--only` verifica so o que ele instalou. Num run do perfil inteiro,
    # todas verificam. E o que separa "a maquina nao esta pronta" de "este run nao
    # era para deixa-la pronta".
    if [ -n "$ONLY" ]; then
        echo
        echo -e "${BLUE}=== Verificacao do que este run instalou (--only) ===${NC}"
        echo -e "Um --only e um run parcial: a maquina vai continuar sem o que ele nao"
        echo -e "instalou, por escolha. As pos-condicoes do perfil inteiro nao valem aqui."
        _zshrc_presente
        echo
        return 0
    fi
    echo
    echo -e "${BLUE}=== O que esta maquina tem, verificado agora ===${NC}"
    _od_server_presente
    _od_container_presente
    _od_publicado "$OPENDESIGN_SERVE_PORT" "OpenDesign"
    _od_publicado 8445 "Hermes"
    _gh_identidade_presente
    _hermes_secret_presente
    _zshrc_presente
    echo
}

_rodar_pos_condicoes
# A mensagem final é por perfil porque o próximo passo mudou de destino: o devpod
# passou a mirar a VM, não o host. Dizer "configure o devpod com este servidor"
# aqui mandaria o Mac ao lugar errado.
# O banner diz o que o ESTADO diz, e nao o que o run queria. Um "finalizada"
# incondicional ao lado de um `exit 1` era uma contradicao que nao deixava ninguem
# decidir nada; e o `exit` dependia do `set -e` acertar a posicao do `return 1`,
# o que e acaso, nao projeto.
#
# As duas informacoes vem do MESMO lugar: a lista de falhas. Se a lista esta
# vazia, o banner e verde e o codigo e 0. Se tem algo, o banner diz o que ficou
# para tras e o codigo e 1. Nao ha como divergirem, porque sao a mesma leitura.
if [ "${#_FALHAS[@]}" -eq 0 ]; then
    _banner="Configuração da VM de agentes finalizada!"
    _cor="${GREEN}"
else
    _banner="Configuração da VM de agentes: ${#_FALHAS[@]} pendência(s)."
    _cor="${YELLOW}"
fi

if [ "$PROFILE" = "vm" ]; then
    echo -e "\n${_cor}=== ${_banner} ===${NC}"
    if [ "${#_FALHAS[@]}" -ne 0 ]; then
        # Cada pendencia com o comando que resolve. Um numero ("2 pendencias")
        # obriga quem leu a voltar ao log e casar o numero com a linha; a lista
        # nao.
        echo -e "${YELLOW}Não ficou pronto. Estas são as pendências, por estado:${NC}"
        for _f in "${_FALHAS[@]}"; do
            echo -e "  ${YELLOW}•${NC} $_f"
        done
        echo
        echo -e "O código de saída é 1 por causa delas. A máquina está no que deu para"
        echo -e "instalar, e nos pontos acima ela não está no que precisa estar."
    else
        echo -e "Próximo passo: tire um snapshot desta VM como baseline, e no Mac aponte o"
        echo -e "devpod para ela por provider SSH. Ver ARQUITETURA.md."
    fi
else
    if [ "${#_FALHAS[@]}" -eq 0 ]; then
        echo -e "\n${GREEN}=== Configuração do Fedora Workstation finalizada! ===${NC}"
    else
        echo -e "\n${YELLOW}=== Configuração do Fedora Workstation: ${#_FALHAS[@]} pendência(s). ===${NC}"
        for _f in "${_FALHAS[@]}"; do
            echo -e "  ${YELLOW}•${NC} $_f"
        done
    fi
    echo -e "Próximo passo: crie a VM de agentes no Cockpit e rode './setup.sh --profile=vm' dentro dela."
    echo -e "A rede usada é a default do libvirt; o repo ainda não declara rede, porque a lista de"
    echo -e "serviços que o host vai expor não está escrita. Ver ARQUITETURA.md."
fi

# O código de saída, deciddo aqui e em mais nenhum lugar.
#
# Não havia nenhum. O `exit 1` que apareceu nesta VM foi o `set -e` reagindo ao
# `return 1` de um módulo — o que significa que o mesmo `return 1` encerra o run
# num ponto e só marca falha em outro, conforme a posição. Um código de saída que
# depende de posição é acaso com aparência de contrato.
#
# Agora ele sai da lista de pendências, que veio das pós-condições, que
# interrogaram o estado da máquina. Quem provisiona olha o código e sabe se a
# máquina está no que precisa estar, e o banner diz a mesma coisa pela mesma
# leitura — não podem divergir porque não são duas fontes.
if [ "${#_FALHAS[@]}" -ne 0 ]; then
    echo -e "\n${YELLOW}Código de saída 1: ${#_FALHAS[@]} pendência(s) acima.${NC}"
    exit 1
fi
exit 0
# setup.sh versão: 2026.10.03-e952827+pull-serve (última linha; leia-a para saber qual script é este)
