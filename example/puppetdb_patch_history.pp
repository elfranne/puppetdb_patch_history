# Manage the puppetdb_patch_history importer: binary, archive database, and timer.
#
# Intended for the PuppetDB host itself, since the importer speaks plain HTTP to
# PuppetDB's unauthenticated port.
#
# This is an example. Copy it into your control repo as
# site-modules/profile/manifests/puppetdb_patch_history.pp, or rename the class to
# match wherever you put it. See INSTALL.md for the full walkthrough.
#
# @param version           Release to install, as the git tag reads. Tags carry no "v" prefix.
# @param checksum          SHA-512 of the release tarball. Strongly recommended.
# @param puppetdb_url      Base URL of the PuppetDB instance to read from.
# @param containing_class  Regex matched against containing_class, to archive only patch runs.
# @param db_name           Name of the archive database.
# @param db_user           PostgreSQL role and OS user the importer runs as.
# @param db_schema         Schema holding the archive. Must match the schemaName
#   constant compiled into the binary; changing it alone will break the importer.
# @param db_socket_dir     Directory holding the PostgreSQL unix socket.
# @param oncalendar        systemd OnCalendar expression for the import.
# @param randomized_delay  systemd RandomizedDelaySec, to spread load.
# @param grafana_user      Read-only PostgreSQL role for Grafana.
# @param grafana_certname  Certname of the Grafana node. Its Puppet agent certificate
#   is what authenticates it, so this must match the CN of that certificate.
# @param grafana_clientcert pg_hba clientcert mode; use '1' on PostgreSQL < 12.
class profile::puppetdb_patch_history (
  String[1]            $grafana_certname,
  String[1]            $version            = '1.1.0',
  Optional[String[1]]  $checksum           = undef,
  Stdlib::HTTPUrl      $puppetdb_url       = 'http://localhost:8080',
  String[1]            $containing_class   = '^Patching_as_code',
  String[1]            $db_name            = 'patch_history',
  String[1]            $db_user            = 'patch_history',
  String[1]            $db_schema          = 'patch_history',
  Stdlib::Absolutepath $db_socket_dir      = '/var/run/postgresql',
  String[1]            $oncalendar         = 'hourly',
  String[1]            $randomized_delay   = '5m',
  String[1]            $grafana_user       = 'grafana_ro',
  String[1]            $grafana_clientcert = 'verify-full',
) {
  # GoReleaser names its artefacts with Go's architecture strings, and 32-bit ARM
  # carries the ARM version as a suffix: linux_armv7, not linux_arm. Debian reports
  # the dpkg architecture here (armhf), RedHat reports uname -m (armv7l).
  $release_arch = case $facts['os']['architecture'] {
    'amd64', 'x86_64':    { 'amd64' }
    'arm64', 'aarch64':   { 'arm64' }
    'i386', 'i686', 'x86': { '386' }
    'armv7l', 'armhf':    { 'armv7' }
    'armv6l':             { 'armv6' }
    'armv5l', 'armel':    { 'armv5' }
    default:              { fail("puppetdb_patch_history: unsupported architecture ${facts['os']['architecture']}") }
  }

  $cache_dir = '/var/cache/puppetdb_patch_history'
  $stage_dir = "${cache_dir}/${version}"
  $tarball   = "puppetdb_patch_history_${version}_linux_${release_arch}.tar.gz"
  $binary    = '/usr/local/bin/puppetdb_patch_history'

  # The postgresql::server::* resources below read this class's variables, so it
  # has to be in the catalog. include is idempotent, so this stays compatible with
  # the PuppetDB host, where puppetdb::database::postgresql already declares it.
  include postgresql::server

  # The OS user the timer runs as. Its name matches the database role so peer
  # authentication over the unix socket works without a password anywhere.
  group { $db_user:
    ensure => present,
    system => true,
  }

  user { $db_user:
    ensure  => present,
    gid     => $db_user,
    home    => '/nonexistent',
    shell   => '/usr/sbin/nologin',
    system  => true,
    comment => 'puppetdb_patch_history importer',
    require => Group[$db_user],
  }

  postgresql::server::role { $db_user:
    require => User[$db_user],
  }

  postgresql::server::database { $db_name:
    owner   => $db_user,
    require => Postgresql::Server::Role[$db_user],
  }

  postgresql::server::pg_hba_rule { "local access for ${db_user}":
    description => 'puppetdb_patch_history importer over the unix socket',
    type        => 'local',
    database    => $db_name,
    user        => $db_user,
    auth_method => 'peer',
    order       => 100,
  }

  # The archive schema. It is applied here, as postgres, so that postgres owns the
  # tables and neither application role can drop them. The importer deliberately
  # holds no CREATE privilege: it only reads a watermark and appends rows, and the
  # archive exists precisely because PuppetDB has already discarded this data.
  #
  # Index names are not schema-qualified - PostgreSQL rejects that in CREATE INDEX,
  # and an index always lands in its table's schema.
  $schema_sql = @("SQL")
    CREATE SCHEMA IF NOT EXISTS ${db_schema};

    CREATE TABLE IF NOT EXISTS ${db_schema}.patch_run (
        id                 bigserial   PRIMARY KEY,
        certname           text        NOT NULL,
        report_hash        text        NOT NULL UNIQUE,
        run_at             timestamptz NOT NULL,
        report_received_at timestamptz NOT NULL
    );

    CREATE INDEX IF NOT EXISTS patch_run_certname_run_at_idx
        ON ${db_schema}.patch_run (certname, run_at DESC);

    CREATE INDEX IF NOT EXISTS patch_run_received_at_idx
        ON ${db_schema}.patch_run (report_received_at DESC);

    CREATE TABLE IF NOT EXISTS ${db_schema}.patch_package (
        run_id      bigint NOT NULL REFERENCES ${db_schema}.patch_run(id) ON DELETE CASCADE,
        package     text   NOT NULL,
        old_version text,
        new_version text,
        message     text,
        status      text   NOT NULL
    );

    -- For archives created before message was collected. Those rows stay as they
    -- are: nothing can give them a message now, because PuppetDB expired the reports
    -- they came from long ago.
    ALTER TABLE ${db_schema}.patch_package ADD COLUMN IF NOT EXISTS message text;

    CREATE INDEX IF NOT EXISTS patch_package_run_idx
        ON ${db_schema}.patch_package (run_id);

    CREATE INDEX IF NOT EXISTS patch_package_name_version_idx
        ON ${db_schema}.patch_package (package, new_version);

    -- What you should query, and what the dashboard reads.
    --
    -- new_version is the value from the catalog, not the outcome. patching_as_code
    -- declares its packages `ensure => latest`, so every row it produces carries the
    -- literal string "latest" and no version at all; the version the provider really
    -- installed appears only in the agent's message:
    --
    --     ensure changed '10.0.301' to '10.0.302' (corrective)
    --
    -- Parsing that here rather than in the importer keeps the archive a verbatim copy
    -- of what PuppetDB said. A provider whose message reads differently is then a
    -- CREATE OR REPLACE away, instead of a re-import of data PuppetDB no longer has.
    --
    -- A failed event carries the provider's error text instead, matches nothing, and
    -- resolves to NULL - which is why this is a fallback in coalesce below and not a
    -- replacement for new_version.
    CREATE OR REPLACE VIEW ${db_schema}.patch_event AS
    SELECT r.id                AS run_id,
           r.certname,
           r.report_hash,
           r.run_at,
           r.report_received_at,
           p.package,
           p.old_version,
           p.new_version,
           substring(p.message from ' to ''([^'']*)''') AS new_version_resolved,
           coalesce(substring(p.message from ' to ''([^'']*)'''), p.new_version)
                               AS effective_version,
           p.status,
           p.message
    FROM ${db_schema}.patch_run r
    JOIN ${db_schema}.patch_package p ON p.run_id = r.id;
    | SQL

  # Every statement is idempotent - IF NOT EXISTS, or CREATE OR REPLACE - so
  # re-applying is harmless. The unless probes the last object created, so a partial
  # apply is retried on the next run.
  $schema_applied = "SELECT 1 FROM pg_views WHERE schemaname = '${db_schema}' AND viewname = 'patch_event'" # lint:ignore:140chars

  postgresql_psql { "apply ${db_schema} schema to ${db_name}":
    db      => $db_name,
    command => $schema_sql,
    unless  => $schema_applied,
    require => Postgresql::Server::Database[$db_name],
  }

  # What the importer needs, and nothing more. Notably absent: UPDATE, DELETE,
  # TRUNCATE and CREATE.
  postgresql::server::grant { "usage on ${db_schema} for ${db_user}":
    privilege   => 'USAGE',
    object_type => 'SCHEMA',
    object_name => $db_schema,
    db          => $db_name,
    role        => $db_user,
    require     => Postgresql_psql["apply ${db_schema} schema to ${db_name}"],
  }

  # SELECT is needed for the max(report_received_at) watermark, and again because
  # PostgreSQL requires it on any column named in an INSERT ... RETURNING clause.
  postgresql::server::grant { "select on ${db_schema} tables for ${db_user}":
    privilege   => 'SELECT',
    object_type => 'ALL TABLES IN SCHEMA',
    object_name => $db_schema,
    db          => $db_name,
    role        => $db_user,
    require     => Postgresql_psql["apply ${db_schema} schema to ${db_name}"],
  }

  postgresql::server::grant { "insert on ${db_schema} tables for ${db_user}":
    privilege   => 'INSERT',
    object_type => 'ALL TABLES IN SCHEMA',
    object_name => $db_schema,
    db          => $db_name,
    role        => $db_user,
    require     => Postgresql_psql["apply ${db_schema} schema to ${db_name}"],
  }

  # Without this the first insert fails at runtime: patch_run.id is a bigserial, and
  # nextval() on its sequence is a privileged operation.
  postgresql::server::grant { "sequence usage on ${db_schema} for ${db_user}":
    privilege   => 'USAGE',
    object_type => 'ALL SEQUENCES IN SCHEMA',
    object_name => $db_schema,
    db          => $db_name,
    role        => $db_user,
    require     => Postgresql_psql["apply ${db_schema} schema to ${db_name}"],
  }

  # Read-only role for Grafana.
  #
  # It has no password at all: it authenticates with the Grafana node's Puppet agent
  # certificate, which PostgreSQL validates against the Puppet CA. That CA is already
  # configured as ssl_ca_file by `class { 'puppetdb': postgresql_ssl_on => true }`,
  # which is a prerequisite of this profile - without it there is nothing to verify
  # client certificates against and cert auth cannot work.
  #
  # false, not undef, is the module's sentinel for "manage no password"; Undef is not
  # in the parameter's type.
  postgresql::server::role { $grafana_user:
    password_hash => false,
    login         => true,
    superuser     => false,
    createdb      => false,
    createrole    => false,
    require       => Postgresql::Server::Database[$db_name],
  }

  # The map is the allowlist. A certificate signed by the Puppet CA authenticates as
  # nothing unless its CN appears here, which is why the pg_hba rules below can leave
  # the address open.
  $grafana_map = "${db_name}-${grafana_user}-map"

  postgresql::server::pg_ident_rule { "map ${grafana_certname} to ${grafana_user}":
    description       => 'Grafana node certificate to the read-only archive role',
    map_name          => $grafana_map,
    system_username   => $grafana_certname,
    database_username => $grafana_user,
  }

  # Mirrors puppetdb::database::postgresql_ssl_rules, which is how PuppetDB itself
  # reaches this PostgreSQL.
  postgresql::server::pg_hba_rule { "certificate access to ${db_name} as ${grafana_user} (ipv4)":
    description => 'Grafana read-only access, authenticated by Puppet CA client certificate',
    type        => 'hostssl',
    database    => $db_name,
    user        => $grafana_user,
    address     => '0.0.0.0/0',
    auth_method => 'cert',
    auth_option => "map=${grafana_map} clientcert=${grafana_clientcert}",
    order       => 110,
  }

  postgresql::server::pg_hba_rule { "certificate access to ${db_name} as ${grafana_user} (ipv6)":
    description => 'Grafana read-only access, authenticated by Puppet CA client certificate',
    type        => 'hostssl',
    database    => $db_name,
    user        => $grafana_user,
    address     => '::0/0',
    auth_method => 'cert',
    auth_option => "map=${grafana_map} clientcert=${grafana_clientcert}",
    order       => 111,
  }

  postgresql::server::database_grant { "connect ${grafana_user} to ${db_name}":
    privilege => 'CONNECT',
    db        => $db_name,
    role      => $grafana_user,
    require   => Postgresql::Server::Role[$grafana_user],
  }

  postgresql::server::grant { "usage on ${db_schema} for ${grafana_user}":
    privilege   => 'USAGE',
    object_type => 'SCHEMA',
    object_name => $db_schema,
    db          => $db_name,
    role        => $grafana_user,
    require     => Postgresql_psql["apply ${db_schema} schema to ${db_name}"],
  }

  postgresql::server::grant { "select on ${db_schema} tables for ${grafana_user}":
    privilege   => 'SELECT',
    object_type => 'ALL TABLES IN SCHEMA',
    object_name => $db_schema,
    db          => $db_name,
    role        => $grafana_user,
    require     => Postgresql_psql["apply ${db_schema} schema to ${db_name}"],
  }

  # Staging for the download, not an install location: /var/cache is where the FHS puts
  # regenerable data, and the release tarball ships LICENSE, README.md and CHANGELOG.md
  # alongside the binary, so it cannot be unpacked straight into /usr/local/bin. Root
  # only, since a predictable world-writable path is exactly what this avoids.
  #
  # purge clears the staging trees of versions no longer configured. Only $stage_dir is
  # managed, so everything else under here is unmanaged by definition.
  file { $cache_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0700',
    purge   => true,
    recurse => true,
    force   => true,
  }

  file { $stage_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0700',
    require => File[$cache_dir],
  }

  # The tarball is fetched into $stage_dir rather than $cache_dir, so the purge above
  # only ever sees version directories and cannot race the download.
  archive { "${stage_dir}/${tarball}":
    source        => "https://github.com/elfranne/puppetdb_patch_history/releases/download/${version}/${tarball}",
    extract       => true,
    extract_path  => $stage_dir,
    creates       => "${stage_dir}/puppetdb_patch_history",
    checksum      => $checksum,
    checksum_type => 'sha512',
    cleanup       => true,
    require       => File[$stage_dir],
  }

  # Installed by content rather than symlinked, so the path carries no version. Raising
  # $version stages a different binary and this resource replaces the installed one.
  file { $binary:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    source  => "file://${stage_dir}/puppetdb_patch_history",
    require => Archive["${stage_dir}/${tarball}"],
  }

  $service_content = @("EOT")
    [Unit]
    Description=Import patch history from PuppetDB
    Documentation=https://github.com/elfranne/puppetdb_patch_history
    After=network-online.target postgresql.service
    Wants=network-online.target

    [Service]
    Type=oneshot
    User=${db_user}
    Group=${db_user}
    Environment=PUPPETDB_URL=${puppetdb_url}
    Environment=DATABASE_URL=postgres:///${db_name}?host=${db_socket_dir}
    ExecStart=${binary} -containing-class '${containing_class}'

    NoNewPrivileges=true
    PrivateTmp=true
    ProtectHome=true
    ProtectSystem=full
    | EOT

  $timer_content = @("EOT")
    [Unit]
    Description=Import patch history from PuppetDB on a schedule

    [Timer]
    OnCalendar=${oncalendar}
    RandomizedDelaySec=${randomized_delay}
    Persistent=true

    [Install]
    WantedBy=timers.target
    | EOT

  systemd::timer { 'puppetdb-patch-history.timer':
    timer_content   => $timer_content,
    service_content => $service_content,
    active          => true,
    enable          => true,
    require         => [
      File[$binary],
      Postgresql::Server::Database[$db_name],
    ],
  }
}
