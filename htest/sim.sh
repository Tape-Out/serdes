#!/usr/bin/env bash
# 四个自测台：码表的穷举核对，接收端逐个符号的定向核对，两条通道带频偏、带抖动的对接，带寄存器的通道经总线自环与对接。
# 用法：sim.sh <输出目录>
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
rm -rf "$O"
mkdir -p "$O"
rc=0
for t in tb_code tb_rx tb_lane tb_apb; do
  # 测试台排在前面：它的 `timescale 顺着编译次序带给后面没写的 RTL 文件（所以关掉这一类提示）。其余告警一律当错
  iverilog -g2012 -Wall -Wno-timescale -o "$O/$t.vvp" -s "$t" "htest/$t.v" hwsrc/*.v 2> "$O/$t.build.log" || { cat "$O/$t.build.log"; exit 1; }
  if grep -q 'warning' "$O/$t.build.log"; then cat "$O/$t.build.log"; exit 1; fi
  vvp -n "$O/$t.vvp" | tee "$O/$t.log"
  # $finish 的退出码恒为 0，判据是日志里的那一行
  grep -q "^PASS $t\$" "$O/$t.log" || rc=1
done
[ $rc = 0 ] && echo "serdes 四个自测台全过" || { echo "有自测台没过"; exit 1; }
