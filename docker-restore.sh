#!/usr/bin/env bash
#
# docker-restore.sh — Restore a container’s data from a backup archive
#
# Usage:
#   ./docker-restore.sh <container_name_or_id> <path/to/backup.tar.zst>
#
# What it does
# ------------
# 1. Verifies the archive and container exist
# 2. Stops the container (if running) so all volumes are quiescent
# 3. Extracts the archive to a temporary working directory
# 4. Rsync-copies each volume/bind-mount back to its original host path
# 5. Restarts the container (if it was running)
# 6. Logs every step and aborts on the first error
#
# IMPORTANT
# ---------
# • Run as root (it must write directly into volume paths such as
#   /var/lib/docker/volumes/…/_data).
# • The script restores **only the data** inside bind-mounts & named volumes
#   exactly as created by docker-backup.sh.  It does **not** recreate the
#   snapshot image that backup.sh produced with `docker commit`.  In most real
#  -world situations that image already lives inside your local registry, but
#   if you ever saved it with `docker save … > image.tar`, simply reload it
#   beforehand with `docker load -i image.tar`.
# • The archive must still contain absolute paths (that’s how backup.sh stores
#   them).  Do **not** untar it manually before running this script.

set -Eeuo pipefail
shopt -s nullglob

##### USER-TUNABLE SETTINGS ############################################
WORK_DIR="/var/backups/docker/tmp"     # Same FS as the archive if possible
LOG_DIR="/var/backups/docker/logs"
########################################################################

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_FILE="${LOG_DIR}/restore-${TIMESTAMP}.log"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

trap 'die "Command \"${BASH_COMMAND}\" failed on line ${LINENO}."' ERR

### ---------- argument / sanity checks -------------------------------
[[ $# -eq 2 ]] || die "Usage: $0 <container_name_or_id> <backup.tar.zst>"
CONTAINER="$1"
ARCHIVE="$2"

[[ -f "$ARCHIVE" ]]                     || die "Archive $ARCHIVE not found"
docker inspect "$CONTAINER" &>/dev/null || die "Container \"$CONTAINER\" not found"

mkdir -p "$WORK_DIR" "$LOG_DIR"

RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER")
log "Container state: ${RUNNING}"

### ---------- stop the container (if running) ------------------------
if [[ "$RUNNING" == "true" ]]; then
    log "Stopping \"$CONTAINER\" before restore"
    docker stop --time 30 "$CONTAINER" >>"$LOG_FILE"
fi

### ---------- discover host-side mount points ------------------------
readarray -t DESTS < <(
  docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$CONTAINER" | sort -u
)
[[ ${#DESTS[@]} -gt 0 ]] || die "No mount points discovered for $CONTAINER"

log "Will restore these targets:"
for d in "${DESTS[@]}"; do log "  • $d"; done

### ---------- extract archive to a temp dir --------------------------
EXTRACT_DIR="${WORK_DIR}/restore_${CONTAINER}_${TIMESTAMP}"
mkdir -p "$EXTRACT_DIR"

log "Extracting archive (this can take a while)…"
# The archive was created with: tar -C "$DEST_DIR" -cf - . | zstd -T0 -19 -o <file>
zstd -d -c "$ARCHIVE" | tar -C "$EXTRACT_DIR" -xf -
log "Extraction finished"

### ---------- rsync each volume back ---------------------------------
for DEST in "${DESTS[@]}"; do
    SRC="${EXTRACT_DIR}${DEST}"            # archive kept absolute paths
    [[ -d "$SRC" ]] || { log "SKIP: no data for $DEST"; continue; }

    log "Restoring $DEST"
    # Preserve owners, permissions, xattrs & hard links
    rsync -aHAX --numeric-ids --delete "$SRC/" "$DEST/" >>"$LOG_FILE"
done

### ---------- cleanup temp dir ---------------------------------------
rm -rf "$EXTRACT_DIR"
log "Temporary directory removed"

### ---------- restart container if necessary -------------------------
if [[ "$RUNNING" == "true" ]]; then
    log "Restarting \"$CONTAINER\""
    docker start "$CONTAINER" >>"$LOG_FILE"
fi

log "Restore completed successfully ✅"
echo "Log file: $LOG_FILE"
