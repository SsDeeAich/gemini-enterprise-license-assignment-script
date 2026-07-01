# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **`delete_unassigned` now actually revokes licenses.** Previously every user in the
  payload carried a `licenseConfig`, so the `deleteUnassignedUserLicenses` flag was a
  no-op and users who left a group kept their license. The delete path is now a real
  reconcile: after assigning, the script lists all assigned licenses, diffs each managed
  edition against its group, and explicitly unassigns the leavers. Only editions with a
  successful group fetch are reconciled, so a transient `gcloud` error can no longer
  trigger a mass revoke. Assignment calls now always send
  `deleteUnassignedUserLicenses: false`.
- **Per-group errors no longer abort the whole run.** Under `set -e`, a failing
  `members_raw=$(get_group_members ...)` assignment aborted the script, making the
  existing error-handling branch dead code. The fetch is now branched on directly so a
  failed group is skipped and the sync continues.
- **`updateMask` uses the canonical FieldMask string form** (`"userPrincipal,licenseConfig"`)
  matching the Discovery Engine v1 schema, instead of the `{ "paths": [...] }` object form.

### Changed

- Themed the output in Google brand colors (Blue/Red/Yellow/Green, 24-bit truecolor).
- Clearer project prompts: the wizard now shows a "✓ Detected" line and an "(press Enter
  to accept)" hint so it's obvious the bracketed value is the default.

### Added

- Interactive setup wizard. Run `--setup` (or just run the script with no
  `config.json` in a terminal) for a guided flow that confirms the project, discovers
  license editions, shows each group's member count as you map it, explains the
  revocation policy, writes `config.json`, and offers a dry run before any changes.
  New flags: `--setup` (force wizard) and `--no-input` (never prompt; cron-safe).
- Wizard region auto-detection: licenses are tied to a multi-region, so the wizard probes
  a common set (`global`, `us`, `eu`, `ca`, `au`) and lists the regions where subscriptions
  actually exist for you to pick. Additional multi-regions are whitelisted per project, so
  it also offers a manual-entry option (with a note that licenses are region-bound) for any
  region it didn't probe.
- Subscription auto-resolution: set a `group_mappings` value to `"auto"` and, if the
  project has exactly one license config, the script resolves it at startup. Combined with
  the existing `project_id`/`project_number` auto-discovery, a single-edition setup needs
  only the group email in `config.json`.
- `Users revoked` count in the final summary.
