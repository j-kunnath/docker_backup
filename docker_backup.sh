#!/usr/bin/env bash
#
# docker-backup.sh — Safe, incremental backups of a single container
#
# Usage:  ./docker-backup.sh <container_name_or_id>
#
# Features
# --------
# 1. Detects & logs running / stopped state
# 2. Snapshots container with `docker commit`
# 3. Finds every bind-mount and named-volume path automatically
# 4. Performs incremental, hard-link based backups with `rsync --link-dest`
# 5. Compresses finished backup with tar + zstd (fast & space-saving)
# 6. Cleans up archives older than BACKUP_RETENTION days
# 7. Fails fast, captures every error line in the log

set -Eeuo pipefail
shopt -s nullglob

##### CONFIGURABLE DEFAULTS ############################################
BACKUP_ROOT="/var/backups/docker"      # Where compressed archives are stored
WORK_DIR="${BACKUP_ROOT}/tmp"          # Rsync staging area (on same FS!)
BACKUP_RETENTION=30                    # Days to keep *.tar.zst files
COMPRESSOR="zstd -T0 -19"              # Change to "gzip -9" if you prefer
LOG_DIR="${BACKUP_ROOT}/logs"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_FILE="${LOG_DIR}/backup-${TIMESTAMP}.log"
########################################################################

# ------------ helper functions ---------------------------------------
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

trap 'die "Command \"${BASH_COMMAND}\" failed on line ${LINENO}."' ERR

# ------------ sanity checks ------------------------------------------
[[ $# -eq 1 ]] || die "Usage: $0 <container_name_or_id>"
CONTAINER="$1"

mkdir -p "$BACKUP_ROOT" "$WORK_DIR" "$LOG_DIR"

# -------- Check container alive & grab metadata -----------------------
if ! docker inspect "$CONTAINER" &>/dev/null; then
    die "Container \"$CONTAINER\" does not exist"
fi

RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER")
log "Container state: ${RUNNING}"

# -------- Create live snapshot image ----------------------------------
SNAP_IMAGE="${CONTAINER}_snapshot:${TIMESTAMP}"
log "Committing live snapshot: $SNAP_IMAGE"
docker commit "$CONTAINER" "$SNAP_IMAGE" >>"$LOG_FILE"

# -------- Stop (if running) to get quiescent volumes ------------------
if [[ "$RUNNING" == "true" ]]; then
    log "Stopping \"$CONTAINER\" to freeze volumes"
    docker stop --time 30 "$CONTAINER" >>"$LOG_FILE"
fi

# -------- Build array of mount sources --------------------------------
readarray -t SOURCES < <(
  docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$CONTAINER" | sort -u
)
[[ ${#SOURCES[@]} -gt 0 ]] || die "No mount points discovered"

log "Backing up directories:"
for s in "${SOURCES[@]}"; do log "  • $s"; done

# -------- Determine incremental base ----------------------------------
LAST_BACKUP=$(ls -1d "${WORK_DIR}"/${CONTAINER}_* 2>/dev/null | sort | tail -n1 || true)
INC_FLAG=()
[[ -d "$LAST_BACKUP" ]] && INC_FLAG=(--link-dest="$LAST_BACKUP")

# -------- Rsync into a new dated dir ----------------------------------
DEST_DIR="${WORK_DIR}/${CONTAINER}_${TIMESTAMP}"
mkdir -p "$DEST_DIR"

for SRC in "${SOURCES[@]}"; do
  RSYNC_DEST="${DEST_DIR}${SRC}"
  mkdir -p "$(dirname "$RSYNC_DEST")"
  rsync -aHAX --numeric-ids --delete "${INC_FLAG[@]}" "$SRC/" "$RSYNC_DEST/" >>"$LOG_FILE"
done
log "Incremental copy finished"

# -------- Restart container if it was running -------------------------
if [[ "$RUNNING" == "true" ]]; then
    log "Restarting \"$CONTAINER\""
    docker start "$CONTAINER" >>"$LOG_FILE"
fi

# -------- Tar + compress the new backup -------------------------------
ARCHIVE="${BACKUP_ROOT}/${CONTAINER}_${TIMESTAMP}.tar.zst"
log "Compressing backup → ${ARCHIVE}"
tar -C "$DEST_DIR" -cf - . | eval ${COMPRESSOR} -o "\"${ARCHIVE}\""
log "Compression done: $(du -h "$ARCHIVE" | cut -f1)"

# -------- Cleanup staging dir & old archives --------------------------
rm -rf "$DEST_DIR"

log "Pruning archives older than $BACKUP_RETENTION days"
find "$BACKUP_ROOT" -maxdepth 1 -name "${CONTAINER}_*.tar.zst" \
     -mtime +$BACKUP_RETENTION -print -delete >>"$LOG_FILE"

# -------- Success banner ----------------------------------------------
log "Backup completed successfully 🎉"
echo "Backup archive: $ARCHIVE"
echo "Log file:       $LOG_FILE"
