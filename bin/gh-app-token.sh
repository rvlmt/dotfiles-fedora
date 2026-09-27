#!/usr/bin/env bash
# Minta um token de instalação de GitHub App e o escreve num arquivo 600.
#
# Existe porque o `gh` não faz login como App. O caminho é: assinar um JWT com a
# private key da App, trocá-lo por um token de instalação, e exportar esse token
# como `GH_TOKEN` — que, pela documentação do `gh`, tem precedência sobre
# credenciais guardadas.
#
# A private key NUNCA entra no repositório, nem em variável de ambiente, nem no
# histórico. Este script só a lê de um arquivo 600, e só a usa para assinar.
#
# O token NUNCA é impresso sem que se peça explicitamente. O caminho normal é
# `--out`, que escreve num arquivo 600; `--print` existe para quando se quer o
# valor no stdout, e é aí que quem chama tem o cuidado de não logar.
#
# Uso:
#   gh-app-token.sh --out ~/.cache/gh-app-token [--app-id N] [--key F] [--installation N]
#   GH_APP_TOKEN="$(gh-app-token.sh --print ...)"
#   gh-app-token.sh --check ...      # valida sem deixar token em lugar nenhum
set -euo pipefail

# Default é o caminho onde o módulo `gh-app` gravou as duas coisas. Sem isto o
# wrapper `gh-app` — que não passa --app-id nem --key — falha com "App ID
# ausente", que é a forma mais provável de o uso anunciado não funcionar.
APP_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-app"
APP_ID="${GH_APP_ID:-}"
KEY_FILE="${GH_APP_KEY:-}"
[ -z "$APP_ID" ] && [ -r "$APP_DIR/app-id" ] && APP_ID="$(cat "$APP_DIR/app-id")"
[ -z "$KEY_FILE" ] && [ -r "$APP_DIR/private-key.pem" ] && KEY_FILE="$APP_DIR/private-key.pem"
INSTALLATION_ID="${GH_APP_INSTALLATION_ID:-}"
OUT=""
META=""
PRINT=0
CHECK=0
SCOPE_REPOS="${GH_APP_REPOSITORIES:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --app-id|--key|--installation|--out|--meta|--repositories)
            # O script roda com `set -u`, então `$2` sem existir é "unbound
            # variable" — que não diz qual argumento faltou.
            [ $# -ge 2 ] || { erro "$1 exige um valor"; exit 64; }
            case "$1" in
                --app-id)       APP_ID="$2" ;;
                --key)          KEY_FILE="$2" ;;
                --installation) INSTALLATION_ID="$2" ;;
                --out)          OUT="$2" ;;
                --meta)         META="$2" ;;
                --repositories) SCOPE_REPOS="$2" ;;
            esac
            shift 2 ;;
        --print)       PRINT=1; shift ;;
        --check)       CHECK=1; shift ;;
        -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "argumento desconhecido: $1" >&2; exit 64 ;;
    esac
done

erro() { echo "gh-app-token: $*" >&2; }

# As tres dependencias, verificadas antes de qualquer trabalho. O `openssl` nao
# entra na lista de pacotes do modulo `base` — o `curl` do Fedora exige
# `openssl-libs`, que e a biblioteca, nao o binario — entao numa maquina nova
# estes tres podem simplesmente nao existir, e sem esta checagem a falha seria um
# "command not found" no meio de um pipeline.
for _dep in openssl curl jq; do
    command -v "$_dep" &>/dev/null || { erro "falta $_dep, que este helper precisa"; exit 69; }
done

[ -n "$APP_ID" ] || { erro "App ID ausente (--app-id ou GH_APP_ID)"; exit 65; }
[ -n "$KEY_FILE" ] || { erro "caminho da private key ausente (--key ou GH_APP_KEY)"; exit 65; }
[ -r "$KEY_FILE" ] || { erro "private key ilegivel: $KEY_FILE"; exit 66; }

# A private key é segredo, e um symlink aqui é o jeito de mandar o openssl ler
# outro arquivo — ou nada, se o alvo sumir. Recusa antes de olhar permissão, para
# que a mensagem diga o que aconteceu em vez de relatar o 777 do próprio symlink.
if [ -L "$KEY_FILE" ]; then
    erro "a private key é um symlink: aponte para o arquivo, não para o link"
    exit 77
fi
PERM=$(stat -c '%a' "$KEY_FILE" 2>/dev/null || echo "?")
DONO=$(stat -c '%U' "$KEY_FILE" 2>/dev/null || echo "?")
if [ "$DONO" != "$(id -un)" ]; then
    erro "a private key pertence a $DONO e o usuario corrente e $(id -un)"
    exit 77
fi
case "$PERM" in
    600|400) : ;;
    *) erro "a private key esta com permissao $PERM; deve ser 600"; exit 77 ;;
esac

# base64url sem quebrasas nem preenchimento, que é o que o JWT exige.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# O App ID é numérico na API. Sem esta checagem, um valor com aspas entraria no
# JSON do JWT sem escape e quebraria a assinatura de um jeito que só apareceria
# como "a API recusou o JWT", sem dizer que a causa foi o App ID.
case "$APP_ID" in
    ''|*[!0-9]*) erro "o App ID tem que ser numérico, e veio: '$APP_ID'"; exit 65 ;;
esac

AGORA=$(date +%s)
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url) || { erro "openssl base64 falhou"; exit 69; }
# `iat` 60s no passado é a recomendação da doc contra deriva de relógio; `exp` no
# máximo 10 minutos no futuro é o teto aceito pela API.
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((AGORA - 60))" "$((AGORA + 600))" "$APP_ID" | b64url) \
    || { erro "openssl base64 falhou"; exit 69; }
ASSINADO="$HEADER.$PAYLOAD"
ASSINATURA=$(printf '%s' "$ASSINADO" | openssl dgst -sha256 -sign "$KEY_FILE" | b64url) \
    || { erro "openssl nao conseguiu assinar com $KEY_FILE — a chave e valida?"; exit 69; }
JWT="$ASSINADO.$ASSINATURA"

API="https://api.github.com"
H=(-H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

if [ -z "$INSTALLATION_ID" ]; then
    # Sem o installation ID, descobre: o App ID sozinho não diz em quem ele está
    # instalado, e essa lista é o que o torna derivável em vez de algo a passar
    # de mão. Uma instalação só é o caso comum; com mais de uma, escolhe a
    # primeira e avisa, porque adivinhar silenciosamente seria pior.
    # Sem `--max-time`, um curl pendurado travaria um módulo que se diz não
    # interativo. E sem `-s`, o `-S` mostra o erro real: sem isso, uma falha de
    # DNS ou de proxy seria relatada como "a API recusou o JWT", que é uma causa
    # completamente diferente e levaria a pessoa a culpar a App à toa.
    ERRO=$(mktemp)
    RESPOSTA=$(curl -fsS --connect-timeout 15 --max-time 60 "${H[@]}" \
        "$API/app/installations?per_page=100" 2>"$ERRO") || {
        erro "a chamada a /app/installations falhou (App ID $APP_ID, chave $KEY_FILE)"
        erro "curl disse: $(tr '\n' ' ' < "$ERRO")"
        rm -f "$ERRO"; exit 69; }
    rm -f "$ERRO"
    # Se a resposta for um objeto de erro em vez da lista, `length` contaria
    # chaves e `.[0]` explodiria — sem mensagem. Checa o formato antes.
    if ! printf '%s' "$RESPOSTA" | jq -e 'type == "array"' &>/dev/null; then
        erro "a API respondeu fora do esperado: $(printf '%s' "$RESPOSTA" | head -c 300)"
        exit 69
    fi
    TOTAL=$(printf '%s' "$RESPOSTA" | jq 'length') || { erro "resposta ilegivel"; exit 69; }
    if [ "$TOTAL" -eq 0 ]; then
        erro "o App $APP_ID nao tem nenhuma instalacao: instale-o em um repositorio"; exit 69
    fi
    INSTALLATION_ID=$(printf '%s' "$RESPOSTA" | jq -r '.[0].id')
    DONOS=$(printf '%s' "$RESPOSTA" | jq -r '[.[] | .account.login] | join(", ")')
    if [ "$TOTAL" -gt 1 ]; then
        echo "gh-app-token: o App esta instalado em $TOTAL contas ($DONOS); usando a id $INSTALLATION_ID" >&2
        echo "gh-app-token: para fixar outra, exporte GH_APP_INSTALLATION_ID" >&2
    fi
fi

CORPO="{}"
if [ -n "$SCOPE_REPOS" ]; then
    # A lista é separada por virgula, e o corpo é JSON de verdade. Com
    # `jq -R . | jq -s .` um "a,b" viraria ["a,b"], que é um nome de repo
    # inexistente em vez de dois nomes.
    LISTA=$(printf '%s' "$SCOPE_REPOS" | tr ',' '\n' | jq -R . | jq -s .)
    CORPO=$(printf '{"repositories":%s}' "$LISTA")
fi

# O Content-Type vai explícito: sem ele o curl manda
# `application/x-www-form-urlencoded`, e o endpoint espera JSON.
ERRO=$(mktemp)
RESPOSTA=$(curl -fsS -X POST --connect-timeout 15 --max-time 60 "${H[@]}" \
    -H "Content-Type: application/json" -d "$CORPO" \
    "$API/app/installations/$INSTALLATION_ID/access_tokens" 2>"$ERRO") || {
    erro "a API recusou o pedido de token para a instalacao $INSTALLATION_ID"
    erro "curl disse: $(tr '\n' ' ' < "$ERRO")"
    rm -f "$ERRO"; exit 69; }
rm -f "$ERRO"

# Estes quatro `jq` leem a resposta ANTES do teste de token vazio, e um `jq` que
# falha sob `pipefail` mata o script sem chegar na mensagem que explica. Todos
# com default, e a checagem do token vem logo depois.
TOKEN=$(printf '%s' "$RESPOSTA" | jq -r '.token // empty' 2>/dev/null || echo "")
EXPIRA=$(printf '%s' "$RESPOSTA" | jq -r '.expires_at // empty' 2>/dev/null || echo "")
PERMISSOES=$(printf '%s' "$RESPOSTA" | jq -r '(.permissions // {}) | to_entries | map("\(.key)=\(.value)") | join(" ")' 2>/dev/null || echo "")
REPOS=$(printf '%s' "$RESPOSTA" | jq -r '[(.repositories // [])[] | .full_name] | join(" ")' 2>/dev/null || echo "")

[ -n "$TOKEN" ] || {
    erro "a resposta da API nao trouxe token: $(printf '%s' "$RESPOSTA" | head -c 300)"
    exit 69
}

# `--check` não escreve o token em lugar nenhum, e o processo o descarta ao sair.
# O que ele **não** faz é revogar o token no lado do GitHub: a troca acontece de
# verdade, e existe um token de instalação válido por uma hora que nada revoga.
# Ele morre sozinho, mas "não fica aqui" não é "não existe".
# E o caminho para uso normal, porque o token vive 1 hora e não serve ficar em
# disco além disso.
if [ "$CHECK" = "1" ]; then
    echo "gh-app-token: token valido para a instalacao $INSTALLATION_ID"
    echo "gh-app-token: expira em $EXPIRA"
    echo "gh-app-token: permissoes: ${PERMISSOES:-<nenhuma declarada>}"
    echo "gh-app-token: repos: ${REPOS:-<todos os da instalacao>}"
    exit 0
fi

# O `.meta` é separado do token porque quem chama precisa saber quando expira sem
# ler o token. E vai ao lado dele, não dentro, para que apagar o token não deixe
# um arquivo que finge ser válido.
if [ -n "$OUT" ]; then
    umask 077
    mkdir -p "$(dirname "$OUT")"
    # `install -m 600 /dev/null` cria o arquivo já com 600 e recusa symlink. Sem
    # isto, um `> "$OUT"` num arquivo que já existisse manteria a permissão antiga
    # — o umask só vale para arquivo novo.
    install -m 600 /dev/null "$OUT"
    printf '%s' "$TOKEN" > "$OUT"
    if [ -n "$META" ]; then
        EPOCH=$(date -d "$EXPIRA" +%s 2>/dev/null || echo 0)
        printf '{"expires_at":"%s","expires_at_epoch":%s,"permissions":"%s","repositories":"%s","installation_id":%s}' \
            "$EXPIRA" "$EPOCH" "$PERMISSOES" "$REPOS" "$INSTALLATION_ID" > "$META"
        chmod 600 "$META"
    fi
    echo "gh-app-token: token escrito em $OUT (expira $EXPIRA)" >&2
    exit 0
fi

if [ "$PRINT" = "1" ]; then
    printf '%s' "$TOKEN"
    exit 0
fi

if [ -n "$META" ]; then
    erro "--meta só vale junto com --out: o .meta descreve o token gravado"
    exit 64
fi

erro "diga --out, --print ou --check"
exit 64
