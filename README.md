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

## Testes

```bash
./tests/run.sh
```

⚠️ **A suíte só roda em sandbox, e o runner recusa fora dela** (`exit 2`). Ela
executa o `setup.sh` de verdade, e alguns scripts de teste usam `systemctl --user`
em serviços reais — numa máquina de trabalho isso para o que a pessoa está usando.
Um teste que quebra o sistema inteiro não é um teste, é um ataque ao ambiente que
o executa. No container:

```bash
podman run --rm -it -v "$PWD:/repo:Z" -w /repo docker.io/library/fedora:44 ./tests/run.sh
```

A suíte roda o `setup.sh` **de verdade**, com `sudo`, `dnf`, `podman`,
`systemctl`, `tailscale` e `gh` falsos no `PATH` e um `HOME` temporário: nada
toca a máquina. São **96 checagens** de eixos de perfil, forma do arquivo e do
bloco de chaves de dispositivo. O que ela **não** cobre está escrito em
[`tests/README.md`](tests/README.md), junto com o motivo — inclusive de dois
scripts que ficaram de fora por pararem serviços reais.

## Estrutura

- **`AUDITORIA.md`** — **comece por aqui para saber o que o script faz.** É o
  documento de auditoria e de reprodução manual: perfis e módulos, portas, o que
  cada um instala, o custo de disco de uma instalação limpa, o que exige mão
  humana, e as decisões conhecidas com o que cada uma custa. Toda tabela tem uma
  medição por trás, e onde o número é de uma máquina isso está marcado.
- **`pos-instalacao.md`** — o que fica **depois** do script: configurar o modelo
  do Hermes, instalar o gateway, verificar por estado, e o que fazer se der 401
  na UI. Nenhum item é instalação; são configuração e verificação.
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

## Passo 0. Provisionar uma VM de agentes nova

> O `setup.sh` **não provisiona a VM** — ele roda *dentro* de uma máquina que já
> existe. Este passo é o que faz a máquina existir com o repositório dentro, e ele
> vem antes do `setup.sh` por uma razão concreta: o repositório é lido por HTTPS,
> o que funciona numa máquina sem chave SSH nenhuma.

### O comando

Uma linha, na VM nova, no console do Cockpit:

```bash
curl -fsSL https://raw.githubusercontent.com/rvlmt/dotfiles-fedora/main/bootstrap.sh | bash
```

O `bootstrap.sh` traz o `setup.sh` e os **dois** arquivos de que ele depende —
`zshrc` e `bin/gh-app-token.sh` — e roda o provisionamento em seguida. Ele não
pede nada: todas as decisões que dependem de conta de terceiro ficam para o
depois, e o run diz quais são, com o comando de cada uma.

Depois, o **único** passo que precisa de você é entrar na tailnet, porque
`tailscale up` abre o navegador e a autenticação é da sua conta:

```bash
ssh <ip-da-vm-na-tailnet> 'sudo tailscale up'
```

### Por que só o Tailscale precisa de você

Das três coisas que este caminho atravessa, duas são automáticas e uma não é:

| passo | quem precisa | por quê |
|---|---|---|
| buscar o repositório por HTTPS | **ninguém** | o repositório é público; não há chave, token nem senha |
| `sudo tailscale up` | **você**, no navegador | autenticar uma conta na tailnet. É o mesmo motivo pelo qual `gh auth login` não roda sozinho: nenhum run não interativo tem navegador nem conta |
| o `setup.sh --defaults` | **ninguém** | não há decisão ali — o `--defaults` responde o default declarado de cada pergunta |

O passo do Tailscale é o único que **para e espera por você**, e ele diz isso na
tela. Todo o resto passa direto.

### O que esperar do `--defaults`

Ele responde o *default declarado* de cada pergunta, e os defaults são escolhidos
para que "aceitar tudo" signifique "provisionar". As duas coisas que ficam de fora
são as que dependeriam de um segredo ou de um navegador:

- a **GitHub App** fica inativa — a private key é um segredo que existe fora da
  máquina, e um App ID inventado marcaria o módulo como configurado sem funcionar;
- o **login de pessoa do `gh`** fica como pendência — `gh auth login` abre o
  navegador.

O run **diz as pendências no fim**, com o comando de cada uma, e sai com código
`1`. Isso não é alarme: é a lista do que falta, verificada por estado — o run
pergunta ao sistema se o serviço está no ar e se o container existe, e não se
confere o log do que ele acabou de dizer que fez.

```bash
# Se o run reclamou da App:
./setup.sh --profile=vm --only=gh-app
# Se reclamou do login de pessoa:
gh auth login -p https -w -s admin:public_key,read:user,user:email
```

### Por que o repositório é público

Para que a URL do `bootstrap.sh` seja estável e para que uma VM nova não precise
de nenhuma credencial para começar. O repositório é conferido antes de cada
publicação:

```bash
./tests/lib/auditoria-publica.py
```

A auditoria procura **material** e não nomes — um bloco PEM só conta se tiver
corpo, e token só conta se tiver formato. Ela mede o que está versionado e diz
quantos arquivos olhou, porque um diagnóstico que reporta "nenhum" sem ter medido
nada é o pior resultado possível: é verde, e está errado.

O que é público não é segredo: é convenção de nomenclatura, portas internas e o
domínio da sua tailnet, que só é alcançável por quem está nela.

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
   2. `hostname` — Mostra o hostname atual e pergunta se quer alterá-lo, já na fase de coleta. **A sugestão vale para os dois perfis**, e o default passa a ser um nome gerado: **`<papel>-<os>-<4 do machine-id>`**. Medido: perfil `vm` + `/etc/os-release` com `ID=fedora` + `machine-id` começando em `c104` → **`vm-fedora-c104`**; neste host, perfil `host` → **`pc-fedora-4bd9`**. As três camadas são o que o nome afirma: **que papel** a máquina cumpre, **de que sistema**, e **qual delas**. **O papel vem do perfil, e essa foi uma simplificação deliberada.** O systemd poderia detectar o hardware — e detecta bem: medido, `hostnamectl status` diz `desktop` nesta máquina e `vm` na VM, e o `systemd-detect-virt` diz `none` e `qemu`. A razão de não ir por aí é que **o perfil já é a declaração** de que papel a máquina cumpre, e ele está digitado na linha de comando; detectar o hardware é redescobrir o que a pessoa acabou de dizer, e o resultado é um nome que discorda do perfil quando os dois divergem. O `DDMM` da proposta inicial saiu por não acrescentar nada sobre um id que já é único, e por mudar com o dia — o que faria um re-run no dia seguinte propor outro nome para uma máquina já correta. O `product_uuid`, que seria o identificador natural por ser o do hypervisor, é **ausente** nas duas máquinas. O módulo **reconhece o próprio esquema** e, numa máquina já nomeada, não pergunta — e reconhecer e não perguntar são coisas diferentes: uma versão anterior reconhecia e perguntava assim mesmo, com a resposta vazia caindo como se fosse um nome. O nome é validado antes de aplicado (RFC 1123: minúsculas, dígitos e hífen, sem ponto, até 63 caracteres), porque depois já é tarde: o nome entra no registro do sistema. **O módulo não renomeia o nó da tailnet, e nunca vai**: renomeado o nó, as três publicações do `tailscale serve` ficam chaveadas no nome antigo e o TLS morre no handshake — e o check de "já publicado" não perceberia, porque compara o *backend* e não o nome. Numa máquina nova o `tailscale` ainda não conectou quando este módulo roda, então não há o que renomear: o `up` posterior já pega o hostname novo. Em máquina já provisionada o nome do nó é estado da pessoa, e o script só **relata** a divergência, com o preço de reconciliar apontado para a seção abaixo.  **[ambos]**
   3. `ssh` — Gera chave SSH Ed25519 e a usa pra autenticar esta máquina no GitHub (`gh ssh-key add`) — não confundir com autorizar OUTRAS máquinas a entrar aqui via SSH, que é manual (passo 2 abaixo).  **[ambos]**
   4. `device-keys` — Autoriza nesta máquina as chaves públicas dos dispositivos que o GitHub reúne, via `github.com/rvlmt.keys`, num **bloco gerenciado** delimitado por comments no `~/.ssh/authorized_keys`. **Pergunta no bloco inicial, com default SIM** (`[Y/n]`): um Enter autoriza. O default é sim porque a fonte é pública e não depende da GitHub App, e porque é a chave que o `sshd-hardening` exige para poder desligar a senha. Quem não quiser digita `n`, e o `authorized_keys` não é tocado. Reescreve só o que está entre os delimitadores e preserva a ordem original do resto do arquivo; **tudo fora do bloco fica intocado**, porque o `authorized_keys` do host tem uma chave que o GitHub não conhece — a de um Mac — e tratar o arquivo como espelho do feed a trancaria fora. Tira do bloco a chave da própria máquina, que aparece nele porque o módulo `ssh` registra a chave do servidor no GitHub com `gh ssh-key add`; sem isso o servidor se autorizaria a si mesmo a entrar nele. **A revogação é real, mas indireta e diferida**: sai-se a chave da conta, e ela perde o acesso na próxima execução deste módulo — a saída lista as revogadas. Valida a resposta antes de escrever: um `>>` cego num 404 ou num html de proxy escreveria lixo no arquivo que decide quem entra, e o `sshd` leria esse lixo sem reclamar. Fecha com `chmod 700` no `.ssh`, `600` no arquivo e `restorecon`, que **sem `sudo`** resolve o contexto — medido: as duas máquinas estão com SELinux Enforcing, e contexto errado faz o `sshd` recusar a chave sem explicar o motivo. **A fonte é um arquivo público** — sem token, sem GitHub App e sem `gh` autenticado, medido: HTTP 200, 405 bytes, 5 chaves ed25519.  **[ambos]**
   5. `git` — O login de pessoa do `gh` é **opt-in**: responder `y` na pergunta do bloco inicial faz o `gh auth login -w` pelo navegador; responder nada deixa o `gh` sem token próprio, porque a GitHub App já cobre a API dos agentes. A consequência é que a chave SSH da máquina **não** é registrada no GitHub — registrar chave é `POST /user/keys`, um endpoint de usuário que um token de instalação não alcança — e o módulo diz isso na hora. Configura `git config --global` e autentica o `gh`, enviando a chave pública.  **[ambos]**
   6. `podman` — Instala Podman rootless, configura subuid/subgid, habilita linger (containers sobrevivem ao logout/desconexão de SSH) e configura `userns=keep-id` (`~/.config/containers/containers.conf`) — sem isso, processos rodando como "root" dentro de um container não conseguem escrever em bind-mounts que pertencem ao seu usuário real.  **[guest]**
   7. `gh-app` — **Pergunta no bloco inicial, sem `y/N`**: pede o App ID e a private key, e grava os dois em `~/.config/gh-app/` com permissão `600`. Instala o `gh-app-token`, que assina um JWT RS256 com a private key e o troca por um token de instalação — o `gh` não faz login como App, e é por isso que o token vira `GH_TOKEN`, que tem precedência sobre credenciais guardadas. Instala também o wrapper `gh-app`, que obtém um token por comando e o descarta; o token vive **uma hora**, e a pós-condição do módulo é a API respondendo, não o arquivo existindo. **Não vai para o shell rc de propósito**: mintar a cada shell aberto seria uma chamada de API por terminal. É do guest porque é lá que os agentes rodam, e é de lá que eles abrem PR, escrevem issue e comentam. Sem App ID ou sem chave, o módulo fica inativo e o `gh` volta a pedir login.  **[guest]**
   8. `tailscale` — Adiciona o repo oficial da Tailscale via `dnf config-manager` e instala via `dnf` (não usa `curl | sh`), conecta com `tailscale up` (sem `--ssh` de propósito — ver nota abaixo). Assume DNF5 (padrão desde o Fedora 41).  **[ambos]**
   9. `sshd-hardening` — Desabilita login por senha e login root via SSH, e **trava a senha do root** com `passwd -l`. **Pede confirmação** (no início, junto com as outras), e o default **depende do perfil**: `[Y/n]` na VM, `[y/N]` no host. A assimetria é deliberada — na VM este script é a história inteira e a senha do SSH é a credencial mais exposta da máquina; no host é a máquina de todo dia, e desligar o login por senha é decisão de quem trabalha nela. Em nenhum dos dois a resposta é o que evita o trancar: quem protege é o guard do `authorized_keys`, que pula com aviso se o arquivo estiver vazio. Recusa aplicar o desligamento de senha (avisa e pula) se `~/.ssh/authorized_keys` estiver vazio — ver passo 2 abaixo, senão você fica sem nenhum jeito de entrar via SSH. A trava do root tem guarda própria e mais frouxa: ela só acontece se já existir um usuário não-root com shell de login, e a pergunta sai sem privilégio nenhum (o bloco de perguntas roda antes do `sudo -v`, e ler `/etc/passwd` dispensa qualquer elevação). Travar, e não endurecer: a senha do root não é caminho para nada que o `sudo` não cubra, então deixá-la ali é manter uma credencial sem propósito. Destravar é `sudo passwd -u root`, e o `ROLLBACK.md` avisa que isso só funciona se você souber qual era a senha.  **[ambos]**
   10. `firewalld` — Instala, sobe no boot, e **verifica que a zona em que a `tailscale0` caiu permite `ssh`**. A interface **não** é marcada como confiável: a marcação na zona `trusted` foi removida em 2026-09-30, e quem quiser ela roda o comando à mão (o script imprime qual é). Medido: o `firewalld` não filtra as portas do `tailscale serve`, então a `trusted` nunca esteve segurando a publicação — a zona padrão do Fedora já abre `1025-65535/tcp`. **Pendente:** a rede do libvirt com o filtro de egress, que a [ARQUITETURA.md](ARQUITETURA.md) decide que este repo deve declarar — ver "Ordem de implementação".  **[host e vm]**

   **Por que não usar o Tailscale SSH (`tailscale up --ssh`)**: ele exige reautenticação interativa via navegador sempre que a política da tailnet tiver `action: check` nos grants de SSH (o default da maioria das tailnets) — quebra qualquer ferramenta que não sabe abrir um navegador (Codex Desktop, devpod rodando não-interativamente, cron, etc.), e o próprio Tailscale avisa incompatibilidade com SELinux enforcing no Fedora. O acesso SSH real já é coberto por `sshd-hardening` (só chave, sem senha) + `firewalld` (sshd só na interface `tailscale0`) — chave clássica, sem nenhuma reautenticação. Se você já rodou uma versão anterior deste script com `--ssh`, desative com `sudo tailscale set --ssh=false`.

   11. `vm-host` — Instala `libvirt-daemon`, `libvirt-client`, `virt-install`, `qemu-kvm` e `cockpit-machines`; coloca o usuário no grupo `libvirt` e habilita o `cockpit.socket`. É onde a VM de agentes vai ser criada e gerenciada. **Não declara a rede do libvirt** — ver [ARQUITETURA.md](ARQUITETURA.md), pendência de rede do host.  **[host]**
   12. `toolbx` *(opcional, não roda por padrão)* — Sandbox Podman rápida para mexer em algo fora do contexto de um projeto/devpod. Rode com `--only=toolbx`.  **[host]**
   13. `gui-access` *(opcional, não roda por padrão)* — Habilita o GNOME Remote Desktop nativo (RDP via `grdctl`), já que o Fedora é uma Workstation completa (AIO dedicado) e às vezes vale controlar direto com tela. Rode com `--only=gui-access`; depois defina uma senha com `grdctl rdp set-credentials <usuario> <senha>` e conecte via um cliente RDP no Mac.  **[host]**
   14. `desktop-apps` — Equivalente ao Brewfile do Mac. Cada app foi checado individualmente contra fonte oficial antes de decidir instalar ou não (ver `ROLLBACK.md`/comentários no script pra fontes exatas):  **[host]**
       - **Instalados automaticamente** (fonte oficial confirmada, funciona no Fedora): VS Code (repo Microsoft), Google Chrome (RPM oficial), Brave (repo oficial), Zed (script oficial), Antigravity IDE (repo rpm oficial do Google), Cursor (AppImage oficial), OpenCode Desktop (RPM oficial), Transmission (repo do Fedora).
       - **Genuinamente sem versão Linux** (confirmado oficialmente, sem alternativa real): Adobe Creative Cloud, Raycast, OpenUsage, OrbStack, Rectangle (GNOME já tem tiling nativo), Arc (nunca suportou Linux), AppCleaner e Pearcleaner (resolvem um problema específico do modelo de "bundle" do macOS que não existe no Fedora).
       - **Têm app oficial pra Linux, mas sem Fedora/rpm ainda**: Claude Desktop (só .deb, Ubuntu/Debian), ChatGPT Desktop (tem rpm oficial pro Fedora, mas em preview com bug conhecido de assinatura — manual se quiser).
       - **Oficial só via Docker/Podman Compose** (não é app desktop nativo): Open Design.
       - **Sem app oficial, só opção não-oficial/não-verificada de terceiros** (não instalada automaticamente, decisão sua): GitHub Desktop, Notion, Figma, Spotify e Termius (os Flatpaks desses dois últimos são "Unverified"/não afiliados no Flathub, apesar de populares), FontBase (AppImage oficial existe, mas sem link "sempre atual" estável), Surfshark (sem suporte oficial a Fedora), Ghostty (só via COPR de terceiros).
       - devpod tem binário Linux oficial, mas não é instalado aqui — ele roda do lado Mac controlando este servidor.
   15. `ai-clis` — **Pergunta antes de aplicar**: CLIs de IA (Claude Code, Codex, Cursor Agent, Open Code, Antigravity CLI, DeepSeek Harness). O Open Code vem do **canal v2**, instalado por `opencode.ai/v2/install` — a linha 1 fica em `opencode.ai/install`, e a v1 não tem o subcomando `service` que o próprio script usa para definir a senha do servidor. **Não há pin de versão**: o módulo consulta o mesmo endpoint público que o instalador consulta (`opencode.ai/update/api/latest/cli/npm`) e só roda o instalador quando a resposta difere do que está instalado, de modo que a máquina fica na v2 mais nova sem baixar nada quando já está nela. A major é travada em 2 — se o canal apontar para outra, o módulo para e avisa em vez de trocar. Ver "Runtime do OpenCode". É do guest porque é lá que os agentes rodam; dentro da VM é também onde o servidor do OpenCode, a escuta em loopback e a publicação na tailnet são declarados.  **[guest]**
   16. `opencodex` — Instala a CLI do OpenCodex (`@bitkyc08/opencodex`), um proxy universal de provider que fica no caminho das requisições de modelo. **Pergunta antes de aplicar, com pergunta própria** — separada da do `ai-clis`, porque não é uma CLI local como as seis de lá. É do perfil `host` e serve o uso pessoal: os agentes dentro da VM não o recebem, cada um usa a credencial do provider direto.  **[host]**
   17. `zshrc` — Torna o `zsh` o shell de login da máquina: instala `zsh`+plugins via `dnf`, linka o `zshrc` versionado deste repo e roda `chsh`. Participa da execução normal sem confirmação. A única confirmação é sobre substituir um `~/.zshrc` que já exista e não seja o link deste repo (o atual é salvo como backup).  **[ambos]**

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
   iPhone, etc). Dois caminhos, e eles se combinam:

   **Automático, pelo módulo `device-keys`** — registre a chave pública do
   dispositivo na sua conta do GitHub e rode o script. Ele lê
   `github.com/rvlmt.keys` e reescreve o bloco gerenciado do `authorized_keys`.
   Cada dispositivo se registra em <https://github.com/settings/keys>.

   **Manual, para o que o módulo não cobre** — chaves que não devem passar pela
   conta do GitHub, ou um aparelho que você não quer registrado lá. O script
   gera/usa uma chave SSH só pra autenticar *este servidor* no GitHub; ele não
   copia a chave pública de outras máquinas pra cá:

   ```bash
   # No dispositivo cliente, copie a saída (ex.: no Mac):
   cat ~/.ssh/id_ed25519.pub

   # Aqui no Fedora (fisicamente, ou por qualquer sessão que já funcione):
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   echo "<cole a chave pública do dispositivo aqui>" >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   restorecon -Rv ~/.ssh   # SELinux enforcing no Fedora — evita rótulo errado bloquear a checagem da chave pelo sshd
   ```

   Só é preciso se você respondeu **não** ao módulo `device-keys`. O caminho normal
   é o contrário: o `device-keys` roda **antes** do `sshd-hardening` na lista dos
   dois perfis, e o `authorized_keys` já está populado quando a pergunta do
   hardening é feita. E o módulo se recusa a desligar a senha se o arquivo estiver
   vazio, que é exatamente para não ficar sem nenhum jeito de entrar via SSH.

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

O Node e o npm do host vêm do `mise`, **não** do `dnf`. O `setup.sh` não instala
`nodejs`/`npm` de propósito, para que o runtime não dependa da versão que o
Fedora decidir empacotar a cada atualização.

⚠️ **Nenhuma versão é pinada por número, e isso é decisão.** O script usa:

```bash
mise use -g node@lts devcontainer-cli@<última>
```

O Node acompanha o alias **`lts`**, e não `latest`: `lts` é a linha de suporte
estendido, que é o que um runtime de host quer, enquanto `latest` traz major novo
com frequência. Medido: `node@lts` e `node@24` resolvem para a mesma versão, e
`@latest` **não é alias no mise** — devolve vazio.

O `devcontainer-cli` **não tem alias nenhum**: `ls-remote` devolve vazio para
`@latest` e para `@lts`, então a última versão real é lida do registro, e a
constante `MISE_DEVCONTAINER_FALLBACK` cobre o caso sem rede.

Um pin fixo tem um custo que só aparece tarde: se a versão sair do registro,
`mise install` falha e, como a chamada não tem `|| true`, o módulo `base` inteiro
cai sem dizer qual versão deixou de existir. Acompanhar a última troca esse modo
de falha por um que não existe. O `--pin` também saiu de propósito — ele grava a
versão **resolvida** num config local, e é exatamente o número fixo que a decisão
remove.

O consumo **baseline** é o Dev Container CLI, que é controller de host. O
`setup.sh` cria ainda `~/.local/bin/devcontainer` apontando para o shim do `mise`,
o que dá um atalho curto que funciona inclusive fora de shell interativo — situação
em que `mise activate` não se aplica, como em serviço systemd ou script.

⚠️ **Dentro de um projeto com `mise.toml` ou `.tool-versions` próprios, o shim
resolve o runtime daquele diretório**, não o do host. Para forçar o do host, use
a forma `mise exec`:

```bash
mise exec node@lts -- node --version
mise exec devcontainer-cli -- devcontainer --version
```

Se você aceitou o módulo `ai-clis`, há consumo adicional, e ele é consequência
dessa escolha, não um invariante do host:

- `codex` e `ocx`/`opencodex` resolvem `#!/usr/bin/env node`, ou seja, o mesmo
  Node do mise. `claude`, `opencode` e `cursor-agent` são binários nativos e não
  usam Node.
- O instalador do `agy` cria o serviço `antigravity-cli-daemon`, que executa
  `npm exec` como filho. Serviço systemd não lê `~/.zshrc` nem o `~/.bashrc`, então
  o `setup.sh` cria um drop-in em
  `~/.config/systemd/user/antigravity-cli-daemon.service.d/10-mise-path.conf`


## Dev Container CLI no host Fedora

O Dev Container CLI é a exceção deliberada, user-scoped, ao
container-first: é um controlador do host, não um toolchain de aplicação.
Esta seção não altera a arquitetura de execução dos agents. Os
devcontainers de aplicação não recebem credenciais nem CLIs de agent; o
template `agent-sandbox` é tratado separadamente.

  A instalação é gerenciada pelo `mise`, incluindo um runtime Node próprio
  para o CLI — sem pin de número, como o resto do host:

```bash
  mise use -g node@lts devcontainer-cli@<última>
mise exec node@lts -- node --version
mise exec node@lts -- devcontainer --version
```

Force as versões globais também nos comandos executados dentro de um
repositório, para que um `mise.toml` local não substitua o runtime do CLI:

```bash
mise exec node@lts -- devcontainer up \
  --docker-path podman \
  --workspace-folder /caminho/do/projeto

mise exec node@lts -- devcontainer exec \
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

O CLI da série `0.8x` não oferece um `down` completo. O cleanup usa o label
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
mise exec node@lts -- devcontainer up \
  --docker-path podman \
  --workspace-folder "${WORKSPACE}"
```

Nenhuma etapa deste runbook deve ser automatizada com `rm` por wildcard:
os IDs revisados são parte do procedimento.

## Unidades criadas por instaladores de terceiros

**Só uma** unit da VM de agentes é criada por instalador:
`antigravity-cli-daemon.service`, do `agy`. O instalador não consulta o padrão,
então o que ele escreve é estado **sem dono no repositório**.

O `opencode` **não cria unit nenhuma** — e isso não é impressão. Na v2,
`opencode service start` executa `opencode serve --service` como filho
`detached`, com `stdio` ignorado e `unref`; não há caminho de `systemd` em todo o
código do projeto. Medido na VM: o processo aparece com `ppid=1`, e o systemd
responde *"PID 91628 does not belong to any loaded unit"*. **Esse processo não
volta depois de um reboot**, e nada no padrão o recria.

O caminho documentado é o oposto do que o padrão fazia: uma unit escrita à mão,
rodando `opencode serve` em **primeiro plano**. E há uma consequência que muda o
resto: em modo foreground o `serve` **ignora `~/.config/opencode/service.json`**,
então `hostname` e `porta` têm de vir de flag, e a senha, de variável de ambiente.
Ver "OpenCode em uma VM nova", abaixo.

O padrão declara as duas por drop-in, não editando a unit: assim uma reescrita do
instalador não desfaz o que o padrão quer, e as outras diretivas que ele define
(`PATH`, `Restart`, `TimeoutStopSec`) ficam intactas.

| Unit | Drop-in | O que declara |
|---|---|---|
| `antigravity-cli-daemon` | `…service.d/10-mise-path.conf` | o `PATH` do mise, para que o filho `npm exec` encontre o runtime |
| `opencode` | — (nenhum) | A unit é **declarada** por `setup_opencode_service`, não lida de instalador: a v2 não cria nenhuma. Não há drop-in porque não há o que sobrepor — a escuta e a senha vão para `~/.config/opencode/service.json` via `service set`. Ver "OpenCode em uma VM nova". |

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

| Serviço | Escuta | Publicação | Auth da app |
|---|---|---|---|
| OpenCode | `127.0.0.1:49374` | `:8443` | **só a API** é basic auth; a página é pública |
| OpenDesign | `127.0.0.1:7456` | `:8444` | basic auth com `OD_API_TOKEN`; o 401 é texto puro |
| **Hermes** (dashboard) | `0.0.0.0:9119` | `:8445` | **hash scrypt** no `config.yaml`; a senha em texto puro fica num arquivo 600 do usuário. `/` responde 302 para `/login` |
| _(reservado)_ | — | `:443`, para o próximo serviço | — |

#### O que cada link mostra de fato

Verificado abrindo os três endereços num navegador de verdade, e não por `curl`.
A diferença entre o que a tabela diz e o que aparece na tela é o que vale aqui:

| link | o que o navegador mostra |
|---|---|
| `:8443` | a UI do opencode, com o endereço já preenchido e um campo **"Senha (opcional)"** |
| `:8444` | **tela em branco** — o 401 não vira interface |
| `:8445` | a tela de login do **Nous Portal**, com e-mail, Google, Microsoft e GitHub |

⚠️ **No opencode, a página é pública e o que exige basic auth é a API.** A página
responde **200** sem credencial nenhuma — o *fallback* da SPA entrega o mesmo shell
para qualquer caminho. O portão está no namespace `/api/`, e a rota que o mede é
`/api/session`: **401** sem senha, **200** com ela. É o inverso do que a tabela dizia
antes, e a distinção importa: quem publicar a porta e testar o caminho errado vai
concluir que o servidor está aberto.

⚠️ **O campo da senha diz "(opcional)" e não é.** A senha é a única coisa que separa
a página pública de uma sessão funcional, e o rótulo é do upstream — não dá para
corrigir daqui. O efeito prático: seguir a tela ao pé da letra leva a conectar e a
receber 401 da API, e parece defeito da publicação quando é defeito do rótulo.

⚠️ **O 401 do OpenDesign é texto puro, e o navegador não mostra texto puro.** O
corpo é `OpenDesign authentication required. Use username "open-design" and
OD_API_TOKEN as the password.`, com `www-authenticate: Basic realm="OpenDesign"`.
O Chrome renderiza isso como **página em branco** — sem a dica, sem o 401, sem
nada. Quem for pela primeira vez precisa saber o par de antemão; o servidor nunca
vai dizer na cara que a credencial é a do `.env`.

#### Qual rota medir, e por que 200 às vezes não quer dizer nada

Medido, porque a versão anterior desta seção **afirmava um 401 que ninguém tinha
medido** — o par "401 sem credencial, 200 com" foi extrapolado de um padrão em vez de
verificado. A sonda que separa as duas coisas é **`/api/session`**: **401** sem
senha, **200** com ela.

O que existe de fato, em duas metades que não se confundem:

| rota | sem credencial | com credencial |
|---|---|---|
| `/api/session` | **401** | **200** |
| `/api/health` | 401 | **404** |
| `/api/doc` | 401 | **404** |
| qualquer coisa fora de `/api/` | 200 | 200 |

Duas leituras, e a segunda é a que quase me levou a escrever um achado falso:

**O namespace `/api/` é o portão, e funciona.** `/api/health` e `/api/doc` devolvem
401 sem credencial e **404** com ela — a rota realmente não existe, e o 401 era a
camada de auth recusando antes do roteador. Os dois números mediam a mesma coisa, e
`/api/health` nunca podeu ser prova de que o servidor servia.

⚠️ **Fora de `/api/`, todo 200 é a mesma página, e isso não é dado nenhum.** `/`,
`/config`, `/project`, `/agent`, `/file`, `/log` — e também uma rota inventada na
verificação — devolvem **o mesmo HTML de 5986 bytes**, com o mesmo `sha256`. É o
*fallback* da SPA, que entrega o shell para qualquer caminho. Um `200` ali não é
exposição **e** não é prova de nada: precisa comparar o corpo, não o status. Foi
exatamente por ler só o status que pareceu que `/config` estava servindo a
configuração do servidor sem senha.

A distinção final, que é a que importa para a tabela: **a página é pública e o que
exige basic auth é a API.** Isso continua valendo — mas a rota que o demonstra é
`/api/session`, e não `/config`, que só devolve o shell.

No OpenDesign e no Hermes `/api/health` existe e responde **200**, o que aumenta a
confusão: o mesmo caminho é válido em um serviço, inexistente no outro e enganoso no
terceiro.




As três publicações vivem na **VM de agentes**, no mesmo nó, e todas seguem a mesma
forma: escuta em loopback + `tailscale serve` com TLS. As portas são **uma por
serviço, em sequência**, para que a tabela fique legível — e `8443` é o opencode nos
dois nós, host e VM.

⚠️ **A faixa 8443–8444 é do `serve`, não das aplicações.** Nenhuma aplicação
escuta nesses números: são portas do `tailscaled`, e cada uma faz proxy para o
loopback da aplicação. Duas camadas, e o número publicado vem do namespace do
`serve` — não do interno. A consequência prática: se uma aplicação voltar a
escutar em `0.0.0.0` na porta interna, **não** colide com a publicação, e o
conflito fica explícito em vez de virar diagnóstico confuso.

⚠️ **Para desligar uma publicação, use `serve --https=<porta> off`, nunca
`serve reset`.** As publicações ficam lado a lado, e o reset derruba as outras
junto. Foi o que quase aconteceu com o `8445` ao remover o container do Hermes.

⚠️ **O bind do Hermes tem uma assimetria que os outros dois não têm.** O dashboard
só exige login quando escuta **fora** do loopback, então `--host 127.0.0.1` publicado
por `serve` serviria a tailnet inteira **sem auth**. A solução é tornar as duas coisas
independentes: `--host 0.0.0.0` **dentro do container**, que engata o gate, mapeado
só para o loopback do host com `-p 127.0.0.1:9119:9119`, que mantém a LAN de fora.
Verificado: `/` responde **302** para `/auth/login`, e `192.168.122.181:9119` está
**fechada**.

Ao publicar um serviço novo: acrescente a linha na tabela com uma porta livre, e
não troque o que já existe. `setup_opencode_serve` não sobrescreve config de outro
serviço — se já houver algo publicado, avisa e devolve a decisão.

#### A senha do OpenCode é obrigatória, e o padrão a mantém estável

A senha do servidor **não é opcional** no OpenCode v2. O binário sempre escolhe um
valor:

- **com `--service`**: a senha vem de `~/.config/opencode/service.json` e é
  **estável** entre restarts — o código reutiliza a guardada e só gera 32 bytes
  aleatórios quando não existe nenhuma. Esse é o único caminho em que a senha é
  persistida, e é o que o padrão deve preservar;
- **sem `--service`** (foreground): a senha vem da variável **`OPENCODE_PASSWORD`**,
  ou é gerada aleatória a cada start e impressa no stdout.

`OPENCODE_SERVER_PASSWORD` **ainda funciona**, mas é o nome **legado** — o atual
é `OPENCODE_PASSWORD`, e o antigo é aceito como alias. Em modo `--service` a
variável de ambiente é **ignorada por completo**: a senha vem do arquivo, e o CLI
ainda remove as duas do ambiente que entrega ao processo que cria. Por isso não é
`UnsetEnvironment=` com essas variáveis que mantém a senha estável — é
`--service` que mantém, e o arquivo que guarda.

Trocar a senha invalida todas as sessões abertas; elas duram 30 dias.

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

### Hermes — documentado, não instalado

**Nenhuma das duas rotas foi executada.** O que está aqui é a análise de custo de
cada uma, para a decisão ser sua antes de algo entrar no host. A Nous Research
publica os dois caminhos como pares de primeira classe, e a documentação **não
recomenda um sobre o outro**.

**O que é.** Um harness de agente autônomo, não um copilot de código: tem
interface de terminal, memória e skills que persistem entre sessões, agendador
`cron`, delegação a subagentes, e um gateway que o expõe em ~20 plataformas de
mensagem. O diferencial declarado é um ciclo de aprendizado fechado, com o agente
curando a própria memória e criando skills depois de tarefas complexas. 60+
ferramentas, cliente MCP, e 7 backends de execução de shell. MIT, repo
`NousResearch/hermes-agent`.

#### Rota A — `install.sh`, a escolhida, e as quatro guardas que ela custou

A doc oficial oferece esta rota primeiro, e é a que o módulo `hermes-cli` roda:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
  | bash -s -- --non-interactive --branch "$HERMES_CLI_TAG"
```

E o que ele **de fato** faz, lido no script: **não baixa binário do agente, não
instala por pip/npm/cargo, não puxa imagem, e não sobe serviço.** Ele faz
`git clone --filter=tree:0` do repo, baixa um **`uv` 0.12.3 pinado com sha256
verificado**, deixa o gerenciador do próprio projeto (`pm`, com `uv.lock`)
resolver as dependências sobre um **Python 3.14 gerenciado**, e compila a
fonte. Nenhuma chamada a `docker` ou `podman` no script inteiro.

⚠️ **As quatro objeções a esta rota continuam sendo verdade, e as quatro viraram
guardas no `setup.sh`.** Elas não sumiram por ignoradas — cada uma está escrita
como comentário no ponto do código que a neutraliza, que é o jeito de não perder
a medida:

| objeção | o que o módulo faz |
|---|---|
| **trava sob pty** — os estágios `setup` e `gateway` leem `/dev/tty` e só se pulam quando `/dev/tty` **não abre** | passa **`--non-interactive`**, obrigatório e não conveniência: o `setup.sh` roda sob pty, então `/dev/tty` abre e sem a flag o passo **não termina** |
| **instalar não é configurar** — o install novo tem `model: ""`, sentinela explícita de "ainda não configurado", e `LLM_MODEL` não é mais lido do `.env` | nenhum instalador faz isso; o módulo avisa quando `~/.hermes/auth.json` está sem provider, e `hermes config set model.provider` / `model.default` é passo posterior |
| **não é idempotente** — a segunda execução é um *update*: `git merge --ff-only`, e quando não dá, `git reset --hard origin/main` | o módulo **pula o instalador** quando `git describe --tags` já é a `HERMES_CLI_TAG`, então o ciclo de update nunca roda sozinho |
| **escreve nos rc do shell** — acrescenta uma linha de `PATH` em `~/.zshrc` | medido: a guarda `append_shell_path` do instalador casa com a linha 11 do `zshrc` versionado deste repo, então **não escreve**. Sem isso, escreveria dentro do arquivo do repo |

O que ela **não** sobrescreve, e isso é bem feito: `~/.hermes/.env` e
`config.yaml` só são criados se ausentes, e o instalador **para** se o
`git stash` falhar em vez de descartar trabalho.

O lado bom que existe: o instalador expõe um protocolo de estágios de verdade —
`--manifest` imprime a lista em JSON com `needs_user_input`, `--stage NOME` roda
um isolado, `--commit SHA` fixa a revisão (validada por ancestralidade antes do
checkout). O cabeçalho do script diz que esse protocolo *"kept for Hermes-Setup"*,
isto é, existe um driver externo que já o consome. Vale registrar que o módulo
**não** usa esse protocolo: ele usa o `curl | bash` de uma vez, e é a
`--non-interactive` que mantém isso terminando.


#### Rota B — imagem oficial

**Docker Hub, não GHCR.** O caminho `ghcr.io/nousresearch/hermes-agent` que
circula em guias de terceiros **não é publicado**; a doc oficial só menciona
`nousresearch/hermes-agent`. Tags `latest`, `stable`, `main` e versionadas
(`v2026.9.24`), ~950 MB, `linux/amd64` e `linux/arm64`, base `debian:13.4`, com
`docker-compose.yml` de primeira parte no repo. A doc descreve o estado como um
único mount em **`/opt/data`** (o `~/.hermes` do host), com `/opt/hermes`
read-only e `hermes update` recusando alteração de código da imagem.

⚠️ **O `state.db` é SQLite em modo WAL, e há uma armadilha de corrupção.** A doc
avisa que `virtiofs` e `9p`/drvfs **deixam escritores concorrentes corromper um
banco WAL silenciosamente, e o `PRAGMA integrity_check` ainda passa**. Num volume
nomeado no ext4 da VM isso não se aplica; num bind mount de `~/.hermes` sobre
`virtiofs`, sim. Vale a regra: **volume nomeado, nunca bind mount** — e por
extensão, nunca dois containers gateway contra o mesmo diretório de dados, que não
tem lock nem detecção.

#### Autenticação

Só um caminho é automatizável. **BYO API key em `~/.hermes/.env`** (a `600`, que
o instalador cria a partir do `.env.example`), mais `model.provider` e
`model.default` no `config.yaml`.

O caminho que a doc chama de recomendado — Nous Portal por OAuth — é **device
code**: o Hermes imprime uma URL, **uma pessoa** abre no navegador e aprova, e o
processo faz polling. Sem túnel, mas com navegador e com gente. Não há fluxo
documentado de device code automatizado, nem injeção de token não interativa.

Duas coisas da doc que valem porque são defaults seguros: o dashboard **falha
fechado** em bind fora do loopback sem um provedor de auth registrado — e a
`HERMES_DASHBOARD_INSECURE` virou **no-op depreciado**, removida depois que
*"scanners de internet alcançaram dashboards expostos e drove the agent into
planting an SSH-key backdoor"*. E a API server é desligada por padrão, exigindo
`API_SERVER_KEY` para sair do loopback.

#### Antes de fixar qualquer versão

O PyPI lista **dois avisos sem correção publicada** (`fixed_in: []`), um de
injeção em `_compress_context` e outro de consumo de recursos em
`_handle_webhook_request`, e o fornecedor não respondeu à divulgação. Pode ser
metadata obsoleta — o `pyproject.toml` da árvore main tem pinagem pesada e
datada por CVE — mas para deploy automatizado convém checar contra a versão exata
que se pretende fixar, e não confiar só no aviso.

E os registries divergem entre si: PyPI em `0.19.0`, npm em `0.21.5`, as tags
docker em `v2026.9.24`, e o `requires_python` publicado no PyPI é `<3.14` enquanto
o da main é `<3.15` — então `pip install hermes-agent` em Python 3.14 seria
**rejeitado pelos metadados publicados**, apesar de 3.14 ser o runtime suportado.
Nada disso é o que o `install.sh` usa: ele clona o repo e usa o `uv.lock`. Os
pacotes de registry são canal alternativo **não anunciado**, não substituto
documentado.

**Nenhuma das duas rotas foi executada nesta VM.** A decisão fica registrado aqui
para quando for tomada.

### OpenDesign via container

O daemon é um serviço, não uma CLI: processo de longa duração, porta própria e
estado persistente. Instalado aqui pelo **compose base do upstream**, que é o que
publica **só em loopback** — o override `docker-compose.linux.yml` troca para
`network_mode: host` e é justamente o que não se quer.

**O que a VM não tinha: provider de compose.** O `podman` estava instalado e o
`podman compose` respondia *"looking up compose provider failed"* — nem
`podman-compose` nem `docker-compose` presentes. Sem isso, o caminho do compose
simplesmente não existe, e o sintoma não parece o que é.

```bash
sudo dnf install -y podman-compose
podman compose version
```

⚠️ **O compose base tem `build:`, e ele precisa de `--no-build`.** O arquivo traz
`image:` e `build:` juntos, que é normal para quem desenvolve a partir do repo.
Sem a flag, o Podman tenta **compilar da fonte** — o caminho nativo, com
toolchain e Node 24 — em vez de usar a imagem publicada. O `--no-build` não é
opcional aqui.

```bash
git clone --depth 1 https://github.com/nexu-io/open-design.git ~/open-design
cd ~/open-design/deploy
podman compose up -d --no-build
```

**O `.env` a `600`, com token de 32 bytes** — é o que a doc do projeto prescreve
(`openssl rand -hex 32`), e o mesmo padrão que o repo usa para as outras
credenciais:

```bash
( umask 077; install -m 600 /dev/null .env )
TOKEN=$(openssl rand -hex 32)
{
  printf 'OD_API_TOKEN=%s\n' "$TOKEN"
  printf 'OPEN_DESIGN_PORT=7456\n'
} >> .env
chmod 600 .env
```

`OPEN_DESIGN_DISABLE_API_AUTH=1` **não** vai aqui. A doc oferece isso para quem
atrás de um proxy reverso já autenticado, e a mesma doc **não diz o que acontece
com `OD_API_TOKEN` vazio e a flag desligada**. Não se supõe esse estado.

**Pinar a imagem, e qual digest é o pinnable — uma armadilha que custou uma rodada.**
A tag `:latest` é mutável e a doc recomenda pinar. Só que existem três digests, e
só um serve:

| o que | onde | pinnable |
|---|---|---|
| **ID da imagem** (digest da config) | `podman image inspect --format '{{.Id}}'` | **não** — o registro responde `manifest unknown` |
| manifest da plataforma | `podman image inspect --format '{{.Digest}}'` | serve para uma arch só |
| **digest do índice** (multi-arch) | cabeçalho `Docker-Content-Digest` do registro | **é este** |

```bash
T=$(curl -s "https://ghcr.io/token?scope=repository:nexu-io/od:pull" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
curl -sI -H "Authorization: Bearer $T" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  https://ghcr.io/v2/nexu-io/od/manifests/latest | grep -i docker-content-digest
```

O erro que a doc não cobre: conferir o digest com `skopeo inspect --raw |
sha256sum` e **confiar no resultado sem verificar se `skopeo` existe**. Sem o
binário, o pipeline devolve a entrada vazia e o sha256 de string vazia
(`e3b0c442…`) — que parece um digest, e não é. Com `2>/dev/null` o
"command not found" desaparece junto.

**Verificar por endpoint, nunca por estado do container.** Existe um bug em
aberto em que o daemon trava consumindo CPU e memória enquanto o `systemd` — ou o
Podman — continua reportando *active*. O readiness é a resposta HTTP:

```bash
# o healthcheck é ABERTO, de propósito: 200 sem credencial é o esperado
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7456/api/health   # 200

# um endpoint de verdade, para conferir a autenticação
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7456/api/projects        # 401
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
     http://127.0.0.1:7456/api/projects                                            # 200
curl -s -o /dev/null -w '%{http_code}\n' -u "open-design:$TOKEN" \
     http://127.0.0.1:7456/api/projects                                            # 200
```

`401` sem credencial e `200` com o token é a prova de que a autenticação está
funcionando — e é a única prova que importa aqui. O corpo do 401 diz as duas
formas aceitas: *"Authorization: Bearer <OD_API_TOKEN> or browser Basic
authentication required"*.

E o que o compose garante, verificado no container: `user=open-design` (uid
1001, não root), `readonly=true`, `mem_limit=384m`, `pids_limit=256`, estado num
volume nomeado. A porta é **`127.0.0.1:7456`**, e medida de fora — LAN e tailnet —
ela está **fechada**.

⚠️ **O container não tem MCP.** A doc diz que os snippets de MCP *"require a
local/source install for now"*. Então os dois caminhos não se somam: o container
mantém a base limpa, e o nativo é o único que entrega MCP. Ver a seção do
OpenDesign nativo, e a escolha é sua sobre qual dos dois fica.

**Rollback** na seção `podman` do [`ROLLBACK.md`](ROLLBACK.md).

### Provisionar os três serviços numa VM nova

Os três serviços da VM de agentes (OpenCode, OpenDesign, Hermes) **têm passo no
`setup.sh`**, e cada um é despachado no perfil `vm`.

⚠️ **Esta seção dizia que os três "não têm passo no `setup.sh` ainda", e a tabela
abaixo descrevia o OpenDesign como `podman compose` com basic auth e o Hermes como
`podman run`, um container.** As três coisas estavam erradas na mesma direção: o
texto era anterior ao modo nativo e ao despacho dos módulos, e ninguém o atualizou.
As duas tabelas abaixo são o estado medido, e a coluna do que é manual é a que
importa para provisionar.

| | como roda | auth | o que ainda é manual |
|---|---|---|---|
| **OpenCode** | unit de usuário `opencode.service`, `service start` | senha em `service.json` (600) | **nada** |
| **OpenDesign** | unit de usuário, `hermes dashboard`… **nativo**: `pnpm install` + `pnpm build` no clone | `OD_DISABLE_API_AUTH=1`, porque o `tailscale serve` autentica antes | **nada** — o clone é feito pelo módulo, o token é gerado se você não colar um |
| **Hermes** | `hermes-cli` (instalador oficial) + `hermes-dashboard` (unit) | hash scrypt no `config.yaml` (600), texto puro num arquivo 600 | a **senha do modelo**: `hermes model` |

### O gateway do Hermes fica de fora, e é decisão

O `hermes-gateway.service` **não é criado pelo `setup.sh`**, e a unit que existe
na VM foi gerada por `hermes gateway install` — subcomando de primeira classe do
CLI (*"install gateway as a systemd/launchd background service"*), que a própria
documentação prescreve.

Decisão: **fica manual.** O gateway é parte da instalação padrão do Hermes e está
em uso; o que o script não faz é duplicar a documentação do produto. Em uma VM
nova, o passo é:

```bash
hermes gateway setup      # configura as plataformas de mensageria
hermes gateway install    # instala a unit de usuário
hermes gateway start
```

⚠️ **A unit do gateway guarda o caminho do executável no momento da instalação.**
Medido na VM: `ExecStart="/home/rvlmt/Hermes-Agent/.hermes/bin/hermes" "gateway"
"run"`. Se a CLI for reinstalada em outro caminho, a unit fica apontando para um
executável que não existe mais, e **é preciso rodar `hermes gateway install` de
novo** — não há como corrigir editando a unit à mão, porque o `ExecStopPost` de
limpeza de cgroup também aponta para o caminho antigo.


#### O OpenDesign: três armadilhas, e uma delas apaga o estado

**O `--no-build` é obrigatório.** A base traz `image:` e `build:` juntos, o que é
normal para quem desenvolve do repo. Sem a flag o Podman tenta **compilar da
fonte**, e a compilação é uma operação longa com aparência legítima.

**A origem da tailnet precisa estar na lista de permidos.** A base já tem a linha
certa — `OD_ALLOWED_ORIGINS: ${OPEN_DESIGN_ALLOWED_ORIGINS:-}` — e o que falta é o
**valor no `.env`**. Sem ele a página carrega e a API morre, e o navegador acusa
cross-origin sem explicar nada:

```bash
# no .env do deploy
OPEN_DESIGN_ALLOWED_ORIGINS=https://<maquina>.<tailnet>.ts.net:8444
```

Medido: sem a linha, a origem da tailnet leva **403** e `localhost` leva **200**.
Com a linha, as três origens levam **200**.

⚠️ **O `docker-compose.linux.yml` do upstream não pode ser aplicado neste
ambiente.** Ele traz os mounts das CLIs do host e o PATH que as aponta, mas fundir
os dois arquivos falha:

```
ValueError: can't merge value of [OD_PORT] of type <class 'int'> and <class 'str'>
```

A base declara `OD_PORT: 7456` (inteiro) e o override declara
`OD_PORT: ${OPEN_DESIGN_PORT:-7456}` (texto, depois de interpolada). O
`podman-compose` não funde int com str. A solução é um **override local** com só o
que falta, e ele está em `deploy/docker-compose.local.yml`.

⚠️ **O `podman-compose` SUBSTITUI a lista de volumes do serviço, não acrescenta.**
Verificado com `podman compose config`: um override que só somasse os host-bins
fazia `open_design_data:/app/.od` sumir do merge — e a recreate seguinte começava
com o estado do OpenDesign **vazio**. O override local tem que repetir o volume de
dados.

⚠️ **O `,z` no fim do mount não é opcional, e o erro que aparece sem ele não
aparece.** As permissões Unix dos diretórios do host são `755` e não são o motivo.
O que barra é o **SELinux**: medido, `~/.local/bin` é `gconf_home_t` e
`~/.opencode/bin` é `user_tmp_t`, e nenhum dos dois é legível de dentro do
container. O sintoma é `Permission denied` — que parece problema de permissão e é de
rótulo. `z` (compartilhado, e não `Z` privado) porque o host também usa esses
diretórios, e os dois precisam do mesmo rótulo.

```yaml
# deploy/docker-compose.local.yml — o que o override do upstream não consegue aplicar
services:
  open-design:
    environment:
      PATH: /mnt/host-local-bin:/mnt/host-opencode:/usr/local/bin:/usr/bin:/bin
    volumes:
      - open_design_data:/app/.od          # repetir: a lista é substituída, não somada
      - ${HOME}/.local/bin:/mnt/host-local-bin:ro,z
      - ${HOME}/.opencode/bin:/mnt/host-opencode:ro,z
```

```bash
podman compose -f docker-compose.yml -f docker-compose.local.yml up -d --no-build
```

⚠️ **Nunca despeje `podman compose config` sem filtrar.** Ele renderiza o ambiente
**já interpolado**, e o `OD_API_TOKEN` sai em claro. Use `--services`, ou um
`grep -v` de `TOKEN|KEY|SECRET`. Isso já aconteceu uma vez aqui: o token apareceu
inteiro na conversa e precisou ser rotacionado.

#### O muro de libc, e ele vai nos dois sentidos

Este é o achado que decide a arquitetura, e é o mesmo dos dois lados.

**Do host para dentro do container, não funciona.** O container é **Alpine
3.24.2** (musl) e não tem `/lib64/ld-linux-x86-64.so.2`. O binário do opencode
declara `PT_INTERP=/lib64/ld-linux-x86-64.so.2` — glibc, dinâmico. O `gcompat`
**está instalado** e traz **zero** loaders. Resultado: toda CLI do host montada no
container morre com `not found`, que é o sintoma de loader ausente e parece de
permissão. A UI do OpenDesign mostra *"Nenhum agente detectado ainda"*, porque
detecta por `PATH` e a execução é que falha depois.

**Do container para o host, o inverso também é verdade.** A imagem traz **16
módulos nativos** já compilados, e entre eles `@img/sharp-linuxmusl-x64` e
`better_sqlite3` compilados para musl. **Copiar `/app` para o Fedora não carrega** —
é o mesmo muro do outro lado. Um nativo só funciona **compilando da fonte**, que é
justamente o que o `Dockerfile` faz:

| requisito | valor | de onde |
|---|---|---|
| Node | `~24` | o mise resolve `lts`, que é a linha `24` — casa |
| pnpm | a mais recente | `corepack prepare pnpm@latest --activate` — ver a ressalva do major |
| build | `gcc-c++`, `make`, `python3` | o `Dockerfile` usa `apk add python3 make g++` |

⚠️ **Só o `node` na sessão não interativa não conta.** O PATH vem do shell rc, e um
`ssh` cru não o tem. O node do mise está em
  `~/.local/share/mise/installs/node/lts/bin` (o mise grava `lts` como link) — é
  preciso colocá-lo no PATH explicitamente antes de qualquer build.

#### A raiz do build passou a ser o próprio clone

O modo nativo **não** cria mais uma pasta paralela. A raiz do build é
`~/Developer/open-design/`, que é o clone — o caminho que a documentação e os
exemplos do próprio OpenDesign esperam.

Havia um nome provisório, `~/Developer/open-design-native-root/`, criado só para
não colidir com o clone. Ele estava registrado em três lugares (aqui, no
`setup.sh` e no `ROLLBACK.md`) como *"a próxima instalação deve usar só
`~/Developer/open-design` e não criar a raiz paralela"*.

**A próxima instalação chegou, e a mudança foi feita.** O critério era o momento:
mover a raiz é trivial numa máquina que ainda não rodou nada, e caro numa que já
está rodando — e é justamente por isso que ficou adiada até agora e não antes.

O que a mudança exige em código, e que é a pegadinha real: com a raiz **igual** ao
clone, o symlink de `apps/web/out` passaria a apontar para o próprio destino.

```
apps/web/out  ->  apps/web/out        # laço
```

Por isso o symlink ficou dentro de um guard que compara `$OPENDESIGN_ROOT` com
`$OPENDESIGN_SRC`, e só o cria quando são diferentes — que é o caso de uma raiz
paralela. O guard está em `_setup_open_design_native`, logo depois do
`pnpm deploy`, e ele existe por causa dessa decisão, não por Prudência genérica.

**O que isso não muda:** o `pnpm deploy` continua precisando do layout
`<projeto>/apps/daemon/dist`, porque `resolveProjectRoot` faz
`path.resolve(daemonDir, '../..')`. Escrever dentro do clone deixa `apps/daemon`
com o conteúdo do deploy — que é o que o daemon espera, e o que a imagem do
container traz. O clone passa a ter arquivos não rastreados, e `git status` mostra
isso; é o preço de não manter uma cópia paralela da mesma árvore.


#### O OpenDesign tem DOIS modos, e a pergunta é no bloco de inicial

Não são dois ramos de uma coisa só: **não compartilham pré-requisito nenhum**, e
por isso são dois módulos e a pergunta escolhe qual roda. Um `if/else` num módulo
só seria mentira — o `if` teria quarenta linhas e nenhum lado pareceria o que é.

| | **nativo** | **container** |
|---|---|---|
| pré-requisitos | node do mise, pnpm via corepack, `libatomic` | nada, a imagem traz tudo |
| custo | `pnpm install` de 1,5 GB + build do daemon + build do web | pull de 1,28 GB |
| agentes | **7** | **0** |
| como o auth é aplicado | escutando no **IP da tailnet** | bridge: o peer é o gateway |
| alcançável | direto, em HTTP sem TLS | só atrás do `:8444`, com TLS |

⚠️ **A documentação do OpenDesign diz que o bind é loopback, e eu propus o
contrário.** `deploy/.env.example` e `docs/deployment/docker.md` — que eu não
abri — afirmam:

> *connector endpoints (Composio, GitHub OAuth) also require the daemon to receive
> requests over **loopback**. On Linux Docker this is handled automatically by
> `docker-compose.linux.yml` (`network_mode: host`).*

E o motivo está no `server.js`, num comentário que eu li e não reconheci:

> *the loopback bypass exists for the **localhost desktop UI which has no proxy in
> the path***

Não é escolha de onde escutar: é o desenho do produto. Os endpoints de
**escrita** — associar CLI, OAuth de conector — exigem loopback porque a UI desktop
local é o caso de uso, e o proxy TLS na frente não é. A exclusão dos dois modos é
consequência disso, não preferência minha:

| | token na API | associar CLI / OAuth de conector |
|---|---|---|
| **container** (bridge) | sim — o peer é o gateway | **sim** — gateway conta como loopback dentro |
| **nativo em loopback** | não — o carve-out desliga | **sim** |
| **nativo na tailnet** | sim | **não** |

⚠️ **A saída que eu não vi, porque não li: `OPEN_DESIGN_DISABLE_API_AUTH=1`.** O
`.env.example` a chama de *escape hatch for deployments whose reverse proxy already
authenticates every request*, e `docker.md` condiciona: *set to 1 only when that
proxy already authenticates every request and the daemon is not directly exposed*.
Com o `tailscale serve` fazendo TLS e a tailnet como fronteira, o nativo em
loopback passa a ter os dois.

**Não é desligar o portão de olhos fechados**: `OD_API_TOKEN` é o portão quando
não há proxy que autentique, e desligá-lo é desligar o portão. A condição da doc é
"o proxy já autentica tudo", e isso precisa ser verdade, não presumido.

⚠️ **O sintoma do `public_url` quebrado é `400` no `/login`, e ele fica MASCARADO
quando o token está ligado** — o portão responde 401 antes da rota, e o
`Cannot GET /` desaparece. Só `/` **sem** credencial revela que a UI não existe.

⚠️ **`pnpm deploy --legacy --prod` ACHATA o pacote, e o daemon não.** O
`resolveProjectRoot` faz `path.resolve(daemonDir, '../..')` e assume
`<projeto>/apps/daemon/dist`, que é o layout do container. Achatado, o
`PROJECT_ROOT` sobe um nível a mais, o `STATIC_DIR` cai fora, e a UI não é montada.
O layout que funciona é `apps/daemon/` e `apps/web/out`.

⚠️ **O build do web estoura o HEAP do V8, não a RAM.** `rc=0 em 89s` com
`--max-old-space-size=3072` e `taskset -c 0-3`, numa máquina com 7,7 GiB de RAM e
7,7 GiB de swap **livres** e `dmesg` sem OOM. O frame 2 da pilha era
`node::OOMErrorHandler`. Duas alavancas, porque o Next cria um worker por CPU e
cada um tem heap próprio.

#### `export` não sumiu: virou `session export` — e a correção é uma linha

O que escrevi acima sobre `--sanitize` estar ausente **estava incompleto**, e a
forma de descobrir foi a que a regra manda: ler a lista de subcomandos do próprio
binário, não supor pelo `--help` pontual.

```
uninstall  acp  api  debug  mcp  plugin  models  stats  mini  run  session  service  reload  pair  serve
```

Não há `export` no topo — há **`session export`**, com a mesma função:

```
opencode session export --sanitize    Redact sensitive transcript and file data
```

A descrição é literalmente a que o adaptador precisa. Medido: com uma sessão
criada por `opencode run --format json`, o `session export --sanitize` devolve
**16.200 bytes** com `info.id` correto e `info.parentID` — que é `null` para a
sessão **raiz**, e é o campo que o adaptador compara com a sessão filha que está
verificando.

E `acp` na lista confirma a outra hipótese que valia: `opencode acp` é *"Start an
Agent Client Protocol server"*, o mesmo `streamFormat: "acp-json-rpc"` que o
`/api/agents` reporta para o opencode.

⚠️ **`--pure` continua ausente no 2.0.18** — é a outra flag do adaptador, e ela
não tem substituto na lista. As duas coisas que o adaptador faz são isolar um
plugin instalado pelo usuário e dar um diretório de trabalho neutro, e é o
`execAgentFile` que as monta. Sem `--pure`, a garantia de que um plugin não roda
dentro do caminho de evidência **não existe no 2.0.18** — e isso não é uma flag a
menos, é uma propriedade de segurança que a flag entregava.

⚠️ **O `parentID` só existe para sessão FILHA.** Medido numa sessão raiz, ele é
`null`. A comparação do adaptador é `info.parentID !== candidate.rootSessionId`,
então o campo existe, e o que falta no 2.0.18 é só a semântica do `--pure`.



O modal de "associar CLI" chega ao daemon, passa a rota de escrita — e quebra **depois**,
no CLI. Não é PATH, não é mount, não é libc, e não é o carve-out: é **contrato de
versão**. E o contrato está escrito, em `docs/agent-adapters.md` do próprio projeto.

**§5.6 diz como o agente roda**, e nenhuma das flags que o modal mandou aparece lá:

```
opencode run --format json     # prompt no stdin
-s <session-id>                # turnos seguintes, sessão nativa
--dangerously-skip-permissions # só se o `run --help` anunciar
```

O `2.0.18` cumpre os três: aceita `--format json`, aceita `-s`, e **não** anuncia
`--dangerously-skip-permissions` — e a doc cobre esse caso ("older builds keep the
compatible argv without it"). Prova funcional:

| invocação | resultado |
|---|---|
| `opencode run --format json` | `{"type":"step_start",…,"sessionID":"ses_f129…"}` |
| `opencode run --dir /tmp --pure` | recusa as flags e despeja o usage |

**O fluxo do agente funciona no 2.0.18.** O que quebra é outra coisa, e o próprio
daemon diz qual: `dist/runtimes/opencode-child-evidence.js`, o **adaptador de
evidência de sessão filha**. O comentário dele explica as duas flags:

> *`--pure` keeps a user-installed OpenCode plugin from executing inside the
> evidence path, and `execAgentFile` supplies a neutral working directory*

E no topo do arquivo, a versão que ele declara:

```js
export const OPENCODE_CHILD_EVIDENCE_CLI_VERSION = '1.18.18'
```

**A máquina tem a `2.0.18`.** Não é flag renomeada: é major atravessado, e o
adaptador nem tem como avisar, porque o número está num `const` que nada compara
contra o binário instalado. A segunda superfície quebrada confirma: o adaptador lê
a transcript com `opencode export <id> --sanitize`, e no `2.0.18` o `export`
existe mas **não tem `--sanitize`**.

⚠️ **O `stdout` que o modal mostrava não era um segundo erro.** Era o **usage** do
opencode depois de recusar as flags — daí o `level (choices: all, trace, debug, …)`
e o `--print-logs`. Ler aquilo como uma segunda falha é ler a mensagem de_usage do
erro anterior.

**A decisão: aceita sem a evidência de sessão filha, no opencode 2.0.18.** O
agente roda, os 7 agentes são detectados, e a transcript da sessão raiz é salva.
O que não acontece é a verificação de que uma sessão filha corresponde ao que a
raiz diz que ela fez.

E o que se perde, nomeado: **o `--pure` é a garantia de que um plugin instalado
pelo usuário não executa dentro do caminho de evidência.** Sem essa flag, no 2.0.18
não existe nada que assegure isso — não é uma flag a menos, é a propriedade que a
flag entregava. Isso vale para qualquer plugin que você tenha instalado no
opencode, e é o motivo de a decisão ser uma decisão e não um detalhe.

⚠️ **A degradação é silenciosa, e isso é o ponto de atenção.** O coletor devolve
`retained: []` e o run segue. Nada na UI avisa que a parte não rodou. A evidência
também é infraestrutura de **conformidade**, com nível declarado por capacidade —
`nativeSessionContinuation: { support: 'verified', evidenceLevel: 'L0' }` e
`nativeSubagents: { support: 'verified', evidenceLevel: 'L2' }`, sob o esquema
`EVIDENCE_V1`. Então o que falta é trilha de auditoria de subagente, não
funcionalidade de execução.

**O caminho ACP foi verificado e NÃO é a saída.** `opencode acp` existe no
binário — *"Start an Agent Client Protocol server"* — mas `docs/agent-adapters.md`
atribui `acp-json-rpc` a `amr`, `devin`, `hermes`, `kimi`, `kiro`, `kilo`,
`reasonix`, `trae-cli` e `vibe`, e o **opencode** a `json-event-stream`. Existe um
`runtimes/acp/` inteiro no daemon, para os outros. E a API em execução concorda com
a doc nas quatro entradas conferidas — `opencode` e `byok-opencode` em
`json-event-stream`, `antigravity` em `plain`, `claude` em `claude-stream-json`.

**Como reverter, se a trilha de auditoria passar a importar:** fixar o opencode na
`1.18.18`, que é a versão que `dist/runtimes/opencode-child-evidence.js` declara em
`OPENCODE_CHILD_EVIDENCE_CLI_VERSION`. Repare que essa constante é um **registro, e
não um gate** — nada no daemon a compara com o binário instalado, então o adaptador
não consegue avisar que a versão mudou. Uma versão antiga fixada sem pin declarado é
dívida, e é o custo de voltar atrás.



| | o que |
|---|---|
| instalar a `1.18.18` do opencode | a evidência volta; a UI e os 7 agentes ficam, e o `setup_opencode_service` passa a fixar uma versão antiga sem pin declarado |
| o container | o gateway do podman conta como loopback **dentro** dele, então a evidência funciona — e a CLI tem de ser musl, o que o próprio `deploy/.env.example` diz que a aplicação não faz |
| aceitar que a evidência não roda | o agente roda, a verificação de sessão filha não; e nada no UI avisa que ela é o que falta |





⚠️ **O sintoma do `public_url` quebrado é `400` no `/login`, e ele MASCARADO
quando o token está ligado.** O portão de auth responde 401 antes da rota, então o
`Cannot GET /` some. Só `/` **sem** credencial revela que a UI não existe — e é por
isso que a verificação final é feita nos dois lados.

⚠️ **`pnpm deploy --legacy --prod` ACHATA o pacote, e o daemon não.** O
`resolveProjectRoot` faz `path.resolve(daemonDir, '../..')` e assume
`<projeto>/apps/daemon/dist`, que é o layout do container. Achatado, o
`PROJECT_ROOT` sobe um nível a mais, o `STATIC_DIR` cai fora, e a UI não é montada.
O layout que funciona é `apps/daemon/` e `apps/web/out` — o mesmo do container.

⚠️ **O build do web estoura o HEAP do V8, não a RAM.** `rc=0 em 89s` com
`--max-old-space-size=3072` e `taskset -c 0-3`, numa máquina com 7,7 GiB de RAM e
7,7 GiB de swap **livres** e `dmesg` sem OOM. O frame 2 da pilha era
`node::OOMErrorHandler`. Duas alavancas, porque o Next cria um worker por CPU e
cada um tem heap próprio.

**Um por máquina.** Os dois disputam a mesma porta interna, e deixar isso acontecer
não dá erro visível: o segundo sobe, o primeiro fica com o processo no ar mas sem
escutar, e a publicação continua respondendo pelo que ficou. O script recusa, com
a mensagem dizendo qual remover.


#### O dashboard do Hermes é NATIVO, e a UI não custa container

O dashboard do Hermes — o container em `127.0.0.1:9119`, publicado em `:8445` —
**foi removido por decisão de projeto**. A máquina fica com a CLI nativa
(`setup_hermes-cli`). Não é preferência de estilo; são duas medições:

**A CLI nativa é a única que roda.** `opencode` e `agy`, os agentes que o
OpenDesign usa, são **ELF glibc**; o container do OpenDesign é Alpine. Dentro dele
nenhuma CLI do host executa — o Hermes inclusive, que entra pelo mesmo mount. A
dashboard em container não tinha capacidade que a nativa não tenha, e ocupava
2,81 GB de imagem.

**Os dois homes não compartilhavam estado.** O nativo usa `~/.hermes`; o container
usava `~/Developer/.hermes`. Provider configurado num **não** aparecia no outro, o
que tornava a dashboard quase decorativa para o uso real.

**O backup do estado do container foi descartado depois.** Isto é o estado
medido hoje, e substitui a afirmação anterior de que ele fora preservado com
7138 arquivos e 919 MB:

| | estado medido |
|---|---|
| `~/Developer/.hermes` | 8 KB, 1 entrada — não é o estado do container |
| `~/Developer/.hermes-backup-20260929-050136` | **vazio** |

⚠️ **A tabela anterior dizia que os dois guardavam 919 MB.** Ela estava escrita
quando o backup existia, e ninguém a atualizou quando ele sumiu. Registrado aqui
porque a lição é o que importa: **um backup que ninguém verifica volta a ser uma
afirmação no README.** O que sobreviveu do container está em `~/.hermes`, que é o
home do nativo.


⚠️ **O backup também cai no subuid, e isso é o surpreendente.** Fazer o backup de
dentro de um container funciona — ele lê como uid 10000 — mas o `tar` extrai com
esse dono, e o resultado é um diretório `700` que o `rvlmt` **não consegue abrir**.
O `podman unshare chown -R 1000:1000` **não resolve**: o bloqueio não é o uid, é o
rótulo `container_file_t` com categoria MCS própria, que o host não atravessa.
Medido: os dois diretórios têm categorias diferentes (`c44,c215` e `c58,c660`) e
os dois são ilegíveis do host. Um backup nesse regime só se **restaura por
container** — aceitável, e significa que não é um backup que você pode inspecionar.

Duas lições do container valem mesmo depois dele ir embora, porque são armadilhas
de qualquer bind mount rootless com estado:

- **`:Z` é obrigatório** no bind mount. Sem ele o SELinux barra o caminho, o setup
  inicial sai com 1, e o container morre com **exit 2 e nenhuma mensagem útil no
  FIM do log** — a causa está no começo.
- **O `public_url` vem de variável de ambiente e tem que existir ANTES do start**,
  e é o **DNSName** do nó, não o `hostname` da máquina. Medido: `hostname` dá
  `fedora-vm` e o DNSName termina em `.sawfish-banjo.ts.net`. Montar a URL com o
  hostname produz um `public_url` que o fluxo OAuth não reconhece, e o sintoma é
  `redirect_uri_mismatch`. Registrar o dashboard **antes** de escolher o bind grava
  a URL canônica errada — foi assim que o erro nasceu.

Para trazer de volta, o que reverter: o `podman run` com o digest pinado, o `:Z` no
bind, o hash scrypt no lugar da senha, e `sudo tailscale serve --bg --https=8445`.


⚠️ **A unit precisa dos TRÊS códigos de saída, e o Hermes avisa quando não tem.**
O aviso na TUI — *`hermes-dashboard lacks RestartPreventExitStatus=78`* — procede,
e vale a mesma tripé que a unit do gateway escreve. Medido nesta máquina: com a
porta ocupada, `hermes dashboard` devolve **75** e sai em 2,3s.

| código | nome em `sysexits.h` | o que significa | o que o systemd deve fazer |
|---|---|---|---|
| **75** | `EX_TEMPFAIL` | drenagem graciosa, recarregar | **reiniciar** |
| **78** | `EX_CONFIG` | recusa deliberada: um `--port` que o dono não pode servir | **estacionar** |

Sem o `78`, um `78` sob `Restart=always` vira **laço infinito sem nada escutando**
na porta de entrada — que é o defeito que o próprio código do projeto registra
(#119824). E sem `SuccessExitStatus=75` mais `RestartForceExitStatus=75`, um `75`
parece saída limpa e o serviço não volta.

⚠️ **`hermes gateway install` NÃO substitui a unit da dashboard.** São serviços
diferentes: o gateway é *mensageria* (WhatsApp, Telegram) e não abre a porta
`9119`; a dashboard é a UI. O `install` cria `hermes-gateway.service` e não toca
em `hermes-dashboard.service` — verificado, com as duas `active` ao mesmo tempo. A
unit da dashboard **precisa** ser declarada, e é a única que o `setup.sh` escreve.

⚠️ **O `pm` baixa binários para uma máquina que não é a do build.** Duas vezes
agora, com a mesma assinatura — `staged entry failed verification … exited 127 …
error while loading shared libraries`:

| binário | biblioteca que faltava | origem |
|---|---|---|
| o `node` pinado do install | `libatomic.so.1` | `sudo dnf install -y libatomic` |
| o `cua-driver` | `libX11.so.6` | `sudo dnf install -y libX11` |

O verificador é honesto — ele **executa** o binário baixado e reporta o que o
loader diz — mas nenhum dos dois `install` menciona a dependência de sistema. A
regra prática: se o `pm` reclamar de `shared libraries`, é biblioteca do sistema,
não do pacote.

⚠️ **O aviso de "fork não rastreia o upstream" foi enganoso.** Medido: o remote é
`https://github.com/NousResearch/Hermes-Agent.git`, o branch é `main` e `@{u}` é
`origin/main`. É o upstream que o repo em `~/Developer` fica, e o `pm` lê o
estado de tracking de um modo que não casa com esse arranjo.


#### A CLI do Hermes é instalada pelo instalador que a doc prescreve

O "Quick Install" do README upstream é **uma linha**:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

E é essa linha que o módulo `hermes-cli` roda, com o pin de tag em cima:

```bash
curl -fsSL "$HERMES_INSTALL_URL" \
  | bash -s -- --non-interactive --branch "$HERMES_CLI_TAG"
```

⚠️ **Esta seção descrevia um caminho montado à mão, e estava errada em três
pontos.** O texto antigo recipe `curl` do uv do astral + `git clone` +
`setup-hermes.sh --runtime-only` + symlink, e dizia a tag **`rc.9-v0.21.5`** — que
é a *mesma* `0.21.5` da `rc.14-v0.21.5` e está marcada como `abandoned-` pelo
upstream. Quem seguisse o README instalava a tag abandonada.

O caminho antigo perdia três garantias do instalador oficial:

| | antes | oficial |
|---|---|---|
| **uv** | `astral.sh/uv/install.sh`, sem pin | artefato pinado do `pm/lock.json`, com **sha256 conferido** (`UV_PIN_VERSION="0.12.3"`) |
| **árvore** | `~/Hermes-Agent`, symlink manual | `$HERMES_HOME/hermes-agent`, o padrão do instalador |
| **log** | nenhum | `~/.hermes/logs/install.log` |
| **PATH** | symlink manual para `~/Hermes-Agent/hermes` | publicado pela própria `source_completion` |

A flag `--runtime-only` **existe** — medido no `setup-hermes.sh` do clone, linhas
20, 24 e 179. Não era dedução; era o caminho certo com uma dependência fora do
lugar.

⚠️ **A instalação falha sem `libatomic`, e o erro é de biblioteca, não de
permissão.** O `pm` baixa um node pinado e **verifica rodando `node --version`**; o
binário morre com

```
error while loading shared libraries: libatomic.so.1: cannot open shared object file
```

e o `pm` reporta `node: staged entry failed verification ... exited 127`. Nem o
`setup-hermes.sh` nem o README mencionam a dependência. A ironia útil: a
`libatomic.so.1` **existe dentro do container Alpine** e não existe no host — é o
mesmo muro de libc do OpenDesign, no sentido inverso. O `libX11.so.6` cai no
mesmo grupo, e o script **não o verificava em lugar nenhum**.
⚠️ **Medido numa segunda VM, e é a correção desta afirmação:** `libatomic` e
`libX11` **JÁ VIERAM** numa Fedora 44 Workstation Edition recém-criada. A frase
"não existe no host" era verdadeira para a outra VM — de imagem menor — e falsa
para esta. A afirmação honesta é que **depende da imagem**, e é por isso que
estão na lista do `base` e não num passo opcional.

O que não mudou é o porquê de estarem lá: o `pm` baixa binários para a
máquina-alvo e **verifica rodando o binário**, e sem as duas bibliotecas falha com
`error while loading shared libraries` e reporta `staged entry failed
verification ... exited 127`. `libX11` **não era verificado em lugar nenhum**
antes de entrar na lista, e foi ela que faltou na máquina onde a `libatomic` já
estava presente.


🛠️ **Agora os dois são instalados pelo módulo `base`**, junto com o resto:

```bash
sudo dnf install -y --skip-unavailable libatomic libX11
```

Antes eram dois `return 1` no meio do caminho, exigindo um `sudo` manual em dois
lugares — e o `libX11` passava sem aviso nenhum.

⚠️ **O instalador tentaria anexar uma linha de PATH no `~/.zshrc`, e aqui ele
não vai.** O `append_shell_path` do `install.sh` tem guarda própria:

```
^[[:space:]]*([^#[:space:]].*)?PATH=.*\.local/bin
```

e a linha 11 do `zshrc` versionado deste repo já casa com ela (medido, `grep -E`
no arquivo real). O detalhe importa porque `~/.zshrc` aqui é **symlink para o
arquivo do repositório** — sem essa guarda, o instalador escreveria dentro do
arquivo versionado, que é a mesma armadilha do `--no-modify-path` do opencode.
Não há `--no-modify-path` no instalador do Hermes; a proteção vem de o zshrc
deste repo já satisfazer a guarda.


#### O container não roda NENHUMA CLI do host, por duas causas

Medido depois de a CLI existir. Não é uma causa, são **duas**, e o OpenDesign
reporta as duas com a mesma mensagem:

| CLI | o que é | por que não roda no container |
|---|---|---|
| `opencode` | ELF glibc | **libc**: Alpine é musl, sem `/lib64/ld-linux-x86-64.so.2` |
| `agy` | ELF glibc | **libc**, idem |
| `hermes` | launcher em `~/.local/bin` | **caminho**: o container monta `~/.local/bin`, mas não `~/.hermes` |

E o diagnóstico do app é impreciso nos dois casos: ele diz *"foi encontrado mas não
pode ser iniciado — seu wrapper ou shim aponta para um caminho ausente"*, o que é
exato para o symlink e **falso para o ELF**, cujo problema é a libc. Um
`shim-broken` no container **não significa** que o shim está quebrado.

⚠️ **O `shim-broken` é o estado normal do container, não um sintoma a investigar.**
Três agentes aparecem como `shim-broken` desde que os mounts existem, e nenhum
deles vai ficar disponível enquanto o container for Alpine. A lista de agentes que
o container consegue usar é vazia por construção.

Isso é o argumento medido a favor do **nativo**: no modo nativo os três aparecem
disponíveis, porque os binários glibc executam no glibc.


#### As senhas provisórias, e o que elas custam

`hermes` e `opencode` como senha são **adivinháveis** por qualquer um que saiba que
você as usa. Isso é exposição conhecida, e é o que a senha compra: a separação
entre uma pessoa da tailnet e a sua sessão — **não** a máquina, que quem alcança a
tailnet já acessa. A barreira é real e fina.

O que reduz a exposição sem trocar a convenção: o **hash scrypt** no ambiente, o
texto puro num arquivo `600`, e `~/Developer/.hermes` em `700`.

| serviço | onde a senha mora | como trocar |
|---|---|---|
| OpenCode | `~/.config/opencode/service.json` | `opencode service set password <nova>` |
| Hermes | env `…_BASIC_AUTH_PASSWORD_HASH` | regerar o hash e recriar o container |
| OpenDesign | `OD_API_TOKEN` no `.env` | trocar no `.env` e `compose up -d` |


### O disco da VM, e por que não é assunto de install

O `sudo virsh` expande o **block device no host**, o que não é o mesmo que expandir
o disco da VM — e a diferença é fácil de perder porque o `lsblk` mostra o bloco
maior e dá a impressão de que acabou:

```
vda        40G   <- o host expandiu
`-vda3     13G   <- a particao dentro do guest continua 13G
```

São dois passos, e o segundo é o que faz diferença. `/` e `/home` são **subvolumes
do mesmo btrfs** em `vda3`, então crescem juntos:

```bash
sudo dnf install -y cloud-utils-growpart   # growpart nao vem no Fedora
sudo growpart /dev/vda 3
sudo btrfs filesystem resize max /         # ATENCAO: o tamanho ANTES do caminho
```

⚠️ **A sintaxe é o contrário do que parece.** `resize max /` funciona; `resize / max`
devolve *"cannot access 'max'"*, e o mesmo erro para o `40G`. O `man` confirma:
`[<devid>:]<size>|[<devid>:]max` vem **antes** de `<path>`. E a partição precisa
crescer antes — sem o `growpart` o `resize` não tem de onde pegar.

Isto não entra no `setup.sh` de propósito: numa VM nova o disco é dimensionado certo,
e expandir é operação de **host**, uma vez — não de provisionamento.

### `~/Developer` é a base

Os repos e o estado dos agentes vivem sob `~/Developer`. O módulo `hostname` já
criava o diretório; o que passou a ser regra é que **os repos também ficam lá** —
`dotfiles-fedora` e `open-design` — e não mais direto em `$HOME`.

A consequência prática: **o caminho de execução do script muda.** Onde era
`~/dotfiles-fedora/setup.sh`, agora é `~/Developer/dotfiles-fedora/setup.sh`.


### OpenCode em uma VM nova

Sequência medida numa VM real. Os caminhos de arquivo vêm do binário v2.0.18, não
da documentação — que é onde a v1 e a v2 divergem.

**0. O que o `opencode service` realmente aceita.** Cinco chaves, e nenhuma outra:
`hostname`, `port`, `password`, `cors`, `env`. `bind`, `address` e `url` são
rejeitados com *"Unknown service config key"*. O terceiro argumento do `set` só
existe para `key = env`, onde o segundo argumento é o **nome** da variável e o
terceiro o **valor**:

```bash
opencode service set env OPENCODE_LOG_LEVEL DEBUG
```

**1. Login.** A senha do servidor não é opcional, e **não se escreve em `argv`** —
`opencode service set password "$senha"` deixa o valor no histórico do shell. O
padrão do repo para isso já existe: ler com `read -s` e apagar a variável em
seguida (`apply_opencode_password`). A senha é gravada em
`~/.config/opencode/service.json` a `600` e **fica estável entre restarts**.

```bash
opencode service set hostname 127.0.0.1
opencode service set password "<senha de verdade>"
```

**Loopback já é o default** — a doc diz que o servidor *"listens only on
localhost"* e a porta padrão é `49374` (`0xc0de`) nos canais `latest`/`dev`/
`beta`/`next`. Fixar `hostname` é redundância defensiva, e vale a pena mesmo
assim: `opencode pair` **enumera endereços conforme o que está escutando**, então
em `0.0.0.0` ele imprime um link por endereço alcançável em vez do que você
quer. Foi exatamente isso que produziu links na LAN inúteis.

**2. Publicação pela tailnet.** Não existe documentação oficial do Tailscale para
o OpenCode — a árvore v2 não menciona `tailscale` uma vez sequer. O padrão de
escuta em loopback e publicação por `tailscale serve` é **decisão deste projeto**,
e é por isso que ela vale como regra e não como citação.

```bash
tailscale serve --bg --https=8443 http://127.0.0.1:49374
tailscale serve status
```

⚠️ **A armadilha do nome defasado, medida na VM.** O `tailscale serve` guarda a
publicação **chaveada pelo nome**, e o nó tem dois nomes: o `DNSName` (o que
resolve) e o `HostName` (o que o tailscale ainda acredita). Medido:

```
Self DNSName:  fedora-vm.sawfish-banjo.ts.net.
Self HostName: fedora
config do serve: fedora.sawfish-banjo.ts.net:8443
```

Com o nó renomeado, a publicação fica chaveada no nome antigo, o `tailscaled` pede
certificado para um nome que o nó não responde, e o TLS morre no handshake com
`tlsv1 alert internal error (592)` — sem mensagem que aponte a causa. HTTP puro
devolve `400`, que é só o listener dizendo "eu espero TLS". **Reiniciar o serviço
não resolve**; o certificado não tem a ver com ele.

O conserto é republicar, e é instantâneo:

```bash
tailscale serve reset
tailscale serve --bg --https=8443 http://127.0.0.1:49374
```

E o sintoma que confirma a causa: o certificado sai correto na hora, com o `CN`
igual ao nome novo. Reconciliar o `HostName` evita a recorrência:

```bash
sudo tailscale set --hostname=<hostname-da-maquina>
```

**3. Link de acesso.** O `pair` imprime links de uso único, que **expiram em 5
minutos**, e um QR code do primeiro. Para acessar de outro aparelho, a URL
publicada entra explicitamente:

```bash
opencode pair --url https://<maquina>.<tailnet>.ts.net:8443
```

Com `--url` sai **um** link, e o `pair` deixa de consultar os endereços do
servidor. **Não "teste" o link para verificar se funciona**: ele é de uso único, e
consumir é usar. Para verificar o caminho, use um endpoint que não queima o link:

```bash
curl -i https://<maquina>.<tailnet>.ts.net:8443/api/health   # 401 = chegou autenticado
```

**4. O que falta, e é o passo que o padrão ainda não cobre.** `opencode service
start` **não cria unit** — spawna um filho `detached`, com `unref`, que não
sobrevive a reboot e não pertence a nenhuma unit. Para rodar sob systemd é preciso
escrever a unit, com `opencode serve` em **primeiro plano**, e aí muda o quadro:
o foreground **ignora `~/.config/opencode/service.json`**, então `hostname` e
`porta` vêm de flag (`--hostname`, `--port`) e a senha, de `OPENCODE_PASSWORD` no
ambiente — de preferência um `EnvironmentFile` a `600`, lido no start. `serve` em
primeiro plano bloqueia para sempre, que é o que uma unit quer.

**Ordem de montagem numa VM nova**, sem nada exposto no meio: senha e loopback
(1) → publicação (2) → unit (4) → só então `pair` (3). Pular direto ao `pair`
deixa o processo escutando fora do loopback enquanto ninguém está olhando.

### Antigravity (`agy`) em uma VM nova

Três passos, e **dois são automatizáveis; o primeiro não é**.

**1. Login, manual e uma vez só.** O `agy` autentica por OAuth no navegador:

```bash
agy
```

O passo de terminal do agente é só abrir o `agy`; a autenticação em si é humana.
É a mesma natureza do login de pessoa do `gh` — automação que depende de abrir
navegador não é automação.

**2. O `remote-control`.** Para servir a interface de controle remoto:

```bash
agy remote-control start --name "$(hostname)"
```

O que roda em serviço de fundo é o `serve`:

```bash
systemctl --user cat antigravity-cli-daemon.service | grep ExecStart
# ExecStart=/home/<user>/.local/bin/agy remote-control serve
```

**3. Habilitar no boot.** A unit é criada pelo instalador do `agy`; o papel do
padrão é apenas habilitá-la, e é idempotente:

```bash
systemctl --user enable antigravity-cli-daemon.service
```

⚠️ **Pendência conhecida, e ela é uma divergência.** O padrão declara um drop-in
`…antigravity-cli-daemon.service.d/10-mise-path.conf`, para que o filho `npm exec`
encontre o runtime do mise — serviço systemd não lê o `~/.zshrc`. **Esse drop-in
não está na VM**, e mesmo assim o daemon está `active` e servindo, porque o
`ExecStart` atual chama o `agy` direto. Ou a premissa do drop-in ficou obsoleta
quando o `ExecStart` mudou, ou o drop-in nunca foi escrito. **Não se sabe qual**,
e a decisão de removê-lo ou escrevê-lo depende de resolver isso — não de escolher
uma das duas no escuro.

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
