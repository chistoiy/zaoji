# 下载 Noto CJK 源字体到 app/tool/font-cache/
#
# 为什么不用 Google Fonts 的 css2 接口：
#   用旧 UA 请求 `https://fonts.googleapis.com/css2?family=Noto+Sans+SC` 会拿到一个
#   `https://fonts.gstatic.com/l/font?kit=...` 直链，但它返回的文件**不是裸字体**——
#   实测头部是 [文件总长][载荷长][…] 这种 304 字节私有封装，真正的 sfnt 数据
#   从偏移 304（Serif 是 296）才开始。ttLib 直接拒收（bad sfntVersion）。
#   这是未公开格式，拿它当构建输入不可靠，所以改用 jsDelivr 上的官方 noto-cjk 仓库，
#   拿到的是干净的 OTTO。
#
# 为什么选 SubsetOTF 而不是 OTF：
#   `Sans/OTF/SimplifiedChinese/` 是全量 pan-CJK（含日韩台字形），每个约 16 MB；
#   `Sans/SubsetOTF/SC/` 只含简体所需字形，约 8 MB，够用且省一半。
#   反正后面还要按 profile 子集化，源文件小一点对构建速度也有好处。
#
# 本机执行策略是 Restricted，调用方式：
#   powershell -ExecutionPolicy Bypass -File app\tool\download_fonts.ps1

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$cache = Join-Path $here 'font-cache'
if (-not (Test-Path $cache)) { New-Item -ItemType Directory -Path $cache -Force | Out-Null }

$base = 'https://cdn.jsdelivr.net/gh/googlefonts/noto-cjk@main'
$files = @(
  @{ name = 'NotoSansSC-Regular.otf';  url = "$base/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf" },
  @{ name = 'NotoSansSC-Medium.otf';   url = "$base/Sans/SubsetOTF/SC/NotoSansSC-Medium.otf" },
  @{ name = 'NotoSerifSC-Regular.otf'; url = "$base/Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf" }
)

Write-Host ''
Write-Host '  灶记 · 下载 Noto CJK 源字体' -ForegroundColor Cyan
Write-Host ''

$failed = @()
foreach ($f in $files) {
  $out = Join-Path $cache $f.name
  if (Test-Path $out) {
    $sz = [math]::Round((Get-Item $out).Length / 1MB, 2)
    Write-Host ("  已存在，跳过  {0}  ({1} MB)" -f $f.name, $sz) -ForegroundColor DarkGray
    continue
  }
  $r = & curl.exe -sL --max-time 240 -o $out -w "%{http_code} %{size_download}" $f.url 2>&1 | Out-String
  $code = ($r.Trim() -split '\s+')[0]
  if ($code -ne '200' -or -not (Test-Path $out)) {
    Write-Host ("  ✘ 下载失败    {0}  (HTTP {1})" -f $f.name, $code) -ForegroundColor Red
    $failed += $f.name
    continue
  }
  # 必须校验magic：OTTO = CFF/OpenType。上面那段注释说的就是「看起来下成功了其实不是字体」。
  $b = [System.IO.File]::ReadAllBytes($out)
  $magic = ($b[0..3] | ForEach-Object { $_.ToString('X2') }) -join ' '
  $ok = ($magic -eq '4F 54 54 4F')
  $sz = [math]::Round($b.Length / 1MB, 2)
  if ($ok) {
    Write-Host ("  ✔ {0}  {1} MB  magic={2}" -f $f.name, $sz, $magic) -ForegroundColor Green
  } else {
    Write-Host ("  ✘ {0}  文件头不是 OTTO（得到 {1}），已删除" -f $f.name, $magic) -ForegroundColor Red
    [System.IO.File]::Delete($out)
    $failed += $f.name
  }
}

Write-Host ''
if ($failed.Count -gt 0) {
  Write-Host ("  有 {0} 个文件失败：{1}" -f $failed.Count, ($failed -join ', ')) -ForegroundColor Red
  exit 1
}
Write-Host '  源字体齐备。下一步：' -ForegroundColor Cyan
Write-Host '    python app\tool\build_fonts.py --profile gbk'
Write-Host ''
exit 0
