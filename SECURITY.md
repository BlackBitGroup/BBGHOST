# Política de Segurança — BBGHOST

## Reportar uma vulnerabilidade

**Não** abra issue pública para falhas de segurança. Reporte de forma
privada por **divulgação coordenada**:

- E-mail: `<security@blackbit… — preencher>`
- (Opcional) use o canal de *Security advisories* privado do GitHub.

Descreva a classe do problema e como reproduzir. Pedimos ~90 dias de
embargo antes de divulgação pública, para corrigir e liberar atualização.
Como o BBGHOST mexe em firewall/VPN/DNS, um bug pode causar **vazamento de
identidade** — tratamos isso com prioridade.

## Verifique a integridade do que você roda

O próprio projeto traz verificação de integridade:

```bash
opsec.sh verify        # confere o código contra o manifesto SHA-256
```

Releases oficiais trazem um manifesto **assinado com GPG**
(`.integrity/manifest.sha256.asc`). Confira a assinatura antes de confiar
num binário/clone que não veio do repositório oficial.

## Uso aceitável

O BBGHOST é uma ferramenta **defensiva de OPSEC do operador**: protege a
sua própria identidade/conexão contra vazamentos. Destina-se a:

- jornalistas, pesquisadores e defensores de direitos;
- times de segurança e **pentests/red teams autorizados**;
- qualquer pessoa protegendo a própria privacidade de forma legítima.

**Não** é destinado a atividade ilegal. Você é responsável por cumprir as
leis e os termos dos serviços (VPN, etc.) da sua jurisdição. Os autores
não se responsabilizam por uso indevido (ver isenção de garantia na
`LICENSE`, seções 15–16).

## Boas práticas de OPSEC ao usar

- Mantenha os `.conf` de VPN **fora** do controle de versão (já cobertos
  pelo `.gitignore`); eles contêm **chave privada**.
- Prefira `LOG_TO_RAM="true"` em cenários sensíveis.
- Revise os hooks de terceiros antes de colocá-los em `hooks/`.
