#!/bin/bash
HOT="/media/hot"
COLD="/media/cold"

THRESHOLD_PERCENT=80
TARGET_PERCENT=70
MIN_FREE_GB=50

RADARR_API="http://radarr:7878/api/v3"
SONARR_API="http://sonarr:8989/api/v3"
RADARR_KEY="${RADARR_API_KEY}"
SONARR_KEY="${SONARR_API_KEY}"

# ============================================================================
# OPERATIONAL MODES (controlled via env vars)
# ============================================================================
DRY_RUN="${DRY_RUN:-false}"           # Set to "true" to preview without moving
MAX_FILES="${MAX_FILES:-0}"            # Set to number to limit files moved (0 = unlimited)
DRAIN_MODE="${DRAIN_MODE:-false}"      # Set to "true" to archive EVERYTHING
SKIP_HYDRATION="${SKIP_HYDRATION:-false}"  # Set to "true" to skip hydration phase

get_usage_percent() { df "$HOT" | awk 'NR==2 {gsub(/%/,"",$5); print $5}'; }
get_free_gb() { df -BG "$HOT" | awk 'NR==2 {gsub(/G/,"",$4); print $4}'; }

calculate_space_needed() {
    local current=$1
    local target=$2
    local total_bytes
    total_bytes=$(df -B1 "$HOT" | awk 'NR==2 {print $2}')
    if [ "$current" -gt "$target" ]; then
        echo $(( (current - target) * total_bytes / 100 ))
    else
        echo "0"
    fi
}

# ============================================================================
# PHASE 1: HYDRATION
# ============================================================================
hydrate_symlinks() {
    if [ "$SKIP_HYDRATION" = "true" ]; then
        echo "[Hydration] Skipped (SKIP_HYDRATION=true)"
        return
    fi

    echo "=================================================="
    echo "[Hydration] Starting symlink restoration..."
    echo "=================================================="

    if [ ! -d "$COLD" ]; then
        echo "[Hydration] ✗ Cold storage not found at $COLD"
        return 1
    fi

    local SYMLINKS_CREATED=0
    local CONFLICTS_FOUND=0

    echo "[Hydration] Creating directory structure..."
    cd "$COLD" || return 1
    find . -type d -print0 | xargs -0 -I {} mkdir -p "$HOT/{}"

    echo "[Hydration] Creating symlinks for archived files..."
    while IFS= read -r FILE; do
        HOT_PATH="$HOT/$FILE"
        COLD_PATH="$COLD/$FILE"

        if [ -f "$HOT_PATH" ] && [ ! -L "$HOT_PATH" ]; then
            echo "[Hydration] ⚠️  Conflict: Real file exists on hot: $FILE"
            CONFLICTS_FOUND=$(( CONFLICTS_FOUND + 1 ))
            continue
        fi

        if [ -L "$HOT_PATH" ]; then
            CURRENT_TARGET=$(readlink "$HOT_PATH")
            [ "$CURRENT_TARGET" = "$COLD_PATH" ] && continue
            rm "$HOT_PATH"
        fi

        if ln -s "$COLD_PATH" "$HOT_PATH" 2>/dev/null; then
            SYMLINKS_CREATED=$(( SYMLINKS_CREATED + 1 ))
        fi
    done < <(find . -type f -not -name ".*")

    echo ""
    echo "[Hydration] ✓ Complete"
    echo "[Hydration]   - Symlinks created: ${SYMLINKS_CREATED}"
    [ "$CONFLICTS_FOUND" -gt 0 ] && echo "[Hydration]   - Conflicts: ${CONFLICTS_FOUND}"
    echo "=================================================="
    echo ""
}

# ============================================================================
# PHASE 2: API QUERIES
# ============================================================================

get_movies_by_age() {
    echo "[Query] Fetching movies from Radarr..." >&2

    local RESPONSE
    RESPONSE=$(curl -s "${RADARR_API}/moviefile" -H "X-Api-Key: ${RADARR_KEY}" 2>/dev/null)

    if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "[]" ]; then
        echo "[Warning] No movies found in Radarr" >&2
        return
    fi

    local COUNT
    COUNT=$(echo "$RESPONSE" | jq -r 'length' 2>/dev/null)
    echo "[Query] Found ${COUNT} movie files" >&2

    echo "$RESPONSE" | jq -r '.[] | "\(.dateAdded)|\(.path)|\(.size)"' 2>/dev/null | sort
}

get_episodes_by_age() {
    echo "[Query] Fetching episodes from Sonarr..." >&2

    local SERIES_IDS
    SERIES_IDS=$(curl -s "${SONARR_API}/series" -H "X-Api-Key: ${SONARR_KEY}" 2>/dev/null | \
                      jq -r '.[].id' 2>/dev/null)

    if [ -z "$SERIES_IDS" ]; then
        echo "[Warning] No series found in Sonarr" >&2
        return
    fi

    local SERIES_COUNT
    SERIES_COUNT=$(echo "$SERIES_IDS" | wc -l)
    echo "[Query] Found ${SERIES_COUNT} series, fetching episode files..." >&2

    while read -r SERIES_ID; do
        curl -s "${SONARR_API}/episodefile?seriesId=${SERIES_ID}" \
          -H "X-Api-Key: ${SONARR_KEY}" 2>/dev/null
    done <<< "$SERIES_IDS" | jq -s 'add // [] | .[] | "\(.dateAdded)|\(.path)|\(.size)"' 2>/dev/null | sort
}

# ============================================================================
# PHASE 3: ARCHIVAL
# ============================================================================

archive_file() {
    local FILE_PATH="$1"
    local DATE_ADDED="$2"
    local FILE_SIZE="$3"

    # Skip if not on hot storage
    [[ "$FILE_PATH" != "$HOT"* ]] && return 1

    # Skip symlinks (already archived)
    [ -L "$FILE_PATH" ] && return 1

    # Skip if file doesn't exist
    [ ! -f "$FILE_PATH" ] && return 1

    local DEST="${FILE_PATH/$HOT/$COLD}"
    local DEST_DIR
    DEST_DIR="$(dirname "$DEST")"

    # Skip if already on cold storage
    if [ -f "$DEST" ]; then
        echo "[Cleanup] File exists on cold, creating symlink: $(basename "$FILE_PATH")" >&2
        if [ "$DRY_RUN" = "false" ]; then
            rm -f "$FILE_PATH" && ln -s "$DEST" "$FILE_PATH"
        fi
        return 1
    fi

    # Calculate age
    local NOW
    NOW=$(date +%s)
    local ADDED_EPOCH
    ADDED_EPOCH=$(date -d "$DATE_ADDED" +%s 2>/dev/null || echo "$NOW")
    local AGE_DAYS=$(( (NOW - ADDED_EPOCH) / 86400 ))

    # Calculate size in GB
    local SIZE_GB
    SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE/1024/1024/1024}")

    # Show what we would do
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] Would archive: ${SIZE_GB}GB | ${AGE_DAYS}d old | $(basename "$FILE_PATH")"
        return 0
    fi

    # Actually perform the archive
    mkdir -p "$DEST_DIR"

    if mv "$FILE_PATH" "$DEST" 2>/dev/null; then
        if ln -s "$DEST" "$FILE_PATH" 2>/dev/null; then
            echo "[Archive] ✓ ${SIZE_GB}GB | ${AGE_DAYS}d old | $(basename "$FILE_PATH")"
            return 0
        else
            echo "[Archive] ✗ Symlink failed, reverting..." >&2
            mv "$DEST" "$FILE_PATH" 2>/dev/null
            return 1
        fi
    else
        echo "[Archive] ✗ Move failed: $(basename "$FILE_PATH")" >&2
        return 1
    fi
}

# ============================================================================
# MAIN
# ============================================================================

echo "=================================================="
echo "[Mover] Starting Radarr/Sonarr API-aware archiver"
echo "=================================================="
echo "[Config] Threshold: ${THRESHOLD_PERCENT}%"
echo "[Config] Target: ${TARGET_PERCENT}%"
echo "[Config] Min Free: ${MIN_FREE_GB}GB"
echo "[Config] Hot: $HOT"
echo "[Config] Cold: $COLD"
echo ""
echo "[Mode] DRY_RUN: ${DRY_RUN}"
echo "[Mode] MAX_FILES: ${MAX_FILES} (0 = unlimited)"
echo "[Mode] DRAIN_MODE: ${DRAIN_MODE}"
echo "[Mode] SKIP_HYDRATION: ${SKIP_HYDRATION}"
echo "=================================================="
echo ""

# Run hydration on startup (unless skipped)
hydrate_symlinks

# Determine if we should run once or loop
if [ "$DRAIN_MODE" = "true" ] || [ "$DRY_RUN" = "true" ] || [ "$MAX_FILES" -gt 0 ]; then
    RUN_ONCE=true
else
    RUN_ONCE=false
fi

# Main loop
LOOP_COUNT=0
while true; do
    LOOP_COUNT=$(( LOOP_COUNT + 1 ))

    CURRENT_PERCENT=$(get_usage_percent)
    FREE_GB=$(get_free_gb)

    echo ""
    echo "=================================================="
    echo "[Status] $(date '+%Y-%m-%d %H:%M:%S')"
    echo "[Status] Usage: ${CURRENT_PERCENT}% | Free: ${FREE_GB}GB"
    echo "=================================================="

    # Determine if we should archive
    SHOULD_ARCHIVE=false

    if [ "$DRAIN_MODE" = "true" ]; then
        echo "[Mover] 🔥 DRAIN MODE: Archiving ALL files"
        SHOULD_ARCHIVE=true
        SPACE_TO_FREE=999999999999999  # Effectively unlimited
    elif [ "$CURRENT_PERCENT" -gt "$THRESHOLD_PERCENT" ] || [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
        echo "[Mover] ⚠️  Archival needed"
        SHOULD_ARCHIVE=true
        SPACE_TO_FREE=$(calculate_space_needed "$CURRENT_PERCENT" "$TARGET_PERCENT")
    else
        echo "[Mover] ✓ Storage healthy - no action needed"
    fi

    if [ "$SHOULD_ARCHIVE" = "true" ]; then
        SPACE_FREED=0
        FILES_ARCHIVED=0

        echo ""

        # Combine movies and episodes, sorted by date (oldest first)
        while IFS='|' read -r TYPE DATE_ADDED FILE_PATH FILE_SIZE; do

            # Check MAX_FILES limit
            if [ "$MAX_FILES" -gt 0 ] && [ "$FILES_ARCHIVED" -ge "$MAX_FILES" ]; then
                echo "[Mover] MAX_FILES limit reached (${MAX_FILES}), stopping"
                break
            fi

            # Stop if we've freed enough space (unless in DRAIN_MODE)
            if [ "$DRAIN_MODE" = "false" ] && [ "$SPACE_FREED" -ge "$SPACE_TO_FREE" ]; then
                echo "[Mover] Target reached, stopping archival"
                break
            fi

            # Archive the file
            if archive_file "$FILE_PATH" "$DATE_ADDED" "$FILE_SIZE"; then
                SPACE_FREED=$(( SPACE_FREED + FILE_SIZE ))
                FILES_ARCHIVED=$(( FILES_ARCHIVED + 1 ))
            fi
        done < <({
            get_movies_by_age 2>&1 | grep -v "^\[" | sed 's/^/movie|/'
            get_episodes_by_age 2>&1 | grep -v "^\[" | sed 's/^/episode|/'
        } | sort -t'|' -k2)

        FREED_GB=$(awk "BEGIN {printf \"%.2f\", $SPACE_FREED/1024/1024/1024}")
        echo ""
        echo "[Mover] ✓ Archival complete"
        echo "[Mover]   - Files archived: ${FILES_ARCHIVED}"
        echo "[Mover]   - Space freed: ${FREED_GB}GB"

        if [ "$DRY_RUN" = "false" ]; then
            NEW_PERCENT=$(get_usage_percent)
            NEW_FREE=$(get_free_gb)
            echo "[Mover]   - New usage: ${NEW_PERCENT}% (${NEW_FREE}GB free)"
        fi
    fi

    # Exit if run-once mode
    if [ "$RUN_ONCE" = "true" ]; then
        echo ""
        echo "[Mover] Run-once mode complete. Exiting."
        exit 0
    fi

    echo ""
    echo "[Mover] Next check in 5 minutes..."
    sleep 300
done