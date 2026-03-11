#!/usr/bin/env zsh
# cleanup_docker_snapshots.sh
#
# Cleans up orphaned ZFS snapshots of docker containers on a backup pool.
#
# When sanoid snapshots a system and syncoid replicates to a backup pool,
# docker container datasets (ephemeral by nature) get snapshotted too.
# When containers are removed on the original pool, those backup snapshots
# become orphans that waste space. This script finds and optionally deletes them.
#
# Written with Claude Code.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
BACKUPS_DATASET="backups"
ORIGINAL_DATASET="rpool"
FILTER_PATTERN="var/docker"
DELETE=false
DRY=false
SPACE=false

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: cleanup_docker_snapshots.sh [OPTIONS]

Find (and optionally delete) orphaned docker ZFS snapshots on a backup pool.

Options:
  --backups-dataset-name NAME   Backup pool/dataset name (default: backups)
  --original-dataset-name NAME  Original pool/dataset name (default: rpool)
  --filter-pattern PATTERN      Substring to match in dataset names (default: var/docker)
  --space                        Compute and display space usage per dataset
  --dry                          Simulate deletion (print what would be destroyed)
  --delete                       Actually destroy orphaned snapshots (default: dry-run listing)
  -h, --help                     Show this help
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backups-dataset-name)
            BACKUPS_DATASET="$2"; shift 2 ;;
        --original-dataset-name)
            ORIGINAL_DATASET="$2"; shift 2 ;;
        --filter-pattern)
            FILTER_PATTERN="$2"; shift 2 ;;
        --space)
            SPACE=true; shift ;;
        --dry)
            DRY=true; shift ;;
        --delete)
            DELETE=true; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ── Helper: human-readable size ──────────────────────────────────────────────
# Converts a byte count to a human-readable string (K, M, G, T).
human_size() {
    local bytes=$1
    if (( bytes >= 1099511627776 )); then
        printf "%.1fT" $(( bytes / 1099511627776.0 ))
    elif (( bytes >= 1073741824 )); then
        printf "%.1fG" $(( bytes / 1073741824.0 ))
    elif (( bytes >= 1048576 )); then
        printf "%.1fM" $(( bytes / 1048576.0 ))
    elif (( bytes >= 1024 )); then
        printf "%.1fK" $(( bytes / 1024.0 ))
    else
        printf "%dB" "$bytes"
    fi
}

# ── Collect data ──────────────────────────────────────────────────────────────

# Get unique dataset names (without snapshot part) from the backup pool
# that match the filter pattern.
# e.g. "backups/var/docker/abc123"
echo "Listing backup snapshots matching '${FILTER_PATTERN}' in '${BACKUPS_DATASET}'..."
backup_datasets=("${(@f)$(
    sudo zfs list -t snapshot -o name -H -r "${BACKUPS_DATASET}" \
        | grep "${FILTER_PATTERN}" \
        | cut -d@ -f1 \
        | sort -u
)}")

typeset -A dataset_space
if [[ "$SPACE" == true ]]; then
    # Build a map of dataset -> total space (in bytes).
    # This includes both the dataset's own "used" space and the sum of all its
    # snapshot "used" values, giving the full reclaimable footprint per dataset.
    # Using -p for parseable (exact byte) output to allow summing.
    echo "Computing space usage (datasets + snapshots)..."

    # 1) Dataset own space (filesystem/volume "used" property).
    while IFS=$'\t' read -r ds_name ds_used; do
        dataset_space[$ds_name]=$(( ${dataset_space[$ds_name]:-0} + ds_used ))
    done < <(
        sudo zfs list -t filesystem,volume -o name,used -Hp -r "${BACKUPS_DATASET}" \
            | grep "${FILTER_PATTERN}"
    )

    # 2) Add each snapshot's "used" space on top.
    while IFS=$'\t' read -r snap_name snap_used; do
        ds="${snap_name%%@*}"
        dataset_space[$ds]=$(( ${dataset_space[$ds]:-0} + snap_used ))
    done < <(
        sudo zfs list -t snapshot -o name,used -Hp -r "${BACKUPS_DATASET}" \
            | grep "${FILTER_PATTERN}"
    )
fi

# Get existing datasets on the original pool that match the filter pattern.
# These are the "live" datasets — containers that still exist.
# e.g. "rpool/var/docker/abc123"
echo "Listing live datasets matching '${FILTER_PATTERN}' in '${ORIGINAL_DATASET}'..."
original_datasets=("${(@f)$(
    sudo zfs list -t filesystem,volume -o name -H -r "${ORIGINAL_DATASET}" \
        | grep "${FILTER_PATTERN}" \
        | sort -u
)}")

# ── Build lookup set of original dataset suffixes ─────────────────────────────
# We strip the pool prefix to compare across pools.
# "rpool/var/docker/abc123" -> "var/docker/abc123"
typeset -A original_set
for ds in "${original_datasets[@]}"; do
    # Remove the pool prefix (everything up to and including the first /)
    suffix="${ds#*/}"
    original_set[$suffix]=1
done

# ── Classify backup datasets ─────────────────────────────────────────────────
still_exist=()
orphaned=()

for ds in "${backup_datasets[@]}"; do
    suffix="${ds#*/}"
    if [[ -n "${original_set[$suffix]:-}" ]]; then
        still_exist+=("$ds")
    else
        orphaned+=("$ds")
    fi
done

# ── Deduplicate: remove datasets whose ancestor is also in the orphaned list ──
# When we destroy a parent with -R, its children are destroyed too.
# Keeping children in the list would cause "dataset does not exist" errors.
typeset -A orphaned_set
for ds in "${orphaned[@]}"; do
    orphaned_set[$ds]=1
done

deduped_orphaned=()
for ds in "${orphaned[@]}"; do
    local parent="$ds"
    local is_child=false
    while [[ "$parent" == */* ]]; do
        parent="${parent%/*}"
        if [[ -n "${orphaned_set[$parent]:-}" ]]; then
            is_child=true
            break
        fi
    done
    if [[ "$is_child" == false ]]; then
        deduped_orphaned+=("$ds")
    fi
done
orphaned=("${deduped_orphaned[@]}")

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
local still_exist_total=0
echo "=== Still exist on ${ORIGINAL_DATASET} (${#still_exist[@]} datasets) ==="
for ds in "${still_exist[@]}"; do
    if [[ "$SPACE" == true ]]; then
        local sz=${dataset_space[$ds]:-0}
        (( still_exist_total += sz )) || true
        echo "  $ds  ($(human_size $sz))"
    else
        echo "  $ds"
    fi
done
if [[ "$SPACE" == true ]]; then
    echo "  Total: $(human_size $still_exist_total)"
fi

echo ""
local orphaned_total=0
echo "=== Orphaned -- missing from ${ORIGINAL_DATASET} (${#orphaned[@]} datasets) ==="
for ds in "${orphaned[@]}"; do
    if [[ "$SPACE" == true ]]; then
        local sz=${dataset_space[$ds]:-0}
        (( orphaned_total += sz )) || true
        echo "  $ds  ($(human_size $sz))"
    else
        echo "  $ds"
    fi
done
if [[ "$SPACE" == true ]]; then
    echo "  Total: $(human_size $orphaned_total)"
fi

echo ""
if [[ "$SPACE" == true ]]; then
    echo "Summary: ${#still_exist[@]} still exist ($(human_size $still_exist_total)), ${#orphaned[@]} orphaned ($(human_size $orphaned_total))"
else
    echo "Summary: ${#still_exist[@]} still exist, ${#orphaned[@]} orphaned"
fi

# ── Delete if requested ──────────────────────────────────────────────────────
if [[ "$DELETE" == true || "$DRY" == true ]]; then
    if [[ ${#orphaned[@]} -eq 0 ]]; then
        echo "Nothing to delete."
        exit 0
    fi

    echo ""
    local total=${#orphaned[@]}
    local current=0
    if [[ "$DRY" == true ]]; then
        echo "Dry run -- would destroy ${total} orphaned datasets:"
        for ds in "${orphaned[@]}"; do
            (( current++ )) || true
            echo "  [${current}/${total}] Would destroy ${ds}"
        done
    else
        echo "Deleting orphaned datasets..."
        for ds in "${orphaned[@]}"; do
            (( current++ )) || true
            if ! sudo zfs list -H -o name "${ds}" &>/dev/null; then
                echo "  [${current}/${total}] Skipping ${ds} (already destroyed by a prior -R)"
                continue
            fi
            echo "  [${current}/${total}] Destroying ${ds}..."
            sudo zfs destroy -R "${ds}"
        done
        echo "Done. Deleted ${total} orphaned datasets and their snapshots."
    fi
else
    if [[ ${#orphaned[@]} -gt 0 ]]; then
        echo ""
        echo "Run with --delete to destroy orphaned datasets and their snapshots."
    fi
fi
