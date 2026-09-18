# 构建 Flutter Web 产物。**所有 Web 构建都走这个脚本，不要直接敲 flutter build web。**
#
# 原因：`flutter build web` 有两条「默认开着、但会让产物在断网时变成白屏」的行为，
# 它们都不报错、不影响构建成功，只在你把网线拔掉之后才暴露：
#
#   1. `--web-resources-cdn` 默认 **on**
#      → CanvasKit（整个渲染引擎）从 www.gstatic.com 取。
#        取不到就是**整页空白**，连一个错误提示都没有。
#        实测证据见 app/tool/analyze_netlog.py 的输出。
#      修法：加 `--no-web-resources-cdn`，bootstrap 里会出现 "useLocalCanvasKit":true。
#
#   2. 字体回退会去 fonts.gstatic.com 拉（连 roboto 都在那张表里）
#      → 修法在 pubspec.yaml 里（把 Roboto 族名指向已打包的子集），本脚本只做校验。
#
# 本脚本会把这两条都验一遍，验不过就报错退出——宁可构建失败，也不要产出白屏产物。
#
# 本机执行策略是 Restricted，调用方式：
#   powershell -ExecutionPolicy Bypass -File app\tool\build_web.ps1

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Split-Path -Parent $here
$web  = Join-Path $app 'build\web'

Write-Host ''
Write-Host '  灶记 · 构建 Web 产物' -ForegroundColor Cyan
Write-Host ''

# ── 0. 字体是否齐备 ────────────────────────────────────────────────
$fontDir = Join-Path $app 'assets\fonts'
$need = @('NotoSansSC-Regular.woff2', 'NotoSansSC-Medium.woff2', 'NotoSerifSC-Regular.woff2')
$miss = @()
foreach ($n in $need) { if (-not (Test-Path (Join-Path $fontDir $n))) { $miss += $n } }
if ($miss.Count -gt 0) {
  Write-Host '  ✘ 缺少子集字体：' -ForegroundColor Red
  foreach ($m in $miss) { Write-Host "      $m" }
  Write-Host ''
  Write-Host '  先补齐字体（源字体太大，不进仓库）：' -ForegroundColor Yellow
  Write-Host '      powershell -ExecutionPolicy Bypass -File app\tool\download_fonts.ps1'
  Write-Host '      python app\tool\build_fonts.py'
  Write-Host ''
  exit 1
}
$fontBytes = 0
foreach ($n in $need) { $fontBytes += (Get-Item (Join-Path $fontDir $n)).Length }
Write-Host ("  ✔ 子集字体齐备  {0} MB" -f [math]::Round($fontBytes / 1MB, 2)) -ForegroundColor Green

# ── 1. 构建 ────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  flutter build web --release --no-web-resources-cdn ...' -ForegroundColor DarkGray
Push-Location $app
# 本机的代理会把 flutter_tester / 本地连接也劫走，构建期一并清掉
$env:no_proxy = 'localhost,127.0.0.1,::1'; $env:NO_PROXY = 'localhost,127.0.0.1,::1'
$out = (& flutter build web --release --no-web-resources-cdn) 2>&1 | Out-String
$code = $LASTEXITCODE
Pop-Location
foreach ($l in ($out -split "`r?`n")) {
  if ($l -match 'Built|Error|error:|Failed|Compiling') { Write-Host ("    " + $l.Trim()) }
}
if ($code -ne 0) {
  Write-Host ("  ✘ 构建失败 exit=$code") -ForegroundColor Red
  exit $code
}

# ── 2. 校验：CanvasKit 必须走本地 ──────────────────────────────────
#
# 注意这里**不要**去搜 "gstatic.com/flutter-canvaskit" 这个字符串。
# 它永远都在——那是 flutter_bootstrap.js 里加载器自身的代码：
#     T=(i,e)=> i.canvasKitBaseUrl ? i.canvasKitBaseUrl
#                : e.engineRevision && !e.useLocalCanvasKit
#                  ? I("https://www.gstatic.com/flutter-canvaskit", e.engineRevision)
#                  : "canvaskit"
# 搜字符串会得到「永远失败」的检查，等于没有检查（第一版就是这么写错的）。
# 真正要断言的是**配置状态**：useLocalCanvasKit 必须为 true，
# 这样上面那个三元表达式才会走到本地的 "canvaskit" 分支。
$fb = Get-Content (Join-Path $web 'flutter_bootstrap.js') -Raw
$cfgMatch = [regex]::Match($fb, '_flutter\.buildConfig\s*=\s*(\{.*?\});')
if (-not $cfgMatch.Success) {
  Write-Host '  ✘ flutter_bootstrap.js 里找不到 _flutter.buildConfig' -ForegroundColor Red
  exit 2
}
try {
  $cfg = $cfgMatch.Groups[1].Value | ConvertFrom-Json
} catch {
  Write-Host '  ✘ buildConfig 不是合法 JSON' -ForegroundColor Red
  exit 2
}
if ($cfg.useLocalCanvasKit -eq $true) {
  Write-Host '  ✔ useLocalCanvasKit = true（CanvasKit 走本地 canvaskit/）' -ForegroundColor Green
} else {
  Write-Host '  ✘ buildConfig.useLocalCanvasKit 不是 true' -ForegroundColor Red
  Write-Host '    → 浏览器会去 www.gstatic.com 取 CanvasKit，断网时整页白屏。' -ForegroundColor Red
  Write-Host '    → 检查是否漏了 --no-web-resources-cdn。' -ForegroundColor Red
  exit 3
}
# 本地那份 canvaskit 必须真的在
$ck = Join-Path $web 'canvaskit\chromium\canvaskit.wasm'
if (Test-Path $ck) {
  Write-Host ("  ✔ 本地 canvaskit 存在  {0} MB" -f [math]::Round((Get-Item $ck).Length / 1MB, 2)) -ForegroundColor Green
} else {
  Write-Host '  ✘ 本地 canvaskit/chromium/canvaskit.wasm 不存在' -ForegroundColor Red
  exit 3
}

# ── 2.5 校验：Drift 的 Web 资产必须随产物带上 ──────────────────────
# 客户端本地库（R11 起）在 Web 上跑的是 sqlite3.wasm + drift_worker.js，
# 两者来自 `web/` 源目录（flutter build 会原样拷进产物）。
# 源文件从 pub 缓存的 drift 包里拷（drift 自带 drift_worker.js 与 devtools 里的 sqlite3.wasm），
# 缺了就是「App 首屏停在启动页且控制台报 fetch 失败」——离线自足清单的一部分。
foreach ($n in @('sqlite3.wasm', 'drift_worker.js')) {
  $src = Join-Path $app "web\$n"
  $dst2 = Join-Path $web $n
  if (-not (Test-Path $dst2)) {
    Write-Host ("  ✘ 产物缺 {0}（Web 端本地库起不来，App 会卡在启动页）" -f $n) -ForegroundColor Red
    if (-not (Test-Path $src)) {
      Write-Host ("    源文件 {0} 也不存在。" -f $src) -ForegroundColor Red
      Write-Host '    从 pub 缓存的 drift 包拷回：drift_worker.js 与 extension\devtools\build\sqlite3.wasm' -ForegroundColor Red
      exit 5
    }
    Copy-Item $src $dst2 -Force
    Write-Host ("    已从 web\ 源目录补回 {0}" -f $n) -ForegroundColor Yellow
  }
}
Write-Host '  ✔ Drift Web 资产在位（sqlite3.wasm + drift_worker.js）' -ForegroundColor Green

# ── 3. 校验：字体清单 ──────────────────────────────────────────────
$fmPath = Join-Path $web 'assets\FontManifest.json'
$fm = Get-Content $fmPath -Raw | ConvertFrom-Json
$families = @($fm | ForEach-Object { $_.family })
Write-Host ("  · FontManifest 家族： " + ($families -join ' / '))
foreach ($must in @('Noto Sans SC', 'Noto Serif SC', 'Roboto')) {
  if ($families -contains $must) {
    Write-Host ("  ✔ 已声明 $must") -ForegroundColor Green
  } else {
    Write-Host ("  ✘ 缺少字体族 $must —— 断网时这一类文字会变方块") -ForegroundColor Red
    exit 4
  }
}

# ── 4. 汇总 ────────────────────────────────────────────────────────
$all = Get-ChildItem $web -Recurse -File
$totalBytes = ($all | Measure-Object -Property Length -Sum).Sum
Write-Host ''
Write-Host ("  产物目录 = {0}" -f $web)
Write-Host ("  文件数   = {0}    总大小 = {1} MB" -f $all.Count, [math]::Round($totalBytes / 1MB, 2))
Write-Host '  ── 首屏实际会下载的大头 ──'
foreach ($n in @('main.dart.js', 'canvaskit\chromium\canvaskit.js', 'canvaskit\chromium\canvaskit.wasm',
                 'assets\assets\fonts\NotoSansSC-Regular.woff2', 'assets\assets\fonts\NotoSansSC-Medium.woff2',
                 'assets\assets\fonts\NotoSerifSC-Regular.woff2', 'sqlite3.wasm', 'drift_worker.js')) {
  $p = Join-Path $web $n
  if (Test-Path $p) {
    Write-Host ("    {0,-48} {1,7} MB" -f $n, [math]::Round((Get-Item $p).Length / 1MB, 2))
  }
}
Write-Host ''
Write-Host '  下一步：让服务端托管它（-w 指向上面这个目录），' -ForegroundColor Cyan
Write-Host '          然后用 app\tool\analyze_netlog.py 验一遍没有外部请求。'
Write-Host ''
exit 0
