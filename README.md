# BBGHOST — OPSEC Toggle

[![CI](https://github.com/blackbit/bbghost/actions/workflows/ci.yml/badge.svg)](https://github.com/blackbit/bbghost/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPLv3-blue.svg)](LICENSE)

> **Feito pela Black Bit** · Made by Black Bit · Сделано Black Bit · 由 Black Bit 制作

Sistema de ativação/desativação de camadas de OPSEC para Kali Linux, com
painel de monitoramento em tempo real. Filosofia: **fail-closed** — se
algo não confirma que subiu, a rede continua travada, nunca vaza.

## Pré-requisitos

```bash
sudo apt install wireguard macchanger nftables curl iproute2 tcpdump firefox-esr python3-tk
```

`tcpdump` e `lsattr`/`comm` (geralmente já vêm no Kali) são opcionais —
sem eles o `radar` e o `selftest` perdem algumas checagens, mas o
`on`/`off`/`status` funcionam de qualquer forma.

**Importante:** este projeto assume `/etc/wireguard/` e `/opt/bbghost`
como local de instalação. Se você instalar em uma partição **NTFS**
(pendrive, HD compartilhado com Windows), os scripts vão rodar mesmo
sem bit de execução (o `opsec.sh` é sempre chamado via `bash opsec.sh`,
nunca `./opsec.sh`), mas o ideal é instalar direto em `/opt/bbghost`
— também protege melhor a chave privada da VPN, que fica dentro do
`.conf`.

## Setup inicial (ProtonVPN)

1. No painel da Proton (`account.protonvpn.com` → Downloads →
   WireGuard configuration), gere um config:
   - Escolha um servidor
   - Ative **NetShield** se seu plano permitir (no Free só aparece
     VPN Accelerator, sem problema)
   - Baixe o `.conf`

2. Instale o projeto e copie o config:
   ```bash
   sudo mkdir -p /opt/bbghost
   sudo cp -r . /opt/bbghost/          # rodando de dentro da pasta extraída
   sudo cp seu-arquivo.conf /etc/wireguard/wg0.conf
   sudo chmod 600 /etc/wireguard/wg0.conf
   sudo chmod +x /opt/bbghost/opsec.sh /opt/bbghost/modules/*.sh
   ```

   **Não precisa editar o `.conf` manualmente** — o `vpn.sh` remove
   sozinho a diretiva `DNS =` (pra nunca depender do `resolvconf`, que
   se mostrou frágil em teste real) e remove endereços IPv6 se o
   sistema estiver com IPv6 desabilitado. Ele guarda uma cópia
   intocada do seu `.conf` original em `.state/wg-wg0-original.conf`
   antes de mexer, então nada é perdido.

3. Edite `config.env`:
   - `IFACE` → confira com `ip route | grep default` (pega a interface
     com **menor metric**, é a rota prioritária de verdade — não
     confie só em qual interface "parece" ativa)
   - `WG_INTERFACE` → deixa `wg0` se seguiu o passo 2
   - `SECURE_DNS` → confirma que bate com o `DNS =` do seu `.conf`
     original (antes da sanitização), normalmente `10.2.0.1`
   - `EXPECTED_LISTEN_PORTS` → portas que você espera ver escutando
     localmente (ex: `22` pra SSH). O `radar` avisa se aparecer
     alguma porta nova fora dessa lista.

4. Ative:
   ```bash
   cd /opt/bbghost
   sudo bash opsec.sh on
   sudo bash opsec.sh status
   ```

## Comandos

```bash
sudo bash opsec.sh on         # ativa tudo
sudo bash opsec.sh off        # desativa e restaura tudo
sudo bash opsec.sh status     # resumo rápido
sudo bash opsec.sh radar      # painel de monitoramento em tempo real
sudo bash opsec.sh selftest   # valida a cadeia inteira, testando o kill switch de verdade
sudo bash opsec.sh panic      # corte de emergência manual
     bash opsec.sh pc <cmd>   # roda um comando via proxychains+Tor (SEM sudo)
```

## O painel `radar`

Mostra, atualizando a cada 5s (ajustável: `sudo bash opsec.sh radar 10`):

- **Cadeia de saltos** — desenho simples de você → MAC/hostname
  spoofed → kill switch → WireGuard → (Tor, se ativo) → internet
- **Integridade**: kill switch de pé, handshake da VPN recente, DNS
  apontando pro túnel e travado (imutável)
- **Sinais de observação**:
  - **ARP do gateway mudou** → possível ARP spoofing / MITM na rede
    local (alguém se passando pelo roteador)
  - **Interface em modo promíscuo** → algo pode estar capturando todo
    o tráfego (sniffer ativo que não foi você)
  - **Porta nova escutando** que não estava no baseline → possível
    backdoor ou serviço que subiu sem você saber
- **IP público** — checado só a cada N ciclos (`RADAR_EXTERNAL_CHECK_EVERY`
  no config), de propósito: ficar martelando uma API de geolocalização
  o tempo todo seria, ironicamente, um padrão de tráfego característico.

### Reação automática (`RADAR_AUTO_REACT`)

Com `RADAR_AUTO_REACT="true"` (padrão), **ARP spoofing confirmado** ou
**modo promíscuo detectado** não geram só um aviso — o radar aciona o
`panic.sh` sozinho, na hora, sem esperar você ler a tela. Porta nova
escutando **não** aciona reação automática de propósito (é o sinal com
mais chance de falso positivo — muito app legítimo abre porta nova).

Se estiver testando numa rede instável onde o gateway muda de MAC por
motivo legítimo com frequência (ex: roteador com failover), desative
com `RADAR_AUTO_REACT="false"` pra não tomar panic falso toda hora.

### Dead man's switch (`DEADMAN_ENABLED`)

Desligado por padrão — é opt-in porque muda o comportamento real do
radar. Quando `DEADMAN_ENABLED="true"`, o radar espera algum toque de
tecla seu a cada ciclo como "check-in de presença". Se passar mais que
`DEADMAN_TIMEOUT_SEC` (padrão 900s = 15min) sem nenhuma tecla, aciona
o `panic.sh` sozinho.

Pensado pro cenário de você ser afastado da máquina no meio de uma
sessão ativa (fisicamente detido, dispositivo apreendido, etc.) — o
próprio painel mostra uma contagem regressiva, ficando amarelo nos
últimos 3 minutos e vermelho no último minuto.

**Cuidado**: se você deixar o radar rodando e for dormir, ele vai
disparar panic sozinho. É o comportamento esperado, não um bug — mas
ajuste `DEADMAN_TIMEOUT_SEC` pra algo compatível com o que você
realmente vai fazer (não deixa em 900s se pretende ficar 20min longe
do teclado de propósito).

## `panic` — corte de emergência

Diferente do `off` normal, o `panic` **não restaura sua identidade
real**. A lógica: se você está no meio de um incidente (ARP spoofing
detectado, dead man's switch disparado), reverter pro MAC/hostname
reais nesse momento seria revelar quem você é bem na hora que mais
importa esconder. Ele só:

1. Derruba a interface física por completo (`ip link down`) — mais
   forte que só o kill switch, corta de vez, não só filtra
2. Derruba a VPN e o Tor
3. Loga o motivo com timestamp
4. **Não mexe em MAC/hostname** — ficam como estavam

Depois de um panic, você decide os próximos passos manualmente:
reconectar pra investigar (`sudo ip link set eth0 up`), ou, só depois
de confirmar que está seguro, `sudo bash opsec.sh off` pra voltar de
vez ao normal.

Pode ser acionado manualmente a qualquer momento: `sudo bash opsec.sh panic "motivo"`.

## `pc` — rodando comandos pelo Tor via proxychains

**Esse é o único caminho suportado pra rotear algo pelo Tor** — não
existe redirecionamento automático de todo o sistema (ver seção
"Tor via SOCKS" acima pra entender por quê: a versão que tentava isso
foi removida depois de travar consistentemente em teste ao vivo).

```bash
bash opsec.sh pc curl https://check.torproject.org/api/ip
bash opsec.sh pc nmap -sT alvo.com
```

Não precisa de `sudo` — é só um wrapper de usuário normal em cima do
SOCKS5 do Tor (porta `TOR_SOCKS_PORT`, padrão 9050). A config gerada
(`.state/proxychains.conf`, recriada a cada `on`) usa:

- `strict_chain` — se o proxy cair, a conexão **falha**, nunca sai
  silenciosamente sem proxy (mesmo princípio fail-closed do resto do
  projeto; `dynamic_chain` faria fallback silencioso, que é
  exatamente o que você não quer numa ferramenta de OPSEC)
- `proxy_dns` — força resolução de nome pelo proxy também, evita DNS
  leak específico de ferramentas wrapped

Vale notar a limitação inerente do próprio proxychains (não é algo
que o BBGHOST pode contornar): funciona via `LD_PRELOAD`, então não
pega binários linkados estaticamente nem sockets raw. Pra a grande
maioria das ferramentas de linha de comando (curl, nmap, etc.) isso
não é problema.

Baselines (MAC do gateway, portas esperadas) são salvos na primeira
execução em `.state/`. Se você trocar de rede de propósito (ex: for
pra outro lugar), apague `.state/gateway_mac_baseline` pra o radar não
acusar falso positivo.

## O `selftest`

Automatiza o checklist manual que normalmente você faria à mão: confere
IP público, DNS, kill switch, MAC — e faz um teste real, **derrubando
a VPN por alguns segundos** e tentando sair sem ela. Se aparecer
"FALHOU (esperado!)" nesse teste específico, é uma boa notícia: quer
dizer que o kill switch segurou de verdade.

## Isolamento do ProtonMail

O módulo `identity.sh` cria um perfil de Firefox **separado**
(`bbghost-proton`), com cookies/histórico/cache isolados da sessão de
trabalho normal:

```bash
firefox -P bbghost-proton --no-remote
```

Considere também:
- 2FA com chave física (Yubikey), nunca SMS
- Nunca abrir o Proton pelo profile "normal" do Firefox
- Acessar o Proton só com BBGHOST ativo, nunca em rede "crua"

## Bugs que já caçamos e corrigimos (documentado pra não repetir)

Isso aqui é histórico de depuração real, deixado de propósito — se
algo parecido acontecer de novo (ex: você editar um módulo na mão),
é bom saber o que já mordeu antes:

1. **SIGPIPE sob `pipefail`**: qualquer pipe onde o comando da direita
   fecha cedo (`head -c8`, `grep -q`) manda SIGPIPE pro comando da
   esquerda, que conta como falha sob `set -o pipefail` — e o script
   morre **em silêncio total**, sem imprimir nada. Afetou a geração do
   hostname aleatório e a checagem do kill switch no `status`. Corrigido
   evitando pipes assim (bash puro pro hostname, `nft list table` direto
   em vez de `nft list ruleset | grep` pro status).
2. **`BBGHOST_HOME` hardcoded no `config.env`**: sobrescrevia o valor
   correto calculado pelo `opsec.sh`. Corrigido removendo a redeclaração.
3. **Variável não exportada entre processos**: os módulos rodam como
   processos `bash` separados e não herdam variáveis do processo pai
   a menos que sejam exportadas. Corrigido com `export BBGHOST_HOME`.
4. **`oif` vs `oifname` no nftables**: `oif` resolve pelo ÍNDICE da
   interface, exigindo que ela já exista no momento em que a regra
   carrega — quebra porque o kill switch sobe antes da VPN.
   `oifname` casa pelo nome, funciona mesmo antes da interface existir.
5. **Sem rollback automático**: se a VPN falhasse no meio da ativação,
   o kill switch ficava de pé sem VPN nenhuma, travando a internet de
   verdade. Corrigido com `trap ... ERR` que desfaz tudo automaticamente.
6. **`resolvconf` frágil**: o `wg-quick` chama `resolvconf` automaticamente
   quando existe uma linha `DNS =` no `.conf`, e esse comando se mostrou
   propenso a erros ("signature mismatch") em ambientes onde o
   `/etc/resolv.conf` foi editado por fora. Corrigido removendo a
   diretiva `DNS =` do `.conf` automaticamente — DNS é gerenciado 100%
   pelo `dns.sh`, sem depender do `resolvconf`.
7. **IPv6 causando falha no `wg-quick`**: se o sistema tem IPv6
   desabilitado mas o `.conf` tem endereço IPv6, o `wg-quick` falha com
   "IPv6 is disabled on this device" e desfaz tudo. Corrigido removendo
   automaticamente endereços IPv6 do `.conf` quando detecta IPv6
   desabilitado no sistema.
8. **Handshake demorando mais que o esperado**: servidores free-tier
   podem demorar mais que 2 segundos pra confirmar. Corrigido com
   espera de até 24s, checando a cada 2s, em vez de uma checagem única.
9. **Baseline de hostname/MAC sobrescrita em ciclos de falha
   consecutivos**: se o `network.sh on` rodasse de novo antes do
   anterior restaurar direito, salvava o hostname *fake* como se fosse
   o "real", perdendo o valor original permanentemente. Corrigido: só
   salva o baseline se ainda não existir um.
10. **Alerta falso de handshake "velho"**: o radar acusava qualquer
    handshake com "minute" na descrição, mas o WireGuard renegocia a
    chave a cada ~2 minutos por padrão — isso disparava alerta em
    situação 100% normal. Corrigido: só alerta de verdade acima de 3
    minutos (com margem sobre o ciclo normal de 2min).
11. **`tor.sh` original só subia o daemon, sem rotear nada por ele**:
    tinha "Tor ativo" mas nenhum tráfego de fato passava por ele —
    falsa sensação de segunda camada. Tentativa de correção nº1: um
    redirecionamento transparente via `nftables` (ver item 12 —
    essa correção em si tinha um bug sério e foi revertida).
12. **Tentativa de redirecionamento transparente travava toda
    conexão em timeout**: o roteamento próprio que o WireGuard cria
    (`ip rule` + tabela de rota por fwmark) colidia com o NAT redirect
    do `nftables`, e o WireGuard sempre vencia — o pacote saía direto
    pro destino real, nunca era desviado pro Tor. Confirmado via
    `ss -tnp` capturando o estado real da conexão no meio do travamento.
    Solução: removido de vez o redirecionamento automático; `tor.sh`
    agora só sobe o daemon com SOCKS5, e o `pc` (proxychains) é o único
    caminho suportado pra rotear algo pelo Tor. Testado e confirmado
    funcionando via SOCKS direto antes dessa decisão (detalhes na
    seção "Tor via SOCKS" abaixo).
13. **UID errado na tentativa de exceção do redirecionamento** (bug
    dentro da tentativa nº12, encontrado antes dela ser abandonada):
    o Tor sobe como root por padrão (quem chama o processo), não como
    `debian-tor` — usar o UID de `debian-tor` numa regra de exceção
    fazia o próprio tráfego do Tor entrar em loop consigo mesmo.
    Corrigido descobrindo o UID real via `ps` na hora, em vez de
    assumir por nome — mantido no código mesmo após a reversão do
    item 12, porque a lição (nunca assumir UID por nome de usuário)
    vale pra qualquer uso futuro de exceção por UID.
14. **`DataDirectory`/`Log` do Tor dentro da pasta do projeto
    falhavam com "Permission denied" mesmo como root**: o perfil
    AppArmor que o pacote `tor` do Kali/Debian instala restringe quais
    caminhos o binário pode abrir, liberando só padrões parecidos com
    `/var/lib/tor/**` — bloqueando qualquer coisa dentro da home do
    usuário, independente de permissão Unix normal. Corrigido movendo
    os dois pra um caminho de sistema fixo (`/var/lib/bbghost-tor`),
    criado com dono e permissão corretos desde o início.
15. **`/etc/tor/torrc` do sistema conflitando com config alheia**: se
    você já usa Tor pra outra coisa na máquina (ex: hidden service de
    outro projeto), carregar o `/etc/tor/torrc` do sistema como config
    trazia junto diretivas totalmente alheias ao BBGHOST, travando a
    validação antes do Tor conseguir subir. Corrigido: o BBGHOST usa
    SOMENTE seu próprio overlay de config, nunca toca no torrc do
    sistema.

## Tor via SOCKS (`pc`) — não é automático, e o motivo importa

Com `USE_TOR="true"` no `config.env` (ativado por padrão neste
pacote), depois que a VPN confirma, o `tor.sh` sobe um daemon Tor
próprio (config isolada, não mexe no `torrc` do sistema nem em
`/var/lib/tor`) e disponibiliza um SOCKS5 em `127.0.0.1:9050`. Pra
rotear qualquer comando por ele:

```bash
sudo bash opsec.sh pc curl https://check.torproject.org/api/ip
sudo bash opsec.sh pc nmap -sT alvo.com
```

**Isso NÃO acontece automaticamente pra todo o sistema** — e essa
não foi a intenção original. A primeira versão desse módulo tentava
exatamente isso: redirecionamento transparente de **todo** o tráfego
TCP via uma regra `nftables` (NAT REDIRECT), sem precisar prefixar
comando nenhum. Parecia funcionar — o Tor bootava, o daemon ficava de
pé, o radar mostrava tudo verde — mas testado ao vivo, **toda conexão
travava em timeout puro**, sem exceção.

Diagnóstico completo (via `ss -tnp` capturando o estado da conexão
no meio do timeout): o roteamento próprio que o WireGuard cria
sozinho (regras de `ip rule` + tabela de rota customizada baseada em
fwmark) decide a rota e o endereço de origem **antes** do redirect do
`nftables` conseguir agir. As duas camadas de roteamento customizado
colidem — o WireGuard vence, e o pacote sai direto pro destino real
em vez de ser desviado pro Tor. Confirmado comparando lado a lado: a
mesma requisição via SOCKS5 direto (`curl --socks5-hostname
127.0.0.1:9050 ...`) completava em segundos com resposta 200; a
mesma requisição via redirecionamento transparente travava
indefinidamente, sempre.

Essa é uma combinação genuinamente frágil de Linux (VPN com
roteamento por fwmark + NAT redirect no hook output), não um erro de
digitação — por isso a decisão foi remover o redirecionamento
automático de vez, em vez de deixar uma funcionalidade que aparenta
funcionar (radar verde, daemon de pé) mas trava silenciosamente na
hora H. O `pc` via SOCKS foi testado e confirmado funcionando
repetidas vezes ao vivo antes dessa decisão.

Se o Tor não conseguir bootar em 20s, `tor_on()` desiste da camada
extra e avisa — mas **não derruba a VPN**, você continua protegido só
com a primeira camada.

O `radar` mostra se o daemon Tor está de pé e disponível via SOCKS,
sem prometer roteamento automático que não existe mais.

## O que NÃO está incluído (de propósito)

- Isso não te torna anônimo contra adversário estatal/forense sério.
- Não substitui compartimentação de identidade real (hardware, contas
  e horários de atividade separados por operação).
- Limpeza de `/var/log` fica comentada de propósito no `cleanup.sh` —
  também apaga sua própria trilha de auditoria.

## Estrutura

```
bbghost/
├── opsec.sh                  # dispatcher: setup/on/off/status/radar/gui/profile/iso/autostart/verify/...
├── config.env                # toda configuração fica aqui
├── modules/
│   ├── _lib.sh               # helpers compartilhados (edição segura do config + chaves de perfil)
│   ├── network.sh            # MAC, hostname, kill switch (tabela isolada + endpoint pin + multi-hop), IPv6 off
│   ├── lan-silence.sh        # cala mDNS/LLMNR/NetBIOS na LAN durante a sessão
│   ├── vpn.sh                 # WireGuard/OpenVPN (qualquer provedor) + multi-hop + retry de handshake
│   ├── tor.sh                 # Tor via SOCKS5 + geração do proxychains.conf
│   ├── dns.sh                 # trava resolv.conf, evita DNS leak
│   ├── identity.sh             # timezone spoof + profile Firefox isolado + workspace efêmero
│   ├── cleanup.sh             # limpeza de rastros ao desligar
│   ├── radar.sh               # painel em tempo real (shell) + reação automática + dead man's switch
│   ├── setup.sh               # assistente de configuração (instala VPN .conf + toggles)
│   ├── profiles.sh           # perfis de missão (multi-provedor): save/load/list/del
│   ├── isolation.sh          # isolamento forte estilo Whonix (netns → gateway)
│   ├── autostart.sh          # fail-closed no boot (serviço systemd)
│   ├── integrity.sh          # manifesto SHA-256 + verificação de adulteração
│   ├── gui.sh                 # MODO GRÁFICO: prepara perfil Tor + abre a GUI nativa
│   └── panic.sh               # corte de emergência (não restaura identidade real)
├── gui/                        # modo gráfico (interface nativa Tkinter, multiplataforma)
│   ├── bbghost_gui.py         # app Tkinter (Opera-GX): status + on/off/panic + config + perfis + ajuda
│   └── userChrome.css         # tema do chrome do Firefox (perfil bbghost-gx)
├── win/                        # motor Windows
│   └── bbghost.ps1            # PowerShell: VPN + kill switch (Windows Firewall) + status JSON
├── hooks/                      # automação: on.d/*.sh e off.d/*.sh (seus scripts)
├── profiles/                   # perfis de missão salvos (criado em runtime)
├── bbghost-toggle.desktop     # launcher do modo shell (liga/desliga direto)
├── bbghost-gui.desktop        # launcher do modo gráfico
├── .integrity/                 # manifesto de integridade (criado por 'integrity sign')
├── .state/                    # baselines, proxychains.conf, torrc overlay — criado em runtime
├── status.lock                # existe = ON, não existe = OFF
└── opsec.log                  # log LOCAL, nunca sai da máquina
```

---

## Dois modos: shell e gráfico

O BBGHOST tem **duas interfaces para a mesma engine** (os módulos são
os mesmos — o modo gráfico não é um fork, é outra casca):

### Configuração (nova)
Antes do primeiro uso, configure a VPN e os toggles — por qualquer um dos dois caminhos:

**Wizard shell:**
```bash
sudo bash opsec.sh setup
```
Detecta a interface física, instala o `.conf` da ProtonVPN em
`/etc/wireguard/` (chmod 600), extrai o DNS do túnel e grava tudo no
`config.env` (preservando os comentários). Pergunta sobre Tor, IPv6 e
silenciamento de LAN.

**GUI — botão ⚙ CONFIG:** no modo gráfico há uma janela de configuração
onde você **seleciona o `.conf`** (abre um seletor de arquivo), ajusta
interface/DNS/org esperado e liga/desliga cada camada por checkbox.
Grava no `config.env` com **validação estrita por chave** (o `config.env`
é `source`ado como root — nenhum valor com aspas/`$`/`;`/nova-linha
passa). Alterações valem na próxima ativação.

### Modo shell (o de sempre)
```bash
sudo bash opsec.sh setup | on | off | status | radar | selftest | panic
```

### Modo gráfico
```bash
sudo bash opsec.sh gui          # ou o atalho "BBGHOST (Modo Gráfico)"
```
Abre uma **interface gráfica nativa própria** (Tkinter, estilo Opera GX —
dark neon), **não** um painel dentro de navegador. Tem:
- botão de poder para **ativar/desligar** a cadeia OPSEC inteira;
- **tiles ao vivo**: kill switch, WireGuard, DNS, Tor, exposição pública
  (com alerta de **LEAK** se o org do IP público não for o da VPN) e
  identidade/hostname;
- botão de **PANIC**;
- botão **⚙ CONFIG** — configura **tudo**: envia **ou cola** o `.conf`, escolhe
  `VPN_TYPE` (WireGuard/OpenVPN), caminho do `.ovpn`, interface/DNS/org,
  modo do MAC, Tor, timezone, radar, dead-man, log em RAM (janela rolável);
- botão **? AJUDA** — guia embutido (o que cada camada faz, primeiro uso,
  leitura dos tiles, troubleshooting);
- botão **Navegador Tor**, que abre o navegador endurecido abaixo.

O **Navegador Tor** é o perfil Firefox dedicado `bbghost-gx`, que sobe:
- **roteado pelo Tor** (SOCKS5 + `socks_remote_dns` → sem DNS leak);
- **WebRTC desligado** (o vazamento de IP que a VPN/Tor não cobre),
  `resistFingerprinting`, telemetria e geolocalização off;
- **tema Opera-GX** no próprio chrome do Firefox (`userChrome.css`).

**Como funciona por baixo (sem marketing):**
- A GUI é um app **Tkinter** (stdlib do Python — zero dependências
  externas). Roda como root (herda do `opsec.sh gui`) e abre no seu
  display; pra isso o `gui.sh` libera o X pro root com `xhost`
  (revogado ao fechar). Os botões acionam `on/off/panic` direto, sem
  prompt de senha repetido.
- O navegador **não** é um Firefox forkado/"embutido" — é o **Firefox
  do sistema** com um *perfil* dedicado, *tema* e *roteamento Tor*
  próprios, isolado do seu Firefox normal e do perfil `bbghost-proton`.

> O `bbghost-gx` é **fail-closed por consequência**: com o OPSEC
> desligado o Tor não está de pé, então os sites externos não abrem até
> você **ATIVAR** na GUI.

Pré-requisitos extras do modo gráfico: `python3`, **`python3-tk`**
(`sudo apt install python3-tk`), `firefox`/`firefox-esr` e `curl`.

---

## Recursos avançados (v3)

### Qualquer VPN — não é preso a ninguém
O BBGHOST roteia por **qualquer provedor** (Mullvad, IVPN, ProtonVPN,
Windscribe, AirVPN, um WireGuard próprio…) ou **OpenVPN**. Basta
instalar o `.conf` (⚙ CONFIG → *Enviar* ou *Colar*, ou `opsec.sh setup`).
`VPN_PROVIDER` é só um rótulo seu; o detector de leak usa `VPN_EXPECT_ORG`
(o org/ASN que você espera ver — ex: "Mullvad").

### Perfis de missão
Um perfil guarda **config + VPN** de uma missão inteira; trocar reconfigura
tudo num comando.
```bash
opsec.sh profile save pentest-clienteX   # snapshot do estado atual (+ VPN)
opsec.sh profile list
opsec.sh profile load jornalismo          # aplica e instala a VPN do perfil
opsec.sh profile del  antigo              # remove (confs destruídos com shred)
```
Na GUI: botão **⬢ PERFIS** (ativar / salvar atual / excluir).

### Multi-hop (VPN sobre VPN)
Com `VPN_MULTIHOP="true"` + um `.conf` de 2º salto, o BBGHOST sobe um
segundo túnel **por dentro** do primeiro: `real → hop1 → hop2 → internet`.
Seu IP real nunca toca o 2º provedor e o 2º provedor nunca vê o 1º. O
kill switch libera a saída pelo 2º salto automaticamente.

### Isolamento forte (Whonix)
Com `ISOLATION_MODE="whonix"`, o navegador/apps rodam num **network
namespace** cujo ÚNICO caminho de saída é um **Whonix-Gateway** — à prova
de leak mesmo se o app ignorar proxy/VPN.
```bash
opsec.sh iso run firefox -P bbghost-gx    # app isolado pelo gateway
```
⚠ Exige você montar a VM Whonix-Gateway e apontar `WHONIX_GATEWAY_IP` +
`ISOLATION_UPLINK_IF` (a bridge do host até o gateway). **Plumbing pronto;
não testável sem a VM.**

### Automação / boot
```bash
opsec.sh autostart enable    # systemd sobe a cadeia fail-closed no boot
opsec.sh autostart disable
```
**Hooks:** scripts em `hooks/on.d/*.sh` e `hooks/off.d/*.sh` rodam no
on/off (notificação, montar volume cifrado, logging externo…). Ver
`hooks/README.md`.

### Verificação de integridade
```bash
opsec.sh integrity sign      # (re)gera o manifesto SHA-256 do código
opsec.sh verify              # confere tudo; detecta adulteração e
                             # arquivos de código novos fora do manifesto
```
Se você tiver chave GPG, o manifesto também é assinado (`.asc`).

### Windows (motor nativo)
Há um motor Windows em **`win/bbghost.ps1`** (PowerShell): sobe o túnel
WireGuard, aplica o **kill switch via Windows Firewall**, trava o DNS e
emite status em JSON. A **mesma GUI** (Tkinter) detecta o SO e chama o
motor certo. Requisitos no Windows: **WireGuard para Windows**, **Python
+ Tkinter**, e rodar como **Administrador**; os `.conf` ficam em
`win\..\wg\<interface>.conf`.

> **Honestidade:** o motor Windows foi **escrito mas não testado** pelo
> autor (ambiente de dev é Linux) — a lógica espelha o motor Linux já
> testado, mas **valide numa VM Windows** antes de confiar. No Linux
> tudo foi testado (inclusive screenshots da GUI e os módulos novos).

---

## OPSEC hardening v2 — o que mudou e por quê

Rodada de endurecimento focada em **reduzir superfície de vazamento** e
**proteger o operador se a máquina for apreendida**. Resumo do que mudou:

| # | Mudança | Por quê |
|---|---------|---------|
| 1 | `vpn.sh` não guarda mais cópia integral do `.conf` | O backup antigo (`.state/wg-*-original.conf`) continha a `PrivateKey` em claro — chave da VPN duplicada no disco. Agora só anotamos as linhas removidas (sem segredo) e um backup antigo é destruído com `shred`. |
| 2 | Log sem valores reais + opção `LOG_TO_RAM` | O `opsec.log` virava um diário forense (MAC/hostname reais, IP, timestamps de toda sessão). Agora os valores reais não vão pro log (ficam só em `.state`, chmod 700), e `LOG_TO_RAM="true"` move o log pra `/dev/shm` (some no desligamento). |
| 3 | Kill switch em **tabela isolada** (`nft delete table`, nunca `flush ruleset`) | O `flush ruleset` global apagava o firewall inteiro do host (Docker/ufw/libvirt) e deixava a máquina **sem firewall nenhum** no `off`. Agora só a tabela `bbghost_killswitch` é adicionada/removida. |
| 4 | `.state` em chmod 700 + `panic --burn` | `.state` guarda os baselines de identidade real. `panic --burn` destrói (`shred`) esses baselines no cenário de apreensão. Trade-off: você perde a restauração automática (reboot restaura MAC/hostname de qualquer forma). |
| 5 | Kill switch fixa o handshake no **IP:porta reais** do servidor | Antes liberava qualquer host na `51820/1194` (brecha de exfil/leak). Agora parseia o `Endpoint =` do `.conf` e libera só aquele destino. Cai no modo genérico só se não conseguir parsear. |
| 6 | Novo módulo `lan-silence.sh` | O hostname spoofed não cobre mDNS/Avahi, LLMNR e NetBIOS — que anunciam o nome da máquina em broadcast na LAN. Agora são calados durante a sessão e restaurados no `off`. Controlado por `SILENCE_LAN`. |
| 7 | `identity.sh` aplica `user.js` endurecido no perfil sensível | Mesmo com VPN perfeita, **WebRTC** vaza IP local/público via STUN. O `user.js` desliga WebRTC, força DNS pelo proxy, liga `resistFingerprinting` e mata telemetria. Escrito como o seu usuário (via `SUDO_USER`), não root. |
| 8 | MAC spoof com OUI plausível (`MACCHANGER_MODE="-a"`) + `NM_PIN_MAC` | OUI totalmente aleatório às vezes é mais anômalo/logável. `-a` usa um fabricante real. `NM_PIN_MAC="true"` fixa o MAC no NetworkManager pra ele não reverter. |
| 9 | Radar detecta **DNS/IP leak** contínuo | O radar compara o org/ASN do IP público com `VPN_EXPECT_ORG` (ex: `Proton`). Se não bater, o tráfego está saindo fora da VPN → grita LEAK, e com `RADAR_LEAK_AUTOREACT="true"` aciona o panic sozinho. |
| 11 | `cleanup.sh` limpa histórico dos dois usuários + nota de limitação | `history -c` num subshell não limpa o shell pai. O módulo agora trunca os arquivos de histórico do root **e** do usuário humano (`SUDO_USER`), e documenta como zerar a sessão atual de verdade. |

### Item 12 (ordem Tor→VPN) — **documentado, não embarcado**

Inverter a cadeia para **Tor→VPN** (VPN saindo *por dentro* do Tor, pra
que nem o provedor da VPN veja seu IP real) **não foi implementado como
toggle**, de propósito. O `tor.sh` já abandonou, com diagnóstico ao vivo
(ver o cabeçalho do módulo), o redirecionamento transparente por colisão
de roteamento com o WireGuard. Um Tor→VPN real exigiria a VPN egressar
por um transporte Tor/obfs — algo que o WireGuard da Proton não faz via
SOCKS. Embarcar um toggle que "parece funcionar mas trava" iria contra a
filosofia fail-closed do projeto. A cadeia atual segue **VPN→Tor** (Tor
disponível via SOCKS com `opsec.sh pc <comando>`). Se quiser Tor→VPN de
verdade, o caminho é um provedor/transporte que suporte egresso via Tor,
não um patch no roteamento local.

### Novas opções em `config.env`

`LOG_TO_RAM`, `MACCHANGER_MODE`, `NM_PIN_MAC`, `SILENCE_LAN`,
`VPN_EXPECT_ORG`, `RADAR_LEAK_AUTOREACT` — cada uma comentada no próprio
arquivo. Para descobrir o valor certo de `VPN_EXPECT_ORG`, rode
`sudo bash opsec.sh radar` uma vez com a VPN de pé e veja qual "org"
aparece na linha de IP público.

### Item 10 (higiene da conta VPN) — guidance operacional

Não é código: a melhor OPSEC técnica não salva uma conta de VPN ligada
à identidade real. Recomendações para a conta ProtonVPN usada aqui:

- Conta **dedicada** só para operações, nunca a conta pessoal.
- Criada já **sob uma rede anônima** (a própria VPN/Tor), nunca do IP
  residencial.
- E-mail de cadastro descartável/isolado (o próprio perfil Firefox
  endurecido deste projeto serve pra isso).
- Se for plano pago, pagamento **não atribuível**.
- Não reutilize a mesma conta/credencial entre operações que não devam
  ser correlacionáveis entre si.

---

## Licença

BBGHOST é **open-core com licenciamento duplo**:

- **Código aberto:** [GNU AGPLv3](LICENSE). Use, modifique e redistribua
  livremente; derivados ficam sob AGPLv3 e serviços em rede devem abrir o
  fonte (cláusula de rede).
- **Licença comercial:** para uso proprietário/empresarial e recursos
  Pro/Business. Veja [`LICENSING.md`](LICENSING.md).

Segurança: [`SECURITY.md`](SECURITY.md) · Contribuir: [`CONTRIBUTING.md`](CONTRIBUTING.md)

© 2026 **Black Bit** — *Feito pela Black Bit · Made by Black Bit · Сделано Black Bit · 由 Black Bit 制作*
