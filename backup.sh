#!/usr/bin/env bash
# Backup script for Raspberry Pi running Docker Compose projects.
# This script performs a hot (live) backup of each project:
# 1. Exports Pi-hole config via Teleporter REST API.
# 2. Archives each project directory into a timestamped tar.gz file on the NAS.
# No container stop/start is required — DNS and other services stay online.
# The script also logs all operations and sends status updates to a locally hosted Uptime Kuma instance via HTTP requests.
#
# Designed for cron execution - all output goes to log file.
# Use -v flag for verbose output to terminal (for testing).

VERSION="0.3.0"

# Usage:
# Terminal: sudo ./backup.sh -v
# Note: run with -v for verbose output to terminal (for testing), otherwise all output goes to log file.
# Crontab:
# Edit with `sudo crontab -e` and add the following line:
# 0 3 * * * /home/pi/backup.sh
# sudo required for permissions.

set -Euo pipefail

# Parse command line arguments
VERBOSE=0
while getopts "v" opt; do
  case $opt in
    v) VERBOSE=1 ;;
    *) echo "Usage: $0 [-v]" >&2; exit 1 ;;
  esac
done

### CONFIG ###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/backup.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  echo "Copy backup.conf.example to backup.conf and edit it." >&2
  exit 1
fi
# shellcheck source=backup.conf
source "$CONFIG_FILE"

DATE="$(date +%F-%H%M)"
LOGFILE="$BACKUP_ROOT/backup-$DATE.log"
LOCKFILE="/tmp/docker-backup.lock"

# Track results for summary
declare -a FAILED_PROJECTS=()
declare -a SUCCESS_PROJECTS=()

### FUNCTIONS ###

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" >>"$LOGFILE"
  [[ $VERBOSE -eq 1 ]] && echo "$msg"
  return 0
}



report_status() {
  local status="$1"
  local msg="$2"
  log "Reporting to Uptime Kuma: status=$status msg=$msg"
  # URL-encode the message (basic: replace spaces with +)
  msg="${msg// /+}"
  local response
  if ! response=$(curl -fsSL --max-time 10 "${PUSH_URL}/${PUSH_TOKEN}?status=${status}&msg=${msg}" 2>&1); then
    log "WARN: Failed to report to Uptime Kuma: $response"
  else
    log "Uptime Kuma: OK"
  fi
}

cleanup_lock() {
  rm -rf "$LOCKFILE"
}

cleanup_old_backups() {
  log "Cleaning up backups older than $RETENTION_DAYS days..."
  local deleted_archives deleted_teleporter deleted_logs
  deleted_archives=$(find "$BACKUP_ROOT" -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -print -delete 2>/dev/null | wc -l)
  deleted_teleporter=$(find "$BACKUP_ROOT" -name "pihole_teleporter_*.zip" -type f -mtime +$RETENTION_DAYS -print -delete 2>/dev/null | wc -l)
  deleted_logs=$(find "$BACKUP_ROOT" -name "backup-*.log" -type f -mtime +$RETENTION_DAYS -print -delete 2>/dev/null | wc -l)
  log "Retention cleanup: removed $deleted_archives archives, $deleted_teleporter teleporter exports, $deleted_logs logs"
}

verify_archive() {
  local archive="$1"
  if tar -tzf "$archive" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# Pi-hole Teleporter backup via REST API (v6+)
backup_pihole_teleporter_api() {
  local backup_file="$BACKUP_ROOT/pihole_teleporter_${DATE}.zip"

  local token
  token=$(curl -s -X POST "${PIHOLE_API_URL}/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"${PIHOLE_PASSWORD}\"}" | jq -r '.session.sid')

  if [[ -z "$token" || "$token" == "null" ]]; then
    log "ERROR: Pi-hole API authentication failed"
    return 1
  fi

  if ! curl -s -X GET "${PIHOLE_API_URL}/api/teleporter" \
    -H "sid: $token" \
    --output "$backup_file"; then
    log "ERROR: Pi-hole Teleporter API export failed"
    curl -s -X DELETE "${PIHOLE_API_URL}/api/auth" -H "sid: $token" > /dev/null
    return 1
  fi

  local file_size
  file_size=$(du -h "$backup_file" | cut -f1)
  log "Teleporter export saved: $backup_file ($file_size)"

  curl -s -X DELETE "${PIHOLE_API_URL}/api/auth" -H "sid: $token" > /dev/null
}

backup_project() {
  local project="$1"
  local project_dir="$BASE_DIR/$project"
  local archive="$BACKUP_ROOT/$project-$DATE.tar.gz"

  log "---- Processing $project ----"

  if [[ ! -d "$project_dir" ]]; then
    log "WARN: missing dir $project_dir, skipping"
    return 1
  fi

  # For pihole, use Teleporter export via REST API (config only, no tar needed)
  if [[ "$project" == "pihole" ]]; then
    log "Exporting Pi-hole configuration via REST API Teleporter..."
    if ! backup_pihole_teleporter_api; then
      log "ERROR: Pi-hole Teleporter API backup failed for $project, skipping"
      return 1
    fi
    log "$project backup complete"
    return 0
  fi

  # Archive the project directory live (no container stop needed)
  log "Archiving $project..."
  if [[ "$project" == "caddy" ]]; then
    if ! sudo tar -C "$BASE_DIR" -czf "$archive" "$project" 2>>"$LOGFILE"; then
      log "ERROR: failed to archive $project (sudo required)"
      rm -f "$archive"
      return 1
    fi
  else
    if ! tar -C "$BASE_DIR" -czf "$archive" "$project" 2>>"$LOGFILE"; then
      log "ERROR: failed to archive $project"
      rm -f "$archive"
      return 1
    fi
  fi

  # Verify archive integrity
  if ! verify_archive "$archive"; then
    log "ERROR: archive verification failed for $project"
    rm -f "$archive"
    return 1
  fi

  local archive_size
  archive_size=$(du -h "$archive" | cut -f1)
  log "Archive created: $archive ($archive_size)"

  log "$project backup complete"
  return 0
}

generate_summary() {
  local total=${#PROJECTS[@]}
  local success=${#SUCCESS_PROJECTS[@]}
  local failed=${#FAILED_PROJECTS[@]}

  if [[ $failed -eq 0 ]]; then
    echo "${success}/${total}+OK"
  else
    local failed_list
    failed_list=$(IFS=,; echo "${FAILED_PROJECTS[*]}")
    echo "${success}/${total}+failed:${failed_list}"
  fi
}

### MAIN ###

# Acquire lock (prevent concurrent runs)
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  # Check if lock is stale (older than 2 hours)
  if [[ -d "$LOCKFILE" ]] && find "$LOCKFILE" -mmin +120 | grep -q .; then
    rm -rf "$LOCKFILE"
    mkdir "$LOCKFILE"
  else
    echo "Another backup is already running (lockfile exists). Aborting." >&2
    exit 1
  fi
fi
trap cleanup_lock EXIT

# Ensure NFS is mounted (prevents writing backups to local disk by accident)
if ! mountpoint -q /mnt/nas-unas; then
  echo "ERROR: /mnt/nas-unas is not mounted; aborting." >&2
  report_status "down" "Backup failed: NAS not mounted"
  exit 1
fi

mkdir -p "$BACKUP_ROOT"
touch "$LOGFILE"

# Redirect all output to log file (for cron), or tee to terminal if verbose
if [[ $VERBOSE -eq 1 ]]; then
  exec > >(tee -a "$LOGFILE") 2>&1
else
  exec >>"$LOGFILE" 2>&1
fi

# Check available disk space
available_mb=$(df -m "$BACKUP_ROOT" | awk 'NR==2 {print $4}')
if [[ "$available_mb" -lt "$MIN_SPACE_MB" ]]; then
  log "ERROR: insufficient disk space (${available_mb}MB available, ${MIN_SPACE_MB}MB required)"
  report_status "down" "Backup failed: low disk space"
  exit 1
fi

report_status "up" "Backup started"
log "===== Docker Compose Backup v$VERSION Started: $DATE ====="
log "Available disk space: ${available_mb}MB"

# Process each project
for PROJECT in "${PROJECTS[@]}"; do
  if backup_project "$PROJECT"; then
    SUCCESS_PROJECTS+=("$PROJECT")
  else
    FAILED_PROJECTS+=("$PROJECT")
  fi
done

# Generate summary
SUMMARY=$(generate_summary)
log "===== Backup Completed: $SUMMARY ====="

# Clean up old backups only after successful backup ensures at least one good copy
if [[ ${#SUCCESS_PROJECTS[@]} -gt 0 ]]; then
  cleanup_old_backups
fi

# Report final status
if [[ ${#FAILED_PROJECTS[@]} -eq 0 ]]; then
  report_status "up" "Backup OK: $SUMMARY"
  exit 0
else
  report_status "down" "Backup: $SUMMARY"
  exit 1
fi
