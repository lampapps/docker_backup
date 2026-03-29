# Docker Compose Backup

Hot (live) backup script for Raspberry Pi Docker Compose projects. Containers stay running during backup — no DNS or service downtime.

Backs up: **pihole**, **caddy**, **cloudflared**

## How It Works

1. Exports Pi-hole configuration via the **Teleporter REST API** (v6+) and backs up its `docker-compose.yml`.
2. Archives caddy and cloudflared project directories into timestamped `.tar.gz` files on the NAS.
3. Verifies archive integrity.
4. Reports status to Uptime Kuma via push notification.
5. Cleans up backups older than the configured retention period.

No containers are stopped or restarted.

## Requirements

- `bash`, `curl`, `jq`, `tar`, `sudo`
- Pi-hole v6+ (REST API required for Teleporter export)
- NAS mounted at `/mnt/nas-unas`
- `sudo` access (required for archiving caddy's directories)

## Setup

1. Copy the example config and edit it:

   ```bash
   cp backup.conf.example backup.conf
   nano backup.conf
   ```

2. Set your Pi-hole password, push token, paths, and project list in `backup.conf`.

3. Ensure the NAS is mounted at the path configured in `BACKUP_ROOT`.

4. Make the script executable:

   ```bash
   chmod +x backup.sh
   ```

## Usage

### Manual run (verbose output to terminal)

```bash
sudo ./backup.sh -v
```

### Cron (daily at 3 AM)

```bash
sudo crontab -e
```

Add:

```
0 3 * * * /home/pi/scripts/docker_backup/backup.sh
```

## Configuration

All settings are in `backup.conf`. See `backup.conf.example` for defaults.

| Variable | Description |
|---|---|
| `PIHOLE_API_URL` | Pi-hole REST API base URL (e.g., `http://127.0.0.1:8080`) |
| `PIHOLE_PASSWORD` | Pi-hole admin password for API authentication |
| `BASE_DIR` | Parent directory of Docker Compose project folders |
| `BACKUP_ROOT` | Destination directory for backups and logs (on NAS) |
| `PUSH_URL` | Uptime Kuma push API URL |
| `PUSH_TOKEN` | Uptime Kuma push token (keep secret — file is gitignored) |
| `RETENTION_DAYS` | Delete backups older than this many days |
| `MIN_SPACE_MB` | Abort if less than this much free space on backup volume |
| `PROJECTS` | Bash array of project directory names to back up |

## Backup Output

Files are stored at `$BACKUP_ROOT` with timestamped names:

**Pi-hole** (Teleporter export + compose file):
```
pihole_teleporter_2026-03-28-0300.zip
pihole-docker-compose-2026-03-28-0300.yml
```

**Caddy / Cloudflared** (full directory archive):
```
caddy-2026-03-28-0300.tar.gz
cloudflared-2026-03-28-0300.tar.gz
```

**Logs:**
```
backup-2026-03-28-0300.log
```

## Restore

### Pi-hole

Pi-hole is restored by importing the Teleporter export and redeploying with the backed-up compose file.

1. Copy the backed-up compose file into place:

   ```bash
   mkdir -p /home/pi/pihole
   cp /mnt/nas-unas/backups/pi4-1/pihole-docker-compose-YYYY-MM-DD-HHMM.yml /home/pi/pihole/docker-compose.yml
   ```

2. Start the container:

   ```bash
   cd /home/pi/pihole
   docker compose up -d
   ```

3. Import the Teleporter backup via the Pi-hole web UI:
   - Go to **Settings → Teleporter**
   - Upload the `pihole_teleporter_YYYY-MM-DD-HHMM.zip` file
   - Click **Restore**

4. Verify DNS is working:

   ```bash
   dig @127.0.0.1 example.com
   ```

### Caddy / Cloudflared

1. Stop the project:

   ```bash
   cd /home/pi/<project>
   docker compose down
   ```

2. Replace the project directory with the archived copy:

   ```bash
   cd /home/pi
   mv <project> <project>.broken
   tar -xzf /mnt/nas-unas/backups/pi4-1/<project>-YYYY-MM-DD-HHMM.tar.gz
   ```

3. Start the project:

   ```bash
   cd /home/pi/<project>
   docker compose up -d
   ```

4. Verify:

   ```bash
   docker compose ps
   ```
