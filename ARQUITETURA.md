# Arquitetura

O que este repositório **é**, e não como se executa. O passo a passo de
provisionamento é o [README](README.md); este documento existe para que o runbook
tenha um alvo, e para que cada decisão fique na camada que apossui.

Regra que o repo segue: **nada entra aqui como decisão sem aprovação explícita.**

## Regra: o estado do host atual não é evidência

**O que existe, ou não existe, na máquina de hoje não diz nada sobre o padrão.** O
repositório descreve o estado **ideal** de um host novo. Medição de host atual não
justifica, não corrige e não dimensiona decisão aqui — vale para disco, pacotes
instalados, serviço ativo, VM definida, regra de firewall, senha e porta aberta.

Isso já falhou mais de uma vez, e a falha tem sempre a mesma forma: um número ou um
estado da máquina atual entra no documento como se fosse premissa do desenho, e a
conclusão sai errada. Os casos ficam registrados aqui de propósito, para não se
repetirem:

- **O tamanho do store de container.** Um `du` em btrfs com `compress=zstd`
  superestima, e a diferença entre `du` e `df` passou de dezenas de GB sem que
  houvesse algo errado. O número de um host descartável não é a capacidade do
  padrão.
- **Se o daemon do `libvirt` estava instalado.** A pergunta certa não era essa,
  mas a resposta dependia de qual pacote se testava, e a conclusão tirada dela
  estava errada. Nada disso diz o que o `setup.sh` deve fazer.
- **O que a zona do `firewalld` permite.** A conclusão "tirar a interface do
  `trusted` resolve" veio de ler a zona, e o default amplo do Fedora faz a
  publicação funcionar por outro caminho. O padrão declara a propriedade que
  quer, não o que o default por acaso já faz.
- **A senha do servidor do OpenCode.** Credencial de um host não descreve
  comportamento de software, e foi um palpite sobre o software que quebrou.

O que **é** válido medir, e é a diferença: medir o comportamento do **alvo**. Do
`tailscaled` funcionando num guest com o filtro ativo, ou do `virsh` respondendo
numa VM recém-criada, é medir o padrão. Medir o que a sua máquina já tem é medir
outra coisa.
Os pontos em aberto estão marcados como abertos, na seção
[Em aberto](#em-aberto), e não aparecem aqui como decisão.

## As três camadas

```
┌─── Mac / Mac mini (cliente, thin) ───────────────────────────┐
│ devpod (provider SSH) · IDE · terminal · cliente Tailscale   │
└────────────────────────────┬─────────────────────────────────┘
                             │ ssh, pela tailnet
┌────────────────────────────▼─────────────────────────────────┐
│ VM de agentes — A FRONTEIRA                                    │
│ um container por projeto · CLIs de agente · servidor OpenCode │
│ provisionada por setup.sh --profile=vm · reset por snapshot   │
└────────────────────────────┬─────────────────────────────────┘
                    rede: NAT + filtro; sem rota para a LAN
┌────────────────────────────▼─────────────────────────────────┐
│ Host — Fedora Workstation, pessoal e GUI                       │
│ libvirt + cockpit-machines · firewalld (guarda o egress)      │
│ Tailscale · sshd-hardening · apps de workstation              │
└───────────────────────────────────────────────────────────────┘
```

O host deixou de executar agentes. Ele é workstation pessoal **e** hospedeiro de
VMs. A VM é a fronteira: um escape de container aterrissa num guest que se
reverte por snapshot, em vez de na máquina de trabalho.

## Divisão de responsabilidade

| Camada | É | Declara | Nunca declara |
|---|---|---|---|
| Cliente | thin client | nada neste repo | nada sobre o guest |
| Guest | a fronteira | o ambiente de execução dos agentes | a topologia de rede que aVm consome |
| Host | workstation e hospedeiro |VMs, rede, workstation, identidade | o que roda dentro do guest |

Uma decisão mora na camada que a executa. `tailscale serve` e a senha do OpenCode
são do guest; a rede do libvirt e o `firewalld` são do host; o `--profile` do
script é do repo. O critério é o mesmo que motivou os drop-ins de unit: estado que
ninguém possui diverge em silêncio do padrão.

## O host

**Papel:** workstation pessoal com GUI **e** hospedeiro de VMs.

**Fica com:** `libvirt` e `cockpit-machines`, `firewalld`, Tailscale,
`sshd-hardening` e os apps de workstation. `desktop-apps` e `gui-access` **permanecem
no caminho normal** — antes se sugeriu tirá-los, e estava errado: com o host
virando workstation pessoal, eles são o trabalho dele.

**Sai do host:** Podman rootless (e `podman-docker`), `subuid`/`subgid`,
`containers.conf` com `userns=keep-id`, `enable-linger`, as CLIs de agente, o
servidor do OpenCode, a publicação `tailscale serve` na 8443, e o
`devcontainer-template`.

A decisão "sem `podman-docker`" **passa a ser invariante do guest**, não do host.
No host ela fica sem objeto porque o Podman sai inteiro; no guest importa mais,
porque é lá que o devpod roda e é lá que um `docker` inesperado faria o provider
escolher o engine errado.

**A rede do libvirt é do repo, sempre.** O Cockpit cria rede com NAT ou bridge e
faixa de DHCP, mas não tem onde expressar regra de filtro — e o filtro é
obrigatório, não opcional. Essa é a parte da configuração de VM que o repo não
delega, independentemente de quem constrói a VM.

**`firewalld` é o guardião do egress da VM.** Com o host nessa função, marcar
`tailscale0` como zona `trusted` — que libera todo tráfego — deixa de ser "um
pouco amplo" e passa a ser o elo errado da cadeia. Ver
[#10](https://github.com/rvlmt/dotfiles-fedora/issues/10).

## O guest

**Papel:** a fronteira.

**Construção:** **manual, no Cockpit.** O repo não constrói o guest e não há
kickstart. O fluxo é:

```bash
./setup.sh --profile=host        # no host
# criar a VM no Cockpit — o Cockpit baixa a ISO
./setup.sh --profile=vm          # dentro da VM
virsh snapshot-create ...         # baseline de reset
```

**Reset:** snapshot do libvirt. A imutabilidade vem da **borda** — a VM inteira
reverte — e não do sistema operacional do guest.

**Recurso:** 8 GiB. O `devcontainer-template` pede 4 GiB por container, então a
VM acomoda dois projetos com limite efetivo; o terceiro estoura. Ajustar no
Cockpit do host.

### A rede do guest

- Rota default via NAT — **necessária**, ver a correção abaixo.
- Filtro que bloqueia o guest para a LAN.
- `tailscaled` dentro do guest: dá MagicDNS, certificado e **nenhuma porta nova no
  host**, então a [#10](https://github.com/rvlmt/dotfiles-fedora/issues/10) não
  piora e a regra de loopback mais tailnet continua sem exceção.

**O `firewalld` do guest não é configurado pelo perfil.** A zona padrão do Fedora
Workstation já inclui `ssh`, então um guest intacto aceita a entrada do Mac pela
tailnet — o desenho não quebra em default. O perfil `vm` **verifica** isso como
pós-condição e não mexe. A assimetria que decide: no host o `firewalld` é estrutural
(guarda o egress e a LAN), então o repo é dono; no guest é uma camada a mais cujo
default já está certo, e a pior consequência de errar ali é cortar a única entrada
da VM.

**O filtro de egress é medido antes de ser declarado.** O `nwfilter` está
descartado: ele é referenciado no XML do domínio, e quem cria o domínio é o
Cockpit, na mão — o repo não injeta referência num domínio que outro criou. O dono
é o `firewalld` do host, que já tem a zona `libvirt` com `forward: no` e suporte a
policy de zona para zona. **A questão é se o default já bloqueia**, e se não
bloquear, a policy entra. Declarar antes de medir seria escrever regra de firewall
no repo sem nunca ter visto uma VM subir.

Três coisas que este desenho **não** entrega, e que precisam estar escritas para
não virar promessa:

1. **O DNS do guest passa pelo host.** Resolução de nome continua funcionando; o
   que se bloqueia é alcance direto por IP.
2. **O firewall do host só enxerga o IP único da VM.** Política de egress *por
   container* teria que viver dentro do guest.
3. **Nada disso desfaz um escape guest→host.** A resposta a um incidente é
   procedimento: reverter o snapshot, ou destruir e recriar, e rotacionar a auth
   key da tailnet.

## O cliente

`devpod` no Mac, com provider SSH apontando para a VM.

O devpod **não** está velho: está apontado para a camada errada, e é por isso que
nunca consumiu o template. O que sustenta a escolha:

- o provider SSH é SSH puro, então o binário do devpod fica **só no cliente** e o
  `podman` **só no guest** — nunca nos dois;
- exige par de chaves, o que bate com o `sshd-hardening`;
- não precisa do `podman.socket`: roda o CLI `podman` por SSH, então a postura de
  socket desabilitado continua intacta.

O Dev Container CLI foi considerado e fica de fora: não tem provider remoto de
primeira classe, e falaria no engine remoto por `DOCKER_HOST=ssh://` herdado do
podman. É plumbing não suportado pelo CLI — a mesma classe de premissa que a
[#11](https://github.com/rvlmt/dotfiles-fedora/pull/11) mostrou ser perigosa de
assumir.

## O repositório

**Um repo, dois perfis.** `--profile=host` e `--profile=vm` são um **eixo novo,
ortogonal** ao `--only`/`--skip` que já existe: o perfil escolhe o conjunto de
módulos, e `--only`/`--skip` refinam por dentro.

**A base é a mesma nos dois: Fedora Workstation.** O host já é; o guest passa a
ser também. A escolha é do guest e vale registrar o que ela resolve e o que ela
traz.

O que resolve: a leveza nunca foi o critério, e a discussão toda provou isso.
**Rodar browser não discrimina base nenhuma** — o Chromium roda dentro do
container, e o container é uma imagem sua, não a imagem do SO do guest. O que a
base de fato produz são três exigências, e Workstation satisfaz as três:

1. **kernel com user namespace não privilegiado** e `user.max_user_namespaces`
   acima de zero — é o que permite o namespace aninhado (rootless Podman por
   fora, sandbox do Chromium por dentro);
2. **systemd com cgroup v2** — sem ele o `--memory=4g` do devcontainer é
   decorativo;
3. **disco** para a imagem de browser mais um container por projeto.

O que traz: um ponto que **não existia** antes. Workstation liga o `firewalld` por
padrão, então **o guest passa a ter firewall onde antes se supunha que não
havia** — o que era uma das razões para descartar o Cloud. E um firewall que
ninguém projetou é um firewall com configuração desconhecida. Ver o ponto 1 em
[Em aberto](#em-aberto).

O eixo que de fato discriminava as candidatas era "a imagem possui a sua
configuração ou não". Workstation não opinions sobre dotfiles, e é o que o repo
precisa para ser o padrão autoritativo. Omarchy e ZimaOS gerenciam os próprios
dotfiles, o que colide com a premissa. Silverblue opinions sobre o SO, que é outra
camada, e ficou de fora por incompatibilidade com o provisionamento: `dnf` não
existe em atomic, é `rpm-ostree install` criando um deployment novo, o toolchain
vive no toolbox, e a unit systemd do OpenCode teria que achar caminho dentro dele.
**Imutável e provisionado por `dnf` não convivem.**

## O plano dos perfis

O que cada perfil declara, módulo a módulo. A regra que distribui os módulos é a
mesma da seção de divisão: **um módulo mora no perfil da camada que o executa.**

| Módulo | host | guest | Por quê |
|---|:--:|:--:|---|
| `base` | sim | sim | Baseline de CLI, `mise`, Bun. Idêntico nos dois. |
| `zshrc` | sim | sim | Shell de login e dono do PATH. Vale por SSH no guest. |
| `git` | sim | sim | Cada máquina tem identidade e chave próprias. |
| `ssh` | sim | sim | Cada máquina tem par de chaves próprio. |
| `tailscale` | sim | sim | Identidade na tailnet. No guest é **como o Mac chega**. |
| `sshd-hardening` | sim | sim | Os dois são alcançáveis por SSH. |
| `hostname` | sim | — | No guest o hostname vem do formulário do Cockpit. |
| `firewalld` | sim | — | O host guarda o egress. O guest é NAT e não é exposto. |
| `vm-host` | sim | — | `libvirt`, `cockpit-machines`, grupo `libvirt`. Sem rede: pendência. |
| `desktop-apps` | sim | — | Workstation pessoal. No guest quem edita é o devcontainer. |
| `gui-access` | sim | — | RDP para a tela do host. |
| `toolbx` | sim | — | Sandbox pessoal fora de projeto. No guest quem isola é o devcontainer. |
| `podman` | **—** | sim | Sai do host e vira o motor do guest. |
| `ai-clis` | — | sim | Os agentes rodam no guest. |
| `opencodex` | sim | — | Proxy de provider, com **confirmação própria**. Uso pessoal. |

**O que o perfil `vm` deliberadamente não faz:** não cria a VM (isso é do
Cockpit, na mão), não toca em `libvirt`, não define hostname, não instala apps de
workstation. Ele roda **dentro** do guest e é idempotente como qualquer módulo.

**O `devcontainer-template` fica aqui, e é referência nominal, não
sincronização.** Este repo é a fonte do arquivo; o README nomeia a versão e **cada
projeto guarda a sua própria cópia**, que envelhece sozinha. Isso é aceito
explicitamente: `devcontainer.json` é por projeto por especificação, e não existe
`extends` nele. "Referenciar sem copiar" só se resolveria por caminho relativo no
campo `dockerfile` (quebrado por mudança de layout) ou por imagem base publicada
por este repo (que é um elemento de arquitetura novo, com tag e ciclo de vida
próprios). Nenhum dos dois foi adotado.

O preço, dito com todas as letras: **mudar o template aqui não muda o que já está
dentro de um projeto.** Os quatro defeitos conhecidos do template — colisão do nome
de volume, base `bullseye` com LTS encerrado, ausência de `--pids-limit`, e
`safe.directory '*'` — só se corrigem, para de fato, nos projetos que o
consomem. O registro aqui serve para o requisito ser auditável, não para
propagar a correção.

**A disciplina base-agnóstica continua valendo**, mesmo com a base decidida: os
módulos não afirmam nada sobre a imagem do SO além do que já é verdade em Workstation.
Se um dia a base mudar, a mudança deve ficar **num módulo só**, e não espalhada.

### Pós-condições por perfil

Cada perfil verifica no final o que ele mesmo deixou. Não é suíte de testes — são
afirmações que o script faz sobre o próprio resultado, e são a resposta
proporcional ao fato de o repo não ter verificação automática.

- **`host`:** `virsh -c qemu:///system` responde, testado **dentro do grupo
  `libvirt`** (`sg libvirt -c ...`). Testar o grupo com `id -nG` seria mentira: o
  grupo só chega ao processo no próximo login, e é o `getgroups()` do processo que
  o libvirt consulta. `tailscale0` fora da zona `trusted` e a VM sem rota para a LAN
  são pós-condições **pendentes**, porque dependem da decisão de rede.
- **`vm`:** `userns=keep-id` efetivo; `podman.socket` desabilitado;
  **`podman-docker` ausente**; cgroup v2 presente; `user.max_user_namespaces` acima
  de zero; um container por projeto, sem volume compartilhado; e o `firewalld` do
  guest **intocado**, com a verificação de que `tailscale0` caiu numa zona que
  permite `ssh` — que é o que garante que o Mac consegue entrar.

### Ordem de implementação

**Feito.** O eixo `--profile` na CLI, ortogonal ao `--only`/`--skip`, e a
pertenência de cada módulo ao perfil da camada que o executa — `podman` e
`ai-clis` no guest, `opencodex` no host, `firewalld`/`hostname`/`desktop-apps`/
`gui-access`/`toolbx` restritos ao host, e o resto nos dois.

O eixo e a pertenência entraram **no mesmo PR**, e isso é deliberado: um
`--profile=host` que ainda instalasse Podman estaria mentindo desde o primeiro
commit. Separá-los produziria estados intermediários em que a flag afirma algo
falso, que é pior do que um PR maior.

A validação `--only` contra o perfil é assimétrica de propósito: `--only` falha
alto se o módulo não pertence à camada, porque isso é erro de quem pediu e
silenciar poderia instalar Podman no host por engano. `--skip` de um módulo fora
do perfil apenas avisa, porque pular o que não roda é inócuo.

**Feito depois.** O módulo `vm-host` no perfil `host`, no corte mínimo: pacotes,
grupo `libvirt` e `cockpit.socket`. Ele **não** declara a rede do libvirt — ver a
[pendência de rede](#pendência-a-postura-de-rede-do-host).

**Falta, nesta ordem.**

1. As pós-condições de cada perfil, à parte das do `vm-host` que já existem.
2. As correções no template do devcontainer, que são do guest: colisão do nome de
   volume, base `bullseye` com LTS encerrado, ausência de `--pids-limit`, e
   `safe.directory '*'`.
3. Tirar `tailscale0` da zona `trusted` no host, com a zona própria.
4. O mecanismo do filtro de egress, **depois** de medido.

O filtro é o último de propósito: é o único item que depende de uma medição que
só uma VM real dá. Fazer antes seria escrever regra de firewall no repo sem nunca
ter visto uma VM subir.

**Um furo que o eixo expôs, e que estava pior do que parecia.** As confirmações usam
`read -rp`, que o bash só imprime quando o stdin é terminal, e `read` devolve 1 no
fim da entrada. Como algumas dessas leituras estão fora de um contexto `&&`, o
`set -e` **abortava o script**: saía com código 1, depois do banner, sem mensagem,
sem rodar módulo nenhum. Não era "recusar em silêncio" — era morrer em silêncio,
e por isso também não dava para dizer que era seguro rodar por pipe.

Corrigido na #18: o script **recusa no início**, com mensagem, quando o stdin não
é um terminal. A alternativa seria seguir com os defaults, que produziria um
provisionamento parcial e silencioso — pior que não rodar. O ponto que fica para o
padrão, e que não foi decidido aqui: **o que uma execução verdadeiramente não
interativa deveria fazer** (instalar com defaults declarados? exigir flags
explícitas? recusar?). Recusar é o comportamento seguro, não o completo.

## Pendência: a postura de rede do host

Não é base, e **não é decidível agora**. Duas coisas estão erradas no host e
nenhuma delas tem correção possível antes de um dado que ainda não existe:

1. `tailscale0` está na zona `trusted`, que aceita todo tráfego de toda a tailnet.
2. A zona `FedoraWorkstation` tem `1025-65535/tcp` e `1025-65535/udp` abertos, e é
   o **default do próprio Fedora** — está no XML do pacote, com a intenção
   documentada de liberar portas altas para apps de desktop.

O que a medição mostrou, e que é o ponto não óbvio: **tirar a interface do
`trusted` não conserta nada.** A publicação na 8443 funciona porque a zona default
libera toda porta alta, não porque a interface estivesse em `trusted`. A interface
cairia no default e a exposição continuaria idêntica.

A correção na ordem certa seria: `tailscale0` sai do `trusted`; `tailscale0` ganha
uma **zona própria** que permite só o que precisa; e só então fecha o
`1025-65535` da `FedoraWorkstation`, que é a [#10](https://github.com/rvlmt/dotfiles-fedora/issues/10).

**Por que não agora.** O passo do meio exige saber quais portas `tailscale0`
precisa. A regra do host é uma porta por serviço, e a lista de serviços que o host
vai expor não está escrita — o próprio OpenCode vai migrar para a VM, e há outros
a definir. Declarar uma zona hoje seria escrever um invariante com um conjunto
conhecidamente incompleto, que se quebra a cada serviço novo. E o
`ARQUITETURA.md` diz que a 443 fica reservada: reserva de porta e uma zona com um
conjunto mínimo de regras são coisas diferentes.

Então o `vm-host` **não declara rede**, e a pendência fica aqui. Quando a lista de
serviços existir, a zona própria é uma decisão de uma vez, e a #10 fecha junto.

## O perfil escolhido é responsabilidade de quem executa

O script **não** impede `--profile=vm` num host físico, nem `--profile=host`
dentro da VM. Quem executa é soberano, e a decisão é de propósito.

Na prática, `--profile=vm` num host instala o que a seção [O host](#o-host) diz
que sai dele — Podman, `subuid`, keep-id, as CLIs de agente. E `--profile=host`
dentro da VM instala `desktop-apps`, habilita o `firewalld` e marca `tailscale0`
como `trusted` no guest, o que a [postura de rede](#pendência-a-postura-de-rede-do-host)
reprova. As duas coisas são visíveis depois: o host fica com container, ou a VM
fica com a postura de rede errada. E quem fez isso de propósito pode querer
exatamente isso — um ambiente único que é as duas coisas, como o host era antes
desta mudança.

Por isso não há `systemd-detect-virt` recusando. Um aviso existiria e seria
ignorado no caso legítimo, e um erro bloquearia um uso válido. O que substitui a
recusa é a leitura do que está escrito acima: cada perfil declara o que instala, e
a lista é pública.

## Em aberto

**Uma decisão pendente, e ela tem uma pré-condição que não existe:** a postura de
rede do host. Ver
[Pendência: a postura de rede do host](#pendência-a-postura-de-rede-do-host).

## Decisões que precisaram de revisão, e por quê

O registro importa porque a primeira versão de cada uma delas foi uma premissa
falsa, e premissa falsa escrita com confiança é o modo de falha mais caro deste
repo.

**`firewalld` do guest — verificar, não configurar.** A primeira versão da
pergunta era "o guest tem firewall?" com o tom de risco. A medição mostrou que a
zona `FedoraWorkstation` já inclui `ssh`, então o default está correto e o
desenho não quebra. A pergunta certa é se o repo declara ou deixa com o Fedora, e
a resposta segue a assimetria entre as camadas: o host é dono estrutural do
firewall, o guest não.

**Filtro de egress — medir antes de declarar.** A primeira versão apresentava
`nwfilter` e regra de `FORWARD` como alternativas em pé de igualdade. Duas coisas
invalaram isso: o `nwfilter` é referenciado no XML do domínio, e o domínio é
criado pelo Cockpit — logo a opção mais declarativa é impossível no fluxo
escolhido. E o `firewalld` do host já tem a peça. Sobrou uma pergunta de medição,
não de escolha.

**`opencodex` — só no host, e com confirmação própria.** Não é um CLI como os
outros seis do `ai-clis`: é um proxy universal de provider, que está no caminho
das requisições de modelo. A incoerência era instalar em silêncio o que tem
mais superfície, no módulo que pergunta sobre o que tem menos. Ficar no host
também tira o proxy do caminho das credenciais dos agentes: ele serve o uso
pessoal do Codex e do Claude Code na workstation, e **os agentes dentro da VM não
o têm** — cada um usa a credencial do provider direto.

**`devcontainer-template` — referência nominal, sem sincronização.** Explicitamente
o mais fraco das três realizações, e escolhido como tal: o README nomeia a versão
e cada projeto guarda a sua cópia, que envelhece. Custa pouco e não inventa
mecanismo; o preço é que a correção de um defeito no template não chega aos
projetos sozinha.

## Correções que precisam ficar registradas

Três premissas falsas que já entraram em documento deste repo. Ficam porque são
fáceis de readotar por quem não viu a discussão.

**1. "A VM sem rota default, só o Tailscale."** Falso. Para entrar na tailnet o
`tailscaled` fala com o servidor de coordenação, e o fallback de pareamento é um
relé DERP — ambos na internet pública. Sem rota default ele não sobe. O desenho
correto é: rota default **necessária**, e o que não existe é rota **para a LAN**.

**2. "xfs, rede persistente, firewall presente" como premissas do desenho.** Não
foram derivadas de decisão nenhuma. Foram suposições apresentadas como premissas.
A resposta foi manter guest mutável com imutabilidade na borda, mas a pergunta que
elas mascaravam — imutabilidade do SO, ou provisionamento por `dnf`? — é a mesma
do ponto 1 acima.

**3. "O registro de risco do `label=disable` continua valendo."** Ele foi aceito
porque o user namespace não isola kernel e a MAC era a única camada a mais. Dentro
de uma VM o escape já é contido, então o registro não descreve mais o risco real.
Por isso ele saiu do README, e as **exigências de operação** que estavam misturadas
nele é que sobreviveram, junto do Podman: socket desabilitado, `keep-id`,
credencial fora do workspace, um container por projeto.

O que o registro de risco **não** é, e continua não sendo: o modo não é confine
SELinux, não é fronteira de host, e user namespaces rootless não isolam kernel.

## O risco que este desenho carrega

**O repo nunca foi rodado do zero.** Toda validação aconteceu numa máquina que já
tinha Podman, CLIs de agente e estado acumulado. O `setup.sh` nunca provou que
provisiona um host novo.

A decisão é que a reconstrução do host seja o teste — coerente com um host
descartável. Fica registrado o que isso implica: o primeiro `setup.sh` num host
novo vai falhar em coisas que nenhum teste teria pegado. Vale esperar isso em vez
de tratar como surpresa quando chegar.
