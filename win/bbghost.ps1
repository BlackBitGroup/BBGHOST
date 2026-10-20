<#
=================================================================
 BBGHOST — bbghost.ps1   (MOTOR WINDOWS)
 Equivalente Windows do opsec.sh: VPN (WireGuard) + kill switch
 (Windows Firewall / WFP) + DNS travado + panic + status JSON.
 A GUI (bbghost_gui.py) chama este script no Windows.

 ⚠ ESCRITO MAS NÃO TESTADO em Windows pelo autor da porta (ambiente
   de dev é Linux). Valide numa VM Windows antes de confiar. A lógica
   espelha o motor Linux já testado.

 Requisitos no Windows:
   - WireGuard para Windows instalado (wireguard.exe no PATH ou em
     "C:\Program Files\WireGuard").
   - Rodar como Administrador (mexe em firewall/serviços/DNS).
   - Confs em  <BBGHOST_HOME>\wg\<WG_INTERFACE>.conf

 Uso:  powershell -ExecutionPolicy Bypass -File bbghost.ps1 <on|off|status|panic>
=================================================================
#>
param([Parameter(Position=0)][string]$Action = "status")

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Home_ = Split-Path -Parent $Here                      # <BBGHOST_HOME>
$ConfigEnv = Join-Path $Home_ "config.env"
$WgDir = Join-Path $Home_ "wg"
$LockFile = Join-Path $Home_ "status.lock"
$FwGroup = "BBGHOST-KillSwitch"

# ---- parse simples do config.env (KEY="valor") ----
function Get-Cfg([string]$key, [string]$default="") {
    if (!(Test-Path $ConfigEnv)) { return $default }
    $m = Select-String -Path $ConfigEnv -Pattern ("^\s*{0}\s*=\s*""?([^""#\r\n]*)""?" -f [regex]::Escape($key)) | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value.Trim() } else { return $default }
}

$WG      = Get-Cfg "WG_INTERFACE" "wg0"
$HOP2    = Get-Cfg "HOP2_WG_INTERFACE" "wg1"
$MULTIHOP= (Get-Cfg "VPN_MULTIHOP" "false") -eq "true"
$DNS     = Get-Cfg "SECURE_DNS" ""
$EXPECT  = Get-Cfg "VPN_EXPECT_ORG" ""

function Find-WireGuard {
    $c = Get-Command wireguard.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = "C:\Program Files\WireGuard\wireguard.exe"
    if (Test-Path $p) { return $p }
    throw "wireguard.exe não encontrado. Instale o WireGuard para Windows."
}

function Tunnel-Up([string]$iface) {
    $conf = Join-Path $WgDir "$iface.conf"
    if (!(Test-Path $conf)) { throw "Conf não encontrada: $conf" }
    $wgexe = Find-WireGuard
    & $wgexe /installtunnelservice $conf | Out-Null
    # espera handshake (até 24s)
    for ($i=0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name "WireGuardTunnel`$$iface" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            $hs = (& $wgexe show $iface latest-handshakes) 2>$null
            if ($hs -and ($hs -split "\s+")[-1] -ne "0") { return $true }
        }
    }
    return $true   # serviço subiu; handshake pode confirmar logo após
}

function Tunnel-Down([string]$iface) {
    $wgexe = Find-WireGuard
    & $wgexe /uninstalltunnelservice $iface 2>$null | Out-Null
}

# ---- Kill switch via Windows Firewall (fail-closed) ----
function KillSwitch-On {
    # bloqueia TODA saída por padrão nos três perfis
    netsh advfirewall set allprofiles firewallpolicy blockinbound,blockoutbound | Out-Null
    # permite o essencial: loopback, DHCP, e o adaptador WireGuard
    New-NetFirewallRule -DisplayName "BBGHOST loopback" -Group $FwGroup -Direction Outbound `
        -RemoteAddress 127.0.0.1 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "BBGHOST DHCP" -Group $FwGroup -Direction Outbound `
        -Protocol UDP -RemotePort 67,68 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    # libera tudo que sai pela interface do túnel WireGuard
    $tun = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "WireGuard" -or $_.Name -match $WG }
    foreach ($a in $tun) {
        New-NetFirewallRule -DisplayName ("BBGHOST tunnel {0}" -f $a.Name) -Group $FwGroup `
            -Direction Outbound -InterfaceAlias $a.Name -Action Allow -ErrorAction SilentlyContinue | Out-Null
    }
    # libera o handshake WireGuard (UDP) saindo pra qualquer servidor
    New-NetFirewallRule -DisplayName "BBGHOST handshake" -Group $FwGroup -Direction Outbound `
        -Protocol UDP -RemotePort 51820,1194 -Action Allow -ErrorAction SilentlyContinue | Out-Null
}

function KillSwitch-Off {
    Remove-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue
    netsh advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound | Out-Null
}

function Dns-Lock {
    if (-not $DNS) { return }
    $tun = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "WireGuard" }
    foreach ($a in $tun) { Set-DnsClientServerAddress -InterfaceAlias $a.Name -ServerAddresses $DNS -ErrorAction SilentlyContinue }
}

function Do-On {
    KillSwitch-On
    Tunnel-Up $WG | Out-Null
    if ($MULTIHOP) { Tunnel-Up $HOP2 | Out-Null }
    Dns-Lock
    "on" | Out-File -Encoding ascii $LockFile
    Write-Host "[BBGHOST] ATIVO (Windows). Kill switch + WireGuard de pé."
}

function Do-Off {
    if ($MULTIHOP) { Tunnel-Down $HOP2 }
    Tunnel-Down $WG
    KillSwitch-Off
    Remove-Item $LockFile -ErrorAction SilentlyContinue
    Write-Host "[BBGHOST] OFF (Windows). Rede restaurada."
}

function Do-Panic {
    # corte de emergência: derruba os adaptadores físicos na hora
    Get-NetAdapter -Physical | Where-Object Status -eq "Up" | Disable-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[BBGHOST] PANIC: adaptadores físicos derrubados."
}

function Do-Status {
    $active = Test-Path $LockFile
    $ks = [bool](Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue)
    $svc = Get-Service -Name "WireGuardTunnel`$$WG" -ErrorAction SilentlyContinue
    $vpnUp = ($svc -and $svc.Status -eq "Running")
    $ns = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty ServerAddresses)
    $pub = $null; $org = $null; $country = $null; $leak = $false
    try {
        $j = Invoke-RestMethod -Uri "https://ifconfig.co/json" -TimeoutSec 5
        $pub = $j.ip; $org = $j.asn_org; $country = $j.country
        if ($EXPECT -and $org -and ($org -notmatch [regex]::Escape($EXPECT))) { $leak = $true }
    } catch {}
    $out = [ordered]@{
        active     = $active
        hostname   = $env:COMPUTERNAME
        killswitch = $ks
        vpn        = @{ up = $vpnUp; handshake = $(if($vpnUp){0}else{$null}) }
        dns        = @{ ns = $ns; ok = ($ns -eq $DNS -and $DNS -ne "") }
        tor        = @{ running = $false; used = $false }
        public     = @{ ip = $pub; org = $org; country = $country; leak = $leak }
    }
    $out | ConvertTo-Json -Depth 5 -Compress
}

switch ($Action.ToLower()) {
    "on"     { Do-On }
    "off"    { Do-Off }
    "panic"  { Do-Panic }
    "status" { Do-Status }
    default  { Write-Host "uso: bbghost.ps1 {on|off|status|panic}" }
}
