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

# Runtime do host, pinado aqui para que setup, shell de login e devcontainers
# concordem. Quem fornece Node/npm no host é o mise — o pacote nodejs do dnf
# não é instalado de propósito, para que o runtime do host não dependa da
# versão que o Fedora decidir empacotar. Ver README, "Runtime Node no host".
MISE_NODE_VERSION="22.23.3"
MISE_DEVCONTAINER_VERSION="0.89.0"
MISE_BIN_PATH="$HOME/.local/bin/mise"
MISE_SHIMS_PATH="$HOME/.local/share/mise/shims"

# Endereço e porta do servidor do OpenCode no host, declarados aqui para que um
# host novo reproduza o mesmo estado — o instalador do opencode cria a unit sem
# consultar estas escolhas.
#
# `0.0.0.0` escuta em todas as interfaces, e isso inclui a interface WiFi local,
# não só a tailnet. O acesso remoto que motiva isto é pela tailnet, mas o
# servidor também fica alcançável por qualquer máquina da mesma rede WiFi, e o
# que separa esse acesso é a credencial de pareamento do OpenCode. É uma escolha
# consciente, não um default esquecido: se a exposição deixar de ser aceitável,
# o caminho é apontar `OPENCODE_BIND` para o IP do Tailscale ou passar a expor
# por `tailscale serve`.
OPENCODE_BIND="0.0.0.0"
OPENCODE_PORT="49374"

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

# O instalador do opencode cria a unit opencode.service. Ela é estado de host
# sem dono no padrão: um `setup.sh` em um host novo não reproduziria o ajuste de
# escuta, e o servidor voltaria a ficar em loopback. Por isso a escuta é
# declarada aqui, por drop-in: sobrevive a uma reescrita do instalador e não
# encosta nas outras diretivas que ele define (PATH, Restart, TimeoutStopSec).
# Só o valor de `--hostname` e de `--port` é reescrito, o resto das flags fica.
setup_opencode_service() {
    local unit="$HOME/.config/systemd/user/opencode.service"
    local dropin_dir="$HOME/.config/systemd/user/opencode.service.d"
    local dropin="$dropin_dir/10-bind.conf"
    if [ ! -f "$unit" ]; then
        return 0
    fi

    local exec_line
    exec_line="$(sed -nE 's/^ExecStart=(.*)$/\1/p' "$unit" | head -1)"
    if [ -z "$exec_line" ]; then
        echo -e "${YELLOW}Não li o ExecStart de $unit; pulei o drop-in do OpenCode.${NC}" >&2
        return 1
    fi

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
# Gerado por dotfiles-fedora (setup.sh): declara o endereco de escuta do servidor
# do OpenCode, que o instalador deixa em loopback. Drop-in em vez de edicao da
# unit para sobreviver a uma reescrita do instalador.
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
    echo -e "${YELLOW}  $OPENCODE_BIND inclui a interface WiFi, nao so a tailnet — veja OPENCODE_BIND no setup.sh.${NC}"
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
    install_npm_global "@google/gemini-cli" "gemini"
    install_npm_global "@github/copilot" "copilot"

    if command -v cursor-agent &> /dev/null; then
        echo -e "${YELLOW}cursor-agent já instalado, pulando.${NC}"
    else
        curl https://cursor.com/install -fsS | bash
        echo -e "${GREEN}✓ Cursor Agent CLI instalado.${NC}"
    fi

    if command -v opencode &> /dev/null; then
        echo -e "${YELLOW}opencode já instalado, pulando.${NC}"
    else
        curl -fsSL https://opencode.ai/install | bash
        echo -e "${GREEN}✓ Open Code (sst/opencode) instalado.${NC}"
    fi

    if command -v agy &> /dev/null; then
        echo -e "${YELLOW}agy (Antigravity CLI) já instalado, pulando.${NC}"
    else
        curl -fsSL https://antigravity.google/cli/install.sh | bash
        echo -e "${GREEN}✓ Antigravity CLI (agy) instalado.${NC}"
    fi

    # O daemon do agy roda "npm exec" fora de shell interativo, então precisa do
    # PATH do mise explicitado no serviço. Ver setup_agy_service_path.
    setup_agy_service_path

    # A unit do opencode é criada pelo instalador sem consultar o padrão, então a
    # escuta é declarada aqui. Ver setup_opencode_service.
    setup_opencode_service
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

# Módulos disponíveis, na ordem em que rodam.
ALL_STEPS="base hostname ssh git podman tailscale sshd-hardening firewalld toolbx gui-access desktop-apps ai-clis opencodex zshrc"

usage() {
    cat <<EOF
Uso: ./setup.sh [--only=modulo1,modulo2] [--skip=modulo1,modulo2]

Módulos disponíveis: ${ALL_STEPS// /, }

  --only=podman,tailscale   Roda apenas os módulos listados.
  --skip=gui-access          Roda tudo, exceto os módulos listados.
  -h, --help                  Mostra esta ajuda.

Sem argumentos, roda todos os módulos exceto os opcionais (toolbx, gui-access).
Use --only para rodá-los explicitamente.
EOF
}

ONLY=""
SKIP=""
for arg in "$@"; do
    case "$arg" in
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

validate_steps() {
    local list="$1" label="$2" step
    [ -z "$list" ] && return
    for step in ${list//,/ }; do
        if [[ " $ALL_STEPS " != *" $step "* ]]; then
            echo "Módulo desconhecido em $label: '$step'" >&2
            usage
            exit 1
        fi
    done
}
validate_steps "$ONLY" "--only"
validate_steps "$SKIP" "--skip"

should_run() {
    local step="$1"
    if [ -n "$ONLY" ]; then
        [[ ",$ONLY," == *",$step,"* ]]
        return $?
    fi
    if [ -n "$SKIP" ]; then
        [[ ",$SKIP," == *",$step,"* ]] && return 1
    fi
    return 0
}

# toolbx e gui-access são opcionais: só rodam se pedidos explicitamente via
# --only, a menos que o usuário já tenha especificado um --skip próprio.
# ai-clis participa da execução normal e pergunta antes de agir (confirm()).
# zshrc também participa da execução normal e não pergunta: o zsh é o shell de
# login padrão do host. A única confirmação é sobre substituir um ~/.zshrc que
# já exista e não seja o link deste repositório.
if [ -z "$ONLY" ] && [ -z "$SKIP" ]; then
    SKIP="toolbx,gui-access"
fi

echo -e "${BLUE}=== Setup do Servidor Fedora (host de execução dos coding agents) ===${NC}\n"

if should_run "git" || should_run "ssh"; then
    prompt_git_identity
fi

# ==============================================================================
# Confirmações antecipadas — tudo que pede "y/N" é perguntado aqui, no
# começo, pra você poder sair de perto do terminal depois e o script rodar
# até o fim sem parar no meio esperando resposta.
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

CONFIRM_AI_CLIS=""
if should_run "ai-clis"; then
    confirm "Instalar as CLIs de IA (Claude Code, Codex, Gemini, etc.) também diretamente no host Fedora? (opcional, já rodam nos devcontainers)" && CONFIRM_AI_CLIS=1
fi

CONFIRM_ZSHRC_OVERWRITE=0
if { [ -e "$HOME/.zshrc" ] || [ -L "$HOME/.zshrc" ]; } \
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
    sudo dnf install -y --skip-unavailable \
        git gh jq tree tmux zellij ripgrep fd-find unzip \
        curl wget btop \
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
    sudo dnf install -y --skip-unavailable podman podman-docker slirp4netns fuse-overlayfs

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
# Tailscale (rede segura entre o Mac e este servidor, sem exposição pública)
# ==============================================================================
if should_run "tailscale"; then
    echo -e "\n${BLUE}==> Tailscale${NC}"
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
# CLIs de IA (opcional no host — rodarão principalmente dentro dos devcontainers)
# ==============================================================================
if should_run "ai-clis"; then
    echo -e "\n${BLUE}==> CLIs de IA${NC}"
    if [ "$CONFIRM_AI_CLIS" = "1" ]; then
        install_common_ai_clis
    else
        echo -e "${YELLOW}Instalação de CLIs de IA no host ignorada (rodarão dentro dos devcontainers).${NC}"
    fi
fi

# ==============================================================================
# OpenCodex CLI (@bitkyc08/opencodex) — router para modelos de IA
# ==============================================================================
if should_run "opencodex"; then
    echo -e "\n${BLUE}==> OpenCodex${NC}"
    install_opencodex
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

echo -e "\n${GREEN}=== Configuração do servidor finalizada! ===${NC}"
echo -e "Próximo passo no Mac: configure o devpod com este servidor como provider SSH via Tailscale."

