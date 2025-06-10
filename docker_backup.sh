#!/bin/bash

# Backup script for Docker container and its volumes
# Usage: ./docker_backup.sh <container_name>

# Configuration
BACKUP_DIR="/var/backups/docker"
LOG_FILE="/var/log/docker_backup.log"
RETENTION_DAYS=7  # Days to keep old backups

# Ensure backup and log directories exist
mkdir -p "$BACKUP_DIR" || exit 1
touch "$LOG_FILE" || exit 1

# Timestamp
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
BACKUP_PATH="${BACKUP_DIR}/${CONTAINER_NAME}_${TIMESTAMP}"

# Ensure container exists
if ! docker inspect "$CONTAINER_NAME" &>/dev/null; then
    log "ERROR: Container '$CONTAINER_NAME' not found."
    exit 1
fi

# Check if container is running
RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")

# Commit container snapshot
IMAGE_NAME="${CONTAINER_NAME}_backup_${TIMESTAMP}"
log "Creating snapshot image: $IMAGE_NAME"
if ! docker commit "$CONTAINER_NAME" "$IMAGE_NAME" >>"$LOG_FILE" 2>&1; then
    log "ERROR: Failed to commit container snapshot."
    exit 1
fi

# Backup volumes
log "Backing up volumes..."
mkdir -p "$BACKUP_PATH/volumes"
VOLUME_PATHS=$(docker inspect --format='{{range .Mounts}}{{.Source}} {{end}}' "$CONTAINER_NAME")

for VOLUME in $VOLUME_PATHS; do
    if [ -d "$VOLUME" ]; then
        VOL_NAME=$(basename "$VOLUME")
        DEST="${BACKUP_PATH}/volumes/${VOL_NAME}"
        log "Copying volume: $VOLUME"
        cp -a "$VOLUME" "$DEST" || log "WARNING: Failed to copy $VOLUME"
    fi
done

# Save container image
log "Saving snapshot image..."
docker save "$IMAGE_NAME" | gzip > "${BACKUP_PATH}/${IMAGE_NAME}.tar.gz"

# Stop container if running (optional for consistent state)
if [ "$RUNNING" == "true" ]; then
    log "Stopping container $CONTAINER_NAME..."
    docker stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
    STOPPED=1
else
    STOPPED=0
fi

# (Optional) Backup container state or configuration
docker inspect "$CONTAINER_NAME" > "${BACKUP_PATH}/container_inspect.json"

# Restart if it was previously running
if [ "$STOPPED" -eq 1 ]; then
    log "Restarting container $CONTAINER_NAME..."
    docker start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
fi

# Cleanup old backups
log "Cleaning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type d -mtime +$RETENTION_DAYS -exec rm -rf {} \; >>"$LOG_FILE" 2>&1

log "Backup for '$CONTAINER_NAME' completed successfully at $BACKUP_PATH"
