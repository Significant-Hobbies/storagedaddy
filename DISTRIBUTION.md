storagedaddy 0.1.4 — Beta
=======================

Apple silicon Mac · macOS 14 Sonoma or later

Yours free forever, including all future versions. Everyone who downloads during early access gets every future version free.
There is no trial expiry or subscription.

Install
-------
Drag storagedaddy to Applications, eject this disk image, then open the app
from Applications. Enable Full Disk Access when onboarding points you to
System Settings if you want a Mac-wide scan. A folder scan is also available.

Start with Scan a Disk for the complete storage picture. Quick Cache Scan checks only the current user's cache folder; a folder scan limits the result to one chosen location.
Storage opens your scan results. Explore shows scanned files; Developer Insights
groups recognized tools and projects. Review Cleanup lists your choices.
Save a snapshot from completed results to revisit it in History.

Settings is visible at the bottom of the sidebar and in the app menu (⌘,).
Use Excluded Folders to keep selected folders out of disk scans and storage
cleanup. Changes save on this Mac; rescan to refresh existing results.
Applications and AI tools keep their own inventories.
Cleanup shows regeneration guidance on each item in one review list.
“Usually regenerable” is not a guarantee that local changes can be recovered.

Your files stay under your control
---------------------------------
Scans do not delete files. Cleanup uses Trash only after confirmation.
Trash still uses space until you empty it yourself. Review all candidates:
caches and build outputs may be needed by active tools or projects.

AI Sessions → Archive saves supported older Claude/Codex conversations to
Desktop or another chosen folder. This is a lossy export of prompts, replies
and metadata, not a complete backup or a way to resume the original sessions.
Tool traffic, attachments, reasoning and unsupported records may be omitted.
Exporting keeps originals and frees no space. Redaction is best-effort; review
exports before sharing them. No guaranteed compression ratio is promised.

Privacy
-------
storagedaddy processes your files on your Mac without accounts or file uploads.
Optional App Health foreground-session heartbeats are off by default and require
a valid per-user native public key. They contain a temporary session identifier
and active state, with no events, logs, file/scan details or user/device identity. Sparkle checks for updates over HTTPS and downloads updates
when you choose to install them.
It scans file metadata. Session detail views read bounded local metadata;
skills previews read only the selected text file. Archiving reads eligible
local transcripts and writes the destination you choose. Exports can contain
private conversations. The app does not send them to a service.

Beta limitations
----------------
This build supports Apple silicon only. Permissions and protected locations
can make scans partial. On-disk allocation includes filesystem effects and is
not a promise of reclaimable space. Whole-disk scans can use substantial RAM;
folder scans are preferable on memory-constrained Macs.
Application inventory and developer classifications are best-effort.
Custom agent home folders are not automatically included in conversation exports.
AI Context is in beta. It groups discovered project instructions and shared
skills; per-agent context loads are estimates, not measured live prompts.

Acknowledgments and bundled dependency licenses are available in
Settings → Acknowledgments and the storagedaddy app menu → Acknowledgments.

## Verified original review
After a successful compact export, storagedaddy tests ZIP integrity and binds SHA-256 digests to the archive and the exact original files represented by it. Review Originals lists eligible files and requires accepting the loss of resumable history and omitted data. A separate confirmation rechecks the archive and originals before moving files to Trash. Changed, replaced, unsupported or unrepresented files are not eligible. Close active sessions first: an old modification date does not prove a session is inactive. Filesystem checks and Trash moves are not one atomic transaction. A failure stops further moves and reports partial results; Show Originals in Trash supports Finder Put Back. Export remaining originals again to start a fresh review.
