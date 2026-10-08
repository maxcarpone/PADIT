# PADIT / WAPT — Active Technical Checkpoint

**Updated:** 2026-10-08
**Status:** authoritative active checkpoint.
**Historical evidence:** preserve the existing 9,818-line checkpoint unchanged as `WAPT_HISTORY.md`; historical sections are evidence, **not current instructions**.

## 1. Mission and non-negotiable decisions

- Modernize WAPT Community 1.8.2 as **PADIT**, preserving real migration paths from historical WAPT 1.8.2.7393 deployments (nine servers). Python 2.7.18 is a **transitional compatibility runtime**, not the target architecture; Python 3 modernization is later.
- Main development branch: `release/1.8.3`; Waptworm working repository: `/git/paditdev`; VM106 Windows working repository: `C:\git\waptdev`.
- Preserve natural Git commit-count versioning and historical validated release artifacts. The first consolidated autonomous release milestone is planned as **1.8.3.1** following the earlier 1.8.3 validation line; do not claim a new release merely because the source count advanced.
- Do not rewrite Git authorship/history; do not silently change legacy package/signing trust semantics or historical migration evidence.
- Scope security work separately: Bookworm **server**, Windows agent, Unix agent. Fixing one scope does not close findings in another.

## 2. Frozen historical milestones (do not repeat without regression evidence)

| Area | Validated baseline | Reference |
|---|---|---|
| Windows 1.8.2 | 7402 Community console/installer; migration from real 7393 client | Historical checkpoint §§11–19 |
| Debian 10 / Buster | Historical DB migration, clean install, production-clone DR and client compatibility | Historical §§21–43; `WAPT_DR_DEBIAN10.md` |
| Buster DR tooling | Backup V1.0 and Restore V1.0 validated, distinct signing/trust and service identity | `WAPT_DR_DEBIAN10.md` |
| Windows 1.8.3 | Autonomous numbered 01/02/03 build workflow, clean VM107 proof, internal signing/Root CA work | Historical §§45–47 |
| Debian 11 / Bullseye | Server/setup packaging, services, publication and branding | Historical §48 |
| Debian 12 / Bookworm | Earlier installed server/setup baseline: PostgreSQL 15, nginx/HTTPS/API, console connection, agent publication | Historical §49 |

**Boundary:** the historical Bookworm package/deployment PASS does **not** mean the *new* M01–M03 runtime has passed Debian packaging, installation, or migration testing. Keep this as a separate validation milestone.

## 3. Current server source and runtime — 2026-10-08

- Host: **Waptworm**, repository `/git/paditdev`, branch `release/1.8.3`.
- Validated source HEAD before this documentation update: **`5d7708fb`**.
- Builder: `tools/build-python2-runtime-bookworm.sh`; permanent regression tests **M01–M06**.
- Runtime: `/git/paditdev/build/python2-runtime-server-bookworm` — Python **2.7.18**, OpenSSL **3.0.22**.
- Backups: `/git/padit-python2-runtime-pre-m01` and `build/python2-runtime-server-bookworm-pre-m04`.
- Consolidated M04–M06 rebuild on **2026-10-08**: **exit 0**, `BUILD SUCCESS`, `All PADIT runtime tests passed`; size **222M**.
- Build log: `/tmp/padit-bookworm-m04-m06-build.log`; exit code: `/tmp/padit-bookworm-m04-m06-build.rc`.
- Inventory: `build/python2-runtime-server-bookworm/WAPT-runtime-inventory.txt`.
- Python binary SHA256: `92c1d7665993f96c9ee44d44811c77454ec80b08046deb35a32d4f0775e9f0a0`.
- All six permanent modernization tests **M01–M06 PASS** in the full rebuilt runtime.
- The runtime build PASS does **not** establish a new Debian package, installed-server or migration validation.

### Server CVE remediation

- The final verified GitHub Dependabot query returned **zero OPEN findings for `requirements-server.txt`** on 2026-10-08. This is **not** a guarantee of no vulnerabilities; always refresh GitHub for live status.
- Last pyOpenSSL SNI remediation: commit `bc03a837`, CVE-2026-27448; regression test `utils/patch-pyopenssl-19.0.0/test-CVE-2026-27448.py`.
- Retain existing targeted backports, checksum verification, and regression tests for security-sensitive packages (ujson, cryptography/OpenSSL, urllib3, requests, Werkzeug, eventlet, python-socketio, Jinja2, Flask, lxml, pyOpenSSL).
- Do **not** close agent alerts because of server remediation.

## 4. Non-CVE server dependency modernization

The server dependency modernization matrix distinguishes installed versions,
Python-2-compatible ceilings, upstream versions and recommended actions.

| Lot | Dependency | Previous → validated | Git commit |
|---|---|---|---|
| M01 | `six`, `pyparsing`, `iniparse` | 1.11.0 → 1.17.0; 2.2.0 → 2.4.7; 0.4 → 0.5 | `14da06e8` |
| M02 | `passlib`, `netifaces`, `Flask-Login` | 1.7.1 → 1.7.4; 0.10.6 → 0.11.0; 0.4.1 → 0.5.0 | `de33ed9f` |
| M03 | `pytz`, `future`, `wakeonlan` | 2017.2 → 2026.5; 0.18.3 → 1.0.0; 0.2.2 → 1.1.6 | `de33ed9f` |
| M04 | `Flask-Babel` | 0.11.2 → 1.0.0 | `adf886e6` |
| M05 | `click`, `WTForms` | 6.7 → 7.1.2; 2.1 → 2.3.3 | `56ce18b2` |
| M06 | `pefile` | 2016.3.28 → 2019.4.18 | `5d7708fb` |

**All lots M01–M06:** permanent tests
`utils/test-server-dependencies-m01.py` through `-m06.py`;
all six PASS in the consolidated Bookworm runtime rebuild.

**M03 / Wake-on-LAN:** migrated `waptserver/server.py` to
`wakeonlan.send_magic_packet`. Mocked UDP tests PASS; real-host
operational validation remains pending.

**M04 / Flask-Babel:** fixes the pre-existing `ImmutableDict` import
failure with Werkzeug 1.0.1. Real French translation and session-based
locale selection PASS. Untranslated Polish server catalog removed in
commit `c9082f81`; German catalog retained.

**M06 / pefile:** `get_wapt_exe_version()` now accepts both historical
and nested `FileInfo` structures, retaining `FileVersion` priority and
`ProductVersion` fallback. Real `waptdeploy.exe` version extraction
returned `1.8.3.7531` with both pefile versions. Permanent regression
test PASS.

**Caveat:** runtime rebuild validation is distinct from deployed-server
functionality, Debian package validation and migration testing.

## 5. Open items and boundaries

2. **WOL operational pilot:** exercise server-initiated wake on a controlled host; verify configured ports, broadcast reachability and real-device behavior.
3. **`certifi`/trust-store audit:** pinned legacy bundle; distinguish `requests` HTTPS verification from PADIT certificate and CRL validation. Do not globally swap trust roots without a targeted review.
4. **Further server modernization:** candidates in matrix; tests isolated in `/tmp`, cross-tests in combination, dedicated permanent tests, **one full rebuild per consolidated batch**. Potential cleanup `argparse`/`wsgiref` from requirements is not yet done.
5. **Agents:** Windows-agent and Unix-agent security findings require separate assessment and respective build pipelines.
6. **New Bookworm distribution milestone:** rebuild package(s), install/upgrade, verify functional server and migration separately from runtime-only success; later Bookworm DR and backup/restore interoperability.
7. **Signing:** keep internal Authenticode Root CA / publisher trust separate from WAPT package-signing certificates and HTTPS/client CA. Public signing (SignPath Foundation) remains a later investigation, not a validated current dependency.
8. **Debian 13 / Python 3:** later optional/strategic work; not part of the current validated milestone.

## 6. Working-tree safety and synchronization

After the successful build, the only remaining known untracked Waptworm files were:

    waptsetup/deb/Thouet-Software-Signing-Root-CA.cer
    waptsetup/deb/builddir/
    waptsetup/deb/waptsetup-tis.exe

**Never** `git add .`; do not delete or commit these artifacts accidentally. The checkpoint is historically maintained on **VM106**; coordinate Git synchronization deliberately, and preserve the original long checkpoint as a history archive.

## 7. Exact next action

1. Commit this checkpoint update, then synchronize `release/1.8.3`
   with GitHub and VM106 deliberately; last observed remote tracking
   HEAD before synchronization: `9939e7e6`.
2. Begin **M07 — Huey**: inspect server task and consumer APIs before
   evaluating a Python-2-compatible candidate in isolation.
3. Continue the server dependency modernization matrix, with isolated
   tests, permanent regressions and consolidated runtime builds.
4. Complete the real Wake-on-LAN pilot and targeted `certifi`/trust
   audit separately.
5. Keep new Bookworm package installation, upgrade, server functionality
   and migration as separate acceptance gates.

## 8. Resume protocol

Gipity: treat **this file** as the **current** PADIT project state and `WAPT_HISTORY.md` as historical evidence only. Speak French; address user as Max; keep answers concise and proceed in validated steps. Do not replay closed Buster DR, Bullseye, previous Bookworm installation or historical author-rewrite investigations without contradictory evidence. Preserve security-scope separation (server vs agents).

**SSH safety:** never paste `set -e` or `exit` into an interactive Bash shell; prefer separate scripts/subshells. Python 2 snippets should declare UTF-8 (or remain ASCII). Long builds use detached execution with persistent log and exit code. Do not claim build success without an actual zero return code and terminal PASS markers.
