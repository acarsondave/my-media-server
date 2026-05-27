# my-media-server

A self-hosted media center that keeps nothing on disk. Downloads land on a local SSD staging area, get automatically sorted and pushed to Cloudflare R2, and Jellyfin streams everything back through an rclone FUSE mount. The whole thing runs on a cheap VPS (4GB RAM, 2 CPU) alongside your existing sites via Coolify.

I built this because I was tired of running out of disk space on small VPS instances. R2's free egress and S3-compatible API made it a natural fit for media storage, and rclone's VFS caching makes streaming from it surprisingly smooth.

The stack is split into two independent compose files so you can shut down the VPN and downloader when you're not actively grabbing files. On a 4GB box, that matters.

## Disclaimer

This project is a personal infrastructure blueprint for managing and streaming your own legally obtained media files (home videos, DRM-free purchases, personal recordings, content you have the rights to distribute to yourself). It is not designed, intended, or endorsed for use with copyrighted material you do not own or have license to store and stream.

Cloudflare R2's [Terms of Service](https://www.cloudflare.com/terms/) apply to all data stored in your bucket. Misuse of this stack to host or distribute infringing content is solely your responsibility and may result in account termination by Cloudflare. The authors of this repository assume no liability for how you use it.

## What's in the box

| Component | Role |
|-----------|------|
| **Rclone** | Mounts R2 as a local filesystem on the host |
| **Gluetun** | VPN tunnel for download traffic (NordVPN, ProtonVPN, Mullvad, etc.) |
| **JDownloader 2** | Headless downloader managed via my.jdownloader.org |
| **Jellyfin** | Streams media to your devices from the R2 mount |

Subtitles and UI enhancements are handled by Jellyfin's native plugin system instead of running a separate Bazarr container. Less moving parts, less memory.

## How it works

```
                         JDownloader
                              |
                              v
              /data/downloads/incomplete  (active chunks)
                              |
                              v  (EventScripter on completion)
              /data/downloads/completed/
                   Movies/Movie Name (2024)/
                   Shows/Show Name/Season 01/
                   Others/
                              |
                              v  (host cron, every 5 min, with lock checks)
                    rclone move -> Cloudflare R2
                              |
                              v  (rclone FUSE mount, read by Jellyfin)
                    /mnt/r2/media
```

JDownloader downloads to `incomplete/`. When a download finishes, an EventScripter automation script fires immediately, parses the filename, and sorts the file into the correct subfolder under `completed/` -- movies get `Movies/Name (Year)/`, TV shows get `Shows/Name/Season XX/`, and anything else lands in `Others/`.

A host-level cron script runs every 5 minutes, checks that nothing in `completed/` is still being written to (using `lsof` and a file size stability check), and moves everything to R2. Empty subdirectories under `completed/` are cleaned up, but the `completed/` root itself is never deleted so JDownloader's output path stays intact.

## Prerequisites

- A Linux VPS with root access (tested on Ubuntu 22.04 / Debian 12)
- Docker and Docker Compose (Coolify handles this)
- A Cloudflare account with an R2 bucket
- A free MyJDownloader account (https://my.jdownloader.org)

## Setup

### 1. Create your R2 bucket

In the Cloudflare dashboard:
1. Go to R2 Object Storage and create a bucket. Call it `media` (or whatever you prefer, just update the rclone config to match).
2. Go to Manage R2 API Tokens and create a token with read/write access on the bucket.
3. Note down the **Access Key ID**, **Secret Access Key**, and your **Account ID** (visible in the URL or the token page).

### 2. Run the host setup

SSH into your VPS as root:

```bash
git clone https://github.com/acarsondave/my-media-server.git
cd my-media-server
chmod +x setup.sh
sudo ./setup.sh
```

This installs `rclone`, `lsof`, and `fuse3`, creates the directory structure, writes the systemd mount unit, drops the upload cron script into `/home/vps/`, and registers the 5-minute cron job.

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

Start the mount:

```bash
sudo systemctl start rclone-mount
sudo systemctl status rclone-mount
```

Verify:

```bash
ls /mnt/r2/media
```

### 4. Deploy the streaming stack

Copy the env template:

```bash
cp .env.example .env
nano .env
```

Fill in at minimum your VPN and MyJDownloader credentials.

**Via Coolify:**

1. Create a new project, select Docker Compose.
2. Paste the contents of `streaming-stack.yml` (or point it at the file in the repo).
3. Set your environment variables in Coolify's panel.
4. Map your domain: `jellyfin.yourdomain.com` -> port `8096`.
5. Deploy.

**Directly on the host:**

```bash
docker compose -f streaming-stack.yml up -d
```

### 5. Deploy the acquisition stack

Same process, separate Coolify project (or separate compose command):

**Via Coolify:**

1. Create another project, paste `acquisition-stack.yml`.
2. Add the same `.env` values.
3. Deploy. No domain mapping needed -- JDownloader is headless.

**Directly:**

```bash
docker compose -f acquisition-stack.yml up -d
```

When you're done downloading, stop the acquisition stack to free up memory:

```bash
docker compose -f acquisition-stack.yml down
```

### 6. Configure JDownloader's default download path

Once JDownloader connects to your MyJDownloader account, log into https://my.jdownloader.org and set the default download folder:

1. Go to **Settings > General** and set the default download folder to `/output/incomplete`.
2. Go to **Settings > Archive Extractor** and set the extraction output to `/output/incomplete` as well (the sorter script will handle the final move).

### 7. Set up the EventScripter sorting automation

This is the piece that replaces needing Sonarr/Radarr or manual folder organization. JDownloader has a built-in scripting engine called EventScripter that can run JavaScript when specific events fire.

In MyJDownloader:
1. Go to **Settings > Advanced Settings > EventScripter**.
2. Make sure EventScripter is enabled.
3. Click on the **Scripts** tab.
4. Click **Add**, then paste the following JSON into the script import (or create a new script manually with trigger `ON_DOWNLOAD_CONTROLLER_STOPPED` and paste the script body):

```json
[{"eventTrigger":"ON_DOWNLOAD_CONTROLLER_STOPPED","eventTriggerSettings":{},"id":1779857029277","name":"Ultimate Sorter v3","script":"var baseDir = \"/output/completed/\"; if (link.isFinished()) { var downloadPathStr = link.getDownloadPath(); if (downloadPathStr.indexOf(\"incomplete\") !== -1) { var fileName = link.getName(); var extMatch = fileName.match(/\\.([a-zA-Z0-9]+)$/); var ext = extMatch ? extMatch[1].toLowerCase() : \"\"; var videoExtensions = [\"mkv\", \"mp4\", \"avi\", \"mov\", \"m4v\", \"wmv\", \"flv\", \"webm\"]; var isVideo = videoExtensions.indexOf(ext) !== -1; var targetDir; if (!isVideo) { targetDir = baseDir + \"Others/\"; } else { var showRegex = /(.+?)\\.S(\\d+)E(\\d+)/i; var showMatch = fileName.match(showRegex); if (showMatch) { var showName = showMatch[1].replace(/\\./g, \" \").trim(); var seasonNum = parseInt(showMatch[2], 10); targetDir = baseDir + \"Shows/\" + showName + \"/Season \" + (seasonNum < 10 ? \"0\" + seasonNum : seasonNum) + \"/\"; } else { var movieRegex = /(.+?)[.\\-_ ]\\b((?:19|20)\\d{2})\\b/i; var movieMatch = fileName.match(movieRegex); if (movieMatch) { var movieName = movieMatch[1].replace(/\\./g, \" \").trim(); var movieYear = movieMatch[2]; targetDir = baseDir + \"Movies/\" + movieName + \" (\" + movieYear + \")/\"; } else { var cleanName = fileName.substring(0, fileName.lastIndexOf('.')).replace(/\\./g, \" \").trim(); targetDir = baseDir + \"Movies/\" + cleanName + \"/\"; } } } getPath(downloadPathStr).moveTo(targetDir); } }","enabled":true}]
```

What the script does:
- Fires the exact moment a download stops.
- Checks if the file came from the `incomplete/` directory and is actually finished.
- Parses the filename extension to determine if it's a video file.
- For TV shows matching patterns like `S01E01`, it creates `Shows/Show Name/Season 01/`.
- For movies with a year like `Movie.Name.2024`, it creates `Movies/Movie Name (2024)/`.
- Movies without a detectable year get `Movies/Clean Name/`.
- Non-video files (NFOs, samples, etc.) go to `Others/`.

## Connecting the cron upload script to Docker volumes

Because the JDownloader volume is a bind mount (`/data/downloads:/output`), the host OS has direct filesystem access to the download directories. The cron script at `/home/vps/upload-to-r2.sh` targets `/data/downloads/completed` on the host, which is the same path as `/output/completed` inside the container.

If you changed the bind mount path in your compose file, or if Coolify remapped it, you need to find the actual host path:

```bash
docker inspect jdownloader --format '{{ range .Mounts }}{{ if eq .Destination "/output" }}{{ .Source }}{{ end }}{{ end }}'
```

Use whatever that returns as the `COMPLETED_DIR` value in `/home/vps/upload-to-r2.sh`.

## Subtitles and UI plugins (replacing Bazarr)

Running Bazarr as a separate container uses ~200MB of RAM for something Jellyfin can do natively with plugins. Here's how to set it up.

### Subtitle plugins

In Jellyfin's admin dashboard, go to **Dashboard > Plugins > Catalog** and install one of:

**Option A: OpenSubtitles plugin**
- Install the **Open Subtitles** plugin from the catalog.
- Restart Jellyfin.
- Go to **Dashboard > Plugins > Open Subtitles** and enter your opensubtitles.com credentials (the v2 API -- create a free account at opensubtitles.com, not the legacy .org site).
- Free tier gets 20 subtitle downloads per day, which is plenty for personal use.
- Go to **Dashboard > Libraries**, edit each library, and under **Subtitle Downloads** enable automatic downloading.

**Option B: Subbuzz plugin (fully free)**
- Install the **Subbuzz** plugin from the catalog.
- This aggregates from sources like Subdl and YIFY that don't require accounts or API limits.
- Configure under **Dashboard > Plugins > Subbuzz** after restarting Jellyfin.

Both options download `.srt` text-based subtitles, which Smart TVs render client-side without triggering server transcoding.

### UI enhancement plugins

These are optional but worth the 2 minutes to install. They turn Jellyfin from "functional" into something that actually looks good on a TV:

| Plugin | What it does |
|--------|-------------|
| **Jellyfin Enhanced** | General UI polish and quality-of-life fixes |
| **IamParadox - Home Screen Sections** | Custom sections on the home screen (trending, recently added, etc.) |
| **IamParadox - Custom Tabs** | Add your own navigation tabs |
| **IamParadox - Media Bar** | Persistent media bar for quick access |
| **IamParadox - JavaScript Injector** | Run custom JS for deeper UI tweaks |
| **KefinTweaks** | Additional UI refinements |
| **Intro Skipper** | Detects and lets you skip show intros |
| **InPlayerEpisodePreview** | Episode preview thumbnails during playback |

Install all of these from the Jellyfin plugin catalog. Most just need a Jellyfin restart to activate. The IamParadox suite and KefinTweaks may need you to add their third-party plugin repository URL in **Dashboard > Plugins > Repositories** first if they don't show up in the default catalog.

## Disabling transcoding (important for low-resource VPS)

If you leave transcoding enabled, a single stream can peg both CPUs on a 2-core VPS and tank everything else on the machine. This was the original reason I split the stacks -- I needed every bit of headroom for Jellyfin when someone was watching something.

In Jellyfin's admin dashboard:

1. Go to **Dashboard > Users**.
2. Edit each user profile.
3. Under **Media Playback**, uncheck:
   - **Allow video transcoding**
   - **Allow audio transcoding**
4. Save.

This forces all clients to direct play, meaning Jellyfin just serves the file as-is with zero CPU overhead. The trade-off is that your media needs to be in formats your devices can natively decode. Most Smart TVs from the last few years handle H.264/H.265 in MKV or MP4 containers without issues.

For subtitles: text-based `.srt` files are rendered client-side by Smart TVs. Image-based formats (PGS, VobSub) force the server to burn them into the video stream, which is transcoding. That's why the subtitle plugins are configured for `.srt` only.

## VPN IP rotation

When a filehost like PixelDrain hits you with a download limit or blocks your IP, you need a fresh one.

### Restart the container

Gluetun picks a new server on startup:

```bash
docker restart gluetun
```

JDownloader briefly loses connectivity and resumes automatically once the tunnel is back.

### Use the Gluetun control API

Gluetun exposes an HTTP API on port 8000 (mapped to `localhost:8888` on the host):

Check current status:
```bash
curl -s http://localhost:8888/v1/vpn/status | jq .
```

Cycle the connection:
```bash
curl -s -X PUT -H "Content-Type: application/json" \
  -d '{"status":"stopped"}' http://localhost:8888/v1/vpn/status

sleep 3

curl -s -X PUT -H "Content-Type: application/json" \
  -d '{"status":"running"}' http://localhost:8888/v1/vpn/status
```

### Switch countries

Update `VPN_COUNTRIES` in your `.env` and restart:

```bash
# In .env:
VPN_COUNTRIES=Germany,Switzerland,Sweden
```

```bash
docker restart gluetun
```

## File structure

```
/data/
  downloads/
    incomplete/              # JDownloader active downloads
    completed/               # Sorted by EventScripter, uploaded by cron
      Movies/
        Movie Name (2024)/
      Shows/
        Show Name/
          Season 01/
      Others/

/mnt/r2/
  media/                     # Rclone FUSE mount of the R2 bucket

/etc/rclone/
  rclone.conf                # R2 credentials (chmod 600)

/home/vps/
  upload-to-r2.sh            # Cron upload script
```

## Troubleshooting

**"Transport endpoint is not connected" on /media inside Jellyfin**: The host rclone mount crashed or restarted after Jellyfin started. The `rshared` bind propagation flag in the compose file should handle this automatically, but if you hit it, restart Jellyfin: `docker restart jellyfin`. Then fix the root cause by checking `systemctl status rclone-mount` and `journalctl -u rclone-mount -n 50`.

**Rclone mount disappears after reboot**: Check `systemctl status rclone-mount`. Common causes: bad credentials in `rclone.conf`, or `fuse3` not installed.

**Upload script isn't running**: Check `crontab -l` as root. The entry should read `*/5 * * * * /home/vps/upload-to-r2.sh`. Check `/var/log/upload-to-r2.log` for errors.

**JDownloader can't reach the internet**: Gluetun's tunnel is down. Check `docker logs gluetun`. Make sure your VPN credentials in `.env` are correct.

**JDownloader not showing up on my.jdownloader.org**: Verify `MYJDOWNLOADER_EMAIL`, `MYJDOWNLOADER_PASSWORD`, and `MYJDOWNLOADER_DEVICE_NAME` are set in your `.env`. Check `docker logs jdownloader` for authentication errors.

**Jellyfin buffering on Smart TV**: This is the VFS cache warming up. The first few seconds of a file that hasn't been accessed recently will buffer while rclone pulls chunks from R2. Subsequent playback and seeking should be smooth thanks to the 2GB VFS cache.

**Coolify times out deploying the acquisition stack**: Make sure JDownloader's `depends_on` uses `condition: service_started`, not `service_healthy`. The `service_healthy` condition causes Coolify to wait indefinitely in some configurations.

**Finding the real host path for Docker volumes**: If you're not sure where a container's `/output` directory lives on the host, inspect it:
```bash
docker inspect jdownloader --format '{{ range .Mounts }}{{ if eq .Destination "/output" }}{{ .Source }}{{ end }}{{ end }}'
```

## License

MIT
