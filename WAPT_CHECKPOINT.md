# PADIT / WAPT — Active Technical Checkpoint

**Updated:** 2026-10-09
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

## 3. Current server source and runtime — 2026-10-09

- Host: **Waptworm**, repository `/git/paditdev`, branch `release/1.8.3`.
- Last confirmed source HEAD: **`eca7dc02`** (M10).
- Builder: `tools/build-python2-runtime-bookworm.sh`.
- Runtime: `build/python2-runtime-server-bookworm`.
- Runtime platform: Python **2.7.18**, OpenSSL **3.0.22**, Debian 12 Bookworm.
- Consolidated M01–M07 rebuild: PASS, exit 0, 2026-10-09.
- Consolidated M08–M10 rebuild: new versions installed and verified.
- All ten permanent regression tests **M01–M10 PASS**.
- `pip check`: **No broken requirements found**.
- Final M08–M10 validation initially failed only because a manual test
  invocation omitted the repository root from `PYTHONPATH`.
  Retesting with `PYTHONPATH="$PWD"`: **10/10 PASS**.
- Build log: `/tmp/padit-bookworm-m08-m10-build.log`.
- M07 runtime backup: `build/python2-runtime-server-bookworm-pre-m08`.
- This runtime validation does **not** establish a new Debian package,
  installed-server validation or migration validation.

### Server security

- Last recorded Dependabot review (2026-10-08):
  zero OPEN findings for `requirements-server.txt`.
- Retain all validated server CVE backports and regression tests.
- Server, Windows agent and Unix agent are separate security scopes.
- Never close an agent finding merely because the server was corrected.

## 4. Server dependency modernization — M01–M10

| Lot | Dependencies | Commit | Status |
|---|---|---|---|
| M01 | six, pyparsing, iniparse | `14da06e8` | PASS |
| M02 | passlib, netifaces, Flask-Login | `de33ed9f` | PASS |
| M03 | pytz, future, wakeonlan | `de33ed9f` | PASS |
| M04 | Flask-Babel | `adf886e6` | PASS |
| M05 | click, WTForms | `56ce18b2` | PASS |
| M06 | pefile | `5d7708fb` | PASS |
| M07 | huey | `f259d703` | PASS |
| M08 | ldap3 2.7 -> 2.9.1 | `97016d17` | PASS |
| M09 | MarkupSafe 1.0 -> 1.1.1 | `23ed37e5` | PASS |
| M10 | Peewee 3.11.2 -> 3.14.10 | `eca7dc02` | PASS |

- Permanent tests:
  `utils/test-server-dependencies-m01.py` through
  `utils/test-server-dependencies-m10.py`.
- M08: LDAP DN parsing, mock bind and user/computer searches PASS.
- M09: compiled C extension, HTML escaping and Jinja2 integration PASS.
- M10: SQLite transactions, rollback, conflict handling, Huey SQLite
  execution and real `waptserver.model` import PASS.
- Real Active Directory, production PostgreSQL integration and full
  deployed-server behavior require separate validation.
- The general non-CVE Python 2 server dependency modernization pass
  is complete at runtime level.
- Preserve sensitive compatibility/CVE backports. Consider future
  upgrades individually only where concrete benefit justifies the risk.
- Future maintenance: consolidate M01–M10 calls into one test runner;
  this is a separate refactoring task, not a build blocker.

## 5. PADIT project roadmap — confirmed 2026-10-09

### Phase 1 — Finish Debian 12 server

- Debian 12 minimal server and autonomous packaging.
- Backup/Restore and historical migration compatibility.
- Server rebranding PADIT.
- Server CVE remediation.
- Python 2.7-compatible dependency modernization: M01–M10 validated.
- Complete remaining Bookworm package/install/upgrade/functional tests.
- Validate PostgreSQL 15, server services, HTTPS, console/agent access,
  repository publication and migration on the new package/runtime.
- Validate Backup/Restore interoperability on Bookworm.
- Perform the real Wake-on-LAN operational pilot.
- Review `certifi` versus WAPT-specific certificate/trust semantics.
- Do not replay frozen Debian 10 DR or previous Debian 11/12 milestones
  without evidence of a regression.

### Phase 2 — Modernize Windows and Linux clients/agents

- PADIT rebranding of console, installers, agent and related components.
- Remediate Windows-agent and Unix-agent CVEs separately.
- Upgrade compatible dependencies and preserve WAPT 1.8.2 migration.
- Modernize build tools and reproducible compilation infrastructure.
- Retain previously proven autonomous Windows Community build pipeline.
- Compile the Linux agent for the first time in this project.
- Validate binaries, services, package formats and signing/trust paths.

### Phase 3 — Product-wide acceptance tests

- Clean installation and upgrade from authentic historical deployments.
- Server / console / Windows agent / Linux agent interoperability.
- Package installation, upgrade, inventory and realtime communication.
- Backup/Restore, disaster recovery and migration continuity.
- Authenticode, WAPT package signatures, HTTPS and certificate trust.
- Validate autonomous/offline-capable distribution paths.

### Phase 4 — PADIT release

- Prepare and validate the consolidated autonomous PADIT release.
- Planned milestone: **1.8.3.1**; preserve earlier historical 1.8.3
  milestones and natural Git commit-count versioning.
- Publish reproducible binaries/packages, checksums and documentation.
- Do not claim a release before full validation.

### Phase 5 — Python 3 feasibility study

- **Only after the PADIT release.**
- Evaluate server and agent migration separately.
- Python 2.7 is intentionally retained for the current release.
- Python 3 is a longer-term project, not the next operational milestone.

## 5A. Debian 12 installed-server validation — 2026-10-09

### Packaging and upgrade

- Bookworm server and Windows-setup Debian packages built from
  `5d1a7250`, version `1.8.3.7587`.
- In-place server upgrade to 7587 completed on Waptworm.
- PostgreSQL 15, nginx, waptserver and wapttasks operational.
- Six sensitive configuration, CA and TLS files preserved (SHA256).
- DR backup tool v1.1 supports Debian 10/11/12; Bookworm backup
  creation validated. Bookworm restore remains untested.

### Homepage performance regression and correction

- Symptom on server 7587: homepage `/` HTTP 200 in 13.5116 s;
  `/lang/en`, `/login` and `/api/v1/hosts` responded in milliseconds.
- Root cause: pefile 2019.4.18 performs a full-file byte-frequency
  count via `collections.Counter(bytearray(self.__data__))` when
  `fast_load=False`. Windows executables are approximately 27 MB.
- Fix in `waptserver/utils.py`: `pefile.PE(exe, fast_load=True)`
  followed by targeted parsing of
  `IMAGE_DIRECTORY_ENTRY_RESOURCE`.
- Permanent M06 regression test updated: historical and nested
  `FileInfo`, ProductVersion fallback, fast-load requirement and
  resource-directory-only parsing.
- Source correction commit: `953660ab`.
- Python 2 syntax validation and M01-M10 suite: 10/10 PASS.
- Server package rebuilt and installed on Waptworm:
  `tis-waptserver-1.8.3.7589-953660ab-debian-12-amd64.deb`.
- Package SHA256:
  `918462de71ac20b7c7896c5889bba8427be2312af3c37dde2d4a2b359e002207`.
- Installed server homepage: HTTP 200 in 0.170041 s, approximately
  79 times faster than 7587 (98.7% reduction).
- `/lang/en`: HTTP 302, `/login` and `/api/v1/hosts`: HTTP 401
  without credentials, all responding in approximately 2 ms.
- PostgreSQL, nginx, waptserver and wapttasks active.
- Six configuration/identity files still match original SHA256.
- User confirmed markedly improved browser responsiveness.
- Initial connection refusal immediately following dpkg installation
  was a transient service startup window, not a persistent failure.

### Additional application acceptance — 2026-10-09

- Flask-Babel M04: French/English translations and language switching
  confirmed working in the installed server web interface.
- VM107 console successfully generated an agent installer using
  PADIT server 1.8.3.7589.
- VM104 Windows agent installed, registered and reported reachable.
- VM104 update detection triggered successfully from the console.
- PostgreSQL recorded both VM104 and VM107 with reachable=OK and
  listening_protocol=websockets.
- Socket.IO: VM107 initially presented an expired token after server
  upgrades/restarts; its recorded SID subsequently changed and
  connectivity recovered. No Flask-SocketIO regression demonstrated.
- Token expiry/reconnection behavior remains a separate regression
  scenario to validate; no authentication weakening applied.
- Wake-on-LAN M03: real UDP emission validated from console VM107
  through PADIT 7589 on Waptworm using tcpdump.
- Two 102-byte packets containing VM104's MAC were observed:
  destinations 255.255.255.255:9 and 192.168.223.255:9.
- VM104 did not wake because it is a stopped Proxmox VM; normal
  virtual networking does not establish physical Wake-on-LAN support.
  Physical-machine wake-up remains untested.

### Outstanding Debian 12 acceptance

- Complete authenticated console and application workflow tests.
- Validate agent communication and investigate Socket.IO warnings,
  including an expired-token warning.
- Complete restore testing in an isolated Debian 12 environment.
- Preserve separation between server validation and later Windows/
  Linux agent modernization.

## 6. Remaining server boundaries

1. New Bookworm Debian server/setup packages and real deployed validation
   remain separate from the successful runtime rebuild.
2. Backup/Restore V1.0 is historically validated on Debian 10; validate
   its behavior on the intended Bookworm target.
3. Historical Windows build/installation evidence is preserved.
4. Windows and Unix agent CVE work remains independent.
5. Authenticode trust, WAPT package-signing trust and HTTPS/client CA
   must remain explicitly separated.
6. Internal signing is transitional; SignPath Foundation remains a
   future public Authenticode signing option to investigate.
7. Keep historical database identity, package-signing continuity and
   legacy upgrade paths intact.

## 7. Working-tree safety and exact next action

Known untracked Waptworm artifacts to preserve:

    waptsetup/deb/Thouet-Software-Signing-Root-CA.cer
    waptsetup/deb/builddir/
    waptsetup/deb/waptsetup-tis.exe

- Never use `git add .` or indiscriminate cleanup.
- Do not synchronize VM106 until Windows work resumes.
- Preserve `WAPT_HISTORY.md` unchanged as historical evidence.
- Next: commit this checkpoint-only update.
- Then inventory the remaining Debian 12 server acceptance gates
  and complete them before opening the client/agent modernization phase.

## 8. Resume protocol

Gipity: treat **this file** as the **current** PADIT project state and `WAPT_HISTORY.md` as historical evidence only. Speak French; address user as Max; keep answers concise and proceed in validated steps. Do not replay closed Buster DR, Bullseye, previous Bookworm installation or historical author-rewrite investigations without contradictory evidence. Preserve security-scope separation (server vs agents).

**SSH safety:** never paste `set -e` or `exit` into an interactive Bash shell; prefer separate scripts/subshells. Python 2 snippets should declare UTF-8 (or remain ASCII). Long builds use detached execution with persistent log and exit code. Do not claim build success without an actual zero return code and terminal PASS markers.

---

## Appendix A — Server dependency modernization M01–M10

### Purpose and execution order

M01–M10 are historical modernization batches, **not ten build stages**.
They were developed incrementally to preserve Python 2.7 compatibility,
isolate regressions and validate changes before consolidated rebuilds.

The operational sequence is:

1. Build the Python 2.7 server runtime and install pinned requirements.
2. Apply the existing security backports and run their regression tests.
3. Run the PADIT server functional/cryptographic tests.
4. Remove the temporary WAPT server test configuration.
5. Execute `tools/test-server-dependencies.sh` (M01 through M10).
6. Generate the runtime inventory and complete builder checks.
7. Separately build Debian packages and validate the installed server.

**M01–M10 are regression tests, not separate dependency installations.**
The pinned versions remain in `requirements-server.txt`.

### Modernization batches and rationale

| Lot | Dependencies / selected versions | Reason and compatibility notes |
|---|---|---|
| M01 | six 1.17.0; pyparsing 2.4.7; iniparse 0.5 | Update general Python utilities without breaking Python 2.7 imports. |
| M02 | passlib 1.7.4; netifaces 0.11.0; Flask-Login 0.5.0 | Authentication and network utility compatibility. |
| M03 | pytz 2026.5; future 1.0.0; wakeonlan 1.1.6 | Refresh timezone/compatibility libraries; adapt WOL API to `send_magic_packet`. Real UDP emission validated on Bookworm (2026-10-09): console VM107 -> PADIT server -> two 102-byte magic packets for VM104 (Proxmox), captured with tcpdump on port 9. Physical-device wake-up remains untested. |
| M04 | Flask-Babel 1.0.0 | Resolve `ImmutableDict` incompatibility with Werkzeug 1.0.1; verify French translations and locale selection. |
| M05 | click 7.1.2; WTForms 2.3.3 | Preserve Flask CLI and form validation behavior. |
| M06 | pefile 2019.4.18 | Preserve legacy/nested `FileInfo` and optimize version extraction using fast load plus targeted PE resource parsing. |
| M07 | huey 1.10.5 | Preserve legacy task names, SQLite execution and persisted tasks. Huey 1.11.0 was deferred due to task identifier/decorator changes. |
| M08 | ldap3 2.9.1 | Preserve DN parsing, escaped characters and simulated LDAP bind/search behavior. |
| M09 | MarkupSafe 1.1.1 | Validate compiled C extension, escaping and patched Jinja2 2.11.3 integration. |
| M10 | Peewee 3.14.10 | Validate transactions, rollback, `ON CONFLICT IGNORE`, Huey SQLite and real PADIT model import. |

### Regression-test implementation

- The builder calls `tools/test-server-dependencies.sh` exactly once.
- The runner executes `utils/test-server-dependencies-m01.py` through
  `utils/test-server-dependencies-m10.py` in ascending order.
- Each test runs as a separate Python 2.7 process.
- `PYTHONPATH` includes the PADIT repository root for `waptutils`,
  `waptcrypto` and `waptserver` imports.
- The runner stops immediately upon the first failure.
- An all-PASS result does not replace PostgreSQL, Active Directory,
  network, Debian package, installation or historical migration tests.

Manual execution on Waptworm:

    cd /git/paditdev
    ./tools/test-server-dependencies.sh

The builder supplies its own Python runtime explicitly:

    "${REPO_ROOT}/tools/test-server-dependencies.sh" "${PYTHON}"

### Compatibility and security decisions

- Preserve existing server CVE backports and their dedicated tests.
- `pyOpenSSL==19.0.0` retains the CVE-2026-27448 backport.
- `cryptography==3.3.2` retains the validated WAPT/OpenSSL compatibility.
- `certifi==2021.10.8` is intentionally retained following the
  trust-path audit. Requests uses its CA bundle by default; WAPT's
  certificate and CRL verification can receive an explicit `SSLCABundle`.
- Keep the legacy Flask/Socket.IO/Engine.IO compatibility stack until
  separate integration testing justifies a change.
- `itsdangerous==1.1.0` preserves `TimedJSONWebSignatureSerializer`.
- `psycopg2==2.8.6` remains the Python-2-compatible PostgreSQL driver.
- Do not confuse runtime modernization PASS with Debian installed-server
  or client/agent security validation.

### Validated milestone

M01–M07: consolidated rebuild and permanent tests PASS.

M08–M10: isolated functional tests and consolidated Bookworm runtime
validation PASS on 2026-10-09.

Full final verification: **10/10 tests PASS**, `pip check` PASS.

Source milestone: `eca7dc02` (M10); roadmap checkpoint: `32b7dc2b`.
