# Migrating an Existing Windrose World onto the Dedicated Server

How to take a world someone has been hosting from their PC and move it onto the Kubernetes dedicated server so the whole group can keep playing it.

There are two roles in this guide:

- **World owner** — whoever has been hosting the world on a Windows PC. Everything in Part 1 is theirs to do.
- **Server operator** — whoever runs this cluster. Everything in Part 2 is theirs to do.

## How the server actually finds a world

This is the part that makes or breaks the migration, and it is not what the generic hosting guides describe.

Windrose stores a world as a RocksDB database — a **folder of binary files**, not a single save file. But the server does **not** discover worlds by scanning the `Worlds/` directory. It builds its island registry from the **backup archives**, and restores each world from its archive on boot:

```
SaveProfiles/Default/RocksDB_v2_Backups/Worlds/<WorldID>/<WorldID>_<GameVersion>_Latest.zip
```

A world folder sitting in `Worlds/` with no matching archive is invisible. The server enumerates zero islands for it, treats `WorldIslandId` as a dangling reference, creates a brand new island, and overwrites `WorldIslandId` in `ServerDescription.json` with the new one. It looks completely healthy in the logs while doing it.

That is the single most common reason a migration appears to fail, and it repeats on every restart — each boot leaves another abandoned world behind.

So three things have to line up:

| Thing | Where it lives |
|-------|----------------|
| The backup archive | `.../RocksDB_v2_Backups/Worlds/<WorldID>/<WorldID>_<GameVersion>_Latest.zip` |
| The world folder | `.../RocksDB_v2/<GameVersion>/Worlds/<WorldID>/` |
| `WorldIslandId` | `ServerDescription.json` at the root of `R5/` |

Note that the backups tree has **no `<GameVersion>` level** — it is `RocksDB_v2_Backups/Worlds/<WorldID>/` directly, and the version appears in the zip filename instead.

Because the server restores the world folder from the archive, the archive is the source of truth. Hand edits made directly to files inside `Worlds/<WorldID>/` can be silently reverted on the next boot.

## Before you start

The world owner should **update their game client to the current version first**, then play and save once. The world lives under a `<GameVersion>` folder, and the chart runs `UPDATE_ON_START=true`, so the server always installs the latest build. If the world was last written by an older client, the versions will not line up.

They should also **not delete anything** afterward. Their copy is the rollback if the migration goes wrong.

---

## Part 1 — What the world owner does

### Step 1. Freeze the world and fully close the game

Tell the group the world is frozen. Windrose must be **fully exited** — not alt-tabbed, not sitting at the main menu. The RocksDB database is still being written while the game runs, and copying a live database is the classic way to produce a corrupted save.

### Step 2. Open the save folder

Press `Win + R`, paste this, press Enter:

```
%LOCALAPPDATA%\R5\Saved\SaveProfiles
```

Full path for reference: `C:\Users\<User>\AppData\Local\R5\Saved\SaveProfiles\`

Inside there will be a profile folder. On Steam or Epic this is the **numeric Steam/platform ID**, not `Default`. (On the Stove launcher it is `StoveDefault`.)

### Step 3. Identify the correct world

Open:

```
%LOCALAPPDATA%\R5\Saved\SaveProfiles\<ProfileID>\RocksDB_v2\<GameVersion>\Worlds\
```

`Worlds\` may contain several folders with long generated IDs. To find the right one, open the `WorldDescription.json` inside each candidate in Notepad and read the `WorldName` field — that is the name shown in-game.

**Write down the exact folder name**, the whole ID string. It is case sensitive and must never be renamed; the database relies on that generated ID.

### Step 4. Copy the backup archive — this is the important one

Go to:

```
%LOCALAPPDATA%\R5\Saved\SaveProfiles\<ProfileID>\RocksDB_v2_Backups\Worlds\<WorldID>\
```

Zip that whole folder. It contains files named `<WorldID>_<GameVersion>_Latest.zip` plus timestamped older snapshots. **`_Latest.zip` is the file the server needs to register the world at all** — without it nothing else in this guide will work.

### Step 5. Copy the world folder too

Right click the `<WorldID>` folder from Step 3 → **Send to** → **Compressed (zipped) folder**.

Or in PowerShell:

```powershell
$world = "$env:LOCALAPPDATA\R5\Saved\SaveProfiles\<ProfileID>\RocksDB_v2\<GameVersion>\Worlds\<WorldID>"
Compress-Archive -Path $world -DestinationPath "$env:USERPROFILE\Desktop\windrose-world.zip"
```

The zip must contain the `<WorldID>` folder itself with the RocksDB files inside it, not just the loose contents.

### Step 6. Send both over and report these four things

Anything works: Google Drive, Dropbox, Discord, WeTransfer. Worlds are typically tens to a few hundred MB; the backup archives are much smaller.

1. The exact `<WorldID>` folder name
2. The exact `<GameVersion>` folder name it came out of (e.g. `0.10.0`)
3. The game version / build number
4. The `WorldName` from the JSON, so the load can be confirmed later

### Step 7. After the migration

On the first client launch after the transfer, Windrose may ask whether to use the **Local** or **Cloud** save. Pick **Local** — Cloud can overwrite the migrated copy with an older one.

---

## Part 2 — What the server operator does

Run these from WSL. Substitute `<WorldID>` and `<GameVersion>` with what was reported.

### Step 1. Let the server boot once first

If the chart has not been started yet, deploy it and let it come all the way up. This creates the directory tree and a throwaway world, which shows the exact layout the current build uses. Skip to Step 2 if it has already run.

### Step 2. Stop the server

The PVC is ReadWriteOnce, so nothing else can mount it while the pod is running. This also guarantees nothing is writing to the database during the copy.

```bash
kubectl -n windrose scale deployment/windrose --replicas=0
kubectl -n windrose rollout status deployment/windrose --timeout=180s
```

### Step 3. Start a helper pod that mounts the same volume

```bash
kubectl -n windrose apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: windrose-shell
spec:
  restartPolicy: Never
  securityContext:
    fsGroup: 1000
  containers:
    - name: shell
      image: alpine:3.20
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: server
          mountPath: /server-files
  volumes:
    - name: server
      persistentVolumeClaim:
        claimName: windrose-server
EOF

kubectl -n windrose wait --for=condition=Ready pod/windrose-shell --timeout=120s
```

### Step 4. Back up the current save tree before touching anything

```bash
kubectl -n windrose exec windrose-shell -- \
  tar czf /tmp/pre-migration-backup.tar.gz -C /server-files/R5/Saved SaveProfiles

kubectl -n windrose cp windrose-shell:/tmp/pre-migration-backup.tar.gz \
  ~/windrose-pre-migration-backup.tar.gz
```

Staging the tarball in the pod's `/tmp` rather than on the volume keeps it out of the save tree, and pulling a copy off the volume matters — a backup that only lives on the same PVC does not protect against a bad import.

### Step 5. Confirm the layout and version this build uses

```bash
kubectl -n windrose exec windrose-shell -- \
  find /server-files/R5/Saved/SaveProfiles -maxdepth 4 -type d
```

Expect `SaveProfiles/Default/RocksDB_v2/<GameVersion>/Worlds` alongside `SaveProfiles/Default/RocksDB_v2_Backups/Worlds`. On older installs the live tree may be `RocksDB` rather than `RocksDB_v2`; use whichever one the server generated its own world into.

Confirm the `<GameVersion>` folder name matches the one reported in Part 1. If it does not, stop and align the versions before continuing. Cross-check against `DeploymentId` in `ServerDescription.json`:

```bash
kubectl -n windrose exec windrose-shell -- \
  grep DeploymentId /server-files/R5/ServerDescription.json
```

### Step 6. Unpack locally

```bash
mkdir -p ~/windrose-import && cd ~/windrose-import
unzip /mnt/c/Users/cbart/Downloads/windrose-world.zip
unzip /mnt/c/Users/cbart/Downloads/windrose-backups.zip
ls    # confirm both the <WorldID> world folder and the <WorldID>_<GameVersion>_Latest.zip archive
```

### Step 7. Copy in the backup archive

This is the step that registers the world with the server.

```bash
WORLD_ID="<WorldID>"
GAME_VERSION="<GameVersion>"
BACKUPS="/server-files/R5/Saved/SaveProfiles/Default/RocksDB_v2_Backups/Worlds"

kubectl -n windrose exec windrose-shell -- mkdir -p "${BACKUPS}/${WORLD_ID}"

kubectl -n windrose cp \
  ~/windrose-import/${WORLD_ID}_${GAME_VERSION}_Latest.zip \
  windrose-shell:${BACKUPS}/${WORLD_ID}/${WORLD_ID}_${GAME_VERSION}_Latest.zip

kubectl -n windrose exec windrose-shell -- ls -la "${BACKUPS}/${WORLD_ID}"
```

### Step 8. Copy in the world folder

```bash
DEST="/server-files/R5/Saved/SaveProfiles/Default/RocksDB_v2/${GAME_VERSION}/Worlds"

kubectl -n windrose exec windrose-shell -- mkdir -p "${DEST}"

tar cf - -C ~/windrose-import "${WORLD_ID}" \
  | kubectl -n windrose exec -i windrose-shell -- tar xf - -C "${DEST}"

kubectl -n windrose exec windrose-shell -- ls -la "${DEST}/${WORLD_ID}"
```

A tar pipe is more reliable than `kubectl cp` for folders with many small files. Do **not** rename the folder at any point.

Ownership does not need fixing by hand — `init.sh` in the image runs `chown -R steam:steam /home/steam/server-files` on every container start.

### Step 9. Point the server at the world

Confirm the island ID inside the imported world matches its folder name:

```bash
kubectl -n windrose exec windrose-shell -- \
  cat "${DEST}/${WORLD_ID}/WorldDescription.json"
```

The field is written as `islandId` by the client and `IslandId` in some documentation; Unreal's JSON reader is case insensitive, so either is fine. The value must match the folder name character for character.

Then set `WorldIslandId` in `ServerDescription.json`:

```bash
kubectl -n windrose exec windrose-shell -- \
  sed -i "s/\"WorldIslandId\": \"[^\"]*\"/\"WorldIslandId\": \"${WORLD_ID}\"/" \
  /server-files/R5/ServerDescription.json

kubectl -n windrose exec windrose-shell -- cat /server-files/R5/ServerDescription.json
```

While in there, `AutoLoadLatestBackupIfHasBroken` is worth setting to `false` for the migration — if the import is broken, the server should fail loudly rather than quietly swap in an unrelated backup and look fine.

### Step 10. Leave `generateSettings` alone

`server.generateSettings` controls whether the container's startup script patches `ServerDescription.json`. That patch only touches `ServerName`, `Password`, `IsPasswordProtected`, `MaxPlayerCount`, `InviteCode`, `UseDirectConnection`, the direct-connection ports and addresses, and `UserSelectedRegion`. It **never writes `WorldIslandId`**, and it preserves every other field in the file.

So `generateSettings: true` is safe during a migration and is the better default — it keeps the server name, password and player cap managed from `values.yaml` instead of by hand on the volume. Set it to `false` only if those settings should be hand-managed on the PVC, and accept that `values.yaml` then goes inert for them.

Leave `server.runWorldDescriptionUpdater: false`. Turn it on only to deliberately apply `WorldSettings` difficulty edits to the migrated world.

### Step 11. Clean up and restart

```bash
kubectl -n windrose delete pod windrose-shell
kubectl -n windrose scale deployment/windrose --replicas=1
kubectl -n windrose logs -f deployment/windrose
```

Give it time — `UPDATE_ON_START=true` revalidates the install before the server comes up.

### Step 12. Confirm the world was actually registered

Do not skip this. The log states its island registry explicitly at boot:

```bash
kubectl -n windrose logs deployment/windrose | grep -A 8 "RootDocumentsCollection::Init"
```

The imported `<WorldID>` must appear in the `Records` list. If it does not, the archive was not picked up and everything after this point is a fresh world — go to the troubleshooting section.

Then confirm it loaded:

```bash
kubectl -n windrose logs deployment/windrose | grep -E "RestoreBackup|Successfully loaded DB|SetCurrentIslandId"
```

Expect `Restore backup <WorldID>_<GameVersion>_Latest requested`, `Successfully loaded DB <GameVersion>/Worlds/<WorldID>`, and `SetCurrentIslandId <WorldID>`.

### Step 13. Validate in game before telling anyone

Join alone first and confirm the world is the right one: check the world name, look for recognisable structures and ships, and confirm map exploration is intact. Only then hand the address to the group.

Once it is confirmed working, the abandoned worlds the server generated during failed attempts can be deleted from `Worlds/` and `RocksDB_v2_Backups/Worlds/` with the server stopped.

---

## If the server generates a fresh world anyway

Check the island registry first — it distinguishes the causes immediately:

```bash
kubectl -n windrose logs deployment/windrose | grep -A 8 "RootDocumentsCollection::Init"
kubectl -n windrose logs deployment/windrose | grep -c "<WorldID>"
```

**The world ID does not appear in `Records`, and the grep count is 0.** The server has never seen it. The backup archive is missing, misnamed, or in the wrong place. Confirm the file is at `RocksDB_v2_Backups/Worlds/<WorldID>/<WorldID>_<GameVersion>_Latest.zip` — note there is no `<GameVersion>` directory level in the backups tree, the version belongs in the filename, and the ID appears twice.

**The world ID appears in `Records` but a new world is still created.** `WorldIslandId` in `ServerDescription.json` does not match the folder name exactly. Recheck for trailing whitespace and case. Remember the server rewrites this field itself when it falls back, so an edit that looks lost may simply have been overwritten on a later boot.

**Restore fails or the server refuses to load it.** The archive or database is incomplete or corrupt. Usually the game was still running when the files were copied, or the zip contained the folder's loose contents rather than the folder. Re-export with the game fully closed.

**Wrong tree.** The world was placed under `RocksDB` when this build reads `RocksDB_v2`, or vice versa. Recheck Step 5.

## Rolling back

```bash
kubectl -n windrose scale deployment/windrose --replicas=0
# recreate the helper pod from Step 3, then:
kubectl -n windrose exec -i windrose-shell -- \
  tar xzf - -C /server-files/R5/Saved < ~/windrose-pre-migration-backup.tar.gz
```

## Reconstructing a missing backup archive

If the world folder survived but the `_Latest.zip` did not, the archive can be rebuilt. `windrose-import/build_backup.py` does this, and `windrose-import/manifest.py` reads the RocksDB MANIFEST it depends on:

```bash
python3 build_backup.py <world-folder> <WorldID>_<GameVersion>_Latest.zip <WorldID> <GameVersion>
```

The layout is a stock RocksDB `BackupEngine` directory — `Checkpoint/meta/1`, `Checkpoint/private/1/` holding `CURRENT`, `MANIFEST-*`, `OPTIONS-*` and the WAL, and `Checkpoint/shared_checksum/` holding the `.sst` and `.blob` files — plus `AdditionalRecordFiles/WorldDescription.json` alongside `Checkpoint/`. Details that are easy to get wrong:

- `meta/1` opens with the timestamp, the DB's last sequence number, and the file count, then one `<path> crc32 <value>` line per file. The checksums are **unmasked CRC32C**, not the CRC32 in `zlib`.
- SST files are stored as `<file_number>_s<db_session_id>_<size>.sst`, where the session id comes from each SST's own `rocksdb.session.identity` table property. Blob files use `<file_number>_<crc32c>_<size>.blob` instead.
- Only files the MANIFEST still references belong in the archive. Determining that set requires replaying the MANIFEST's edits **in order**: a compaction that relocates a file between levels emits a delete for the old level and an add for the new one *within the same edit*, so collecting all deletes and subtracting them at the end wrongly drops files that are still live. A short archive gets accepted by the registry and then fails at load with `NewRandomAccessFile failed to Create/Open: <file>.sst`, taking the server into a crash loop.

Verify a rebuilt archive by unpacking it into a scratch directory — mapping `shared_checksum/<num>_..._<size>.sst` back to `<num>.sst` — and running `manifest.py` against the result. It must report every live SST present and no missing files.

This is a last resort. Getting the original archive from the world owner is always the safer path.

## One thing not verified

Whether player **characters** and personal progression travel with the world, or whether characters are stored client-side per player. The world data definitely carries structures, exploration, ships, and world progression. If characters turn out to be world-side, the server operator's character will not exist in the imported world and they will start fresh in an established world — worth knowing before the group sits down to play. Validate in Step 13.

## Sources

- Server behaviour in this guide was confirmed against `R5.log` on this cluster and the startup scripts in [indifferentbroccoli/windrose-server-docker](https://github.com/indifferentbroccoli/windrose-server-docker)
- [Dedicated World not portable to RocksDB_v2 — Steam Community](https://steamcommunity.com/app/3041230/discussions/0/837249543665987048/)
- [Windrose Save Transfer, Backups, and World Recovery — Supercraft](https://supercraft.host/wiki/windrose/save_transfer_backups_and_world_recovery/)
- [Windrose Save Location & How to Upload Your World — LOW.MS](https://low.ms/knowledgebase/windrose-save-location-how-to-upload)
- [Dedicated Server Guide — playwindrose.com](https://playwindrose.com/dedicated-server-guide/)
