"""Verify a Windrose world backup archive is complete and uncorrupted.

The archive carries its own inventory at Checkpoint/meta/1: a timestamp, the DB's
last sequence number, a file count, then one "<path> crc32 <value>" line per file.
This checks every listed file is present with a matching unmasked CRC32C, which is
what catches a zip copied while the server was midway through rewriting it.

Exits non-zero on any mismatch. Prints the world name and sequence number so a sync
can report how much progress it is carrying.
"""
import json
import sys
import zipfile

POLY = 0x82F63B78
TBL = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (POLY if _c & 1 else 0)
    TBL.append(_c)


def crc32c(data):
    c = 0xFFFFFFFF
    for b in data:
        c = TBL[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF


def fail(msg):
    print(f"ARCHIVE INVALID: {msg}", file=sys.stderr)
    sys.exit(1)


def main(path):
    try:
        z = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        fail(f"not a readable zip ({e})")

    with z:
        bad = z.testzip()
        if bad:
            fail(f"corrupt zip member {bad}")

        names = set(z.namelist())
        if 'Checkpoint/meta/1' not in names:
            fail("no Checkpoint/meta/1 - this is not a BackupEngine archive")
        if 'AdditionalRecordFiles/WorldDescription.json' not in names:
            fail("no AdditionalRecordFiles/WorldDescription.json")

        lines = z.read('Checkpoint/meta/1').decode().splitlines()
        if len(lines) < 3:
            fail("meta/1 is truncated")
        last_seq, count = lines[1], int(lines[2])
        entries = [l for l in lines[3:] if l.strip()]
        if len(entries) != count:
            fail(f"meta/1 declares {count} files but lists {len(entries)}")

        ssts = 0
        for line in entries:
            rel, _, expected = line.rsplit(' ', 2)
            member = 'Checkpoint/' + rel
            if member not in names:
                fail(f"listed file missing from archive: {rel}")
            data = z.read(member)
            actual = crc32c(data)
            if actual != int(expected):
                fail(f"checksum mismatch on {rel}: meta says {expected}, got {actual}")
            if rel.endswith('.sst'):
                ssts += 1

        desc = json.loads(z.read('AdditionalRecordFiles/WorldDescription.json'))
        world = desc.get('WorldDescription', {})

    print(f"world name     {world.get('WorldName', '<unknown>')}")
    print(f"island id      {world.get('islandId', '<unknown>')}")
    print(f"last sequence  {last_seq}")
    print(f"files verified {count}  ({ssts} SSTs)  all checksums match")


if __name__ == '__main__':
    main(sys.argv[1])
