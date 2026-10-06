#!/usr/bin/env bash
# 带寄存器的那一层的变异：在 hwsrc/serdes_apb.v 上逐个埋错，tb_apb 每个都要红。埋了错还过，就是测试没有量到那一条。
# 用法：mut.sh <输出目录>
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
rm -rf "$O"
mkdir -p "$O"

# 名字、要改掉的那一句（sed 的表达式）、它对应的规矩
muts=(
  "inject~s/\.inject(l_inj)/.inject(1'b0)/~CMD 的第 0 位在线上翻一位"
  "clear~s/\.clear(l_clr)/.clear(1'b0)/~CMD 的第 1 位把计数清零"
  "loop~s/\.loopback(loop_s\[1\])/.loopback(1'b0)/~LOOP 让收端听自己的发端"
  "kbit~s/\.tx_k(tq\[8\])/.tx_k(1'b0)/~TX 的第 8 位是 K"
  "pop~s/\.rready(rd \&\& sel == 4'd5)/.rready(1'b0)/~读 RX 取走一个"
  "snap~s/h_perr    <= n_prbs_err;//~抓计数时把线路那一侧的值存下"
  "prxq~s/wire       rq_wvalid = rx_valid \&\& !prx_s\[1\];/wire       rq_wvalid = rx_valid;/~PRBS_RX 开着时字节不进收的队列"
  "over~s/else if (rq_wvalid \&\& !rq_wready) over <= 1'b1;//~收的队列满了记 RX_OVER"
  "ie~s/assign irq = ie \&\& rq_valid;/assign irq = rq_valid;/~没开 IE 不报中断"
  "en~s/lane_rst_n <= en_s\[1\];/lane_rst_n <= 1'b1;/~EN 为 0 时线路那一侧在复位里"
)

one() {
  local name=$1 expr=$2 d="$O/$1"
  mkdir -p "$d"
  sed "$expr" hwsrc/serdes_apb.v > "$d/serdes_apb.v"
  if [ -n "$expr" ] && cmp -s hwsrc/serdes_apb.v "$d/serdes_apb.v"; then
    echo "$name：这一句没改上" > "$d/run.log"
    return 2
  fi
  local src
  src=$(ls hwsrc/*.v | grep -v serdes_apb.v)
  iverilog -g2012 -Wno-timescale -o "$d/tb.vvp" -s tb_apb htest/tb_apb.v $src "$d/serdes_apb.v" > "$d/build.log" 2>&1 || { tail -n 5 "$d/build.log"; return 3; }
  vvp -n "$d/tb.vvp" > "$d/run.log" 2>&1 || true
  grep -q '^PASS tb_apb$' "$d/run.log"
}

fail=0
rc=0
one clean "" || rc=$?
grep -m1 '^PASS\|^FAIL' "$O/clean/run.log" || true
[ $rc = 0 ] || fail=1
for m in "${muts[@]}"; do
  IFS='~' read -r name expr what <<< "$m"
  rc=0
  one "$name" "$expr" || rc=$?
  case $rc in
    1) echo "$name 红了：$(grep -m1 FAIL "$O/$name/run.log")" ;;
    0) fail=1; echo "$name 埋了错还是过，测试没量到「$what」" ;;
    *) fail=1; echo "$name 没跑成（$rc）：$(tail -n 1 "$O/$name/run.log" 2>/dev/null)" ;;
  esac
done
if [ $fail = 0 ]; then echo "PASS mut：原样过，${#muts[@]} 处埋错都红"; else echo "FAIL mut"; exit 1; fi
