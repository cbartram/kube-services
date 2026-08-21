#!/usr/bin/env bash
# Copy the Windrose dedicated server's world down to the local Windows client.
#
# Read-only against the cluster: it copies files out of the pod and never writes to,
# renames, or deletes anything on the PVC. The server keeps running throughout.
#
# Usage: ./sync-save.sh [--force] [--dry-run]
set -euo pipefail

NAMESPACE="${WINDROSE_NAMESPACE:-windrose}"
WORLD_ID="${WINDROSE_WORLD_ID:-D74B96C5DFBF42327F914AD618AA88AB}"
GAME_VERSION="${WINDROSE_GAME_VERSION:-0.10.0}"
PROFILE_ID="${WINDROSE_PROFILE_ID:-76561198037782343}"
LOCALAPPDATA_PATH="${WINDROSE_LOCALAPPDATA:-/mnt/c/Users/cbart/AppData/Local}"
BACKUP_DIR="${WINDROSE_BACKUP_DIR:-$HOME/windrose-sync-backups}"
STATE_FILE="${BACKUP_DIR}/last-sync-${WORLD_ID:0:8}.env"

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SERVER_PROFILE="/home/steam/server-files/R5/Saved/SaveProfiles/Default"
LOCAL_PROFILE="${LOCALAPPDATA_PATH}/R5/Saved/SaveProfiles/${PROFILE_ID}"
LOCAL_WORLDS="${LOCAL_PROFILE}/RocksDB_v2/${GAME_VERSION}/Worlds"
LOCAL_WORLD="${LOCAL_WORLDS}/${WORLD_ID}"
LOCAL_ARCHIVES="${LOCAL_PROFILE}/RocksDB_v2_Backups/Worlds/${WORLD_ID}"
ARCHIVE_NAME="${WORLD_ID}_${GAME_VERSION}_Latest.zip"
REMOTE_ARCHIVE="${SERVER_PROFILE}/RocksDB_v2_Backups/Worlds/${WORLD_ID}/${ARCHIVE_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Locating the server pod"
POD="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=windrose \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$POD" ]] || { echo "no running windrose pod in namespace $NAMESPACE" >&2; exit 1; }
echo "    pod ${POD}"

# The server rewrites _Latest.zip every ~11 minutes. Copying mid-rewrite yields a
# truncated file, so verify before trusting it and retry rather than installing junk.
echo "==> Pulling ${ARCHIVE_NAME}"
VERIFIED=0
for attempt in 1 2 3; do
  rm -f "$WORK/archive.zip"
  kubectl -n "$NAMESPACE" cp "${POD}:${REMOTE_ARCHIVE}" "$WORK/archive.zip" >/dev/null 2>&1 || true
  if [[ -s "$WORK/archive.zip" ]] && python3 "$SCRIPT_DIR/verify_archive.py" "$WORK/archive.zip"; then
    VERIFIED=1
    break
  fi
  echo "    attempt ${attempt} did not verify; the server may be rewriting it - retrying in 20s"
  sleep 20
done
[[ "$VERIFIED" -eq 1 ]] || { echo "could not obtain a valid archive after 3 attempts" >&2; exit 1; }

echo "==> Rebuilding the world folder from the archive"
unzip -q "$WORK/archive.zip" -d "$WORK/unpacked"
mkdir -p "$WORK/world"
# private/1 holds CURRENT, the MANIFEST, OPTIONS and the WAL, which sit at the world root.
cp -r "$WORK/unpacked/Checkpoint/private/1/." "$WORK/world/"
# shared_checksum stores SSTs as <number>_s<session>_<size>.sst; live folders want <number>.sst.
for f in "$WORK"/unpacked/Checkpoint/shared_checksum/*; do
  base="$(basename "$f")"
  cp "$f" "${WORK}/world/${base%%_*}.${base##*.}"
done
cp "$WORK/unpacked/AdditionalRecordFiles/WorldDescription.json" "$WORK/world/"
echo "    $(ls "$WORK/world" | wc -l) files reconstructed"

if [[ -f "$SCRIPT_DIR/../windrose-import/manifest.py" ]]; then
  echo "==> Cross-checking the MANIFEST's live file set"
  MANIFEST_OUT="$( cd "$SCRIPT_DIR/../windrose-import" && python3 manifest.py "$WORK/world" )"
  echo "$MANIFEST_OUT" | grep -E 'live SSTs|MISSING|unparsed' | sed 's/^/    /'
  echo "$MANIFEST_OUT" | grep -q 'MISSING (live but absent): none' \
    || { echo "reconstructed world is missing live SSTs - refusing to install" >&2; exit 1; }
fi

read -r ARCHIVE_TS ARCHIVE_SEQ < <(python3 -c "
import zipfile, sys
m = zipfile.ZipFile(sys.argv[1]).read('Checkpoint/meta/1').decode().splitlines()
print(m[0], m[1])" "$WORK/archive.zip")

# Syncing overwrites the local world. Installing stamps every local file at install
# time, so 'has the world been written since then' is the question that detects local
# play - comparing against the archive's own timestamp would fire on every run.
if [[ -d "$LOCAL_WORLD" && "$FORCE" -ne 1 ]]; then
  NEWEST_LOCAL="$(find "$LOCAL_WORLD" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)"
  BASELINE=""
  [[ -f "$STATE_FILE" ]] && BASELINE="$(sed -n 's/^synced_at=//p' "$STATE_FILE")"
  if [[ -z "$BASELINE" ]]; then
    echo "==> No sync record for the existing local world; falling back to its archive stamp"
    BASELINE="$ARCHIVE_TS"
  fi
  # 120s of slack absorbs the time the previous install itself took to copy.
  if [[ -n "$NEWEST_LOCAL" && "$NEWEST_LOCAL" -gt $((BASELINE + 120)) ]]; then
    echo
    echo "REFUSING TO SYNC: the local world has been written since the last sync."
    echo "  local last written  $(date -d "@${NEWEST_LOCAL}" '+%Y-%m-%d %H:%M:%S')"
    echo "  last synced         $(date -d "@${BASELINE}" '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "You have hosted locally since then, and that progress is only on this PC."
    echo "Overwriting would discard it. Back it up, or re-run with --force to overwrite."
    exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "==> Dry run - nothing written. Would install:"
  echo "    ${LOCAL_WORLD}"
  echo "    ${LOCAL_ARCHIVES}/${ARCHIVE_NAME}"
  exit 0
fi

if [[ -d "$LOCAL_WORLD" || -d "$LOCAL_ARCHIVES" ]]; then
  echo "==> Backing up the current local copy"
  DEST="${BACKUP_DIR}/${STAMP}"
  mkdir -p "$DEST"
  [[ -d "$LOCAL_WORLD" ]]    && cp -r "$LOCAL_WORLD" "${DEST}/world"
  [[ -d "$LOCAL_ARCHIVES" ]] && cp -r "$LOCAL_ARCHIVES" "${DEST}/archives"
  echo "    ${DEST}"
fi

echo "==> Installing into the local client"
mkdir -p "$LOCAL_WORLDS" "$LOCAL_ARCHIVES"
rm -rf "${LOCAL_WORLD:?}"
cp -r "$WORK/world" "$LOCAL_WORLD"
cp "$WORK/archive.zip" "${LOCAL_ARCHIVES}/${ARCHIVE_NAME}"
echo "    world    ${LOCAL_WORLD}"
echo "    archive  ${LOCAL_ARCHIVES}/${ARCHIVE_NAME}"

mkdir -p "$BACKUP_DIR"
printf 'synced_at=%s\narchive_ts=%s\nlast_seq=%s\n' \
  "$(date +%s)" "$ARCHIVE_TS" "$ARCHIVE_SEQ" > "$STATE_FILE"

echo
echo "Synced world sequence ${ARCHIVE_SEQ} (server snapshot $(date -d "@${ARCHIVE_TS}" '+%Y-%m-%d %H:%M:%S'))."
echo "Launch Windrose and pick the world from the single-player / host list."
echo "If asked to choose between Local and Cloud saves, choose Local."
