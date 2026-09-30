# WAPT Community 1.8.3.7494 — Debian 10 Buster

Upgrade guide for the Debian 10 Buster pilot release, identified by tag `v1.8.3.7494`.

## GitHub release notes

This WAPT Community fork provides server and setup packages for Debian 10 Buster, built from source revision 1.8.3.7494. Two upgrade paths from an existing Community 1.8.2.7393 server were tested on an isolated Buster test server: manual installation of both packages and installation through the migration script.

The Debian package names `tis-waptserver` and `tis-waptsetup` are retained.

### Consolidated changes

- Builds use the project's controlled Python 2.7.18 environments. The Debian package builders no longer use the build server's system Python 2.7.16.
- Windows components and WAPTSetup were rebuilt as 1.8.3.7494. WAPTSetup and WAPTDeploy are signed using the internal Thouet Software Code Signing identity.
- The public Thouet Software Signing Root CA is distributed with the setup package. The installer explicitly asks for consent before adding it to the Windows trusted root store.
- Windows artifacts are published by the local WAPT server, with a bilingual homepage and version information.
- Buster migration script 1.1 upgrades the server and setup together, using an external release manifest, SHA256 checks, a prerequisite backup and post-installation checks.
- The existing server configuration is preserved, and the WAPT database schema is migrated from `1.8.2.1` to `1.8.3.0`.
- Project disaster recovery tools cover the database, configuration, identities and, in full backup mode, the repository. The validated restore workflow preserves the target version's published Windows artifacts and public signing root when restoring a historical repository.

### Validation scope

The test used Debian 10.13 amd64, `tis-waptserver 1.8.2.7393-75a5de09-debian-10-amd64`, `tis-waptsetup 1.8.2.7393` and a WAPT database running on PostgreSQL 9.6. A separate PostgreSQL 11 cluster was also present. This WAPT upgrade did not migrate the PostgreSQL cluster.

Both upgrade paths preserved the SHA256 of `waptserver.ini` and all six database reference counts. Service and published-file checksum checks passed. A Windows 7494 console subsequently accessed the inventory, and the test client reconnected.

Debian 11, other starting versions and installation on a new server are outside the scope of these two upgrade tests. The Python 2 runtime remains a compatibility stage for existing packages.

## Artifact provenance

| Component | Reference |
| --- | --- |
| Release tag | `v1.8.3.7494` |
| Source of both Debian packages and Windows product 7494 | `85a5bee5550f5ab4763ee3e7c0dbcc128b08ca81` |
| Migration script 1.1 promotion and validation checkpoint | `e2b65b26c2af18f71bb4ebf1f8af2fa52058f608` |
| Retained historical tag | `v1.8.3.7493`, commit `98e16ad6000bd025a1f40a5c45b8ff60186240ee` |

The migration script was tested as `1.1-rc1`. Promotion to `1.1` changes only its version declaration. Documentation and promotion commits do not change the version or provenance of the 7494 binaries.

The release tag points to the binary source commit. The attached migration script 1.1 and documentation include subsequent promotion and documentation changes. GitHub-generated source archives represent the tagged commit; use the attached release files for the procedures in this guide.

### Release files

- `tis-waptserver-1.8.3.7494-85a5bee5-debian-10-amd64.deb`
- `tis-waptsetup-windows-1.8.3.7494-85a5bee5.deb`
- `waptserver-migrate-buster.sh`, version 1.1
- `release.manifest`, matching these exact Debian packages
- `waptserver-backup.sh`, version 1.0
- `waptserver-restore.sh`, version 1.0.2
- `WAPT_DR_DEBIAN10.md`, the associated disaster recovery documentation
- `Thouet-Software-Signing-Root-CA.cer`, the public certificate also included in the setup package
- `WAPT_BUSTER_RELEASE.md`, this upgrade guide
- `SHA256SUMS`, generated from the final assembled release files

The restore script is documented in `WAPT_DR_DEBIAN10.md`; it is not used by the upgrade commands below. Public release files must not contain private keys, private `.pem`, `.p12` or `.pfx` files, passwords, site backups or a site-specific agent.

### Validated Debian package SHA256 values

```text
c2222beeabef1b0858a38f3f600e9ff815be3a0200cc128d5356300279908c47  tis-waptserver-1.8.3.7494-85a5bee5-debian-10-amd64.deb
0c059501866d30fb61e71f76dfe7c436db16796321d1c7b8cd018456371b2785  tis-waptsetup-windows-1.8.3.7494-85a5bee5.deb
```

## Before upgrading an existing server

Schedule a service interruption and ensure that administrative access to the server and hypervisor is available. Download the release files from the official release publication and place them together in a directory accessible to your account, such as `/var/www/wapt-release-7494/`.

Use an account authorized to run the administrative commands with `sudo`. The directory name is an example; adjust it to the location of your downloaded files. Full backups are created under `/var/www/wapt-backups`. Keep transferred DR archives on a filesystem with sufficient free space as well. Verify the actual mount layout: placing two directories under `/var/www` does not guarantee they share a filesystem if the repository has a separate mount.

Debian dependencies must already be available. The validation used an existing server with satisfied dependencies; these Debian packages are not a complete Debian package mirror. Upgrade the server and setup packages together.

Check the files and source environment, then create a full disaster recovery backup:

```bash
cd /var/www/wapt-release-7494
sha256sum -c SHA256SUMS
cat /etc/debian_version
date -u -Is
dpkg-query -W -f='${Package} ${Version} ${Status}\n' tis-waptserver tis-waptsetup
pg_lsclusters
df -h /var/www/wapt
sudo bash ./waptserver-backup.sh precheck
sudo bash ./waptserver-backup.sh backup
```

Wait for `BACKUP PASSED`, record the archive path and checksum, and keep a copy outside the server VM. Full backup mode includes the repository; backup time and free space requirements depend on its size. Follow `WAPT_DR_DEBIAN10.md` for backup handling and restoration.

If supported by your environment, take an identified pre-upgrade server snapshot after the backup. A local snapshot provides a convenient return point; it does not replace an external backup.

After restoring a snapshot, check the clock and package versions before proceeding. During the isolated test, the hardware clock was correct and the guest system clock was realigned using `sudo hwclock --hctosys --utc --noadjfile`. Use this command only after checking that the hardware clock is correct.

## Path A — Manual installation

Review the installation plan without applying it:

```bash
sudo apt-get -s install \
  ./tis-waptserver-1.8.3.7494-85a5bee5-debian-10-amd64.deb \
  ./tis-waptsetup-windows-1.8.3.7494-85a5bee5.deb
```

Only the two WAPT package upgrades were planned in the validated test. Review any additional changes before continuing.

Record the configuration checksum and schema version before installation. Adjust the PostgreSQL port if the WAPT database uses a different port:

```bash
sudo sha256sum /opt/wapt/conf/waptserver.ini
sudo -u postgres psql -p 5432 -d wapt -Atc \
  "SELECT value FROM serverattribs WHERE key='db_version';"
```

Install both packages together:

```bash
sudo dpkg -i \
  ./tis-waptserver-1.8.3.7494-85a5bee5-debian-10-amd64.deb \
  ./tis-waptsetup-windows-1.8.3.7494-85a5bee5.deb
```

The server restart stage can take some time. Wait for the command to finish and check its result.

The package prints a generic message suggesting `postconf.sh`. The existing configured server used in this test upgraded successfully without running it, with its configuration preserved. Do not automatically rerun initial configuration for this upgrade path. A new server installation requires a separate procedure.

Check package versions, configuration preservation, services, database schema and published files:

```bash
dpkg-query -W -f='${Package} ${Version} ${Status}\n' tis-waptserver tis-waptsetup
sudo sha256sum /opt/wapt/conf/waptserver.ini
systemctl is-active postgresql nginx waptserver wapttasks
sudo -u postgres psql -p 5432 -d wapt -Atc \
  "SELECT value FROM serverattribs WHERE key='db_version';"
sudo sha256sum /var/www/wapt/waptsetup-tis.exe \
  /var/www/wapt/waptdeploy.exe \
  /var/www/wapt/Thouet-Software-Signing-Root-CA.cer
sudo journalctl -u waptserver -u wapttasks --since '10 minutes ago' -p err --no-pager
```

Expected versions: server `1.8.3.7494-85a5bee5-debian-10-amd64`, setup `1.8.3.7494`, schema `"1.8.3.0"`. The configuration SHA256 must match the value recorded before the upgrade. Compare published-file checksums with the corresponding fields in `release.manifest`, then check HTTPS access and inventory access through the console.

## Path B — Migration script 1.1

The script targets Debian 10 and the historical source version 1.8.2.7393. The manifest describes the target packages and must accompany the exact two files from this release. Do not execute or source the manifest as a shell script.

After the full backup and pre-upgrade snapshot, run:

```bash
bash -n ./waptserver-migrate-buster.sh
sudo bash ./waptserver-migrate-buster.sh precheck
sudo bash ./waptserver-migrate-buster.sh check-package \
  ./release.manifest \
  ./tis-waptserver-1.8.3.7494-85a5bee5-debian-10-amd64.deb \
  ./tis-waptsetup-windows-1.8.3.7494-85a5bee5.deb
sudo bash ./waptserver-migrate-buster.sh backup ./release.manifest
sudo bash ./waptserver-migrate-buster.sh check-backup ./release.manifest
```

Each step must succeed before starting the next. The migration script backs up the database and configuration without copying the repository; this backup complements the full disaster recovery backup. The script checks that the migration backup matches the source, release manifest and current configuration.

Then start the upgrade:

```bash
sudo bash ./waptserver-migrate-buster.sh upgrade \
  ./release.manifest \
  ./tis-waptserver-1.8.3.7494-85a5bee5-debian-10-amd64.deb \
  ./tis-waptsetup-windows-1.8.3.7494-85a5bee5.deb
```

Wait for `POST-UPGRADE RESULT: PASS` and `UPGRADE RESULT: PASS`. Checks cover both package versions, published-file checksums, configuration preservation, WAPT/nginx services, schema migration and database reference counts.

Then check server access, historical inventory and reconnection of a test workstation through the console. The script does not perform automatic rollback. If a step reports `BLOCKED` or an error, retain the output and backup location, inspect package state and use the planned return point if necessary. Reinstalling an old Debian package alone does not revert an already migrated database.

## Windows: setup trust and site-specific agent generation

WAPTSetup and WAPTDeploy in this distribution use the internal Thouet Software Code Signing identity. Windows workstations are not assumed to trust its issuing authority already.

Verify the public root certificate's file SHA256 before importing it:

```text
5bb7881d601856f1ee55c7a7b88e988751751779dee1ab08d21dd319b1690e7a
```

The administrator decides whether to establish this trust. WAPTSetup offers an explicit import prompt. A prior or centrally deployed import also allows Windows to recognize the setup's signature before execution. A valid signature does not guarantee the absence of a SmartScreen prompt: reputation checking is a separate mechanism and may be unavailable offline.

Each site's administrator is responsible for generating and publishing its own `waptagent.exe`. After the server upgrade, the previously published agent can still be present; this does not mean that the setup package upgrade failed.

Use a console matching the new version. Retain the site's URLs, historical package prefix, authorized package-signing certificates and intended configuration. Use the FQDN matching the server's HTTPS certificate, and configure certificate verification with the appropriate site trust. Build the agent, then test publication and installation on a pilot workstation before wider deployment.

Three mechanisms remain distinct: WAPT signing of packages/actions, Windows Authenticode signing of executables and HTTPS server certificate verification.

The historical automatic agent-generation path looks for SignTool at `utils/signtool.exe` and a `.p12` file with the same basename as the selected personal certificate. A historical WAPT package-signing `.crt`/`.pem` pair alone therefore does not guarantee Authenticode signing of the generated agent. If the required signing material is absent, the agent can be `NotSigned`. A signed agent can also be untrusted if Windows does not trust its issuing authority.

The upgrade test retained the historical package-signing identity and produced an unsigned 7494 agent. This is documented behavior of that generation path, not a migration regression. The public release does not include an agent customized for the test site's identity or configuration.

## Pilot deployment

Keep the release files and `SHA256SUMS` together, and retain a copy outside the build VMs. Validate the upgrade on an isolated clone before deploying it to a production server. Record the starting package versions, backup location and post-upgrade results.

The GitHub release notes section provides the release description; the complete guide provides commands and validation limits. This first publication targets Debian 10 Buster pilot upgrades. Debian 11 modernization and a new-VM installation/restore workflow will be addressed separately.
