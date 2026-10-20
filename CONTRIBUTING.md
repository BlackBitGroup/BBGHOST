# Contribuindo com o BBGHOST

Obrigado pelo interesse! Algumas regras curtas.

## Licença das contribuições (CLA)

O BBGHOST usa **licenciamento duplo** (AGPLv3 + comercial). Para que a via
comercial continue possível, ao enviar um Pull Request você concorda com o
**Contributor License Agreement**: você garante que é autor do código e
concede à **Black Bit** o direito de distribuí-lo tanto sob a AGPLv3 quanto
sob a licença comercial.

Na prática, inclua esta linha no PR (ou no commit):

> I agree to the BBGHOST CLA: I grant Black Bit the right to license my
> contribution under both the AGPLv3 and a commercial license.

## Como contribuir

1. Abra uma issue descrevendo o problema/ideia antes de um PR grande.
2. Mantenha o estilo do código vizinho (bash: `set -euo pipefail` onde faz
   sentido; Python: stdlib, sem dependências externas na GUI).
3. **Nunca** inclua segredos, `.conf` de VPN, logs ou estado de runtime.
4. Antes de abrir o PR:
   ```bash
   bash -n opsec.sh modules/*.sh          # sintaxe shell
   python3 -c "import ast,sys; ast.parse(open('gui/bbghost_gui.py').read())"
   opsec.sh integrity sign                # regenere o manifesto se mudou código
   ```
5. Descreva o que testou (e em qual SO). O motor Windows (`win/*.ps1`)
   precisa de validação em Windows real.

## Segurança

Falhas de segurança **não** vão em issue pública — veja [`SECURITY.md`](SECURITY.md).
