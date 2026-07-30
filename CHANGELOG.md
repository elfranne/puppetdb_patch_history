<!-- Update this file before pushing a tag: GoReleaser bundles it into the release archives. -->

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-07-30

Records the version a patch actually installed. A resource event carries the value from the
catalog, not the outcome, so packages declared `ensure => latest` — which is how
`patching_as_code` declares them — were archived with the literal string `latest` and no version
at all. The version is in the agent's message, which was not being collected.

### Added

- The importer now fetches `message` from the PuppetDB `events` endpoint and stores it in a new
  `patch_package.message` column. It holds the version actually installed
  (`ensure changed '10.0.301' to '10.0.302'`), and on a failed event the provider's error text —
  the only record of why a patch did not apply.
- A `patch_history.patch_event` view, joining `patch_run` and `patch_package` and adding
  `new_version_resolved` (the version parsed out of `message`, `NULL` when there is nothing to
  parse) and `effective_version` (that value, falling back to `new_version`). **Query this rather
  than the tables.**
- `example/dashboard.json`, a Grafana dashboard for the archive: patch volume over time, version
  rollout, nodes by last patch, and failures with the provider's error text. It reads the view
  exclusively, and expects the datasource UID `grafana.pp` provisions.

### Changed

- The message is stored verbatim and parsed in the view rather than at import time, so a provider
  whose message reads differently can be accommodated with `CREATE OR REPLACE VIEW` instead of a
  re-import of data PuppetDB no longer holds.
- The profile's `$schema_applied` probe now tests for the `patch_event` view rather than the
  `patch_package_name_version_idx` index. Left on the index, an existing archive would report its
  schema as already applied and silently skip everything added here.
- Documented example queries read `patch_event` and `effective_version`. Matching on `new_version`
  finds nothing when packages are declared `ensure => latest`.

### Upgrade notes

The schema change is additive and the profile applies it in place. Install the new binary
**before** re-importing: the column is nullable, so an older binary writes rows without a message
and those cannot be resolved afterwards.

Rows imported before this version have no message, so their `effective_version` still reads
`latest`. Nothing can fill them in — PuppetDB expired the reports they came from. An archive
younger than `report-ttl` can be dropped and rebuilt instead; see
[example/INSTALL.md](example/INSTALL.md#upgrading-an-existing-archive).

[Unreleased]: https://github.com/elfranne/puppetdb_patch_history/compare/1.1.0...HEAD
[1.1.0]: https://github.com/elfranne/puppetdb_patch_history/compare/1.0.0...1.1.0
