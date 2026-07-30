# Installing puppetdb_patch_history

Deploy it with Puppet: the profile sets up the binary, the archive database and schema, the
privileges, and the schedule in one pass.

Put it on the **PuppetDB host**. The importer speaks plain HTTP to PuppetDB's unauthenticated
port, and its default connection string is a local unix socket.

- [Prerequisite: PostgreSQL SSL](#prerequisite-postgresql-ssl)
- [Deploying with Puppet](#deploying-with-puppet)
- [Read-only access for Grafana](#read-only-access-for-grafana)
- [The Grafana datasource](#the-grafana-datasource)
- [The dashboard](#the-dashboard)
- [Upgrading an existing archive](#upgrading-an-existing-archive)
- [Troubleshooting](#troubleshooting)

## Prerequisite: PostgreSQL SSL

The profile's Grafana access is authenticated by **client certificate against the Puppet CA**, so
PostgreSQL has to be told about that CA. The puppetdb module does it for you:

```puppet
class { 'puppetdb':
  postgresql_ssl_on       => true,
  database_host           => $facts['networking']['fqdn'],
  database_listen_address => '0.0.0.0',
}
```

`postgresql_ssl_on => true` makes `puppetdb::database::ssl_configuration` set:

| `postgresql.conf` | Value |
| --- | --- |
| `ssl` | `on` |
| `ssl_cert_file` | `${datadir}/server.crt` — copy of the node's Puppet cert, `postgres` `0600` |
| `ssl_key_file` | `${datadir}/server.key` — copy of the node's Puppet key, `postgres` `0600` |
| `ssl_ca_file` | `/etc/puppetlabs/puppet/ssl/certs/ca.pem` — the Puppet CA |

**Without this there is no `ssl_ca_file`, so PostgreSQL has nothing to validate client certificates
against and `cert` authentication cannot work at all.** The symptom is a connection rejected before
any password or role is considered.

Two things to be aware of:

- `database_listen_address => '0.0.0.0'` exposes 5432 on **every** interface. `pg_hba` still gates
  who may authenticate, but a host firewall limited to your Grafana host is worth having.
- `database_host` should be the FQDN, not `localhost`, because with SSL the hostname is checked
  against the server certificate.

## Deploying with Puppet

### 1. Module dependencies

```ruby
# Puppetfile
mod 'puppetlabs-postgresql'
mod 'puppetlabs-stdlib'
mod 'puppetlabs-concat'
mod 'puppet-systemd'
mod 'puppet-archive'
```

Pin these to the versions you have already tested with. `puppetlabs-postgresql` needs
`puppetlabs-concat`; the rest are used directly by the profile.

### 2. Add the profile

The manifests live in this repository, not in the release archives — they belong in your control
repo under version control, not deployed to a server. Clone it and copy
[`puppetdb_patch_history.pp`](puppetdb_patch_history.pp) across. It is self-contained; the archive
schema is inlined in the manifest, so there is nothing else to place:

```sh
git clone https://github.com/elfranne/puppetdb_patch_history
cp puppetdb_patch_history/example/puppetdb_patch_history.pp \
   site-modules/profile/manifests/puppetdb_patch_history.pp
```

The class is named `profile::puppetdb_patch_history`, so Puppet's autoloader expects it at
`profile/manifests/puppetdb_patch_history.pp`. If you keep profiles somewhere else, rename the
class to match its path.

What it manages:

| Resource | Purpose |
| --- | --- |
| `group` / `user` | The unprivileged account the timer runs as |
| `postgresql::server::role` | The importer's role, and `grafana_ro` |
| `postgresql::server::database` | The archive database |
| `postgresql_psql` | Applies the archive schema as `postgres`, so `postgres` owns the tables |
| `postgresql::server::grant` | Least-privilege access for both roles |
| `postgresql_psql` (grants) | `SELECT` for `grafana_ro` on every relation in the schema, views included, and `ALTER DEFAULT PRIVILEGES` so later ones are covered |
| `postgresql::server::pg_hba_rule` | `peer` for the importer, `hostssl`+`cert` for Grafana |
| `postgresql::server::pg_ident_rule` | Maps the Grafana certificate CN to `grafana_ro` |
| `archive` + `file` | Stages the release under `/var/cache/puppetdb_patch_history`, installs the binary as `/usr/local/bin/puppetdb_patch_history` |
| `systemd::timer` | The `.service` and `.timer` units, enabled and started |

### 3. Configure it

```yaml
# data/nodes/puppetdb.example.com.yaml
profile::puppetdb_patch_history::grafana_certname: 'grafana.example.com'
profile::puppetdb_patch_history::version: '1.1.0'
profile::puppetdb_patch_history::checksum: '<sha512 from the release checksums file>'
profile::puppetdb_patch_history::oncalendar: 'hourly'
```

```puppet
include profile::puppetdb_patch_history
```

`grafana_certname` is the only parameter without a default — it is the certname of your Grafana
node, and it must match the CN of the Puppet agent certificate that node presents.

| Parameter | Default | Description |
| --- | --- | --- |
| `grafana_certname` | *(required)* | Certname of the Grafana node, mapped to `grafana_ro` |
| `version` | `'1.1.0'` | Release to install, as the git tag reads (no `v` prefix) |
| `checksum` | `undef` | SHA-512 of the release tarball |
| `puppetdb_url` | `'http://localhost:8080'` | PuppetDB base URL |
| `containing_class` | `'^Patching_as_code'` | Regex limiting the import to patch runs |
| `db_name` | `'patch_history'` | Archive database name |
| `db_user` | `'patch_history'` | PostgreSQL role and OS user |
| `db_schema` | `'patch_history'` | Schema holding the archive |
| `db_socket_dir` | `'/var/run/postgresql'` | PostgreSQL unix socket directory |
| `oncalendar` | `'hourly'` | systemd `OnCalendar` expression |
| `randomized_delay` | `'5m'` | systemd `RandomizedDelaySec` |
| `grafana_user` | `'grafana_ro'` | Name of the read-only role |
| `grafana_clientcert` | `'verify-full'` | `pg_hba` clientcert mode; use `'1'` on PostgreSQL < 12 |

`db_schema` must match the schema name compiled into the binary. Changing it here alone will break
the importer.

The import interval only needs to be comfortably shorter than your PuppetDB `report-ttl`. Hourly is
a reasonable default, and `Persistent=true` means a node that was down catches up on boot; a missed
window heals itself as long as the gap stays under `report-ttl`.

### 4. Verify

```sh
systemctl list-timers puppetdb-patch-history.timer
systemctl start puppetdb-patch-history.service   # run once now
journalctl -u puppetdb-patch-history.service
```

A healthy first run looks like this:

```text
level=INFO msg=importing since=2026-06-28T07:41:02Z
level=INFO msg=fetched events=1832 runs=274
level=INFO msg=done runs_imported=274 runs_already_present=0
```

### Why the profile looks the way it does

- **No password anywhere, for either role.** The importer's OS user and PostgreSQL role share a
  name, so `peer` auth over the unix socket needs no secret. Grafana authenticates with its Puppet
  agent certificate. Nothing to store or rotate.
- **`postgres` owns the tables, not the importer.** The schema is applied by Puppet as `postgres`,
  so the importer can be append-only. It has no `CREATE`, and cannot `UPDATE`, `DELETE`,
  `TRUNCATE` or `DROP` — it reads a watermark and adds rows, which is all it does. An archive that
  exists because PuppetDB already discarded the data should not be droppable by the thing filling
  it.
- **The archive lives in its own `patch_history` schema, not `public`.** A freshly created schema
  grants the built-in `PUBLIC` pseudo-role nothing, so there is no ambient `CREATE` to revoke and
  no behavioural difference between PostgreSQL 14 and 15+.
- **`include postgresql::server` is deliberate.** On the PuppetDB host that class is already
  declared by `puppetdb::database::postgresql`. `include` is idempotent, so this reuses the
  PostgreSQL instance PuppetDB already runs on rather than standing up a second one. It also has
  to be in the catalog regardless, because the `postgresql::server::*` defined types read its
  class variables.
- **Set `checksum`.** It is optional only so the example applies without editing. Pin it to the
  SHA-512 from the release's checksums file for anything real.
- **`ProtectSystem=full`, not `strict`.** `strict` would mount `/run` read-only, where the
  PostgreSQL socket lives. `full` still protects `/usr`, `/boot`, and `/etc`.

## Read-only access for Grafana

The profile creates a `grafana_ro` role that can read the archive and nothing else. It has **no
password**: it authenticates with the Grafana node's Puppet agent certificate, validated against
the Puppet CA that [`postgresql_ssl_on`](#prerequisite-postgresql-ssl) installs.

### How the access is controlled

```text
pg_hba:    hostssl  patch_history  grafana_ro  0.0.0.0/0  cert  map=patch_history-grafana_ro-map clientcert=verify-full
pg_ident:  patch_history-grafana_ro-map  grafana.example.com  grafana_ro
```

The address is open, exactly as `puppetdb::database::postgresql_ssl_rules` leaves it for PuppetDB
itself, because **the `pg_ident` map is the allowlist**. A certificate must be signed by the Puppet
CA *and* have its CN listed in the map. A certificate from any other Puppet node — signed by the
same CA — authenticates as nothing and is rejected. Add a host by adding it to the map, not by
opening a network range.

### The rule order matters

Both rules are set to `order` **`010`/`011`**, and the value is load-bearing.
`postgresql::server::config` ships an `allow access to all users` rule at **order 100** —
`host all all 0.0.0.0/0` with password authentication — and `host` matches SSL connections as well
as plaintext ones. `pg_hba` is first-match-wins, so anything ordered below that rule is
unreachable: PostgreSQL answers with a password challenge, and `grafana_ro` has no password by
design. Keep these rules below 100 and above the module's own `001`–`004`.

### What each role is granted

| Role | Granted | Deliberately absent |
| --- | --- | --- |
| `patch_history` (importer) | `CONNECT`; `USAGE` on the schema; `SELECT` and `INSERT` on its tables; `USAGE` on the `patch_run_id_seq` sequence | `UPDATE`, `DELETE`, `TRUNCATE`, `CREATE`, ownership |
| `grafana_ro` | `CONNECT`; `USAGE` on the schema; `SELECT` on its tables, including tables added later | everything else |

Two of these are less obvious than they look. The importer needs `SELECT` as well as `INSERT`
because PostgreSQL requires it on any column named in an `INSERT ... RETURNING` clause. And it
needs `USAGE` on the sequence because `patch_run.id` is a `bigserial`, so every insert calls
`nextval()` — without that grant, imports fail at runtime rather than at deploy time.

`grafana_ro`'s `SELECT` is granted by a `postgresql_psql` resource rather than
`postgresql::server::grant`. The module's `ALL TABLES IN SCHEMA` grant decides whether it still
needs to run by asking `pg_tables` which relations lack the privilege, and **`pg_tables` does not
list views** — so once the tables were granted it stopped firing, and the `patch_event` view added
in 1.1.0 was left unreadable on any archive that gained it by upgrade. The replacement issues the
same `GRANT` (which does cover views) but probes `pg_class`, so a view, materialised view or
partitioned table added by a later schema change is picked up on the next run.

`grafana_ro` also gets `ALTER DEFAULT PRIVILEGES ... GRANT SELECT ON TABLES`, which covers objects
created *after* it is set — the next schema addition, not one already in place. It is applied as
`postgres`, the role that creates everything in this schema, so it needs no `FOR ROLE` clause.

### Check it

Against the database, confirm the read-only role really is read-only:

```sh
sudo -u postgres psql -d patch_history -c \
  "SELECT count(*) FROM patch_history.patch_run"          # works

sudo -u postgres psql -d patch_history -U grafana_ro -c \
  "DELETE FROM patch_history.patch_run"                   # ERROR: permission denied
```

Queries must be schema-qualified — `patch_history.patch_run`, not `patch_run` — since the tables
are not in `public` and `grafana_ro` has no rights there.

## The Grafana datasource

[`grafana.pp`](grafana.pp) provisions the archive as a datasource. It goes on the **Grafana node**,
not the PuppetDB host — it is the other half of the `grafana_ro` role above, and the two are only
ever brought together at connection time.

```sh
cp puppetdb_patch_history/example/grafana.pp \
   site-modules/profile/manifests/puppetdb_patch_history/grafana.pp
```

```yaml
# data/nodes/grafana.example.com.yaml
profile::puppetdb_patch_history::grafana::archive_host: 'puppetdb.example.com'
```

```puppet
include profile::puppetdb_patch_history::grafana
```

`archive_host` is the only required parameter. It must be the **certname of the PuppetDB host** —
`sslmode=verify-full` checks the PostgreSQL server certificate against it, and that certificate is
the node's Puppet cert. An alias or an IP will fail verification even though it routes fine.

Grafana must already be managed: the class notifies `Service['grafana-server']` and writes files
owned by the `grafana` group, so declare your Grafana class before this one.

| Parameter | Default | Description |
| --- | --- | --- |
| `archive_host` | *(required)* | Certname of the PuppetDB host |
| `archive_port` | `5432` | Port the archive PostgreSQL listens on |
| `db_name` | `'patch_history'` | Must match the other profile |
| `grafana_user` | `'grafana_ro'` | Must match the other profile |
| `datasource_name` | `'Patch history'` | Display name in Grafana |
| `datasource_uid` | `'puppetdb-patch-history'` | Stable UID for dashboards to reference |
| `is_default` | `false` | Whether this becomes the default datasource |
| `postgres_version` | `1400` | Server version as Grafana encodes it; `1500` for 15 |
| `tls_dir` | `'/etc/grafana/tls'` | Where the readable certificate copies go |
| `certname` | `$trusted['certname']` | Must match the other profile's `grafana_certname` |

### There is no password

The generated `puppetdb_patch_history.yaml` has no `secureJsonData` block, because there is no
secret: the credential is the Grafana node's Puppet agent certificate. The provisioning file is
inert on its own, and nothing has to be rotated or kept out of your control repo.

### Why the certificates are copied

Grafana cannot use the agent's certificate material where it lies.
`/etc/puppetlabs/puppet/ssl/private_keys` is `0750 puppet:puppet`, so an unprivileged process
cannot even traverse into it. The class copies the CA, the certificate and the key into `tls_dir`,
and Puppet re-syncs them from the originals, so a renewed certificate propagates on the next run.

The key's mode is load-bearing rather than hygiene. Grafana's PostgreSQL driver refuses a private
key that is group- or world-accessible *unless* the file is owned by `root`, in which case it
allows `0640`. `root:grafana 0640` is what satisfies both that check and Grafana's need to read it:

```text
pq: private key has world access; permissions should be u=rw,g=r (0640) if owned by root,
or u=rw (0600), or less
```

### The archive node's certificate needs a subjectAltName

**Certificates without a `subjectAltName` are not supported.** `sslmode` is fixed at `verify-full`
and is not a parameter.

`verify-full` verifies the server's hostname. Grafana's driver is written in Go, which removed the
fallback to the certificate's Common Name, so the certificate must carry a SAN matching
`archive_host`. Puppet puts one in only when `dns_alt_names` was set at the time the CSR was
generated, so a certificate issued without it fails like this:

```text
tls: failed to verify certificate: x509: certificate relies on legacy Common Name field,
use SANs instead
```

The fix is to reissue the PuppetDB host's certificate with `dns_alt_names` covering its FQDN — set
it in that node's `puppet.conf`, revoke and clean the old certificate, and sign the new request
with `puppetserver ca sign --allow-alt-names`. A SAN has been mandatory for a well-formed
certificate for years; this is worth correcting at the source rather than working around at the
client.

## The dashboard

[`dashboard.json`](dashboard.json) is a ready-made dashboard for the archive. Import it through
**Dashboards → New → Import** and pick the datasource when prompted.

Every query reads the `patch_history.patch_event` view rather than the tables, so versions come out
resolved instead of as `latest`. It will not work against an archive whose schema predates the
view — apply the profile first.

The datasource UID in the file is `puppetdb-patch-history`, matching `grafana.pp`'s
`datasource_uid` default. If you changed that parameter, or created the datasource by hand in the
UI rather than provisioning it, the UID will not match and every panel will fail to resolve its
datasource — the visible symptom is empty variable dropdowns. Either set `datasource_uid` to the
UID Grafana generated, or replace the UID throughout the JSON:

```sh
sed -i 's/puppetdb-patch-history/<your-datasource-uid>/g' dashboard.json
```

The dashboard's own `uid`, `patch-history`, is deliberately different and should be left alone: it
is what makes a re-import update the existing dashboard instead of creating a second copy.

## Upgrading an existing archive

The schema gained a `message` column and the `patch_event` view. The DDL in the profile handles
both — `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` and `CREATE OR REPLACE VIEW` — but two things
need attention.

**The `unless` probe moved.** It now tests for the `patch_event` view, because it has to name the
last object the DDL creates. Had it stayed on the old index, an existing archive would report the
schema as already applied and silently skip everything added after it. If you carry a modified copy
of the profile, carry this across too.

**Rows imported before the upgrade have no message**, so their `new_version_resolved` is `NULL` and
`effective_version` falls back to `latest`. Nothing can fill them in: PuppetDB has expired the
reports they came from. To find them:

```sql
SELECT count(*) FROM patch_history.patch_event
WHERE status = 'success' AND new_version_resolved IS NULL;
```

If the archive is younger than your `report-ttl` — 14 days by default — everything in it is still
in PuppetDB, and starting over gets you resolved versions for the whole history. On the PuppetDB
host:

```sh
systemctl stop puppetdb-patch-history.timer
sudo -u postgres psql -c 'DROP DATABASE patch_history'
puppet agent -t                                    # recreates the database and applies the schema
systemctl start puppetdb-patch-history.service     # backfills 30 days by default
```

Check `report-ttl` first. Anything PuppetDB has already expired does not come back, and this is one
of the few ways to lose archive data on purpose.

## Troubleshooting

**`archive schema is missing`** — the schema has not been applied to this database. Under Puppet
that is the `postgresql_psql` resource in the profile, which applies it on the first run. The
importer never creates its own tables.

**`relation "patch_history.patch_event" does not exist`** — the view has not been created. On an
archive that predates it, check that the profile's `$schema_applied` probe tests for `patch_event`
and not for an earlier object; if it still names the old index, the whole DDL is being skipped as
already applied. See [Upgrading an existing archive](#upgrading-an-existing-archive).

**Every `new_version` reads `latest`** — that is correct, and not a bug. It is the value from the
catalog, and `patching_as_code` declares its packages `ensure => latest`. Query `patch_event` and
read `effective_version` for the version that was actually installed.

**`effective_version` also reads `latest`** — there was no message to parse. Either the row was
imported before the `message` column existed, or the event failed and carries an error instead of
an `ensure changed 'a' to 'b'` line. `new_version_resolved IS NULL` distinguishes them from rows
that parsed cleanly.

**`permission denied for sequence patch_run_id_seq`** — the importer is missing
`GRANT USAGE ON ALL SEQUENCES IN SCHEMA patch_history`. `patch_run.id` is a `bigserial`, so every
insert calls `nextval()`. This only ever shows up on the first insert, not at deploy time.

**`certificate authentication failed for user "grafana_ro"`** — the certificate reached PostgreSQL
and was signed by a CA it trusts, but its CN is not in the `pg_ident` map. Check that
`grafana_certname` matches the CN the Grafana node actually presents.

**`password authentication failed for user "grafana_ro"`**, with
`DETAIL: User "grafana_ro" has no password assigned.` — this is not a credentials problem. The
`hostssl ... cert` rule never matched, and an earlier password-authentication rule answered
instead; the client certificate was never requested. Grafana reports only a generic
``failed to connect to `user=grafana_ro database=patch_history` ``, so read the PostgreSQL log for
the line above. Then dump the rules in order:

```sh
sudo grep -nE '^(host|hostssl|local)' /etc/postgresql/*/main/pg_hba.conf
```

The `hostssl patch_history grafana_ro` lines must appear **above** any `host all all 0.0.0.0/0`
rule. If they do not, see [the rule order](#the-rule-order-matters). After fixing it,
`systemctl reload postgresql` explicitly — reordering `concat` fragments does not reliably notify
the service, so a Puppet run alone can leave the old file loaded.

**`permission denied for view patch_event`** — the view exists but `grafana_ro` was never granted
`SELECT` on it, which is what `postgresql::server::grant`'s `pg_tables` blind spot used to cause
(see [what each role is granted](#what-each-role-is-granted)). The current profile fixes this on
the next Puppet run. To repair an archive by hand:

```sh
sudo -u postgres psql -d patch_history \
  -c 'GRANT SELECT ON ALL TABLES IN SCHEMA patch_history TO grafana_ro'
```

The dashboard works immediately afterwards — Grafana does not cache privileges. Confirm with
`\dp patch_history.*`, which should show `grafana_ro=r/postgres` against the view as well as the
two tables.

**Grafana connects but sees no tables** — its queries are probably unqualified. The archive is in
the `patch_history` schema, and `grafana_ro` has no rights in `public`, so queries need
`patch_history.patch_run` rather than `patch_run`.

**`x509: certificate relies on legacy Common Name field`** — the archive node's certificate has no
`subjectAltName`, which is not supported. Reissue it with `dns_alt_names`; see
[the datasource notes](#the-archive-nodes-certificate-needs-a-subjectaltname).

**`private key has world access`** — the copy of the client key in `tls_dir` is not `root:grafana
0640`. Grafana's driver checks this before it connects.

**The datasource is missing from Grafana after a Puppet run** — Grafana only reads provisioning
files at startup. The class notifies `Service['grafana-server']`, so check that resource exists in
the catalog; without it the file lands but nothing restarts.

**`puppetdb returned 404`** — check the URL. The importer appends `/pdb/query/v4` itself, so
`-puppetdb` wants the base URL only (`http://puppetdb.example.com:8080`).

**Connection refused on port 8080** — PuppetDB's cleartext port is often bound to localhost only.
Run the importer on the PuppetDB host, or see the authentication note in the
[README limitations](../README.md#limitations).

**The timer runs but nothing is imported** — check `-containing-class`. If your `patching_as_code`
classes are named differently, the filter matches nothing. List what is actually in your data:

```sh
curl -s -X POST http://puppetdb.example.com:8080/pdb/query/v4 \
  -H 'Content-Type: application/json' \
  -d '{"query":"events[containing_class]{ resource_type = \"Package\" and property = \"ensure\" order by containing_class }"}' \
  | sort -u
```

**`peer authentication failed`** — the OS user and the PostgreSQL role must have the same name for
`peer` auth to work. If you changed `db_user`, both follow it; if you changed only one by hand, they
no longer match.
