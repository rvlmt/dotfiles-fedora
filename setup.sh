#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Runtime do host, pinado aqui para que setup, shell de login e devcontainers
# concordem. Quem fornece Node/npm no host é o mise — o pacote nodejs do dnf
# não é instalado de propósito, para que o runtime do host não dependa da
# versão que o Fedora decidir empacotar. Ver README, "Runtime Node no host".
MISE_NODE_VERSION="24.21.0"
MISE_DEVCONTAINER_VERSION="0.89.0"
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
OPENCODE_BIND="127.0.0.1"
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

# Preenche GIT_NAME/GIT_EMAIL: pula o prompt se já vierem do ambiente
# (pré-exportados), senão pergunta com o default sugerido entre colchetes
# (Enter aceita, digitar outra coisa sobrescreve só nesta execução).
prompt_git_identity() {
    if [ -z "$GIT_NAME" ]; then
        read -rp "Nome completo para o Git [$DEFAULT_GIT_NAME]: " GIT_NAME
        GIT_NAME="${GIT_NAME:-$DEFAULT_GIT_NAME}"
    fi
    if [ -z "$GIT_EMAIL" ]; then
        read -rp "E-mail (Git e SSH) [$DEFAULT_GIT_EMAIL]: " GIT_EMAIL
        GIT_EMAIL="${GIT_EMAIL:-$DEFAULT_GIT_EMAIL}"
    fi
}

confirm() {
    local prompt="$1"
    local reply
    read -rp "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
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
    local mise_bin_path
    mise_bin_path="$(mise_bin)"
    "$mise_bin_path" install "node@$MISE_NODE_VERSION" "devcontainer-cli@$MISE_DEVCONTAINER_VERSION"
    "$mise_bin_path" use -g --pin "node@$MISE_NODE_VERSION" "devcontainer-cli@$MISE_DEVCONTAINER_VERSION"
    prepend_mise_shims
    echo -e "${GREEN}✓ Runtime do host: node@$MISE_NODE_VERSION, devcontainer-cli@$MISE_DEVCONTAINER_VERSION${NC}"
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
    local target="${OPENCODE_BIND}:${OPENCODE_PORT}"

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
setup_opencode_service() {
    local unit="$HOME/.config/systemd/user/opencode.service"
    local dropin_dir="$HOME/.config/systemd/user/opencode.service.d"
    local dropin="$dropin_dir/10-bind.conf"
    if [ ! -f "$unit" ]; then
        return 0
    fi

    local exec_line bin
    exec_line="$(sed -nE 's/^ExecStart=(.*)$/\1/p' "$unit" | head -1)"
    if [ -z "$exec_line" ]; then
        echo -e "${YELLOW}Não li o ExecStart de $unit; pulei o drop-in do OpenCode.${NC}" >&2
        return 1
    fi
    bin="${exec_line%% *}"
    if [ ! -x "$bin" ]; then
        echo -e "${YELLOW}Binário $bin não é executável; pulei o drop-in do OpenCode.${NC}" >&2
        return 1
    fi

    # Sobrescreve só --hostname e --port, preservando --service e qualquer outra
    # flag do instalador. Trocar o comando inteiro aqui quebraria a senha.
    local new_line="$exec_line"
    if [[ "$new_line" == *"--hostname"* ]]; then
        new_line="$(printf '%s' "$new_line" | sed -E "s/--hostname[= ][^ ]+/--hostname ${OPENCODE_BIND}/g")"
    else
        new_line="$new_line --hostname $OPENCODE_BIND"
    fi
    if [[ "$new_line" == *"--port"* ]]; then
        new_line="$(printf '%s' "$new_line" | sed -E "s/--port[= ][^ ]+/--port ${OPENCODE_PORT}/g")"
    else
        new_line="$new_line --port $OPENCODE_PORT"
    fi

    local expected="[Service]
# Gerado por dotfiles-fedora (setup.sh): declara a escuta em loopback do servidor
# do OpenCode. Preserva --service de propósito, para que a senha continue vindo
# de ~/.config/opencode/service.json em vez de ser regenerada a cada start.
ExecStart=
ExecStart=$new_line"

    mkdir -p "$dropin_dir"
    if [ -f "$dropin" ] && [ "$(cat "$dropin")" = "$expected" ]; then
        echo -e "${GREEN}✓ Escuta do OpenCode já declarada ($OPENCODE_BIND:$OPENCODE_PORT).${NC}"
        return 0
    fi
    printf '%s\n' "$expected" > "$dropin"
    systemctl --user daemon-reload 2>/dev/null || true
    echo -e "${GREEN}✓ Drop-in de escuta do OpenCode criado ($OPENCODE_BIND:$OPENCODE_PORT).${NC}"
    echo -e "${YELLOW}  Aplique com: systemctl --user restart opencode${NC}"
}

# Instala um pacote npm global (via Bun se disponível, com fallback pra npm), idempotente.
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

    install_npm_global "@anthropic-ai/claude-code" "claude"
    install_npm_global "@openai/codex" "codex"

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
        echo -e "${YELLOW}Login de pessoa não solicitado: 'gh' segue sem token próprio.${NC}"
        echo -e "${YELLOW}  A API dos agentes continua coberta pela GitHub App, pelo wrapper 'gh-app'.${NC}"
        echo -e "${YELLOW}  Consequência: a chave SSH desta máquina NÃO é registrada no GitHub, porque${NC}" >&2
        echo -e "${YELLOW}  registrar chave é um endpoint de usuário (POST /user/keys) e um token de${NC}" >&2
        echo -e "${YELLOW}  instalação da App não o alcança. Para clonar e dar push por SSH, registre a${NC}" >&2
        echo -e "${YELLOW}  chave uma vez, de uma máquina que já tenha o 'gh' autenticado:${NC}" >&2
        echo -e "${YELLOW}    gh ssh-key add ~/.ssh/id_ed25519.pub --title '<esta VM>'${NC}" >&2
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
    elif [ -e "$zshrc_dest" ] || [ -L "$zshrc_dest" ]; then
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
ALL_STEPS="base hostname ssh git podman gh-app tailscale sshd-hardening firewalld vm-host toolbx gui-access desktop-apps ai-clis opencodex zshrc"

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
HOST_STEPS="base hostname ssh git tailscale sshd-hardening firewalld vm-host toolbx gui-access desktop-apps opencodex zshrc"
VM_STEPS="base ssh git gh-app tailscale sshd-hardening podman ai-clis zshrc"

# Opcionais dentro do próprio perfil: não rodam por padrão mesmo sem --only.
OPT_IN_STEPS="toolbx gui-access"

usage() {
    cat <<EOF
Uso: ./setup.sh [--profile=host|vm] [--only=modulo1,modulo2] [--skip=modulo1,modulo2]

Perfis:
  host   Workstation pessoal com GUI e hospedeiro de VMs. Padrão.
  vm     A VM de agentes: Podman rootless, CLIs de agente, servidor do OpenCode.
         Use dentro da VM, não no host.

  --profile=vm            Escolhe a camada. Sem --profile, assume host.

Módulos:
  --only=modulo1,modulo2   Roda apenas os módulos listados, dentro do perfil.
  --skip=modulo1,modulo2  Roda o perfil inteiro, exceto os módulos listados.
  -h, --help               Mostra esta ajuda.

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
for arg in "$@"; do
    case "$arg" in
        --profile=*) PROFILE="${arg#*=}" ;;
        --only=*) ONLY="${arg#*=}" ;;
        --skip=*) SKIP="${arg#*=}" ;;
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

# Recusa antecipada quando o stdin não é um terminal.
#
# As perguntas usam `read -rp`, que o bash só imprime quando o stdin é terminal.
# E `read` devolve 1 no fim da entrada; como algumas dessas leituras estão fora de
# um contexto `&&`, o `set -e` aborta o script — sem mensagem, com código 1, e
# depois do banner. Ou seja: um run por pipe morre no meio em vez de recusar.
#
# A escolha é recusar aqui, com mensagem, e não "seguir com o default". Seguir
# produziria um provisionamento parcial e silencioso, que é pior que não rodar.
if [ ! -t 0 ]; then
    echo "Este script precisa de um terminal: ele pergunta coisas antes de agir." >&2
    echo "" >&2
    echo "stdin não é um terminal (pipe, redirecionamento ou CI). Nessas condições o" >&2
    echo "comportamento seria morrer no meio, sem aviso, em vez de recusar — por isso" >&2
    echo "a recusa é aqui." >&2
    echo "" >&2
    echo "Para rodar de verdade: abra um terminal e execute './setup.sh'." >&2
    echo "Para inspecionar sem rodar: './setup.sh --help'." >&2
    exit 1
fi

case "$PROFILE" in
    host) echo -e "${BLUE}=== Setup do Fedora Workstation: workstation pessoal + hospedeiro de VMs ===${NC}\n" ;;
    vm) echo -e "${BLUE}=== Setup da VM de agentes: a fronteira ===${NC}\n" ;;
esac

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
        read -r -p "  App ID: " app_id
        if [ -z "$app_id" ]; then
            echo -e "${GREEN}  Mantida a App já configurada em $GH_APP_DIR.${NC}"
            return 0
        fi
    else
        read -r -p "  App ID [${DEFAULT_GH_APP_ID}]: " app_id
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
        echo -e "${YELLOW}Rodando 'tailscale up' — abra o link exibido para autenticar.${NC}"
        # Sem --ssh de propósito: o Tailscale SSH exige reautenticação
        # interativa via navegador sempre que a política da tailnet tiver
        # "action: check" nos grants de ssh (o default da maioria das
        # tailnets) — quebra qualquer ferramenta que não sabe abrir um
        # navegador (Codex Desktop, devpod não-interativo, etc.), e tem
        # aviso oficial de incompatibilidade com SELinux enforcing no
        # Fedora. O acesso SSH de verdade já é coberto pelo módulo
        # sshd-hardening (só chave, sem senha) + firewalld (sshd só na
        # interface tailscale0) — sem depender de reautenticação alguma.
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
    echo "Hostname atual: $CURRENT_HOSTNAME"
    read -rp "Novo hostname (deixe em branco para manter '$CURRENT_HOSTNAME'): " NEW_HOSTNAME
    if [ -n "$NEW_HOSTNAME" ] && [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
        confirm "Alterar o hostname para '$NEW_HOSTNAME'?" && CONFIRM_HOSTNAME=1
    else
        NEW_HOSTNAME=""
    fi
fi

CONFIRM_SSHD_HARDENING=""
if should_run "sshd-hardening" && [ ! -f /etc/ssh/sshd_config.d/99-dotfiles-hardening.conf ]; then
    confirm "Desabilitar login por senha via SSH (só chave pública a partir daqui)?" && CONFIRM_SSHD_HARDENING=1
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
    confirm "Instalar as CLIs de IA (Claude Code, Codex, Gemini, etc.) nesta máquina? (opcional, já rodam nos devcontainers)" && CONFIRM_AI_CLIS=1
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
    confirm "Definir uma senha de sua preferencia para o servidor do OpenCode? (a senha e obrigatoria; em branco mantem a que o instalador gerar)" && CONFIRM_OPENCODE_PASSWORD=1
    if [ "$CONFIRM_OPENCODE_PASSWORD" = "1" ]; then
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
    confirm "Autenticar o 'gh' com login de pessoa? (Enter = não; a GitHub App já cobre a API dos agentes)" && CONFIRM_GH_LOGIN=1
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
sudo -v
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
    sudo dnf install -y --skip-unavailable \
        git gh jq tree tmux zellij ripgrep fd-find unzip \
        curl wget btop tar openssl \
        dnf5-plugins
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
    if [ -n "$NEW_HOSTNAME" ]; then
        if [ "$CONFIRM_HOSTNAME" = "1" ]; then
            sudo hostnamectl set-hostname "$NEW_HOSTNAME"
            echo -e "${GREEN}✓ Hostname definido como: $NEW_HOSTNAME${NC}"
        else
            echo -e "${YELLOW}Alteração de hostname ignorada.${NC}"
        fi
    else
        echo -e "${YELLOW}Hostname mantido como '$CURRENT_HOSTNAME'.${NC}"
    fi
    mkdir -p "$HOME/Developer"
fi

# ==============================================================================
# Chave SSH Ed25519 + Git/GitHub CLI
# ==============================================================================
if should_run "ssh"; then
    echo -e "\n${BLUE}==> SSH (Ed25519)${NC}"
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

GH_TOKEN="$(cat "$TOKEN")" command gh "$@"
WRAPPER
        chmod 0755 "$HOME/.local/bin/gh-app"

        echo -e "${BLUE}Validando a App contra a API (não é checagem de arquivo)${NC}"
        if GH_APP_KEY="$GH_APP_KEY_FILE" GH_APP_ID="$(cat "$GH_APP_ID_FILE")" \
           "$HOME/.local/bin/gh-app-token" --check; then
            echo -e "${GREEN}✓ App validada contra a API.${NC}"
            echo -e "${YELLOW}  Use como 'gh-app pr list'. O 'gh' sem o wrapper vai pedir login.${NC}"
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
    SSHD_CONFIG="/etc/ssh/sshd_config.d/99-dotfiles-hardening.conf"
    if [ ! -f "$SSHD_CONFIG" ]; then
        # Desabilitar PasswordAuthentication sem ter nenhuma chave em
        # authorized_keys já cadastrada te tranca pra fora via SSH de vez —
        # o script não popula esse arquivo (ele só gera/usa chaves pra
        # autenticar ESTA máquina no GitHub, não pra permitir login de
        # outras máquinas aqui). Se você contava só com o Tailscale SSH pra
        # entrar (agora desligado por padrão — ver módulo "tailscale"),
        # confirme que já tem uma chave pública aí antes de continuar.
        if [ ! -s "$HOME/.ssh/authorized_keys" ]; then
            echo -e "${YELLOW}~/.ssh/authorized_keys vazio ou inexistente — desabilitar login por senha agora te deixaria sem nenhum jeito de entrar via SSH. Adicione a chave pública da máquina de onde você acessa (ex.: 'cat ~/.ssh/id_ed25519.pub' no Mac, cole aqui em ~/.ssh/authorized_keys) antes de rodar este módulo. Pulando.${NC}"
        elif [ "$CONFIRM_SSHD_HARDENING" = "1" ]; then
            sudo tee "$SSHD_CONFIG" > /dev/null <<EOF
PasswordAuthentication no
PermitRootLogin no
EOF
            sudo systemctl reload sshd
            echo -e "${GREEN}✓ sshd endurecido (login por senha desabilitado).${NC}"
        else
            echo -e "${YELLOW}Hardening do sshd ignorado.${NC}"
        fi
    else
        echo -e "${YELLOW}Hardening do sshd já aplicado ($SSHD_CONFIG existe).${NC}"
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
# firewalld: interface do Tailscale fica totalmente confiável (SSH, RDP, devpod,
# etc.), o resto (LAN/internet) segue bloqueado pela zona padrão do firewalld.
# ==============================================================================
if should_run "firewalld"; then
    echo -e "\n${BLUE}==> firewalld${NC}"
    sudo dnf install -y firewalld
    sudo systemctl enable --now firewalld

    if ! sudo firewall-cmd --get-zones | grep -q trusted; then
        echo -e "${YELLOW}Zona 'trusted' não encontrada — pulando regra de interface Tailscale.${NC}"
    else
        # Zona "trusted" libera TODO tráfego na interface tailscale0 (não só SSH) —
        # aceitável aqui porque a própria tailnet já autentica quem entra nela.
        sudo firewall-cmd --zone=trusted --change-interface=tailscale0 --permanent 2>/dev/null || true
        sudo firewall-cmd --reload
        echo -e "${GREEN}✓ Interface tailscale0 marcada como confiável no firewalld.${NC}"
    fi
    echo -e "${YELLOW}Revise 'sudo firewall-cmd --list-all' e feche manualmente qualquer porta que não precise estar exposta na LAN/internet.${NC}"
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
# O zsh é o shell de login padrão do host, então o zshrc versionado é quem é dono
# do PATH interativo: mise, bun, ~/.local/bin e ~/.opencode/bin. O bloco em
# ~/.bashrc cobre apenas os contextos bash restantes (su -, shell não interativo).
if should_run "zshrc"; then
    echo -e "\n${BLUE}==> zsh como shell de login${NC}"
    sudo dnf install -y --skip-unavailable zsh zsh-autosuggestions zsh-syntax-highlighting
    link_zshrc
    if [ "$SHELL" != "$(command -v zsh)" ]; then
        sudo chsh -s "$(command -v zsh)" "$USER" && echo -e "${GREEN}✓ Shell padrão alterado para zsh (efeito no próximo login).${NC}"
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
        _bin=$(command -v "$_cli" 2>/dev/null || echo "$HOME/.bun/bin/$_cli")
        if [ ! -x "$_bin" ]; then
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
    unset _cli _dir _bin _falta
fi

# A mensagem final é por perfil porque o próximo passo mudou de destino: o devpod
# passou a mirar a VM, não o host. Dizer "configure o devpod com este servidor"
# aqui mandaria o Mac ao lugar errado.
if [ "$PROFILE" = "vm" ]; then
    echo -e "\n${GREEN}=== Configuração da VM de agentes finalizada! ===${NC}"
    echo -e "Próximo passo: tire um snapshot desta VM como baseline, e no Mac aponte o"
    echo -e "devpod para ela por provider SSH. Ver ARQUITETURA.md."
else
    echo -e "\n${GREEN}=== Configuração do Fedora Workstation finalizada! ===${NC}"
    echo -e "Próximo passo: crie a VM de agentes no Cockpit e rode './setup.sh --profile=vm' dentro dela."
    echo -e "A rede usada é a default do libvirt; o repo ainda não declara rede, porque a lista de"
    echo -e "serviços que o host vai expor não está escrita. Ver ARQUITETURA.md."
fi

