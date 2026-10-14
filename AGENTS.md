# StorageDaddy agent instructions

Read `PRODUCT.md` before changing product scope. Preserve measured storage
accounting, local-only scanning, and explicit review and recovery for cleanup.

- Follow the shared global autonomy policy: finish work within the owner's
  requested scope, including local builds, tests, signing, packaging,
  installation, verification, commits and pushes, without extra approvals.
- Ask only before a public release. Existing user-facing product consent,
  reviewed actions and recovery requirements still apply.

- Use XcodeBuildMCP for native build, test, run and UI verification; run focused
  checks before the full package suite.
