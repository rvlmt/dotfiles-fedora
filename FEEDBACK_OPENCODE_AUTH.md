# Post-Mortem & Feedback: Configuração do Serviço OpenCode e Autenticação

**Data:** 26 de Setembro de 2026  
**Componente:** `opencode.service` / `setup_opencode_service` em `setup.sh`  
**Commit relacionado:** `ebf14c3` (*feat(ai-clis): make the standard the owner of the opencode service (#8)*)

---

## 1. Contexto do Problema

O agente responsável pela automação de host no repositório `dotfiles-fedora` buscou configurar o serviço do OpenCode para:
1. Escutar apenas em loopback (`127.0.0.1:49374`).
2. Ser publicado de forma segura na Tailnet via `tailscale serve` com HTTPS na porta `8443`.
3. "Remover" a exigência de senha HTTP Basic Auth, sob a premissa de que a segurança de acesso já estaria garantida pela filiação à Tailnet (*tailnet membership boundary*).

Para tentar atingir o objetivo (3), o agente implementou no drop-in `~/.config/systemd/user/opencode.service.d/10-bind.conf`:
- A remoção intencional da flag `--service` do comando `opencode serve`.
- A inclusão da diretiva `UnsetEnvironment=OPENCODE_SERVER_PASSWORD`.

O rationale documentado pelo agente no `setup.sh` e `README.md` foi:
> *"Diferente das demais flags, aqui o padrão declara o comando INTEIRO em vez de preservar o do instalador, porque é preciso remover `--service`: é essa flag que faz o wrapper gerar uma senha aleatória e injetar OPENCODE_SERVER_PASSWORD, o que liga basic auth em /api/*. Sem `--service`: sem senha."*

---

## 2. A Realidade Técnica do OpenCode v2

A premissa adotada pelo agente sobre a flag `--service` estava **invertida**.

Ao inspecionar diretamente a lógica de inicialização no binário do OpenCode v2 (`~/.opencode/bin/opencode`), constata-se:

```javascript
let a = e.mode === "service" 
    ? i.password || U(32).toString("base64url") 
    : v ? Xu(v) : U(32).toString("base64url");

if (!a) return yield* D(Error("Missing server password"));
```

### O que isso significa:
1. **O OpenCode v2 NUNCA roda sem senha:** A autenticação é obrigatória e estrutural no servidor (`Missing server password`).
2. **Modo `--service` (com a flag):** O servidor lê a configuração persistida em `~/.config/opencode/service.json` (`i.password`). A senha é **estável**, sobrevive a restarts, é gerenciável via `opencode service set password <valor>` e é exibida no QR Code / link gerado por `opencode pair`.
3. **Modo padrão (sem `--service`):** O servidor consulta a variável de ambiente `OPENCODE_SERVER_PASSWORD` (`v`). Se a variável estiver ausente ou desfeita com `UnsetEnvironment`, o servidor executa `U(32).toString("base64url")` e **gera uma nova senha aleatória efêmera a cada execução**, logando-a no `stdout`/`journalctl`:
   ```
   server password <token_aleatorio_de_32_bytes>
   ```

---

## 3. Consequências para o Usuário

1. **Bloqueio Total de Acesso (Lockout):**
   Ao reiniciar o serviço após o script do agente, o OpenCode não ficou sem senha. Pelo contrário: ele gerou uma senha aleatória (`5FxwCuVL...`) e descartou a senha estável anterior do usuário (`pv1hHGXuzV...`).
2. **Inutilização de Credenciais Salvas:**
   A senha antiga do usuário e os tokens salvos no `localStorage` do navegador pararam de funcionar imediatamente com erro `HTTP 401 Unauthorized`.
3. **Instabilidade Contínua:**
   A cada reboot do sistema operacional ou reinicialização do `opencode.service`, uma nova senha temporária era gerada em memória, forçando o usuário a caçar a credencial dentro de `journalctl --user -u opencode`.
4. **Falsa Confiança em Testes Unitários:**
   O agente escreveu um script de teste (`.unit-test.sh`) que verificava com sucesso se `--service` havia sido removido e se `UnsetEnvironment` estava no arquivo gerado. O teste passou com louvor porque testava apenas a presença da string errada, sem validar o efeito no runtime real do binário.

---

## 4. Recomendações e Correções Necessárias

### No Host (Já aplicado):
O drop-in `~/.config/systemd/user/opencode.service.d/10-bind.conf` foi corrigido para:
```ini
[Service]
ExecStart=
ExecStart=/home/rvlmt/.opencode/bin/opencode serve --service --hostname 127.0.0.1 --port 49374
```

### No Repositório `dotfiles-fedora`:
1. **Em `setup.sh` (`setup_opencode_service`):**
   - Restaurar `--service` no `ExecStart`.
   - Remover `UnsetEnvironment=OPENCODE_SERVER_PASSWORD`.
   - Documentar que a senha do OpenCode é administrada em `~/.config/opencode/service.json`.
2. **Em `README.md`:**
   - Corrigir a seção que afirma que o OpenCode roda sem autenticação na tailnet. O acesso na tailnet continua protegido pela senha fixa pareada via link `https://<host>.<tailnet>.ts.net:<port>/connect#<token>`.
3. **Lição de Engenharia para Agentes:**
   - Nunca assuma que remover uma flag desativa um mecanismo de segurança sem testar o binário em runtime (`curl -i http://localhost:<port>/api/info`).
   - Um teste de configuração que só valida expressões regulares no texto gerado não substitui o teste funcional da aplicação integrada.
