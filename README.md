# dotfiles-fedora

Provisiona o Fedora Workstation que é **workstation pessoal e hospedeiro de VMs**.
Os agentes e os containers rodam **dentro de uma VM**, não no host: ver
[ARQUITETURA.md](ARQUITETURA.md) para o desenho e o papel de cada camada.

> **Como este README e o `ARQUITECTURA.md` se dividem.** A
> [ARQUITETURA.md](ARQUITETURA.md) diz o que o repo **é** — as três camadas, o
> papel de cada uma, e o que ainda está pendente. Este README diz **como
> executar**: os módulos, os flags, e as ressalvas de cada um. Onde um passo aqui
> diz "no host" e "na VM", o `--profile` correspondente decide o que roda.

O Mac (thin client: terminal, IDE, navegador, cliente Tailscale/devpod) é
provisionado pelo repo irmão **[dotfiles](https://github.com/rvlmt/dotfiles)**.
Os dois repos são independentes de propósito — nenhum depende do outro pra
rodar seu próprio `setup.sh` — mas compartilham a mesma ideia de estrutura
(`zshrc`, módulos com `--only`/`--skip`).

## Estrutura

- **`setup.sh`** — provisiona o servidor Fedora. Um arquivo só (cores,
  confirmação, geração de chave SSH, config git/gh, instalação das CLIs de
  IA, os módulos — tudo junto); idempotente, pode ser executado várias vezes
  sem duplicar configuração.
- **`zshrc`** — configurações e aliases do terminal, portáveis entre macOS e
  Fedora. Cópia independente da do repo `dotfiles`. No Fedora ele é o shell de
  login padrão e o dono do PATH interativo (módulo `zshrc`): é ele que declara
  mise, Bun, `~/.local/bin` e `~/.opencode/bin`, então um host novo não depende
  de ninguém acrescentar isso à mão.
- **`devcontainer-template/`** — template de `.devcontainer/` (Containerfile
  + devcontainer.json) para copiar em cada projeto que vai rodar isolado via
  devpod/Podman neste servidor. Também existe uma cópia no repo `dotfiles`,
  já que é de lá (do Mac) que você copia o template pra dentro de um projeto
  antes de rodar `devpod up`.
- **[`ROLLBACK.md`](ROLLBACK.md)** — como reverter cada mudança feita pelo
  script, módulo por módulo.
- **[`ARQUITETURA.md`](ARQUITETURA.md)** — o que este repo é: as três camadas, o
  papel de cada uma, as decisões fechadas e o que segue em aberto. É o alvo; este
  README é o runbook.

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

   O script deve ser executado como **usuário comum** (`./setup.sh`, e **NÃO** `sudo ./setup.sh`), pois ele configura o `$HOME`, chaves SSH e dotfiles do seu usuário (e, no perfil `vm`, o Podman rootless). Ele pede a senha do `sudo` uma vez logo no início e mantém o cache "quente" em background até terminar — evita travar pedindo senha de novo no meio de um `dnf upgrade` longo.

   **Todas as perguntas de confirmação (`y/N`) acontecem logo no início**,
   antes de qualquer `dnf`/instalação — assim você responde tudo de uma vez
   e pode sair de perto do terminal, sem precisar checar se o script parou
   esperando resposta no meio do caminho.

   Módulos, por perfil (a ordem dentro de cada um é a de execução):
   1. `base` — `dnf upgrade`, ferramentas essenciais (git, gh, jq, tree, tmux, zellij, ripgrep, fd-find, unzip, curl, wget, btop, tar, openssl, dnf5-plugins) e o runtime via `mise` (Node e Dev Container CLI pinados — ver "Runtime Node no host"). `tar` entra na lista porque dois dos instaladores que o script chama precisam dele: o mise, em `ensure_host_node`, e o Zed, no módulo `desktop-apps`. Usa `dnf install --skip-unavailable`: um pacote ausente/renomeado numa versão específica do Fedora não trava a instalação dos outros.  **[ambos]**
   2. `hostname` — Mostra o hostname atual e pergunta se quer alterá-lo, já na fase de coleta do início (`hostnamectl set-hostname` só aplica depois); cria `~/Developer`.  **[host]**
   3. `ssh` — Gera chave SSH Ed25519 e a usa pra autenticar esta máquina no GitHub (`gh ssh-key add`) — não confundir com autorizar OUTRAS máquinas a entrar aqui via SSH, que é manual (passo 2 abaixo).  **[ambos]**
   4. `git` — O login de pessoa do `gh` é **opt-in**: responder `y` na pergunta do bloco inicial faz o `gh auth login -w` pelo navegador; responder nada deixa o `gh` sem token próprio, porque a GitHub App já cobre a API dos agentes. A consequência é que a chave SSH da máquina **não** é registrada no GitHub — registrar chave é `POST /user/keys`, um endpoint de usuário que um token de instalação não alcança — e o módulo diz isso na hora. Configura `git config --global` e autentica o `gh`, enviando a chave pública.  **[ambos]**
   5. `podman` — Instala Podman rootless, configura subuid/subgid, habilita linger (containers sobrevivem ao logout/desconexão de SSH) e configura `userns=keep-id` (`~/.config/containers/containers.conf`) — sem isso, processos rodando como "root" dentro de um container não conseguem escrever em bind-mounts que pertencem ao seu usuário real.  **[guest]**
   6. `gh-app` — **Pergunta no bloco inicial, sem `y/N`**: pede o App ID e a private key, e grava os dois em `~/.config/gh-app/` com permissão `600`. Instala o `gh-app-token`, que assina um JWT RS256 com a private key e o troca por um token de instalação — o `gh` não faz login como App, e é por isso que o token vira `GH_TOKEN`, que tem precedência sobre credenciais guardadas. Instala também o wrapper `gh-app`, que obtém um token por comando e o descarta; o token vive **uma hora**, e a pós-condição do módulo é a API respondendo, não o arquivo existindo. **Não vai para o shell rc de propósito**: mintar a cada shell aberto seria uma chamada de API por terminal. É do guest porque é lá que os agentes rodam, e é de lá que eles abrem PR, escrevem issue e comentam. Sem App ID ou sem chave, o módulo fica inativo e o `gh` volta a pedir login.  **[guest]**
   7. `tailscale` — Adiciona o repo oficial da Tailscale via `dnf config-manager` e instala via `dnf` (não usa `curl | sh`), conecta com `tailscale up` (sem `--ssh` de propósito — ver nota abaixo). Assume DNF5 (padrão desde o Fedora 41).  **[ambos]**
   8. `sshd-hardening` — Desabilita login por senha e login root via SSH. **Pede confirmação** (no início, junto com as outras). Recusa aplicar (avisa e pula) se `~/.ssh/authorized_keys` estiver vazio — ver passo 2 abaixo, senão você fica sem nenhum jeito de entrar via SSH.  **[ambos]**
   9. `firewalld` — Garante o firewall ativo e marca a interface `tailscale0` como confiável. **Pendente:** a [ARQUITETURA.md](ARQUITETURA.md) decide que `tailscale0` sai da zona `trusted` e que a rede do libvirt é declarada por este repo com o filtro de egress. O código ainda não faz nenhum dos dois — ver "Ordem de implementação".  **[host]**

   **Por que não usar o Tailscale SSH (`tailscale up --ssh`)**: ele exige reautenticação interativa via navegador sempre que a política da tailnet tiver `action: check` nos grants de SSH (o default da maioria das tailnets) — quebra qualquer ferramenta que não sabe abrir um navegador (Codex Desktop, devpod rodando não-interativamente, cron, etc.), e o próprio Tailscale avisa incompatibilidade com SELinux enforcing no Fedora. O acesso SSH real já é coberto por `sshd-hardening` (só chave, sem senha) + `firewalld` (sshd só na interface `tailscale0`) — chave clássica, sem nenhuma reautenticação. Se você já rodou uma versão anterior deste script com `--ssh`, desative com `sudo tailscale set --ssh=false`.

   10. `vm-host` — Instala `libvirt-daemon`, `libvirt-client`, `virt-install`, `qemu-kvm` e `cockpit-machines`; coloca o usuário no grupo `libvirt` e habilita o `cockpit.socket`. É onde a VM de agentes vai ser criada e gerenciada. **Não declara a rede do libvirt** — ver [ARQUITETURA.md](ARQUITETURA.md), pendência de rede do host.  **[host]**
   11. `toolbx` *(opcional, não roda por padrão)* — Sandbox Podman rápida para mexer em algo fora do contexto de um projeto/devpod. Rode com `--only=toolbx`.  **[host]**
   12. `gui-access` *(opcional, não roda por padrão)* — Habilita o GNOME Remote Desktop nativo (RDP via `grdctl`), já que o Fedora é uma Workstation completa (AIO dedicado) e às vezes vale controlar direto com tela. Rode com `--only=gui-access`; depois defina uma senha com `grdctl rdp set-credentials <usuario> <senha>` e conecte via um cliente RDP no Mac.  **[host]**
   13. `desktop-apps` — Equivalente ao Brewfile do Mac. Cada app foi checado individualmente contra fonte oficial antes de decidir instalar ou não (ver `ROLLBACK.md`/comentários no script pra fontes exatas):  **[host]**
       - **Instalados automaticamente** (fonte oficial confirmada, funciona no Fedora): VS Code (repo Microsoft), Google Chrome (RPM oficial), Brave (repo oficial), Zed (script oficial), Antigravity IDE (repo rpm oficial do Google), Cursor (AppImage oficial), OpenCode Desktop (RPM oficial), Transmission (repo do Fedora).
       - **Genuinamente sem versão Linux** (confirmado oficialmente, sem alternativa real): Adobe Creative Cloud, Raycast, OpenUsage, OrbStack, Rectangle (GNOME já tem tiling nativo), Arc (nunca suportou Linux), AppCleaner e Pearcleaner (resolvem um problema específico do modelo de "bundle" do macOS que não existe no Fedora).
       - **Têm app oficial pra Linux, mas sem Fedora/rpm ainda**: Claude Desktop (só .deb, Ubuntu/Debian), ChatGPT Desktop (tem rpm oficial pro Fedora, mas em preview com bug conhecido de assinatura — manual se quiser).
       - **Oficial só via Docker/Podman Compose** (não é app desktop nativo): Open Design.
       - **Sem app oficial, só opção não-oficial/não-verificada de terceiros** (não instalada automaticamente, decisão sua): GitHub Desktop, Notion, Figma, Spotify e Termius (os Flatpaks desses dois últimos são "Unverified"/não afiliados no Flathub, apesar de populares), FontBase (AppImage oficial existe, mas sem link "sempre atual" estável), Surfshark (sem suporte oficial a Fedora), Ghostty (só via COPR de terceiros).
       - devpod tem binário Linux oficial, mas não é instalado aqui — ele roda do lado Mac controlando este servidor.
   14. `ai-clis` — **Pergunta antes de aplicar**: CLIs de IA (Claude Code, Codex, Gemini CLI, Copilot CLI, Cursor Agent, Open Code, Antigravity CLI). O Open Code vem do **canal v2**, instalado por `opencode.ai/v2/install` e **pinado** em `OPENCODE_VERSION` no topo do `setup.sh` — a linha 1 fica em `opencode.ai/install`, e a v1 não tem o subcomando `service` que o próprio script usa para definir a senha do servidor. Ver "Runtime do OpenCode". É do guest porque é lá que os agentes rodam; dentro da VM é também onde o servidor do OpenCode, a escuta em loopback e a publicação na tailnet são declarados.  **[guest]**
   15. `opencodex` — Instala a CLI do OpenCodex (`@bitkyc08/opencodex`), um proxy universal de provider que fica no caminho das requisições de modelo. **Pergunta antes de aplicar, com pergunta própria** — separada da do `ai-clis`, porque não é uma CLI local como as seis de lá. É do perfil `host` e serve o uso pessoal: os agentes dentro da VM não o recebem, cada um usa a credencial do provider direto.  **[host]**
   16. `zshrc` — Torna o `zsh` o shell de login da máquina: instala `zsh`+plugins via `dnf`, linka o `zshrc` versionado deste repo e roda `chsh`. Participa da execução normal sem confirmação. A única confirmação é sobre substituir um `~/.zshrc` que já exista e não seja o link deste repo (o atual é salvo como backup).  **[ambos]**

   **`[host]`** marca os módulos do perfil `host` (workstation pessoal e
   hospedeiro de VMs), **`[guest]`** os do perfil `vm` (a VM de agentes), e
   **[ambos]** os que existem nos dois. A regra é uma só: *um módulo mora no
   perfil da camada que o executa* — ver [ARQUITETURA.md](ARQUITETURA.md).

   ```bash
   ./setup.sh                        # perfil host (padrão)
   ./setup.sh --profile=vm           # dentro da VM de agentes
   ./setup.sh --only=firewalld,tailscale        # no host
   ./setup.sh --profile=vm --only=podman,ai-clis   # dentro da VM
   ./setup.sh --skip=gui-access
   ./setup.sh --help                 # lista os perfis e os módulos de cada um
   ```

   `--profile` é um **eixo novo, orthogonal** ao `--only`/`--skip` que já existia:
   o perfil escolhe o conjunto de módulos, e o `--only`/`--skip` refinam por
   dentro. `--only` é validado **contra o perfil** e falha alto se o módulo não
   pertence à camada — pedir Podman no host é um erro, e falhar alto evita
   instalar por engano. `--skip` de um módulo fora do perfil apenas avisa, porque
   pular o que não roda é inócuo.

   Só `toolbx` e `gui-access` ficam de fora por padrão (precisam de `--only`
   explícito). `ai-clis` e `opencodex` são de terceiros e **perguntam antes de
   agir**, cada um com a sua pergunta: o `opencodex` não é uma CLI local, é um
   proxy de provider que fica no caminho das requisições de modelo, e por isso
   tem pergunta separada. `zshrc` não pergunta, exceto na substituição destrutiva
   descrita acima.

   > **Por que o script recusa stdin não-interativo.** As perguntas usam
   > `read -rp`, que o bash só imprime quando o stdin é um terminal, e `read`
   > devolve 1 no fim da entrada. Como algumas dessas leituras estão fora de um
   > contexto `&&`, o `set -e` abortava o script: saía com código 1, depois do
   > banner, sem mensagem, sem rodar módulo nenhum e sem recusa nenhuma. Por
   > isso o script **recusa no início**, com mensagem, quando o stdin não é um
   > terminal. A alternativa — seguir com os defaults — produziria um
   > provisionamento parcial e silencioso, que é pior do que não rodar. Para
   > inspecionar sem executar: `./setup.sh --help`.

   ### Camadas `<none>` são cache, não lixo

   Cada `devcontainer up` deixa camadas intermediárias de build com tag `<none>`.
   Elas **não são lixo**: são cache de buildah, reaproveitado por digest de pai.
   Um build igual reusa essas camadas; só um build diferente (base ou Containerfile
   alterados) as descarta de qualquer forma. Ficam "órfãs" apenas porque nada as
   referencia por nome depois que a imagem final recebeu tag.

   O runbook de cleanup desta seção remove **containers** por label, nunca
   **images** — então nada remove essas camadas por conta própria, e elas
   acumulam em disco conforme o número de builds e recriações de devcontainer.

   **Podar ou não é uma decisão de tradeoff, não uma correção.** Removê-las
   libera disco mas obriga o próximo `devcontainer build` a refazer as camadas do
   zero; mantê-las economiza rebuild mas ocupa disco. Num host com espaço,
   **não podar é legítimo** — as camadas são o cache que faz o próximo build ser
   rápido. Podar só faz sentido sob pressão de disco, e o comando abaixo não
   remove imagens em uso, volumes nem containers:

   ```bash
   podman image prune --force --filter dangling=true
   ```

   Meça o espaço pelo `df`, não pelo `du` do store. Se o filesystem do store for
   btrfs com compressão, o `du` superestima o uso real com facilidade:
   `stat -c %b` devolve blocos **não comprimidos**, enquanto o disco ocupa o
   tamanho comprimido. Num host assim, camadas de imagem cheias de texto e JS
   comprimem várias vezes, e a diferença entre `du` e `df` passa de dezenas de GB
   sem que nada esteja errado. Neste host, um arquivo de 200 MB de texto repetido
   foi reportado pelo `du` como 200 MB e ocupou 6,5 MB de disco.

   Antes de acreditar em qualquer número de disco, uma checagem basta. O
   `--target` é obrigatório: sem ele o `findmnt` não resolve um caminho dentro de
   um subvolume e responde que não há compressão.

   ```bash
   findmnt -T ~/.local/share/containers/storage -no OPTIONS \
     | tr ',' '\n' | grep -i '^compress='
   ```

   Se não imprimir nada, o `du` é confiável nesse filesystem. Se imprimir, meça
   pelo `df`.

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

3. Crie a VM de agentes: no Cockpit do host (**Machines → Create VM**), com a
   imagem do Fedora Workstation. Escolha uma porta por serviço se precisar
   exponer algo, e **deixe a rede como está** — o padrão do libvirt serve, e a
   postura de rede do host é uma pendência documentada, não algo que este passo
   precisa acertar.

4. Dentro da VM, rode o mesmo script com o perfil de guest:

   ```bash
   ./setup.sh --profile=vm
   ```

5. No Mac, aponte o devpod para a **VM** (não para o host) como provider remoto
   via Tailscale — ver o repo [`dotfiles`](https://github.com/rvlmt/dotfiles)
   pros passos completos (`devpod provider add ssh`, `devpod up`, etc).

**Notas de segurança**, e elas valem por camada:

- **Host** — o SSH fica restrito à interface Tailscale (sem exposição pública), e
  o módulo `sshd-hardening` desabilita login por senha mas se recusa a aplicar
  enquanto `~/.ssh/authorized_keys` estiver vazio. O host não roda container: ele
  hospeda a VM.
- **VM de agentes** — é alcançada por SSH pela tailnet, e o `firewalld` do host não
  a governa, porque a VM vive atrás de NAT. A defesa da VM é o
  `sshd-hardening` que roda **dentro** dela, mais a fronteira da própria VM. O
  Podman rootless com `userns=keep-id` isola os projetos **entre si**, dentro da
  VM — essa é a fronteira do container, e ela **não** é fronteira de host.
- Não há usuário Linux dedicado, nem no host nem na VM. A postura completa, e o
  que ela **não** cobre, está em [ARQUITETURA.md](ARQUITETURA.md).

O template de devcontainer traz, por padrão:
- **Limite de recursos** (`runArgs: --memory=4g --cpus=2`) — um agente com bug/loop não derruba o servidor inteiro. Ajuste por projeto.
- **Credenciais escopadas por projeto**: um volume nomeado (`<projeto>-agent-home`), não um bind-mount do seu `$HOME` — autentique `gh auth login` uma vez dentro do container; fica isolado desse projeto e nunca usa sua chave SSH/config pessoal do host.
  > **Ressalva: esse nome colide.** O volume é derivado de
  > `${localWorkspaceFolderBasename}`, que é só o nome do diretório. Dois projetos
  > com o mesmo nome base — duas cópias do mesmo repositório em caminhos
  > diferentes, ou dois projetos chamados `api` — compartilham o volume, e com ele as
  > credenciais. Isso contraria a exigência de "um container por projeto, sem
  > volume compartilhado". O conserto é derivar o nome de algo único (o caminho
  > completo tem hash) em vez do basename, e ainda não foi feito.
- **Trilha de auditoria**: toda sessão de shell interativa é gravada em `$AGENT_LOG_DIR` (dentro do mesmo volume nomeado, fora do repositório) via `script` — útil pra revisar depois o que um agente autônomo executou de fato.

Os três itens acima descrevem **o que o template traz**, não o que ele garante.
O template é um arquétipo de agent sandbox, não é fronteira de host, e não deve
receber código não confiável. As lacunas conhecidas dele estão levantadas na
[#3](https://github.com/rvlmt/dotfiles-fedora/issues/3): base flutuante e antiga,
instaladores de CLI não pinados, auditoria que só cobre shell interativo, e
credencial compartilhando volume com os logs.

## O que este fluxo de devcontainer exige

O registro de risco do modo `label=disable` saiu do README quando a arquitetura
passou a ter a VM como fronteira, e a discussão foi para
[ARQUITETURA.md](ARQUITETURA.md). O que sobrevive são as **exigências de
operação** — e elas valem porque o fluxo depende delas, não porque o risco foi
aceito:

- **`podman.socket` desabilitado.** Nada expõe a API do engine por TCP ou socket.
  É o que permite rodar o Dev Container CLI com `--docker-path podman` sem
  reabrir uma superfície.
- **`userns=keep-id`** em `~/.config/containers/containers.conf`, para que o uid do
  container seja o uid real e um bind-mount continue pertencendo a quem o montou.
- **Credencial de agente fora do workspace montado.** `GH_CONFIG_DIR` e as
  credenciais de provider nunca dentro do repositório.
- **Um container por projeto, sem volume compartilhado entre projetos.** Ver a
  ressalva sobre o template, logo abaixo, sobre o nome do volume.

O que o registro de risco **não** era, e continua não sendo: este modo não é
confine SELinux, não é fronteira de host, e user namespaces rootless não isolam
o kernel.

## Runtime Node no host

O Node e o npm do host vêm do `mise`, com versão pinada — **não** do `dnf`. O
`setup.sh` não instala mais `nodejs`/`npm` de propósito, para que o runtime não
dependa da versão que o Fedora decidir empacotar a cada atualização:

```bash
mise use -g --pin node@24.21.0 devcontainer-cli@0.89.0
```

O consumo **baseline** é o Dev Container CLI, que é controller de host. O
`setup.sh` cria ainda `~/.local/bin/devcontainer` apontando para o shim do `mise`,
o que dá um atalho curto que funciona inclusive fora de shell interativo — situação
em que `mise activate` não se aplica, como em serviço systemd ou script.

Se você aceitou o módulo `ai-clis`, há consumo adicional, e ele é consequência
dessa escolha, não um invariante do host:

- `codex` e `ocx`/`opencodex` resolvem `#!/usr/bin/env node`,
  ou seja, o mesmo Node do mise. `claude`, `opencode` e `cursor-agent` são
  binários nativos e não usam Node.
- O instalador do `agy` cria o serviço `antigravity-cli-daemon`, que executa
  `npm exec` como filho. Serviço systemd não lê `~/.zshrc` nem o `~/.bashrc`, então
  o `setup.sh` cria um drop-in em
  `~/.config/systemd/user/antigravity-cli-daemon.service.d/10-mise-path.conf`
  para que ele encontre o mise. **É isso que permite remover o RPM `nodejs22*` com
  segurança** — remover antes quebraria o daemon.

Rollback de cada peça em [`ROLLBACK.md`](ROLLBACK.md), seções `ai-clis` e `base`.

### Ressalva: shim resolve por diretório

Os shims consultam a configuração do diretório em que são chamados. Dentro de um
repositório com `.tool-versions`/`mise.toml` próprios, `node` e `devcontainer`
resolvem a versão **daquele projeto**, e não o pin do host. Esse é o comportamento
desejado ao trabalhar em um projeto; por isso, quando o pin do host importar,
use a forma `mise exec ... --` da seção seguinte.

### O host não deve ter Node do dnf

Este repositório é o padrão, não um registro do que uma máquina específica fez. O
invariante é: **o Node do host vem do mise, e nenhum RPM `nodejs*` está
instalado.** O `setup.sh` não instala `nodejs`/`npm` justamente para que o
runtime não dependa da versão que o Fedora decidir empacotar.

Se um host tiver esses pacotes por outro caminho, a remoção precisa de `sudo` e
é de quem administra a máquina:

```bash
sudo dnf remove 'nodejs22*'
command -v node && node --version   # deve resolver para o shim do mise
```

Ordem importa, porque serviço systemd não lê `~/.bashrc` nem o `zshrc`: o daemon
do `agy` executa `npm exec` e precisa do PATH do mise por um drop-in em
`~/.config/systemd/user/antigravity-cli-daemon.service.d/10-mise-path.conf`, que
o `setup.sh` cria no módulo `ai-clis`. Remover o RPM antes disso quebra o daemon.
Rollback em [`ROLLBACK.md`](ROLLBACK.md).

## Dev Container CLI no host Fedora

O Dev Container CLI é a exceção deliberada, user-scoped, ao
container-first: é um controlador do host, não um toolchain de aplicação.
Esta seção não altera a arquitetura de execução dos agents. Os
devcontainers de aplicação não recebem credenciais nem CLIs de agent; o
template `agent-sandbox` é tratado separadamente.

A instalação é gerenciada e pinada pelo `mise`, incluindo um runtime Node
próprio para o CLI:

```bash
mise use -g --pin node@24.21.0 devcontainer-cli@0.89.0
mise exec node@24.21.0 devcontainer-cli@0.89.0 -- node --version
mise exec node@24.21.0 devcontainer-cli@0.89.0 -- devcontainer --version
```

Force as versões globais também nos comandos executados dentro de um
repositório, para que um `mise.toml` local não substitua o runtime do CLI:

```bash
mise exec node@24.21.0 devcontainer-cli@0.89.0 -- devcontainer up \
  --docker-path podman \
  --workspace-folder /caminho/do/projeto

mise exec node@24.21.0 devcontainer-cli@0.89.0 -- devcontainer exec \
  --docker-path podman \
  --workspace-folder /caminho/do/projeto \
  <comando-do-aplicativo>
```

O atalho `devcontainer` (symlink para o shim, criado pelo `setup.sh`) é
equivalente ao primeiro `mise exec` acima, **fora** de repositórios com
`.tool-versions`/`mise.toml` próprios. Dentro deles, o shim resolve a versão do
projeto — use `mise exec ... --` para não depender disso.

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
mise exec node@24.21.0 devcontainer-cli@0.89.0 -- devcontainer up \
  --docker-path podman \
  --workspace-folder "${WORKSPACE}"
```

Nenhuma etapa deste runbook deve ser automatizada com `rm` por wildcard:
os IDs revisados são parte do procedimento.

## Unidades criadas por instaladores de terceiros

Duas units da **VM de agentes** são criadas por instaladores, não pelo `setup.sh`:
`antigravity-cli-daemon.service` (do `agy`) e `opencode.service` (do opencode).
O instalador não consulta o padrão, então o que ele escrever é estado **sem dono
no repositório** — foi assim que o servidor do OpenCode ended up divergindo do
padrão, com um ajuste de escuta feito à mão e que um `setup.sh` em uma VM nova não
reproduziria.

O padrão declara as duas por drop-in, não editando a unit: assim uma reescrita do
instalador não desfaz o que o padrão quer, e as outras diretivas que ele define
(`PATH`, `Restart`, `TimeoutStopSec`) ficam intactas.

| Unit | Drop-in | O que declara |
|---|---|---|
| `antigravity-cli-daemon` | `…service.d/10-mise-path.conf` | o `PATH` do mise, para que o filho `npm exec` encontre o runtime |
| `opencode` | `…service.d/10-bind.conf` | o endereço de escuta, `OPENCODE_BIND:OPENCODE_PORT` |

A publicação na tailnet (`tailscale serve`) também é do padrão, e é declarada por
`setup_opencode_serve` — com a ressalva de que ela não sobrescreve o que já
estiver publicado.

Regra para o próximo instalador que criar uma unit: ou o padrão a declara, ou ela
vira passo manual documentado no README. O estado que ninguém possui é o que
gera divergência silenciosa entre o host e o padrão.

### Acesso remoto a serviços do host: loopback + tailnet

Regra do host, aplicável a qualquer serviço que precise ser alcançado de fora:

> **Escuta em loopback, publicação pela tailnet com HTTPS, em porta
> dedicada.**

`tailscale serve` faz a publicação e emite certificado para
`https://<host>.<tailnet>.ts.net/`. Isso é tailnet-only, não abre porta no
firewalld e não expõe na LAN.

O caminho alternativo — escutar em `0.0.0.0` e alcançar o serviço pelo IP da
tailnet — foi descartado. Além de incluir a interface WiFi local, alcançável por
qualquer máquina da mesma rede, ele entregava o serviço sem TLS. No lugar dele, o
OpenCode escuta em `127.0.0.1:49374` e a unit declara isso por drop-in.

#### Uma porta por serviço; a 443 fica reservada

Cada serviço escuta em loopback e é publicado em **porta HTTPS própria**. A 443
fica reservada: é o slot para o serviço que você quiser ter mais à mão — um painel,
não a ferramenta mais sensível.

| Serviço | Escuta | Publicação na tailnet | Auth da app |
|---|---|---|---|
| OpenCode | `127.0.0.1:49374` | `https://<host>.<tailnet>.ts.net:8443` | basic auth obrigatória — ver abaixo |
| _(reservado)_ | — | `:443`, para o próximo serviço | — |

Ao publicar um serviço novo: acrescente a linha na tabela com uma porta livre, e
não troque o que já existe. `setup_opencode_serve` não sobrescreve config de outro
serviço — se já houver algo publicado, avisa e devolve a decisão.

#### A senha do OpenCode é obrigatória, e o padrão a mantém estável

A senha do servidor **não é opcional** no OpenCode v2, apesar de a documentação
dizer que `OPENCODE_SERVER_PASSWORD` "habilita" o basic auth. O que o binário faz
é sempre escolher um valor:

- **com `--service`** (o que o instalador usa e o padrão preserva): a senha vem de
  `~/.config/opencode/service.json` e é **estável** entre restarts;
- **sem `--service`**: a senha vem de `OPENCODE_SERVER_PASSWORD` ou, se ela não
  existir, é **gerada aleatoriamente a cada start** e registrada no journal.

`UnsetEnvironment=OPENCODE_SERVER_PASSWORD` não desliga a autenticação — apenas
escolhe o caminho aleatório, o que invalida as credenciais já salvas no navegador
a cada reinício. Por isso o drop-in preserva `--service` de propósito.

Definir uma senha de sua preferência:

```bash
./setup.sh --profile=vm --only=ai-clis
# ou direto:
opencode service set password <a-sua-senha>
systemctl --user restart opencode
```

A senha é lida de `service.json` no start, então o restart é o que a aplica. Não
há como passá-la por stdin — `opencode service set` recebe o valor em `argv` —
por isso a leitura no `setup.sh` é silenciosa e apaga a variável assim que usa. O
histórico do shell não é afetado, já que o valor nunca é digitado como argumento.

Quem alcança a porta da tailnet ainda precisa dessa credencial: a API inclui ler
qualquer arquivo (`/api/file/content`) e **executar shell**
(`/api/session/:id/shell`), então trate a senha como chave de acesso ao host.

#### Por que porta, e não prefixo de caminho

Duas razões independentes, e as duas importam:

1. **Porta diferente é origem diferente.** Cookies, `localStorage` e CSP de um
   serviço não alcançam o que está em outra porta. Prefixo de caminho no mesmo
   hostname mantém a **mesma origem** e não isola nada — foi uma escolha
   minha anterior, e ela estava errada.
2. **O OpenCode não funciona fora da raiz.** A SPA é servida em qualquer path
   (o backend responde 200 em `/opencode`), mas as chamadas de API em caminho
   absoluto caem na raiz do host, onde não há handler, e a interface quebra com
   `Unrecognised route!`. Só a raiz da própria origem serve.

Se um dia um app tolerar prefixo e você quiser URLs sem porta, ainda assim prefira
porta: o isolamento de origem é propriedade de segurança, não de estética.

Aplicar mudanças de escuta ou publicação:

```bash
./setup.sh --profile=vm --only=ai-clis
systemctl --user restart opencode
tailscale serve status
```

A porta larga do firewalld (`1025-65535` na zona `FedoraWorkstation`) continua
registrada como pendência em
[#10](https://github.com/rvlmt/dotfiles-fedora/issues/10). Publicar pela tailnet
reduz a dependência dela, mas não fecha o problema para os outros serviços.

### `gh` é opcional; a base é git sobre SSH

O padrão para agentes é `git` sobre SSH: `clone`, `fetch`, `branch`, `commit`,
`push`, `diff` — sem token, sem keyring, sem estado que possa expirar. Push e
pull por SSH funcionam mesmo com o `gh` inválido, e é isso que o padrão garante.

O `gh` fica instalado pelo módulo `git` como **conveniência** para o que o `git`
não faz: abrir e fechar PR, mexer em issue, rodar `gh pr checks`, `gh run`. A
autenticação dele é interativa (`gh auth login`) e o token vive no keyring do
GNOME, que é um serviço de usuário — se o keyring não subir, o `gh` falha em
silêncio **sem** afetar o git.

Consequência prática: um agente sem `gh` autenticado pode trabalhar em branch e
subir código, mas **não** abre PR nem mexe em issue sem token. Se um fluxo
depender disso, é decisão consciente e não omissão.

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
