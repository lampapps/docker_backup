# Docker Compose Backup

Hot (live) backup script for Raspberry Pi Docker Compose projects. Containers stay running during backup — no DNS or service downtime.

Backs up: **pihole**, **caddy**, **cloudflared**

## How It Works

1. Creates safe SQLite snapshots for pihole databases (`gravity.db`, `pihole-FTL.db`) using `sqlite3 .backup` inside the running container.
2. Archives each project directory into a timestamped `.tar.gz` on the NAS.
3. Verifies archive integrity.
4. Reports status to Uptime Kuma.
5. Cleans up backups older than the configured retention period.

No containers are stopped or restarted.

## Setup

1. Copy the example config and edit it:

   ```bash
   cp backup.conf.example backup.conf
   nano backup.conf
   ```

2. Set your `PUSH_TOKEN`, `BASE_DIR`, `BACKUP_ROOT`, and `PROJECTS` in `backup.conf`.

3. Ensure the NAS is mounted at the path configured in `BACKUP_ROOT` (e.g., `/mnt/nas-unas`).

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
0 3 * * * /home/pi/containers_backup/backup.sh
```

## Configuration

All settings are in `backup.conf`. See `backup.conf.example` for defaults.

| Variable | Description |
|---|---|
| `BASE_DIR` | Parent directory of Docker Compose project folders |
| `BACKUP_ROOT` | Destination directory for archives and logs (on NAS) |
| `PUSH_URL` | Uptime Kuma push API URL |
| `PUSH_TOKEN` | Uptime Kuma push token (keep secret — file is gitignored) |
| `RETENTION_DAYS` | Delete backups older than this many days |
| `MIN_SPACE_MB` | Abort if less than this much free space on backup volume |
| `PROJECTS` | Bash array of project directory names to back up |

## Backup Output

Archives are stored at `$BACKUP_ROOT` with the naming pattern:

```
<project>-YYYY-MM-DD-HHMM.tar.gz
```

Example:

```
/mnt/nas-unas/backups/pi4-1/pihole-2026-03-23-0300.tar.gz
/mnt/nas-unas/backups/pi4-1/caddy-2026-03-23-0300.tar.gz
/mnt/nas-unas/backups/pi4-1/cloudflared-2026-03-23-0300.tar.gz
```

Logs are saved alongside the archives as `backup-YYYY-MM-DD-HHMM.log`.

## Restore

### 1. Stop the project

```bash
cd /home/pi/<project>
docker compose down
```

### 2. Extract the backup

Replace the project directory with the archived copy:

```bash
cd /home/pi
# Remove or rename the current project directory
mv <project> <project>.broken

# Extract the backup
tar -xzf /mnt/nas-unas/backups/pi4-1/<project>-YYYY-MM-DD-HHMM.tar.gz
```

### 3. Restore pihole databases

The backup contains SQLite `.bak` snapshots that are guaranteed consistent. Replace the live databases with these before starting:

```bash
cd /home/pi/pihole
# Find the volume-mounted pihole data directory (check docker-compose.yml for the bind mount path)
# Replace the databases with the safe backup copies:
cp etc-pihole/gravity.db.bak etc-pihole/gravity.db
cp etc-pihole/pihole-FTL.db.bak etc-pihole/pihole-FTL.db
```

> **Important:** Use the `.bak` files, not the original `.db` files. The `.bak` files were created with `sqlite3 .backup` and are guaranteed to be in a consistent state. The original `.db` files may have been mid-write when the archive was created.

### 4. Start the project

```bash
cd /home/pi/<project>
docker compose up -d
```

### 5. Verify

```bash
docker compose ps
```

For pihole, confirm DNS is resolving:

```bash
dig @127.0.0.1 example.com
```
