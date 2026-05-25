# my-media-server

A self-hosted media center that keeps nothing on disk. Downloads land on a local SSD staging area, get automatically pushed to Cloudflare R2, and Jellyfin streams everything back through an rclone mount. The whole thing runs on a cheap VPS (4GB RAM, 2 CPU) alongside your existing sites via Coolify.

I built this because I was tired of running out of disk space on small VPS instances. R2's free egress and S3-compatible API made it a natural fit for media storage, and rclone's VFS caching makes streaming from it surprisingly smooth.

## What's in the box

| Component | Role |
|-----------|------|
| **Rclone** | Mounts R2 as a local filesystem on the host |
| **Gluetun** | VPN tunnel for download traffic (NordVPN, ProtonVPN, Mullvad, etc.) |
| **JDownloader 2** | Grabs files from direct download hosts, routed through the VPN |
| **Jellyfin** | Streams media to your devices from the R2 mount |
| **Bazarr** | Finds and downloads `.srt` subtitles into the media library |

## How it works

```
JDownloader -> /data/downloads/incomplete (active downloads)
                       |
                       v  (on completion / extraction)
               /data/downloads/completed
                       |
                       v  (cron, every 5 min, with lock checks)
               rclone move -> Cloudflare R2
                       |
                       v  (rclone mount, read by Jellyfin)
               /mnt/r2/media
```

Downloads go through a two-stage pipeline. JDownloader writes active chunks to `incomplete/`, then moves finished files to `completed/`. A cron script checks `completed/` every 5 minutes, verifies nothing is still writing to the files (using `lsof` and a size-stability check), and moves them to R2. After the move, it cleans up empty subdirectories but always preserves the `completed/` root so JDownloader doesn't break.

## Prerequisites

- A Linux VPS with root access (tested on Ubuntu 22.04 / Debian 12)
- Docker and Docker Compose (Coolify handles this for you)
- A Cloudflare account with an R2 bucket

## Setup

### 1. Create your R2 bucket

In the Cloudflare dashboard:
1. Go to R2 Object Storage and create a bucket. Name it `media` (or whatever you want, just update the rclone config to match).
2. Go to Manage R2 API Tokens and create a token with read/write permissions on the bucket.
3. Note down the **Access Key ID**, **Secret Access Key**, and your **Account ID** (visible in the URL or the API token page).

### 2. Run the host setup

SSH into your VPS and run:

```bash
git clone https://github.com/your-username/my-media-server.git
cd my-media-server
chmod +x setup.sh
sudo ./setup.sh
```

This installs `rclone`, `lsof`, and `fuse3`, creates the directory structure, writes a systemd unit for the rclone mount, drops the upload cron script into `/home/vps/`, and registers the 5-minute cron job.

### 3. Configure rclone credentials

```bash
sudo nano /etc/rclone/rclone.conf
```

Fill in your R2 details:

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = your_access_key
secret_access_key = your_secret_key
endpoint = https://your-account-id.r2.cloudflarestorage.com
acl = private
```

Then start the mount:

```bash
sudo systemctl start rclone-mount
sudo systemctl status rclone-mount
```

Verify it's working:

```bash
ls /mnt/r2/media
```

### 4. Deploy the container stack

Copy the env template and fill it in:

```bash
cp .env.example .env
nano .env
```

If you're deploying through **Coolify**:
1. Create a new project and select Docker Compose as the build method.
2. Point it at this repo (or paste the `docker-compose.yml` contents).
3. Add your `.env` values in Coolify's environment variables panel.
4. Deploy.

If you're running it directly:

```bash
docker compose up -d
```

### 5. Set up domain routing (Coolify)

In Coolify's service settings, map your domains:

| Service | Internal Port | Domain |
|---------|---------------|--------|
| Jellyfin | 8096 | `jellyfin.yourdomain.com` |
| Bazarr | 6767 | `bazarr.yourdomain.com` |
| JDownloader | 5800 | `jdownloader.yourdomain.com` |

Coolify handles the reverse proxy and SSL certificates automatically.

### 6. Configure JDownloader's two-folder pipeline

Once JDownloader is running, open its web UI and configure:

1. Go to **Settings > General** and set the default download folder to `/output/incomplete`.
2. Go to **Settings > Archive Extractor** and set the extraction output to `/output/completed`.
3. Go to **Settings > Packagizer** or use the Move Rules to set up an automatic move-on-completion rule from `/output/incomplete` to `/output/completed`.

This separation keeps partially downloaded files from being picked up by the upload script.

### 7. Configure Bazarr

1. Open Bazarr's web UI.
2. Under **Settings > Subtitles**, configure your preferred subtitle providers (OpenSubtitles, Addic7ed, etc.).
3. Under **Settings > Languages**, add your languages and make sure the subtitle format is set to **SRT**. Avoid ASS/SSA/PGS formats -- they trigger transcoding on most Smart TVs.
4. Connect Bazarr to Jellyfin under **Settings > Jellyfin** using Jellyfin's local URL (`http://jellyfin:8096` from within the Docker network, or `http://host-ip:8096`).
5. Map the media root so Bazarr sees the same `/media` path that Jellyfin uses.

## Disabling transcoding (important for low-resource VPS)

This is the part most people miss. If you leave transcoding enabled, a single stream can peg both CPUs on a 2-core VPS and tank everything else running on the machine.

In **Jellyfin's admin dashboard**:

1. Go to **Dashboard > Users**.
2. Edit each user profile.
3. Under **Media Playback**, uncheck:
   - **Allow video transcoding**
   - **Allow audio transcoding**
4. Save.

This forces all clients to direct play, which means Jellyfin just serves the file as-is with zero CPU overhead. The trade-off is that your media files need to be in formats your devices can natively decode. Most Smart TVs from the last few years handle H.264/H.265 in MKV or MP4 containers without issues.

For subtitles specifically: text-based `.srt` files are rendered client-side on Smart TVs. Image-based subtitle formats (PGS, VobSub) require the server to burn them into the video stream, which is transcoding. That's why Bazarr is configured to only fetch `.srt` files.

## VPN IP rotation

When a filehost like PixelDrain hits you with a download limit or IP block, you need a fresh IP. There are two ways to do this.

### Restart the container

The fastest way. Gluetun reconnects to a different server on startup:

```bash
docker restart gluetun
```

JDownloader will briefly lose connectivity and resume automatically once the tunnel is back up.

### Use the Gluetun control API

For scripting or more control, Gluetun exposes an HTTP API on port 8000 (bound to localhost for security):

Check current VPN status and public IP:
```bash
curl -s http://localhost:8000/v1/vpn/status | jq .
```

Cycle the connection (stop, wait, start):
```bash
curl -s -X PUT -H "Content-Type: application/json" \
  -d '{"status":"stopped"}' http://localhost:8000/v1/vpn/status

sleep 3

curl -s -X PUT -H "Content-Type: application/json" \
  -d '{"status":"running"}' http://localhost:8000/v1/vpn/status
```

You could wrap this in a script that JDownloader calls on download failure, or just run it manually when you notice downloads stalling.

### Picking a different country

Update the `VPN_COUNTRIES` variable in your `.env` file and restart Gluetun:

```bash
# .env
VPN_COUNTRIES=Germany,Switzerland,Sweden
```

```bash
docker restart gluetun
```

## File structure

```
/data/
  downloads/
    incomplete/    # JDownloader active downloads
    completed/     # Finished files waiting for upload

/mnt/r2/
  media/           # Rclone mount of the R2 bucket (read-write)
    movies/        # Organize however you want
    shows/
    ...

/etc/rclone/
  rclone.conf      # R2 credentials

/home/vps/
  upload-to-r2.sh  # Cron upload script
```

## Troubleshooting

**Rclone mount disappears after reboot**: Check `systemctl status rclone-mount`. If it failed, look at the logs with `journalctl -u rclone-mount -n 50`. Common causes: bad credentials in `rclone.conf`, or `fuse3` not installed.

**Upload script isn't running**: Check `crontab -l` as root. The entry should look like `*/5 * * * * /home/vps/upload-to-r2.sh`. Check the log at `/var/log/upload-to-r2.log` for errors.

**JDownloader can't reach the internet**: This means Gluetun's tunnel is down. Check `docker logs gluetun` for authentication or connection errors. Make sure your VPN credentials are correct in `.env`.

**Jellyfin buffering on Smart TV**: This is usually the VFS cache warming up for a new file. The first few seconds of playback on a file that hasn't been accessed recently may buffer while rclone pulls chunks from R2. Subsequent playback of the same file (or seeking within it) should be smooth thanks to the 2GB VFS cache.

**Bazarr can't write subtitles**: Make sure `/mnt/r2/media` is mounted read-write on the host. The rclone mount service in this setup does not use `--read-only` specifically so Bazarr can write `.srt` files alongside the media.

## License

MIT
