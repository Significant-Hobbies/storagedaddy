# Publisher toolchain audit — StorageDaddy #58

Assessment: 2026-10-08. Source base: `0b6e45deea7af566a4e92b9faaf25341cef9f541`.

`wrangler` and TypeScript are development dependencies. Wrangler brings the
Miniflare, sharp and undici dependency tree into the local publisher/dev server.
The initial frozen lock audit reported four high package nodes and zero critical
nodes; Wrangler and Miniflare aggregate transitive advisories rather than adding
independent vulnerabilities.

## Applicability

The Worker entrypoint `worker.mjs` imports only release metadata, rewrites asset
URLs, and delegates to the Workers `ASSETS.fetch` binding. It does not import
sharp/undici, decode uploaded images, create WebSocket connections or construct
a BalancedPool with a custom TLS verifier. These audited npm packages belong to
the Node tooling process, not that Worker entrypoint. This source assessment does
not establish that every internal Wrangler/Miniflare path is unreachable, and
is not an exception for retaining vulnerable publisher dependencies.

- [sharp GHSA-rgj7-g3m4-5g8c](https://github.com/advisories/GHSA-rgj7-g3m4-5g8c)
  concerns untrusted HEIF/AVIF decoding through libheif; fixed in sharp 0.35.4.
  No such decoding exists in the site source. Risk remains in tooling paths that
  process attacker-controlled image input, particularly affected Linux binaries.
- [sharp GHSA-wq5f-xc86-pv6w](https://github.com/advisories/GHSA-wq5f-xc86-pv6w)
  concerns librsvg memory safety; fixed in sharp 0.35.5. SVG assets are served
  without a source-level sharp conversion pipeline. Tooling image processing is
  still the relevant boundary.
- [undici GHSA-rfgv-xxqx-mfg5](https://github.com/advisories/GHSA-rfgv-xxqx-mfg5)
  concerns a WebSocket handshake that returns an unrequested subprotocol and
  crashes its Node process. Fixed in 7.29.1 (7.x). The site source has no WebSocket
  client. Publisher/dev tooling network clients remain the potential boundary.
- [undici GHSA-w293-vg96-wgc3](https://github.com/advisories/GHSA-w293-vg96-wgc3)
  concerns BalancedPool dropping function-valued connection/TLS options,
  including custom certificate validation. Fixed in 7.29.1 (7.x). The site source
  configures no such pool or verifier. This is not a general bypass of Node's
  default certificate validation.

## Repair qualification

Wrangler is updated within its existing major to 4.148.0. Its Miniflare version
still pins sharp 0.35.4, so a narrowly nested `miniflare` override selects the
patched sharp 0.35.5. The frozen lock and installed tree resolve sharp 0.35.5 and
undici 7.29.1. TypeScript remains 6.0.3. No runtime dependency is added.

On 2026-10-08 the patched frozen installation succeeded. A complete `npm audit
--json` exited 0 with zero vulnerabilities (92 dependency nodes). The existing
`npm run check` exited 0: 19 tests, TypeScript and Wrangler deployment dry-run.
This qualifies the local candidate; a dry-run is build validation, not
publication. No native app release is required. The native application, release
guards and provider configuration remain unchanged.

Retain the sharp override until the upstream Miniflare pin resolves a patched
version without it. Candidate/main CI must be qualified after publication; do
not infer that old-main CI cleared this dependency audit.
