# AUDITORIA — o que o `setup.sh` faz, instala e deixa para trás

Documento de auditoria e de reprodução manual. Ele descreve **o estado medido**,
não o intencionado: quando o texto e o script divergem, o erro está no texto, e
este documento existe para que isso seja raro.

Toda tabela aqui tem uma medição por trás. Onde o número é de uma máquina, está
marcado como tal.

---

## 1. Como o script se organiza

Um **módulo** por função, e o perfil decide o que roda.

| perfil | para quê | passos |
|---|---|---|
| `host` | workstation pessoal, hospeda VMs | `base`, `hostname`, `ssh`, `device-keys`, `git`, `tailscale`, `sshd-hardening`, `firewalld`, `vm-host`, `toolbx`, `gui-access`, `desktop-apps`, `opencodex`, `zshrc` |
| `vm` | **fronteira**: agentes, sem exposição na LAN | `base`, `ssh`, `device-keys`, `git`, `gh-app`, `tailscale`, `sshd-hardening`, `podman`, `ai-clis`, `hermes-cli`, `hermes-dashboard`, `open-design`, `open-design-container`, `zshrc` |
| ambos | a parte comum, idêntica nos dois | — |

Opt-in dentro do próprio perfil: **`toolbx`, `gui-access`**.

⚠️ **Antes da correção, dois perfis rodavam um `setup.sh` que não instalava
Hermes nem OpenDesign.** As funções existiam completas e nenhuma era chamada — o
script perguntava o modo do OpenDesign e seguia para o fim. Numa máquina já montada
isso é invisível, porque a instalação foi feita à mão e a mão não aparece no log
do script. Ver `README.md`, e o despacho em `setup.sh` perto do fim.

---

## 2. Portas

| serviço | porta da aplicação | porta publicada |
|---|---|---|
| OpenCode | `127.0.0.1:49374` | `:8443` |
| OpenDesign | `127.0.0.1:7456` | `:8444` |
| Hermes (dashboard) | `:9119` | `:8445` |

⚠️ **A faixa `8443`–`8445` é do `tailscale serve`, não das aplicações.** As
aplicações escutam em loopback ou no IP da tailnet conforme o portão exige, e é o
`serve` que termina TLS. `443` fica reservada.

**Nunca rode `tailscale serve reset`**: derruba os três de uma vez e o comando não
tem como desfazer um por um.

---

## 3. O que cada módulo instala

### `base` — o runtime do host

Pacotes de sistema: **`git`, `gh`, `jq`, `tree`, `tmux`, `zellij`, `ripgrep`, `fd-find`, `unzip`**

Depois: Bun pelo instalador oficial, `mise` (Node e Dev Container CLI pinados),
ativação do mise em `~/.bashrc`, e o link do `devcontainer` para `~/.local/bin`.

⚠️ **`libatomic` e `libX11` estão na lista por um motivo medido, não por catálogo.**
O provisionador `pm` do Hermes baixa binários para a máquina-alvo e **verifica
rodando o binário**; os dois existiam no container Alpine e não no host. Sem eles o
`pm` falha com `error while loading shared libraries` e reporta
`staged entry failed verification ... exited 127`, que não parece falta de
biblioteca.

### `ai-clis` — as CLIs de agente

| | como |
|---|---|
| Claude Code, Codex | `npm install -g` por **presença** do binário |
| DeepSeek Harness (`dsh`) | `npm install -g` pela **versão publicada** — é preview com mudanças incompatíveis declaradas, e o pior candidato possível para um pin |
| Cursor Agent | instalador oficial (`curl`) |
| OpenCode | instalador oficial da linha 2, com trava de major |
| Antigravity (`agy`) | instalador oficial, e um drop-in de PATH para o daemon dele |

⚠️ **O OpenCode não tem pin de versão.** O script consulta o endpoint público que o
próprio instalador consulta, instala a 2 mais recente e não reinstala quando já
está nela. A major é travada em 2 **de propósito**: se a 3 subir para o canal, o
script para e avisa em vez de trocar de major por decisão própria.

### `hermes-cli` — pelo instalador que a documentação prescreve

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
  | bash -s -- --non-interactive --branch "$HERMES_CLI_TAG"
```

O oficial traz o **uv pinado por sha256**, o estado em `~/.hermes` com log em
`~/.hermes/logs/install.log`, e publica o launcher em `~/.local/bin`.

⚠️ **`--non-interactive` não é conveniência.** Os estágios `setup` e `gateway` do
instalador leem `/dev/tty` e só se pulam quando ele **não** abre. O `setup.sh` roda
sob pty, então sem a flag este passo **não termina**.

⚠️ **O instalador tentaria anexar uma linha de PATH no `~/.zshrc`, e aqui não
vai.** A guarda dele casa com a linha 11 do `zshrc` versionado deste repo, e isso
importa porque o `~/.zshrc` daqui é **symlink para o arquivo do repositório**.

### `hermes-dashboard` — a UI, nativa

`hermes dashboard` é subcomando da CLI, então a UI não precisa de container. A
senha entra como **hash scrypt** gerado pelo próprio código do Hermes; o texto puro
fica num arquivo **600** do usuário, e no `config.yaml` nunca.

⚠️ **A unit precisa dos três códigos de exit status.** Medido: porta ocupada devolve
**75**, e o launcher usa **78** para "já está no ar". Sem `SuccessExitStatus=75`,
`RestartForceExitStatus=75` e `RestartPreventExitStatus=78`, o systemd reinicia em
loop.

### `open-design` — dois modos, e a pergunta no bloco de inicial

**nativo** — compila de fonte: `pnpm install` (~1,5 GB), build do daemon, build do
web, e `pnpm deploy` no layout que o daemon espera.

⚠️ **O `pnpm deploy --legacy --prod` NÃO achata o pacote no daemon.** Ele achata o
web, e o daemon não: `resolveProjectRoot` faz `path.resolve(daemonDir, '../..')` e
assume `<projeto>/apps/daemon/dist`. Achatar, o `PROJECT_ROOT` sobe um nível a mais,
o `STATIC_DIR` sai do lugar, e o sintoma é `Cannot GET /` com a API normal. **E o
sintoma se mascara**: com o token ligado, o portão responde 401 antes da rota e o
404 desaparece. Por isso a verificação final é feita em `/` **sem** credencial.

⚠️ **O build do web estoura o heap do V8, não a RAM.** Medido numa máquina com
7,7 GiB livres e `dmesg` sem OOM, com `node::OOMErrorHandler` no topo da pilha. São
duas alavancas, porque o Next cria um worker por CPU e cada um tem heap próprio:
`--max-old-space-size=3072` e `taskset -c 0-3`.

⚠️ **A raiz do build é o próprio clone.** Não há pasta paralela. Com a raiz igual ao
clone, o symlink de `apps/web/out` apontaria para o próprio destino, então ele fica
atrás de um guard que compara a raiz com a origem.

**Escuta em loopback, e não no IP da tailnet.** É o que a documentação do projeto
exige: *"connector endpoints also require the daemon to receive requests over
loopback"*, resolvido no Linux por `network_mode: host`. O motivo está num
comentário do próprio daemon: *"the loopback bypass exists for the localhost desktop
UI which has no proxy in the path"*.

⚠️ **`OD_DISABLE_API_AUTH=1` é o escape hatch que o `deploy/.env.example` do projeto
descreve**, e `docs/deployment/docker.md` o condiciona: *"only when that proxy already
authenticates every request and the daemon is not directly exposed"*. As duas
condições são verdadeiras aqui — o `tailscale serve` termina TLS e autentica pela
tailnet, e o daemon só escuta em loopback, então não há caminho direto até ele.

⚠️ **A ordem do `.env` não é detalhe.** A origem vem **antes** do `.env`, porque o
`.env` a consome. Com `set -u`, usar a variável antes de defini-la aborta com
"unbound variable" — e o modo silencioso deste script é o que dói: o `.env` sai
**vazio**, o daemon sobe com o auth ligado, e o sintoma aparece muito depois, como um
401 que ninguém liga a esta linha.

**container** — `podman compose` puro, sem unit. Existe como alternativa e exige
`podman-compose`, que é um pacote que o perfil `vm` **não** instala.

### `podman`, `tailscale`, `sshd-hardening`, `firewalld`, `gh-app`

Container rootless, subuid/subgid, `podman.socket` desabilitado, linger habilitado.
Tailscale para a tailnet. SSH com chave apenas. GitHub App para as chaves de
dispositivo.

**O `firewalld` instala e sobe, e não marca mais nada.** Até 2026-09-30 ele marcava
`tailscale0` na zona `trusted` — que libera TODO o tráfego da interface, e que o
`ARQUITETURA.md` chamava de "o elo errado da cadeia" desde o começo. A marcação saiu:
virou decisão de quem está na máquina, executada à mão, e o script só diz qual é o
comando. O que ele faz no lugar é a **pós-condição** — verificar que a zona em que a
`tailscale0` caiu **permite `ssh`**, que é o que garante que o Mac consegue entrar.
Um firewall recém-habilitado é o componente que pode fechar o caminho de entrada, e o
motivo de a verificação existir é a mesma classe do primeiro bloqueio numa VM limpa: o
`sshd` nunca subir, e o jeito de descobrir é ficar sem entrada.

**Medição que muda o cálculo de risco:** o `firewalld` **não filtra** as portas do
`tailscale serve`. Com a `tailscale0` amarrada na zona `public` — que não abre porta
nenhuma além de `ssh` — as três respostas continuaram `200 / 200 / 302`. As regras
netfilter do próprio Tailscale aceitam o tráfego antes das regras de zona. Por isso a
remoção da `trusted` **não tirou publicação nenhuma**, e por isso este script não abre
porta alguma: abrir seria corrigir um problema que a medição diz que não existe.

---

## 4. Custo de disco de uma instalação limpa

Medido nesta VM, e **sem contar as duplicações** que o layout antigo impunha.

### O que o `usage` mostra, e o que é cache

| | tamanho | regenerável |
|---|---|---|
| `~/.hermes/tools` | 1,6 GB | não — é o runtime provisionado |
| `~/.hermes/installs` | 1,6 GB | não — idem |
| `~/.hermes/cache` | 466 MB | **sim** |
| clone `node_modules` | 2,8 GB | **sim** — `pnpm install` |
| store do pnpm | 2,7 GB | **sim** — cache de download |
| `apps/web/out` | 115 MB | **sim** — `pnpm build` |
| `apps/daemon/dist` | 26 MB | **sim** — `pnpm build` |
| `~/.opencode` | 194 MB | não — o binário |
| mise (runtimes) | 404 MB | não |
| **estado que não se regenera** | `config.yaml`, `auth.json`, sessões, `state.db`, skills, senhas — tudo abaixo de 5 MB | **não** |

### A duplicação que a raiz paralela impunha

A raiz `open-design-native-root` media **948 MB**, dos quais:

| | |
|---|---|
| `apps/daemon/node_modules` | **921 MB** — uma segunda árvore de dependências, a de produção |
| `apps/daemon/dist` | 26 MB — cópia do que o clone já tem |
| `apps/web/out` | não ocupava: era um **symlink** para o clone |

Como a raiz passou a ser o próprio clone, os 921 MB da árvore de produção
desaparecem: as dependências sobem para o `node_modules` da raiz. **A fusão
economiza ~947 MB de duplicata.**

### O número para provisionar

| | |
|---|---|
| partição usada nesta VM | **12 GB de 38 GB (31%)** |
| home inteira, por `du` | 17 GB |
| **instalação limpa, sem cache e sem a raiz paralela** | **~10 GB** |

Uma VM de 38 GB sobra com folga; 25 GB já fecha.

---

## 5. O que exige mão humana

Nada disto é instalação — é configuração, ou é opt-in.

| | quando |
|---|---|
| **colar a private key da GitHub App** | perfil `vm`, primeira vez. O `setup.sh` **não tem como** promptar por arquivo; é o passo mais inevitavelmente humano |
| `hermes model` | o instalador novo deixa `model: ""`, sentinela explícita de "não configurado" |
| `hermes gateway setup` + `install` | **fora do script, por decisão.** A unit gerada guarda o caminho do executável; se a CLI mudar de caminho, é preciso `install` de novo |
| `sudo loginctl enable-linger` | o módulo `podman` já faz; o aviso existe para quem roda com `--only` |
| `sudo dnf install podman-compose` | **só** no modo container |
| `sudo tailscale serve …` | **só** se rodar `ai-clis` antes do módulo `tailscale` |
| `ocx start` | OpenCodex, opt-in, proxy de terceiros |
| **`tailscale up` sem chave** | imprime uma URL e espera autenticação humana. Ver §9.7 |

⚠️ **O prompt do modo do OpenDesign não tem default, e isso é deliberado.** Sem
resposta — EOF, ou o passo pulado com `--only` — a saída correta é **não instalar**.
Uma entrada inválida repregunta; em EOF o `read` falharia para sempre e um
`while :` sem esse teste trava o script indefinidamente.

---

## 6. Decisões conhecidas e o que cada uma custa

| decisão | o que se ganha | o que se paga |
|---|---|---|
| **Tailscale SSH desligado**, VM em NAT | a entrada é `ssh` normal, com a hardened config | sem acesso se a chave se perder |
| **OpenCode sem pin de versão** | a máquina não fica presa numa versão | acompanha a major 2; se a 3 subir, o script **para e avisa** |
| **sem evidência de sessão filha** (opencode 2.x) | o agente roda, os 7 agentes são detectados, a transcript da raiz salva | **`--pure` é a garantia de que um plugin não executa no caminho de evidência, e ela não existe no 2.x.** A degradação é **silenciosa** |
| **gateway do Hermes manual** | o script não duplica a documentação do produto | três comandos a mais numa VM nova — e a unit gerada prende o caminho do executável |
| **nenhuma marcação de zona no `tailscale0`** | a interface fica na zona padrão, que já abre `ssh`; e medido: o `firewalld` não filtra as portas do `tailscale serve`, então nada foi perdido | quem quiser a `trusted` precisa rodar o comando à mão — a decisão sai do provisionamento e vira uma escolha de quem está na máquina |
| **`shields-up` do Tailscale desligado** (o default do produto) | o nó continua alcançável pelos outros nós da tailnet, que é o que o provisionamento espera | **qualquer nó da tailnet alcança as portas que a máquina escuta** — é a mesma exposição da `trusted`, em um controle que o script nunca pergunta. Medido: `ShieldsUp: False`, e o default do binário também é `False`. Fica registrado, não perguntado |
| **`device-keys` com default sim** | o `authorized_keys` sai populado, e é o que permite ao `sshd-hardening` desligar a senha em seguida | a cadeia de entrada passa a depender da conta `rvlmt` no GitHub, e o acesso é revogado **indireto e diferido**: sai-se a chave lá, e ela perde o acesso na próxima execução deste módulo |
| **hardening com default sim na VM, não no host** | a senha do SSH — a credencial mais exposta da VM — fica desligada sem depender de alguém responder "y" numa lista | a assimetria entre os perfis é uma decisão, e ela precisa continuar visível: quem provisionar um host recebe `[y/N]`, e a diferença está documentada no `README` e nesta tabela, não na chamada do prompt |
| **nenhuma versão pinada por número** | o `base` não pode falhar porque um número saiu do registro | o **pnpm** salta de major (10.33.2 → 12.x) contra um lockfile `9.0` |
| **`--yes` para rodar sem terminal** | provisionamento não interativo, com o default ainda sendo **não** | **o `sudo` continua pedindo senha** — a flag tira as perguntas do script, não as do sudo |
| **raiz do build = o clone** | o caminho é o que a doc do OpenDesign espera; −947 MB | o clone ganha arquivos não rastreados, e `git status` mostra |
| **`gpgcheck=0` no repo do Antigravity** | o repo **não publica chave** — os dois `.repo` dão 404 e não há `gpgkey` | pacotes desse repo sem verificação de assinatura. É do perfil `host`, não afeta a VM |
| **senhas padrão** (`hermes`, `opencode`) | nada a configurar | adivinhável por quem conheça a convenção |

### A incompatibilidade do adaptador de evidência, em detalhe

`dist/runtimes/opencode-child-evidence.js` declara
`OPENCODE_CHILD_EVIDENCE_CLI_VERSION = '1.18.18'`, e **é um registro, não um gate**:
nada no daemon compara a constante com o binário, então o adaptador não consegue
avisar que a versão mudou.

O `export` **não sumiu** — virou `session export`, e `--sanitize` existe com a
descrição *"Redact sensitive transcript and file data"*. O que falta no 2.x é
`--pure`, sem substituto na lista de subcomandos.

**Para reverter:** fixar o opencode na `1.18.18`, que é a versão que a constante
declara.

---

## 7. Reproduzir sem o script

A ordem, e o que cada passo é:

```bash
# 1. runtime
sudo dnf install -y --skip-unavailable git gh jq tree tmux zellij ripgrep \
  fd-find unzip curl wget btop tar openssl dnf5-plugins libatomic libX11
curl -fsSL https://bun.sh/install | bash
# mise, com o Node e o Dev Container CLI pinados

# 2. o OpenCode, pelo instalador oficial da linha 2
curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path

# 3. o Hermes, pelo instalador oficial
curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
  | bash -s -- --non-interactive --branch rc.14-v0.21.5

# 4. o OpenDesign, compilando de fonte
git clone --depth 1 https://github.com/nexu-io/open-design.git ~/Developer/open-design
cd ~/Developer/open-design
pnpm install --frozen-lockfile
pnpm --filter @open-design/daemon build
cd apps/web && NODE_OPTIONS=--max-old-space-size=3072 taskset -c 0-3 pnpm build
cd .. && cd .. && pnpm --filter @open-design/daemon deploy --legacy --prod apps/daemon
```

As units **não** são lidas de instalador nenhum, em nenhum dos três: são declaradas.
A do OpenCode porque a v2 não cria unit; a do dashboard porque ela precisa dos três
códigos de exit status; a do OpenDesign porque o modo nativo é uma unit de usuário
com `WorkingDirectory` na raiz do build.

---

## 8. O que este documento não garante

Os números são de **uma** VM, e o próprio `ARQUITETURA.md` diz que o estado de um
host não é evidência sobre o padrão. O que muda com o tempo e precisa ser
remedido: as versões publicadas, o canal do OpenCode, os digests pinados, e as
medições de disco.

O que **não** muda: as armadilhas de layout, de ordem e de heap. Essas estão
descritas acima com a medição que as revelou, e nenhuma delas se resolve sozinha.

## 9. O que a VM limpa mostrou

Tudo nesta seção é medido numa **Fedora 44 Workstation Edition recém-criada**,
nunca vista pelo script antes. A VM de agentes é Fedora 43, então não é repetição:
são duas imagens diferentes, e o que está aqui só apareceu na segunda.

### 9.1. O primeiro bloqueio: o `sshd` não estava no ar

| | |
|---|---|
| sintoma | porta 22 **"connection refused"** — não filtrada |
| prova | `tailscale ping` responde e o nó está online: os pacotes chegam, e a máquina recusa porque não há ouvinte |
| causa | o script nunca sobe o serviço; o `sshd-hardening` fazia só `reload`, que falha contra unidade parada |
| entrada possível | só o console, para um `systemctl enable --now sshd` à mão |

Corrigido nos módulos `ssh` e `sshd-hardening`. A duplicação é deliberada: o
`ssh` sobe cedo porque é o que permite desligar `PasswordAuthentication` sem
janela de risco, e o `sshd-hardening` cobre o caso de `--only=sshd-hardening`.

### 9.2. `libatomic` e `libX11` **já vêm** nesta imagem

A afirmação "não vem no Fedora" era verdadeira na VM de agentes, de imagem menor,
e **falsa nesta**. As duas estão instaladas numa Workstation Edition recém-criada.

O que não muda é o porquê de estarem na lista do `base`: o `pm` do Hermes baixa
binários para a máquina-alvo e **verifica rodando**, então biblioteca faltando
vira `staged entry failed verification ... exited 127`. E `libX11` não era
verificado em lugar nenhum antes de entrar na lista — foi ela que faltou na
máquina onde a `libatomic` já estava.

### 9.3. O que o mise grava, e por que ainda acompanha a última

`~/.config/mise/config.toml` depois do `base`:

```
[tools]
devcontainer-cli = "0.89.0"
node = "lts"
```

**Um alias é gravado como alias, e um número explícito como número.** O que decide
isso é a forma do argumento, não o `--pin`. Passar `node@lts` é o que preserva o
alias, e é por isso que a máquina continua acompanhando: cada execução re-resolve
o `lts` e reescreve a linha.

O aviso do `mise install` — *"installed but not activated"* — é **esperado**: ele
instala e não ativa; quem ativa é o `use` logo em seguida. Trocar a ordem deixaria
o runtime instalado e não ativado.

### 9.4. O `base` não é um módulo pequeno

`sudo dnf upgrade --refresh` numa imagem Workstation puxou **835 pacotes** —
`linux-firmware`, `iwlwifi-mvm-firmware`, `nvidia-gpu-firmware`, entre outros.
São centenas de MB de firmware numa máquina que talvez nem tenha GPU.

Vale decidir conscientemente: quem não quer um upgrade completo do sistema no
módulo `base` precisa saber que ele está lá.

### 9.5. O `sshd-hardening` vai pular nesta VM

O módulo tem uma guarda que é uma das melhores peças do script: se
`~/.ssh/authorized_keys` está vazio, ele **não** desabilita login por senha, porque
faria isso trancar a máquina para fora. Medido aqui: `authorized_keys` está vazio,
então o hardening vai pular e avisar.

A correção é deliberada e manual: cadastrar a chave pública de onde você acessa
antes de rodar o módulo.

### 9.6. O repositório é privado, e o `git clone` falha

`gh repo view` confirma: `PRIVATE`. Uma VM nova não consegue `git clone` direto sem
`gh` autenticado, o que por sua vez depende da GitHub App, que depende de uma
chave privada colada por alguém. **O primeiro passo do procedimento numa VM limpa
não é coberto pelo script.**

Neste teste o repositório foi levado por `tar` sobre `ssh`, e o `tree` conferido
nos dois lados.

### 9.7. O `tailscale up` não tem caminho não interativo

O módulo roda `sudo tailscale up` sem chave de autenticação: ele imprime uma URL e
espera a autenticação humana. Numa máquina já autenticada, o módulo detecta e não
faz nada — medido aqui, "Tailscale já conectado", e o `BackendState` continuou
`Running` com o mesmo IP.

Mas provisionar do zero exige abrir a URL. Um `--authkey` lido do ambiente seria o
caminho, e é o que falta para o perfil `vm` ser automatizável de ponta a ponta.


## 10. As correções que a VM limpa obrigou, e o padrão delas

§9 é o que a máquina **mostrou**. Esta é a lista do que foi **corrigido**,
e ela é a parte que importa para a próxima: nenhuma das oito aparece em
`bash -n`, e **nenhuma reclama**. Todas devolvem 0 ou saem em silêncio.

| | o que era | como se manifestava |
|---|---|---|
| `sshd` | nunca era subido | porta 22 recusada, sem entrada |
| relatório do `ai-clis` | `command -v` sem fallback para `~/.opencode/bin` | "binário ausente" no módulo que o instalou |
| `hermes-cli` | idempotência por **nome** de tag | reinstalava tudo a cada run |
| dashboard | `read -d ''` devolve 1 no EOF | unit faltando, sem mensagem |
| dashboard | crase em here-doc sem aspas | `command not found` |
| dashboard | `PYTHONPATH` com caminho morto e archive arbitrário | "não consegui gerar o hash scrypt" |
| open-design | guard comparava `native` com `nativo` | módulo não fazia nada |
| open-design | nada publicava o `:8444` | link anunciado não existia |

### O padrão: um guarda que erra não falha, finge que não é a vez dele

O caso do `native`/`nativo` é o arquétipo. O `case` da pergunta aceita
`nativo | container`; os dois wrappers comparavam com `native`, em inglês. O
guarda é `|| return 0` — "não é o meu modo", **sucesso** — então o modo errado
caiu exatamente no mesmo caminho do modo certo, e o `|| echo` do despacho nunca
reclamou.

O mesmo em `read -d ''`: procura um byte NUL, não acha, devolve 1, e o `set -e` na
linha 2 mata a execução no meio de uma função. O chamador só vê a unit faltando.

E o mesmo no `PYTHONPATH`: apontava para um caminho que não existe mais e para
`find | head -1` num cache de **106 entradas**, sendo a primeira em ordem
alfabética um pacote sem relação. Funcionava ou não, depende do acaso.

### Uma máquina montada esconde as oito

O que as sete tinham em comum: **o trabalho que elas deveriam fazer foi feito à
mão**. O `sshd` foi habilitado no console; as units foram escritas à mão; o Hermes
era a instalação antiga em `~/Hermes-Agent`. Nenhuma dessas mãos aparece no log
do script, e nenhuma delas é detectável sem provisionar do zero.

### O caso mais instrutivo: eu removendo um passo documentado

O `corepack enable` saiu na revisão da lista de pacotes do `base`, com a medição
correta — o corepack resolve a versão declarada dentro do repo mesmo sem o shim
global. A conclusão é que estava errada, e o erro foi de método: **um passo
documentado foi removido sem que nenhuma medição contradição a documentação.**

O `CONTRIBUTING.md` do OpenDesign diz, na linha 33:

    corepack enable           # selects the pinned pnpm from packageManager

e o README repete em dois lugares. O projeto dá nome ao que o passo faz, e a
medição minha tinha encontrado um caminho lateral que funcionava. **Funcionar por
um caminho que ninguém documentou não é o mesmo que seguir o manual** — e a regra
que vale desde o começo desta sessão é que a documentação da aplicação vem antes
da medição própria.

### Um diagnóstico que mede o objeto errado

O módulo do OpenDesign anunciava `pnpm em uso: 12.8.1` enquanto o build usava
10.33.2. Um splice meu tinha deixado a atribuição antiga do `pnpm_ver` para trás,
e ela lia a versão **na raiz do script**, não dentro do clone. Isolado funcionava;
no script, mentia.

Um diagnóstico que reporta o objeto errado é pior do que nenhum: é confiável,
está errado, e ninguém o confere de novo — quem lê supõe que o número veio de
onde o trabalho acontece.

### O que a máquina derrubou do que eu escrevi

| eu afirmava | medido |
|---|---|
| `libatomic` e `libX11` não vêm no Fedora | **já vêm** nesta imagem |
| o corepack não honra o `packageManager` | honra — eu medi **fora do repo** |
| o pin do Hermes é `rc.14` e é o caminho certo | a latest release é `v2026.9.24`, **outro commit** |

A do corepack é a mais instrutiva porque eu tinha **medido**: rodei
`pnpm --version` e li 12.8.1, que é o default global, e escrevi no código que o
projeto ignorava a própria declaração. Dentro do repo, a resposta é 10.33.2. O
erro não foi não medir — foi medir e não conferir o que eu media.

### A regra que apareceu no fim, e que é aplicável a qualquer lista

**Todo pacote declara quem o consome; se ninguém declara, ele sai.** Medido: a
única ocorrência de `tree`, `tmux`, `zellij`, `ripgrep`, `fd-find`, `btop` e
`wget` no script inteiro era a própria lista. Vieram no **primeiro commit do
repositório**, há 20 dias, no commit que separa o provisionamento do Fedora do
repo do Mac — e em vinte dias ninguém podou. A segunda metade da regra é a que
impede a lista de inflar de novo: quando o consumidor é um instalador externo, isso
é dito na linha. `tar` e `unzip` são esse caso — o mise e o Bun os chamam, dentro
dos instaladores que o próprio `base` executa.

### Fica registrado e não contornado

O `.env` com o `OD_API_TOKEN` cai **dentro do clone** do OpenDesign, e o
`.gitignore` do upstream não o cobre — `git status` mostra `?? .env` e
`git check-ignore` não acha nada. Um `git add -A` nesse clone commitaria a
credencial. O impacto é baixo, porque o modo nativo vem com
`OD_DISABLE_API_AUTH=1` e o script diz isso onde escreve o arquivo: ali o token
não é credencial viva. A correção é do upstream, e é por isso que fica registrado
em vez de contornado.

---

