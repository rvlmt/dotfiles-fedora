# Como reverter as mudanças do setup.sh

Este documento é o **inverso** do `setup.sh`: uma seção por módulo, na mesma ordem
em que `ALL_STEPS` executa, e cada comando desfaz algo que o módulo faz. O que não
é módulo está no [apêndice](#apêndice-o-que-não-é-módulo).

A maioria das seções é segura de reverter isoladamente. Onde há ordem obrigatória,
ela está indicada — e isso importa mais neste documento do que no `setup.sh`,
porque remover o runtime antes das ferramentas deixa as CLIs quebradas.

  Módulos cobertos: `base`, `hostname`, `ssh`, `git`, `podman`, `gh-app`, `tailscale`,
  `sshd-hardening`, `firewalld`, `vm-host`, `toolbx`, `gui-access`, `desktop-apps`,
  `ai-clis`, `opencodex`, `zshrc`.

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
sudo dnf remove git gh jq tree tmux zellij ripgrep fd-find unzip btop tar openssl dnf5-plugins
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

## `device-keys` — devolver o `authorized_keys` ao estado anterior

O módulo reescreve **só** o bloco entre os delimitadores
`# >>> dotfiles-fedora: chaves de dispositivos (GitHub) >>>` e
`# <<< … <<<`. Tudo fora do bloco nunca foi tocado e não precisa de rollback.

**Antes de apagar, confira o que existe.** Um chave fora do bloco não pertence a
este módulo — removê-la junto seria trocar o estado da máquina por outro, e não
desfazer o que o módulo fez.

```bash
# 1. Ver o arquivo como ele está, com os blocos destacados.
grep -nE '^(#|ssh-|ecdsa-|sk-)' ~/.ssh/authorized_keys

# 2. Guardar uma cópia antes de mexer.
cp -a ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak

# 3. Remover o bloco gerenciado e as chaves que ele trazia.
#    O awk abaixo apaga do BEGIN ao END inclusive; o resto da linha a linha
#    sobrevive intacto, na ordem original.
BEGIN='# >>> dotfiles-fedora: chaves de dispositivos (GitHub) >>>'
END='# <<< dotfiles-fedora: chaves de dispositivos (GitHub) <<<'
awk -v b="$BEGIN" -v e="$END" '
  $0 == b { dentro = 1; next }
  dentro   { if ($0 == e) dentro = 0; next }
  { print }
' ~/.ssh/authorized_keys > /tmp/ak.novo &&
  cat /tmp/ak.novo > ~/.ssh/authorized_keys && rm -f /tmp/ak.novo

chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
restorecon ~/.ssh/authorized_keys

# 4. Conferir o resultado.
ssh-keygen -lf ~/.ssh/authorized_keys
```

⚠️ **Desfazer isto revoga o acesso, não o concede.** Depois do passo acima a
máquina só aceita as chaves que restaram fora do bloco. **Não feche a sessão de
onde você está executando** antes de abrir outra e confirmar que ela entra — é a
mesma armadilha do resto do hardening, e a saída já causa mais lockouts do que
falha de configuração.

E se o `authorized_keys.bak` não tiver o que esperava, resta o caminho de sempre:
`sudo virsh console <vm>`, que não depende de SSH.

**Repor o bloco do jeito do módulo**, em vez de apagar, é rodar o passo de novo
com uma resposta afirmativa na pergunta. Ele é idempotente: mesmo feed, arquivo
inalterado.

## `git` — identidade global e autenticação do GitHub CLI

O módulo escreve quatro chaves de `git config --global` e faz `gh auth login`,
cujo token fica em `~/.config/gh/hosts.yml`.

```bash
git config --global --unset user.name
git config --global --unset user.email
git config --global --unset init.defaultBranch
git config --global --unset pull.rebase

gh auth logout        # remove o token de ~/.config/gh/hosts.yml; só se o login de pessoa foi feito
```

A chave SSH adicionada ao GitHub é revertida na seção `ssh`.

## `podman` — desfazer rootless e/ou desinstalar

```bash
sudo loginctl disable-linger "$USER"   # desfaz o "sobrevive ao logout"

# O módulo desabilita o podman.socket, que já vem desabilitado por padrão no
# Fedora. O inverso de "desabilitar" seria "habilitar", e é exatamente o que
# este rollback NÃO faz: devolver ao estado anterior significa deixar como está.
# Só habilite se você quiser a API do engine exposta:
# sudo systemctl enable podman.socket

# Remover as faixas de subuid/subgid (edite manualmente, dnf/usermod não
# tem um comando direto de remoção):
sudo sed -i "/^$USER:/d" /etc/subuid /etc/subgid

# Reverter userns=keep-id (volta ao padrão do Podman, "host"):
sed -i '/^userns = "keep-id"/d' ~/.config/containers/containers.conf

# Desinstalar de vez (cuidado: containers/imagens locais ficam em
# ~/.local/share/containers — apague à parte se quiser limpar tudo):
sudo dnf remove podman slirp4netns fuse-overlayfs
```

Se o `containers.conf` existia só por causa deste módulo, remova o arquivo em vez
de deixar `[containers]` vazio.

## `gh-app` — desfazer a identidade da máquina no GitHub

O módulo grava duas coisas: a private key e o App ID, ambos em
`~/.config/gh-app/` com permissão `600`. Nenhum dos dois entra no repositório, e
é por isso que esta seção não tem nenhum comando para desfazer algo versionado —
não há nada versionado para desfazer.

```bash
# 1. Apagar a private key e o App ID, na ordem: a chave primeiro, porque um App ID
#    sem chave é só um número, e uma chave sem App ID é segredo sem dono.
shred -u ~/.config/gh-app/private-key.pem 2>/dev/null || rm -f ~/.config/gh-app/private-key.pem
rm -f ~/.config/gh-app/app-id
rmdir ~/.config/gh-app 2>/dev/null

# 2. Tirar os dois executáveis.
rm -f ~/.local/bin/gh-app-token ~/.local/bin/gh-app

# 3. O cache do token, se o wrapper chegou a ser usado. Vai sozinho com a
#    expiração de uma hora, então apagar é opcional — mas é o único lugar onde um
#    token de verdade chegou a existir em disco.
rm -rf ~/.cache/gh-app
```

A App em si **não** é removida: ela vive no GitHub, e o que este rollback desfaz
é a cópia local da credencial. Para revogar do lado do GitHub, é_SETTINGS →
_Developer settings → GitHub Apps_, e é decisão sua, porque afeta outras máquinas
se a App estiver instalada em mais de uma.

### O OpenDesign está em modo NATIVO — desfazer é desfazer a unit

O que está instalado nesta VM é o modo **nativo**: a unit `open-design.service`
com a raiz em `~/Developer/open-design-native-root/`. Medido no provisionamento:
**0 containers, 0 imagens, 0 volumes** — o modo container nunca chegou a ser o
estado instalado, ele é o módulo alternativo `open-design-container` que o
`setup.sh` ainda oferece.

Por isso o rollback do container que ficava aqui era, na prática, a sequência de
limpeza de um estado inexistente. O que desfaz o que existe:

```bash
# 1. guardar o token ANTES do passo 3 — a .env e a unica copia dele
cp ~/Developer/open-design-native-root/.env ~/.od.env.keep
chmod 600 ~/.od.env.keep

# 2. derrubar e desabilitar
systemctl --user disable --now open-design.service

# 3. remover a raiz do build
rm -rf ~/Developer/open-design-native-root
```

O passo 1 importa pelo mesmo motivo de sempre: a `.env` guarda o `OD_API_TOKEN`,
e o token **não tem rotação pela doc** — o caminho é gerar outro com
`openssl rand -hex 32` e reiniciar. Perdido, o daemon seguinte gera outro e o que
estava salvo deixa de valer.

⚠️ **A raiz do build é estado, mas é estado regenerável.** Ela é `pnpm install` +
`pnpm build` do repo `~/Developer/open-design`; apagar não perde trabalho, só
tempo de reconstrução. O que **não** é regenerável é o token do passo 1.

**A pasta `open-design-native-root` é um nome provisório.** Ela existe para não
colidir com o clone do repo em `~/Developer/open-design`, que a doc e os exemplos
do próprio OpenDesign esperam. A intenção registrada é que a **próxima**
instalação use só `~/Developer/open-design` e não crie a raiz paralela — mas
mudar agora exigiria mover a raiz e reapontar a unit, e a troca é reversível
com o caminho de volta em cima. **Não foi feito nesta VM**, e o nome atual
funciona; o que fica é o registro, para a próxima.

### O modo CONTAINER, para quem tiver instalado por ele

Válido só se a unit `open-design-container.service` existir. Ela é o outro modo
do mesmo módulo, não um serviço extra.

```bash
podman ps -a --filter name=open-design --format 'table {{.Names}}\t{{.Status}}'
podman volume ls | grep open-design
```

⚠️ **Parar antes de apagar o volume.** Ele é o estado do daemon — projetos,
skills, histórico. `podman volume rm` é o passo que perde trabalho, e ele é
independente de parar o container.

```bash
systemctl --user disable --now open-design-container.service
rm -rf ~/open-design
podman volume rm open-design_open_design_data    # o passo que perde trabalho
podman rmi ghcr.io/nexu-io/od:latest             # 1,28 GB, se o disco importa
```


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

A publicação pela tailnet é do módulo `tailscale`, não deste — ver a seção dele.
Aviso: `tailscale serve reset` **apaga tudo** que estiver publicado, então não é
o inverso apenas deste passo se houver mais de um serviço.

Destravar a senha do root, que o mesmo módulo aplica. É reversível, mas só
funciona se você souber a senha: `passwd -l` não a guarda em lugar nenhum, e o
`root` da instalação continua sendo `1234` numa VM recém-criada. Se a senha já
não é essa, destravar deixa o root com uma senha que você não escolheu.

```bash
passwd -S root            # o segundo campo: L = travada, P = com senha
sudo passwd -u root
```

Só faça isto com acesso por console — `sudo virsh console <vm>` — ou por outro
caminho já aberto. Destravar o root não é o que te tranca para fora; ficar sem
saber a senha dele, sim.

## `firewalld` — tirar a interface Tailscale da zona confiável

```bash
sudo firewall-cmd --zone=trusted --remove-interface=tailscale0 --permanent
sudo firewall-cmd --reload
```

Pra desligar o firewalld por completo (não recomendado, ele que garante que só
o Tailscale alcança a máquina): `sudo systemctl disable --now firewalld`.

## `vm-host` — remover o hospedeiro de VMs

```bash
# 1. Tirar o socket do Cockpit antes dos pacotes, senão o cockpit.socket
#    continua ativo apontando para um daemon que saiu.
sudo systemctl disable --now cockpit.socket


# 2. Retirar o usuário do grupo libvirt. Vale no próximo login.
sudo gpasswd -d "$USER" libvirt

# 3. Desinstalar. `cockpit` e `qemu-kvm-core` ficam de fora porque são
#    dependência de outra coisa; `qemu-kvm` volta porque o módulo o nomeia.
sudo dnf remove libvirt-daemon libvirt-client virt-install qemu-kvm cockpit-machines
```

⚠️ **Assimetria de propósito:** o passo 2 remove o usuário do grupo mesmo que ele
já estivesse lá antes do setup. Um rollback que só desfaz o que ele fez exigiria
guardar o estado anterior, e o módulo é idempotente — roda de novo sem produzir
diferença. Se o grupo já existia por outro motivo, reponha com
`sudo gpasswd -a "$USER" libvirt`.

⚠️ O módulo **não** cria rede do libvirt, então não há o que reverter aqui. Se
você criou uma VM pelo Cockpit, ela **continua existindo** depois deste rollback —
o módulo cuida do hospedeiro, não do hóspede. Remova a VM pelo Cockpit antes.

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

O módulo instala as CLIs de npm **pelo Bun** (`bun add -g`, com fallback
para npm), e por instalador nativo o Cursor Agent, o OpenCode e o `agy`. O
instalador do `agy` ainda deixa uma unit de usuário que precisa ser parada antes
dos binários sumirem.

O `dsh` (DeepSeek Harness) entra pelo mesmo caminho, e sai pelo mesmo caminho
dos outros: o pacote some, o binário some junto. Ele guarda estado próprio em
`~/.dsh` — que só é criado no primeiro uso, não na instalação — então quem nunca
rodou `dsh` não tem o que apagar aqui.

```bash
# conferir o que existe antes de apagar
dsh --version 2>/dev/null
ls -d ~/.dsh 2>/dev/null

# remover o pacote e o binário
bun remove -g @deepseek-ai/dsh 2>/dev/null || npm uninstall -g @deepseek-ai/dsh
command -v dsh || echo "dsh fora do PATH"

# remover o estado, se chegou a existir
rm -rf ~/.dsh
```

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
for pkg in @anthropic-ai/claude-code @openai/codex; do
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

# Remove a unit. NAO ha drop-in para apagar: a v2 nao cria unit nenhuma, e a
# nossa e reescrita por `setup_opencode_service` — que ja a reescreve, e e o
# caminho de volta. `opencode.service.d` nao existe e nunca existiu nesta maquina.
rm -f ~/.config/systemd/user/opencode.service
systemctl --user daemon-reload

# A config em ~/.config/opencode/service.json e do BINARIO, nao do script: ela
# guarda a escuta e a senha, e sobrevive a remocao da CLI. Apagar e opcional.
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

`claude` e `cursor-agent` não dependem de Node, mas `codex` e `ocx` resolvem
`#!/usr/bin/env node` — por isso remova estas últimas **antes** do Bun e do mise
(seção `base`). Os symlinks em `~/.bun/bin` são recriados pelo Bun a
partir de `~/.bun/install/global/node_modules`; remover os pacotes basta.

### A configuração do servidor do OpenCode não é do repo, e uma parte não tem inverso

`opencode service set hostname|port|password` grava em
`~/.config/opencode/service.json` a `600`. Esse arquivo existe **por causa** do
`ai-clis`, mas não é do `setup.sh` — é do binário. Desinstalar a CLI leva o
arquivo junto? **Não**: ele fica.

```bash
# ver o que está gravado (a senha sai mascarada, por decisão do próprio binário)
opencode service get

# voltar ao default de loopback
opencode service unset hostname
```

**A senha não tem volta.** `unset password` faz o servidor voltar a *gerar* uma
aleatória a cada start — o que invalida as credenciais já salvas no navegador, e
não devolve a anterior. Se o objetivo é trocar por outra escolha, o caminho é
`set password` com a nova, e não há como recuperar a velha depois de sobrescrita.
Por isso ela é lida sem eco e a variável é apagada logo depois: o valor nunca
precisa ser reescrito para ser lembrado.

O serviço em si, hoje, **não sobrevive a reboot** — `opencode service start`
spawna um filho `detached` e `unref`, sem unit. Não há o que remover aqui porque
não há unit; ver a seção "OpenCode em uma VM nova" do `README.md` para o caminho
com `systemd`.

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
