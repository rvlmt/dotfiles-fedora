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
runner="$(cat "$REPO/tests/run.sh")"
if grep -q '_dentro_de_sandbox' <<<"$runner"; then ok "o runner tem um guard de sandbox"
else falha "o runner nao tem guard: ele roda em qualquer maquina"; fi
if grep -qE 'exit 2' <<<"$runner"; then ok "e ele sai com codigo diferente de zero"
else falha "o guard nao sinaliza a recusa no codigo de saida"; fi
n_marcas=$(grep -cE '/run/\.containerenv|/\.dockerenv' <<<"$runner")
if [ "$n_marcas" -ge 2 ]; then ok "e detecta container por marcador de filesystem ($n_marcas)"
else falha "so ha $n_marcas marcadores de container"; fi
if grep -q 'FD_TESTS_UNSAFE' <<<"$runner"; then ok "e a override existe, e e explicita"
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
  if grep -nE '\[ +!?-f +/etc/' setup.sh | grep -v 'sshd_config' | grep -c . >/dev/null; then
    ok "os únicos -f absolutos em /etc são os de arquivos soltos"
  fi


# O codigo sem os comentarios, para as checagens que sao sobre CODIGO. Sem isto,
# um `grep` no arquivo inteiro casa o comentario que explica a propria proibicao:
# foi assim que a checagem do hostname acusou o codigo correto, porque a frase
# que ela proibe sobrevivia na explicacao de por que a pergunta foi removida.
codigo="$(grep -vE '^[[:space:]]*#' "$REPO/setup.sh")"

echo "== o shim de gh, e so no perfil vm =="
# A identidade da maquina e da pessoa sao ALTERNATIVAS. O shim injetaria
# GH_TOKEN, e a documentacao do gh diz que essa variavel tem precedencia sobre
# as credenciais guardadas — num host, isso sobrescreveria o login de quem usa a
# maquina. O perfil e a unica coisa que sabe qual maquina e esta.
# (o `codigo` abaixo e derivado deste arquivo; a variavel `r` foi eliminada para
# que nenhuma checagem possa ler o objeto errado por heranca de nome)
if grep -A1 'if \[ "\$PROFILE" = "vm" \] && \[ -n "\$_real_gh" \]; then' <<<"$codigo" \
     | grep -c 'local/bin/gh' >/dev/null ; then
  ok "o shim de gh e instalado sob o perfil vm"
else
  falha "o shim de gh nao esta sob o perfil vm"
fi
if grep -q 'elif \[ "\$PROFILE" = "host" \]' <<<"$codigo"; then
  ok "e o perfil host diz explicitamente que nao instala shim"
else
  falha "o host nao declara a ausencia do shim: sem isso, um shim herdado continua valendo"
fi
# O shim e o wrapper se chamariam pelo `command gh` se nenhum deles usasse caminho
# absoluto: cada um acharia o outro e chamaria de volta, para sempre.
n_abs=$(grep -c 'exec "\$REAL_GH"' <<<"$codigo")
if [ "$n_abs" -ge 1 ]; then
  ok "os wrappers chamam o gh por caminho absoluto (sem recursao entre shim e wrapper)"
else
  falha "nenhum wrapper usa caminho absoluto do gh: shim e wrapper podem se chamar para sempre"
fi
if grep -q '__REAL_GH__' <<<"$codigo"; then
  ok "e o caminho do gh real e resolvido antes de ser assado nos dois"
else
  falha "o caminho do gh real nao e assado: o shim e o wrapper naoTem o que execar"
fi

echo "== o default do modo do OpenDesign =="
# Virou container. O que torna isso seguro e o podman-compose: sem o provider,
# `podman compose` falha e o default entregaria uma VM quebrada. Por isso a
# ordem estas duas checagens nao e arbitraria.
if grep -q 'Modo \[container/nativo\]' <<<"$codigo"; then
  ok "o prompt anuncia container primeiro"
else
  falha "o prompt nao anuncia o default novo"
fi
if grep -q '\[ -n "\$OPENDESIGN_MODE" \] || OPENDESIGN_MODE="container"' <<<"$codigo"; then
  ok "e o Enter sem resposta aplica o default (o caso aceita a string vazia)"
else
  falha "o Enter nao aplica o default: apertar Enter repregunta e o default e ilusao"
fi
if grep -q 'OPENDESIGN_MODE="container"' <<<"$codigo"; then
  ok "e --defaults instala o modo container"
else
  falha "--defaults nao instala container"
fi
if grep -q 'sudo dnf install -y podman-compose' <<<"$codigo"; then
  ok "e o passo podman instala o podman-compose, que o modo container exige"
else
  falha "o podman-compose nao e instalado: o modo container falha numa VM limpa"
fi

echo "== o .env do OpenDesign =="
# Medido no clone: deploy/.env e coberto por deploy/.gitignore; o .env da raiz
# NAO e coberto por nada e aparecia como '?? .env' -- e ele tem o token dentro.
if grep -q 'cp "\$D/.env.example" "\$envf"' <<<"$codigo"; then
  ok "o modo container parte do .env.example, como o upstream documenta"
else
  falha "o .env e escrito do zero e descarta as outras chaves do template"
fi
if grep -q 'info/exclude' <<<"$codigo"; then
  ok "o .env da raiz e coberto por .git/info/exclude, e nao pelo .gitignore do upstream"
else
  falha "o .env da raiz, que tem o token, continua aparecendo como ?? .env"
fi
if grep -q 'check-ignore -q .env' <<<"$codigo"; then
  ok "e a cobertura e verificada por ESTADO (check-ignore), nao pelo log impresso"
else
  falha "a pos-condicao do .env nao e verificada: um log sem o efeito ao lado nao prova nada"
fi
# Idempotencia sem destruir credencial: regerar do template com token vazio
# apagaria um token em uso.
if grep -q '_od_token_anterior' <<<"$codigo"; then
  ok "e um token ja escrito e preservado quando a execucao nao traz um novo"
else
  falha "regerar o .env com token vazio apaga um token em uso"
fi

echo "== o login do gh e por perfil, e --defaults nao abre o handshake =="
if grep -q 'if \[ "\$PROFILE" = "host" \]; then' <<<"$codigo"; then
  ok "o default do login de pessoa e decidido pelo perfil"
else
  falha "o login de pessoa nao e decidido pelo perfil"
fi
# A razao do guard: `gh auth login -w` abre o navegador e espera. Foi onde o
# --yes antigo travou para sempre, e um default que trava nao e um default.
n_handshake=$(grep -c 'gh auth login -p https -w' <<<"$codigo")
n_guard=$(grep -c 'ASSUME_DEFAULTS' <<<"$codigo")
if [ "$n_guard" -ge 1 ] && [ "$n_handshake" -ge 1 ]; then
  ok "e ha um caminho de --defaults que nao chega no handshake do navegador"
else
  falha "o --defaults pode chegar no handshake do gh e travar para sempre"
fi

echo "== o hostname nao tem segunda pergunta =="
# Havia um 'Alterar o hostname para X?' depois da pergunta. Nao decidia nada: quem
# aceitou o default ja disse sim. E o efeito era o oposto do pretendido — sob
# --defaults ela aceitava o 'nao' e a VM ficava com o nome do hypervisor, que e
# exatamente o que o passo existe para trocar.
n_host=$(grep -c "Alterar o hostname para" <<<"$codigo")
if [ "$n_host" -eq 0 ]; then
  ok "a pergunta do hostname e unica, como as de identidade"
else
  falha "a segunda pergunta do hostname ainda existe ($n_host vez(es))"
fi
if grep -q 'Novo hostname \[\$NEW_HOSTNAME_SUGGESTED\]' <<<"$codigo"; then
  ok "e o default vem entre colchetes, que e o formato das perguntas 1-2"
else
  falha "o hostname nao mostra o default entre colchetes"
fi

echo "== nenhum check_not que nao pode falhar =="
# Um check_not passa quando a saida NAO contem o texto proibido. Se esse texto nao
# existe no codigo, a checagem e sempre verdadeira: conta como cobertura e nao
# mede nada. Foi assim que duas das 103 eram foles — proibiam um banner com
# sufixo de modo que o script nunca imprimiu.
if python3 "$LIB/check-not-vacuous.py"; then
  ok "todo check_not proibe algo que o script poderia imprimir"
else
  falha "ha check_not que nao pode falhar: contam como cobertura sem medir"
fi

echo "== o exit sai das pos-condicoes, e nao do set -e =="
# Nao havia exit explicito nenhum. O exit 1 que apareceu na VM foi o `set -e`
# reagindo ao `return 1` de um modulo, o que significa que o mesmo return 1
# encerra o run num ponto e so marca falha em outro, conforme a posicao. Um codigo
# de saida que depende de posicao e acaso com aparencia de contrato.
if grep -q '_rodar_pos_condicoes' <<<"$codigo"; then
  ok "existe uma etapa de pos-condicoes"
else
  falha "o run nao tem pos-condicoes: o exit passa a ser acidente do set -e"
fi
# O exit tem que estar nos DOIS desfechos, e no fim do script. A forma idiomatica
# e `if ...; then exit 1; fi; exit 0` — o `exit 1` fica indentado e o `exit 0`
# nao, entao o padrao tem de aceitar indentacao. A primeira versao desta checagem
# procurava `^exit` e falhou com o codigo CORRETO: era a checagem que estava errada,
# e nao o codigo, que e a mesma distincao da §10.15 vale nas duas direcoes.
n_exit=$(grep -cE '^[[:space:]]*exit [01]$' <<<"$codigo")
if [ "$n_exit" -ge 2 ]; then
  ok "e o exit e explicito nos dois desfechos ($n_exit)"
else
  falha "o exit nao e explicito nos dois desfechos: achei $n_exit"
fi
if tail -5 "$REPO/setup.sh" | grep -qE '^exit [01]$'; then
  ok "e ele esta no fim do script"
else
  falha "o exit nao esta no fim: algo depois dele decide o codigo de saida"
fi

echo "== as pos-condicoes VERIFICAM estado, e nao o log que o script imprimiu =="
# Cada pendencia e uma funcao que pergunta ao sistema se a coisa existe. A
# diferenca entre as duas coisas e a razao delas existirem: o log e o que o
# script disse, o estado e o que a maquina tem.
n_estado=0
for alvo in 'is-active --quiet opencode.service' \
            'podman container exists open-design' \
            'podman inspect -f' \
            'tailscale serve status' \
            'readlink -f "$HOME/.zshrc"'; do
  if grep -qF -- "$alvo" <<<"$codigo"; then
    n_estado=$((n_estado + 1))
  fi
done
if [ "$n_estado" -ge 4 ]; then
  ok "as pos-condicoes consultam o estado, nao o log ($n_estado de 5)"
else
  falha "as pos-condicoes consultam o log em vez do estado ($n_estado de 5)"
fi
if grep -q '_registrar_falha\|_registrar_ok' <<<"$codigo"; then
  ok "e cada uma registra o desfecho, para o banner e o exit lerem a mesma lista"
else
  falha "as pos-condicoes nao registram o desfecho: banner e exit nao vem da mesma fonte"
fi

echo "== o banner nao e mais incondicional =="
# Um 'finalizada' ao lado de um exit 1 era uma contradicao. Agora o texto sai da
# lista de pendencias, entao o banner e o exit nao podem divergir.
if grep -q '_banner="Configuração da VM de agentes' <<<"$codigo"; then
  ok "o banner e montado a partir da lista de pendencias"
else
  falha "o banner e incondicional: ele diz 'finalizada' mesmo com pendencia"
fi
if grep -q 'pendência(s)' <<<"$codigo"; then
  ok "e ele tem um desfecho para quando ha pendencia, com a lista"
else
  falha "o banner nao tem desfecho para o caso com pendencia"
fi
if grep -q 'for _f in "\${_FALHAS\[@\]}"' <<<"$codigo"; then
  ok "e a pendencia vem nomeada, e nao so como numero"
else
  falha "a pendencia e so um numero: obriga a voltar ao log e casar com a linha"
fi

echo "== o conflito dos dois modos do OpenDesign: o script resolve, nao recusa =="
# O script e o DONO da unit open-design.service: ele a cria e a habilita. Deixar
# o desmonte para a mao era incoerente com isso, e tornava o default novo num
# beco: numa maquina que ja rodou o nativo, TODO run futuro falhava aqui.
if grep -q 'systemctl --user disable --now open-design.service' <<<"$codigo"; then
  ok "o script desliga e desabilita o nativo, que e dele"
else
  falha "o script recusa o conflito em vez de resolver, e o nativo e dele"
fi
if grep -q 'A unit continua no disco' <<<"$codigo"; then
  ok "e a unit fica preservada, para o caminho de volta ao nativo"
else
  falha "o script apaga a unit, e perde o caminho de volta ao modo nativo"
fi
# O caso inverso e DESTRUTIVO (remover container apaga dados), entao esse recusa.
if grep -q 'podman rm -f open-design' <<<"$codigo"; then
  ok "e o caso inverso ainda recusa, porque remover container apaga dados"
else
  falha "o caso inverso passou a apagar container: isso e destrutivo"
fi

echo "== as pos-condicoes nao sao alarme falso num run parcial =="
# Um --only instala uma coisa e NAO as outras, por escolha. Se as pos-condicoes
# perguntarem pela maquina inteira, elas reportam como pendencia tudo o que o run
# proposadamente nao instalou — e o run parcial termina com "7 pendencias" numa
# maquina que esta exatamente como o --only pediu. Alarme falso treina quem le a
# ignorar a saida, que e o que as pos-condicoes vieram evitar.
if grep -q 'if \[ -n "\$ONLY" \]; then' <<<"$codigo"; then
  ok "um run --only verifica so o que instalou"
else
  falha "um run --only verifica a maquina inteira: toda pendencia e alarme falso"
fi
# E a variavel tem que ser a de verdade. Eu escrevi ONLY_STEPS, que nao existe
# no script — a condicao nunca era verdadeira e todo --only caia no caminho do
# perfil inteiro, que e exatamente o que a checagem devia pegar.
if grep -qE '^ONLY=""' <<<"$codigo"; then
  ok "e a condicao usa a variavel que o script realmente define (ONLY)"
else
  falha "a variavel ONLY nao existe no script: a condicao nunca e verdadeira"
fi
if grep -q 'ONLY_STEPS' <<<"$codigo"; then
  falha "a condicao usa ONLY_STEPS, que o script nao define"
else
  ok "e nao usa nenhum nome inventado"
fi

echo "== o 'tailscale up' e pendencia, e nao travamento =="
# Numa VM recem-criada a maquina NAO esta conectada, entao este e o caminho que o
# run sempre pega. E `tailscale up` abre o navegador e ESPERA — o mesmo modo de
# falha que travou o --yes antigo no handshake do gh, agora no modulo que da
# acesso a maquina.
if grep -q 'sudo tailscale up' <<<"$codigo"; then
  if grep -B12 'sudo tailscale up' <<<"$codigo" | grep -c 'ASSUME_DEFAULTS' >/dev/null ; then
    ok "o 'tailscale up' e pulado sob --defaults"
  else
    falha "o 'tailscale up' roda sem guarda: trava o --defaults numa VM nova"
  fi
else
  falha "nao ha 'tailscale up' no script: a VM nunca entra na tailnet"
fi
if grep -q "sudo tailscale up'" <<<"$codigo" || grep -c 'rode .sudo tailscale up' <<<"$codigo"; then
  ok "e a pendencia diz o comando, em vez de so dizer que falhou"
else
  falha "a pendencia do tailscale nao diz o comando que resolve"
fi

echo "== o registro das pendencias vem ANTES de qualquer modulo =="
# Isto eu fiz ao contrario na primeira vez: a lista estava definida perto do fim,
# e o `provision_tailscale` a usava antes dela existir. Em bash isso nao da erro
# de sintaxe — da lista vazia, e o run reporta "pronto". E o modo de falha mais
# caro, porque ninguem tem como dizer que nao foi.
d=$(grep -n '^_FALHAS=()' <<<"$codigo" | head -1 | cut -d: -f1)
u=$(grep -n '    provision_tailscale$' <<<"$codigo" | head -1 | cut -d: -f1)
if [ -n "$d" ] && [ -n "$u" ] && [ "$d" -lt "$u" ]; then
  ok "a lista ($d) vem antes do uso ($u)"
else
  falha "a lista de pendencias ($d) nao vem antes do uso ($u): o run reportaria 'pronto'"
fi

echo "== o README documenta o passo 0, e o comando e o que funciona =="
# O `setup.sh` nao provisiona a VM: ele roda DENTRO de uma maquina que ja existe.
# Sem o passo 0 escrito, quem provisionar uma VM nova nao sabe como trazer o
# script — e o repositorio, antes desta mudanca, era privado.
r=$(cat "$REPO/README.md")
if grep -q '## Passo 0' <<<"$r"; then
  ok "o README documenta o passo 0 (trazer o script para a VM nova)"
else
  falha "o README nao tem o passo 0: como trazer o script fica por conta de quem le"
fi
# A forma do pipe e o que importa, e a forma curta e a perigosa: `| bash`
# FUNCIONA e provisiona o perfil `host` numa VM de agentes, sem aviso e com
# codigo 0. Um README que documenta so a forma longa deixa a pessoa Discovering
# isso sozinha, na base do erro.
if grep -q 'bash -s -- --profile=vm --defaults' <<<"$r"; then
  ok "o README documenta o pipe com -s --"
else
  falha "o README documenta o pipe sem o -s --, que provisiona 'host' em silencio"
fi
if grep -q 'provisiona a máquina errada' <<<"$r"; then
  ok "e avisa que a forma curta da certo resultado errado"
else
  falha "o README nao avisa sobre a forma curta: e a que a pessoa vai digitar"
fi
# Nenhum segredo atravessa o caminho do README. O que nao pode aparecer ali e um
# segredo de verdade; a chave publica e inofensiva e nao aparece mais.
if grep -qE 'ghp_[A-Za-z0-9]{20}|BEGIN [A-Z ]*PRIVATE KEY' <<<"$r"; then
  falha "o README tem o que parece ser um segredo"
else
  ok "e nenhum segredo aparece no README"
fi
# O comando precisa ter SINTAXE valida, extraida do README e conferida de
# verdade. A primeira versao aceitava o proprio fracasso como "ok" — um teste que
# nao pode falhar e pior que nenhum.
# A extracao pega o comando INTEIRO, que no README ocupa duas linhas com barra de
# continuacao. A primeira versao pegava de `curl -fsSL` ate `bash -s --` e cortava
# no meio, e o `bash -n` falhava — a checagem acusava o README por um problema do
# proprio sed. A barra e removida antes de conferir, senao o comando fica com uma
# continuacao pendurada.
_tmp_c=$(mktemp)
awk '/^curl -fsSL/{p=1} p{print} p&&/bash -s --/{exit}' "$REPO/README.md" \
  | sed 's/\\\\$//' > "$_tmp_c"
if [ -s "$_tmp_c" ] && bash -n "$_tmp_c" 2>/dev/null; then
  ok "e o comando do passo 0 tem sintaxe valida ($(wc -l < "$_tmp_c") linhas)"
else
  falha "o comando do passo 0 do README nao tem sintaxe valida"
  bash -n "$_tmp_c" 2>&1 | head -2 | sed 's/^/        /'
fi
rm -f "$_tmp_c"

echo "== o caminho por pipe traz SO o que o setup.sh le =="
# Um repositorio de dotfiles nao precisa de dois scripts para se instalar: o
# `setup.sh` se obtem quando chega por pipe, e traz os anexos de que ele depende.
# A lista vem do PROPRIO codigo, nao de uma lista escrita a mao — uma lista a mao
# desatualiza em silencio quando o script ganha uma dependencia nova.
if grep -q '_se_colocar_no_disco_e_reexecutar' <<<"$codigo"; then
  ok "o setup.sh se monta quando chega por pipe"
else
  falha "o setup.sh nao se obtem: o caminho do curl exige um segundo script"
fi
if grep -q '_anexos_necessarios' <<<"$codigo"; then
  ok "e a lista de anexos vem do proprio codigo"
else
  falha "a lista de anexos esta escrita a mao: desatualiza em silencio"
fi
# O destino e um lugar de INSTALACAO, nao de codigo. `~/tmp/dotfiles` e o que a
# auditoria do comando usa, e o padrao.
if grep -q 'SETUP_DESTINO="\${SETUP_DESTINO:-\$HOME/tmp/dotfiles}"' <<<"$codigo"; then
  ok "e o destino e ~/tmp/dotfiles, e nao ~/Developer"
else
  falha "o destino nao e ~/tmp/dotfiles: material de instalacao com cara de projeto"
fi

echo "== o filtro de pagina de erro nao se rejeita sozinho =="
# O filtro procurava `<!DOCTYPE html|<html` no arquivo BAIXADO — e a propria
# linha do filtro estava nesse arquivo, entao o script se rejeitava. A montagem
# nunca passava, e o sintoma era "nao consegui baixar o setup.sh" com um GET 200
# no log do servidor: mensagem CORRETA, causa ERRADA.
# A pergunta estavel e o TIPO, e o sinal de que ele e pedido e a classe `case`
# com `text/html`. Uma busca pelo nome do cabecalho nao serve: o texto do `sed`
# tem a forma `[Cc]ontent-[Tt]ype`, com colchetes, e qualquer padrao que casasse o
# nome teria que repetir essa forma — o que e testar a grafia, nao o
# comportamento. `text/html` so aparece quando a rejeicao e por tipo.
if grep -q 'text/html' <<<"$codigo"; then
  ok "a rejeicao de HTML pergunta o Content-Type, e nao o conteudo"
else
  falha "a rejeicao nao e por tipo de resposta: o filtro se rejeita sozinho"
fi
# E o sinal de que o filtro NAO procura mais HTML no arquivo: nenhum `grep -qi`
# de HTML sobre o destino pode existir, que e o que se auto-rejeitava.
if grep -qE "grep -qiE? .*[Dd][Oo][Cc][Uu][Mm][Ee][Nn][Tt]" <<<"$codigo"; then
  falha "ainda ha um grep de DOCTYPE no arquivo baixado: e o filtro que se rejeita"
else
  ok "e nao ha mais busca de DOCTYPE no conteudo do arquivo"
fi
# A pergunta de Content-Type tem que ser a do arquivo BAIXADO, e nao a de uma
# referencia a \$SCRIPT_DIR, que e o bug circular: a funcao aceitava um anexo so
# se ele ja estivesse no destino, que e o que ainda nao existe.
if grep -q 'curl -fsI' <<<"$codigo"; then
  ok "e a lista verifica o anexo na URL, e nao no destino (que e circular)"
else
  falha "a lista filtra por existencia no destino: nunca aceita nenhum anexo"
fi

echo "== o pipe sem argumentos recusa, e nao provisiona 'host' =="
# `curl | bash` e a forma que todo mundo escreve, e ela FUNCIONA: o script roda
# inteiro, com o perfil `host`. Numa VM de agentes, isso provisiona a camada da
# maquina de trabalho e nao a da fronteira — sem aviso e com codigo 0.
if grep -q 'veio por pipe sem nenhum argumento' <<<"$codigo"; then
  ok "o script detecta o pipe sem argumento"
else
  falha "o script nao detecta o pipe sem argumento: provisiona 'host' sem avisar"
fi
if grep -q 'bash -s -- --profile=vm' <<<"$codigo"; then
  ok "e a mensagem diz a forma correta do pipe, com o -s --"
else
  falha "a recusa nao diz a forma correta: a pessoa repete o comando errado"
fi

echo "== a forma do pipe no README e a que funciona =="
rr=$(cat "$REPO/README.md")
if grep -q 'bash -s -- --profile=vm --defaults' <<<"$rr"; then
  ok "o README documenta o pipe com -s --"
else
  falha "o README documenta o pipe sem o -s --, que provisiona 'host' em silencio"
fi
# E o README tem de AVISAR que a forma curta funciona e provisiona errado, porque
# ela e a que a pessoa vai digitar.
if grep -q 'provisiona a máquina errada' <<<"$rr"; then
  ok "e avisa que a forma curta da certo resultado errado"
else
  falha "o README nao avisa sobre a forma curta: e a que a pessoa vai digitar"
fi

echo "== a montagem por pipe roda TAMBEM com --defaults =="
# O bug: a montagem estava DENTRO de `if [ ! -t 0 ] && [ ASSUME_DEFAULTS != 1 ]`,
# que e o tratamento do pipe ACIDENTAL. O caminho do `curl` e nao-terminal COM
# --defaults, entao a condicao e `verdadeiro E falso`, e a montagem nunca rodava.
# Resultado medido em tres runs seguidos na VM nova: o `SCRIPT_DIR` ficava sendo o
# diretorio de onde a pessoa digitou, e o modulo do `zshrc` criava um symlink
# quebrado para `$HOME/zshrc`.
#
# A ordem e o que se verifica: a montagem ANTES do tratamento do pipe acidental.
m_mont=$(grep -n 'if ! _se_colocar_no_disco_e_reexecutar' <<<"$codigo" | head -1 | cut -d: -f1)
m_acid=$(grep -n 'if \[ ! -t 0 \] && \[ "\${ASSUME_DEFAULTS' <<<"$codigo" | head -1 | cut -d: -f1)
if [ -n "$m_mont" ] && [ -n "$m_acid" ] && [ "$m_mont" -lt "$m_acid" ]; then
  ok "a montagem ($m_mont) vem antes do pipe acidental ($m_acid)"
else
  falha "a montagem esta depois ou dentro do pipe acidental: com --defaults ela nunca roda"
fi
# E a sua propria condicao so pode ser "veio por pipe de verdade" — sem
# --defaults e sem depender de onde a pessoa digitou.
# A janela do `-A` precisa ser MAIOR que a distancia entre o `if` e a chamada, e
# a primeira versao usou `-A7` contra uma distancia de 11. O grep nao achou a
# chamada e acusou a CHEIAGEM de estar errada — quando a condicao dela estava
# certa. Um teste que depende de uma janela magica quebra quando o codigo cresce
# dentro dela, e o sintoma e uma acusacao falsa.
_c_mont=$(grep -n 'if ! _se_colocar_no_disco_e_reexecutar' <<<"$codigo" | head -1 | cut -d: -f1)
_c_if=$(grep -n 'if \[ ! -t 0 \] && \[ ! -s "\${BASH_SOURCE\[0\]:-}" \]; then' <<<"$codigo" | head -1 | cut -d: -f1)
if [ -n "$_c_if" ] && [ -n "$_c_mont" ] && [ "$_c_mont" -gt "$_c_if" ] \
   && [ $((_c_mont - _c_if)) -le 20 ] \
   && awk -v a="$_c_if" 'NR>=a && NR<=a+20' <<<"$codigo" | grep -c '_se_colocar_no_disco_e_reexecutar' >/dev/null ; then
  ok "e a condicao dela e so 'veio por pipe de verdade'"
else
  falha "a montagem continua condicionada a algo alem de ter vindo por pipe"
fi

echo "== os DOIS modos do OpenDesign clonam o repositorio =="
# Medido na VM nova com o modo container (o default): o modulo reclamou
# "Falta .../deploy/docker-compose.yml". O clone vivia dentro de
# `_setup_open_design_native`, e o container nao tinha clone nenhum — ele usava
# `$OPENDESIGN_SRC/deploy` como se o repositorio ja estivesse la.
# A mensagem estava CORRETA e apontava para o lugar ERRADO: o arquivo nao existia
# porque o clone nunca tinha sido feito.
if grep -q '_garantir_clone_open_design' <<<"$codigo"; then
  ok "existe uma rotina de clone compartilhada"
else
  falha "o clone continua dentro de um so modo, e o outro falha sem o repositorio"
fi
n_modos=0
for m in '_setup_open_design_native' '_setup_open_design_container'; do
  ini=$(grep -n "^${m}() {" <<<"$codigo" | head -1 | cut -d: -f1)
  [ -z "$ini" ] && continue
  # O fecho e o primeiro `}` NA COLUNA 0 DEPOIS do inicio. Um `^}` achado antes
  # (o fim de um `if` interno com o `}` indentado nao conta, mas um bloco
  #fechado sem indentacao sim) encurtaria a janela e a funcao pareceria nao ter
  # a chamada. Por isso a busca comeca DEPOIS da linha de inicio.
  fim=$(awk -v s="$ini" 'NR>s && /^}/ {print NR; exit}' <<<"$codigo")
  # `grep -q` sai assim que acha, o `awk` recebe SIGPIPE, e o `pipefail` do topo da
  # suite transforma o 141 em FALHA — mesmo com a ocorrencia la. Medido: `exit=141`
  # com pipefail e `exit=0` sem. E o `grep -q` estava na posicao de quem
  # encontra a linha; o `grep -c` le tudo e nao sofre com isso.
  if awk -v a="$ini" -v b="$fim" 'NR>=a && NR<=b' <<<"$codigo" | grep -c '_garantir_clone_open_design' >/dev/null; then
    n_modos=$((n_modos + 1))
  else
    falha "$m nao garante o clone (linhas $ini..${fim:-?})"
  fi
done
if [ "$n_modos" -eq 2 ]; then
  ok "e os dois modos o usam"
fi
# E um clone que falhou nao pode deixar diretorio pela metade: sem isso o
# proximo run acha o diretorio, pula o clone, e falha num `pnpm` que nao existe —
# o sintoma de um clone quebrado no lugar do sintoma do clone que falhou.
if grep -A14 'if ! git clone -q --depth 1' <<<"$codigo" | grep -c 'rm -rf "\$OPENDESIGN_SRC"' >/dev/null ; then
  ok "e um clone que falhou nao deixa diretorio pela metade"
else
  falha "um clone malformado fica no disco e o proximo run pula o clone"
fi

echo "== o shell de login e medido pelo passwd, nao pelo codigo de saida do chsh =="
# Medido no container, com um usuario de teste:
#
#     $ chsh -s /bin/bash tester     # o shell que ele JA tinha
#     Changing shell for tester.
#     chsh: Shell not changed.
#     exit=0
#
# O `chsh` sai com 0 QUANDO NAO MUDOU NADA, e o `man` nao avisa disso: "0 se a
# operacao deu certo, 1 se falhou". Com o `&&` do jeito antigo, o script imprimia
# "✓ Shell padrão alterado" depois de um chsh que tinha dito "Shell not changed."
# — foi assim que o log mentiu na VM nova.
#
# A prova e a entrada do passwd depois da chamada, e nao o codigo de saida dela.
n_chsh=$(grep -c 'chsh -s' <<<"$codigo")
if [ "$n_chsh" -eq 1 ]; then
  ok "o chsh aparece uma vez, e a decisao esta em volta dele"
else
  falha "o chsh aparece $n_chsh vez(es); a decisao precisa estar em um lugar so"
fi
# O `&&` do chsh e o que fabricava o sucesso. Nao pode sobrar.
if grep 'chsh -s' <<<"$codigo" | grep -c '&&' >/dev/null; then
  falha "o chsh ainda esta ligado por && — e ele sai com 0 sem mudar nada"
else
  ok "e nao esta mais ligado por &&"
fi
# E o estado tem de ser lido do passwd, e nao do $SHELL (que e o shell do
# PROCESSO, herdado de quem abriu a sessao, e nao o shell de LOGIN do usuario).
if grep -q 'getent passwd' <<<"$codigo"; then
  ok "o shell de login e lido do passwd, e nao do \$SHELL"
else
  falha "o shell de login ainda vem do \$SHELL, que e o shell do processo"
fi
# A leitura tem de acontecer DEPOIS do chsh tambem: e a comparacao pos-chamada que
# distingue "mudou" de "disse que mudou".
if grep -c '_shell_login' <<<"$codigo" >/dev/null && [ "$(grep -c '_shell_login' <<<"$codigo")" -ge 3 ]; then
  ok "e a funcao de leitura e usada antes e depois do chsh"
else
  falha "a leitura do passwd aparece uma vez so; sem a comparacao pos-chamada nao ha prova"
fi
# O padrao `${_shell_login:-desconhecido}` e o bug do,sai do parentesis. Com
# chaves, bash expande uma variavel chamada pelo VALOR da funcao, e o resultado e
# sempre a string "desconhecido" — a frase aponta para o lugar errado.
if grep -c '${_shell_login' <<<"$codigo" >/dev/null; then
  falha "tem \${_shell_login:-...}: isso nao chama a funcao, e sempre da 'desconhecido'"
else
  ok "e a funcao e chamada com \$(), nao com \${}"
fi

echo "== sintaxe =="
if bash -n setup.sh 2>/dev/null; then ok "bash -n limpo"; else falha "bash -n"; fi

echo "== nenhum caractere CJK em nenhum arquivo =="
if python3 "$LIB/cjk-scan.py" | grep -c nenhum >/dev/null; then ok "sem CJK"
else falha "CJK encontrado"; fi

echo
if [ "$falhas" -eq 0 ]; then echo "ESTRUTURA: todas as checagens ok"
else echo "ESTRUTURA: $falhas falha(s)"; exit 1; fi
