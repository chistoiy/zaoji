# 本机 / 家里那台实例的换装脚本（默认只预演，加 -Apply 才真动）
#
# 为什么要有这个脚本：main 这条线已经是 schema v7（R39 改列轮），而两台实例的 exe 还是
# v0.14.3 / v6。服务端白名单是**多出来的列整条拒绝**（server/lib/src/sync.dart:548 起），
# 所以「v7 前端 + v6 服务端」这台机器现在的状态是：Web 版本地写得动、推送被逐条拒收。
# 换装要停进程、要备份、要在原地把库升到 v7 —— 这三件事都不该靠手敲记住，
# 所以固成一个脚本，**默认 dry-run**，看过计划再加 -Apply。
#
# 用法（本机执行策略是 Restricted，必须带 -ExecutionPolicy Bypass）：
#   预演：  powershell -ExecutionPolicy Bypass -File server\tool\upgrade_local_instance.ps1
#   真做：  powershell -ExecutionPolicy Bypass -File server\tool\upgrade_local_instance.ps1 -Apply
#   家里那台：把整个仓库拷过去后 -InstallDir D:\zaoji，或者只拷本脚本 + dist\release_v0.15.0\
#
# 做完还要人验的两件事（脚本替不了）：
#   1) 浏览器开 http://127.0.0.1:8666/ ，状态页应显示 schema v7；
#   2) 在 Web 版新建一道菜 → 等同步转完 → 「我的 → 同步」的差异数应当能清零，
#      日志 logs\zaoji.log 里不该再出现「包含不允许同步的列」。
#
# 回滚：脚本会把旧 exe 与 data 目录都留副本，末尾会打印一条一条的回滚命令。

param(
  # 服务端安装目录（exe、data、certs、logs 都在这）。默认取仓库里的 server/。
  [string]$InstallDir = (Split-Path -Parent $PSScriptRoot),
  # 新 exe。默认指向仓库里 R39 编好的那份 v7。
  [string]$NewExe = "",
  # 换装后要不要顺手把 -w 指到某个 web 目录；不给就沿用现状（不带 -w 起来）。
  [string]$WebDir = "",
  # 期望升级到的 schema 版本（状态页上那行 'schema v7' 的 7）。
  [int]$WantSchema = 7,
  [switch]$Apply
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Say($m, $c = 'Gray') { Write-Host ("  " + $m) -ForegroundColor $c }
function Head($m) { Write-Host ''; Write-Host ("── " + $m + " " + ("─" * [Math]::Max(0, 62 - $m.Length))) -ForegroundColor Cyan }

# 仓库根 = 本脚本所在目录(server/tool)往上两级：tool → server → 仓库根。
# （别拿 $InstallDir 推：它的默认值已经是 server/ 这一级，再往上就跑到仓库外面去了。）
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $NewExe) { $NewExe = Join-Path $repoRoot 'dist\release_v0.15.0\zaoji_server.exe' }
$exe = Join-Path $InstallDir 'zaoji_server.exe'
$data = Join-Path $InstallDir 'data'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$exeBak = "$exe.bak-$stamp"
$dataBak = "$InstallDir\data_backup-$stamp"
$log = Join-Path $InstallDir 'logs\zaoji.log'

Head '计划（先看这段，确认没问题再加 -Apply）'
Say "安装目录   $InstallDir"
Say "当前 exe   $(if (Test-Path $exe) { (Get-Item $exe).Length.ToString() + ' B  mtime ' + (Get-Item $exe).LastWriteTime.ToString('MM-dd HH:mm') } else { '不在' })"
Say "新 exe     $NewExe  ($(if (Test-Path $NewExe) { (Get-Item $NewExe).Length } else { 0 }) B)"
# ★ 重启时必须沿用原来的启动参数，否则"只升级库"会把 Web 版整段弄没：
#   现在的实例是 zaoji_server.exe -w ..\app\build\web 起来的，不带 -w 重启 = 家里没人能用网页版。
#   本机读不到进程命令行（Get-CimInstance / Get-WmiObject 的 Win32_Process 在这台机器上都报
#   「类不存在/无效类」，WMI 仓库是坏的），所以**改从状态页拿**：它会把托管中的 web 目录原样打出来。
if (-not $WebDir) {
  try {
    $page = (Invoke-WebRequest -Uri 'http://127.0.0.1:8666/status' -UseBasicParsing -TimeoutSec 5).Content
    $m = [regex]::Match($page, 'Web 产物：<code>([^<]+)</code>')
    if ($m.Success) {
      # 状态页打的是当初拼出来的原样（…\server\../app/build/web），归一化一下再传 -w，
      # 免得日志与文档里出现一串 ".."，也免得有人照着它去手工拼路径。
      try { $WebDir = [IO.Path]::GetFullPath($m.Groups[1].Value.Trim()) } catch { $WebDir = $m.Groups[1].Value.Trim() }
    }
  } catch { Say "读状态页失败，拿不到当前 -w 目录：$($_.Exception.Message)" 'DarkGray' }
}
if ($WebDir) { Say "web 目录   $WebDir（重启时带回 -w）" -ForegroundColor Yellow }
else { Say "web 目录   拿不到！这台若在挂 Web 版，重启后 / 会 404 —— 请先人工确认要不要补 -WebDir" -ForegroundColor Red }
Say "备份       exe → $exeBak"
Say "            data → $dataBak"
Say "目标       原地开库升到 schema v$WantSchema（迁移由服务端自己跑，幂等）" -ForegroundColor Yellow
if (-not $Apply) { Write-Host ''; Write-Host '  这是预演：什么都没动。加 -Apply 才会真做。' -ForegroundColor Green; exit 0 }

# ── 0. 前置校验：宁可不干，也不要干一半 ───────────────────────────────
Head '0 · 前置校验'
foreach ($p in @(@{n = '安装目录'; v = $InstallDir }, @{n = 'data 目录'; v = $data }, @{n = '旧 exe'; v = $exe })) {
  if (-not (Test-Path $p.v)) { throw "$($p.n) 不存在：$($p.v)" }
  Say "$($p.n) 在"
}
if (-not (Test-Path $NewExe) -or (Get-Item $NewExe).Length -lt 1MB) {
  throw "新 exe 不存在或体积可疑：$NewExe"
}
Say "新 exe 体积 $((Get-Item $NewExe).Length) B" -ForegroundColor Green

# ── 1. 找在跑的那个进程：必须是 zaoji_server.exe 才允许停 ────────────
Head '1 · 找到在跑的服务端（不盲杀）'
$conns = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -in 8666, 8667 })
$procIds = @($conns | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique)
$target = $null
foreach ($pid2 in $procIds) {
  $p = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
  if ($p -and $p.ProcessName -like 'zaoji_server*') { $target = $p }
  elseif ($p) { throw "端口 8666/8667 被「$($p.ProcessName)」(pid $($p.Id)) 占着，不是灶记服务端 —— 先人工处理，脚本不停它" }
}
if ($null -eq $target) {
  Say "没有正在监听 8666/8667 的灶记进程，跳过停进程" -ForegroundColor DarkGray
} else {
  Say "要停的是 pid $($target.Id)（$($target.ProcessName)），端口 $(($conns | ForEach-Object { $_.LocalPort } | Sort-Object -Unique) -join '/')"
  Stop-Process -Id $target.Id -Force
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (-not (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 8666, 8667 })) { break }
  }
  if (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 8666, 8667 }) {
    throw "端口还没释放，Windows 文件锁会让覆盖 exe 失败 —— 等几秒重跑（备份已做的不会被浪费）"
  }
  Say "端口已释放" -ForegroundColor Green
}

# ── 2. 备份：整包退路，拷完要比字节数 ────────────────────────────────
Head '2 · 备份 data 与旧 exe'
Copy-Item $exe $exeBak -Force
Copy-Item $data $dataBak -Recurse -Force
$srcBytes = (Get-ChildItem $data -Recurse -File | Measure-Object Length -Sum).Sum
$dstBytes = (Get-ChildItem $dataBak -Recurse -File | Measure-Object Length -Sum).Sum
if ($srcBytes -ne $dstBytes) { throw "data 备份字节不一致：$srcBytes vs $dstBytes（不要用这份备份回滚，先人工看）" }
Say "data 已备份 $dstBytes B → $dataBak" -ForegroundColor Green
Say "旧 exe 已留 $exeBak"

# ── 3. 换 exe ────────────────────────────────────────────────────────
Head '3 · 换上新 exe'
Copy-Item $NewExe $exe -Force
if ((Get-Item $exe).Length -ne (Get-Item $NewExe).Length) { throw '覆盖后体积与新 exe 不符' }
Say "zaoji_server.exe = $((Get-Item $exe).Length) B（与 $NewExe 一致）" -ForegroundColor Green

# ── 4. 起来（本机 Start-Process 有个环境变量的坑，失败就退回 cmd start）──
Head '4 · 启动新服务端（原地开库会在这里跑迁移）'
$argList = @()
if ($WebDir) { $argList += @('-w', $WebDir) }
$psi = (@($exe) + $argList) -join ' '
try {
  if ($argList.Count) { Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $InstallDir -WindowStyle Hidden }
  else { Start-Process -FilePath $exe -WorkingDirectory $InstallDir -WindowStyle Hidden }
} catch {
  Say "Start-Process 抛了（本机有 Path/PATH 双键的老坑），改用 cmd start" -ForegroundColor DarkYellow
  cmd /c start "zaoji" /min "" cmd /c "cd /d `"$InstallDir`" && $psi"
}

# ── 5. 等它就绪，并核状态页报的 schema ───────────────────────────────
Head "5 · 等它就绪并核 schema v$WantSchema"
$ok = $false
$schema = ''
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 1
  try {
    $page = (Invoke-WebRequest -Uri 'http://127.0.0.1:8666/status' -UseBasicParsing -TimeoutSec 3).Content
    $m = [regex]::Match($page, 'schema\s*v(\d+)')
    if ($m.Success) { $schema = $m.Groups[1].Value; if ([int]$schema -eq $WantSchema) { $ok = $true; break } }
  } catch { }
}
if (-not $ok) {
  Say "状态页报的 schema 是 '$schema'，不是期望的 v$WantSchema" -ForegroundColor Red
  Say "先别慌：日志尾部能看出来是没起来、还是迁移报错。回滚命令在最后。"
  if (Test-Path $log) { Write-Host ''; Get-Content $log -Tail 12 | ForEach-Object { Say $_ 'DarkGray' } }
} else {
  Say "服务端已跑在 schema v$schema" -ForegroundColor Green
}

# ── 6. 收尾：把还要人验的两件事 + 回滚命令打在屏幕上 ─────────────────
Head '6 · 还要你亲手验的两件事'
Say '1) 浏览器开 http://127.0.0.1:8666/ —— 状态页 schema 应当是 v' -NoNewline; Say "$WantSchema"
Say '2) Web 版新建一道菜 → 等「我的 → 同步」转完 → 差异数应能清零；'
Say "   logs\zaoji.log 里不该再出现「包含不允许同步的列」。旧版才会出这句。"

Head '要回滚的话（照顺序执行）'
Say "Stop-Process -Name zaoji_server -Force"
Say "Remove-Item '$data' -Recurse -Force; Copy-Item '$dataBak' '$data' -Recurse"
Say "Copy-Item '$exeBak' '$exe' -Force"
Say "然后按原来的参数重新启动 zaoji_server.exe"
Write-Host ''
Write-Host $(if ($ok) { '  ✔ 换装完成，库已在原地升级；旧 exe 与 data 都有副本，删掉之前请先验完上面两件事' -replace '^', '' } else { '  ✘ 没验到期望的 schema，先看日志再决定回滚' }) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
if (-not $ok) { exit 1 }
