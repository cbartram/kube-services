# Syncing the Dedicated Server's World Down to a Local PC

How to pull the live world off the Kubernetes dedicated server onto the Windows client, so the same world can be hosted locally if the tailnet route falls through. Written to be re-run routinely as the world progresses, not once.

This is the reverse of [WORLD-MIGRATION.md](WORLD-MIGRATION.md), which covers moving a world *onto* the server.

## The short version

```bash
cd manifests/windrose/windrose-sync
./sync-save.sh
```

That copies the newest world snapshot down, verifies it, backs up whatever was there before, and installs it into the local client. **The server keeps running the whole time** — nothing is stopped, and nothing on the PVC is written, renamed, or deleted.

Run `./sync-save.sh --dry-run` first if you want to see what it would do without touching anything.

## What actually moves, and what does not

The two save trees are disjoint, which is what makes this safe:

| Location | Server profile (`Default`) | Local profile (`76561198037782343`) |
|----------|---------------------------|-------------------------------------|
| `RocksDB_v2/0.10.0/Worlds/` | the world — the only thing there | installed by this sync |
| `RocksDB_v2/0.10.0/Players/` | *absent* | your character — never touched |
| `RocksDB_v2/0.10.0/Accounts/` | *absent* | your account data — never touched |

**The world lives on the server. Your character lives on your PC.** The server has no `Players` or `Accounts` directory at all — the local client writes character progression into its own profile even while you are playing on the dedicated server. The local `Players` DB updates during dedicated-server sessions, which is how it stays current.

Two consequences worth knowing:

- Your character comes across for free. You do not need to sync it, and this script deliberately never writes to `Players/` or `Accounts/`.
- Your friends' characters live on *their* PCs. When they join a locally hosted game they bring their own progression with them, exactly as they did on the dedicated server.

This settles the open question left at the end of `WORLD-MIGRATION.md` — characters are client-side, not world-side.

## Why this needs no downtime

The server writes its own backup archive on a timer, roughly **every 10–11 minutes**:

```
SaveProfiles/Default/RocksDB_v2_Backups/Worlds/<WorldID>/<WorldID>_0.10.0_Latest.zip
```

That archive is a stock RocksDB `BackupEngine` checkpoint — a point-in-time consistent copy of the database, written by the server itself while it holds the appropriate locks. It keeps about ten timestamped snapshots alongside `_Latest.zip` and rotates them.

So there is no reason to scale the deployment to zero. Copying `_Latest.zip` out of the running pod gives a clean snapshot at most ~11 minutes old, and reading a file can never damage the source. Contrast this with copying the live `Worlds/<WorldID>/` folder out from under a running server, which is the classic way to produce a torn, unloadable database.

The archive is also self-describing. `Checkpoint/meta/1` opens with a timestamp, the DB's last sequence number and a file count, then lists every file with an **unmasked CRC32C**. `verify_archive.py` checks all of it before anything local is touched, which is what catches the one real hazard here: copying the zip during the ~1 second the server spends rewriting it.

## Layout translation

The archive is not shaped like a live world folder, so the sync rewrites it:

| In the archive | In the live world folder |
|----------------|--------------------------|
| `Checkpoint/private/1/CURRENT`, `MANIFEST-*`, `OPTIONS-*`, `*.log` | the world folder root, same names |
| `Checkpoint/shared_checksum/010166_sOO286RK8W7TFEQECLSLS_13440.sst` | `010166.sst` |
| `AdditionalRecordFiles/WorldDescription.json` | `WorldDescription.json` |

The SST rename is the part that is easy to get wrong: `<number>_s<session-id>_<size>.sst` collapses to `<number>.sst`. Blob files, if the world ever has any, use `<number>_<crc32c>_<size>.blob` instead.

The sync installs **both** the rebuilt world folder and the original `_Latest.zip`, mirroring how the local client already stores its own `Players` DB — a live folder under `RocksDB_v2/` plus an archive under `RocksDB_v2_Backups/`. The engine registers databases from the backup archives, so a world folder with no matching archive can be ignored entirely.

## Paths

| | |
|---|---|
| World ID | `D74B96C5DFBF42327F914AD618AA88AB` |
| World name | The Peninsula |
| Game version | `0.10.0` |
| Server path | `/home/steam/server-files/R5/Saved/SaveProfiles/Default/` |
| Local path | `%LOCALAPPDATA%\R5\Saved\SaveProfiles\76561198037782343\` |
| Local path from WSL | `/mnt/c/Users/cbart/AppData/Local/R5/Saved/SaveProfiles/76561198037782343/` |

Every one of these is overridable by environment variable — see the top of `sync-save.sh`. If the server ever updates past `0.10.0`, set `WINDROSE_GAME_VERSION` to the new folder name, and make sure the client is on the same build.

## Hosting the world locally

1. Run the sync with the game **fully closed**.
2. Launch Windrose. The world appears in the world list as **The Peninsula**.
3. If the client asks whether to use the **Local** or **Cloud** save, choose **Local**. Cloud will happily overwrite the freshly synced copy with an older one.
4. Host, and invite your friends the normal way.

## The one hazard: this sync is one-way

The moment you host locally, the local copy starts accumulating progress the server has never seen. Running the sync again would overwrite it. There is no merge — RocksDB databases cannot be combined, and whichever copy you keep, the other's progress is gone.

The script defends against exactly this. After each sync it records the install time in `~/windrose-sync-backups/last-sync-D74B96C5.env`, and on the next run it refuses if the local world has been written since:

```
REFUSING TO SYNC: the local world has been written since the last sync.
  local last written  2026-08-20 16:22:18
  last synced         2026-08-20 16:12:18

You have hosted locally since then, and that progress is only on this PC.
Overwriting would discard it. Back it up, or re-run with --force to overwrite.
```

`--force` overwrites deliberately. Before you use it, decide which copy is canonical.

**Pick one home for the world at a time.** Either the server is authoritative and local is a read-only spare, or you have moved the group to local hosting and the server is now the stale copy. Alternating between them loses progress.

If you do end up playing locally and want the server to take over again, that is the migration in `WORLD-MIGRATION.md`, running in the opposite direction — and it does require stopping the server.

## Rolling back a sync

Every sync copies the previous local world aside first:

```bash
ls ~/windrose-sync-backups/
# 20260820-161148/world  20260820-161148/archives
```

To restore one, with the game closed:

```bash
STAMP=20260820-161148
W="/mnt/c/Users/cbart/AppData/Local/R5/Saved/SaveProfiles/76561198037782343"
WORLD_ID=D74B96C5DFBF42327F914AD618AA88AB

rm -rf "$W/RocksDB_v2/0.10.0/Worlds/$WORLD_ID"
cp -r ~/windrose-sync-backups/$STAMP/world "$W/RocksDB_v2/0.10.0/Worlds/$WORLD_ID"
cp -r ~/windrose-sync-backups/$STAMP/archives/. "$W/RocksDB_v2_Backups/Worlds/$WORLD_ID/"
```

These backups are only pruned by hand. Delete old ones when disk matters; each is a few MB.

## Doing it by hand

If the script is unavailable, this is the whole thing. It is read-only against the cluster.

```bash
WORLD_ID=D74B96C5DFBF42327F914AD618AA88AB
GAME_VERSION=0.10.0
POD=$(kubectl -n windrose get pods -l app.kubernetes.io/name=windrose \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
SERVER=/home/steam/server-files/R5/Saved/SaveProfiles/Default

mkdir -p ~/windrose-pull && cd ~/windrose-pull

kubectl -n windrose cp \
  "${POD}:${SERVER}/RocksDB_v2_Backups/Worlds/${WORLD_ID}/${WORLD_ID}_${GAME_VERSION}_Latest.zip" \
  ./Latest.zip

unzip -q -o Latest.zip -d unpacked
mkdir -p world
cp -r unpacked/Checkpoint/private/1/. world/
for f in unpacked/Checkpoint/shared_checksum/*; do
  b=$(basename "$f"); cp "$f" "world/${b%%_*}.${b##*.}"
done
cp unpacked/AdditionalRecordFiles/WorldDescription.json world/
```

Confirm the rebuild is complete before installing it — this must report no missing files:

```bash
python3 /mnt/c/Users/cbart/GolandProjects/kube-services/manifests/windrose/windrose-import/manifest.py world
```

Then install, with the game closed:

```bash
W="/mnt/c/Users/cbart/AppData/Local/R5/Saved/SaveProfiles/76561198037782343"
mkdir -p "$W/RocksDB_v2/${GAME_VERSION}/Worlds" "$W/RocksDB_v2_Backups/Worlds/${WORLD_ID}"
cp -r world "$W/RocksDB_v2/${GAME_VERSION}/Worlds/${WORLD_ID}"
cp Latest.zip "$W/RocksDB_v2_Backups/Worlds/${WORLD_ID}/${WORLD_ID}_${GAME_VERSION}_Latest.zip"
```

To check how fresh the server's snapshot is at any point:

```bash
kubectl -n windrose exec deploy/windrose -- \
  ls -l --full-time "${SERVER}/RocksDB_v2_Backups/Worlds/${WORLD_ID}/"
```

## Troubleshooting

**`could not obtain a valid archive after 3 attempts`.** The copy kept landing mid-rewrite, or the pod is unhealthy. Check the archive timestamps with the command above and confirm they are still advancing; if they are not, the server has stopped taking backups and the logs are the place to look.

**The world does not appear in the client's list.** The archive is missing or misnamed. It must be at `RocksDB_v2_Backups/Worlds/<WorldID>/<WorldID>_0.10.0_Latest.zip` — note there is **no `<GameVersion>` directory level** in the backups tree, the version lives in the filename, and the ID appears twice.

**The world appears but fails to load.** The rebuild was short. Run `manifest.py` against the installed folder; `MISSING` must be `none`. A short world folder fails with `NewRandomAccessFile failed to Create/Open: <file>.sst`.

**Wrong version folder.** The client's `RocksDB_v2/` must contain a folder matching the server's version. If the client updated ahead of the server, or vice versa, they will not line up.

**The world loads but is older than expected.** The client used the Cloud save. Re-sync and pick **Local**.

## What is not covered

Pushing local progress back up to the server. That is `WORLD-MIGRATION.md`, and unlike this direction it requires stopping the deployment, because writing to the PVC while the server holds the database open will corrupt it.
