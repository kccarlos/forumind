# iCloud sync

Forumind syncs between a person's iPhone and iPad in two ways:

- **A folder the user picks in iCloud Drive** carries forums, summaries,
  chats, agent runs, watched topics, and settings as encrypted files.
- **iCloud Keychain** carries API keys and the key that encrypts the folder.

Neither needs an iCloud (CloudKit) entitlement, so sync works in builds signed
with any team, including a free personal team, and there is no server of ours
involved: the files live in the user's own iCloud Drive.

## For users

1. Open **Settings › iCloud Sync** and tap **Choose folder…**.
2. Pick **iCloud Drive**, then create or choose a folder such as
   "Forumind".
3. Do the same on each device, choosing the same folder.

API keys sync by themselves through iCloud Keychain (turn that off with
**Sync API keys**). If a device says it's waiting for iCloud Keychain, turn on
**Settings › [your name] › iCloud › Passwords and Keychain**.
**Stop syncing on this device** keeps everything already on the device.
**Reset sync data** starts a new encryption key and re-uploads from this
device.

## What syncs

| Data | Transport | Merge rule |
|---|---|---|
| API keys | Keychain items with `kSecAttrSynchronizable` | iCloud Keychain |
| Settings (except device-local ones) | `settings.json`, with a `modifiedAt` per field | per field, newest wins |
| Forums | one file per forum | newest `updatedAt` wins |
| Topic sessions: summary, chat, instructions, kept flag, counts | one file per topic | fields newest-wins; the chat history as a whole by `chatUpdatedAt` (never merged message by message, so a cleared or edited chat can't come back) |
| Agent runs, including the transcript | one file per run | newest `updatedAt` wins; follow-ups as a whole |
| Watched topics | one file per topic | newest wins; `knownPostCount` takes the maximum |

**Stays on each device:** the work queue and activity log, cached forum pages,
the browser bar position, whether the walkthrough was completed, the chosen
folder itself, panel width, and browser state.

## Folder layout

```
<picked folder>/Forumind Sync/
  format.json                    { "format": 1, "keyID": "…" }
  settings.json
  forums/<name>.json
  sessions/<name>.json
  runs/<uuid>.json
  watched/<name>.json
```

`<name>` is a lowercase hex SHA-256 prefix of the record key (topic keys
contain `/` and may be non-ASCII); the real key is inside the encrypted file.
A file is bound to its path: one whose kind or id doesn't match its folder and
name is refused, so files can't be swapped between records.

## Encryption and privacy

Every file is encrypted with AES-GCM (Apple CryptoKit) using a random 256-bit
key stored in iCloud Keychain as a synchronizable item. iCloud Drive only ever
holds ciphertext; the kind and id of each record are authenticated as part of
the encryption. The sync key is separate from API keys and always syncs, even
with **Sync API keys** off.

A device without the key (iCloud Keychain off, or not yet synced) shows
"Turn on iCloud Keychain to read synced data" and writes nothing until the key
arrives. It re-checks the Keychain at the start of every pass and whenever the
app comes to the foreground, so it recovers on its own.

If two devices create `format.json` at the same time, the lowest `keyID` wins
and the other device re-encrypts its records with that key.

## API keys

Provider API keys (`KeychainProviderKeyStore` in `Persistence.swift`) are
synchronizable Keychain items while **Sync API keys** is on (the default).

- Each launch moves any local-only key into iCloud Keychain: add the synced
  item, then delete the local copy only if the add worked. A different key
  already in iCloud Keychain is never overwritten; the local key keeps winning
  on that device.
- Turning the setting off writes local copies and leaves the synced items for
  other devices; turning it back on pushes this device's keys.
- If iCloud Keychain refuses an item, the key is stored locally instead.
- Deleting a key while it syncs deletes it on the other devices too.
- Keys are re-read from the Keychain on every foreground, because iOS sends no
  change notifications for Keychain items.

## How a sync pass works

`FolderSyncController` (main actor) owns the folder bookmark, the status shown
in Settings, and scheduling. `FolderSyncEngine` (an actor) does the work, and
`FolderSyncStorage` reads and writes files with `NSFileCoordinator`.

A pass is **pull, then push**:

1. List the folder. Files that are still iCloud placeholders are asked to
   download (`startDownloadingUbiquitousItem`) and skipped this pass; the app
   never reads a file that isn't downloaded.
2. Read changed files, merge any `NSFileVersion` conflict versions with the
   rules above, and apply the result to the app state in one main-actor step
   (`AppModel.applyRemote(_:)`), which saves locally and updates the baseline
   so nothing echoes back.
3. Diff the app state against the baseline and write only the records whose
   content changed, plus tombstones for deletions.

The baseline (per-record plaintext hashes and last-synced versions) is kept in
Application Support. Merges are deterministic (same inputs give the same
plaintext bytes, with stable key order) and the baseline compares plaintext
hashes, since AES-GCM ciphertext differs on every write. Two devices therefore
stop writing once they agree.

**When a pass runs:** about 2 seconds after a local change, when the app comes
to the foreground, every 60 seconds while it's active, when the folder reports
a change (`NSFilePresenter`, plus a best-effort `NSMetadataQuery`), on
**Sync now**, and one last push when the app goes to the background (inside a
background task).

**Running work is not disturbed.** Remote settings changes go through the same
path as local edits, so a summary or agent run that is already running keeps
the settings it started with.

## Deletions

- A deletion rewrites the record's file as a tombstone
  `{ "id", "deletedAt" }`. A tombstone wins only if it is newer than the other
  copy's last update. Tombstones older than 60 days are removed.
- Deletes are logged the moment they happen, so a delete made just before the
  app is closed, or while the folder or key is unavailable, keeps its real
  time.
- Pruning old history on one device (to stay within the app's limits) never
  writes a tombstone; that device simply doesn't re-import the pruned record
  until someone changes it.
- A device returning after longer than the tombstone lifetime treats a record
  it synced and didn't change, whose file has stayed missing for 30 minutes
  over two passes, as deleted elsewhere. A device that was active recently
  re-uploads a missing file instead. A changed local copy is always kept.
- A write that fails keeps the previous hash in the baseline, so a record that
  never reached the folder is written again rather than taken as deleted.
- When a device joins a folder that has an old tombstone for a record it still
  has, the local copy is kept (and uploaded again) if it was used after the
  delete; otherwise it is deleted.

## Resetting

- **Reset sync data** makes a new key and re-uploads everything from this
  device. Other devices notice the new key and re-read the folder.
- **Reset settings** keeps **Sync API keys** (it is device-local). With it off,
  the reset deletes this device's local keys only; with it on, it deletes the
  synced keys on every device. The settings reset itself syncs through the
  folder.

## Limits

- Setting an optional top-level setting back to "none" doesn't propagate (no
  control in the app does this today).
- A device whose clock runs fast wins concurrent edits by the amount of the
  skew; edits made after seeing its change still win.
- Records pruned on every device stay in the folder (about 4 KB per topic;
  500 topics is about 2 MB). A pass over 500 topics takes about 0.5 s (nothing
  changed) to 1 s (full check) on a simulator, off the main thread.
- Each watched-topic check updates `lastCheckedAt`, so it rewrites that
  topic's file.
- Two devices using different folders with the same name look alike in
  Settings.
- Signing matters for Keychain sync: unsigned simulator builds
  (`CODE_SIGNING_ALLOWED=NO`) can't create synchronizable items. DEBUG builds
  have `-dc-keychain-sync-probe` to check a signed build on a device (see
  [DEVELOPMENT.md](DEVELOPMENT.md)).

## Testing

Nothing touches iCloud in unit tests. The storage works on any directory, so
`FolderSyncTests` use temporary folders and simulate two devices sharing one
folder, including convergence (alternating passes stop writing).

For end-to-end checks with two simulators, point both at a folder on the host
Mac with the same fixed key:

```sh
KEY=$(head -c 32 /dev/urandom | base64)
xcrun simctl launch <sim-1> "$BUNDLE_ID" -dc-sync-folder /tmp/dc-sync -dc-sync-key "$KEY"
xcrun simctl launch <sim-2> "$BUNDLE_ID" -dc-sync-folder /tmp/dc-sync -dc-sync-key "$KEY"
```

Without `-dc-sync-folder`, sync stays off under `-dc-sample` and UI tests, so
sample data never reaches a real sync folder.

## Future: CloudKit

A CloudKit private database could replace the folder transport now that the
project can use a paid developer team: no folder to pick, and push-driven
updates instead of polling. The record model, merge rules, and encryption
above would carry over; only the storage layer (`FolderSyncStorage`) would
change.
