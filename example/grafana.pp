# Provision the patch history archive as a read-only Grafana datasource.
#
# This class belongs on the *Grafana* node. Its counterpart,
# profile::puppetdb_patch_history, runs on the PuppetDB host and creates the
# grafana_ro role, the pg_ident map entry and the pg_hba rules that let this node
# in. Neither is any use without the other, and $archive_host here must be the
# certname the other node was configured with.
#
# This is an example. Copy it into your control repo as
# site-modules/profile/manifests/puppetdb_patch_history/grafana.pp, or rename the
# class to match wherever you put it. See INSTALL.md for the full walkthrough.
#
# Grafana itself is assumed to be managed elsewhere: the grafana user and group
# must already exist, and Service['grafana-server'] must be in the catalog for the
# notify below to resolve. Declaring your Grafana class before this one covers both.
#
# @param archive_host      Certname of the host running the archive database. This
#   is matched against the PostgreSQL server certificate, so it must be the FQDN
#   that node's Puppet certificate was issued for - not an alias, not an address.
# @param archive_port      Port the archive PostgreSQL listens on.
# @param db_name           Archive database name. Must match the other profile.
# @param grafana_user      Read-only role to connect as. Must match the other profile.
# @param datasource_name   Display name of the datasource in Grafana.
# @param datasource_uid    Stable UID, so dashboards can reference the datasource
#   without depending on its name.
# @param is_default        Whether this becomes Grafana's default datasource.
# @param postgres_version  Server version, as Grafana encodes it: 1400 for 14,
#   1500 for 15. Grafana uses this to decide which SQL features it may emit.
# @param tls_dir           Directory holding the copies of the certificate material
#   that Grafana can actually read.
# @param provisioning_dir  Grafana's datasource provisioning directory.
# @param ssl_dir           Puppet agent SSL directory to copy from.
# @param certname          Certname of this node. Its agent certificate is what
#   authenticates to PostgreSQL, so this must match the pg_ident entry created by
#   profile::puppetdb_patch_history's $grafana_certname.
# @param grafana_owner     User Grafana runs as.
# @param grafana_group     Group Grafana runs as.
# @param grafana_service   Grafana service resource to notify on change.
class profile::puppetdb_patch_history::grafana (
  Stdlib::Host         $archive_host,
  Stdlib::Port         $archive_port     = 5432,
  String[1]            $db_name          = 'patch_history',
  String[1]            $grafana_user     = 'grafana_ro',
  String[1]            $datasource_name  = 'Patch history',
  String[1]            $datasource_uid   = 'puppetdb-patch-history',
  Boolean              $is_default       = false,
  Integer[0]           $postgres_version = 1400,
  Stdlib::Absolutepath $tls_dir          = '/etc/grafana/tls',
  Stdlib::Absolutepath $provisioning_dir = '/etc/grafana/provisioning/datasources',
  Stdlib::Absolutepath $ssl_dir          = '/etc/puppetlabs/puppet/ssl',
  String[1]            $certname         = $trusted['certname'],
  String[1]            $grafana_owner    = 'grafana',
  String[1]            $grafana_group    = 'grafana',
  String[1]            $grafana_service  = 'grafana-server',
) {
  $ca_file   = "${tls_dir}/puppet_ca.crt"
  $cert_file = "${tls_dir}/client.crt"
  $key_file  = "${tls_dir}/client.key"

  # Grafana cannot use the Puppet agent's certificate material where it lies:
  # ${ssl_dir}/private_keys is 0750 puppet:puppet, so an unprivileged process cannot
  # even traverse into it. These copies are what it reads, and Puppet re-syncs them
  # from the originals, so a renewed agent certificate propagates on the next run.
  file { $tls_dir:
    ensure => directory,
    owner  => 'root',
    group  => $grafana_group,
    mode   => '0750',
  }

  file { $ca_file:
    ensure  => file,
    source  => "${ssl_dir}/certs/ca.pem",
    owner   => 'root',
    group   => $grafana_group,
    mode    => '0640',
    require => File[$tls_dir],
    notify  => Service[$grafana_service],
  }

  file { $cert_file:
    ensure  => file,
    source  => "${ssl_dir}/certs/${certname}.pem",
    owner   => 'root',
    group   => $grafana_group,
    mode    => '0640',
    require => File[$tls_dir],
    notify  => Service[$grafana_service],
  }

  # The mode here is load-bearing, not hygiene. Grafana's PostgreSQL driver refuses
  # a private key that is group- or world-accessible unless the file is owned by
  # root, in which case it allows 0640. Owned by root at 0640 satisfies both that
  # check and the need for Grafana to read it; 0644 would fail at connection time.
  file { $key_file:
    ensure    => file,
    source    => "${ssl_dir}/private_keys/${certname}.pem",
    owner     => 'root',
    group     => $grafana_group,
    mode      => '0640',
    show_diff => false,
    require   => File[$tls_dir],
    notify    => Service[$grafana_service],
  }

  # There is no secureJsonData and no password: the client certificate above is the
  # credential, so nothing in this file is secret.
  #
  # sslmode is verify-full and is not configurable. It checks the server certificate
  # against $archive_host, which is why that has to be the archive node's certname
  # rather than an alias or an address.
  #
  # This requires the archive node's certificate to carry a subjectAltName. Grafana's
  # driver is Go, which dropped the Common Name fallback, so a CN-only certificate is
  # not supported: it fails with "x509: certificate relies on legacy Common Name
  # field". Reissue it with dns_alt_names rather than weakening the mode.
  $datasources = {
    'apiVersion'  => 1,
    'datasources' => [
      {
        'name'      => $datasource_name,
        'uid'       => $datasource_uid,
        'type'      => 'postgres',
        'access'    => 'proxy',
        'url'       => "${archive_host}:${archive_port}",
        'user'      => $grafana_user,
        'isDefault' => $is_default,
        'editable'  => false,
        'jsonData'  => {
          'database'               => $db_name,
          'sslmode'                => 'verify-full',
          'tlsConfigurationMethod' => 'file-path',
          'sslRootCertFile'        => $ca_file,
          'sslCertFile'            => $cert_file,
          'sslKeyFile'             => $key_file,
          'postgresVersion'        => $postgres_version,
          'timescaledb'            => false,
        },
      },
    ],
  }

  # If your Grafana profile already manages $provisioning_dir, add
  # require => File[$provisioning_dir] here.
  file { "${provisioning_dir}/puppetdb_patch_history.yaml":
    ensure  => file,
    content => to_yaml($datasources),
    owner   => 'root',
    group   => $grafana_group,
    mode    => '0640',
    notify  => Service[$grafana_service],
    require => [File[$ca_file], File[$cert_file], File[$key_file]],
  }
}
