#!/usr/bin/env bash
# 给**正在跑的本机服务端**（127.0.0.1:8666）配上两处远端备份通道并手动跑一次。
#
# 凭据只从 gitignored 的 `.secrets/externals.local.env` 读：脚本本身不含任何密钥，
# 服务端接口只回掩码，所以这段输出里不会出现明文。
# 用法：bash server/tool/configure_backups_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source .secrets/externals.local.env

body=$(cat <<JSON
{
  "enabled": true,
  "intervalHours": 24,
  "includeMedia": true,
  "webdavUrl": "$JIANGUO_DAV",
  "webdavUser": "$JIANGUO_USER",
  "webdavPass": "$JIANGUO_PASS",
  "s3Endpoint": "https://s3.bitiful.net",
  "s3Bucket": "$BITIFUL_S3_BUCKET",
  "s3Region": "auto",
  "s3Ak": "$BITIFUL_S3_AK",
  "s3Sk": "$BITIFUL_S3_SK",
  "s3Prefix": "zaoji-backups/"
}
JSON
)

echo '-> POST /api/admin/backup/config（写配置，回显只到掩码）'
curl.exe --noproxy '*' -s -X POST http://127.0.0.1:8666/api/admin/backup/config \
  -H 'content-type: application/json' --data-binary "$body"
echo

echo '-> POST /api/admin/backup（手动跑一次备份）'
curl.exe --noproxy '*' -s -X POST http://127.0.0.1:8666/api/admin/backup \
  -H 'content-type: application/json' --data-binary '{}'
echo

echo '-> GET /api/admin/backup（当前状态）'
curl.exe --noproxy '*' -s http://127.0.0.1:8666/api/admin/backup
echo
