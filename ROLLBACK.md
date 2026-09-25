# Como reverter as mudanças do setup.sh

Cada seção abaixo corresponde a um módulo do script e mostra como desfazer
especificamente o que ele mudou. A maioria é segura de reverter isoladamente
(não depende de desfazer outra coisa antes), exceto onde indicado.

### `sshd-hardening` — reabilitar login por senha/root via SSH

```bash
sudo rm /etc/ssh/sshd_config.d/99-dotfiles-hardening.conf
sudo systemctl reload sshd
```

### `firewalld` — tirar a interface Tailscale da zona confiável

```bash
sudo firewall-cmd --zone=trusted --remove-interface=tailscale0 --permanent
sudo firewall-cmd --reload
```

Pra desligar o firewalld por completo (não recomendado, ele que garante que só
o Tailscale alcança a máquina): `sudo systemctl disable --now firewalld`.

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

### `gui-access` — desligar o GNOME Remote Desktop

Pela GUI: **Configurações → Compartilhamento → Área de Trabalho Remota** →
desliga o toggle.

Ou via terminal: `grdctl rdp disable`.

### `zshrc` — desfazer o link e voltar pro shell padrão

```bash
rm ~/.zshrc                          # remove o link simbólico
chsh -s /bin/bash "$USER"            # ou /bin/zsh sem o link, se preferir manter zsh
```

Se existir um backup (`~/.zshrc.backup.AAAAMMDDHHMMSS`, criado quando já
havia um `.zshrc` antes de rodar o módulo), restaure-o em vez de simplesmente
remover: `mv ~/.zshrc.backup.AAAAMMDDHHMMSS ~/.zshrc`.

### `tailscale` — desconectar ou remover

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

### `podman` — desfazer rootless e/ou desinstalar

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

### `hostname` — voltar ao nome anterior

O script não guarda o hostname anterior em lugar nenhum — anote o valor
mostrado por "Hostname atual: ..." *antes* de trocar, se achar que vai
querer reverter depois. Pra aplicar um novo valor:

```bash
sudo hostnamectl set-hostname <nome-anterior>
```

### `desktop-apps` — desinstalar os apps

```bash
sudo dnf remove code google-chrome-stable brave-browser transmission-gtk opencode-desktop
sudo rm -f /etc/yum.repos.d/vscode.repo /etc/yum.repos.d/brave-browser.repo /etc/yum.repos.d/antigravity.repo
rm -f ~/.local/bin/cursor ~/.local/bin/cursor.AppImage
rm -rf ~/.zed  # zed instalado via script oficial, não dnf
sudo dnf remove antigravity
```

### `ai-clis` / `opencodex` — desinstalar as CLIs

```bash
npm uninstall -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli @github/copilot @bitkyc08/opencodex
rm -f ~/.local/bin/agy ~/.local/bin/cursor-agent
rm -rf ~/.opencode
```

### `base` — pacotes instalados (geralmente inofensivo deixar)

```bash
sudo dnf remove git gh jq tree tmux zellij ripgrep fd-find unzip btop
# bun e mise foram instalados via script próprio, não pelo dnf:
rm -rf ~/.bun ~/.local/bin/mise ~/.local/share/mise
```

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
