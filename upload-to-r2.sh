#!/usr/bin/env bash
#
# Called by cron every 5 minutes.
# Moves finished downloads from the local staging dir to Cloudflare R2,
# but only after confirming nothing is still writing to them.
#

set -euo pipefail

COMPLETED_DIR="/data/downloads/completed"
RCLONE_CONF="/etc/rclone/rclone.conf"
R2_REMOTE="r2:media"
LOG="/var/log/upload-to-r2.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"; }

# Bail early if the completed dir is empty or missing.
if [ ! -d "$COMPLETED_DIR" ] || [ -z "$(ls -A "$COMPLETED_DIR" 2>/dev/null)" ]; then
    exit 0
fi

# Make sure the R2 mount is actually alive before we try to upload.
# rclone lsd will fail fast if the remote is misconfigured or unreachable.
if ! rclone lsd "$R2_REMOTE" --config="$RCLONE_CONF" &>/dev/null; then
    log "ERROR: cannot reach R2 remote. Check rclone config and network."
    exit 1
fi

# Build an exclude list for files that are still being written to.
EXCLUDES="$(mktemp)"
trap 'rm -f "$EXCLUDES"' EXIT

while IFS= read -r -d '' file; do
    rel="${file#"$COMPLETED_DIR"/}"

    # Skip files that any process still has open.
    if lsof -- "$file" &>/dev/null; then
        echo "$rel" >> "$EXCLUDES"
        log "SKIP (locked): $rel"
        continue
    fi

    # Quick size-stability check. If the file is still growing,
    # something is probably extracting or copying into it.
    s1="$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null)"
    sleep 2
    s2="$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null)"

    if [ "$s1" != "$s2" ]; then
        echo "$rel" >> "$EXCLUDES"
        log "SKIP (growing): $rel"
        continue
    fi

done < <(find "$COMPLETED_DIR" -type f -print0)

# Move everything that passed the checks to R2.
rclone move "$COMPLETED_DIR" "$R2_REMOTE" \
    --config="$RCLONE_CONF" \
    --exclude-from "$EXCLUDES" \
    --transfers 4 \
    --checkers 8 \
    --fast-list \
    --log-file="$LOG" \
    --log-level INFO

# Clean up empty subdirectories left behind after the move,
# but never delete /data/downloads/completed itself.
# JDownloader is configured to drop finished files here, and it
# will error out if this directory disappears between runs.
find "$COMPLETED_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
