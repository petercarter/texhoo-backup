#!/bin/bash
# Backup for SQLite-based apps on Texhoo (Vikunja, Homebox, Karakeep)
# Runs INSIDE the texhoo-backup container, triggered by Ofelia (job-exec, as root).
# Host location:  /home/peter/docker/backup/backup-sqlite-app.sh
#
# Usage: backup-sqlite-app.sh <app> [keep_days]
#   Source:  /apps/<app>      (the app's data, mounted from the host)
#   Output:  /backups/<app>   (-> /home/peter/docker/bufiles/<app>)
#
# Every SQLite database found under the source is copied with SQLite's online
# .backup command (safe while the app is running) and integrity-checked.
# Everything else (attachments, photos, assets) is archived as-is.
# Result: one <app>_<timestamp>.tar.gz per run.
set -euo pipefail
umask 007

APP="${1:?usage: backup-sqlite-app.sh <app> [keep_days]}"
KEEP_DAYS="${2:-14}"
SRC="/apps/$APP"
BACKUP_DIR="/backups/$APP"
OWNER="1000:1000"       # peter, so files can be managed/synced from the host
MIN_BYTES=4096
LOG="$BACKUP_DIR/$APP-backup.log"

mkdir -p "$BACKUP_DIR"
chown "$OWNER" "$BACKUP_DIR"

# Truncate the log if it grows past 10 MB
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt $((10*1024*1024)) ] && : > "$LOG"

WORK=""
log(){ printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG"; }
cleanup(){
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
    rm -f "$BACKUP_DIR"/*.partial
    chown "$OWNER" "$LOG" 2>/dev/null || true
}
trap cleanup EXIT
die(){ code="$1"; shift; log "ERROR: $*"; log "FAILED (rc=${code})"; exit "$code"; }

TS="$(date +%F_%H%M%S)"
OUT="$BACKUP_DIR/${APP}_${TS}.tar.gz"
TAR="$BACKUP_DIR/${APP}_${TS}.tar.partial"
START="$(date +%s)"

[ -d "$SRC" ] || die 2 "$SRC is not mounted"
rm -f "$BACKUP_DIR"/*.partial

WORK="$(mktemp -d)"
chmod 1777 "$WORK"
log "Start backup of $APP -> $(basename "$OUT")"

# ---- 1. SQLite databases (online backup + integrity check) ------------------
# sqlite3 runs as the database file's owner, so any -wal/-shm files it touches
# keep the ownership the app expects.
DB_COUNT=0
while IFS= read -r -d '' db; do
    rel="${db#"$SRC"/}"
    owner="$(stat -c '%u:%g' "$db")"
    su-exec "$owner" mkdir -p "$WORK/$(dirname "$rel")"
    su-exec "$owner" sqlite3 -cmd ".timeout 20000" "$db" ".backup '$WORK/$rel'" 2>>"$LOG" \
        || die 3 "SQLite backup failed for $rel"
    res="$(sqlite3 "$WORK/$rel" 'PRAGMA integrity_check;' 2>>"$LOG" || true)"
    [ "$res" = "ok" ] || die 4 "integrity check failed for $rel: $res"
    log "Database $rel copied and checked ($(du -h "$WORK/$rel" | cut -f1))"
    DB_COUNT=$((DB_COUNT + 1))
done < <(find "$SRC" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)

[ "$DB_COUNT" -gt 0 ] || die 5 "no SQLite database found under $SRC"

# ---- 2. Archive: other files as-is, plus the database copies ----------------
# GNU tar exits 1 if a file changed while being read (normal for a live app);
# only higher codes are real errors.
set +e
tar -cf "$TAR" -C "$SRC" --warning=no-file-changed \
    --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.db-journal' \
    --exclude='*.sqlite' --exclude='*.sqlite-*' --exclude='*.sqlite3' --exclude='*.sqlite3-*' \
    . 2>>"$LOG"
rc=$?
set -e
[ "$rc" -le 1 ] || die 6 "archiving files failed (tar rc=$rc)"

tar -rf "$TAR" -C "$WORK" . 2>>"$LOG" || die 7 "adding database copies to archive failed"

gzip -c "$TAR" > "$OUT.partial" || die 8 "gzip failed"
rm -f "$TAR"
gzip -t "$OUT.partial" 2>>"$LOG" || die 9 "gzip integrity test FAILED"

SIZE="$(stat -c %s "$OUT.partial")"
[ "$SIZE" -ge "$MIN_BYTES" ] || die 10 "archive too small (${SIZE} bytes)"

mv "$OUT.partial" "$OUT"
chown "$OWNER" "$OUT"
log "Created $(basename "$OUT") size=$(du -h "$OUT" | cut -f1) (${SIZE} bytes, ${DB_COUNT} database(s))"

# ---- 3. Retention -----------------------------------------------------------
PRUNED="$(find "$BACKUP_DIR" -type f -name "${APP}_*.tar.gz" \
    -mtime +$((KEEP_DAYS - 1)) -print -delete | wc -l | tr -d ' ')"
log "Pruned ${PRUNED} old backup(s)"

log "SUCCESS in $(( $(date +%s) - START ))s"
exit 0
