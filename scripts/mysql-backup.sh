#!/usr/bin/env bash
set -euo pipefail
DIR=${DIR:-/data/backup/mysql}; DAYS=${DAYS:-7}; DB=${DB:-labdb}
LOG=/var/log/mysql-backup.log; E=$(mktemp)
F="$DIR/${DB}_$(date +%Y%m%d_%H%M%S).sql.gz"
say(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
trap 'rm -f "$E"' EXIT
mkdir -p "$DIR"; say "start $DB"
mysqldump --defaults-extra-file=/etc/mysql/backup.cnf --single-transaction --quick \
  --routines --triggers --events --no-tablespaces --databases "$DB" 2>"$E" | gzip -9 >"$F"
if grep -qi error "$E"; then say "FAIL: $(tr '\n' ' ' <"$E")"; rm -f "$F"; exit 1; fi
chmod 600 "$F"; gzip -t "$F"
if ! zcat "$F" | tail -3 | grep -q 'Dump completed'; then say "FAIL: incomplete"; rm -f "$F"; exit 1; fi
say "ok $(du -h "$F" | cut -f1)"
find "$DIR" -maxdepth 1 -name "${DB}_*.sql.gz" -mtime +$((DAYS-1)) -print -delete | while read -r x; do say "del $(basename "$x")"; done
say "done, keep $(find "$DIR" -name "${DB}_*.sql.gz" | wc -l)"
