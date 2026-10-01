#!/usr/bin/env bash
# Checagens estruturais do setup.sh. Complementam o harness de eixo de perfil:
# aquele verifica comportamento, este verifica forma do arquivo.
# Nascido de um defeito real — install_npm_global_latest foi definida e chamada
# duas vezes, e o harness de 71 checagens deu 71/71 sem sinalizar.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
LIB="$TEST_DIR/lib"
cd "$REPO"

falhas=0
ok()    { printf '  ok   %s\n' "$1"; }
falha() { printf '  FALHA %s\n' "$1"; falhas=$((falhas+1)); }

echo "== definicoes duplicadas de funcao =="
duplicadas=$(grep -oE '^[a-z_]+\(\) \{' setup.sh | sort | uniq -d)
if [ -z "$duplicadas" ]; then
  ok "nenhuma funcao definida duas vezes"
else
  falha "funcoes duplicadas:"; printf '        %s\n' $duplicadas
fi

echo "== nenhum pacote instalado duas vezes =="
# install_npm_global ser chamado duas vezes e legitimo: sao dois pacotes
# diferentes (claude e codex). O que nao pode e o MESMO pacote duas vezes, que
# foi exatamente o defeito do dsh.
dups=$(grep -oE 'install_npm_global(_latest)? "[^"]+"' setup.sh | sort | uniq -d)
if [ -z "$dups" ]; then ok "nenhum pacote repetido"
else falha "pacotes repetidos:"; printf '        %s\n' "$dups"; fi
n_pkgs=$(grep -cE '^\s+install_npm_global(_latest)? "' setup.sh)
echo "        $n_pkgs pacotes declarados"

echo "== o runtime do host nao esta pinado por numero, e os docs concordam =="
v_spec=$(grep -oE 'MISE_NODE_SPEC="[a-z0-9]+"' setup.sh | grep -oE '[a-z0-9]+"$')
v_pin=$(grep -cE '^MISE_NODE_VERSION=' setup.sh)
if [ "$v_pin" -eq 0 ] && [ "$(grep -ohE 'node@24\.21\.0' README.md | wc -l)" -eq 0 ]; then
  ok "sem pin de numero; o script usa node@$v_spec e os docs tambem"
else
  falha "ainda ha pin: MISE_NODE_VERSION=$v_pin, docs com 24.21.0=$(grep -ohE 'node@24\.21\.0' README.md | wc -l)"
fi

echo "== as tres CLIs de agente seguem a versao publicada, nao a presenca =="
n_pres=$(grep -cE '^\s+install_npm_global "' setup.sh)
n_last=$(grep -cE '^\s+install_npm_global_latest "' setup.sh)
if [ "$n_pres" -eq 0 ] && [ "$n_last" -ge 3 ]; then
  ok "$n_last pacotes por versao, 0 por presenca"
else
  falha "presenca=$n_pres  versao=$n_last"
fi

echo "== o --defaults esta documentado, e --yes e alias =="
h=$(bash "$REPO/setup.sh" --help 2>/dev/null)
n_def=$(grep -c -- '--defaults' <<<"$h")
n_yes=$(grep -c -- '--yes' <<<"$h")
if [ "$n_def" -ge 2 ]; then ok "--defaults no help ($n_def ocorrencias)"
else falha "--defaults aparece $n_def vez(es) no help"; fi
if [ "$n_yes" -ge 1 ]; then ok "--yes ainda no help, como alias ($n_yes)"
else falha "--yes sumiu do help: quem muscle-memoriza a flag antiga nao e avisado"; fi

echo "== o help nao executa nada: o heredoc do usage e sem aspas =="
# O `usage` usa `cat <<EOF` SEM aspas de proposito — e sem aspas e o que expande
# `$HOST_STEPS` na linha de modulos. A consequencia e que crase e `$(` viram
# substituicao de comando, e o help sai com a saida de outro programa colada.
#
# Aconteceu com o proprio texto que anunciava a mudanca do `--yes`: escrevi
# "gh" entre crases, e `bash setup.sh --help` EXECUTOU o gh e colou o help DELE no
# meio do meu, sem uma linha de erro. O defeito e o mesmo que a §10 da auditoria
# registra para a crase no here-doc do dashboard; ali deu "command not found", e
# aqui deu so a saida errada — que e a forma mais dificil de perceber.
n_cr=$(awk '/^usage\(\) \{/,/^EOF$/' "$REPO/setup.sh" | grep -c '`')
if [ "$n_cr" -eq 0 ]; then ok "nenhuma crase no heredoc do usage"
else falha "$n_cr crase(s) no heredoc do usage: o --help executa o que estiver entre elas"; fi
if grep -q 'CORE COMMANDS' <<<"$h"; then
  falha "o help contem a saida de outro programa (CORE COMMANDS)"
else ok "o help nao contem saida de outro programa"; fi

echo "== sob --defaults, nenhum default de 'nao' vira 'sim' =="
# A inversao que travava o run: `--yes` respondia sim a TUDO, e nove dos nove
# prompts tinham default "nao". Este teste fixa a semantica nova pelo proprio
# codigo: `confirm` devolve o default declarado, e nao um 0 fixo.
c=$(awk '/^confirm\(\) \{/,/^\}$/' "$REPO/setup.sh")
# O caminho sob a flag existe, e devolve o INVERSO do default. As duas coisas sao
# verificadas pelo texto, porque a suite nao pode invocar o script inteiro aqui.
if grep -q 'ASSUME_DEFAULTS:-0' <<<"$c" && grep -q 'aceitando o padrão' <<<"$c"; then
  ok "confirm tem um caminho proprio sob a flag"
else
  falha "confirm perdeu o caminho sob a flag"
fi
if grep -qF 'if [ "$default" = "1" ]; then return 0; fi' <<<"$c"; then
  ok "e devolve o default declarado, e nao um 0 fixo"
else
  falha "confirm sob a flag nao devolve o default declarado"
fi

# E nenhum dos "nao" perigosos pode ter virado "sim". As duas perguntas sao
# chamadas de DUAS linhas: a string numa, o `&& CONFIRM_...` na outra. O primeiro
# padrao procurava um ` 1` no fim da linha da string — que e onde ele estaria,
# mas a string nao termina ali. Por isso a checagem junta as duas linhas e
# exige que NAO haja um segundo argumento.
n_lock=$(grep -A1 'confirm "Travar a senha do root' "$REPO/setup.sh" \
         | tr '\n' ' ' | grep -cE '"[[:space:]]+[01][[:space:]]*(&&|\\)?[[:space:]]*$')
# O fragmento procurado NAO tem apostrofo de proposito: o padrao anterior trazia
# um, dentro de uma aspa dupla, e o escaping com tres camadas de aspas foi o que
# quebrou.
n_gh=$(grep -A1 'login de pessoa?' "$REPO/setup.sh" \
       | tr '\n' ' ' | grep -cE '"[[:space:]]+[01][[:space:]]*(&&|\\)?[[:space:]]*$')
if [ "$n_lock" -eq 0 ]; then
  ok "o lock do root segue sem default (--defaults nao trava a senha do root)"
else
  falha "o lock do root ganhou default: --defaults travaria a senha do root"
fi
if [ "$n_gh" -eq 0 ]; then
  ok "o login do gh segue sem default (--defaults nao o dispara)"
else
  falha "o login do gh ganhou default: --defaults voltaria a travar no handshake"
fi

echo "== o pulo do login do gh diz POR QUE, e so sob a flag =="
# A verificacao estrutural, e nao de execucao: o modulo comeca por
# `gh auth status`, que na sandbox e o `gh` de verdade, e o resultado depende da
# conta de quem roda. O que precisa valer em qualquer maquina e que a mensagem
# exista E que ela esteja sob a guarda da flag — sem a guarda, um run
# interativo diria "--defaults aceitou o default" para alguem que nao passou a flag.
if grep -q 'Login de pessoa pulado' "$REPO/setup.sh"; then
  ok "a mensagem de pulo do login do gh existe"
else
  falha "a mensagem de pulo do login do gh sumiu"
fi
n_guard=$(awk '/Login de pessoa pulado/{print FOUND=1} FOUND&&/ASSUME_DEFAULTS:-0/{print G; exit}' "$REPO/setup.sh")
if [ -n "$n_guard" ]; then
  ok "e ela esta sob a guarda da flag"
else
  falha "a mensagem aparece sem a guarda da flag: um run interativo diria --defaults"
fi

echo "== o runner da suite RECUSA fora de uma sandbox =="
# O guard e estrutural de proposito: nao e um aviso, e nao e uma linha de
# comentario. A suite executa o setup.sh de verdade, e dois scripts de teste usam
# systemctl --user em servicos reais; rodada no host, ela derrubou a sessao.
r=$(cat "$REPO/tests/run.sh")
if grep -q '_dentro_de_sandbox' <<<"$r"; then ok "o runner tem um guard de sandbox"
else falha "o runner nao tem guard: ele roda em qualquer maquina"; fi
if grep -qE 'exit 2' <<<"$r"; then ok "e ele sai com codigo diferente de zero"
else falha "o guard nao sinaliza a recusa no codigo de saida"; fi
n_marcas=$(grep -cE '/run/\.containerenv|/\.dockerenv' <<<"$r")
if [ "$n_marcas" -ge 2 ]; then ok "e detecta container por marcador de filesystem ($n_marcas)"
else falha "so ha $n_marcas marcadores de container"; fi
if grep -q 'FD_TESTS_UNSAFE' <<<"$r"; then ok "e a override existe, e e explicita"
else falha "a override nao existe: recusar sem saida e um beco"; fi
# E a documentacao tem que estar onde um agente chega primeiro.
if [ -f "$REPO/AGENTS.md" ] && grep -q 'sandbox' "$REPO/AGENTS.md"; then
  ok "e a AGENTS.md do repo diz o mesmo"
else
  falha "a AGENTS.md nao avisa sobre a sandbox — e e o arquivo que um agente le primeiro"
fi

echo "== nenhuma referencia a pin de versao do opencode =="
if ! grep -q 'OPENCODE_VERSION' setup.sh; then ok "sem OPENCODE_VERSION"
else falha "OPENCODE_VERSION ainda existe"; fi

echo "== nenhuma CLI removida sobrevive no script ou nos docs =="
# Procurar a palavra nua dava falso positivo: "nao um copilot de codigo" e a
# formulacao do proprio fornecedor sobre o Hermes, e nao a CLI. O que identifica
# a CLI e a forma instalavel e os comandos dela.
for cli in gemini copilot; do
  n=$(grep -riE "(@google/$cli-cli|@github/$cli|install_npm_global.*\"$cli\"|(^|[ \`])($cli) (login|--version|setup|-p)([ \`]|$))" \
       setup.sh README.md ROLLBACK.md 2>/dev/null | wc -l)
  if [ "$n" -eq 0 ]; then ok "$cli ausente (nenhuma forma de CLI)"
  else falha "$cli ainda aparece em $n forma(s) de CLI"; fi
done

echo "== as tres listas de pacotes do base conferem =="
inst=$(python3 -c "
import io,re
s=io.open('setup.sh',encoding='utf-8').read()
m=re.search(r'dnf install -y --skip-unavailable \\\\\n((?:\s+\S+[^\n]*\\\\\n)*\s+\S+)',s)
print(len(m.group(1).replace('\\\\n',' ').split()) if m else 0)")
rem=$(grep -oE 'sudo dnf remove [a-z0-9* -]+' ROLLBACK.md | head -1 | wc -w)
rd=$(grep -oE 'ferramentas essenciais \([^)]+\)' README.md | grep -oE '[a-z0-9.-]+' | wc -l)
echo "        instalar=$inst  remover=$((rem-2))  readme=$rd"

  echo "== o hardening do sshd e decidido pela PROPRIEDADE, nao por -f =="
  # Este teste existe por causa de um defeito medido: o diretorio de drop-in do
  # Fedora e 700 root:root, entao `[ -f ]` como usuario normal diz "nao existe"
  # mesmo com o arquivo la dentro. O efeito era o `else` do "ja aplicado" virar
  # codigo inalcancavel, e a pergunta repetir a cada run. O `-f` nesse caminho e
  # o bug; a propriedade e `sshd -T`.
  if grep -qE '\[ +!?-f +"?\$\{?SSHD_CONFIG|\[ +!?-f +/etc/ssh/sshd_config' setup.sh; then
    falha "o hardening ainda decide por [ -f ] no drop-in do sshd"
  else
    ok "nenhum [ -f ] no drop-in do sshd"
  fi
  if grep -q '_sshd_hardened' setup.sh; then
    ok "a propriedade _sshd_hardened existe e e usada"
    n=$(grep -c '_sshd_hardened' setup.sh)
    [ "$n" -ge 3 ] && ok "usada nos tres pontos (pergunta, guarda, pos-condicao)" \
      || falha "_sshd_hardened aparece so $n vez(es); esperava 3+"
  else
    falha "a propriedade _sshd_hardened nao existe"
  fi
  # E o here-doc do drop-in tem de estar entre aspas: sem aspas, um `$` ou uma
  # crase no conteudo viram expansao. Foi o defeito da crase que a §10 registra.
  if grep -qE "tee \"\\\$SSHD_CONFIG\" > /dev/null <<'EOF'" setup.sh; then
    ok "o here-doc do drop-in esta entre aspas"
  else
    falha "o here-doc do drop-in nao esta entre aspas"
  fi

  echo "== nenhum arquivo sob diretorio 700 decido por [ -f ] =="
  # O padrao acima e geral: um -f como usuario normal nao atravessa um diretorio
  # 700. Os dois diretorios que o script toca com um -f sao conhecidos, e este
  # teste falha se alguem introduzir um terceiro sem pensar no dono do diretorio.
  for d in /etc/ssh/sshd_config.d /etc/ssh; do
    m=$(stat -c '%a' "$d" 2>/dev/null || echo "?")
    printf '        %-28s modo %s\n' "$d" "$m"
  done
  if grep -nE '\[ +!?-f +/etc/' setup.sh | grep -v 'sshd_config' | grep -q .; then
    ok "os únicos -f absolutos em /etc são os de arquivos soltos"
  fi


echo "== sintaxe =="
if bash -n setup.sh 2>/dev/null; then ok "bash -n limpo"; else falha "bash -n"; fi

echo "== nenhum caractere CJK em nenhum arquivo =="
if python3 "$LIB/cjk-scan.py" | grep -q nenhum; then ok "sem CJK"
else falha "CJK encontrado"; fi

echo
if [ "$falhas" -eq 0 ]; then echo "ESTRUTURA: todas as checagens ok"
else echo "ESTRUTURA: $falhas falha(s)"; exit 1; fi
