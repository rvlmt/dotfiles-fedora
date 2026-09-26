# dotfiles-fedora

Provisiona o servidor Fedora Workstation (AIO local, sempre ligado) que roda
os ambientes de execução dos coding agents: containers Podman rootless
isolados por projeto, orquestrados via [devpod](https://devpod.sh) a partir
de um Mac na mesma tailnet.

O Mac (thin client: terminal, IDE, navegador, cliente Tailscale/devpod) é
provisionado pelo repo irmão **[dotfiles](https://github.com/rvlmt/dotfiles)**.
Os dois repos são independentes de propósito — nenhum depende do outro pra
rodar seu próprio `setup.sh` — mas compartilham a mesma ideia de estrutura
(`zshrc`, módulos com `--only`/`--skip`).

## Arquitetura

```
┌────────────── Mac (thin client) ──────────────┐      ┌────────── Fedora (servidor, sempre ligado) ──────────┐
│ Tailscale client                               │◄────►│ Tailscale (SSH só na interface tailscale0)           │
│ devpod CLI (provider SSH → fedora via tailnet) │      │ Podman rootless                                      │
│ VS Code + Remote-SSH/devpod extension          │      │ 1 container por projeto (.devcontainer/)             │
│ terminal (fallback SSH direto)                 │      │   → ai-clis dentro do container (claude, codex, ...) │
│ cliente RDP (opcional, GUI do Fedora)          │      │ GNOME Remote Desktop nativo (RDP, opcional)          │
└──────────────────────────────────────────────────┘      └─────────────────────────────────────────────────────┘
```

Cada projeto carrega seu próprio `.devcontainer/` (a partir do template em
`devcontainer-template/`), então o ambiente de trabalho do agente é isolado
e reprodutível por projeto — o host Fedora só entra com Podman/rede/SSH, não
com as CLIs de IA em si.

## Estrutura

- **`setup.sh`** — provisiona o servidor Fedora. Um arquivo só (cores,
  confirmação, geração de chave SSH, config git/gh, instalação das CLIs de
  IA, os módulos — tudo junto); idempotente, pode ser executado várias vezes
  sem duplicar configuração.
- **`zshrc`** — configurações e aliases do terminal, portáveis entre macOS e
  Fedora. Cópia independente da do repo `dotfiles`; aqui é opcional e
  pergunta antes de aplicar (módulo `zshrc`, faz sentido agora que a máquina
  tem sessão gráfica/RDP).
- **`devcontainer-template/`** — template de `.devcontainer/` (Containerfile
  + devcontainer.json) para copiar em cada projeto que vai rodar isolado via
  devpod/Podman neste servidor. Também existe uma cópia no repo `dotfiles`,
  já que é de lá (do Mac) que você copia o template pra dentro de um projeto
  antes de rodar `devpod up`.
- **[`ROLLBACK.md`](ROLLBACK.md)** — como reverter cada mudança feita pelo
  script, módulo por módulo.

## Por que dois repos (`dotfiles` + `dotfiles-fedora`)

Antes disso era um repo só. Na prática, isso significava carregar decisões e
módulos inteiros de uma plataforma toda vez que se mexia na outra — mais
lógica condicional, mais coisa pra entender antes de rodar um `./setup.sh`
simples numa máquina nova. Separar por papel (thin client vs. servidor de
execução) deixa cada script fazendo sentido sozinho, ao custo de duplicar um
punhado de arquivos pequenos (`zshrc`) — duplicação aceitável aqui porque são
poucos e mudam raramente; se um dia isso doer de verdade, dá pra
reconsiderar. Pela mesma lógica, `lib-common.sh` (que só existia pra
compartilhar funções entre `setup.sh` e `setup-fedora.sh` no repo antigo) foi
embutido direto no `setup.sh` de cada repo — não há mais um segundo script no
mesmo repo pra justificar mantê-las separadas.

## Como rodar num Fedora novo ou recém-formatado

1. Clone este repositório e rode:

   ```bash
   git clone https://github.com/rvlmt/dotfiles-fedora.git ~/dotfiles-fedora
   cd ~/dotfiles-fedora
   chmod +x setup.sh
   ./setup.sh
   ```

   > Se o repositório estiver **privado**, `git clone` direto falha numa
   > máquina nova (sem chave SSH nem `gh` autenticado ainda). Numa instalação
   > recém-feita, `sudo dnf install -y gh` isolado costuma falhar por
   > metadata desatualizada dos repositórios — rode
   > `sudo dnf upgrade --refresh -y` primeiro se isso acontecer. Depois, use
   > `gh auth login` (login via navegador) seguido de
   > `gh repo clone rvlmt/dotfiles-fedora ~/dotfiles-fedora`.

   O script deve ser executado como **usuário comum** (`./setup.sh`, e **NÃO** `sudo ./setup.sh`), pois ele configura o `$HOME`, chaves SSH, dotfiles e Podman rootless do seu usuário. Ele pede a senha do `sudo` uma vez logo no início e mantém o cache "quente" em background até terminar — evita travar pedindo senha de novo no meio de um `dnf upgrade` longo.

   **Todas as perguntas de confirmação (`y/N`) acontecem logo no início**,
   antes de qualquer `dnf`/instalação — assim você responde tudo de uma vez
   e pode sair de perto do terminal, sem precisar checar se o script parou
   esperando resposta no meio do caminho.

   Módulos (em ordem):
   1. `base` — `dnf upgrade`, ferramentas essenciais (git, gh, jq, tree, tmux, zellij, ripgrep, fd-find, btop) e `mise` (gerenciador de versões de runtime). Usa `dnf install --skip-unavailable`: um pacote ausente/renomeado numa versão específica do Fedora não trava a instalação dos outros.
   2. `hostname` — Mostra o hostname atual e pergunta se quer alterá-lo, já na fase de coleta do início (`hostnamectl set-hostname` só aplica depois); cria `~/Developer`.
   3. `ssh` — Gera chave SSH Ed25519 e a usa pra autenticar esta máquina no GitHub (`gh ssh-key add`) — não confundir com autorizar OUTRAS máquinas a entrar aqui via SSH, que é manual (passo 2 abaixo).
   4. `git` — Configura `git config --global` e autentica o `gh`, enviando a chave pública.
   5. `podman` — Instala Podman rootless, configura subuid/subgid, habilita linger (containers sobrevivem ao logout/desconexão de SSH) e configura `userns=keep-id` (`~/.config/containers/containers.conf`) — sem isso, processos rodando como "root" dentro de um container não conseguem escrever em bind-mounts que pertencem ao seu usuário real.
   6. `tailscale` — Adiciona o repo oficial da Tailscale via `dnf config-manager` e instala via `dnf` (não usa `curl | sh`), conecta com `tailscale up` (sem `--ssh` de propósito — ver nota abaixo). Assume DNF5 (padrão desde o Fedora 41).
   7. `sshd-hardening` — Desabilita login por senha e login root via SSH. **Pede confirmação** (no início, junto com as outras). Recusa aplicar (avisa e pula) se `~/.ssh/authorized_keys` estiver vazio — ver passo 2 abaixo, senão você fica sem nenhum jeito de entrar via SSH.
   8. `firewalld` — Garante o firewall ativo e marca a interface `tailscale0` como confiável.

   **Por que não usar o Tailscale SSH (`tailscale up --ssh`)**: ele exige reautenticação interativa via navegador sempre que a política da tailnet tiver `action: check` nos grants de SSH (o default da maioria das tailnets) — quebra qualquer ferramenta que não sabe abrir um navegador (Codex Desktop, devpod rodando não-interativamente, cron, etc.), e o próprio Tailscale avisa incompatibilidade com SELinux enforcing no Fedora. O acesso SSH real já é coberto por `sshd-hardening` (só chave, sem senha) + `firewalld` (sshd só na interface `tailscale0`) — chave clássica, sem nenhuma reautenticação. Se você já rodou uma versão anterior deste script com `--ssh`, desative com `sudo tailscale set --ssh=false`.

   9. `toolbx` *(opcional, não roda por padrão)* — Sandbox Podman rápida para mexer em algo fora do contexto de um projeto/devpod. Rode com `--only=toolbx`.
   10. `gui-access` *(opcional, não roda por padrão)* — Habilita o GNOME Remote Desktop nativo (RDP via `grdctl`), já que o Fedora é uma Workstation completa (AIO dedicado) e às vezes vale controlar direto com tela. Rode com `--only=gui-access`; depois defina uma senha com `grdctl rdp set-credentials <usuario> <senha>` e conecte via um cliente RDP no Mac.
   11. `desktop-apps` — Equivalente ao Brewfile do Mac. Cada app foi checado individualmente contra fonte oficial antes de decidir instalar ou não (ver `ROLLBACK.md`/comentários no script pra fontes exatas):
       - **Instalados automaticamente** (fonte oficial confirmada, funciona no Fedora): VS Code (repo Microsoft), Google Chrome (RPM oficial), Brave (repo oficial), Zed (script oficial), Antigravity IDE (repo rpm oficial do Google), Cursor (AppImage oficial), OpenCode Desktop (RPM oficial), Transmission (repo do Fedora).
       - **Genuinamente sem versão Linux** (confirmado oficialmente, sem alternativa real): Adobe Creative Cloud, Raycast, OpenUsage, OrbStack, Rectangle (GNOME já tem tiling nativo), Arc (nunca suportou Linux), AppCleaner e Pearcleaner (resolvem um problema específico do modelo de "bundle" do macOS que não existe no Fedora).
       - **Têm app oficial pra Linux, mas sem Fedora/rpm ainda**: Claude Desktop (só .deb, Ubuntu/Debian), ChatGPT Desktop (tem rpm oficial pro Fedora, mas em preview com bug conhecido de assinatura — manual se quiser).
       - **Oficial só via Docker/Podman Compose** (não é app desktop nativo): Open Design.
       - **Sem app oficial, só opção não-oficial/não-verificada de terceiros** (não instalada automaticamente, decisão sua): GitHub Desktop, Notion, Figma, Spotify e Termius (os Flatpaks desses dois últimos são "Unverified"/não afiliados no Flathub, apesar de populares), FontBase (AppImage oficial existe, mas sem link "sempre atual" estável), Surfshark (sem suporte oficial a Fedora), Ghostty (só via COPR de terceiros).
       - devpod tem binário Linux oficial, mas não é instalado aqui — ele roda do lado Mac controlando este servidor.
   12. `ai-clis` — **Pergunta antes de aplicar**: CLIs de IA (Claude Code, Codex, Gemini CLI, Copilot CLI, Cursor Agent, Open Code, Antigravity CLI). Opcional no host, já que os coding agents rodam primariamente isolados dentro dos containers devpod.
   13. `opencodex` — Instala a CLI do OpenCodex (`@bitkyc08/opencodex`), router local para modelos de IA.
   14. `zshrc` — **Pergunta antes de aplicar**: linka o `zshrc` compartilhado também neste servidor (com aliases para Git, Podman e Docker), instala `zsh`+plugins via `dnf` e troca o shell padrão.

   Use `--only=modulo1,modulo2` ou `--skip=modulo1,modulo2`. Só `toolbx` e
   `gui-access` ficam de fora por padrão (precisam de `--only` explícito); os
   demais módulos interativos (`ai-clis`, `zshrc`) participam da execução normal,
   com a confirmação coletada logo no início.

   ```bash
   ./setup.sh --only=podman,tailscale
   ./setup.sh --skip=gui-access
   ./setup.sh --help   # lista os módulos disponíveis
   ```

2. **Autorize cada dispositivo que vai entrar por SSH aqui** (Mac, Mac Mini,
   iPhone, etc). O script gera/usa uma chave SSH só pra autenticar *este
   servidor* no GitHub — ele não copia a chave pública de outras máquinas pra
   cá, então isso é manual, uma vez por dispositivo:

   ```bash
   # No dispositivo cliente, copie a saída (ex.: no Mac):
   cat ~/.ssh/id_ed25519.pub

   # Aqui no Fedora (fisicamente, ou por qualquer sessão que já funcione):
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   echo "<cole a chave pública do dispositivo aqui>" >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   restorecon -Rv ~/.ssh   # SELinux enforcing no Fedora — evita rótulo errado bloquear a checagem da chave pelo sshd
   ```

   Faça isso **antes** de rodar o módulo `sshd-hardening` (ele mesmo verifica
   e recusa desabilitar login por senha se `~/.ssh/authorized_keys` estiver
   vazio, exatamente pra evitar ficar sem nenhum jeito de entrar via SSH).

   Cada dispositivo com sua própria chave (em vez de uma chave compartilhada
   entre todos) é proposital: revogar o acesso de um dispositivo perdido é
   deletar uma linha aqui, sem afetar os outros, e sem depender da segurança
   de nenhuma conta externa (GitHub incluso) pra decidir quem entra neste
   servidor.

3. No Mac, configure o devpod para usar este servidor como provider remoto
   via Tailscale — ver o repo [`dotfiles`](https://github.com/rvlmt/dotfiles)
   pros passos completos (`devpod provider add ssh`, `devpod up`, etc).

**Notas de segurança**: o SSH deste servidor fica restrito à interface
Tailscale (sem exposição pública), login por senha é desabilitado, e o
isolamento entre projetos/tarefas acontece no nível de container (Podman
rootless) — não é necessário um usuário Linux dedicado para isso, já que o
boundary real é o container, não o usuário do host.

O template de devcontainer traz, por padrão:
- **Limite de recursos** (`runArgs: --memory=4g --cpus=2`) — um agente com bug/loop não derruba o servidor inteiro. Ajuste por projeto.
- **Credenciais escopadas por projeto**: um volume nomeado (`<projeto>-agent-home`), não um bind-mount do seu `$HOME` — autentique `gh auth login` uma vez dentro do container; fica isolado desse projeto e nunca usa sua chave SSH/config pessoal do host.
- **Trilha de auditoria**: toda sessão de shell interativa é gravada em `$AGENT_LOG_DIR` (dentro do mesmo volume nomeado, fora do repositório) via `script` — útil pra revisar depois o que um agente autônomo executou de fato.

## Dev Container CLI no host Fedora

O Dev Container CLI é a exceção deliberada, user-scoped, ao
container-first: é um controlador do host, não um toolchain de aplicação.
Esta seção não altera a arquitetura de execução dos agents. Os
devcontainers de aplicação não recebem credenciais nem CLIs de agent; o
template `agent-sandbox` é tratado separadamente.

A instalação é gerenciada e pinada pelo `mise`, incluindo um runtime Node
próprio para o CLI:

```bash
mise use -g --pin node@22.23.3 devcontainer-cli@0.89.0
mise exec node@22.23.3 devcontainer-cli@0.89.0 -- node --version
mise exec node@22.23.3 devcontainer-cli@0.89.0 -- devcontainer --version
```

Force as versões globais também nos comandos executados dentro de um
repositório, para que um `mise.toml` local não substitua o runtime do CLI:

```bash
mise exec node@22.23.3 devcontainer-cli@0.89.0 -- devcontainer up \
  --docker-path podman \
  --workspace-folder /caminho/do/projeto

mise exec node@22.23.3 devcontainer-cli@0.89.0 -- devcontainer exec \
  --docker-path podman \
  --workspace-folder /caminho/do/projeto \
  <comando-do-aplicativo>
```

Neste fluxo, `--docker-path podman` é uma exigência de política: torna o
provider explícito e não depende do shim `podman-docker`, que também
faria o CLI detectar Podman. O CLI executa o binário informado; esta
operação não depende do `podman.socket`. O socket permanece
desabilitado, e builds/testes/lint de aplicação não usam `docker compose`
nem `podman-compose`.

Quando executado pelo usuário regular contra Podman rootless, o provider
Podman do CLI em Linux adiciona `--security-opt label=disable`. Esse
comportamento pertence ao variant do Podman, não a uma versão específica
do CLI. Os containers continuam rootless e separados por projeto, mas este
workflow de devcontainer não deve ser descrito como confine SELinux.
Mantenha as credenciais fora do workspace montado e não use este modo
como boundary do host.

### Ciclo de vida dos devcontainers

O CLI `0.89.0` não oferece um `down` completo. O cleanup usa o label
`devcontainer.local_folder` e deve ser feito em etapas, revisando a lista
antes de remover qualquer container:

```bash
WORKSPACE=/caminho/absoluto/do/projeto

# 1. Identificar containers do projeto.
podman ps -a \
  --filter "label=devcontainer.local_folder=${WORKSPACE}" \
  --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}'

# 2. Parar somente os IDs revisados no passo anterior.
podman stop <id-1> <id-2>

# 3. Verificar portas residuais. Sem saída significa que estão livres.
ss -ltnp | grep -E ':(8000|8080|5173|3000|5432)\b'

# 4. Remover os mesmos IDs depois da confirmação.
podman rm <id-1> <id-2>

# 5. Confirmar que não restou container com o label do projeto.
podman ps -a \
  --filter "label=devcontainer.local_folder=${WORKSPACE}" \
  --format '{{.ID}} {{.Names}} {{.Status}}'

# 6. Recriar quando o cleanup estiver aprovado.
mise exec node@22.23.3 devcontainer-cli@0.89.0 -- devcontainer up \
  --docker-path podman \
  --workspace-folder "${WORKSPACE}"
```

Nenhuma etapa deste runbook deve ser automatizada com `rm` por wildcard:
os IDs revisados são parte do procedimento.

## Configurações Manuais Opcionais no Host (GUI ou Terminal)

Caso você queira transformar o Fedora em um servidor autônomo sem intervenção física (ex.: recuperação após reboot para sessões RDP), essas configurações podem ser feitas sob demanda:

### 1. Login automático do GDM (Autologin)
Permite que o Fedora suba a sessão gráfica no boot sem ninguém digitar a senha fisicamente. **Atenção**: qualquer pessoa com acesso físico ao computador terá acesso à sessão aberta.

- **Pela GUI**: **Configurações → Usuários** → selecione seu usuário → ative o toggle **"Login Automático"**.
- **Pelo Terminal**:
  ```bash
  sudo sed -i '/^\[daemon\]/,/^\[/{/^AutomaticLoginEnable=/d; /^AutomaticLogin=/d}' /etc/gdm/custom.conf
  sudo sed -i "/^\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=$USER" /etc/gdm/custom.conf
  ```

### 2. Gestão de Energia (Prevenir suspensão e tela preta por ociosidade)
Garante que o host continue sempre ativo mesmo sem mouse ou teclado físicos conectados.

- **Pela GUI**: **Configurações → Energia** → defina "Apagar tela" para **Nunca** e desative "Suspensão Automática".
- **Pelo Terminal** (dconf + máscara no systemd-logind):
  ```bash
  # Previne suspensão e bloqueio no GNOME
  sudo mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
  printf 'user-db:user\nsystem-db:local\n' | sudo tee /etc/dconf/profile/user > /dev/null
  sudo tee /etc/dconf/db/local.d/00-power-management > /dev/null <<'EOF'
  [org/gnome/settings-daemon/plugins/power]
  sleep-inactive-ac-type='nothing'
  sleep-inactive-ac-timeout=0

  [org/gnome/desktop/session]
  idle-delay=uint32 0

  [org/gnome/desktop/screensaver]
  lock-enabled=false
  EOF
  sudo dconf update

  # Mascara suspensão/hibernação no systemd
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  ```

### 3. Reboot Semanal Agendado
Caso queira programar um reboot automático como rotina de limpeza do sistema (ex.: domingo às 04h):

- **Pelo Terminal**:
  ```bash
  sudo tee /etc/systemd/system/scheduled-reboot.service > /dev/null <<'EOF'
  [Unit]
  Description=Reboot semanal agendado (higiene geral do servidor)

  [Service]
  Type=oneshot
  ExecStart=/usr/bin/systemctl reboot
  EOF

  sudo tee /etc/systemd/system/scheduled-reboot.timer > /dev/null <<'EOF'
  [Unit]
  Description=Dispara o reboot semanal agendado

  [Timer]
  OnCalendar=Sun *-*-* 04:00:00
  Persistent=true

  [Install]
  WantedBy=timers.target
  EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now scheduled-reboot.timer
  ```

## Pré-configurando respostas (evitar digitar de novo a cada execução)

`GIT_NAME` e `GIT_EMAIL` já têm um default fixado no topo do `setup.sh`
(`DEFAULT_GIT_NAME`/`DEFAULT_GIT_EMAIL`). O prompt mostra esse default entre
colchetes; Enter aceita, digitar outra coisa sobrescreve só naquela
execução. Também podem ser pré-exportados no ambiente antes de rodar, o que
pula o prompt completamente:

```bash
GIT_NAME="Seu Nome" GIT_EMAIL="voce@exemplo.com" ./setup.sh
```

Não crie um arquivo com essas variáveis dentro do repositório (viraria
commitável por engano) — prefira exportá-las no seu shell rc pessoal (fora
deste repo) ou passá-las inline como acima.
