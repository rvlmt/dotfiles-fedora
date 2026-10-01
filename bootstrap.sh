#!/usr/bin/env bash
# Provisiona uma VM de agentes nova, a partir de um repositório público.
#
#   curl -fsSL https://raw.githubusercontent.com/rvlmt/dotfiles-fedora/main/bootstrap.sh | bash
#
# ── Por que este arquivo existe ──────────────────────────────────────────────
#
# Porque o `setup.sh` sozinho não basta, e isso é medido: ele lê **dois** outros
# arquivos do repositório, e ambos são alcançados no caminho de provisionamento.
#
#   zshrc                  o módulo `zshrc`, duas vezes
#   bin/gh-app-token.sh    o módulo `gh-app`
#
# Tratar isso com um "clone completo"resolveria, mas exigiria chave SSH — e a
# máquina nova não tem nenhuma. Ler os três por HTTPS funciona sem nenhuma
# credencial, e é o que este arquivo faz.
#
# ── O que ele NÃO faz, e por quê ─────────────────────────────────────────────
#
# Ele não pede nada e não decide nada. As duas coisas que dependeriam de conta de
# terceiro — a private key da GitHub App e o login de pessoa do `gh` — ficam para
# o run seguinte, e o `setup.sh` diz quais são, com o comando de cada uma. Um
# bootstrap que tentasse autenticar abriria um navegador, e nenhum run não
# interativo tem um.
#
# ── A ordem ─────────────────────────────────────────────────────────────────
#
# `curl` → repo em disco → `setup.sh`. O `tailscale up` NÃO acontece aqui: ele
# precisa de navegador e da conta de quem provisiona, e é o único passo que para
# e espera por uma pessoa. O script avisa isso no fim, com o comando.

set -uo pipefail

BASE="https://raw.githubusercontent.com/rvlmt/dotfiles-fedora/main"
# Sobrescrevível por variável de ambiente, para quem quiser o repo em outro
# lugar. O default é o mesmo que o `setup.sh` usa, medido: é onde o OpenDesign
# e as units esperam encontrá-lo.
DESTINO="${DESTINO:-$HOME/Developer/dotfiles-fedora}"

erro() {
  # Para stderr de verdade: um bootstrap que escreve o erro em stdout se mistura
  # com o `curl | bash`, e a pessoa ve a mensagem no lugar errado.
  printf '%s\n' "$*" >&2
}

echo "==> Conferindo o que a máquina tem de fábrica"
# Estes quatro vêm de fábrica numa instalação mínima do Fedora: `curl` e
# `tar` são `Mandatory` no grupo `core` do Anaconda, e `sudo` também. É o que
# permite começar sem instalar nada antes.
for t in curl tar sudo; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "  ✓ $t"
  else
    erro "  ✗ falta o '$t' — e sem ele não há como começar."
    erro "    Num Fedora novo ele costuma vir. Se não veio:"
    erro "    sudo dnf install -y $t"
    exit 1
  fi
done

echo
echo "==> Trazendo o repositório para $DESTINO"
mkdir -p "$DESTINO/bin" || { erro "  ✗ não consegui criar $DESTINO"; exit 1; }

# Uma função, e não tres blocos repetidos: os três arquivos são lidos do mesmo
# lugar para o mesmo destino, e a diferença é só o caminho dentro do repositório.
# Um `curl` que falha tem que PARAR o bootstrap, e não seguir para o
# `setup.sh` — que então falharia por um arquivo que não chegou, com uma
# mensagem que aponta para o sintoma e não para a causa.
buscar() {
  local caminho="$1" destino="$2"
  if ! curl -fsSL "$BASE/$caminho" -o "$destino"; then
    erro "  ✗ não consegui baixar $caminho"
    erro "    URL: $BASE/$caminho"
    erro "    O repositório precisa estar PÚBLICO para este caminho funcionar."
    exit 1
  fi
  # O arquivo chegou. Agora ele tem que ser o que era: um HTML de página de erro
  # devolveu 200 em alguns casos, e o `setup.sh` não distinguiria isso de um
  # script. A checagem é de estado, não de confiança no `curl`.
  if grep -qiE '<!DOCTYPE html|<html' "$destino" 2>/dev/null; then
    erro "  ✗ $caminho veio como uma página HTML, não como o arquivo"
    erro "    Se o repositório é privado, o raw devolve essa página em vez do conteúdo."
    exit 1
  fi
  echo "  ✓ $caminho"
}

buscar "setup.sh"                "$DESTINO/setup.sh"
buscar "zshrc"                   "$DESTINO/zshrc"
buscar "bin/gh-app-token.sh"     "$DESTINO/bin/gh-app-token.sh"

# O helper precisa ser executável, e o setup precisa ser legível. O `chmod` do
# script roda depois, para o caso de um servidor de arquivos que devolva o
# bit de execução desligado.
chmod 0755 "$DESTINO/setup.sh" "$DESTINO/bin/gh-app-token.sh" 2>/dev/null || true

cd "$DESTINO" || { erro "  ✗ não consegui entrar em $DESTINO"; exit 1; }

echo
echo "==> Rodando o provisionamento"
echo "    ./setup.sh --profile=vm --defaults"
echo
echo "    Duas coisas vão ficar pendentes, porque precisam de uma conta e de um"
echo "    navegador, e nenhum run não interativo tem os dois: a GitHub App e o"
echo "    login de pessoa do 'gh'. O script diz o comando de cada uma no fim."
echo

./setup.sh --profile=vm --defaults
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "Provisionamento concluído."
else
  echo "Provisionamento concluído COM PENDÊNCIAS (código $rc)."
  echo "As pendências estão listadas acima, cada uma com o comando que resolve."
fi

echo
echo "==> O único passo que falta é o Tailscale, e ele precisa de você"
echo "    Ele abre o navegador e autentica a sua conta na tailnet."
echo "    Nenhum run não interativo tem navegador, então este fica de fora:"
echo
echo "      sudo tailscale up"
echo
echo "    A partir daí a VM tem IP na tailnet, e o 'ssh' funciona dela."

exit "$rc"
