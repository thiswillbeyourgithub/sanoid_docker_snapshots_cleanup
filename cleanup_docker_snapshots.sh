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

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: cleanup_docker_snapshots.sh [OPTIONS]

Find (and optionally delete) orphaned docker ZFS snapshots on a backup pool.

Options:
  --backups-dataset-name NAME   Backup pool/dataset name (default: backups)
  --original-dataset-name NAME  Original pool/dataset name (default: rpool)
  --filter-pattern PATTERN      Substring to match in dataset names (default: var/docker)
  --delete                      Actually destroy orphaned snapshots (default: dry-run listing)
  -h, --help                    Show this help
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

# Build a map of dataset -> total space (in bytes).
# This includes both the dataset's own "used" space and the sum of all its
# snapshot "used" values, giving the full reclaimable footprint per dataset.
# Using -p for parseable (exact byte) output to allow summing.
echo "Computing space usage (datasets + snapshots)..."
typeset -A dataset_space

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

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
local still_exist_total=0
echo "=== Still exist on ${ORIGINAL_DATASET} (${#still_exist[@]} datasets) ==="
for ds in "${still_exist[@]}"; do
    local sz=${dataset_space[$ds]:-0}
    (( still_exist_total += sz ))
    echo "  $ds  ($(human_size $sz))"
done
echo "  Total: $(human_size $still_exist_total)"

echo ""
local orphaned_total=0
echo "=== Orphaned — missing from ${ORIGINAL_DATASET} (${#orphaned[@]} datasets) ==="
for ds in "${orphaned[@]}"; do
    local sz=${dataset_space[$ds]:-0}
    (( orphaned_total += sz ))
    echo "  $ds  ($(human_size $sz))"
done
echo "  Total: $(human_size $orphaned_total)"

echo ""
echo "Summary: ${#still_exist[@]} still exist ($(human_size $still_exist_total)), ${#orphaned[@]} orphaned ($(human_size $orphaned_total))"

# ── Delete if requested ──────────────────────────────────────────────────────
if [[ "$DELETE" == true ]]; then
    if [[ ${#orphaned[@]} -eq 0 ]]; then
        echo "Nothing to delete."
        exit 0
    fi

    echo ""
    echo "Deleting orphaned snapshots..."
    local total=${#orphaned[@]}
    local current=0
    for ds in "${orphaned[@]}"; do
        (( current++ ))
        local pct=$(( current * 100 / total ))
        local filled=$(( pct / 2 ))
        local empty=$(( 50 - filled ))
        printf "\r  [%-50s] %3d%% (%d/%d) %s" \
            "$(printf '#%.0s' {1..$filled})" \
            "$pct" "$current" "$total" "$ds"
        sudo zfs destroy -r "${ds}"
    done
    echo ""
    echo "Done. Deleted ${total} orphaned datasets and their snapshots."
else
    if [[ ${#orphaned[@]} -gt 0 ]]; then
        echo ""
        echo "Run with --delete to destroy orphaned datasets and their snapshots."
    fi
fi
