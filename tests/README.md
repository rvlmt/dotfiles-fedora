# tests/

Suíte do `setup.sh`. Rodar com `./tests/run.sh`, a partir da raiz do repositório.

Os testes rodam o `setup.sh` **de verdade**, com `sudo`, `dnf`, `podman`,
`systemctl`, `tailscale` e `gh` falsos no `PATH` e um `HOME` temporário. Nada
toca a máquina. Os que abrem pty usam `lib/ptyfile2.py`, porque `read -rp` só
imprime quando o stdin é terminal — sem pty, o script não faz uma pergunta e o
teste passa por um motivo errado.

## O que está aqui

| arquivo | o que verifica | custo |
|---|---|---|
| `profile-axis-test.sh` | a matriz de perfis, `--only`, `--skip`, `--yes`, e o texto do `--help` | ~4 min, abre pty |
| `structure-test.sh` | o script e os documentos concordam entre si: listas de pacotes, o hardening decidido por propriedade, ausência de CJK | segundos |
| `test-device-keys.sh` | `sync_device_keys_from_github` contra um feed falso, com chaves reais | segundos |

`lib/ptyfile2.py` e `lib/cjk-scan.py` são auxiliares, e vivem em `lib/` para que
`profile-axis-test.sh` e `structure-test.sh` não tenham caminho hardcoded — o
primeiro deles apontava para `/tmp/opencode/ptyfile2.py`, o que funciona nesta
máquina e em nenhuma outra.

## O que NÃO está aqui, e por quê

Isto importa mais do que a lista de cima.

**Quatro scripts que pareciam testes ficaram de fora**, e os motivos são
diferentes uns dos outros:

- **Não podem falhar.** `test-opencode-guard.sh`, `testa-yes.sh` e
  `test-unit-start.sh` imprimem observações e saem com `0` sempre — nenhum tem
  contador de falha nem `exit 1`. Um membro de suíte que não pode falhar é
  decoração: pior que nenhum, porque ocupa a posição de algo que protege.
- **Não podem falhar *e* mexem na máquina.** `test-unit-start.sh` roda
  `systemctl --user stop opencode.service` e `testa-boot.sh` roda
  `systemctl --user stop hermes-dashboard.service`, **sem stub nenhum**, numa
  máquina que pode ter o serviço no ar. Num host onde o `opencode.service` está
  ativo — que é o caso de uma workstation provisionada por este repo — o primeiro
  desses para o serviço do qual uma sessão de agente depende. Foi o que derrubou
  esta máquina três vezes enquanto a suíte era montada.

**Um quinto grupo, em `tests/fora/`.** `test-own-opencode.sh` e `test-serve.sh`
são testes de verdade — contam falhas e saem com `1` — e mesmo assim ficaram de fora:
eles dirigem `setup_opencode_service` por `OPENCODE_BIND` e `OPENCODE_PORT`, e o
`setup.sh` diz na linha 110 que essas variáveis **não existem** no opencode v2, com
a medição do binário de 203 MB ao lado. O código abandonou uma entrada que o
produto nunca teve, por decisão, e esses testes continuam afirmando que ela
funciona. Eles falham porque o código está certo. Ver `tests/fora/LEIA-ME.md`.

O segundo item é a razão de o `run.sh` não ter um interruptor para "rodar tudo":
não há um "tudo" seguro para rodar.

Se alguém quiser trazer `testa-boot.sh` de volta, ele é um **teste de
integração** — a prova de que a unit sobe sozinha depois de um `stop` exige um
sessão de usuário real de verdade, e não se faz com stub. Ele precisa de um
guard que recuse rodar sem uma confirmação explícita, e de um alvo que não seja o
serviço de uma sessão viva.

## Por que `run.sh` não interpreta a saída

Ele chama cada teste, guarda o status de saída e imprime. Não tenta adivinhar o que
um teste quis dizer, nem transforma texto em veredito. Um runner que "entende" os
testes é um runner que passa verde quando eles não deveriam — e foi exatamente isso
que aconteceu com estes quatro scripts quando entraram na suíte sem terem sido
verificados um a um.
