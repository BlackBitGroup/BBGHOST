# Hooks de automação do BBGHOST

Scripts `.sh` colocados aqui rodam automaticamente:
- `hooks/on.d/*.sh`  — ao final de `opsec.sh on`
- `hooks/off.d/*.sh` — no começo de `opsec.sh off`

A variável `$BBGHOST_PHASE` vale `on` ou `off`. Uma falha num hook
nunca derruba a sessão (é logada e ignorada).

Exemplos de uso: notificação (ntfy/telegram), montar/desmontar um
volume cifrado, iniciar/parar uma captura, logar em sistema externo.
