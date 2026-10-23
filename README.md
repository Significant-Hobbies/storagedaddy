# storagedaddy

**Yours free forever, including all future versions.** Everyone who downloads during early access gets all future versions free forever. No trial expiry.

A free, open-source Mac footprint manager for developers. Understand what
projects, applications and AI tools leave behind; find large, stale or
replaceable material; and review every cleanup before removing anything.

[Download the Mac app](https://storage.daddyrad.com/download) ·
[Website](https://storage.daddyrad.com/) ·
[Report an issue](https://github.com/sarthakagrawal927/storagedaddy/issues)

![storagedaddy exploring a generated demo folder](site/public/storagedaddy/assets/storage-explorer.png)

The screenshot shows the real app with generated demonstration files. Its
sizes and timing are not a whole-disk benchmark.

## What's included

- A native SwiftUI and AppKit explorer with live scan results, treemap and
  other visual views, folder drill-down, sorting and an inspector.
- Find Files: FinderSearch/fsearch fuzzy filename matching, recursive folder
  scope and filters (`ext:pdf`, `size:>100mb`, `mtime:<7d`, `kind:dir`) over
  existing scan metadata. Results link to the inspector and reviewed cleanup.
- Developer Insights for caches, builds, packages, node_modules, Git data and
  recognized AI storage. Scan time, entries per second and sampled memory
  make the cost of scanning visible.
- Reviewed cleanup: stage candidates, then confirm. Node dependencies and
  bounded npm/pnpm/yarn caches can bypass Trash; the review shows which folders
  will be permanently deleted and lets you choose Trash instead. Other items
  keep the Trash recovery path. Items with issues are skipped so cleanup can
  continue. Scanning never deletes files, and the app never empties Trash.
- Installed applications with icons, sizes, last-used metadata, categories
  and reviewed removal of eligible apps.
- AI Sessions for standard Claude and Codex transcript locations, independent
  of a disk scan. Older conversations can be exported locally before cleanup.
- Git worktrees grouped by repository, with current status, lock/upstream/commit
  checks and explicitly reviewed non-force Git removal. Git removal is permanent,
  includes ignored files and keeps branch refs; unknown safety evidence blocks it.
- Local scan history with per-file diffs, time-range choices and reopening saved
  maps/developer artifacts. Completed scans save by default; Settings can turn
  this off. Oversized metadata falls back to a saved summary with an explanation.
  History stops at 512 scans or 2 GB until older metadata is reviewed
  and moved to Trash. Optional per-folder retention keeps the latest 7, 14 or
  30 scans after confirmation and moves older metadata to Trash. File contents are never stored.
- Manager-native `yarn cache clean`, `uv cache clean`, `npm cache clean --force`,
  `brew cleanup -s` and `pip3 cache purge`, with cache discovery and permanent
  cleanup review. Homebrew can also remove old versions, unused dependencies,
  logs and temporary files. uv caches use its own locking-aware cleaner.
- Easy Move with a reviewed destination, symlink, verified copy, local recovery
  journal and restore. Ordinary files/folders are supported; protected runtimes,
  symlink-containing trees and unavailable cloud files are refused.
- Duplicate content checks with selectable size-group coverage, bounded parallel
  hashing, verified hash reuse, newest/oldest retention and reviewed batch moves.
- Fresh joint-removal measurement accounts for external hard links and full APFS
  clone references, and reports uncertain allocation separately.
- All accessible processes with interval CPU/RSS, app/parent grouping, per-process
  trends, one-core/system CPU scales, memory treemap, CPU heatmap,
  details and reviewed quit/force quit. A pinnable system widget shows capacity,
  scan state, CPU, memory and aggregate disk I/O (⌘⇧W).
- Opt-in drive polling, persistent free-space events and drop alerts; separately
  approved recurring full scans preserve your current page and defer for reviews.
  Polling, idle gates, scan worker presets and start-minimized behavior are configurable.
- Opt-in local MCP access for Claude/Codex and other clients, native approval,
  roles, revocation and audited removal requests. Agent access never approves
  or executes cleanup. The bundled stdio helper uses a private same-user socket;
  loopback HTTP uses native OAuth approval and PKCE. HTTP logins expire when
  the listener stops; the local transport is not an HTTPS conformance claim.
- Tree and global Size treemap layouts, stable extension colors, color-blind
  palette, dark/light/system appearance and decimal/binary units.
- Signed updates through Sparkle.
- A menu bar status item: closing the window keeps StorageDaddy available,
  scan status and cancel stay reachable, and opt-in **Launch at Login** and
  **Notify When Scan Finishes** cover scans that finish with no window open.
  Quitting during a scan, reviewed cleanup, snapshot save or conversation
  export asks before interrupting it.

These additions follow the macOS feature set of [DiskHound](https://github.com/tzarebczan/diskhound).
Its NTFS/MFT/USN scanner and per-process GPU counters are Windows features.
Per-process disk I/O is unavailable in its macOS implementation; StorageDaddy
shows measured aggregate driver I/O and explicit unavailable states instead.

## Install

The public DMG is Developer ID signed, notarized and stapled. It supports
**Apple silicon Macs with macOS 14 or later**. Download it, drag storagedaddy
into Applications and open it. Choose a disk or a folder to scan. Full Disk
Access is optional and helps with protected locations.

Automatic update checks are enabled by default. Installing an update requires
confirmation. The app menu also provides **Check for Updates…**.

Mac Controls embeds the MIT-licensed [RemoveMacAI](https://github.com/omlahore/RemoveMacAI) core for Apple Intelligence, privacy, Finder, Dock, typing, background items and storage cleanup. Changes are reviewed before applying; StorageDaddy owns a separate configuration profile and undo journal. Mac Controls requires macOS 26 or newer. Simulator and Time Machine snapshot removal is permanent and explicitly confirmed.

## Build from source

Requirements: macOS 14+, Xcode with Swift 6, Python 3, Git, and current stable
Rust with Cargo for the Memory Pack and FinderSearch helpers. Dependencies are
pinned with `Package.resolved`, `Vendor/MemoryPack/Cargo.lock`, and
`Vendor/FinderSearch/adapter/Cargo.lock`.

```sh
git clone https://github.com/sarthakagrawal927/storagedaddy.git
cd storagedaddy
swift build -c release

# Build the included archive and filename-search helpers.
python3 scripts/prepare-memory-pack.py --source Vendor/MemoryPack --build
python3 scripts/prepare-finder-search.py --build
python3 scripts/package-app.py
open artifacts/StorageDaddy.app
```

The package script creates an ad-hoc signed development app. It increments a
local build number; it does not reproduce the signing or build number of the
public DMG. Signing keys and notarization credentials are not included. The
checked-in Sparkle key is public and cannot sign updates. For a fork, configure
your own update feed and signing key before distribution.

The protected GitHub release workflow takes an exact tag and explicit version/build,
builds the checked-in Memory Pack helper, and retains a signed, notarized candidate
and signed Sparkle feed after validating their metadata. It requires the six
Developer ID/notary inputs and `SPARKLE_ED25519_PRIVATE_KEY` in the
`production-release` environment. A manual dispatch on `main` also deploys the
qualified DMG and feed to the app-owned Worker, verifies their live bytes, and
records the site manifest on `main`. The environment requires approval; ordinary
pushes run candidate CI only. Distribution remains website-only.

```sh
swift test
(cd scripts && python3 -m unittest test_sparkle_support)
cargo test --locked --manifest-path Vendor/MemoryPack/Cargo.toml
```

## Landing page

The static landing and Cloudflare Worker are under `site/`.

```sh
cd site
npm ci
npm run check
```

To preview the static page without Cloudflare, run
`python3 -m http.server 8792 --directory site/public/storagedaddy` from the
repository root. Public DMGs are hosted on the website and excluded from Git.
The deployment script requires the exact qualified DMG from `site/release.json`
to be present locally. Publishing updates additionally requires the owner's
Developer ID, notarization profile and Sparkle signing key.

## Privacy and limits

File processing stays on your Mac. There are no file uploads. Folder explanations
use your chosen local agent only when you request one; its provider policy applies.
Optional App Health foreground-session heartbeats are disabled by default.
Sparkle uses HTTPS to check for and download updates. Website request counts
are separate from app activity.

Scans can be partial when macOS denies access. On-disk sizes reflect allocated
storage; shared APFS blocks, hard links and snapshots mean totals are not a
promise of space reclaimed. Trash continues to occupy storage until you empty
it. Application associations and developer classifications are best-effort.

AI session counts describe transcript files, including nested subagent files,
not necessarily distinct conversations. Custom agent home folders are not
covered by the standard-location inventory. Agent skills, instructions, and
context policy are inventoried in ContextDaddy, not StorageDaddy.

Conversation archives retain supported prompts, replies and metadata while
omitting bulky tool traffic, attachments and other records. They are lossy
reading exports, not resumable backups. Exporting alone frees no space.
Original removal is a separate verified and confirmed cleanup action. Review
exports before sharing: credential masking is best-effort.

## License and acknowledgments

storagedaddy's original code and documentation are available under the
[MIT license](LICENSE). Third-party libraries and provider artwork retain their
own terms; see [Third-party notices](THIRD_PARTY_NOTICES.md). Acknowledgments
are also available in the app menu.

### Excluded folders

Click **Settings** at the bottom of the sidebar, or open **storagedaddy → Settings…** (⌘,) and select **Excluded Folders**. Add folders to omit them and their contents from future disk scans. Preferences save on this Mac across launches. Remove a folder from this list to include it again, then rescan for updated totals.

Exclusions also block storage cleanup of those folders, their descendants, and any parent that would contain them. Changing exclusions clears the cleanup queue and marks existing results for a rescan. Settings cannot change during an active scan or cleanup check. Independent Applications and AI tools retain their own inventory scope.

Cleanup uses one review list with a regeneration label on each item. Recognized caches and dependencies are usually regenerable; ambiguous build folders and other data are marked “Regeneration unconfirmed.” These labels are recovery guidance, not proof that an item is unused or disposable.

### Optional native App Health sessions

The published Foundation-only Swift SDK is pinned to `sass-maker/app-health`
`0.1.0`. With no valid `StorageDaddyAppHealthPublicKey` in the app's per-user
UserDefaults domain (`local.fleet.storagedaddy`), no App Health client or requests
are created. There is no bundled key. The collector is `https://health.sassmaker.com`.

The owner must first create a **StorageDaddy native public key** in App Health.
Configure that public key locally with `defaults write local.fleet.storagedaddy StorageDaddyAppHealthPublicKey -string '<owner-created-native-public-key>'`, then
restart the app. The key must match `ahk_native_` followed by 64 lowercase hex
characters. To disable reporting, remove this setting and restart the app.
Do not use an owner/admin credential or a website key.

Only SDK active-session heartbeats are sent: a temporary session identifier and
active state. There are no events, logs, user/device identifiers, filenames or scan
details. Backgrounding stops heartbeats. Termination calls `close`, with a three
second quit bound; final delivery is best effort. The SDK stores no persistent
queue. Website traffic and native sessions remain separate measurements, and
neither proves distinct people or installations. Tests use fake transports only.
Live acceptance requires a separate owner-created key and collector receipt;
this release does not configure or activate one.
