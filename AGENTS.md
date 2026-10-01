# AGENTS.md

Instruções para quem trabalha neste repositório — pessoa ou agente.

## A suíte de testes só roda em sandbox

```bash
./tests/run.sh
```

**O runner recusa com `exit 2` se a máquina não for descartável, e isso não é
um aviso.** Não rode a suíte no host de trabalho, e não tente contornar o guard
porque o primeiro teste parece inofensivo.

O motivo está medido: a suíte executa o `setup.sh` de verdade, e dois dos scripts
de teste fazem `systemctl --user stop` em serviços reais. Uma vez rodada no host,
ela derrubou a sessão — o `opencode.service` do próprio host. A suíte foi corrigida
para não incluir esses dois, mas a correção é uma lembrança, e lembrança não
sobrevive a um agente novo. O guard existe para que a próxima vez não dependa de
ninguém lembrar.

Se a override `FD_TESTS_UNSAFE=1` for necessária, é porque o alvo é uma VM
descartável. Nunca uma máquina de trabalho.

## Medir antes de deduzir

Os números deste repo valem porque foram medidos, e vários mudaram de valor no
meio do trabalho. Antes de afirmar qualquer coisa sobre o ambiente:

- **`ls` e `[ -f ]` não probam existência de arquivo sob diretório 700.** Foi assim
  que o hardening do `sshd` reescrevia a config e recarregava o serviço em toda
  execução, e o `else` "já aplicado" era código inalcançável.
- **o estado atual do host não é evidência sobre o padrão.** O hostname
  `fedora-desktop` foi escrito à mão; não diz nada sobre a regra de nomes.
- **um log sem o efeito ao lado não prova que algo rodou.** O relatório dizia
  "✓ sshd endurecido" e o arquivo, checado sem privilégio, não existia.
