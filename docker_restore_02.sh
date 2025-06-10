#!/bin/bash

# Docker container restore with optional interactive timestamp selection
# Usage: ./docker_restore.sh <container_name> [timestamp]

BACKUP_DIR="/var/backups/docker"
LOG_FILE="/var/log/docker_restore.log"

# Logging
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

# Check for container name
if [ -z "$1" ]; then
    echo "Usage: $0 <container_name> [timestamp]"
    exit 1
fi

CONTAINER_NAME="$1"
CONTAINER_BACKUP_DIR="${BACKUP_DIR}/${CONTAINER_NAME}"

# Check backup directory exists
if [ ! -d "$CONTAINER_BACKUP_DIR" ]; then
    log "ERROR: No backups found for container '$CONTAINER_NAME'."
    exit 1
fi

# If timestamp not provided, prompt interactively
if [ -z "$2" ]; then
    echo "Available backups for '$CONTAINER_NAME':"
    BACKUPS=($(ls -1 "$CONTAINER_BACKUP_DIR" | grep -E '^[0-9]{8}_[0-9]{6}$' | sort -r))

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        log "No backups available."
        exit 1
    fi

    select TS in "${BACKUPS[@]}"; do
        if [[ " ${BACKUPS[*]} " == *" $TS "* ]]; then
            TIMESTAMP="$TS"
            break
        else
            echo "Invalid selection. Try again."
        fi
    done
else
    TIMESTAMP="$2"
fi

RESTORE_PATH="${CONTAINER_BACKUP_DIR}/${TIMESTAMP}"
INSPECT_FILE="${RESTORE_PATH}/container_inspect.json"
IMAGE_ARCHIVE=$(find "$RESTORE_PATH" -name "${CONTAINER_NAME}_backup_${TIMESTAMP}.tar.gz" | head -n 1)

# Validate restore files
if [ ! -f "$IMAGE_ARCHIVE" ] || [ ! -f "$INSPECT_FILE" ]; then
    log "ERROR: Backup files missing for timestamp '$TIMESTAMP'."
    exit 1
fi

# Load Docker image
log "Loading Docker image..."
docker load < <(gunzip -c "$IMAGE_ARCHIVE") >>"$LOG_FILE" 2>&1 || {
    log "ERROR: Docker image load failed."
    exit 1
}

# Parse config using jq
log "Parsing container configuration..."
IMAGE=$(jq -r '.[0].Image' "$INSPECT_FILE")
PORTS=$(jq -r '.[0].HostConfig.PortBindings // {} | to_entries[] | "-p \(.value[0].HostPort):\(.key | split("/")[0])"' "$INSPECT_FILE")
ENVS=$(jq -r '.[0].Config.Env[]' "$INSPECT_FILE" 2>/dev/null | sed 's/^/-e /g')
VOLUMES=$(jq -r '.[0].Mounts[] | "\(.Source) \(.Destination)"' "$INSPECT_FILE")

# Remove existing container
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "Removing existing container '$CONTAINER_NAME'..."
    docker stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
    docker rm "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1
fi

# Restore volumes
log "Restoring volumes..."
while read -r SRC DEST; do
    VOL_NAME=$(basename "$SRC")
    BACKUP_SRC="${RESTORE_PATH}/volumes/${VOL_NAME}"
    if [ -d "$BACKUP_SRC" ]; then
        mkdir -p "$SRC"
        rsync -a "$BACKUP_SRC/" "$SRC/" >>"$LOG_FILE" 2>&1 || log "WARNING: rsync failed for $SRC"
    else
        log "WARNING: Backup missing for volume $VOL_NAME"
    fi
done <<< "$VOLUMES"

# Create container
log "Creating container '$CONTAINER_NAME' with restored config..."
docker create --name "$CONTAINER_NAME" $PORTS $ENVS "$IMAGE" >>"$LOG_FILE" 2>&1 || {
    log "ERROR: Failed to create container."
    exit 1
}

# Start container
log "Starting container '$CONTAINER_NAME'..."
docker start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || {
    log "ERROR: Failed to start container."
    exit 1
}

log "✅ Restore complete for '$CONTAINER_NAME' from backup '$TIMESTAMP'."
