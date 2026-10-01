# Depois do `setup.sh` — o que falta, e por quê

O `setup.sh` termina quando os serviços estão instalados e habilitados. Este
documento é o que vem depois: o passo entre "o script acabou" e "a VM está
usável".

Nada aqui é instalação. É configuração que nenhum instalador pode fazer, ou
verificação.

---

## 1. Configurar o modelo do Hermes

O instalador novo deixa `model: ""` — um sentinela explícito de "ainda não
configurado". Nenhuma flag do instalador faz isso, e sem provider a CLI conecta e
não gera.

```bash
hermes model
```

O `setup.sh` avisa quando detecta `~/.hermes/auth.json` sem provider, mas não
conecta: escolher um provider e uma credencial é sua.

---

## 2. Instalar o gateway do Hermes — fora do script, por decisão

O `hermes-gateway.service` **não é criado pelo `setup.sh`**. A unit que existe na
VM de agentes veio de `hermes gateway install`, subcomando de primeira classe do
CLI, que a própria documentação prescreve.

```bash
hermes gateway setup      # configura as plataformas de mensageria
hermes gateway install    # instala a unit de usuário
hermes gateway start
```

⚠️ **A unit gerada guarda o caminho do executável.** Medido na VM de agentes:

```
ExecStart="/…/Hermes-Agent/.hermes/bin/hermes" "gateway" "run"
ExecStopPost=-"/…/Hermes-Agent/.hermes/bin/hermes" "--run-module" "gateway.cgroup_cleanup"
```

Se a CLI for reinstalada em outro caminho — e o `hermes-cli` agora usa o
instalador oficial, que instala em `~/.hermes/hermes-agent` — a unit fica
apontando para um executável que não existe mais. **Não há como corrigir editando
a unit**: o `ExecStopPost` de limpeza de cgroup também aponta para o caminho
antigo. É preciso rodar `hermes gateway install` de novo.

---

## 3. Verificar por estado

O que importa é o estado, não o log. Rodando na VM de agentes depois do
provisionamento:

```bash
# as três publicações respondem
for p in 8443 8444 8445; do
  printf '%s -> %s\n' "$p" "$(curl -skS -o /dev/null -w '%{http_code}' "https://$N:$p/")"
done
# esperado: 8443 -> 200, 8444 -> 200, 8445 -> 302 (redirect para /login)

# as quatro units de usuário estão de pé e habilitadas
for u in opencode open-design hermes-dashboard hermes-gateway; do
  printf '%-20s %s %s\n' "$u" \
    "$(systemctl --user is-active $u.service)" \
    "$(systemctl --user is-enabled $u.service)"
done

# o OpenDesign lista os agentes
curl -s http://127.0.0.1:7456/api/agents | head -c 200
```

⚠️ **O `8445` respondendo 302 está certo.** É o redirect para `/login` do
dashboard, não um erro. E **`8444` tem que responder 200 SEM credencial** — se
pedir, o `OD_DISABLE_API_AUTH` não chegou ao `.env`, e o sintoma é um `Cannot GET`
mascarado por 401.

---

## 4. Se der 401 na UI do OpenDesign

O `.env` do nativo é escrito por ordem, e a ordem importa: a **origem vem antes
do `.env`**, porque o `.env` a consome. Com `set -u`, usar a variável antes de
definir aborta com "unbound variable" — e o modo silencioso do script é o que
dói: o `.env` sai **vazio**, o daemon sobe com o auth ligado, e o sintoma
aparece muito depois.

### Onde cada `.env` fica, e o que o git faz com ele

Isto é medido no clone, e a diferença entre os dois modos é real:

| arquivo | `git check-ignore` | tem segredo? |
|---|---|---|
| `deploy/.env` — modo **container** | coberto, por `deploy/.gitignore:2` | sim, o token |
| `.env` na raiz — modo **nativo** | **não coberto** — aparecia como `?? .env` | sim, o token |

O modo container segue o caminho que o **upstream documenta** (`deploy/.env`, a
partir de `deploy/.env.example`) e o próprio upstream o ignora. O modo nativo
escreve na raiz, onde nada o ignorava, e é por isso que o script acrescenta
`/.env` ao `.git/info/exclude`: esse arquivo é estado local do clone, nunca é
commitado, e não suja um `.gitignore` que pertence ao upstream.

O script **verifica por estado**, não pelo log que acabou de imprimir:

```bash
git -C ~/Developer/open-design check-ignore -v .env   # tem que dizer info/exclude
```

Se a linha não aparecer, o `.env` tem o token dentro e está visível para
`git add -A`. Não commite assim.

```bash
grep -c OD_DISABLE_API_AUTH ~/Developer/open-design/.env   # tem que ser 1
systemctl --user show open-design -p Environment | tr ' ' '\n' | grep OD_
```

⚠️ **A rota de ESCRITA exige loopback, com ou sem token.** Medido: escrita em
`/api/agents/:id/companion/install` responde 403 *"request peer must be a
loopback address"* a partir do IP da tailnet, mesmo com o token certo. Leitura
aceita loopback **ou** token. A causa está no `deploy/.env.example` do projeto:
*"connector endpoints also require the daemon to receive requests over loopback"*.

---

## 5. Rodar sem terminal

O `setup.sh` recusa execução sem tty, porque `read` devolve 1 no fim da entrada e
o `set -e` aborta o script no meio, em silêncio.

```bash
./setup.sh --profile=vm --defaults
```

⚠️ **O `--defaults` tira as perguntas do script, não as do `sudo`.** Medido: sem
terminal, `sudo -v` falha com *"um terminal é necessário para ler a senha"*. O
script detecta e diz o que fazer — `sudo -v` num terminal antes (o timestamp é o
que ele quer manter quente), ou `NOPASSWD` para o `dnf` da distro, ou um
askpass.

O que o `--defaults` decide sozinho (`--yes` é alias):

| | |
|---|---|
| confirmações | **o default de cada uma**, e nenhum default é entrada para serviço externo nem credencial destruída |
| senha do dashboard | a padrão `hermes`, e ela é **dita** na saída |
| senha do OpenCode | a padrão `opencode`, **dita** na saída — a mesma convenção do dashboard |
| modo do OpenDesign | **container**, anunciado. Só é seguro porque o passo `podman` instala o `podman-compose` — medido: sem ele, `podman compose` falha com "looking up compose provider failed" |
| login de pessoa do `gh` | **conteúdo no host, pulado na vm** — são alternativas, não um par. E o default do host **não abre o handshake**: a flag escreve o comando para você rodar, porque `gh auth login -w` abre o navegador e espera |
| GitHub App | **inativa** — a private key é um segredo que existe fora da máquina |

⚠️ **A flag se chama `--defaults`, e `--yes` é alias.** O nome antigo significava
"responde sim a tudo", e como nove dos nove prompts tinham default "não", isso
invertia cada opt-in. Medido: o run **travava para sempre** no handshake do `gh`,
que é uma pergunta dele e não deste script. A semântica agora é a que o nome diz:
aceitar todos os defaults, e os defaults são escolhidos para que "default" signifique
"provisionar".

---

## 6. O que a auditoria cobre e isto repete

`AUDITORIA.md` tem a tabela completa: perfis, módulos, portas, o que cada um
instala, e o custo de disco. Este documento é só o que falta **depois**.

Nenhum item aqui é bloqueio do `setup.sh`. São configuração e verificação — e o
motivo de estarem documentados em vez de automatizados é que cada um exige um
segredo ou uma credencial que não existe dentro da máquina.

---

## 5. Na VM, `gh` é a App — e isso é de propósito

O perfil `vm` instala um **shim** em `~/.local/bin/gh`, que é o `gh` de verdade
com o token de instalação da GitHub App. Sem ele, um agente que roda `gh pr
create` pega o `gh` sem token e falha, sem nenhuma pista de que existe uma App
na máquina.

Não é gambiarra: a documentação do GitHub CLI diz que `gh auth login` **não tem
login como App** (só o fluxo web e `--with-token`), e que a integração com um
token que não vem do login é a variável `GH_TOKEN`, **com precedência sobre as
credenciais guardadas**. Injetar `GH_TOKEN` é o mecanismo documentado.

O shim é **só no perfil `vm`**, e a razão está na mesma frase da documentação: como
`GH_TOKEN` tem precedência, um shim no host **sobrescreveria o seu login de
pessoa**. A máquina de uma pessoa e a máquina de uma fronteira têm identidades
diferentes, e o perfil é a única coisa que sabe qual é esta.

```bash
# na vm: o token é o da App
gh api user --jq .login          # a conta da App, não a sua
# no host: o shim não existe
type -a gh                      # /usr/bin/gh, e só
```

Se o shim aparecer no host, corra `rm ~/.local/bin/gh`: ele não deveria estar lá.
