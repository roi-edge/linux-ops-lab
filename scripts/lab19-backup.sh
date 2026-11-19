#!/bin/bash
set -euo pipefail
cd /home/madrough/lab18
D=/data/backup/lab19; K=7; P='<MYSQL_ROOT_PASSWORD>'
F="$D/lab18db_$(date +%Y%m%d_%H%M%S).sql.gz"
L=/var/log/lab19-backup.log
mkdir -p "$D"
docker compose exec -T db mysqldump -uroot -p"$P" --single-transaction --databases lab18db 2>/dev/null | gzip > "$F"
chmod 600 "$F"; gzip -t "$F"
zcat "$F" | tail -3 | grep -q 'Dump completed'
echo "$(date '+%F %T') ok $(du -h "$F" | cut -f1) $F" >> "$L"
find "$D" -name 'lab18db_*.sql.gz' -mtime +$((K-1)) -print -delete >> "$L"
