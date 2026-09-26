# Como reverter as mudanças do setup.sh

Este documento é o **inverso** do `setup.sh`: uma seção por módulo, na mesma ordem
em que `ALL_STEPS` executa, e cada comando desfaz algo que o módulo faz. O que não
é módulo está no [apêndice](#apêndice-o-que-não-é-módulo).

A maioria das seções é segura de reverter isoladamente. Onde há ordem obrigatória,
ela está indicada — e isso importa mais neste documento do que no `setup.sh`,
porque remover o runtime antes das ferramentas deixa as CLIs quebradas.

Módulos cobertos: `base`, `hostname`, `ssh`, `git`, `podman`, `tailscale`,
`sshd-hardening`, `firewalld`, `toolbx`, `gui-access`, `desktop-apps`, `ai-clis`,
`opencodex`, `zshrc`.

## `base` — runtime, ferramentas de linha de comando e pacotes

O módulo faz quatro coisas: `dnf upgrade`, instala as ferramentas de CLI, instala
o Bun por script e instala o runtime do host pelo mise. O `dnf upgrade` **não tem
inverso** — não há downgrade no dnf5.

```bash
# 1. Atalhos e o bloco do shell, antes de apagar o mise que os alimenta.
rm -f ~/.local/bin/devcontainer
# remove só o bloco marcado do mise, preservando o resto do seu ~/.bashrc:
sed -i '/^# >>> mise (runtime do host) >>>$/,/^# <<< mise (runtime do host) <<<$/d' ~/.bashrc

# 2. Runtime do host (Node e Dev Container CLI pinados vinham daqui).
#    A remoção também descarta os pins de ~/.config/mise/config.toml.
rm -rf ~/.local/share/mise ~/.local/bin/mise

# 3. Bun, instalado por script e não pelo dnf.
rm -rf ~/.bun

# 4. Ferramentas de CLI do módulo. curl e wget ficam de fora de propósito:
#    são dependência de praticamente todo o resto.
sudo dnf remove git gh jq tree tmux zellij ripgrep fd-find unzip btop dnf5-plugins
```

Este módulo **não** instala `nodejs`/`npm`: o Node do host vem do mise. Se você
adicionou esses pacotes por outro motivo, eles não são do `setup.sh` e não são
removidos aqui.

## `hostname` — voltar ao nome anterior

O script não guarda o hostname anterior em lugar nenhum — anote o valor mostrado
por "Hostname atual: ..." *antes* de trocar, se achar que vai querer reverter.

```bash
sudo hostnamectl set-hostname <nome-anterior>
```

## `ssh` — chave Ed25519 e entrada do github.com

O módulo gera `~/.ssh/id_ed25519`, carrega no `ssh-agent` e acrescenta um bloco
`Host github.com` em `~/.ssh/config` (só se ainda não existir). O envio da chave ao
GitHub acontece aqui e no módulo `git`.

```bash
# 1. Remover só a entrada que o módulo escreve, preservando o resto do config.
sed -i '/^Host github\.com$/,/^  IdentityFile ~\/\.ssh\/id_ed25519$/d' ~/.ssh/config

# 2. Tirar a chave do GitHub (precisa de `gh` autenticado).
gh ssh-key list        # descubra o id/índice da chave deste host
gh ssh-key delete <id>

# 3. Encerrar a sessão do agente e apagar o par de chaves — irreversível para
#    qualquer coisa que dependa desta chave.
ssh-add -D
rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
```

⚠️ Remover a chave local **não** revoga outros usos dela. Se outro lugar
depender deste par, o passo 3 quebra esse lugar também.

## `git` — identidade global e autenticação do GitHub CLI

O módulo escreve quatro chaves de `git config --global` e faz `gh auth login`,
cujo token fica em `~/.config/gh/hosts.yml`.

```bash
git config --global --unset user.name
git config --global --unset user.email
git config --global --unset init.defaultBranch
git config --global --unset pull.rebase

gh auth logout        # remove o token de ~/.config/gh/hosts.yml
```

A chave SSH adicionada ao GitHub é revertida na seção `ssh`.

## `podman` — desfazer rootless e/ou desinstalar

```bash
sudo loginctl disable-linger "$USER"   # desfaz o "sobrevive ao logout"

# Remover as faixas de subuid/subgid (edite manualmente, dnf/usermod não
# tem um comando direto de remoção):
sudo sed -i "/^$USER:/d" /etc/subuid /etc/subgid

# Reverter userns=keep-id (volta ao padrão do Podman, "host"):
sed -i '/^userns = "keep-id"/d' ~/.config/containers/containers.conf

# Desinstalar de vez (cuidado: containers/imagens locais ficam em
# ~/.local/share/containers — apague à parte se quiser limpar tudo):
sudo dnf remove podman podman-docker slirp4netns fuse-overlayfs
```

Se o `containers.conf` existia só por causa deste módulo, remova o arquivo em vez
de deixar `[containers]` vazio.

## `tailscale` — desconectar ou remover

```bash
sudo tailscale set --ssh=false   # desliga só o Tailscale SSH (não é habilitado por padrão aqui, mas por segurança)
sudo tailscale down              # desconecta da tailnet (reversível com "tailscale up")
```

Remoção completa:

```bash
sudo dnf remove tailscale
sudo rm /etc/yum.repos.d/tailscale.repo
sudo systemctl disable tailscaled
```

⚠️ Sem Tailscale (e com `sshd-hardening` aplicado), o único jeito de entrar
neste servidor é uma chave já cadastrada em `~/.ssh/authorized_keys` — via
rede local ou acesso físico. Confirme outro caminho de acesso antes de
desconectar a tailnet remotamente.

## `sshd-hardening` — reabilitar login por senha/root via SSH

```bash
sudo rm /etc/ssh/sshd_config.d/99-dotfiles-hardening.conf
sudo systemctl reload sshd
```

## `firewalld` — tirar a interface Tailscale da zona confiável

```bash
sudo firewall-cmd --zone=trusted --remove-interface=tailscale0 --permanent
sudo firewall-cmd --reload
```

Pra desligar o firewalld por completo (não recomendado, ele que garante que só
o Tailscale alcança a máquina): `sudo systemctl disable --now firewalld`.

## `toolbx` — desinstalar

```bash
sudo dnf remove toolbox
```

## `gui-access` — desligar o GNOME Remote Desktop

Pela GUI: **Configurações → Compartilhamento → Área de Trabalho Remota** →
desliga o toggle.

Ou via terminal: `grdctl rdp disable`.

## `desktop-apps` — desinstalar os apps

```bash
sudo dnf remove code google-chrome-stable brave-browser transmission-gtk opencode-desktop
sudo rm -f /etc/yum.repos.d/vscode.repo /etc/yum.repos.d/brave-browser.repo /etc/yum.repos.d/antigravity.repo
rm -f ~/.local/bin/cursor ~/.local/bin/cursor.AppImage
rm -rf ~/.zed  # zed instalado via script oficial, não dnf
sudo dnf remove antigravity
```

## `ai-clis` — as CLIs de agente e o daemon do agy

O módulo instala as quatro CLIs de npm **pelo Bun** (`bun add -g`, com fallback
para npm), e por instalador nativo o Cursor Agent, o OpenCode e o `agy`. O
instalador do `agy` ainda deixa uma unit de usuário que precisa ser parada antes
dos binários sumirem.

```bash
# 1. Parar e remover as units de agente. Sem isso o daemon do agy continua
#    ativo tentando reexecutar.
systemctl --user disable --now antigravity-cli-daemon.service 2>/dev/null
systemctl --user disable --now opencode.service 2>/dev/null
rm -f ~/.config/systemd/user/antigravity-cli-daemon.service \
      ~/.config/systemd/user/opencode.service
rm -rf ~/.config/systemd/user/antigravity-cli-daemon.service.d
systemctl --user daemon-reload

# 2. CLIs de npm: remover pelo Bun quando o pacote estiver no escopo global do
#    Bun; senão ele veio do npm e o comando correto é o outro.
for pkg in @anthropic-ai/claude-code @openai/codex @google/gemini-cli \
           @github/copilot; do
  if [ -d "$HOME/.bun/install/global/node_modules/$pkg" ]; then
    bun remove -g "$pkg"
  else
    npm uninstall -g "$pkg"
  fi
done

# 3. Instaladores nativos (binários próprios, fora do ecossistema npm).
rm -f ~/.local/bin/agy ~/.local/bin/agent ~/.local/bin/cursor-agent
rm -rf ~/.opencode ~/.cursor-agent
```

O módulo também declara a escuta do servidor do OpenCode por drop-in e a
publicação na tailnet, então as duas fazem parte do rollback:

```bash
# Tira a publicação (o servidor deixa de ser alcançável de fora).
sudo tailscale serve reset

# Devolve a unit ao estado que o instalador deixou.
rm -rf ~/.config/systemd/user/opencode.service.d
systemctl --user daemon-reload
```

⚠️ `tailscale serve reset` apaga **toda** a config de publicação do nó, não só a
do OpenCode. Se houver outro serviço publicado, remova o dele com
`tailscale serve clear` em vez de reset. Com o drop-in removido, o servidor volta
a escutar no endereço que o instalador deixou. Remover a unit inteira
(`rm ~/.config/systemd/user/opencode.service`) também a apaga do estado do
usuário e precisa de `disable` antes.

A senha **não** faz parte do rollback: ela vive em
`~/.config/opencode/service.json` e é mantida de propósito, porque sem
`--service` o servidor geraria uma senha aleatória a cada start. Para trocá-la,
`opencode service set password <senha>` seguido de restart.

`claude` e `cursor-agent` não dependem de Node, mas `codex`, `gemini`, `copilot` e
`ocx` resolvem `#!/usr/bin/env node` — por isso remova estas últimas **antes** do
Bun e do mise (seção `base`). Os symlinks em `~/.bun/bin` são recriados pelo Bun a
partir de `~/.bun/install/global/node_modules`; remover os pacotes basta.

## `opencodex` — o router OpenCodex

Instalado à parte do `ai-clis`, com o mesmo dono (Bun ou npm):

```bash
if [ -d "$HOME/.bun/install/global/node_modules/@bitkyc08/opencodex" ]; then
  bun remove -g @bitkyc08/opencodex
else
  npm uninstall -g @bitkyc08/opencodex
fi
```

Os dois symlinks `ocx` e `opencodex` em `~/.bun/bin` apontam para o mesmo pacote e
somem junto.

## `zshrc` — desfazer o link e voltar ao bash

O zsh é o shell de login padrão do host e o `zshrc` versionado é o dono do PATH
interativo (mise, Bun, `~/.local/bin`, `~/.opencode/bin`). Desfazer isto deixa o
shell de login sem essas entradas.

```bash
# 1. Voltar o shell de login. Só tem efeito no próximo login.
sudo chsh -s /bin/bash "$USER"

# 2. Remover o link simbólico (o arquivo no repositório não é afetado).
rm ~/.zshrc

# Se existir um backup (~/.zshrc.backup.AAAAMMDDHHMMSS, criado quando já havia
# um .zshrc antes de rodar o módulo), restaure-o em vez de simplesmente remover:
# mv ~/.zshrc.backup.AAAAMMDDHHMMSS ~/.zshrc

# 3. Remover o zsh e os plugins (opcional — zsh é útil fora deste repo).
sudo dnf remove zsh zsh-autosuggestions zsh-syntax-highlighting
```

Depois disso, o mise continua instalado, mas nenhum shell o coloca no PATH: o bloco
marcado em `~/.bashrc` (seção `base`) e o do `zshrc` versionado saem juntos.

# Referência

## Autorizar/revogar dispositivos que entram via SSH

Ver [README.md](README.md#como-rodar-num-fedora-novo-ou-recém-formatado),
passo 2 — cada dispositivo tem sua própria linha em `~/.ssh/authorized_keys`.
Pra revogar um dispositivo perdido/comprometido, remova só a linha dele:

```bash
nano ~/.ssh/authorized_keys   # ou o editor de sua preferência — apague a linha do dispositivo
```

## Chave SSH deste servidor e conta GitHub

Não é revertido automaticamente — se algum dia quiser invalidar a chave que
este servidor usa pra se autenticar no GitHub:

1. GitHub → Settings → SSH and GPG keys → remove a chave pelo título
   (hostname da máquina que você usou no cadastro).
2. Localmente: `rm ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub`.

Isso não afeta as outras máquinas (cada uma tem sua própria chave
independente).

# Apêndice: o que não é módulo

Estas seções não correspondem a nenhum módulo do `setup.sh` — são configuracões
manuais descritas no README, ou histórico. Ficam aqui para não interromper o
espelho dos módulos.

### `autologin` (configuração manual) — desabilitar login automático do GDM

Mais simples, pela GUI: **Configurações → Usuários** → clique no seu usuário
→ desliga o toggle "Login Automático".

Ou via terminal (caso tenha configurado manualmente):
```bash
sudo sed -i '/^AutomaticLoginEnable=/d; /^AutomaticLogin=/d' /etc/gdm/custom.conf
```

Efeito só depois do próximo reboot/logout.

### `power-management` (configuração manual) — voltar a suspender/bloquear por ociosidade

A parte do **dconf** já é revertível direto pela GUI (**Configurações →
Energia**) — o que escrevemos é só um default, sem lock, então qualquer
mudança sua ali tem prioridade. Pra remover o default do sistema também:

```bash
sudo rm /etc/dconf/db/local.d/00-power-management
sudo dconf update
```

A parte do **systemd-logind** (mais forte, não aparece na GUI) precisa de
`unmask` explícito — sem isso, suspender continua falhando mesmo com a opção
ligada em Configurações → Energia:

```bash
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### `reboot-timer` (configuração manual) — cancelar o reboot semanal agendado

```bash
sudo systemctl disable --now scheduled-reboot.timer
sudo rm /etc/systemd/system/scheduled-reboot.timer /etc/systemd/system/scheduled-reboot.service
sudo systemctl daemon-reload
```

### Docker CE / OpenHands — removidos (histórico, não são mais módulos deste repo)

O experimento de instalar Docker CE de verdade só pra rodar o OpenHands foi
abandonado (ver histórico do git do repo `dotfiles` original se quiser os
detalhes). Se sua máquina ainda tem esses componentes de uma execução
anterior, para desfazer e voltar 100% a Podman:

```bash
sudo systemctl disable --now docker
sudo dnf remove -y --setopt=clean_requirements_on_remove=false docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo dnf install -y podman podman-docker slirp4netns fuse-overlayfs   # garante podman de volta + devolve o shim docker→podman

# No Mac, desfaz o pin do devpod pro Podman explícito, se você chegou a fazer:
devpod provider set-options ssh DOCKER_PATH=/usr/bin/docker
```

⚠️ Use `--setopt=clean_requirements_on_remove=false` no `dnf remove` acima
— sem isso o dnf trata dependências como órfãs e pode remover pacotes que
você quer manter (foi exatamente o que aconteceu ao remover `podman-docker`
sem essa flag: o `podman` foi junto).

```bash
uv tool uninstall openhands   # se o OpenHands foi instalado
rm -rf ~/.openhands           # dados/config locais do OpenHands, se não quiser manter
```
