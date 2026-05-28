#!/usr/bin/env bash
#
# Host setup for the media center stack.
# Run this once as root on a fresh VPS before deploying the containers.
#
# What it does:
#   - Installs rclone, lsof, fuse3
#   - Creates the download staging dirs and the R2 mount point
#   - Writes a systemd unit for the rclone mount
#   - Drops the upload cron script into /home/vps/
#   - Registers a 5-minute cron job for automated uploads
#

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root." >&2
    exit 1
fi

echo "--- media-center host setup ---"

# -- packages --
# fuse3 is needed for rclone mount's --allow-other flag.
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq rclone lsof fuse3 curl
elif command -v dnf &>/dev/null; then
    dnf install -y rclone lsof fuse3 curl
elif command -v yum &>/dev/null; then
    yum install -y rclone lsof fuse3 curl
else
    echo "Could not detect package manager. Install rclone, lsof, and fuse3 manually." >&2
    exit 1
fi

# fuse needs user_allow_other enabled or the containers won't be
# able to read the mount point.
FUSE_CONF="/etc/fuse.conf"
if ! grep -q "^user_allow_other" "$FUSE_CONF" 2>/dev/null; then
    echo "user_allow_other" >> "$FUSE_CONF"
fi

# -- directories --
mkdir -p /data/downloads/incomplete
mkdir -p /data/downloads/completed
mkdir -p /mnt/r2/media
mkdir -p /etc/rclone
mkdir -p /home/vps

# Let containers with UID 1000 write to the download dirs without fighting permissions.
chown -R 1000:1000 /data/downloads

# -- rclone config --
RCLONE_CONF="/etc/rclone/rclone.conf"

if [ ! -s "$RCLONE_CONF" ]; then
    cat > "$RCLONE_CONF" << 'RCLONE_EOF'
[r2]
type = s3
provider = Cloudflare
access_key_id =
secret_access_key =
endpoint =
acl = private
RCLONE_EOF

    chmod 600 "$RCLONE_CONF"
    echo ""
    echo "Wrote config template to $RCLONE_CONF"
    echo "Fill in your R2 credentials before starting the mount."
    echo "  access_key_id     = your R2 token access key"
    echo "  secret_access_key = your R2 token secret key"
    echo "  endpoint          = https://<account-id>.r2.cloudflarestorage.com"
    echo ""
else
    echo "Rclone config already exists at $RCLONE_CONF, skipping."
fi

# -- systemd mount service --
RCLONE_BIN="$(command -v rclone)"
UNIT_FILE="/etc/systemd/system/rclone-mount.service"

cat > "$UNIT_FILE" << EOF
[Unit]
Description=Mount Cloudflare R2 via rclone
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /mnt/r2/media
ExecStart=${RCLONE_BIN} mount r2:media /mnt/r2/media \\
    --config=${RCLONE_CONF} \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 2G \\
    --vfs-read-chunk-size 16M \\
    --allow-other \\
    --dir-cache-time 5m \\
    --poll-interval 1m
ExecStop=/bin/fusermount -uz /mnt/r2/media
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rclone-mount.service

echo "Registered rclone-mount.service (not started -- fill in creds first)."

# -- upload script --
UPLOAD_SCRIPT="/home/vps/upload-to-r2.sh"

cat > "$UPLOAD_SCRIPT" << 'SCRIPT_EOF'
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

# Make sure the R2 remote is actually reachable before we try to upload.
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

# Clean up empty subdirectories left behind, but never delete
# the completed dir itself -- JDownloader needs it to exist.
find "$COMPLETED_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

SCRIPT_EOF

chmod +x "$UPLOAD_SCRIPT"
echo "Wrote upload script to $UPLOAD_SCRIPT"

# -- cron job --
UPLOAD_CRON_LINE="*/5 * * * * $UPLOAD_SCRIPT"
BACKUP_CRON_LINE="0 4 * * * rclone --config /etc/rclone/rclone.conf sync /var/lib/docker/volumes/t11q38yan49mnb3myeo3wtfu_jellyfin-config/_data r2:media/backups/jellyfin-volume-full"

# Avoid duplicating the entries if this script is run more than once.
EXISTING="$(crontab -l 2>/dev/null || true)"

if echo "$EXISTING" | grep -qF "$UPLOAD_SCRIPT"; then
    echo "Upload cron job already registered, skipping."
else
    EXISTING="$(echo "$EXISTING"; echo "$UPLOAD_CRON_LINE")"
    echo "Registered 5-minute upload cron job."
fi

if echo "$EXISTING" | grep -qF "r2:media/backups/jellyfin-volume-full"; then
    echo "Backup cron job already registered, skipping."
else
    EXISTING="$(echo "$EXISTING"; echo "$BACKUP_CRON_LINE")"
    echo "Registered daily backup cron job."
fi

echo "$EXISTING" | crontab -

# -- logrotate --
# Prevent the upload log from growing indefinitely.
LOGROTATE_CONF="/etc/logrotate.d/rclone-upload"
cat > "$LOGROTATE_CONF" << 'EOF'
/var/log/upload-to-r2.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0644 root root
}
EOF
echo "Registered logrotate config for the upload script."

echo ""
echo "--- done ---"
echo "Next steps:"
echo "  1. Fill in your R2 credentials:  nano $RCLONE_CONF"
echo "  2. Start the mount:              systemctl start rclone-mount"
echo "  3. Deploy the docker stack"
