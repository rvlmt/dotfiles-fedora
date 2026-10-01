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
  if grep -nE '\[ +!?-f +/etc/' setup.sh | grep -v 'sshd_config' | grep -q .; then
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
     | grep -q 'local/bin/gh'; then
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
  if grep -B12 'sudo tailscale up' <<<"$codigo" | grep -q 'ASSUME_DEFAULTS'; then
    ok "o 'tailscale up' e pulado sob --defaults"
  else
    falha "o 'tailscale up' roda sem guarda: trava o --defaults numa VM nova"
  fi
else
  falha "nao ha 'tailscale up' no script: a VM nunca entra na tailnet"
fi
if grep -q "sudo tailscale up'" <<<"$codigo" || grep -q 'rode .sudo tailscale up' <<<"$codigo"; then
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

echo "== o README tem o passo 0, e o comando dele tem sintaxe =="
# O `setup.sh` nao provisiona a VM: ele roda DENTRO de uma maquina que ja existe.
# Sem o passo 0 escrito, quem provisionar uma VM nova descobre a ordem errada
# depois de perder a VM — e a ordem nao e livre: o `git clone` usa SSH, e o SSH
# so existe depois do `tailscale up`.
r=$(cat "$REPO/README.md")
if grep -q '## Passo 0' <<<"$r"; then
  ok "o README documenta o passo 0 (provisionar a VM)"
else
  falha "o README nao tem o passo 0: a ordem de provisionamento fica por conta de quem le"
fi
# A ordem e o que importa: tailscale ANTES do clone, e o clone pela chave da VM.
t_up=$(grep -n 'sudo tailscale up' <<<"$r" | head -1 | cut -d: -f1)
t_clone=$(grep -n 'git clone git@github.com' <<<"$r" | head -1 | cut -d: -f1)
if [ -n "$t_up" ] && [ -n "$t_clone" ] && [ "$t_up" -lt "$t_clone" ]; then
  ok "e a ordem esta certa: tailscale up antes do clone (linhas $t_up e $t_clone)"
else
  falha "a ordem esta errada ou falta: o clone por SSH so funciona DEPOIS do tailscale up"
fi
if grep -q 'gh repo deploy-key add' <<<"$r"; then
  ok "e ele diz como autorizar a chave da VM no repo privado"
else
  falha "o passo 0 nao resolve como o repo privado e lido"
fi
# Nenhum segredo atravessa. A chave publica e inutil para quem roubar; o que
# NAO pode aparecer no README e um segredo de verdade.
if grep -qE 'ghp_[A-Za-z0-9]|-----BEGIN [A-Z ]*PRIVATE KEY' <<<"$r"; then
  falha "o README tem o que parece ser um segredo"
else
  ok "e nenhum segredo aparece no README: so chave publica, que nao abre nada"
fi
# O comando precisa ter SINTAXE valida, e isso se extrai do README e se checa de
# verdade. A primeira versao desta checagem aceitava o proprio fracasso como "ok"
# — um teste que nao pode falhar e pior que nenhum, e este era exatamente o caso
# que a §10.16 registrou.
#
# A extracao pega o corpo do `bash -c '...'` e roda `bash -n` nele: o shell le,
# nao executa. Um `read -r -p` no meio nao trava nada porque `-n` nao executa.
# A extracao pega o INTERIOR do `bash -c '...'`: as linhas de abertura e de
# fechamento sao o embrulho do markdown, nao o comando. A primeira versao pegava
# a abertura e descartava o fecho, e o `bash -n` falhava com "EOF inesperado
# procurando por ''" — o que e a falha CORRETA, sobre a extracao errada.
_tmp_m=$(mktemp)
sed -n "/^VM=</,/^'\$/p" "$REPO/README.md" | sed "1d; \$d" > "$_tmp_m"
if [ -s "$_tmp_m" ] && bash -n "$_tmp_m" 2>/dev/null; then
  ok "e o comando do passo 0 tem sintaxe valida ($(wc -l < "$_tmp_m") linhas extraidas)"
else
  falha "o comando do passo 0 do README nao tem sintaxe valida"
  bash -n "$_tmp_m" 2>&1 | head -3 | sed "s/^/        /"
fi
rm -f "$_tmp_m"

echo "== a auditoria do que um repo publico revelaria =="
# Publicar o repo e uma decisao legitima, e a razao de esta checagem existir e
# tornar essa decisao informada — e nao um `git remote set-url` seguido de um
# pedido de desculpas.
#
# O que ela mede e MATERIAL, e nao nomes: um bloco PEM so conta se tem CORPO, e
# token so conta se tem FORMATO. A primeira versao era um `grep` por "PRIVATE KEY"
# e acusou dois arquivos — as duas ocorrencias eram padroes de casamento, uma
# delas a propria checagem que procura segredo. Diagnostico no objeto errado.
if python3 "$LIB/auditoria-publica.py" > /tmp/fd-aud-publica.txt 2>&1; then
  n_med=$(sed -n 's/^Medindo \([0-9]*\) arquivo.*/\1/p' /tmp/fd-aud-publica.txt | head -1)
  if [ -n "$n_med" ] && [ "$n_med" -ge 1 ]; then
    ok "nenhum segredo em $n_med arquivo(s) versionado(s)"
  else
    falha "a auditoria nao mediu nenhum arquivo: 'nenhum segredo' seria mentira"
  fi
else
  falha "a auditoria do repo publico achou algo que nao pode sair"
  sed -n '2,8p' /tmp/fd-aud-publica.txt | sed 's/^/        /'
fi
rm -f /tmp/fd-aud-publica.txt

echo "== o bootstrap cobre TUDO que o setup.sh le do repo =="
# O `curl` do bootstrap e o caminho do provisionamento sem chave nenhuma, entao
# ele tem de trazer os arquivos de que o `setup.sh` depende — e a lista e
# EXTRAIDA do proprio setup.sh, nao escrita a mao. Uma lista escrita a mao e uma
# lista que desatualiza em silencio quando o setup.sh ganha uma dependencia nova.
if [ -f "$REPO/bootstrap.sh" ]; then
  deps=$(grep -oE '\$SCRIPT_DIR/[a-zA-Z0-9/._-]+' "$REPO/setup.sh" | sort -u)
  n_dep=$(printf '%s\n' "$deps" | grep -c . || true)
  n_ok=0
  for d in $deps; do
    rel="${d#\$SCRIPT_DIR/}"
    if grep -qF "buscar \"$rel\"" "$REPO/bootstrap.sh"; then
      n_ok=$((n_ok + 1))
    else
      falha "o setup.sh le $rel e o bootstrap nao traz"
    fi
  done
  if [ "$n_ok" -eq "$n_dep" ]; then
    ok "o bootstrap traz as $n_dep dependencia(s) que o setup.sh le do repo"
  fi
  if grep -qF 'buscar "setup.sh"' "$REPO/bootstrap.sh"; then
    ok "e traz o proprio setup.sh"
  else
    falha "o bootstrap nao traz o setup.sh"
  fi
  # Um `curl` que devolve uma PAGINA de erro com 200 nao falha: o script receberia
  # receberia HTML e nao distinguiria de um script. A checagem existe, e precisa.
  if grep -qE 'DOCTYPE html|<html' "$REPO/bootstrap.sh"; then
    ok "e rejeita uma pagina HTML, que o curl -f nao pega"
  else
    falha "o bootstrap nao rejeita pagina de erro: o setup.sh rodaria um HTML"
  fi
  # Um `curl` que falha tem que PARAR, nao seguir para o setup.sh — que
  # falharia por um arquivo que nao chegou, com uma mensagem que aponta para o
  # sintoma e nao para a causa.
  if grep -A4 '^buscar() {' "$REPO/bootstrap.sh" | grep -q 'exit 1'; then
    ok "e um download que falha para o bootstrap, em vez de seguir"
  else
    falha "um download que falha nao para o bootstrap"
  fi
else
  falha "nao existe bootstrap.sh, e o README aponta para ele"
fi

echo "== sintaxe =="
if bash -n setup.sh 2>/dev/null; then ok "bash -n limpo"; else falha "bash -n"; fi

echo "== nenhum caractere CJK em nenhum arquivo =="
if python3 "$LIB/cjk-scan.py" | grep -q nenhum; then ok "sem CJK"
else falha "CJK encontrado"; fi

echo
if [ "$falhas" -eq 0 ]; then echo "ESTRUTURA: todas as checagens ok"
else echo "ESTRUTURA: $falhas falha(s)"; exit 1; fi
