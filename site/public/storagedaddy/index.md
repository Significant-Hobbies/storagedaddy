# storagedaddy

> Make room. Keep building. An open-source Mac storage analyzer for developers.

Website: https://storage.daddyrad.com/
Download: https://storage.daddyrad.com/download
Source and feedback: https://github.com/sarthakagrawal927/storagedaddy

## Availability and pricing
Version 0.1.2 beta supports Apple silicon Macs with macOS 14 or later. Intel Macs are not supported. The DMG is signed and notarized. Everyone who downloads during early access gets all future versions free forever. There is no trial expiry. There is no account, checkout or subscription today. Published source remains MIT-licensed; third-party libraries and provider artwork retain their own terms.

## What it does
- Explore disk usage with live scan results, folder navigation, multiple graphs and an inspector.
- Developer Insights surfaces caches, builds, installed packages, node_modules, .git and AI storage.
- Review Cleanup collects selected files and folders before a separate confirmation moves them to Trash.
- Applications shows installed apps with native icons, size, last-used information and sorting.
- AI Sessions discovers recognized Claude and Codex histories in known local locations, with date filtering and compact exports.
- AI Context (beta) groups global skills and project context files. Instruction-load estimates are not measurements of an agent's entire runtime context.
- Save snapshots after scans to compare storage over time. Scan duration and sampled memory use are visible.

## First use
Open the DMG and drag the app into Applications. Start with Scan My Caches or choose a folder or disk. Full Disk Access is optional and enables broader coverage. Protected or unreadable locations may still be skipped. Results describe the area scanned, not necessarily total volume usage.

## Cleanup and size measurements
A scan deletes nothing. Add candidates, review the list, then explicitly confirm moving them to Trash. The app does not empty Trash automatically. On-disk means allocated storage; logical means the content size reported to apps. Shared APFS blocks, snapshots and inaccessible files can make totals differ from macOS Storage. Allocated bytes do not guarantee space reclaimed. A folder scan is a useful starting point on Macs with limited memory.

## Mac System Data
Apple's System Data is a Storage category for files that do not fit a more specific category; it is not one folder or a total storagedaddy can reproduce. It can include caches, logs and other system resources. [Download storagedaddy](https://storage.daddyrad.com/download) to scan a disk or folder for readable large files, then use Developer Insights to inspect builds and caches before adding any cleanup candidates. Protected locations, snapshots and shared APFS storage can make the scan total differ from macOS Storage. Review each choice before moving anything to Trash; allocated bytes do not guarantee reclaimed space. See [Apple's storage guidance](https://support.apple.com/102624).

## AI session archives
Powered by Memory Pack. Choose sessions by modification date and save to Desktop or another location. Exports retain prompts, replies and recognized session details in a compact ZIP. Tool payloads, attachments, reasoning and unsupported records may be omitted. These are lossy reading and analysis archives, not resumable session backups. Originals remain until a separate, confirmed cleanup. The app validates the ZIP and content hash before offering review of verified originals. Compression savings vary by session; there is no guaranteed ratio or exhaustive session-discovery claim.

## Privacy and updates
Scanning, previews and archive validation run locally. The app has no file uploads or app telemetry. Sparkle checks an HTTPS update feed and downloads updates when you choose to install them. Website analytics measure visits, sources and download clicks with anonymous browser identifiers, separately from aggregate download requests. They do not receive disk contents or app activity, and download counts do not establish installs or use. The shared Fleet footer opens a question about the public product in your chosen AI assistant only when clicked; no local files are attached.

## Feedback
Tell us what helped, what got in the way, and which developer storage sources are missing: https://github.com/sarthakagrawal927/storagedaddy/issues/new
