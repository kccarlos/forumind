# iCloud sync

Forumind syncs between a person's iPhone and iPad in two ways:

- **CloudKit** carries forums, summaries, chats, Ask the forum runs, watched
  topics, and settings, in the app's private database in the user's own
  iCloud account. It is **on by default** whenever the device is signed in to
  iCloud; there is nothing to set up.
- **iCloud Keychain** carries API keys (**Sync API keys**, on by default).

There is no server of ours involved.

## For users

- Sign in to the same Apple Account on each device. Sync starts by itself.
- **Settings › iCloud Sync** shows the status and when the last sync
  finished, with **Sync now**, the **Sync with iCloud** switch (turns sync off
  on this device only), **Sync API keys**, "What syncs", and **Delete iCloud
  data**.
- The status says what to fix: "Sign in to iCloud in the Settings app" (no
  account), "iCloud is turned off for Forumind in Settings › [your name] ›
  iCloud" (restricted), the reason CloudKit gave (unavailable), or the error
  with **Sync now**.
- Synced data counts toward the user's iCloud storage. When iCloud is full,
  the status shows the error; local data is unaffected.

## What syncs

Every synced item is one CloudKit record. A record is a set of *units* (a
top-level field of the model, or a few fields that must travel together),
each with a `modifiedAt` stamp. Merging two copies picks, per unit, the copy
with the newest stamp, except where the table says otherwise. Stamps come
from diffing against the baseline (what both sides last agreed on), so a
unit this device didn't touch can't beat a remote edit.

| Data | Record kind | Merge rule |
|---|---|---|
| Settings, except device-local ones | `settings` (one record) | per setting, newest wins; each provider configuration is one unit, without its API key; the Summaries & chat model (`assistantModel`) and the Ask the forum model (`agentModel`) are separate units, so two devices changing different ones both keep their change |
| Forums | `forum`, one per forum | newest wins; `addedAt` takes the minimum, `lastVisitedAt` the maximum |
| Topic sessions: summary, chat, instructions, kept flag, counts | `session`, one per topic | newest wins per unit; the chat history is one unit (never merged message by message, so a cleared or edited chat can't come back), and the summary travels with its post count, time, provider, and model; `createdAt` min, `updatedAt` / `lastAccessedAt` max |
| Ask the forum runs, including the transcript | `run`, one per run | the run as a whole, newest wins |
| Watched topics | `watched`, one per topic | newest wins; `knownPostCount` takes the maximum |

An unkept chat that expired (24 hours idle) counts as cleared on every
device.

**Model roles and older builds.** Builds from before model roles read
`selectedProvider` and that provider's configured model. Newer builds keep
both equal to the Summaries & chat model, so an older build on another device
runs the same model. When an older build changes the provider (or that
provider's model), the change moves the Summaries & chat model only; the Ask
the forum model stays. Because the Summaries & chat model is stored in
three units (`assistantModel`, `selectedProvider`, and that provider's
configuration), a merge can pair one device's model with another device's
provider or configuration (a same-second tie, or an edit to that provider's
address on a device that hadn't seen the new model yet). The merge settles
this in the record itself: the newest of those units leads (a tie goes to
`assistantModel`) and the others follow, so every device computes the same
record and nothing flips back and forth. A synced model whose provider has
no key on a device shows that role as not ready there ("Set up" in Settings › AI models, and the
setup card in that mode); the other role keeps working.

**Stays on each device:** API keys (they sync only through iCloud Keychain),
**Sync API keys**, whether sync is on, the work queue and activity log,
fetched topic text and cached forum pages, each device's last watch check,
the browser bar position, whether the walkthrough was completed, panel width,
and browser state.

## Encryption and privacy

Each record's content (the record id, every unit, and the stamps) is one
JSON payload stored in the record's **`encryptedValues`**, which CloudKit
encrypts end to end with keys from the user's iCloud Keychain: neither Apple
nor the developer can read it. The unencrypted fields are only what the
engine needs without decrypting: the record kind, a format version, and the
deletion time of a tombstone. The record name is `settings` or the first 40
hex digits of the SHA-256 of `kind/id`, so forum addresses and topic ids
never appear in plain form.

The developer can't see users' private databases at all; the CloudKit Console
shows only the signed-in developer's own data.

## API keys

Provider API keys (`KeychainProviderKeyStore` in `Persistence.swift`) are
synchronizable Keychain items while **Sync API keys** is on (the default).
They never go into CloudKit.

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

## How it works

`CloudSyncController` (main actor) owns the status shown in Settings, the
on/off switch, and scheduling. `CloudSyncEngine` (an actor) keeps a mirror of
the server's records and a baseline, and plans each pass. `CloudKitTransport`
wraps a `CKSyncEngine` on the private database, zone `Forumind`, and turns the
engine's outbox into CloudKit records. `SyncRecords.swift` defines the record
model and merge rules, and `AppModel+CloudSync.swift` converts app state to
and from records.

A **pass** merges the app state, the mirror, and the baseline, applies remote
changes to the app in one main-actor step (`AppModel.applyRemote`), and queues
the records whose merged content differs from the server's copy. Merges are
deterministic (same inputs give the same plaintext bytes), so two devices
stop sending once they agree.

**When it runs:** about 2 seconds after a local change, after every fetch,
when the app comes to the foreground, on **Sync now**, and a last send when
the app goes to the background (inside a background task). Changes from other
devices arrive as silent CloudKit pushes (`remote-notification` background
mode, `aps-environment` entitlement), and `CKSyncEngine` fetches them.

**Joining.** A device that starts syncing (first launch, sync turned back on,
another account) fetches everything first and sends nothing until that fetch
completes, then merges its local data in.

**Conflicts.** If another device saved a record in between, CloudKit rejects
the send; the engine merges the server's copy and sends the result.

**Running work is not disturbed.** Remote settings changes go through the same
path as local edits, so a summary or agent run that is already running keeps
the settings it started with.

## Deletions

- A deletion replaces the record's payload with a tombstone. A tombstone wins
  only if it is newer than the other copy's last update. Tombstones older than
  60 days are deleted from the server.
- Deletes are logged the moment they happen (`cloudsync-deletions.json`), so
  a delete made just before the app is closed keeps its real time.
- Pruning old history on one device (to stay within the app's limits) never
  writes a tombstone; that device simply doesn't re-import the pruned record
  until someone changes it.
- A device returning after longer than the tombstone lifetime re-lists the
  whole zone first, and treats a record it synced and didn't change that is
  gone from the server as deleted elsewhere.

## Account changes, turning off, deleting

- **Signing out of iCloud** stops sync and forgets the server state; local
  data stays. The next sign-in joins from scratch.
- **Another Apple Account** signs in: the old account's server state is
  forgotten and the device joins the new account's zone with its local data.
- **Sync with iCloud off** stops sync on this device and forgets the server
  state; local data and the iCloud copy stay, and other devices keep syncing.
  Turning it back on joins again.
- **Delete iCloud data** deletes the `Forumind` zone, which removes the
  iCloud copy for every device, and turns sync off here. Other devices notice
  the deleted zone and turn sync off too, rather than uploading everything
  again. Local data stays on every device.
- If the user removes the app's data in iOS Settings › iCloud, or iCloud's
  end-to-end encryption keys are reset, the device uploads its data again.
- **Reset settings** keeps **Sync API keys** (it is device-local). With it off,
  the reset deletes this device's local keys only; with it on, it deletes the
  synced keys on every device. The settings reset itself syncs.

## Requirements and limits

- CloudKit needs a build **signed with a paid team** and the iCloud
  entitlement. The generator turns CloudKit on only when a team is set
  (`CLOUDKIT_ENABLED`); unsigned builds, CI, and unit tests have no transport
  and show "Sync needs a signed build". See
  [DEVELOPMENT.md](DEVELOPMENT.md#icloud-sync-cloudkit-and-signing).
- Everything counts toward the user's iCloud storage (a few KB per topic).
- A record holds at most about 900 KB of payload (CloudKit's limit is 1 MB).
  Payloads over 128 KB are LZFSE-compressed; an Ask the forum run that still
  doesn't fit keeps its goal and the newest transcript messages that do.
- An Ask the forum run syncs once it has finished; work that is running on a
  device is never changed by a remote edit.
- A device whose clock runs fast wins concurrent edits by the amount of the
  skew; edits made after seeing its change still win.
- Signing matters for Keychain sync too: unsigned simulator builds
  (`CODE_SIGNING_ALLOWED=NO`) can't create synchronizable items. DEBUG builds
  have `-dc-keychain-sync-probe` to check a signed build on a device.

## CloudKit schema

Development builds create the schema in the container's **development**
environment as they sync. TestFlight and App Store builds use the
**production** environment, so before the first TestFlight build (and after
any release that adds a record type or field), open
[CloudKit Console](https://icloud.developer.apple.com) › the container
(`iCloud.<BUNDLE_ID_PREFIX>`) › Schema, check it, and **Deploy Schema Changes**
to production. Without it, every save in a TestFlight or App Store build
fails.

Fields only appear in the development schema once a record has used them, and
syncing alone may never write some of them (`deletedAt` is only set on a
deleted item). Before deploying:

1. Run a signed development build once with `-dc-cloudkit-probe`; the probe
   saves a record with every field below, so the development schema is
   complete.
2. In CloudKit Console, compare `SyncRecord`'s fields with the table below.
3. Deploy, then check the same fields in the **Production** environment.

A field missing from Production makes every save fail with "cannot create or
modify field … in production schema".

| Record type | Field | Type | Notes |
|---|---|---|---|
| `SyncRecord` | `kind` | String | `settings`, `forum`, `session`, `run`, `watched` |
| | `formatVersion` | Int(64) | payload format (1) |
| | `deletedAt` | Date/Time | set on deleted items; written (as empty) on every save, so it must exist |
| | `payload` | Bytes, **encrypted** | the record's JSON (id, units, stamps) |

Zone: `Forumind` (custom zone in the private database). No indexes are
needed: records are only fetched through zone changes, never queried. Forks
use their own container (`iCloud.<BUNDLE_ID_PREFIX>`) and deploy the same
schema to it.

## Testing

Nothing touches iCloud in unit tests: `CloudSyncTests` drive the controller
and engine through an in-memory fake transport (`CloudSyncFakes.swift`),
including two devices converging, conflicts, deletes, account changes, and
zone deletion.

End-to-end checks need two devices (or a device and a simulator signed in to
iCloud) on the same Apple Account, both running a signed build generated with
a team. Watch the status in Settings › iCloud Sync on both, change something
on one, and check it arrives on the other. DEBUG builds also have
`-dc-cloudkit-probe`, which logs the account status and a round trip through
a test record.

Sync stays off under `-dc-sample` and the UI tests' `-ui-test-*` arguments,
so sample data never reaches iCloud. `-dc-sync-status <status>` fakes the
status shown in the UI for screenshots ([DEVELOPMENT.md](DEVELOPMENT.md#sync)).
