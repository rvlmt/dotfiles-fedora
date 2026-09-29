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
./setup.sh --profile=vm --yes
```

⚠️ **O `--yes` tira as perguntas do script, não as do `sudo`.** Medido: sem
terminal, `sudo -v` falha com *"um terminal é necessário para ler a senha"*. O
script detecta e diz o que fazer — `sudo -v` num terminal antes (o timestamp é o
que ele quer manter quente), ou `NOPASSWD` para o `dnf` da distro, ou um
askpass.

O que o `--yes` decide sozinho:

| | |
|---|---|
| confirmações | **sim** — mas o default continua sendo **não** |
| senha do dashboard | a padrão, e ela é **dita** na saída |
| senha do OpenCode | a **aleatória** do instalador, no `service.json` 600 |
| modo do OpenDesign | **nativo**, anunciado |
| GitHub App | **inativa** — a private key é um segredo que existe fora da máquina |

---

## 6. O que a auditoria cobre e isto repete

`AUDITORIA.md` tem a tabela completa: perfis, módulos, portas, o que cada um
instala, e o custo de disco. Este documento é só o que falta **depois**.

Nenhum item aqui é bloqueio do `setup.sh`. São configuração e verificação — e o
motivo de estarem documentados em vez de automatizados é que cada um exige um
segredo ou uma credencial que não existe dentro da máquina.
