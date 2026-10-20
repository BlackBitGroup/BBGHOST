# Changelog

Todas as mudanças notáveis do BBGHOST são documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
e o projeto adota [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [Não lançado]

- Nada ainda.

## [1.0.0] — 2026-10-20

Primeira versão pública. OPSEC **fail-closed** para o operador, num
comando — proteção da própria identidade/conexão contra vazamentos.

### Adicionado

#### Núcleo (cadeia fail-closed)
- **Kill switch** fail-closed via nftables em **tabela isolada**
  (`bbghost_killswitch`), sem `flush ruleset` global — não destrói o
  firewall do host. Regra de handshake **fixada no IP:porta reais** do
  servidor da VPN.
- **VPN** WireGuard **ou** OpenVPN, com **qualquer provedor** (Mullvad,
  IVPN, ProtonVPN, Windscribe, AirVPN, WireGuard próprio…). Sanitização
  automática do `.conf` e confirmação de handshake antes de liberar a rede.
- **Anti-DNS-leak**: `resolv.conf` travado (imutável) no DNS do túnel.
- **Spoof** de MAC (OUI de vendor plausível) e hostname; **IPv6** desligado
  na sessão.
- **Tor** opcional via SOCKS5 + geração de `proxychains.conf` (`opsec.sh pc`).
- **Radar** em tempo real: saúde da cadeia, detecção de **ARP spoofing** e
  **modo promíscuo**, **dead man's switch** e **detector de leak** (compara
  o org/ASN do IP público com o esperado).
- **Panic**: corte de emergência imediato da interface física, sem restaurar
  a identidade real; variante `panic --burn` destrói (shred) os baselines.

#### Endurecimento de OPSEC
- Fim da duplicação da **chave privada** da VPN em disco.
- Logs sem valores reais (MAC/hostname/gateway) e opção `LOG_TO_RAM`
  (log em `/dev/shm`, some no desligamento).
- `.state/` em `chmod 700`; arquivos de log nascem `600`.
- **Silenciamento de LAN**: cala mDNS/Avahi, LLMNR e NetBIOS durante a sessão.
- Perfil Firefox endurecido (WebRTC off, `resistFingerprinting`, telemetria
  e geolocalização off).

#### Recursos avançados
- **Perfis de missão**: `opsec.sh profile {list|save|load|show|del}` —
  cada perfil guarda config + VPN (multi-provedor); troca tudo num comando.
- **Multi-hop (VPN sobre VPN)**: 2º túnel por dentro do 1º
  (`real → hop1 → hop2 → internet`).
- **Isolamento forte estilo Whonix**: app num network namespace cuja única
  saída é um Whonix-Gateway (`opsec.sh iso run …`).
- **Automação**: `opsec.sh autostart enable` (serviço systemd fail-closed no
  boot) + **hooks** (`hooks/on.d`, `hooks/off.d`).
- **Verificação de integridade**: `opsec.sh integrity sign` / `opsec.sh
  verify` — manifesto SHA-256 (+ assinatura GPG opcional), detecta
  adulteração e código novo fora do manifesto.

#### Interface
- **Modo shell** completo (`opsec.sh …`) e assistente de configuração
  (`opsec.sh setup`).
- **Modo gráfico**: interface **nativa própria** em Tkinter (estilo
  Opera GX), com status ao vivo, on/off/panic, **⚙ CONFIG** (rolável,
  edita tudo — inclusive enviar/colar `.conf`), **⬢ PERFIS**, **? AJUDA** e
  botão de **Navegador Tor** (perfil `bbghost-gx` roteado pelo Tor, anti-leak,
  tema Opera-GX).
- Lançadores `.desktop` para os dois modos.

#### Multiplataforma
- **Motor Windows** em PowerShell (`win/bbghost.ps1`): túnel WireGuard,
  kill switch via **Windows Firewall**, DNS travado, panic e status JSON. A
  mesma GUI detecta o SO e chama o motor certo.
  > ⚠ Escrito mas **não testado** em Windows pelo autor (dev é Linux);
  > sintaxe validada com `pwsh`. Valide numa VM Windows antes de confiar.

#### Projeto / licença
- Licenciamento **open-core dual**: [AGPLv3](LICENSE) + licença comercial
  ([`LICENSING.md`](LICENSING.md)).
- Governança: [`SECURITY.md`](SECURITY.md), [`CONTRIBUTING.md`](CONTRIBUTING.md)
  (com CLA) e `.gitignore` que impede commitar segredos/chaves de VPN.

### Notas de segurança
- O motor Windows, o isolamento Whonix (precisa da VM) e o multi-hop
  (precisa de 2 servidores reais) têm a lógica pronta, mas a validação
  ponta-a-ponta depende do seu ambiente. Tudo que é testável no Linux foi
  testado.

[Não lançado]: https://github.com/blackbit/bbghost/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/blackbit/bbghost/releases/tag/v1.0.0
