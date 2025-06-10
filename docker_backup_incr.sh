#!/bin/bash

# Incremental Docker container backup script
# Usage: ./docker_backup.sh <container_name>

# Configuration
BACKUP_DIR="/var/backups/docker"
LOG_FILE="/var/log/docker_backup.log"
RETENTION_DAYS=7
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Logging helper
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

# Check arguments
if [ -z "$1" ]; then
    log "ERROR: Container name required."
    echo "Usage: $0 <container_name>"
    exit 1
fi

CONTAINER_NAME="$1"
CONTAINER_BACKUP_DIR="${BACKUP_DIR}/${CONTAINER_NAME}"
CURRENT_BACKUP="${CONTAINER_BACKUP_DIR}/${TIMESTAMP}"
LATEST_LINK="${CONTAINER_BACKUP_DIR}/latest"

mkdir -p "$CURRENT_BACKUP/volumes"
touch "$LOG_FILE"

# Ensure container exists
if ! docker inspect "$CONTAINER_NAME" &>/dev/null; then
    log "ERROR: Container '$CONTAINER_NAME' not found."
    exit 1
fi

# Check if container is running
RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")

# Commit snapshot
IMAGE_NAME="${CONTAINER_NAME}_backup_${TIMESTAMP}"
log "Creating snapshot image: $IMAGE_NAME"
docker commit "$CONTAINER_NAME" "$IMAGE_NAME" >>"$LOG_FILE" 2>&1 || {
    log "ERROR: Failed to commit container."
    exit 1
}

# Save container image (full, because Docker layers are incremental)
log "Saving container image..."
docker save "$IMAGE_NAME" | gzip > "${CURRENT_BACKUP}/${IMAGE_NAME}.tar.gz"

# Backup volumes incrementally
log "Backing up volumes incrementally..."
VOLUME_PATHS=$(docker inspect --format='{{range .Mounts}}{{.Source}} {{end}}' "$CONTAINER_NAME")

for VOLUME in $VOLUME_PATHS; do
    if [ -d "$VOLUME" ]; then
        VOL_NAME=$(basename "$VOLUME")
        DEST_DIR="${CURRENT_BACKUP}/volumes/${VOL_NAME}"
        mkdir -p "$(dirname "$DEST_DIR")"
        
        if [ -L "$LATEST_LINK" ]; then
            PREV="${LATEST_LINK}/volumes/${VOL_NAME}"
            log "Incremental backup of $VOLUME using $PREV"
            rsync -a --delete --link-dest="$PREV" "$VOLUME/" "$DEST_DIR/"
        else
            log "Full backup of $VOLUME"
            rsync -a "$VOLUME/" "$DEST_DIR/"
        fi
    fi
done

# Stop and restart container for consistency (optional)
if [ "$RUNNING" == "true" ]; then
    log "Stopping container $CONTAINER_NAME..."
    docker stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
    STOPPED=1
else
    STOPPED=0
fi

docker inspect "$CONTAINER_NAME" > "${CURRENT_BACKUP}/container_inspect.json"

if [ "$STOPPED" -eq 1 ]; then
    log "Restarting container $CONTAINER_NAME..."
    docker start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
fi

# Update 'latest' symlink
log "Updating latest symlink to $CURRENT_BACKUP"
ln -snf "$CURRENT_BACKUP" "$LATEST_LINK"

# Cleanup old backups
log "Removing backups older than $RETENTION_DAYS days..."
find "$CONTAINER_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name latest -mtime +$RETENTION_DAYS -exec rm -rf {} \; >>"$LOG_FILE" 2>&1

log "Incremental backup for '$CONTAINER_NAME' completed successfully."
