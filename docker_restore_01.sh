#!/bin/bash

# Docker container restore script with interactive backup selection
# Usage: ./docker_restore.sh <container_name> [timestamp]

BACKUP_DIR="/var/backups/docker"
LOG_FILE="/var/log/docker_restore.log"

# Logging helper
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

# Check arguments
if [ -z "$1" ]; then
    echo "Usage: $0 <container_name> [timestamp]"
    exit 1
fi

CONTAINER_NAME="$1"
CONTAINER_BACKUP_DIR="${BACKUP_DIR}/${CONTAINER_NAME}"

# Check if backup directory exists
if [ ! -d "$CONTAINER_BACKUP_DIR" ]; then
    log "ERROR: No backups found for container '$CONTAINER_NAME'."
    exit 1
fi

# Interactive timestamp selection
if [ -z "$2" ]; then
    log "No timestamp provided. Listing available backups..."
    BACKUPS=($(ls -1 "${CONTAINER_BACKUP_DIR}" | grep -E '^[0-9]{8}_[0-9]{6}$' | sort -r))
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        log "ERROR: No valid backups found."
        exit 1
    fi

    echo "Available backups:"
    select TS in "${BACKUPS[@]}"; do
        if [ -n "$TS" ]; then
            TIMESTAMP="$TS"
            break
        else
            echo "Invalid selection."
        fi
    done
else
    TIMESTAMP="$2"
fi

CURRENT_BACKUP="${CONTAINER_BACKUP_DIR}/${TIMESTAMP}"
IMAGE_ARCHIVE=$(find "$CURRENT_BACKUP" -name "${CONTAINER_NAME}_backup_${TIMESTAMP}.tar.gz" | head -n 1)
INSPECT_FILE="${CURRENT_BACKUP}/container_inspect.json"

# Validate backup files
if [ ! -f "$IMAGE_ARCHIVE" ]; then
    log "ERROR: Backup image archive not found: $IMAGE_ARCHIVE"
    exit 1
fi

if [ ! -f "$INSPECT_FILE" ]; then
    log "ERROR: Container inspect file not found: $INSPECT_FILE"
    exit 1
fi

# Restore image
log "Loading Docker image from: $IMAGE_ARCHIVE"
docker load < <(gunzip -c "$IMAGE_ARCHIVE") >>"$LOG_FILE" 2>&1 || {
    log "ERROR: Failed to load Docker image."
    exit 1
}

# Parse original settings
log "Parsing container configuration..."
IMAGE_ID=$(jq -r '.[0].Image' "$INSPECT_FILE")
CMD=$(jq -r '.[0].Config.Cmd | join(" ")' "$INSPECT_FILE")
PORTS=$(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[] | "-p \(.value[0].HostPort):\(.key)"' "$INSPECT_FILE")
ENVS=$(jq -r '.[0].Config.Env[] | "-e \(.)"' "$INSPECT_FILE")
VOLUMES=$(jq -r '.[0].Mounts[] | "\(.Destination) \(.Source)"' "$INSPECT_FILE")

# Remove existing container
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "Removing existing container..."
    docker stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
    docker rm "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
fi

# Create volume mounts
MOUNT_FLAGS=""
while read -r DEST SRC; do
    mkdir -p "$SRC"
    MOUNT_FLAGS+=" -v $SRC:$DEST"
done <<< "$VOLUMES"

# Recreate container
log "Recreating container with restored config..."
CMD_STRING="docker create --name $CONTAINER_NAME $PORTS $ENVS $MOUNT_FLAGS $IMAGE_ID $CMD"
log "Running: $CMD_STRING"
eval $CMD_STRING >>"$LOG_FILE" 2>&1 || {
    log "ERROR: Failed to create container."
    exit 1
}

# Restore volumes
log "Restoring volumes..."
while read -r DEST SRC; do
    VOL_NAME=$(basename "$SRC")
    BACKUP_SRC="${CURRENT_BACKUP}/volumes/${VOL_NAME}"
    if [ -d "$BACKUP_SRC" ]; then
        log "Restoring volume $VOL_NAME -> $SRC"
        rsync -a "$BACKUP_SRC/" "$SRC/" >>"$LOG_FILE" 2>&1 || log "WARNING: rsync failed for $SRC"
    else
        log "WARNING: Missing volume backup for $VOL_NAME"
    fi
done <<< "$VOLUMES"

# Start container
log "Starting restored container: $CONTAINER_NAME"
docker start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || {
    log "ERROR: Failed to start container."
    exit 1
}

log "Restore completed successfully for container '$CONTAINER_NAME' using backup '$TIMESTAMP'."
