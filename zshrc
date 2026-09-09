# ==============================================================================
# 🚀 PATHS & RUNTIMES (Apple Silicon & ferramentas locais)
# ==============================================================================
# Homebrew
if [[ -f "/opt/homebrew/bin/brew" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Bun & Node Globals
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

# Open Code (sst/opencode) instala o binário fora do PATH padrão
[ -d "$HOME/.opencode/bin" ] && export PATH="$HOME/.opencode/bin:$PATH"

# Preferência de editor padrão
# Requer o comando "code" no PATH (VS Code > Cmd+Shift+P > "Shell Command: Install 'code' command in PATH")
# Sem "code" no PATH (ex: Fedora sem VS Code local), cai pro vim.
if command -v code &> /dev/null; then
  export EDITOR="code --wait"
  export VISUAL="code --wait"
else
  export EDITOR="vim"
  export VISUAL="vim"
fi

# ==============================================================================
# ⚡ HISTÓRICO & PERFORMANCE
# ==============================================================================
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

setopt EXTENDED_HISTORY          # Grava timestamp dos comandos
setopt SHARE_HISTORY             # Compartilha histórico entre abas ativas
setopt HIST_EXPIRE_DUPS_FIRST    # Remove duplicatas mais antigas quando cheio
setopt HIST_IGNORE_DUPS          # Ignora comandos idênticos consecutivos
setopt HIST_IGNORE_SPACE         # Não grava comandos que iniciam com espaço
setopt HIST_VERIFY               # Permite revisar histórico expandido antes de rodar

# Autocomplete nativo com cache rápido
# Reaproveita o cache (~/.zcompdump) se ele tiver menos de 24h; caso contrário, regenera.
# "stat -f %m" é BSD/macOS; "stat -c %Y" é GNU/Linux — tenta os dois.
autoload -Uz compinit
ZCOMPDUMP="$HOME/.zcompdump"
ZCOMPDUMP_MTIME=$(stat -f %m "$ZCOMPDUMP" 2>/dev/null || stat -c %Y "$ZCOMPDUMP" 2>/dev/null)
if [[ -f "$ZCOMPDUMP" && -n "$ZCOMPDUMP_MTIME" && $(($(date +%s) - ZCOMPDUMP_MTIME)) -lt 86400 ]]; then
  compinit -C
else
  compinit
fi
unset ZCOMPDUMP ZCOMPDUMP_MTIME

# ==============================================================================
# 🐙 GIT ALIASES
# ==============================================================================
alias g="git"
alias gs="git status -sb"
alias ga="git add"
alias gaa="git add --all"
alias gc="git commit -m"
alias gca="git commit --amend --no-edit"
alias gco="git checkout"
alias gcb="git checkout -b"
alias gb="git branch"
alias gbd="git branch -d"
alias gbD="git branch -D"
alias gl="git pull --prune"
alias gp="git push"
alias gpf="git push --force-with-lease"
alias gd="git diff"
alias gds="git diff --staged"
alias glog="git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
alias gundo="git reset --soft HEAD~1"

# ==============================================================================
# 🐳 DOCKER & ORBSTACK
# ==============================================================================
alias d="docker"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
alias dpsa="docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
alias dc="docker compose"
alias dcu="docker compose up -d"
alias dcd="docker compose down"
alias dcr="docker compose restart"
alias dcl="docker compose logs -f"
alias dclt="docker compose logs -f --tail=100"
alias dex="docker exec -it"
alias dprune="docker system prune -af --volumes"

# Comandos dedicados do OrbStack
alias orb-stop="orb stop"
alias orb-start="orb start"
alias orb-restart="orb restart"

# ==============================================================================
# 📦 RUNTIMES & FERRAMENTAS DEV (Bun, Node, OpenCodex)
# ==============================================================================
# Bun
alias b="bun"
alias bx="bunx"
alias bi="bun install"
alias bd="bun run dev"
alias bb="bun run build"
alias bt="bun test"

# OpenCodex
alias ocxs="ocx start"

# Atalhos de abertura de pastas em IDEs
alias c.="cursor ."
alias v.="code ."
alias z.="zed ."

# ==============================================================================
# 🛠️ UTILITÁRIOS & ATALHOS (macOS & Linux)
# ==============================================================================
# Navegação rápida
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias dev="cd ~/Developer"

# Recarregar configurações do Shell
alias reload="source ~/.zshrc && echo 'Configurações recarregadas!'"

# Ver portas em escuta no sistema
alias ports="lsof -iTCP -sTCP:LISTEN -P -n"

if [[ "$(uname -s)" == "Darwin" ]]; then
  # Limpeza de DNS local no macOS
  alias flushdns="sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder && echo 'DNS Cache limpo!'"
  # Obter IP local e externo
  alias myip="echo 'Local: ' \$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1) && echo 'Externo:' \$(curl -s --max-time 3 ifconfig.me || echo 'indisponível')"
  # Listagem rápida com cores (flag de cor do BSD ls)
  alias ls="ls -G"
  alias ll="ls -lahG"
else
  # Limpeza de DNS local no Linux (systemd-resolved, padrão no Fedora)
  alias flushdns="sudo resolvectl flush-caches && echo 'DNS Cache limpo!'"
  # Obter IP local e externo
  alias myip="echo 'Local: ' \$(hostname -I 2>/dev/null | awk '{print \$1}') && echo 'Externo:' \$(curl -s --max-time 3 ifconfig.me || echo 'indisponível')"
  # Listagem rápida com cores (flag de cor do GNU ls)
  alias ls="ls --color=auto"
  alias ll="ls -lah --color=auto"
fi

# ==============================================================================
# ✨ SUGESTÕES & SYNTAX HIGHLIGHTING
# (zsh-syntax-highlighting precisa ser a ÚLTIMA coisa carregada no arquivo)
# Homebrew usa $HOMEBREW_PREFIX; dnf no Fedora instala em /usr/share — tenta os dois.
# ==============================================================================
for _zsh_plugin_dir in \
  "$HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
  "/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"; do
  [ -f "$_zsh_plugin_dir" ] && source "$_zsh_plugin_dir" && break
done

for _zsh_plugin_dir in \
  "$HOMEBREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
  "/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"; do
  [ -f "$_zsh_plugin_dir" ] && source "$_zsh_plugin_dir" && break
done
unset _zsh_plugin_dir
