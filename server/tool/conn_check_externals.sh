#!/usr/bin/env bash
# 外部服务连通性验证（只读 + 最小可撤销写入）。凭据一律从 .secrets/externals.local.env 读，
# 本脚本与输出都不落凭据。用法：bash server/tool/conn_check_externals.sh
set -u
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source .secrets/externals.local.env

ok()   { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; }
CURL=(curl.exe --noproxy '*' -sS --max-time 30)

echo "== 1. DeepSeek =="
echo "-- /v1/models --"
"${CURL[@]}" -o .secrets/_ds_models.json -w "http=%{http_code}\n" \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
  "$DEEPSEEK_BASE_URL/models" || fail "models 请求失败"
head -c 400 .secrets/_ds_models.json; echo

echo "-- chat 最小请求（model=$DEEPSEEK_MODEL） --"
chat() {
  local model="$1"
  "${CURL[@]}" -o .secrets/_ds_chat.json -w "http=%{http_code} time=%{time_total}s\n" \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"回复OK两个字母即可\"}],\"max_tokens\":8}" \
    "$DEEPSEEK_BASE_URL/chat/completions"
  head -c 300 .secrets/_ds_chat.json; echo
}
chat "$DEEPSEEK_MODEL"

echo "== 2. 缤纷云 S3 =="
BITIFUL_SIGN_REGION="${BITIFUL_SIGN_REGION:-us-east-1}"
echo "-- ListBuckets --"
"${CURL[@]}" --aws-sigv4 "aws:amz:$BITIFUL_SIGN_REGION:s3" \
  --user "$BITIFUL_S3_AK:$BITIFUL_S3_SK" \
  -o .secrets/_s3_list.xml -w "http=%{http_code}\n" "$BITIFUL_S3_ENDPOINT/" || fail "list 失败"
grep -o "<Name>[^<]*</Name>" .secrets/_s3_list.xml | head -5

echo "-- HEAD bucket/$BITIFUL_S3_BUCKET --"
"${CURL[@]}" -I --aws-sigv4 "aws:amz:$BITIFUL_SIGN_REGION:s3" \
  --user "$BITIFUL_S3_AK:$BITIFUL_S3_SK" \
  -w "http=%{http_code}\n" -o /dev/null "$BITIFUL_S3_ENDPOINT/$BITIFUL_S3_BUCKET"

echo "-- PUT/GET/DELETE 小对象 --"
echo "zaoji-conn-check" > .secrets/_s3_put_body.txt
"${CURL[@]}" -X PUT --aws-sigv4 "aws:amz:$BITIFUL_SIGN_REGION:s3" \
  --user "$BITIFUL_S3_AK:$BITIFUL_S3_SK" \
  -T .secrets/_s3_put_body.txt \
  -w "put http=%{http_code}\n" \
  "$BITIFUL_S3_ENDPOINT/$BITIFUL_S3_BUCKET/zaoji/_conn_check.txt"
"${CURL[@]}" --aws-sigv4 "aws:amz:$BITIFUL_SIGN_REGION:s3" \
  --user "$BITIFUL_S3_AK:$BITIFUL_S3_SK" \
  -w "get http=%{http_code}\n" \
  "$BITIFUL_S3_ENDPOINT/$BITIFUL_S3_BUCKET/zaoji/_conn_check.txt"
"${CURL[@]}" -X DELETE --aws-sigv4 "aws:amz:$BITIFUL_SIGN_REGION:s3" \
  --user "$BITIFUL_S3_AK:$BITIFUL_S3_SK" \
  -w "del http=%{http_code}\n" -o /dev/null \
  "$BITIFUL_S3_ENDPOINT/$BITIFUL_S3_BUCKET/zaoji/_conn_check.txt"

echo "== 3. 坚果云 WebDAV =="
echo "-- PROPFIND 根（depth 0） --"
"${CURL[@]}" -X PROPFIND -u "$JIANGUO_USER:$JIANGUO_PASS" \
  -H "Depth: 0" -o .secrets/_jg_prop.xml -w "http=%{http_code}\n" "$JIANGUO_DAV" || fail "propfind 失败"
head -c 200 .secrets/_jg_prop.xml; echo

echo "-- MKCOL + PUT + GET + DELETE 往返 --"
"${CURL[@]}" -X MKCOL -u "$JIANGUO_USER:$JIANGUO_PASS" \
  -w "mkcol http=%{http_code}\n" -o /dev/null "${JIANGUO_DAV}zaoji-backup-test" || true
echo "zaoji-conn-check" > .secrets/_jg_put_body.txt
"${CURL[@]}" -X PUT -u "$JIANGUO_USER:$JIANGUO_PASS" \
  -T .secrets/_jg_put_body.txt -w "put http=%{http_code}\n" \
  "${JIANGUO_DAV}zaoji-backup-test/_conn_check.txt"
"${CURL[@]}" -u "$JIANGUO_USER:$JIANGUO_PASS" \
  -w "get http=%{http_code}\n" \
  "${JIANGUO_DAV}zaoji-backup-test/_conn_check.txt"
"${CURL[@]}" -X DELETE -u "$JIANGUO_USER:$JIANGUO_PASS" \
  -w "del http=%{http_code}\n" -o /dev/null \
  "${JIANGUO_DAV}zaoji-backup-test/_conn_check.txt"
"${CURL[@]}" -X DELETE -u "$JIANGUO_USER:$JIANGUO_PASS" \
  -w "rmdir http=%{http_code}\n" -o /dev/null \
  "${JIANGUO_DAV}zaoji-backup-test"
echo "== 完成 =="
