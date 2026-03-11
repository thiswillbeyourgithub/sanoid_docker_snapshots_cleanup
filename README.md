# Sanoid Docker Snapshots Cleanup

Clean up orphaned ZFS snapshots of Docker containers on a backup pool.

## The problem

When [Sanoid](https://github.com/jimsalterjrs/sanoid) snapshots a system and [Syncoid](https://github.com/jimsalterjrs/sanoid) replicates to a backup pool, Docker container datasets (ephemeral by nature) get snapshotted too. When containers are removed on the original pool, those backup snapshots become orphans that waste space.

This script compares backup pool snapshots against the original pool's live datasets and identifies (or deletes) the orphans.

## Requirements

- ZFS
- `zsh`
- `sudo` access for `zfs` commands

## Usage

```sh
# Dry run — list orphaned snapshots
./cleanup_docker_snapshots.sh

# Actually delete orphaned snapshots
./cleanup_docker_snapshots.sh --delete
```

### Options

| Option | Default | Description |
|---|---|---|
| `--backups-dataset-name NAME` | `backups` | Backup pool/dataset name |
| `--original-dataset-name NAME` | `rpool` | Original pool/dataset name |
| `--filter-pattern PATTERN` | `var/docker` | Substring to match in dataset names |
| `--delete` | off | Destroy orphaned snapshots (default is dry-run) |
| `-h, --help` | | Show help |

### Example

```sh
./cleanup_docker_snapshots.sh \
  --backups-dataset-name tank/backups \
  --original-dataset-name rpool \
  --filter-pattern var/docker \
  --delete
```

## License

AGPL-3.0 — see [LICENSE](LICENSE).
