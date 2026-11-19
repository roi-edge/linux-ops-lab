#!/bin/bash
# lab21 巡检：磁盘/内存/负载/服务；超阈值标红；退出码 0=OK 1=WARN 2=CRIT
set -uo pipefail
W=0; C=0
g=$'\033[32m'; y=$'\033[33m'; r=$'\033[31m'; n=$'\033[0m'

check() {  # 名称 当前值 警告阈值 严重阈值 单位
  if awk "BEGIN{exit !($2 >= $4)}"; then
    printf '%sCRIT%s %-6s %s%s\n' "$r" "$n" "$1" "$2" "$5"; C=$((C+1))
  elif awk "BEGIN{exit !($2 >= $3)}"; then
    printf '%sWARN%s %-6s %s%s\n' "$y" "$n" "$1" "$2" "$5"; W=$((W+1))
  else
    printf '%sOK%s   %-6s %s%s\n' "$g" "$n" "$1" "$2" "$5"
  fi
}

DISK=$(df --output=pcent / | tail -1 | tr -dc '0-9')
MEM=$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
L1=$(awk '{print $1}' /proc/loadavg); N=$(nproc)
LOAD=$(awk -v l="$L1" -v c="$N" 'BEGIN{printf "%.0f", l/c*100}')

echo "=== $(hostname) $(date '+%F %T') ==="
check 磁盘 "$DISK" "${DW:-80}" "${DC:-90}" '%'
check 内存 "$MEM" 85 95 '%'
check 负载 "$LOAD" 100 200 "%(L1=$L1/${N}核)"

for s in nginx mysql dnsmasq ssh cron ufw; do
  st=$(systemctl is-active "$s" 2>/dev/null | head -1)
  [ "$st" = active ] && continue
  printf '%sCRIT%s %-6s %s\n' "$r" "$n" "$s" "${st:-unknown}"; C=$((C+1))
done

echo "--- WARN=$W CRIT=$C ---"
[ "$C" -gt 0 ] && exit 2
[ "$W" -gt 0 ] && exit 1
exit 0
