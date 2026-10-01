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
| `vm` | **fronteira**: agentes, sem exposição na LAN | `base`, `hostname`, `ssh`, `device-keys`, `git`, `gh-app`, `tailscale`, `sshd-hardening`, `podman`, `ai-clis`, `hermes-cli`, `hermes-dashboard`, `open-design`, `open-design-container`, `zshrc` |
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
| **nome: `<papel>-<os>-<4 do machine-id>`**, default nos dois perfis | a máquina se nomeia sozinha, sem ninguém digitar, e o `papel` concorda com o que a pessoa pediu na linha de comando. Medido: `vm-fedora-c104` na VM, `pc-fedora-4bd9` no host | o `DDMM` da proposta saiu — data não acrescenta nada sobre um id único e mudaria todo dia, o que faria um re-run propor outro nome para uma máquina já correta. O `papel` vem do perfil e **não** de detecção de hardware, que o systemd faria bem (`desktop`/`vm` medidos): o perfil já declara o papel, e detectá-lo é medir de novo o que já foi dito. E o `machine-id` vem numa **imagem clonada** junto, por isso o módulo confere a tailnet e avisa se outro nó já estiver com ele |
| **`device-keys` com default sim** | o `authorized_keys` sai populado, e é o que permite ao `sshd-hardening` desligar a senha em seguida | a cadeia de entrada passa a depender da conta `rvlmt` no GitHub, e o acesso é revogado **indireto e diferido**: sai-se a chave lá, e ela perde o acesso na próxima execução deste módulo |
| **hardening com default sim na VM, não no host** | a senha do SSH — a credencial mais exposta da VM — fica desligada sem depender de alguém responder "y" numa lista | a assimetria entre os perfis é uma decisão, e ela precisa continuar visível: quem provisionar um host recebe `[y/N]`, e a diferença está documentada no `README` e nesta tabela, não na chamada do prompt |
| **nenhuma versão pinada por número** | o `base` não pode falhar porque um número saiu do registro | o **pnpm** salta de major (10.33.2 → 12.x) contra um lockfile `9.0` |
| **`--defaults` para rodar sem terminal** (`--yes` é alias) | provisionamento não interativo com uma semântica coerente: a flag aceita **o default de cada pergunta**, e os defaults são escolhidos para que "default" signifique "provisionar" | o nome antigo significava "responde sim a tudo", e como nove dos nove prompts tinham default "não" isso **invertia cada opt-in** — medido: o run travava para sempre no handshake do `gh`. E há um preço mesmo com a semântica nova: quemprovisiona com a flag **não vê nenhuma pergunta**, então precisa ler a saída para saber o que foi assumido |
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
e ela é a parte que importa para a próxima: nenhuma das dez aparece em
`bash -n`, e **nenhuma reclama** — ou reclama o contrário do que anuncia.

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
| `confirm` | `return "$default"` num default de "sim", e `confirm` devolve **1** para não | a pergunta anunciava `[Y/n]` e o Enter respondia **não** — e o harness passava 75/75 |
| `sshd-hardening` | decidia por `[ -f ]` num arquivo sob diretório **700** | a pergunta repetia a cada run e o `else` "já aplicado" era **código inalcançável** — o drop-in era reescrito e o `sshd` recarregado em toda execução |
| `--yes` | respondia sim a **tudo**, e nove dos nove prompts tinham default "não" | **travava para sempre** no handshake do `gh`, que é uma pergunta dele — e antes disso inertiava o lock do root, o OpenCodex e a sobrescrita do `~/.zshrc` |
| `--help` | o `usage` usa `cat <<EOF` sem aspas, e o texto novo tinha crase | `bash setup.sh --help` **executava o `gh`** e colava o help dele no meio do nosso, **sem nenhuma linha de erro** |

### A nona, e a primeira que o harness não pegou

As oito acima têm um traço em comum: **nenhuma reclama**. Devolvem 0, ou saem em
silêncio, e o `bash -n` passa. A nona é a primeira que **anuncia uma coisa e faz
outra** — e ela passou pelo harness inteiro porque nenhuma das 75 verificações
respondia vazio a uma pergunta de default sim.

O que era: `confirm` ganhou um segundo argumento, o default, para que "por padrão"
e "sempre" fossem coisas diferentes que o script dissesse. E o Enter vazio passou a
valer o default declarado. Só que `confirm` devolve **0 para sim e 1 para não**, e o
código novo fazia `return "$default"` — que num default de "sim" devolvia 1. Um
Enter na pergunta que anunciava `[Y/n]` respondia não.

Achado rodando o script na VM, não lendo o código:

```
Autorizar nesta máquina as chaves de dispositivos que o GitHub reúne (…)? [Y/n]
==> Chaves de dispositivos (GitHub)
  Chaves de dispositivos: não autorizado.
```

A lição tem duas partes, e a segunda é a que importa mais. A primeira é que
função que devolve status precisa de teste que olhe o **efeito**, não o texto da
pergunta: o `device-keys` escreve no `authorized_keys`, então "o arquivo tem chave"
e "o script autorizou" são a mesma coisa vista de dois lados. A segunda é que um
harness só cobre o que alguém imaginou perguntar — 75 verificações, nenhuma delas
sobre a combinação "pergunta nova" + "Enter", que é exatamente a que a mudança
introduzia.

O teste que faltava foi escrito, e ele prova os **dois** sentidos: que um Enter
numa pergunta de default sim autoriza, e que um Enter numa de default não continua
recusando — a garantia de que nenhum dos outros prompts mudou de comportamento por a
assinatura passar a aceitar um argumento a mais.

✅ **O harness agora está no repositório, em `tests/`, e a cobertura deixou de ser uma
propriedade desta sessão.** Até 2026-10-01 ele vivia em `/tmp` — as 96 checagens, o
`ptyfile2.py` e os arquivos de entrada — e morria com a máquina. Era uma frase honesta
sobre o estado, e ao mesmo tempo uma frase que tornava a cobertura disposable.

Trazer os arquivos foi a parte fácil, e é por isso que vale registrar o que apareceu no
caminho: **quatro dos nove scripts que eu chamava de teste não eram testes.** Três
imprimiam observações e saíam com `0` sempre. E dois deles paravam **serviços reais**,
sem stub: `systemctl --user stop opencode.service` e
`systemctl --user stop hermes-dashboard.service`, numa máquina que pode ter o serviço no
ar. Num host provisionado por este repo o `opencode.service` está no ar, e o primeiro
deles pararia o serviço de que uma sessão de agente depende.

Sobre a causa dos reinícios desta máquina durante aquele trabalho, o registro honesto é
este: o `opencode.service` já estava `failed`, então o `stop` foi no-op, e **não há
medição que ligue um ao outro**. O que é medido é que o teste é inseguro por
construção. A distinção é a mesma que a auditoria aplica a um diagnóstico: correlação
não é prova, e uma afirmação sobre causa que não foi medida é um defeito, mesmo
quando a hipótese parece óbvia.

E dois outros caíram por **teste podre com causa documentada**: `test-own-opencode.sh` e
`test-serve.sh` contam falhas e saem com `1` corretamente, mas dirigem
`setup_opencode_service` por `OPENCODE_BIND` e `OPENCODE_PORT` — variáveis que o
`setup.sh` diz, na linha 110, não existirem no opencode v2, com a medição do binário de
203 MB ao lado. O código abandonou uma entrada que o produto nunca teve, e eles
continuam afirmando que ela funciona. Estão em `tests/fora/`, com o motivo escrito.


### A décima: um check que não está errado no que pergunta, e sim em quem pergunta

Esta é a melhor das dez como caso didático, porque o check **parece** perfeito. Ele
pedia a coisa certa — "o hardening já foi aplicado?" — e testava o arquivo que
escreve a resposta. O problema é que o teste era feito **sem privilégio**, e o
diretório que guarda o arquivo não deixa passar quem não é root:

```
/etc/ssh/sshd_config.d          drwx------ root:root     ← modo 700
99-dotfiles-hardening.conf      -rw-r--r-- root:root     ← legível por todo mundo

[ -f ... ]  como usuário   -> FALSO          (o que o script testava)
sudo test -f ...          -> VERDADEIRO
ls ...  como usuário      -> "Permission denied"
```

O arquivo é legível; o **caminho** não é atravessável. E um `[ -f ]` que não
consegue resolver o caminho responde "não existe" — que é uma resposta plausível,
silenciosa, e errada.

O mesmo teste, com e sem privilégio, lado a lado na VM:

| | resposta |
|---|---|
| `[ -f ]` como usuário | **FALSO** |
| `[ -r ]` como usuário | **FALSO** |
| `[ -f ]` com `sudo` | **VERDADEIRO** |

E o efeito era duplo, e nenhum dos dois reclamava:

1. A pergunta *"Desabilitar login por senha via SSH?"* aparecia em **toda**
   execução, mesmo com o hardening aplicado há semanas.
2. O `else` que dizia *"já aplicado"* era **código inalcançável** — o módulo
   reescrevia o drop-in e recarregava o `sshd` em cada run, para produzir um
   resultado idêntico ao que já estava lá.

O estado final estava **correto** o tempo todo. `sshd -T` respondia
`passwordauthentication no` e `permitrootlogin no`, o access por chave funcionava, e
nenhum sintoma aparecia. É a assinatura dos outros nove: nada falha, nada reclama.

**A correção é a propriedade, não o `sudo`.** `_sshd_hardened` pergunta a
configuração já resolvida, com `sudo -n sshd -T`, e isso é imune à permissão porque
responde com privilégio. Verificado na VM, depois da correção:

```
==> Hardening do sshd
sshd já está rodando.
✓ sshd já endurecido (PasswordAuthentication no, PermitRootLogin no) — nada a fazer.
```

**E a parte que a primeira versão do comentário.anticipou errado.** A função foi
escrita com a afirmação de que a pergunta deixaria de repetir. Ela continua
repetindo, e a medição diz por quê: no bloco de perguntas o `sudo` ainda não rodou,
o timestamp está frio, `sudo -n` falha, e a função devolve falso. Fazer a pergunta
depender do estado exigiria subir o `sudo -v` para antes dela — o que muda o lugar
em que a senha é pedida. Essa é uma decisão de quem provisiona, e o que fica é o
**atrito de um prompt**, não mais a reescrita e o reload. O comentário agora diz
isso, e a tabela de testes estruturais ganhou uma checagem que falha se alguém
voltar a decidir esse caminho por `[ -f ]`.

**Um detalhe sobre a mesma armadilha, em outro lugar.** O here-doc que escreve o
drop-in estava **sem aspas** (`<<EOF`), e o conteúdo — `PasswordAuthentication no`,
`PermitRootLogin no` — não tem `$` nem crase. Funciona hoje. É o mesmo defeito da
crase que esta seção documenta, na mesma função, e a correção foi uma aspa: não
depender de o conteúdo não ter nada especial.


### A décima primeira: uma flag que respondia "sim" quando o default era "não"

O `--yes` existia há semanas e **nunca tinha rodado**. Quando rodou, na VM, ele não
terminou: parou em

```
==> Git e GitHub CLI
Iniciando handshake com o GitHub via navegador...
? Authenticate Git with your GitHub credentials? (Y/n)
```

e ficou ali. A causa é uma inversão que só aparece quando os dois lados estão juntos:

1. `confirm` sob a flag devolvia **0 incondicionalmente** — "sim" para tudo.
2. **Nove dos nove** prompts do script têm default **não**.

"Responder sim a tudo" era, portanto, o mesmo que **inverter cada opt-in**. E o que
inverteu primeiro foi o login de pessoa do `gh`, que dispara `gh auth login -w`: uma
pergunta **do `gh`**, que nenhuma variável deste repositório alcança. O run não podia
terminar, e o script não tem como evitar isso depois de disparado.

Antes de chegar lá, o `--yes` já teria travado a senha do root, instalado o proxy do
OpenCodex, sobrescrito o `~/.zshrc` e exigido uma senha para o servidor do OpenCode.

**Nada disso é novidade**: é o nono defeito desta lista com a
inversão trocada. Os outros devolvem 0 em silêncio; este **promete uma coisa e faz a
oposta**, que é a variante que um `bash -n` não vê e que um log sem leitura não
denuncia.

A correção é de semântica, e a decisão foi do dono do repo: a flag passa a responder
**o default de cada pergunta**, e os defaults são escolhidos para que "default"
signifique "provisionar". O que está na lista de passos do perfil tem default sim — o
hostname, as chaves de dispositivo, o hardening, as CLIs de IA, a senha do OpenCode; o
que seria entrada para um serviço externo ou destruição de credencial tem default não —
o login do `gh`, o OpenCodex, travar a senha do root, sobrescrever o `~/.zshrc`. Com
isso a flag **não trava por construção**, e não por sorte de ordem.

E o nome mudou para `--defaults`, com `--yes` de alias, porque o nome antigo é a
descrição errada do comportamento.

### A décima segunda: eu escrevendo uma crase no heredoc que eu mesmo documentara

O texto do `--help` que anunciava essa mudança foi escrito com `gh` entre crases. O
`usage` usa `cat <<EOF` **sem aspas** — e precisa sem aspas, porque é o que expande
`$HOST_STEPS` na linha de módulos. Resultado medido:

```
$ bash setup.sh --help | grep -c 'CORE COMMANDS'
2
```

O `--help` **executou o `gh`** e colou o help dele no meio do nosso.

É o defeito que a seção das crases já descreve, e eu escrevi o texto que o reproduziu
duas horas depois de documentá-lo. A diferença que vale registrar: no here-doc do
dashboard a crase dava `command not found`, que é um erro visível; aqui não houve
**nenhuma linha de erro** — só a saída errada, que é a forma mais difícil de perceber
que existe. A correção é uma aspa de diferença no texto, e ali a proteção que ficou é
uma checagem estrutural: o `--help` não pode conter a saída de outro programa.


### O run que alinhou 12 prompts de 13, e o que ele diz sobre medir

O run completo na VM de agentes foi dirigido por um arquivo de entrada **posicional**:
cada linha responde a uma pergunta, na ordem em que o script faz. A primeira tentativa
alinhou 12 de 13 e morreu no `sudo`, e a causa é o tipo de erro que vale mais registro
que o sintoma.

Eu havia medido se o `~/.zshrc` da VM era symlink, e concluí que a pergunta do `zshrc`
ia aparecer. **Não medi se o arquivo existia** — e a pergunta só dispara com
`[ -e "$HOME/.zshrc" ] || [ -L "$HOME/.zshrc" ]`. O arquivo não existia, a pergunta não
apareceu, e a linha a menos desalinhou o resto: o `y` destinado ao `zshrc` foi
consumido pelo login do `gh`, e a senha do `sudo` ficou sem par:

```
Autenticar o 'gh' com login de pessoa? (Enter = não; …)
1234
Sorry, try again.
[sudo] password for agent:
sudo: timed out reading password
```

A entrada posicional é o que torna isso caro. Ela não tem como reportar "não recebi a
pergunta que eu esperava" — ela apenas entrega a linha seguinte para quem aparecer. Um
defeito de leitura do código e um defeito de medição produzem **a mesma** assinatura no
transcripto, e só a medição separa os dois.

A correção não foi arrumar a linha: foi **derivar a entrada do estado**. O script que
gera o arquivo de entrada verifica a precondição de cada pergunta antes de contar, e
cada linha sai com a condição que a produziu:

```
  4. sshd-hardening: Enter, e na VM o default e SIM
  --  zshrc: SEM pergunta, nao ha ~/.zshrc — o modulo cria o link sozinho
  12. private key: Ctrl-D, e o \n colado responde o login do gh
  13. sudo
```

E a lição vale para qualquer harness dirigido por entrada posicional: **uma
precondição medida pela metade é um bug que ainda não aconteceu.** Verificar se a
maioria das condições continua igual é a forma de garantir que nenhuma mudou.


### A décima terceira: um default novo que teria entregado uma VM quebrada

O `container` passou a ser o default do OpenDesign, por decisão do dono. O
código tinha um comentário que dizia, com razão, que isso não podia ser feito:

> Escolher `container` aqui seria instalar o modo alternativo, e ele exige um
> pacote que o perfil `vm` não instala.

O comentário estava certo, e a medição na VM foi mais dura que ele:

```
$ podman compose version
Error: looking up compose provider failed
$ command -v podman-compose
(nada)
$ dnf list --available podman-compose
podman-compose.noarch 1.6.0-1.fc44 updates
```

Ou seja: o modo container **não funcionava numa VM limpa**, porque nada instalava
o provider, e o script só resolvia isso mandando o operador instalar o pacote à
mão. O default novo, sozinho, teria trocado "não instala" por "instala e falha".

A ordem é o que importa: o `podman-compose` entra no passo `podman`, e **depois**
o default vira `container`. E foi verificado que instalar o pacote resolve:

```
$ sudo dnf install -y podman-compose
$ podman compose version
>>>> Executing external compose provider "/usr/bin/podman-compose".
```

Um default é uma promessa sobre o que a máquina vai ter. Trocar o default antes
de instalar o pré-requisito não éprovisionar mais rápido; é deslocar a falha.

### A décima quarta: dois `.env`, e só um deles era visível para o git

O dono transcreveu o README do OpenDesign, e ele diz o caminho certo: `cd deploy`,
`cp .env.example .env`, `openssl rand -hex 32`, colar em `OD_API_TOKEN=`, e só
então `docker compose up -d`. O token é **gerado** — a minha caracterização
anterior, de "segredo prévio à instalação", estava errada, e o script já estava
certo: a pergunta diz "vazio = gerar um" e gera com `openssl rand -hex 32`.

O que a transcrição expôs foi outra coisa, e a medição no clone resolveu qual
dos dois arquivos era o problema:

| arquivo | `git check-ignore` | tem o token |
|---|---|---|
| `deploy/.env` — modo container | `deploy/.gitignore:2:.env` | sim |
| `.env` na raiz — modo nativo | **nada** — `git status` mostra `?? .env` | sim |

O modo container já escrevia no caminho documentado, e o próprio upstream o
ignora. O modo **nativo** escrevia na raiz, onde nada o ignorava. A correção vai
para `.git/info/exclude` — estado local do clone, nunca commitado, e não suja um
`.gitignore` que pertence ao upstream — e a pós-condição é verificada **por
estado**, com `git check-ignore`, e não pela linha que o script acabou de
imprimir.

Duas coisas caíram junto:

- o template tem **8 chaves** e o script escrevia **3**, do zero. Ele agora parte
  do `.env.example`, como o upstream manda;
- regerar do template com token vazio **apagaria um token em uso**. Um token já
  escrito que ainda vale é preservado quando a execução não traz um novo — senão o
  modo idempotente destrói a credencial em vez de preservá-la.

### A décima quinta: um teste que reportava o objeto errado

Duas falhas de `structure-test.sh` apontavam para o código, e o código estava
certo nas duas:

- *"o shim de gh não está sob o perfil vm"* — o padrão exigia o `if` do perfil e
  a `cat` do shim **na mesma linha**, o que nunca acontece: o `if` decide, a
  `cat` escreve, uma linha depois.
- *"a segunda pergunta do hostname ainda existe"* — ela não existia mais. A
  frase sobrevivía num **comentário que explicava por que ela foi removida**.

O segundo é o padrão, e é o mesmo de sempre numa forma nova: um `grep` no
arquivo inteiro casa a documentação do próprio teste. Um teste que acusa o
comentário que explica a regra treina quem o mantém a não escrever a razão.

E havia um terceiro, que ainda não tinha falhado: a variável `r` valia `run.sh`
no bloco do guard do sandbox e `setup.sh` no bloco dos defaults. Duas coisas num
nome só — uma redefinição futura mudaria silenciosamente o que uma checagem
antiga lê, que é a forma mais cara de "um diagnóstico que mede o objeto errado".
Cada checagem agora tem uma variável que **nomeia o arquivo que ela lê**, e as
que são sobre código leem o script sem os comentários.

### A décima sexta: duas checagens que não podiam falhar, e o `ok` que as escondia

A suíte passou com **101** checagens onde antes eram **103**, e a primeira
reação foi olhar o código. O código estava certo. A contagem é que estava errada,
e o erro é a coisa mais instrutiva que apareceu nesta rodada.

O `profile-axis` tem dois blocos que só rodam quando a pergunta do modo do
OpenDesign existe no script, e o guard era:

```bash
if grep -q 'nativo/container' "$REPO/setup.sh"; then
  check     "..."
  check_not "..."
else
  printf '  ok    (a pergunta do modo nao esta neste checkout)\n'
  pass=$((pass+1))
fi
```

Mudar o default do modo de `nativo` para `container` reescreveu o prompt para
`Modo [container/nativo]`, o `grep` deixou de casar, e cada bloco caiu no `else`.
A aritmética fecha exatamente: dois blocos, cada um trocando **duas** checagens
por **um** `ok` falso, dão 103 − 4 + 2 = **101**.

Duas coisas estão erradas ali, e a segunda é a que importa:

**O sentinela era uma literal.** `nativo/container` é o texto de hoje. O guard
precisa saber se a **pergunta** existe, não como ela está escrita — e a primeira
edição que mexe na ordem das opções o quebrava, sem nenhuma falha. Agora ele
procura `Modo [`, que sobrevive a reordenar e reescrever.

**O `else` fabricava aprovação.** Um `pulado` que se declara é honesto: quem lê
vê que a cobertura não foi cobrada. Um `ok` no lugar de duas checagens enche o
contador, e foi ele que escondeu a perda. O pulo agora imprime `PULO`, conta em
`pulados`, e aparece no resumo — porque um pulo que não aparece é um pulo que
ninguém vai notar.

### As duas checagens que eram sempre verdade

Restaurado o guard, **103 de novo** — e apareceu uma falha. A segunda metade da
investigação mostrou que a cobertura restaurada era **folga**:

```bash
check_not "e nao chegou a instalar o modo nenhum" "==> OpenDesign (nativo)" "$out"
check_not "e nao instalou o container"                "==> OpenDesign (container)" "$out"
```

**Nenhuma das duas strings existe no `setup.sh`.** O banner é `==> OpenDesign`,
sem sufixo de modo. As duas checagens eram sempre verdade: contavam como
cobertura e não mediam nada. Um membro que não pode falhar é pior que a ausência
dele, porque compra a sensação de cobertura sem pagar por ela — e foi exatamente
isso: as 103 incluíam 2 que não podiam falhar, então o número de checagens que
mediam alguma coisa era 101 antes e 103 agora.

Pior: a do 16c afirmava o **contrário** do que o run faz. Medido nesta VM:

```
  Modo [container/nativo]: lixo
  Escolha 'container' ou 'nativo'.
  Modo [container/nativo]: container
  token do daemon: gerado (no container ele É a credencial da API, ...)
==> OpenDesign
```

Com `lixo` recusado e `container` na linha seguinte, o modo container **é
aceito** e o banner **sai**. A checagem afirmava que não instalou — e "passava"
só porque procurava a string que o script nunca imprime. Agora as duas medem o
que acontece: no EOF o banner **não** sai; na entrada inválida seguida de válida,
ele **sai**.

### A guarda que impede a classe de voltar

`tests/lib/check-not-vacuous.py` procura `check_not` cuja string proibida é uma
**variação com sufixo de uma mensagem que o script emite de verdade** — que é o
que denunciou este caso. A regra é estreita de propósito: um "o texto proibido
precisa existir no código" em geral daria falsos positivos, porque `RANDOM`,
`urandom` e `date +%d%m` são justamente o que o script **não** deve usar e
legitimamente não aparecem. O caso geral sai como aviso, e o estreito como
falha.

Verificada nos dois sentidos, que é como se prova uma guarda: `exit 0` no estado
bom, `exit 1` com o `check_not` fole reintroduzido, `exit 0` restaurada.

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

### Uma máquina montada esconde as dez

O que as sete primeiras tinham em comum: **o trabalho que elas deveriam fazer foi
feito à mão.** O `sshd` foi habilitado no console; as units foram escritas à mão; o
Hermes era a instalação antiga em `~/Hermes-Agent`. Nenhuma dessas mãos aparece no
log do script, e nenhuma delas é detectável sem provisionar do zero.

A oitava e as duas seguintes são a exceção, e por um motivo que as outras não têm:
não são herança de uma máquina montada à mão. A oitava é um splice meu que deixou
código antigo; a nona e a décima são mudanças **deste dia**, e cada uma introduziu o
defeito junto com a correção que prometia. São os casos em que a máquina limpa não
podia ter revelado, porque o defeito nasceu depois dela — e o único que os pegou foi
rodar o script de verdade.

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

~~O `.env` com o `OD_API_TOKEN` cai **dentro do clone**~~

**RESOLVIDO, e o raciocínio antigo estava errado no ponto que importava.** Este
trecho dizia que o impacto era baixo porque o modo nativo vinha com
`OD_DISABLE_API_AUTH=1`, e portanto o token não era credencial viva. A medição
mostrou que a pregunta estava no arquivo errado:

| arquivo | `git check-ignore` | tem o token |
|---|---|---|
| `deploy/.env` — modo **container** | coberto, por `deploy/.gitignore:2` | sim, e é a credencial da API |
| `.env` na raiz — modo **nativo** | **nada** — `?? .env` | sim, mas o auth está desligado |

O `.env` exposto era o do modo **nativo**, não o do container. E como o default
virou `container`, o token do container passou de inerte a ser **a** credencial —
mas ele mora em `deploy/.env`, que o próprio upstream ignora. Ou seja: a
preocupação original apontava para o arquivo coberto, e o risco real estava no
que ninguém ignorava.

O que importa como lição: eu tinha escrito que o impacto era baixo com base no
raciocínio do momento, e esse raciocínio dependia de um default que mudou. Um
"impacto baixo" justificado por um default é uma afirmação com data de validade, e
a §10.14 conta o resto.

---

