#!/bin/sh
# 极简巡检：磁盘 / 内存 / 负载 / 服务
set -u

echo "=== 巡检 $(date -u '+%Y-%m-%d %H:%M:%S') UTC ==="
echo "主机: $(hostname)"
echo
echo "--- 磁盘 ---"
df -h / 2>/dev/null | tail -n +2
[ -d /data ] && df -h /data 2>/dev/null | tail -n +2
echo
echo "--- 内存 ---"
free -m 2>/dev/null | awk '/Mem:/ {printf "total=%sMB used=%sMB avail=%sMB\n", $2,$3,$7}'
echo
echo "--- 负载 ---"
awk '{printf "load: %s %s %s\n", $1,$2,$3}' /proc/loadavg 2>/dev/null
echo
echo "--- 服务 ---"
if command -v systemctl >/dev/null 2>&1; then
  for s in nginx mysql dnsmasq ssh cron; do
    printf '  %-8s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null | head -n 1)"
  done
else
  echo "  (无 systemctl：容器内看不到宿主机的 systemd)"
fi
