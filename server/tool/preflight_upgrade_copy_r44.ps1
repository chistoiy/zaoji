# R44 pre-swap rehearsal: run the NEW server exe against a COPY of the data
# directory, on ports that avoid the live instance, and prove that
#   - schema really migrates to v8 (meta.schema_version = 8)
#   - the two new serverOnly tables (ai_prompts / ai_runs) exist, and ai_usage
#     gained run_ref/summary on the client-shaped path too
#   - the new /api/ai/runs* and /api/ai/prompts* routes answer (old exe = HTML 404)
#   - nothing above touches the live data directory
#
# Usage (this machine is Restricted, -ExecutionPolicy Bypass is mandatory):
#   powershell -ExecutionPolicy Bypass -File server\tool\preflight_upgrade_copy_r44.ps1
#
# Same three parameter traps as the R43 script (all verified against the source):
#   1) there is NO --no-tls switch: the server always binds HTTP + HTTPS, and an
#      unknown argument exits(64) -> pass a real --tls-port instead of guessing
#   2) omitting --tls-port uses 8667, which the live instance already owns
#   3) point -d at the COPY explicitly: baseDir() is the folder of the EXE, so a
#      bare run would grow logs/ next to the exe and could even open the real db
#
# ASCII-only on purpose: PowerShell 5.1 mis-parses BOM-less UTF-8.
# SQLite readings go through server\tool\r44_db_probe.py, never an inline here-string.

param(
  [string]$Src = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data'),
  [string]$NewExe = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'dist\zaoji_server_v0.16.0.exe'),
  [int]$Port = 8899,
  [int]$TlsPort = 8900
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Say($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$repoServer = Join-Path $repoRoot 'server'
$probe = Join-Path $PSScriptRoot 'r44_db_probe.py'
# python on PATH can be the WindowsApps stub (zero output, rc 49) - use the real one
$pyExe = 'D:\app_workplace\python3.11\python.exe'
if (-not (Test-Path $pyExe)) { throw "python not found at $pyExe" }
if (-not (Test-Path $probe)) { throw "probe not found at $probe" }

function Probe([string]$db) { return ((& $pyExe $probe $db 2>&1) | Select-Object -Last 1) }

$tmp = Join-Path $env:TEMP ("zaoji_preflight_r44_" + (Get-Date -Format 'yyyyMMdd-HHmmss'))

Write-Host ''
Write-Host '-- R44 rehearsal: new exe opens a COPY of the database' -ForegroundColor Cyan
Say "source data   $Src"
Say "copy dir      $tmp"
Say "new exe       $NewExe"
Say "ports         http $Port / https $TlsPort (live instance keeps 8666/8667)"
if (-not (Test-Path $Src)) { throw "source data dir missing: $Src" }
if (-not (Test-Path $NewExe)) { throw "new exe missing: $NewExe" }

# 1) copy db + media + logs, then compare total bytes (a partial copy rehearses nothing)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Copy-Item -Path $Src -Destination (Join-Path $tmp 'data') -Recurse -Force
$srcBytes = (Get-ChildItem $Src -Recurse -File | Measure-Object -Property Length -Sum).Sum
$tmpBytes = (Get-ChildItem (Join-Path $tmp 'data') -Recurse -File | Measure-Object -Property Length -Sum).Sum
Say "copy check    source $srcBytes B / copy $tmpBytes B"
if ($srcBytes -ne $tmpBytes) { throw 'copy size differs, rehearsal invalid' }
$dbCopy = Join-Path $tmp 'data\zaoji.db'
if (-not (Test-Path $dbCopy)) { throw "no zaoji.db in the copy: $dbCopy" }
Say ("before        " + (Probe $dbCopy))

# stale -wal/-shm from the LIVE instance would replay into the copy; drop them
Get-ChildItem (Join-Path $tmp 'data') -Filter 'zaoji.db-*' | Remove-Item -Force -ErrorAction SilentlyContinue

# 2) bring the new exe up ON THE COPY
$certsSrc = Join-Path $repoServer 'certs'
if (Test-Path $certsSrc) { Copy-Item $certsSrc (Join-Path $tmp 'certs') -Recurse -Force }
$argList = @('-p', "$Port", '--tls-port', "$TlsPort",
  '-d', (Join-Path $tmp 'data'),
  '--log', (Join-Path $tmp 'logs'),
  '-c', (Join-Path $tmp 'certs'))
$p = Start-Process -FilePath $NewExe -ArgumentList $argList `
  -WorkingDirectory $tmp -PassThru -WindowStyle Hidden
Say "started       pid $($p.Id)"

$fail = $null
try {
  # 3) poll the status page until it reports a schema version (max 40s)
  $schema = $null
  $page = ''
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    try {
      $page = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/status" -UseBasicParsing -TimeoutSec 4).Content
      if ($page -match 'schema v(\d+)') { $schema = [int]$Matches[1]; break }
    } catch { }
  }
  if (-not $schema) { throw 'status page gave no schema version (server may not be up; read logs in the copy dir)' }
  Say "schema after  v$schema"
  if ($schema -ne 8) { throw "expected schema v8, got v$schema" }

  if ($page -match 'v0\.16\.0') { Say 'version       status page shows v0.16.0' } else { Warn 'status page does not show v0.16.0 - check the header by eye' }

  # 4) the new routes answer. 200/401 = routed; 404 = still the old exe.
  foreach ($path in @('/api/ai/runs', '/api/ai/prompts')) {
    $code = 0
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port$path" -UseBasicParsing -TimeoutSec 5
      $code = [int]$r.StatusCode
    } catch { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } }
    Say ("GET {0,-18} -> HTTP {1}" -f $path, $code)
    if ($code -eq 0 -or $code -eq 404) { throw "$path unreachable or 404" }
  }

  # 5) DELETE must be routed too: clear-all is a body-less DELETE with query filters
  $code = 0
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/ai/runs?feature=__none__" -Method Delete -UseBasicParsing -TimeoutSec 5
    $code = [int]$r.StatusCode
  } catch { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } }
  Say ("DELETE /api/ai/runs   -> HTTP {0}" -f $code)
  if ($code -eq 0 -or $code -eq 404) { throw 'DELETE /api/ai/runs not routed' }

  # 6) a sync pull against the copy must not crash and must not mention the new tables
  for ($i = 0; $i -lt 6; $i++) {
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/changes?since=0" -Headers @{ 'X-Node-Id' = 'preflight' } -UseBasicParsing -TimeoutSec 5 | Out-Null; break } catch { Start-Sleep -Seconds 1 }
  }
  $log = Join-Path $tmp 'logs\zaoji.log'
  if (Test-Path $log) {
    $txt = Get-Content $log -Raw -Encoding UTF8
    if ($txt -match 'ai_prompts|ai_runs') { Warn 'server log mentions the new tables - confirm they are not being synced' }
    if ($txt -match 'Uncaught|Unhandled|SEVERE|errno=7') { Warn 'server log carries crash-ish lines - read it before swapping' }
    Say "log           $log"
  } else { Warn "server log not found: $log" }
} catch { $fail = $_ }
finally {
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
}
if ($fail) { Write-Host "`nREHEARSAL FAILED: $fail" -ForegroundColor Red; throw $fail }

# 7) after shutdown the db handle is free: prove the tables/columns really landed
Say ("after         " + (Probe $dbCopy))
$post = Probe $dbCopy
if ($post -notmatch "ai_prompts") { throw 'ai_prompts missing in the migrated copy' }
if ($post -notmatch "ai_runs") { throw 'ai_runs missing in the migrated copy' }
if ($post -notmatch "run_ref") { throw 'ai_usage.run_ref missing in the migrated copy' }
if ($post -notmatch "synced=none") { Warn "synced tables mention new rows: $post" }

Write-Host "`nREHEARSAL PASSED - schema v8, ai routes live, serverOnly tables in place" -ForegroundColor Green
Write-Host "copy kept for inspection: $tmp"
