# R43 换装前预演：拿**数据目录的副本**在新 exe 上开一次库，确认 v6→v7 不丢东西、
# 且 `/api/purge` 这条新路由真的在了。真 data 一个字节都不碰。
#
# 为什么还要再预演一次：R39 那次跑的是当时那份 v7 exe；这一版服务端里新加了
# purge 与 cleanupIfStale——它们自己就写 change_log / server_setting，
# 万一和迁移撞在同一条路上，代价是家里那台的真实数据。
#
# 用法（这台机器策略是 Restricted，必须带 -ExecutionPolicy Bypass）：
#   powershell -ExecutionPolicy Bypass -File server\tool\preflight_upgrade_copy.ps1
#
# ★ 三个参数的坑（都在这轮查过源码）：
#   1) **没有 --no-tls 这个开关**：服务端总是同时起 HTTP 与 HTTPS，
#      传未知参数会 exit(64) 直接不起——别照别的项目的习惯猜参数。
#   2) **tls-port 不给就会用默认 8667**，真实例占着它 → 起不来。要显式错开。
#   3) **data 用 -d 指到副本目录**，不要靠 WorkingDirectory 隐式推（exe 所在目录才是部署根）。
param(
  [string]$Src = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data'),
  [string]$NewExe = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'dist\release_v0.15.0\zaoji_server.exe'),
  [int]$Port = 8899,
  [int]$TlsPort = 8900
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Say($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }

$repoServer = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP ("zaoji_preflight_r43_" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-Host ''
Write-Host '── 预演：新 exe 在数据副本上开库' -ForegroundColor Cyan
Say "源 data    $Src"
Say "副本目录   $tmp"
Say "新 exe     $NewExe"
Say "端口       http $Port / https $TlsPort（避开真实例的 8666/8667）"
if (-not (Test-Path $Src)) { throw "源 data 目录不在：$Src" }
if (-not (Test-Path $NewExe)) { throw "新 exe 不在：$NewExe" }

# 1) 拷一份（库 + 媒体 + 日志），拷完核对总字节数——拷漏了就等于预演了个空库
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Copy-Item -Path $Src -Destination (Join-Path $tmp 'data') -Recurse -Force
$srcBytes = (Get-ChildItem $Src -Recurse -File | Measure-Object -Property Length -Sum).Sum
$tmpBytes = (Get-ChildItem (Join-Path $tmp 'data') -Recurse -File | Measure-Object -Property Length -Sum).Sum
Say "拷贝校验   源 $srcBytes B / 副本 $tmpBytes B"
if ($srcBytes -ne $tmpBytes) { throw '拷贝体积不一致，预演不作数' }
$dbCopy = Join-Path $tmp 'data\zaoji.db'
if (-not (Test-Path $dbCopy)) { throw "副本里没有 zaoji.db：$dbCopy" }
$beforeHash = (Get-FileHash $dbCopy -Algorithm SHA256).Hash
Say "副本库基线指纹   $beforeHash"

# 2) 证书：没证书服务端会自己签还是报错？——只把现成的拷过去，避免它去写别的目录
$certsSrc = Join-Path $repoServer 'certs'
if (Test-Path $certsSrc) { Copy-Item $certsSrc (Join-Path $tmp 'certs') -Recurse -Force }

# 3) 让新 exe 在**副本**上起来（-d 显式指数据目录，部署根仍是 exe 所在目录）。
#    ★ 日志与证书也要显式指进临时目录：`baseDir()` 取的是 **exe 所在目录**，
#      不指过去就会在 dist/release_v0.15.0/ 里长出一个 logs/（第一次预演真长出来了）
$argList = @('-p', "$Port", '--tls-port', "$TlsPort",
  '-d', (Join-Path $tmp 'data'),
  '--log', (Join-Path $tmp 'logs'),
  '-c', (Join-Path $tmp 'certs'))
$p = Start-Process -FilePath $NewExe -ArgumentList $argList `
  -WorkingDirectory $tmp -PassThru -WindowStyle Hidden
Say "进程已起     pid $($p.Id)"

$fail = $null
try {
  # 4) 轮询状态页拿 schema 版本（最多 40 秒）
  $schema = $null
  $page = ''
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    try {
      $page = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/status" -UseBasicParsing -TimeoutSec 4).Content
      if ($page -match 'schema v(\d+)') { $schema = [int]$Matches[1]; break }
    } catch { }
  }
  if (-not $schema) { throw '状态页读不到 schema 版本（服务端可能根本没起来，看副本目录里的 logs）' }
  Say "迁移后 schema   v$schema"
  if ($schema -lt 7) { throw "没升到 v7" }

  # 5) 服务端自报的版本与统计
  if ($page -match 'v0\.15\.0') { Say '自报版本   v0.15.0 ✔' } else { Warn '状态页里没看到 v0.15.0，请人眼看一眼页头' }
  $ver = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 4).Content
  Say "health       $($ver.Substring(0, [Math]::Min(200, $ver.Length)))"

  # 6) 库确实被写过 = 迁移真跑过。**哈希要等服务停了再算**：
  #    服务端握着 zaoji.db 的独占句柄，运行中 Get-FileHash 直接抛"正由另一进程使用"
  #    （第一次预演就是死在这行上，读数本身没问题）
  Say '副本库指纹在服务停止后核对（见末尾两行）'

  # 7) 行数不许凭空少：拿状态页上的表计数比一比（页面里有 recipe 行数就取）
  foreach ($t in @('recipe', 'ingredient', 'step', 'pantry_item')) {
    if ($page -match "$t[^0-9]{0,40}([0-9]+)") { Say "行数     $t = $($Matches[1])" }
  }

  # 8) 永久删除这条路由在新 exe 上存在（旧 exe 回的是 HTML 404）
  $code = 0
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/purge" -Method Post `
      -Body '{"rows":[]}' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 5
    $code = [int]$r.StatusCode
  } catch { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } }
  Say "POST /api/purge → HTTP $code（400/401 都算路由在；404 = 还是旧那份 exe）"
  if ($code -eq 0 -or $code -eq 404) { throw '/api/purge 读不到或还是 404，这份 exe 不对' }

  # 9) ★ 顺带验 R43 那句「30 天清理挂在拉取上」：拉一次 /api/changes 不许把服务端拉崩，
  #    且第二次立刻拉不该再跑一遍清理（日志里清理行只该出现一次）
  $log = Join-Path $tmp 'logs\zaoji.log'
  for ($i = 0; $i -lt 6; $i++) {
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/changes?since=0" -Headers @{ 'X-Node-Id' = 'preflight' } -UseBasicParsing -TimeoutSec 5 | Out-Null; break } catch { Start-Sleep -Seconds 1 }
  }
  try { Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/changes?since=0" -Headers @{ 'X-Node-Id' = 'preflight' } -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { }
  if (Test-Path $log) {
    $txt = Get-Content $log -Raw -Encoding UTF8
    $purgeLines = ([regex]::Matches($txt, '已清理过期数据')).Count
    Say "日志       「已清理过期数据」出现 $purgeLines 次（12 小时戳记该让它最多一次）"
    if ($txt -match '包含不允许同步的列') { throw '日志里还有「包含不允许同步的列」，说明库没升上来' }
  } else { Warn "没找到副本日志 $log" }
} catch { $fail = $_ }
finally {
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  # 服务停了才拿得到句柄：这一对比只说明"迁移在这份副本上动没动过库"，
  # 判定预演通过与否靠上面那几行（schema v7 / 版本 / /api/purge / 日志）
  try {
    $afterHash = (Get-FileHash $dbCopy -Algorithm SHA256).Hash
    if ($afterHash -eq $beforeHash) { Warn '副本库指纹没变：这份库本来就是 v7，迁移是幂等空跑（不是没跑起来）' }
    else { Say '副本库指纹已变：迁移在这份副本上真动过库' }
  } catch { Warn "副本库指纹没读到（句柄还没释放）：$($_.Exception.Message)" }
  Say "副本留在   $tmp（人眼复核用，不自动删）"
}
if ($fail) { Write-Host ''; Write-Host "预演失败：$fail" -ForegroundColor Red; exit 1 }
Write-Host ''
Write-Host '预演通过：可以把真实例换到这份 exe 了（upgrade_local_instance.ps1 -Apply）' -ForegroundColor Green
