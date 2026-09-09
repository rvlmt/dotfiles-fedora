# lib-common.sh — funções usadas pelo setup.sh deste repo (servidor Fedora).
# Não é executável sozinho: é carregado via `source` pelo setup.sh.
# Existe uma cópia irmã (levemente diferente em alguns detalhes de OS) no
# repo "dotfiles" (macOS) — mantidas independentes de propósito, ver README.

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

# Uso: validate_steps "$ONLY" "--only" (requer $ALL_STEPS e usage() no escopo do script chamador)
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

# CLIs de IA disponíveis via npm/Bun ou script oficial em ambas as plataformas.
# Antigravity CLI fica de fora daqui por só ter formula Homebrew (módulo separado no macOS).
install_common_ai_clis() {
    export PATH="$HOME/.bun/bin:$(npm config get prefix 2>/dev/null)/bin:$HOME/.local/bin:$PATH"

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
}

# Gera (se não existir) uma chave SSH Ed25519 e garante que o ssh-agent a carregue.
# "--apple-use-keychain" só existe no OpenSSH da Apple; em outros sistemas o comando
# falha e cai no fallback "ssh-add" puro, então esta função funciona sem branch por OS.
generate_ssh_key() {
    local email="$1"
    local ssh_key="$HOME/.ssh/id_ed25519"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [ ! -f "$ssh_key" ]; then
        ssh-keygen -t ed25519 -C "$email" -f "$ssh_key" -N ""
        eval "$(ssh-agent -s)"
        ssh-add --apple-use-keychain "$ssh_key" 2>/dev/null || ssh-add "$ssh_key"
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

# Cria/atualiza o link simbólico ~/.zshrc → <repo>/zshrc. Pede confirmação
# antes de sobrescrever um ~/.zshrc existente (faz backup automático).
link_zshrc() {
    local script_dir="$1"
    local zshrc_src="$script_dir/zshrc"
    local zshrc_dest="$HOME/.zshrc"

    if [ -L "$zshrc_dest" ] && [ "$(readlink "$zshrc_dest")" = "$zshrc_src" ]; then
        echo -e "${GREEN}✓ ~/.zshrc já aponta para este repositório.${NC}"
    elif [ -e "$zshrc_dest" ] || [ -L "$zshrc_dest" ]; then
        # CONFIRM_ZSHRC_OVERWRITE, se já definida (setup-fedora.sh pergunta
        # tudo antecipadamente), evita perguntar de novo aqui no meio do
        # script; se não estiver definida (setup.sh no Mac), pergunta na hora.
        local do_overwrite
        if [ -n "$CONFIRM_ZSHRC_OVERWRITE" ]; then
            [ "$CONFIRM_ZSHRC_OVERWRITE" = "1" ] && do_overwrite=0 || do_overwrite=1
        else
            confirm "Já existe um ~/.zshrc. Substituir por um link para este repositório (o atual será salvo como backup)?"
            do_overwrite=$?
        fi
        if [ "$do_overwrite" = "0" ]; then
            local backup="$zshrc_dest.backup.$(date +%Y%m%d%H%M%S)"
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

    export PATH="$HOME/.bun/bin:$(npm config get prefix 2>/dev/null)/bin:$PATH"

    if command -v ocx &> /dev/null; then
        echo -e "${GREEN}✓ OpenCodex CLI (ocx) instalado com sucesso.${NC}"
        echo -e "Para iniciar o proxy OpenCodex, execute no seu terminal: ${GREEN}ocx start${NC}"
    else
        echo -e "${YELLOW}Aviso: O comando 'ocx' não foi encontrado no PATH.${NC}"
    fi
}
