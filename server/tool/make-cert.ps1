<#
  生成灶记局域网 HTTPS 证书。

  ── 为什么非做这件事不可 ──
  iOS Safari 只把 https:// 、localhost 、file:// 当作「安全上下文」。
  http://192.168.x.x 不是。后果是四样能力直接失效，而这四样恰好全是 iOS 端最需要的：

    navigator.wakeLock    -> 做菜时手一停屏幕就灭
    Notification          -> 计时器结束无法提醒
    Service Worker        -> PWA 无法离线、加到主屏也不独立运行
    getUserMedia          -> 网页端不能直接调相机

  所以服务端必须同时监听 http(8666) 与 https(8667)，iOS 走 https。

  ── 为什么要 CA + 服务器证书，而不是一张自签叶子证书 ──
  家里的 IP 是 DHCP 分的，会变。IP 一变就得重签服务器证书。
  如果有自己的 CA，重签时只需要换服务端文件，手机上装过的 CA 不用动；
  否则每次都要重新在 iPhone 上装一遍描述文件。
  所以本脚本默认「复用已有 CA」，只有加 -Force 才会连 CA 一起重做。

  ── 用法 ──
    powershell -ExecutionPolicy Bypass -File tool\make-cert.ps1
    powershell -ExecutionPolicy Bypass -File tool\make-cert.ps1 -Ips 192.168.1.5,10.0.0.9
    powershell -ExecutionPolicy Bypass -File tool\make-cert.ps1 -Force     # 连 CA 一起重做

  ── 注意：本文件必须存成 UTF-8 with BOM ──
  Windows PowerShell 5.1 读取无 BOM 的 .ps1 时会按 GBK 解码，
  中文字节两两配对会吃掉换行与括号，导致「语法错误」而根本跑不起来。
  这是本项目真实踩过的坑，改动本文件后请用 fix-encoding 那步重新保存。

  ── 生成之后，iPhone 上还要做两步（只做一次）──
    1) 把 ca.crt 传到手机（AirDrop / 邮件 / 局域网），点开安装描述文件
       设置 -> 通用 -> VPN与设备管理 -> 安装
    2) 设置 -> 通用 -> 关于本机 -> 证书信任设置 -> 打开「ZAOJI Local CA」的完全信任

  只做第 1 步不做第 2 步，Safari 依然会报「不安全」——这是最常见的卡点。
#>
param(
  [string[]]$Ips = @(),
  [string]$OutDir = (Join-Path $PSScriptRoot '..\certs'),
  [int]$ServerDays = 825,
  [int]$CaDays = 3650,
  [switch]$Force
)

# 调用外部程序（openssl）时必须用 Continue：
# 在 PS 5.1 里，原生命令往 stderr 写东西会被当成 NativeCommandError，
# 配合 'Stop' 会在赋值语句处直接抛异常中断脚本（本项目在 Chrome 截图上踩过同一个坑）。
$ErrorActionPreference = 'Continue'

function Fail($msg) {
  Write-Host ''
  Write-Host "✗ $msg" -ForegroundColor Red
  exit 1
}

# ── 1. 找 openssl（Git for Windows 自带）──
$opensslCandidates = @(
  'D:\app_workplace\Git\mingw64\bin\openssl.exe',
  'D:\app_workplace\Git\usr\bin\openssl.exe',
  'C:\Program Files\Git\mingw64\bin\openssl.exe',
  'C:\Program Files\Git\usr\bin\openssl.exe',
  (Get-Command openssl -ErrorAction SilentlyContinue).Source
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $opensslCandidates) {
  Fail '找不到 openssl。装一个 Git for Windows 就有了。'
}
$openssl = $opensslCandidates[0]
Write-Host "openssl: $openssl" -ForegroundColor DarkGray

# ── 2. 探测局域网 IP ──
# 169.254.x 是 APIPA（网卡没拿到 DHCP 时的自分配地址），签进证书毫无意义，必须排除。
$autoIps = @()
try {
  $autoIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*' -and
      $_.IPAddress -notlike '0.*'
    } |
    Select-Object -ExpandProperty IPAddress
} catch { }

$allIps = @($autoIps + $Ips) | Where-Object { $_ } | Sort-Object -Unique
if (-not $allIps) {
  Fail '没有探测到可用的局域网 IP，请用 -Ips 手工指定。'
}

Write-Host ''
Write-Host '将写入证书的 IP：' -ForegroundColor Cyan
$allIps | ForEach-Object { Write-Host "  $_" }

# ── 3. 准备目录 ──
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$caKey  = Join-Path $OutDir 'ca.key'
$caCrt  = Join-Path $OutDir 'ca.crt'
$svrKey = Join-Path $OutDir 'server.key'
$svrCrt = Join-Path $OutDir 'server.crt'
$csr    = Join-Path $OutDir 'server.csr'
$sanCnf = Join-Path $OutDir 'san.cnf'
$errLog = Join-Path $OutDir '_openssl_err.txt'

# ── 4. CA（已存在就复用，除非 -Force）──
$needCa = $Force -or -not (Test-Path $caKey) -or -not (Test-Path $caCrt)
if ($needCa) {
  Write-Host ''
  Write-Host '-> 生成 CA...' -ForegroundColor Cyan
  & $openssl req -x509 -newkey rsa:2048 -nodes `
    -keyout $caKey -out $caCrt -days $CaDays -sha256 `
    -subj '/CN=ZAOJI Local CA/O=Zaoji Home/OU=Home Network' 2> $errLog
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $caCrt)) {
    if (Test-Path $errLog) { Get-Content $errLog | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
    Fail "CA 生成失败（openssl exit=$LASTEXITCODE）"
  }
} else {
  Write-Host ''
  Write-Host '-> 复用已有 CA（手机上的信任不用重装）' -ForegroundColor DarkGray
}

# ── 5. 先删掉旧的服务器证书 ──
# 这一步不能省：如果签发失败而旧文件还在，后面的 Test-Path 会通过，
# 脚本就会宣布成功，实际用的却是「没有新 IP 的旧证书」——静默失效，最难查。
foreach ($f in @($svrCrt, $svrKey, $csr)) {
  if (Test-Path $f) { Remove-Item -LiteralPath $f -Force }
}

# ── 6. SAN 配置 ──
$sanEntries = @('DNS:zaoji.local', 'DNS:localhost', 'IP:127.0.0.1', 'IP:::1')
$allIps | ForEach-Object { $sanEntries += "IP:$_" }

@"
[req]
distinguished_name = dn
prompt = no

[dn]
CN = zaoji.local
O  = Zaoji Home

[ext]
subjectAltName = $($sanEntries -join ',')
extendedKeyUsage = serverAuth
keyUsage = digitalSignature,keyEncipherment
basicConstraints = CA:FALSE
"@ | Set-Content -Path $sanCnf -Encoding ASCII

# ── 7. 签发（两步法：先 CSR，再由 CA 签）──
# 不要写成 `openssl req -x509 -CA ...` 一步到位：本机这套 openssl 上会失败。
Write-Host ''
Write-Host '-> 生成密钥与 CSR...' -ForegroundColor Cyan
& $openssl req -new -newkey rsa:2048 -nodes `
  -keyout $svrKey -out $csr -config $sanCnf 2> $errLog
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $csr)) {
  if (Test-Path $errLog) { Get-Content $errLog | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
  Fail "CSR 生成失败（openssl exit=$LASTEXITCODE）"
}

Write-Host '-> 由 CA 签发服务器证书...' -ForegroundColor Cyan
& $openssl x509 -req -in $csr `
  -CA $caCrt -CAkey $caKey -CAcreateserial `
  -out $svrCrt -days $ServerDays -sha256 `
  -extfile $sanCnf -extensions ext 2> $errLog
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $svrCrt) -or -not (Test-Path $svrKey)) {
  if (Test-Path $errLog) { Get-Content $errLog | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
  Fail "服务器证书签发失败（openssl exit=$LASTEXITCODE）"
}

# ── 8. 自证：真正验证，而不是只看文件存在 ──
Write-Host ''
Write-Host '-> 校验...' -ForegroundColor Cyan

$verifyOut = & $openssl verify -CAfile $caCrt $svrCrt 2>&1 | Out-String
if ($verifyOut -notmatch 'OK') {
  Write-Host "  $($verifyOut.Trim())" -ForegroundColor DarkGray
  Fail '证书链校验失败，服务端下发这张证书 iOS 不会信任。'
}
Write-Host '  chain verify: OK' -ForegroundColor Green

# SAN 里必须真的包含探到的每个 IP，否则「签了但连不上」比没签更让人困惑
$sanOut = (& $openssl x509 -in $svrCrt -noout -ext subjectAltName 2>&1 | Out-String)
$missing = @()
foreach ($ip in $allIps) { if ($sanOut -notmatch [regex]::Escape($ip)) { $missing += $ip } }
if ($missing.Count -gt 0) {
  Fail ("SAN 里缺少这些 IP，说明签发没生效：" + ($missing -join ', '))
}
Write-Host '  SAN contains all detected IPs: OK' -ForegroundColor Green

# ── 9. 打印结果，别让用户去猜 ──
Write-Host ''
Write-Host '── 服务器证书 ──────────────────────────────' -ForegroundColor Green
& $openssl x509 -in $svrCrt -noout -subject -issuer -dates 2>&1 | ForEach-Object { Write-Host "  $_" }
Write-Host '  SAN:'
$sanLines = (& $openssl x509 -in $svrCrt -noout -ext subjectAltName 2>&1) -split "`r?`n"
$sanLines | Select-Object -Skip 1 | ForEach-Object { Write-Host "   $_" }

Write-Host ''
Write-Host '── CA 证书指纹（手机上核对用）────────────────' -ForegroundColor Green
& $openssl x509 -in $caCrt -noout -fingerprint -sha256 2>&1 | ForEach-Object { Write-Host "  $_" }

if (Test-Path $errLog) { Remove-Item -LiteralPath $errLog -Force }

Write-Host ''
Write-Host "证书已写入：$OutDir" -ForegroundColor Cyan
Write-Host '  ca.crt      <- 传到 iPhone 上安装并信任（只需一次）'
Write-Host '  server.crt  <- 服务端用'
Write-Host '  server.key  <- 服务端用（私钥，别外传）'
Write-Host ''
Write-Host '服务端重启后会自动检测到 certs\server.crt，并额外监听 https。' -ForegroundColor DarkGray
