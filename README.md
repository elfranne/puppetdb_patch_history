# puppetdb_patch_history

Keep a permanent record of what [`puppet/patching_as_code`](https://forge.puppet.com/modules/puppet/patching_as_code)
patched, where, and when.

PuppetDB expires reports after `report-ttl` — **14 days by default** — which means the answer to
"when did we last patch `openssl` on this host?" disappears two weeks after it happened.
`puppetdb_patch_history` copies package-update events out of PuppetDB into a PostgreSQL archive
before they expire, so the history sticks around for as long as you want it.

It is a **one-shot import job**, not a daemon: you run it on a timer (systemd, cron), it imports
everything new since last time, and exits. It binds no port, exposes no HTTP API, and emits no
metrics — the archive is a plain Postgres database you query with `psql` or point Grafana at.

## How it works

1. Queries the PuppetDB `events` endpoint for `Package` resources where the `ensure` property
   changed, with status `success` or `failure`.
2. Groups the events by **report hash**, because that is the only field identifying a single
   Puppet run — the per-event `timestamp` differs between packages in the same run.
3. Inserts each run and its packages in one transaction, keyed on the report hash.
4. Derives its watermark from `max(report_received_at)` in the archive rather than a state file.
   There is nothing to corrupt and nothing to reset.
5. Is safe to re-run: an already-imported report hash conflicts and is skipped, so a crashed or
   killed run simply re-reads the same window next time.

The window is bounded on **when PuppetDB received the report**, not when the run started. A report
only becomes queryable once its run finishes, so a twenty-minute patch run lands *after* a
two-minute run that started later. Tracking start times would leave that long run permanently
below the cutoff, and it would be lost for good once PuppetDB expired it — which is exactly
backwards, since long runs are the interesting ones. `run_at` is still recorded and is what you
should query on; it is just not what the importer paginates by.

## Installation

**See [`example/INSTALL.md`](example/INSTALL.md)** for the walkthrough, and
[`example/puppetdb_patch_history.pp`](example/puppetdb_patch_history.pp) for a ready-to-copy Puppet
profile that manages the binary, the archive database and its schema, the privileges, and the
systemd timer in one pass.

Deployment is via Puppet: the importer needs its schema and grants in place before it will run,
and the profile is what puts them there.

To read the archive from Grafana, [`example/grafana.pp`](example/grafana.pp) provisions it as a
read-only PostgreSQL datasource on the Grafana node. It needs no password — the connection is
authenticated by that node's Puppet agent certificate.

Prebuilt Linux tarballs (`amd64`, `386`, `arm64`, `arm` v5/v6/v7) are attached to each
[release](https://github.com/elfranne/puppetdb_patch_history/releases) with SHA-512 checksums —
those are what the profile downloads.

## Usage

| Flag | Env var | Default | Description |
| --- | --- | --- | --- |
| `-puppetdb` | `PUPPETDB_URL` | `http://localhost:8080` | PuppetDB base URL |
| `-db` | `DATABASE_URL` | `postgres:///patch_history?host=/var/run/postgresql` | PostgreSQL connection string |
| `-page-size` | — | `5000` | Events fetched per PuppetDB query |
| `-since` | — | *(unset)* | RFC3339 report receive time to import from, overriding the watermark |
| `-backfill` | — | `720h` (30 days) | How far back to look when the archive is empty |
| `-grace` | — | `1h` | How far back before the watermark to re-check each run |
| `-containing-class` | — | *(unset)* | Regex matched against `containing_class` |
| `-timeout` | — | `10m` | Overall deadline |
| `-dry-run` | — | `false` | Fetch and report, but write nothing |
| `-verbose` | — | `false` | Log every PuppetDB page fetch |

Precedence is **flag → environment variable → built-in default**. There is no config file.

Progress is logged as `slog` key=value lines on **stderr**; exit status is `0` on success and `1`
on any error.

### Quick start

See what would be imported, without touching the database:

```sh
puppetdb_patch_history \
  -puppetdb http://puppetdb.example.com:8080 \
  -since "$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  -dry-run
```

Then import for real:

```sh
puppetdb_patch_history -puppetdb http://puppetdb.example.com:8080
```

```text
time=2026-07-28T09:41:02.114+02:00 level=INFO msg=importing since=2026-06-28T07:41:02Z
time=2026-07-28T09:41:04.902+02:00 level=INFO msg=fetched events=1832 runs=274
time=2026-07-28T09:41:05.771+02:00 level=INFO msg=done runs_imported=274 runs_already_present=0
```

### Backfilling

On an empty archive the first run reaches back `-backfill` (30 days by default). Raising it beyond
your PuppetDB `report-ttl` gains you nothing — data PuppetDB has already expired is gone.

Once the archive has rows, `-backfill` is ignored and the watermark takes over. To re-import an
older window anyway, override it explicitly:

```sh
puppetdb_patch_history -since 2026-05-01T00:00:00Z
```

That is always safe: runs already in the archive are recognised by their report hash and skipped.

`-since` and `-backfill` are both in terms of **when PuppetDB received the report**, matching the
watermark. For a backfill the distinction is immaterial — a report is received within one run's
duration of its start.

### The grace window

Each run re-reads the last `-grace` (1 hour by default) before the watermark. PuppetDB assigns a
receive time when it accepts a report, but reports do not become *visible* in exactly that order,
so one received just before the newest report you hold can appear a moment after it. Re-reading
that window costs one extra query and nothing else: already-imported runs collide on
`report_hash` and are skipped.

Widen it if your PuppetDB is heavily loaded or its clock drifts against the importer's. Setting
`-grace 0` is supported and still correct for the common case, but gives up that safety margin.

## Filtering to patching_as_code only

By default the tool archives **every** `Package`/`ensure` change Puppet makes — a new package
added to a profile looks the same as a patch run. Use `-containing-class` to keep only the changes
that came from `patching_as_code`:

```sh
puppetdb_patch_history -containing-class '^Patching_as_code'
```

The value is a regex handed to PuppetDB, matched against the event's `containing_class`. Class
names arrive capitalised (`Patching_as_code::Patchday`), which is what the anchor above expects.
Backslash escapes such as `\b` are passed through intact, so quote the pattern in your shell.

The [example profile](example/puppetdb_patch_history.pp) sets this through its `containing_class`
parameter, which defaults to the same `^Patching_as_code`.

To check what you would be filtering on, look at the classes in your own data first:

```sh
curl -s -X POST http://puppetdb.example.com:8080/pdb/query/v4 \
  -H 'Content-Type: application/json' \
  -d '{"query":"events[containing_class]{ resource_type = \"Package\" and property = \"ensure\" order by containing_class }"}' \
  | sort -u
```

## Schema

The archive lives in a **`patch_history` schema**, defined by the `$schema_sql` heredoc in the
[example profile](example/puppetdb_patch_history.pp) and applied by Puppet before the importer
first runs.

The importer does **not** create it. Its database role holds no `CREATE` privilege and cannot
`UPDATE`, `DELETE`, `TRUNCATE` or `DROP` either: it only reads a watermark and appends rows. An
archive that exists because PuppetDB has already discarded the data should not be droppable by the
thing that fills it.

`patch_run` — one row per Puppet run that changed at least one package:

| Column | Notes |
| --- | --- |
| `certname` | The node's Puppet certname |
| `report_hash` | PuppetDB report hash; `UNIQUE`, and what makes re-imports idempotent |
| `run_at` | The report's `run_start_time`, not the per-event timestamp — query on this |
| `report_received_at` | When PuppetDB accepted the report. Bookkeeping: the importer's watermark advances on this, because a long run lands *after* a shorter one that started later |

`patch_package` — one row per package changed in that run:

| Column | Notes |
| --- | --- |
| `run_id` | References `patch_run(id)`, `ON DELETE CASCADE` |
| `package` | The Puppet resource title |
| `old_version` | Version before the change; the literal string `absent` for a newly installed package |
| `new_version` | Version after the change; the literal string `absent` if the package was removed |
| `status` | `success` or `failure` — **failed patches are archived deliberately** |

Version values are stored as PuppetDB reports them. Package providers are inconsistent: usually a
version string, sometimes `absent`, occasionally an array of candidate versions (stored
comma-joined, e.g. `8.5.0,8.6.0`). No attempt is made to parse or compare them, so treat these
columns as opaque labels — `ORDER BY new_version` is string ordering, not version ordering.

Only a JSON `null` from PuppetDB becomes SQL `NULL`; `absent` is stored as text. A query for
"packages that were newly installed" therefore wants `old_version = 'absent'`, not
`old_version IS NULL`.

## Example queries

Recent patch activity on one node:

```sql
SELECT r.run_at, p.package, p.old_version, p.new_version, p.status
FROM patch_history.patch_run r
JOIN patch_history.patch_package p ON p.run_id = r.id
WHERE r.certname = 'web01.example.com'
ORDER BY r.run_at DESC
LIMIT 50;
```

Which hosts received a specific package version, and when:

```sql
SELECT r.certname, min(r.run_at) AS first_seen
FROM patch_history.patch_run r
JOIN patch_history.patch_package p ON p.run_id = r.id
WHERE p.package = 'openssl'
  AND p.new_version LIKE '3.0.13%'
GROUP BY r.certname
ORDER BY first_seen;
```

Packages that failed to patch in the last 30 days:

```sql
SELECT r.certname, p.package, p.old_version, p.new_version, max(r.run_at) AS last_failure
FROM patch_history.patch_run r
JOIN patch_history.patch_package p ON p.run_id = r.id
WHERE p.status = 'failure'
  AND r.run_at > now() - interval '30 days'
GROUP BY r.certname, p.package, p.old_version, p.new_version
ORDER BY last_failure DESC;
```

Patch volume per month:

```sql
SELECT date_trunc('month', r.run_at) AS month,
       count(DISTINCT r.certname) AS nodes,
       count(*)                   AS packages
FROM patch_history.patch_run r
JOIN patch_history.patch_package p ON p.run_id = r.id
GROUP BY month
ORDER BY month DESC;
```

## Limitations

- **No PuppetDB authentication.** Requests are plain HTTP with no client certificate, CA bundle,
  or RBAC token. The default port `8080` is PuppetDB's unauthenticated cleartext port; reaching
  the mTLS port `8081` needs a reverse proxy, `stunnel`, or an SSH tunnel in front of it. Run the
  importer on the PuppetDB host, or restrict `8080` to it.
- **The schema must exist before the first run.** The importer no longer creates it, so a database
  that has not had the schema applied fails immediately — with a message saying so, rather than a
  bare SQLSTATE.
- **A node only appears if it had at least one package change.** No rows for a host means "nothing
  to patch" *or* "not patched" — this archive cannot distinguish them. Don't use it alone to prove
  a node is unpatched; use PuppetDB `nodes` / `report_timestamp` for that.
- **Nothing prunes the archive.** Unbounded growth is the point. Roughly a few hundred bytes per
  changed package, so a thousand nodes patching monthly is on the order of tens of MB a year —
  but add your own retention if you need one.
- **You cannot recover what PuppetDB has already dropped.** The archive starts the day you start
  running this, whatever `-backfill` says.
- **Pagination is offset-based over live data.** Events are ordered by
  `(report_receive_time, report, resource_title)`, a total order, so rows cannot slip between
  pages the way they can when a sort key has ties. Ascending receive time also means reports
  arriving mid-import append *past* the last page rather than shifting rows already read. The
  residual case is a report being **deleted** from inside the window mid-import — PuppetDB expiring
  reports during a long backfill — which shifts rows backward and can step over one. Reports
  expire at the old end of the archive, far below the watermark in steady-state operation, so this
  only realistically applies to a backfill that overlaps `report-ttl`.
- **Everything is buffered in memory** before the first insert. Fine for normal windows; a very
  large backfill is better split into several `-since` runs.

## Development

```sh
go build ./...
go vet ./...
go test ./...
golangci-lint run
```

Tests cover the pure logic — PQL construction and escaping, event-value normalisation, and
grouping events into runs. The PuppetDB and PostgreSQL paths are not covered by unit tests; use
`-dry-run` against a real PuppetDB to exercise those.

CI runs `go test` and `golangci-lint` on every push. Releases are built by
[GoReleaser](https://goreleaser.com/) when a tag is pushed:

```sh
git tag 0.1.0
git push origin 0.1.0
```

Update [`CHANGELOG.md`](CHANGELOG.md) before tagging — it is bundled into the release archives.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
