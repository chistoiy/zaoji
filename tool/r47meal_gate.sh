#!/bin/sh
# R47 第六段门禁：三处 analyze + 三套全量测试，**串行**（本轮定过：门禁不并发）。
# 用法：sh tool/r47meal_gate.sh   （进度里程碑直接打在 stdout，全量输出进 dist/r47meal_gate.log）
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG="$ROOT/dist/r47meal_gate.log"
: > "$LOG"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export no_proxy='localhost,127.0.0.1,::1' NO_PROXY='localhost,127.0.0.1,::1'

milestone() { echo "── $(date +%H:%M:%S) $*" | tee -a "$LOG"; }

for pkg in shared server app; do
  cd "$ROOT/$pkg"
  milestone "[$pkg] analyze 开始"
  flutter analyze 2>&1 | tail -3 | tee -a "$LOG"
  milestone "[$pkg] 全量 test 开始"
  flutter test 2>&1 | grep -E "All tests passed|Some tests failed|[0-9]+ -[0-9]+|Failed to load" | tail -5 | tee -a "$LOG"
  milestone "[$pkg] 全量 test 结束"
done
milestone "门禁跑完：日志见 dist/r47meal_gate.log"
