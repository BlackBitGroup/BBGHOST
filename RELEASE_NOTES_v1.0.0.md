# BBGHOST v1.0.0 — "hello, friend." 👻

**OPSEC fail-closed para o operador, num comando.** O BBGHOST liga e
desliga uma cadeia inteira de proteção — VPN + kill switch + DNS travado +
Tor + MAC/hostname falsos — com a filosofia de que, se algo não confirma
que subiu, **a rede continua travada e nunca vaza**. Protege a *sua*
identidade e conexão; não é ferramenta de ataque.

> *Feito pela Black Bit · Made by Black Bit · Сделано Black Bit · 由 Black Bit 制作*

---

## ✨ Destaques

- 🔒 **Kill switch fail-closed** (nftables, tabela isolada, handshake fixado
  no servidor real) — se a VPN cai, a internet morre. E tem **selftest** que
  derruba a VPN de propósito pra **provar** que o kill switch segura.
- 🌐 **Qualquer VPN** — WireGuard ou OpenVPN, qualquer provedor (Mullvad,
  IVPN, Proton, Windscribe, AirVPN, WireGuard próprio…). Só instalar o `.conf`.
- 🎭 **Perfis de missão** — guarde config + VPN de cada operação e troque
  tudo num clique.
- ⛓️ **Multi-hop (VPN sobre VPN)** — `real → hop1 → hop2 → internet`.
- 🧱 **Isolamento forte estilo Whonix** — navegador/apps num namespace cuja
  única saída é o gateway (leak-proof mesmo se o app ignorar o proxy).
- 🛰️ **Radar ao vivo** — detecta ARP spoofing, modo promíscuo, **vazamento
  de IP**, com reação automática e **dead man's switch**.
- 💣 **Panic** — corte de emergência; `--burn` destrói os baselines de
  identidade real (cenário de apreensão).
- 🖥️ **Dois modos** — shell completo **e** uma **GUI nativa própria** (Tkinter,
  visual Opera GX) com status ao vivo, configuração completa, perfis, ajuda e
  um **Navegador Tor** endurecido (WebRTC off, anti-fingerprint, anti-DNS-leak).
- ⚙️ **Automação** — fail-closed no boot (systemd) + hooks de on/off.
- ✅ **Integridade** — manifesto SHA-256 (+ GPG) que detecta adulteração do
  próprio código.
- 🪟 **Windows** — motor nativo em PowerShell (kill switch via Windows
  Firewall); a mesma GUI detecta o SO.

## 🚀 Começando

```bash
sudo apt install wireguard macchanger nftables curl iproute2 python3-tk
git clone https://github.com/blackbit/bbghost && cd bbghost
sudo bash opsec.sh setup     # instala seu .conf de VPN + ajusta tudo
sudo bash opsec.sh gui       # abre a interface gráfica
# ou, direto no shell:
sudo bash opsec.sh on        # ativa    |    sudo bash opsec.sh off  # desativa
```

Veja o [README](README.md) para o guia completo (e o botão **? AJUDA** dentro da GUI).

## ⚠️ Honestidade (leia antes de confiar)

- **Testado no Linux** (Kali): cadeia OPSEC, GUI (com screenshots), perfis e
  integridade.
- **Motor Windows** (`win/bbghost.ps1`): escrito e com **sintaxe validada**,
  mas **não testado em Windows real** — valide numa VM antes de confiar.
- **Isolamento Whonix**: exige você montar a VM Whonix-Gateway.
- **Multi-hop**: a validação ponta-a-ponta precisa de dois servidores reais.

## 🔐 Dica de OPSEC ao publicar/clonar

Os `.conf` de VPN contêm **chave privada** — já estão no `.gitignore`, nunca
os commite. Verifique o código antes de rodar: `bash opsec.sh verify`.

## 📄 Licença

Open-core **dual**: [AGPLv3](LICENSE) para a comunidade + licença comercial
para uso proprietário/empresarial (ver [`LICENSING.md`](LICENSING.md)).
Falhas de segurança: [`SECURITY.md`](SECURITY.md).

---

**Changelog completo:** [`CHANGELOG.md`](CHANGELOG.md)
© 2026 Black Bit
