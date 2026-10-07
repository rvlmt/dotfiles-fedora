# Fora da suíte: um teste que outro mede melhor

Este arquivo **é** um teste de verdade, e ele passa. Ele não está fora porque está
podre — está fora porque outro teste mede a mesma coisa **melhor**, e rodar os dois
custa um HTTP server e três pipes para ganhar uma medição a menos.

## O que ele mede

As três funções da montagem — `_anexos_necessarios`, `_baixar_anexo`,
`_se_colocar_no_disco_e_reexecutar` — extraídas do `setup.sh` e chamadas
direto. No fim ele confere que o destino tem **exatamente** três arquivos: o
`setup.sh` e os dois anexos que ele declara ler.

## Quem o substitui

`tests/lib/teste-pipe-defaults-completo.py` mede o **caminho completo**: o
`setup.sh` real, truncado logo após a montagem, entrando por `curl … | bash -s --
--profile=vm --defaults`, com o `if` que chama a montagem e o `exec` do re-exec
vivos. Ele também confere os três arquivos, e ainda faz duas coisas que este não
faz:

- **reintroduz o defeito** e exige que ele falhe — 0 ok, 4 falhas com o bug de
  volta, contra 5 ok com o código certo;
- monta **duas versões num run só** (dois servidores, o pipe buscando num e a
  montagem no outro) e exige que a montagem diga que são diferentes.

## Por que isso importa, e não é só custo

A montagem por pipe **não rodava com `--defaults`** — e este arquivo não pegou
nada disso. Ele extrai as funções e chama a montagem direto, então passa pelo
caminho que o autor escreveu e **não** pelo `if` que a chama. A função estava
perfeita; ninguém a chamava. O defeito custou três rodadas, e o que o pegou foi o
teste do caminho completo.

A lição está escrita no `docstring` do arquivo que ficou, e é o argumento para
preferir caminho a função:

> Um teste que extrai a função mede a função. Um teste que executa o caminho mede o
> caminho — e é o caminho que quebra.

## Como rodar, se precisar

```bash
python3 tests/fora/teste-montagem-pipe.py
```

Sai com `0` quando os três arquivos estão no destino, e com `1` caso contrário —
inclusive quando a lista divergir, quando houver lixo, ou quando não montar.
