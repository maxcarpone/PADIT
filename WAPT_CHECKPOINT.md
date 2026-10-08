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
- Local validated source HEAD: **`de33ed9f`**. Previous modernization commit: **`14da06e8`**. Last checked remote tracking tip: **`bc03a837`**; verify and push before claiming synchronization.
- Builder: `tools/build-python2-runtime-bookworm.sh` (40 numbered stages plus M01–M03 regression checks).
- Runtime: `/git/paditdev/build/python2-runtime-server-bookworm` — Python **2.7.18**, system OpenSSL **3.0.22**.
- Validated pre-modernization backup: `/git/padit-python2-runtime-pre-m01` (bit-for-bit comparison passed at backup time).
- Full consolidated build **2026-10-08**: **exit 0**, `BUILD SUCCESS`, `All PADIT runtime tests passed`; runtime inventory generated; size **222M**.
- Build log: `/tmp/padit-bookworm-m01-m03-build.log`; recorded exit code `/tmp/padit-bookworm-m01-m03-build.rc`.
- Inventory: `build/python2-runtime-server-bookworm/WAPT-runtime-inventory.txt`.
- Python binary SHA256 reported: `e036f6079c12a5cfd0da7074ccf400093f162d0e9a4a6a9fc43962674973f2ee`.

### Server CVE remediation

- The final verified GitHub Dependabot query returned **zero OPEN findings for `requirements-server.txt`** on 2026-10-08. This is **not** a guarantee of no vulnerabilities; always refresh GitHub for live status.
- Last pyOpenSSL SNI remediation: commit `bc03a837`, CVE-2026-27448; regression test `utils/patch-pyopenssl-19.0.0/test-CVE-2026-27448.py`.
- Retain existing targeted backports, checksum verification, and regression tests for security-sensitive packages (ujson, cryptography/OpenSSL, urllib3, requests, Werkzeug, eventlet, python-socketio, Jinja2, Flask, lxml, pyOpenSSL).
- Do **not** close agent alerts because of server remediation.

## 4. Non-CVE server dependency modernization

The 40 declared server requirements and relevant transitive dependencies were inventoried in a modernization matrix: current version / last Python-2.7-compatible candidate / latest upstream / action and caveats. Version compatibility metadata is sometimes incomplete; test rather than assume.

| Lot | Dependency | Previous → installed | Git commit | Test |
|---|---|---|---|---|
| M01 | `six` | 1.11.0 → 1.17.0 | `14da06e8` | PASS |
| M01 | `pyparsing` | 2.2.0 → 2.4.7 | `14da06e8` | PASS |
| M01 | `iniparse` | 0.4 → 0.5 | `14da06e8` | PASS |
| M02 | `passlib` | 1.7.1 → 1.7.4 | `de33ed9f` | PASS |
| M02 | `netifaces` | 0.10.6 → 0.11.0 | `de33ed9f` | PASS |
| M02 | `Flask-Login` | 0.4.1 → 0.5.0 | `de33ed9f` | PASS |
| M03 | `pytz` | 2017.2 → 2026.5 | `de33ed9f` | PASS |
| M03 | `future` | 0.18.3 → 1.0.0 | `de33ed9f` | PASS |
| M03 | `wakeonlan` | 0.2.2 → 1.1.6 | `de33ed9f` | PASS (mock UDP) |

Permanent tests: `utils/test-server-dependencies-m01.py`, `-m02.py`, `-m03.py`; builder runs them before the inventory. Isolated and combined functional checks passed; all three passed in the **full consolidated build**.

**WOL API migration:** `waptserver/server.py` now imports `send_magic_packet` from `wakeonlan` and updates its two server calls. Tested legacy 0.2.2 output: 126 bytes; new 1.1.6: standard 102 bytes, with identical first 102 bytes. Network behavior was simulated using mocked sockets, **not** verified against a real pilot host. Windows/Unix agents unchanged.

**Other observations:** non-blocking `PasslibRuntimeWarning` (SHA256 name); cryptography Python-2 deprecation warning. Do not mistake warnings for new PASS evidence.

## 5. Open items and boundaries

1. **Flask-Babel / ImmutableDict:** `import flask_babel` raises `ImportError: cannot import name ImmutableDict` in *both* the pre-M01 baseline and M01 candidate runtime. Investigate actual import chain, actual server usage, and a compatible correction separately; don't attribute to M01–M03.
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

1. Review and adopt a compact active checkpoint **only after** preserving the original historic evidence, preferably as `WAPT_HISTORY.md`; ensure historical references remain traceable.
2. Confirm branch, HEAD, worktrees and remote state on Waptworm/VM106; push the validated `14da06e8` and `de33ed9f` commits when intended, then synchronize VM106 safely.
3. Investigate pre-existing `Flask-Babel / ImmutableDict` failure and its server impact, without mixing it into prior completed M01–M03 tests.
4. Continue the server dependency matrix in bounded batches; avoid a rebuild per dependency.
5. Keep the new Bookworm packaging/install and real-WOL pilot as explicit separate acceptance barriers.

## 8. Resume protocol

Gipity: treat **this file** as the **current** PADIT project state and `WAPT_HISTORY.md` as historical evidence only. Speak French; address user as Max; keep answers concise and proceed in validated steps. Do not replay closed Buster DR, Bullseye, previous Bookworm installation or historical author-rewrite investigations without contradictory evidence. Preserve security-scope separation (server vs agents).

**SSH safety:** never paste `set -e` or `exit` into an interactive Bash shell; prefer separate scripts/subshells. Python 2 snippets should declare UTF-8 (or remain ASCII). Long builds use detached execution with persistent log and exit code. Do not claim build success without an actual zero return code and terminal PASS markers.
