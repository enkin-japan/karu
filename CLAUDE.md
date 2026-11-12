## Model Routing Rules
- Architecture decisions, task breakdown, cross-module refactoring, and final
  review: handled directly by the main session. Never delegate these.
- Running tests / lint / documentation / commit messages / implementing a
  small function from a detailed plan: delegate to chore-worker.
- Multi-file feature implementation and moderately complex bug fixes:
  delegate to implementer.
- Every delegation must include: the specific file paths involved, and
  explicit acceptance criteria (which tests must pass).
- After a subagent completes a task that modified code, the main session must
  review the resulting diff before committing it or building further work on
  top of it.
- Escalation: a task counts as failed if its acceptance criteria are not met.
  If chore-worker fails the same task twice, escalate it to implementer. If
  implementer fails it, the main session takes over directly.
- Changes touching the following paths must never be delegated; the main
  session handles them directly:
  - scripts/bundle-macos.sh and scripts/release-macos.sh (packaging /
    signing / notarization / Sparkle signing; secret red lines: .p8, .env*,
    .secrets.env and private keys must never enter the repo, bundle or logs)
  - Signing, notarization, publishing and replacing /Applications/Karu.app
    (see docs/RELEASE.md); credentials stay referenced via the keychain
    (notary profile `tinyeditor-notary`, Sparkle EdDSA key)
  - The bundle ID `dev.enkin.TinyEditor` (Info.plist in bundle-macos.sh) must
    not change: it is the Sparkle update identity and keys user defaults,
    Application Support data and file associations. Karu does not use APNs.
- Project conventions, budgets and verification: see AGENTS.md and docs/.
- Do not delegate trivial changes (a few lines in a single file); the main
  session does them directly, as delegation overhead is not worth it.
