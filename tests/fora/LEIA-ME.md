# Fora da suíte: dois testes que affirms um contrato morto

Estes dois **são** testes de verdade — têm contador de falha e saem com `1` quando
algo falha. Eles não estão aqui porque estão **podres**, e a causa está documentada
no próprio `setup.sh`.

Ambos dirigem `setup_opencode_service` por `OPENCODE_BIND` e `OPENCODE_PORT`. E o
`setup.sh` diz, na linha 110, que essas variáveis **não existem** no opencode v2:

> Estes dois NÃO são variáveis de ambiente do opencode. Medido no binário de
> 203 MB: `OPENCODE_BIND` tem zero ocorrências, e `OPENCODE_PORT` também. […] São os
> valores que nós aplicamos com `opencode service set hostname|port`, que é o
> mecanismo real.

Ou seja: o código parou de aceitar uma entrada que o produto nunca teve, e estes
dois testes continuaram afirmando que ela funciona. Eles falham porque o código
está certo.

O que faria para trazê-los de volta: reescrever as asserções para o contrato
**atual** — escutar em `127.0.0.1` e publicar por `tailscale serve`, que é a
decisão registrada. Não foi feito aqui de propósito: reescrever uma asserção é
fácil demais para acabar virando "asserir o que o código faz", e essa é uma
coragem que precisa da decisão de quem dono do repo, não de quem só move arquivos.
