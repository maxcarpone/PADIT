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
