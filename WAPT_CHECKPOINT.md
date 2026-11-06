# PADIT / WAPT — Active Technical Checkpoint

**Updated:** 2026-10-13
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
- VM106 Windows work resumed and was validated on 2026-10-13; synchronize branches without overwriting untracked Waptworm artifacts.
- Preserve `WAPT_HISTORY.md` unchanged as historical evidence.
- The former checkpoint-only action has been completed.
- Next: fast-forward Waptworm to the published Windows security commits,
  then document current Windows work as in section 9.
- Resume client-agent CVE review separately from remaining Debian 12
  installed-server acceptance tests.

## 8. Resume protocol

Gipity: treat **this file** as the **current** PADIT project state and `WAPT_HISTORY.md` as historical evidence only. Speak French; address user as Max; keep answers concise and proceed in validated steps. Do not replay closed Buster DR, Bullseye, previous Bookworm installation or historical author-rewrite investigations without contradictory evidence. Preserve security-scope separation (server vs agents).

**SSH safety:** never paste `set -e` or `exit` into an interactive Bash shell; prefer separate scripts/subshells. Python 2 snippets should declare UTF-8 (or remain ASCII). Long builds use detached execution with persistent log and exit code. Do not claim build success without an actual zero return code and terminal PASS markers.

---

## 9. Windows agent security and modernization — 2026-10-13

### 9.1 Windows source and validation milestone

- Working host VM106: `C:\git\waptdev`, branch `release/1.8.3`.
- Latest published Windows commit: `fc83e60a5`,
  `Backport pywin32 CVE-2021-32559 into Windows runtime`.
- The preceding Windows security commit is `d0052413c`,
  `Integrate patched pyasn1 Windows wheel and upgrade ldap3 to 2.9.1`.
- Waptworm was observed at `b403275d` before a successful fetch;
  `origin/release/1.8.3` was at `fc83e60a`, two commits ahead.
  Perform a fast-forward-only merge before editing and committing this
  checkpoint in the Waptworm repository.
- Existing untracked `waptsetup/deb/` artifacts listed in section 7
  must remain untouched.
- The previous Windows dependency modernization commits from October 12–13
  are already in branch history; do not replay them solely to update records.

### 9.2 W05-A — pyasn1 Windows security: completed

- Windows `pyasn1 0.5.1` uses Python-2.7-compatible security backports,
  pinned SHA256 validation and a controlled wheel build in
  `tools/02-build-windows-runtime.ps1`.
- Python 2.7 native-runtime checks and security regressions passed.
- Commit `d0052413c` was pushed to `release/1.8.3`.
- Dependabot alerts #176, #177, #178 and #179 were dismissed with
  backport justification. Real AD/Kerberos integration remains a
  separate operational test; do not overstate its coverage.

### 9.3 W05-B — pywin32 CVE-2021-32559: completed

- Retain `pywin32==228` for Windows Python 2.7 x86 compatibility.
- Two upstream security patches and a distinct targeted-build patch are
  tracked under `utils/patch-pywin32-228/`.
- Official unmodified source archive at
  `C:\padit-build-kit\python\sources\pywin32-b228-source.zip`:
  SHA256 `792247C46F0F51D8EBF37374493FB285E9F2BBD4C5044855BA0379491725C1A0`.
- Verified patches apply cleanly to upstream b228, commit `40a8f25a`.
- Native target build compiles `pywintypes27.dll` and `win32security.pyd`
  with VC9 x86, `--skip-verstamp`, and no auxiliary `axdebug` build.
- All construction logic remains in **`tools/02-build-windows-runtime.ps1`**;
  do not create a separately numbered tool merely for this fix.
- The corrected `pywintypes27.dll` is installed both in the runtime root
  and `Lib/site-packages/pywin32_system32`; `win32security.pyd` is replaced.
- Complete autonomous Windows runtime build on VM106: PASS, exit code 0;
  runtime `C:\padit-runtime-w05b6-validation-3`.
- All seven ACL overflow regression cases PASS; native DLL loaded from the
  expected runtime, and both installed DLL copies have identical SHA256.
- Runtime acceptance test: `PADIT 1.8.3` autonomous runtime PASS
  (terminal messages were subsequently rebranded from WAPT to PADIT).
- Commit `fc83e60a5` published; GitHub Dependabot alert #174
  `CVE-2021-32559` dismissed with reason `fix_started` and explanatory
  backport comment. This is *not* an upstream version upgrade.
- Native build process repeatability is established by a clean-source
  build and functional tests; bit-for-bit binary reproducibility is not
  established.

### 9.4 W05-C — dnspython CVE-2023-29483: explicitly deferred

- Dependabot #175 remains **OPEN**, severity medium, declared in
  `requirements-agent-windows.txt`, `dnspython==1.16.0`.
- Dependabot fixed version: `2.6.1`; not directly usable on Python 2.7.
- `eventlet==0.33.3` declares `dnspython>=1.15.0`.
- PADIT server uses Eventlet; `waptservice` uses the distinct
  `socketIO-client-2` library. `setuphelpers_unix.py` imports
  `dns.resolver`. An absence of direct Windows imports does not prove
  that removal is safe.
- **Decision:** do not delete or change either dependency, do not dismiss
  #175, and do not backport the fix yet. Revisit after broader CVE work,
  with Windows **and Unix** agent/runtime compatibility tests and
  security assessment of Eventlet/DNS interaction.

### 9.5 Live security inventory and next work

- Last observed OPEN Dependabot findings by manifest:
  `requirements-agent.txt`: 53;
  `requirements-agent-unix.txt`: 9;
  `requirements-agent-windows.txt`: 1 (deferred #175).
- Counts are a time-limited snapshot; refresh with live GitHub API.
- Windows security backports do not automatically remediate Unix agent
  findings, even where both manifests install related packages.
- Continue common-agent CVE triage and independent Unix-agent validation;
  do not reopen closed server M01–M10 modernization or Windows W05-A/B
  without new regression evidence.
- Remaining Debian 12 installed-server acceptance, isolated Bookworm
  restore, and physical Wake-on-LAN remain separately tracked in §5A.

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

## 10. Agent Unix Debian 12 — U01–U88 (2026-10-14)

### Objectif et isolation

- Branche : `release/1.8.3`, hote de travail : `waptworm`.
- Runtime pilote : `build/python2-runtime-agent-unix-bookworm/`.
- Python 2.7.18, OpenSSL 3.0.22, pip 20.3.4.
- Runtime serveur `build/python2-runtime-server-bookworm/` preserve.
- Windows W07 conserve son jalon de validation independant.
- Le constructeur Unix complet n'a PAS encore ete execute de zero.

### Constructeurs Unix crees

Constructeur principal :
`tools/build-python2-runtime-agent-unix-bookworm.sh`

Sous-constructeurs :
- `tools/build-agent-unix-crypto-bookworm.sh`
- `tools/build-agent-unix-ujson-bookworm.sh`
- `tools/build-agent-unix-urllib3-bookworm.sh`
- `tools/build-agent-unix-requests-bookworm.sh`
- `tools/build-agent-unix-werkzeug-bookworm.sh`
- `tools/build-agent-unix-eventlet-bookworm.sh`
- `tools/build-agent-unix-socketio-bookworm.sh`
- `tools/build-agent-unix-pyopenssl-bookworm.sh`
- `tools/build-agent-unix-jinja2-bookworm.sh`
- `tools/build-agent-unix-flask-bookworm.sh`

Tous les scripts passent `bash -n` (U88).
Les dix sous-constructeurs sont raccordes au constructeur principal.

### Validations du runtime pilote

- CPython 2.7.18 compile a partir des sources officielles avec SHA256 verifie.
- `cryptography==3.3.2`, `cffi==1.15.1` : correctifs et tests pilotes PASS.
- `ujson==2.0.3` : cinq correctifs et regressions pilotes PASS.
- `urllib3==1.26.20` : cinq correctifs, regressions et
  tests HTTPS proxy/TLS pilotes PASS.
- Requests : quatre correctifs et regressions pilotes PASS.
- Werkzeug : quatre correctifs et regressions pilotes PASS.
- Eventlet et dnspython : correctifs et regressions pilotes PASS.
- python-socketio CVE-2026-48804 : PASS (U77).
- pyOpenSSL CVE-2026-27448 : PASS (U77).
  Le traceback ValueError dans le test SNI est intentionnel.
- Jinja2 2.11.3 : CVE-2024-22195, CVE-2024-34064,
  CVE-2024-56326, CVE-2025-27516 : PASS (U82).
- Flask 1.1.4 : CVE-2023-30861, CVE-2026-27205,
  tests de compatibilite session : PASS (U87).
- `pip check` : aucune dependance cassee a l'issue de U87.
- `requirements-agent.txt` : ipaddress 1.0.22 -> 1.0.23,
  a reverifier dans la reconstruction et sur Windows.

### Limites non validees

- Reconstruction autonome complete depuis un repertoire vierge.
- Ordre d'installation, dependances natives APT et reproductibilite
  sur Bookworm vierge.
- Audit exhaustif des dependances et CVE propres a l'agent Unix.
- Integration des modules de compatibilite PADIT cryptography/x509.
- Tests de regression HTTPS proxy conserves actuellement sous `/tmp` :
  les rendre permanents dans Git sans embarquer de cles privees.
- Verification finale de l'application des correctifs sur l'ensemble
  du runtime reconstruit.
- Tests fonctionnels de l'agent Unix reel et integration produit.
- Aucun avis Dependabot Unix ne doit etre ferme sur la seule base
  de cette validation pilote.

### Reprise exacte

1. Auditer constructeur principal et sous-constructeurs :
   chemins, ordre, versions, empreintes, isolation et pre-requis.
2. Integrer les modules PADIT cryptography/x509 manquants.
3. Perenniser les tests HTTPS proxy/TLS.
4. Reconstruire le runtime agent Unix depuis zero et lancer
   regressions, `pip check` et tests fonctionnels.
5. Reprendre l'inventaire de securite Unix avant toute cloture d'alerte.

### Securite du depot

- Conserver les trois artefacts Debian non suivis :
  `waptsetup/deb/Thouet-Software-Signing-Root-CA.cer`,
  `waptsetup/deb/builddir/`,
  `waptsetup/deb/waptsetup-tis.exe`.
- Ne pas modifier le runtime serveur ni invalider le jalon Windows W07.
- Ne pas considerer les validations pilotes comme une release Unix.


### 10.1 Agent Unix — reconstruction autonome R5 validee
Date : 2026-10-15. Etapes U89-U101.

**Jalon Git valide :**
- Branche : `release/1.8.3`.
- Commit : `7b652210` — `Validate autonomous Bookworm Unix agent runtime and security regressions`.
- Construction R5 terminee sans reprise manuelle :
  `/tmp/padit-agent-unix-validation-runtime-r5`.
- Journal : `/tmp/padit-agent-unix-validation-r5.log`.
- Les onze sous-constructeurs de securite ont ete executes.
- Verification LDAP finale : PASS.
- Pilote historique conserve ; runtime serveur et Windows W07 non modifies.

**Dependances et securite :**
- Python 2.7.18, OpenSSL 3.0.22, cryptography 3.3.2.
- python-ldap 3.3.1 avec trois retroportages :
  CVE-2021-46823/ReDoS, CVE-2025-61911, CVE-2025-61912.
- Extension LDAP native et regressions de securite : PASS.
- Compatibilite cryptographique PADIT et suite X.509 : PASS.
- ujson 2.0.3 avec cinq correctifs et regressions : PASS.
- urllib3 1.26.20 avec cinq correctifs et regressions : PASS.
- CVE-2026-97687 : quatre regressions TLS proxy simulees PASS.
  Validation TLS reelle et couverture exhaustive encore a qualifier.
- `pip check` : aucune dependance cassee.

**Correction du blocage OrderedDict :**
- Cause demontree par `bash -x` et `PYTHONVERBOSE=1`.
- Le constructeur restait dans `src/urllib3` apres application des patchs.
- Son `_collections.py` masquait l'extension native Python `_collections.so`.
- Correction : retour a `${REPO_ROOT}` avant les commandes Python.
- Sous-constructeur urllib3 valide integralement dans R4 apres correction.
- Reconstruction autonome R5 : PASS.

**Decision d'architecture :**
- Maximum trois scripts publics pour reconstruire l'agent Unix,
  sur le modele des trois scripts Windows 01/02/03.
- Les onze sous-constructeurs restent provisoirement internes.
- Simplification a traiter separement, sans invalider le jalon R5.
- Le runtime agent Unix est construit, mais le produit Unix installable
  n'est pas encore assemble ni valide.

**Travail restant :**
1. Organiser la chaine Unix en trois points d'entree maximum.
2. Concevoir et valider l'assemblage du produit agent Unix.
3. Effectuer les tests fonctionnels de l'agent installe.
4. Qualifier separement Windows W07 et les alertes Dependabot encore ouvertes.
5. Ne pas assimiler les regressions simulees a une validation TLS reelle.

**Protection des artefacts :**
Ne pas ajouter, modifier ou supprimer les fichiers historiques non suivis
sous `waptsetup/deb/`, notamment les executables et certificats.


### 10.2 Agent Unix — preparation produit U102

- `01-prepare-unix-build-environment.sh` : pre-requis Bookworm
  controles, execution PASS.
- `02-build-unix-runtime.sh` : interface du constructeur R5 ;
  syntaxe et cinq protections de chemins testees PASS.
- Runtime R5 conserve sans reconstruction.
- Packaging historique `waptservice/deb/createdeb.py` audite :
  dependances Python systeme et scripts Debian historiques
  incompatibles avec les exigences PADIT modernes.
- Decision : paquet agent Debian autonome, Python 2.7 embarque,
  aucun Python systeme ou pip necessaire sur la cible.
- `setuphelpers_linux.py` : inventaire Debian remplace par
  `dpkg-query`, sans python-apt.
- Test fonctionnel Python R5 PASS : 566 paquets, filtres,
  version dpkg, structure des resultats.
- Prochain objectif : `03-build-unix-product.sh`, assemblage
  du runtime R5 et des composants applicatifs dans un vrai .deb.
- Reste a valider : relocabilite du runtime, dependances natives,
  cycle installation/mise a niveau/desinstallation et service.

### 10.3 Agent Unix — premier paquet Debian pilote

- Constructeur : `tools/03-build-unix-product.sh`.
- Produit : `tis-waptagent_1.8.3.7494+unixpilot1_amd64.deb`.
- Sortie : `/tmp/padit-agent-unix-products/`.
- Runtime Python 2.7 autonome R5 embarque sans reconstruction.
- Archive Debian construite et inspectee : PASS.
- Taille : environ 37 Mio.
- Extraction isolee et relocalisation Python : PASS.
- Imports applicatifs PADIT : PASS.
- python-apt absent et non requis pour les tests effectues.
- Scripts de maintenance `/bin/sh` : syntaxe PASS.
- Service systemd present, activation automatique desactivee.
- Conflit historique avec `tis-waptserver` conserve.
- Paquet non installe et non valide en production.
- Restent a qualifier : dependances ELF, configurations persistantes,
  installation, upgrade, desinstallation et service reel sur VM dediee.


### W09 - Common agent CVE remediation

- W08 Windows: Eventlet 0.33.3 and dnspython 1.16.0,
  CVE-2023-29483 backports validated on Python 2.7 x86.
  Commit `4bb0b8993`; autonomous W08 build PASS;
  DNS standalone, Eventlet post-fix and direct UDP tests 3/3 PASS.
  Dependabot Windows #175 and common Eventlet #43 dismissed.
- W09 urllib3: common alerts #59, #60, #61 and #105 dismissed.
  Existing urllib3 1.26.20 backports and Windows/Unix regression
  evidence reviewed. Remaining urllib3 alerts require separate treatment.
- W09 pyasn1: five CVE patches plus Python 2.7 compatibility
  applied to pyasn1 0.5.1. Unix test suite: 1174 tests,
  3 skipped, no failures. Patched wheel built, contents compared,
  isolated installation and constructor-block integration PASS.
  Source tarball vendored with SHA256 verification.
  Commit `61c8593e`.
  Dependabot common alerts #180, #181, #182 and #183 dismissed.
- Unix R5 reference runtime preserved. pyasn1 remediation validated
  in an isolated copy; complete Unix product runtime not rebuilt.
- Current focus: remaining common-agent Dependabot alerts.
- Follow-up: clean up the overcrowded tools/ directory in a
  dedicated refactoring commit after security remediation.


### W10 - requests common-agent CVE remediation

- Retained requests==2.27.1 for Python 2.7 compatibility.
- Reused four server backports:
  CVE-2023-32681, CVE-2024-35195,
  CVE-2024-47081, CVE-2026-25645.
- Unix R5: all four patches confirmed present by reverse
  dry-run checks. No rebuild of the validated R5 runtime.
- Windows VM106: all four patches applied and functional
  regression tests passed on isolated Python 2.7 x86 sources.
- Windows autonomous runtime build PASS:
  C:\padit-runtime-1.8.3-W10-requests
- Windows builder now validates patch SHA256, applies all
  four backports and executes four automated regression tests.
- Commit 0fc9e382c published on release/1.8.3.
- Dependabot common alerts #28, #46, #54, #67 dismissed.
- Next: remaining common-agent dependency CVEs.


### W11 - certifi CA bundle remediation

- Retained certifi==2021.10.8 for Python 2.7 compatibility.
- Replaced its CA data with the controlled Mozilla certifi
  2026.7.22 cacert.pem bundle.
- Bundle SHA256:
  9cc2a774b5198dcff14d9be1e66091f538975d867ce029a96bce15a55dfd730f
- X.509 fingerprint checks confirm the removal of five roots:
  TrustCor RootCert CA-1, RootCert CA-2, ECA-1,
  E-Tugra Certification Authority and GLOBALTRUST 2020.
- Common Python 2.7 regression suite PASS: SHA256,
  five removed roots and OpenSSL CA bundle loading.
- Unix Bookworm: controlled bundle integrated into constructor;
  isolated runtime validation PASS. Historical R5 preserved.
  Full Unix constructor rebuild remains to be validated.
- Windows VM106: autonomous W11 runtime build PASS.
  Controlled bundle installed and security tests PASS.
- Unix commit: 90a81bd0.
- Windows commit: 2e8671bdc.
- Dependabot common certifi alerts #20, #32, #52 dismissed.
- Next: remaining common-agent CVE remediation.


### W12 - Werkzeug common-agent CVE remediation (2026-10-16)

- Scope: Werkzeug==1.0.1 in requirements-agent.txt.
- Seven Dependabot alerts dismissed:
  - #25 CVE-2023-25577
  - #26 CVE-2023-23934
  - #45 CVE-2024-34069
  - #49 CVE-2024-49766
  - #58 CVE-2025-66221
  - #62 CVE-2026-21860
  - #64 CVE-2026-27199
- Existing security patches reused from the validated Debian server/Unix work:
  - CVE-2023-23934.patch
  - CVE-2023-25577.patch
  - CVE-2024-34069.patch
  - safe-join-security-backports.patch
- Unix agent R5:
  - All four patch groups confirmed already applied by reverse dry-run.
  - Existing Unix regression suites retained.
  - No modification of the validated R5 runtime.
- Windows agent VM106:
  - Four patch groups applied successfully to isolated sources.
  - Four historical regression suites PASS.
  - Additional Windows safe_join tests: 15 unsafe paths rejected;
    3 normal paths accepted.
  - Five regression suites committed under
    utils/patch-werkzeug-1.0.1/tests/.
  - Patches and tests integrated into tools/02-build-windows-runtime.ps1.
  - Autonomous Python 2.7.18 Windows x86 runtime build SUCCESS.
  - Runtime: C:\padit-runtime-1.8.3-W12-werkzeug
  - Five regression suites PASS on the autonomous runtime.
  - Werkzeug 1.0.1 module provenance verified inside W12.
- Implementation commit: 3c46f49a.
- GitHub alerts dismissed after Unix/Windows verification.
- Final open common-agent Dependabot inventory: 34 alerts.
- Next: W13 - select the next common-agent dependency CVE family.
- Preserve all previously validated Windows runtimes and Unix R5.

### W13 - Flask common-agent CVE remediation (2026-10-16)

- Scope: Flask==1.1.4 in requirements-agent.txt.
- Dependabot alerts dismissed:
  - #27 CVE-2023-30861
  - #65 CVE-2026-27205
- Existing server security backport reused:
  utils/patch-flask-1.1.4/CVE-2023-30861-CVE-2026-27205.patch
- Unix agent R5: security patch presence verified by reverse dry-run
  using a temporary src/flask source layout. Runtime unchanged.
- Windows VM106:
  - Security patch applied to isolated Flask 1.1.4 sources.
  - Four functional regression checks PASS.
  - Windows runtime builder integration completed.
  - Security patch SHA256 checked during construction.
  - Autonomous Python 2.7.18 x86 build SUCCESS.
  - Runtime: C:\padit-runtime-1.8.3-W13-flask
  - Four functional regression checks PASS on W13.
  - Flask package and all four patched modules provenance verified.
- Implementation commit: d9530910d.
- GitHub alert closure verified for #27 and #65.
- Next: verify remaining Dependabot inventory, then select W14.
- Preserve Windows W08-W13 runtimes and Unix R5.

### W14 - Jinja2 common-agent CVE remediation (2026-10-16)

- Scope: Jinja2==2.11.3 in requirements-agent.txt.
- Dependabot alerts dismissed:
  - #38 CVE-2024-22195
  - #44 CVE-2024-34064
  - #51 CVE-2024-56326
  - #53 CVE-2025-27516
- Existing server security backports reused:
  - CVE-2024-22195-CVE-2024-34064.patch
  - CVE-2024-56326-CVE-2025-27516.patch
- Unix agent R5:
  - Both security patch groups confirmed present by reverse dry-run.
  - Existing validated runtime preserved.
- Windows VM106:
  - Both patch groups applied successfully to isolated Jinja2 sources.
  - Four CVE regression tests PASS.
  - Jinja2 attr compatibility test PASS.
  - Patches and regression tests integrated into Windows runtime builder.
  - Patch SHA256 verification included.
  - Autonomous Python 2.7.18 x86 runtime build SUCCESS.
  - Runtime: C:\padit-runtime-1.8.3-W14-jinja2
  - pip check: no broken requirements.
  - Regression tests PASS on autonomous runtime.
  - Jinja2, filters and sandbox module provenance verified.
- Implementation commit: 9fe4b1e8e.
- GitHub alert closure verified for all four alerts.
- Next: verify remaining Dependabot inventory and select W15.
- Preserve Windows W08-W14 runtimes and Unix R5.

### W15 - idna 2.10 common-agent security remediation (2026-10-21)

- Scope: CVE-2024-3651 and CVE-2026-45409, idna 2.10,
  Python 2.7-compatible Unix and Windows agents.
- Controlled upstream archive:
  `utils/sources/idna-2.10.tar.gz`.
  SHA256: `b307872f855b18632ce0c21c5e45be78c0ea7ae4c15c828c20788b26921eb3f6`.
- Security patch:
  `utils/patch-idna-2.10/CVE-2024-3651-CVE-2026-45409.patch`.
  SHA256: `01fcc4ac316420e773b3e64b71fc80773101b659dea1e8324992b839425ced88`.
- Patched modules: `idna/core.py` and `idna/codec.py`.
- Five versioned regression suites: baseline, security,
  incremental codec, boundaries, Unicode codec.

**Unix Debian 12 — PASS**
- Autonomous W15 runtime:
  `/git/paditdev/build/python2-runtime-agent-unix-W15`.
- Builder completed with exit code 0.
- Patched module provenance and SHA256: PASS.
- Five regression suites: 5/5 PASS.
- `pip check`: PASS.
- Previous Unix R5 runtime preserved.

**Windows x86/VC9 — idna PASS**
- Functional runtime:
  `C:\padit-runtime-1.8.3-W15-idna-retry`.
- Python 2.7.18, 32-bit: PASS.
- Patched sources match the Unix W15 reference after CRLF/LF normalization.
- Five regression suites: 5/5 PASS.
- `pip check`: PASS.
- Autonomous functional acceptance: PASS (three exit codes 0).
- Historical W14 runtime preserved.
- Qualification caveat: the Windows constructor was interrupted;
  a complete uninterrupted build was not demonstrated.
  The recovered runtime passed the subsequent functional checks.

**Git milestones**
- `93ad2c26`: Unix idna integration.
- `3f8dbcbb`: Unix archive verification hardening.
- `dcb62ba3`: Windows idna integration.
- Branch: `release/1.8.3`.

**Security tracking**
- Dependabot #42 and #74: remediation validated in both agent runtimes.
- Dependabot #42 (CVE-2024-3651) and #74 (CVE-2026-45409):
  dismissed with reason `fix_started`, 2026-10-21.
- Detailed remediation evidence retained in this section.
- `requirements-agent.txt` now pins `idna==2.10` without Python 3
  markers: commit `93ed38fa`.
- Original `idna==3.2` marker was inherited from historical WAPT
  commit `8a091e5b`; Python 3 porting remains a separate future project.
- Dismissal covers PADIT-controlled patched runtimes only.
  Unpatched upstream idna 2.10 remains vulnerable.
- GitHub reported 28 vulnerabilities before dismissal of these alerts.
- No additional runtime rebuild required for the completed idna
  regression checks; preserve the Windows build qualification caveat.

**Next**
- Review Dependabot alerts #42 and #74.
- Record the remediation evidence and decide dismissal state.
- Continue the remaining agent dependency CVE inventory.

### W16 - soupsieve 1.9.6 common-agent security remediation (2026-10-21)

- Scope: CVE-2026-49476, CVE-2026-49477,
  CVE-2026-85999 and CVE-2026-86000.
- Preserve soupsieve 1.9.6 and BeautifulSoup4 4.9.3
  for Python 2.7 compatibility.
- Controlled upstream archive:
  `utils/sources/soupsieve-1.9.6.tar.gz`.
  SHA256: `7985bacc98c34923a439967c1a602dc4f1e15f923b6fcf02344184f86cc7efaa`.
- Security patch:
  `utils/patch-soupsieve-1.9.6/CVE-2026-49476-49477-85999-86000.patch`.
  SHA256: `dade2c1f8539b7316c2436e9c1c0a9b803055a08cbbd538a8fb84262a88ac201`.
- Permanent security regression tests:
  `utils/patch-soupsieve-1.9.6/test_security.py`.
  SHA256: `b144b07f1b449dd60517917354e3b9387ada9a576dac4352c5fcc98746af8907`.
- Patched parser SHA256:
  `9fc72fb3b683704ae27404d66639b7a6960d0dcb27c268fd2fa1202ebabb06dc`.

**Historical compatibility — PASS**
- Official soupsieve 1.9.6 test suite:
  306 passed, 51 skipped, 5 deprecation warnings.
- Same results with the patched sources.
- Six targeted security regressions: 6/6 PASS.
- Historical tests were executed in isolated test environments.

**Unix Debian 12 — PASS**
- Builder: `tools/build-python2-runtime-agent-unix-bookworm.sh`.
- Autonomous W16 runtime:
  `/git/paditdev/build/python2-runtime-agent-unix-W16`.
- Complete autonomous runtime build: PASS.
- Python 2.7.18 compatibility retained.
- Corrected soupsieve 1.9.6 installed.
- Installed parser SHA256: PASS.
- Six security regressions executed by the builder: 6/6 PASS.
- Final python-ldap 3.3.1 security checks: PASS.
- Previous Unix W15 runtime preserved.

**Windows x86/VC9 — PASS (2026-11-02)**
- Builder: `tools/02-build-windows-runtime.ps1`.
- Runtime: `C:\padit-runtime-1.8.3-W16-soupsieve-retry`.
- Complete autonomous runtime construction: PASS (`SUCCESS`).
- Python 2.7.18 x86: PASS.
- soupsieve 1.9.6 and BeautifulSoup 4.9.3: PASS.
- Git for Windows patch application: PASS.
- Installed parser SHA256 after CRLF/LF normalization: PASS.
- Six security regression logs: 6/6 PASS.
- Final `pip check`: PASS.
- PADIT autonomous runtime acceptance: PASS.
- Historical Windows W15 runtime preserved.
- First W16 build attempt interrupted by PowerShell 5.1
  stderr redirection; direct retry completed successfully.
- Windows integration commits: `e6cd45fd`, `dde55f7a`.

**Security tracking — PENDING**
- Dependabot alerts #79, #80, #101 and #102.
- Do not dismiss alerts before validating Windows.
- Upstream soupsieve 1.9.6 without PADIT backports
  remains vulnerable.
- No Python 3 migration in W16.

**Next**
- Review and version the Unix W16 implementation.
- Integrate and validate the Windows x86/VC9 runtime.
- Update the checkpoint and Dependabot evidence.

### W17 - certifi emSign root CA security remediation (2026-11-02)

**Status: PASS - Unix Bookworm and Windows x86/VC9**

- Dependabot #185: GHSA-6q48-6c7w-9gw2, critical.
- Keep certifi 2021.10.8 for Python 2.7 compatibility.
- Controlled Mozilla CA bundle: 2026.10.19, 120 certificates.
- SHA256: 50f79f98dac192b20dbf73f35c56f0b0c557ab267ff5199d1117cc1180b70785.
- Removed emSign ECC Root CA - G3; three other emSign roots retained.
- Exactly one certificate removed compared with 2026.7.22; none added.
- Controlled bundle installed into both certifi and pip/_vendor/certifi.
- Unix W17 runtime: build/python2-runtime-agent-unix-W17.
- Unix security regressions, both bundle SHA256 checks, imports and pip check: PASS.
- Windows W17 runtime: C:\padit-runtime-1.8.3-W17-certifi.
- Windows autonomous runtime acceptance: PASS.
- Windows certifi and pip-vendored bundle SHA256: 2/2 PASS.
- Implementation commit: 65cc83f8.
- Dependabot #185 dismissed with reason fix_started.
- Dismissal applies only to PADIT-controlled corrected runtimes.
- W15/W16 historical runtimes preserved.

**Next:** Review Dependabot #187 (dnspython) and #186 (pylint).

### W18 - dnspython CVE-2026-114605 (2026-11-02)

**Status: PASS - Unix Bookworm and Windows x86/VC9**

- Dependabot #187: HIGH, CVE-2026-114605.
- Keep dnspython 1.16.0 for Python 2.7 compatibility.
- Backport: limit DNS compression pointer traversal to 16 hops.
- Preserve existing CVE-2023-29483 TuDoor backport.
- Patch SHA256: 3fd7d9501cc7874943b98e1877e7713f898073e79b818329bb6cd984afc0d559.
- Regression SHA256: 6135449c996f6c858d544cc4a9a563b66febd0ebbf0afb8ba49798d1b0987f6f.
- Unix runtime: build/python2-runtime-agent-unix-W18.
- Windows runtime: C:\padit-runtime-1.8.3-W18-dnspython.
- Unix and Windows: 16 pointers accepted, 17 rejected - PASS.
- Unix pip check: PASS.
- Windows autonomous runtime acceptance: PASS.
- Implementation commit: fe3a594c.
- Dependabot #187 dismissed, reason fix_started.
- Dismissal covers only PADIT-controlled patched runtimes.
- Historical W17 runtimes preserved.

**Next:** Investigate Dependabot #186, pylint CVE-2026-114608.

### W19 - pylint CVE-2026-114608 (2026-11-02)

**Status: PASS - Unix Bookworm and Windows x86/VC9**

- Dependabot #186: MEDIUM, CVE-2026-114608.
- Vulnerable dependency: pylint 1.7.4 (Python 2.7).
- Upstream fixed version requires Python 3.
- No functional imports of pylint or astroid in PADIT sources.
- No production dependency requires pylint.
- Only pylint requires astroid.
- Removed pylint==1.7.4 and astroid==1.5.3 from requirements-agent.txt.
- No vulnerability backport required.
- Implementation commit: b3099c8a.
- Unix runtime: build/python2-runtime-agent-unix-W19.
- Unix autonomous build and security regressions: PASS.
- Unix: pylint absent, astroid absent, imports and pip check: PASS.
- Windows runtime: C:\padit-runtime-1.8.3-W19.
- Windows autonomous runtime construction: SUCCESS.
- Windows: pylint absent, astroid absent, imports and pip check: PASS.
- Dependabot #186 dismissed, reason fix_started.
- Existing historical runtimes preserved.
- Three protected Debian artifacts untouched.
- Python 2.7.18 retained; no Python 3 migration.

**Next:** Inventory remaining open Dependabot alerts and prioritize
the next compatible security remediation.


## W20 - waitress 1.4.4 / validation finale

Statut : PASS - Windows x86/VC9 et Unix Debian 12 Bookworm.

- CVE-2022-24761 : retroportage du correctif HTTP.
- CVE-2024-49769 : retroportage du correctif de gestion des sockets.
- Version : waitress 1.4.4 (Python 2.7).
- Patch : utils/patch-waitress-1.4.4/CVE-2022-24761-CVE-2024-49769.patch
- Patch SHA256 : 7c4144fd7a6506499aa42ec177080e28f6bf24198678545e92858543cf50731b
- Tests : utils/patch-waitress-1.4.4/test_security.py
- Tests SHA256 : 6d637d365173c9ec9e7444715501f00561e9ff8ff47c95c1725e8c05dae05ba0
- Tests de securite : 34/34 PASS sur Windows et Unix.
- Tests historiques waitress adaptes : 354 PASS, 9 SKIPPED.
- Windows : C:\padit-runtime-1.8.3-W20-clean ; construction autonome PASS.
- Unix : build/python2-runtime-agent-unix-W20 ; construction et pip check PASS.
- Cinq modules verifies par SHA256 ; normalisation CRLF/LF sur Windows.
- Runtimes W19 conserves.
- Artefacts Debian proteges conserves.
- Integration : commits 5dbe16cc et 8859562c.
- Dependabot : alertes #19 et #50 dismissed (fix_started), validations W20 conservees.
- Chantier suivant : W21, nouvelles alertes pyasn1.

## W21 - pyasn1 0.5.1 / four CVE security backports (2026-11-03)

**Status: PASS - source reconstruction, Unix Bookworm and Windows x86 validation.**

- Package: pyasn1==0.5.1, retained for Python 2.7 compatibility.
- Dependabot #188: CVE-2026-119194, schemaless tag hash collisions.
- Dependabot #189: CVE-2026-119195, OCTET STRING / ANY assembly.
- Dependabot #190: CVE-2026-119197, REAL binary mantissa decoding.
- Dependabot #191: CVE-2026-119196, BIT STRING fragment assembly.
- Four separate security patches in utils/patch-pyasn1-0.5.1/.
- Historical patches preserved; 10 common patches for Unix, 11 for Windows.
- PADIT-windows-mkstemp.patch normalized to LF without logical changes.
- SHA256SUMS: 11/11 PASS.
- Reproducible decoder SHA256 (LF):
  b0e5f66ac55eecc3cdc0d2f767ca61f3fa041d140aaebdfe15cff3ffa598bb89.
- Unix Bookworm Python 2.7.18: 1174 tests, 3 skipped, 0 failures.
- Windows VM106 Python 2.7.18 x86: 1174 tests, 3 skipped, 0 failures.
- Windows Git core.autocrlf=true: CRLF decoder verified identical after LF normalization.
- Windows patched wheel: pyasn1-0.5.1-py2.py3-none-any.whl.
- Wheel SHA256:
  ac6b461fb8eec8fdd31d127c7d656fbff1d5ff4aa4b48e1d017e1b74ccad9709.
- Offline wheel installation in isolated VM106 directory: PASS.
- Installed package imports and four security-fix signatures: 6/6 PASS.
- Implementation commit: 3a9c2e881e62857c53c1b676e69cfda660b23a66.
- Commit pushed to origin/release/1.8.3; VM106 synchronized.
- Dependabot alerts #188, #189, #190, #191:
  dismissed with reason fix_started and validation evidence.
- Full PADIT runtime rebuild remains pending; isolated wheel validation is complete.
- Historical W07/W19/W20 runtimes preserved.
- Three protected Debian artifacts untouched.

**Next**
- Inventory remaining open Dependabot alerts.
- Continue compatible Python 2.7 security remediations.
- Validate integration in full autonomous Windows and Unix runtimes separately.

## W22 - RPyC 4.1.5 / CVE-2024-27758 (2026-11-03)

**Status: PASS - Unix Bookworm and Windows x86 autonomous runtimes.**

- Dependabot #41: HIGH, CVE-2024-27758.
- Package: rpyc==4.1.5, retained for Python 2.7 compatibility.
- Upstream reference: bba1d3562e6f9f1256ec64048cc23001c0bb7516.
- Backport: reject netref __array__ pickling when allow_pickle=False.
- Patch: utils/patch-rpyc-4.1.5/CVE-2024-27758.patch.
- Patch SHA256:
  be30ddfb1c633f4a54a4f6da575d01ac43452c94f769c6adc894cf99d1433be9.
- Test: utils/patch-rpyc-4.1.5/test_security.py.
- Test SHA256:
  bdb5c9efa2319594839c3a3b6b9250590afae152e59b578805b873a04e910f09.
- Corrected netref.py SHA256 (LF):
  92b477b86552e05875a133b8cfad9a0069d69776009b39504c1a960f950b3321.
- Original W20 Unix netref.py SHA256:
  d828fa1e6f7bc091b26545c4295bb6123ee720adc2be6ddf468f6a7a553d7d86.
- Unix runtime: build/python2-runtime-agent-unix-W22.
- Unix autonomous construction: PASS; pip check: PASS.
- Windows runtime: C:\padit-runtime-1.8.3-W22-rpyc-ter.
- Windows autonomous construction: SUCCESS; pip check: PASS.
- Windows source SHA256 checked after CRLF/LF normalization.
- Unix and Windows: security regression 2/2 PASS.
- Denied configuration: no remote request or deserialization.
- Allowed configuration: historical behavior preserved.
- Implementation commits: 626326bb, c3b2bd83, 8e15f5e3.
- Dependabot #41 dismissed, reason fix_started.
- Dismissal applies to PADIT-controlled corrected runtimes.
- Historical runtimes preserved.
- Three protected Debian artifacts untouched.
- PyScripter console integration not functionally retested.

**Next**
- Inventory remaining open Dependabot alerts.
- Prioritize Python 2.7-compatible security remediations.
- Preserve existing validated Unix and Windows runtimes.

## W23 - python-socketio 4.4.0 / CVE-2026-48804 (2026-11-03)

**Status: PASS - Unix Bookworm and Windows x86.**

- Dependabot #78: HIGH, CVE-2026-48804.
- Package: python-socketio==4.4.0, Python 2.7 compatible.
- Reused validated Bookworm server backport U77.
- Original patch commit: 38e4ffc8.
- Windows integration commit: 5ce7c0eb.
- Patch: utils/patch-python-socketio-4.4.0/CVE-2026-48804.patch.
- Patch SHA256:
  5bc5f0ce38f7d748415a2264fb869d0a6b36325bf7b765673fa65160130983d7.
- Regression test:
  utils/patch-python-socketio-4.4.0/test_security.py.
- Test SHA256:
  217a9285b370d91f8808f61337a968df9589921ae2aad2bc08a6a9f266f09919.
- Security: unauthenticated binary packet rejected.
- Security: incomplete binary packet cleared on disconnect.
- Unix Bookworm W22 runtime: regression 2/2 PASS.
- Windows x86 W23 runtime: regression 2/2 PASS.
- Windows runtime:
  C:\padit-runtime-1.8.3-W23-socketio.
- Windows autonomous build: SUCCESS, exit code 0.
- Unix and Windows: pip check PASS.
- Windows PowerShell syntax: 0 parse errors.
- Dependabot #78 dismissed, reason fix_started.
- Dismissal applies to PADIT-controlled patched runtimes.
- Historical validated runtimes preserved.
- Three protected Debian artifacts preserved.
- Full Windows product/installer integration remains deferred.

**Next**
- Continue inventory of remaining Dependabot alerts.
- Reuse validated Bookworm server fixes for Unix and Windows agents.
- Preserve previously validated runtimes and security tests.

## W24 - Engine.IO 3.11.2 / CVE-2026-48809 and CVE-2026-48802 (2026-11-03)

**Status: PASS - deployment-specific non-applicability verified.**

- Dependabot #76: HIGH, CVE-2026-48809.
- Dependabot #77: HIGH, CVE-2026-48802.
- Package: python-engineio==3.11.2, retained for Python 2.7.
- No existing PADIT server backport identified for these CVEs.
- Audited historical Engine.IO server and socket implementations.
- Runtime used for verification:
  build/python2-runtime-agent-unix-W22.
- Dynamic test: engineio.Server() selected async_mode=eventlet.
- PADIT server uses Flask-SocketIO and Eventlet.
- CVE-2026-48809 affects ASGI polling and aiohttp WebSocket paths.
- Those asynchronous drivers are not used by the validated PADIT deployment.
- CVE-2026-48802 describes excessive heartbeat task/thread creation.
- Historical Engine.IO 3.11.2 uses client PING/server PONG.
- Socket.receive() updates last_ping and sends PONG without launching a task.
- Dynamic source inspection: PASS.
- Dependabot #76 dismissed with reason not_used.
- Dependabot #77 dismissed with reason not_used.
- No patch applied; no runtime reconstruction necessary.
- Scope: verified PADIT Eventlet deployment and historical heartbeat behavior.
- Not a claim that all Engine.IO configurations are unaffected.
- Reassess if the async driver, Engine.IO version or deployment changes.

**Next**
- Continue remaining Dependabot security inventory.
- Reuse previously validated Bookworm server fixes when applicable.
- Preserve Unix/Windows validated runtimes and protected artifacts.

## W25 - urllib3 1.26.20 / CVE-2025-50181 and CVE-2026-44431 (2026-11-03)

**Status: PASS - Unix Bookworm and Windows x86/VC9 autonomous runtimes.**

- Dependabot #55: CVE-2025-50181.
- Dependabot #73: CVE-2026-44431.
- Package: urllib3==1.26.20, retained for Python 2.7 compatibility.
- Seven urllib3 security patches integrated into both agent builders.
- Five previously validated urllib3 patches preserved.
- CVE-2025-50181: PoolManager constructor retry configuration respected.
- CVE-2026-44431: sensitive headers stripped on cross-origin redirects
  through the low-level connection pool.
- No mutable shared connection-pool state introduced.
- Custom Retry.remove_headers_on_redirect policy respected.

**Security artifacts**

- utils/patch-urllib3-1.26.20/CVE-2025-50181.patch
  SHA256: 61b801a0221bbf0df4a3212b73089d44b95615c4844a79dda58d08fa8bb85fdd
- utils/patch-urllib3-1.26.20/CVE-2026-44431.patch
  SHA256: d633c43dfb96063b2c7be9e996e531813c5db40084cfdec3f836f2840692944e
- utils/patch-urllib3-1.26.20/tests/test_CVE-2025-50181.py
  SHA256: 6517dc15ce5f4ebec72888b2e6ef7ea2e3d76682d5c904b2b541ef7d349d8f7e
- utils/patch-urllib3-1.26.20/tests/test_CVE-2026-44431.py
  SHA256: d5e72443b5191b98172d496f2f8d56d67437a41a521657711227f4cad53c3b39

**Unix Bookworm validation**

- Runtime: build/python2-runtime-agent-unix-W25.
- Autonomous construction: PASS.
- CVE-2025-50181 regression: 5/5 PASS.
- CVE-2026-44431 regression: 4/4 PASS.
- pip check: PASS.
- urllib3 1.26.20 confirmed.
- Historical Unix W22 runtime preserved.

**Windows x86/VC9 validation**

- Runtime: C:\padit-runtime-1.8.3-W25-urllib3.
- Python executable: Scripts\python.exe.
- Python 2.7.18, MSC v.1500, 32-bit: confirmed.
- Autonomous runtime construction: SUCCESS, exit code 0.
- CVE-2025-50181 regression: 5/5 PASS.
- CVE-2026-44431 regression: 4/4 PASS.
- pip check: PASS.
- urllib3 1.26.20 confirmed.
- PowerShell builder syntax: PASS.
- Historical Windows runtimes preserved.

**GitHub / Dependabot**

- Implementation commit: 059f0103.
- Branch: release/1.8.3.
- Commit pushed to github.com/maxcarpone/PADIT.
- Dependabot #55: dismissed, reason fix_started.
- Dependabot #73: dismissed, reason fix_started.
- Both dismissal states independently verified via GitHub API.
- Remaining open Dependabot alerts: 14.
- Inventory: 11 cryptography, 1 pyOpenSSL,
  1 python-socketio and 1 eventlet.
- Three protected Debian artifacts untouched.
- Full Windows product/installer integration remains deferred.

**Next**

- Resume remaining Dependabot security inventory.
- Prioritize eventlet #56, python-socketio #57,
  pyOpenSSL #66 and cryptography alerts.
- Reuse validated Bookworm server security backports.
- Preserve all previously validated runtimes.

## W26 - Eventlet 0.33.3 / CVE-2025-58068 (2026-11-03)

**Status: PASS - Unix Bookworm and Windows x86/VC9.**

- Dependabot #56: CVE-2025-58068, HTTP request smuggling.
- Package: eventlet==0.33.3, retained for Python 2.7.
- Reused existing validated Bookworm server security backport.
- Patch: utils/patch-eventlet-0.33.3/CVE-2025-58068.patch.
- Patch SHA256:
  897e91e4e5c77fe8205408e4daca9c9fc12da7540f34f2c19f92875343ea151d.
- Security fix: discard all HTTP chunked request trailers.
- Existing CVE-2023-29483 TuDoor backport preserved.

**Regression test**

- File: utils/patch-eventlet-0.33.3/test_CVE-2025-58068.py.
- SHA256:
  d3d48cffcdeb41a01af2b15822e6ddf5ef82ca17eb91173de671d6557a1ec38f.
- HTTP trailers discarded: PASS.
- Following HTTP request preserved: PASS.

**Unix Bookworm**

- Runtime: build/python2-runtime-agent-unix-W25.
- Existing Unix Eventlet builder already applies this backport.
- Regression: 2/2 PASS.
- pip check: PASS.
- No Unix runtime reconstruction required.

**Windows x86/VC9**

- Runtime: C:\padit-runtime-1.8.3-W26-eventlet.
- Python: 2.7.18, MSC v.1500, 32-bit.
- Eventlet: 0.33.3.
- Autonomous construction: SUCCESS.
- Regression: 2/2 PASS.
- pip check: PASS.
- Patch and regression test SHA256 verified.
- PowerShell syntax validation: PASS.
- Historical Windows runtimes preserved.

**GitHub / Dependabot**

- Windows implementation commit: 5fba724d.
- Branch: release/1.8.3.
- Dependabot #56 dismissed, reason fix_started.
- Dismissal independently verified via GitHub API.
- Remaining open Dependabot alerts: 13.
- Inventory: 11 cryptography, 1 pyOpenSSL,
  1 python-socketio.
- Three protected Debian artifacts preserved.
- Full Windows installer/product build remains deferred.

**Next**

- W27: investigate python-socketio #57 / CVE-2025-61765.
- Reuse validated Bookworm server fixes where applicable.
- Then investigate pyOpenSSL #66 and cryptography alerts.
- Preserve previously validated Unix and Windows runtimes.

## W27 - python-socketio 4.4.0 / CVE-2025-61765 (2026-11-03)

**Status: PASS - deployment-specific non-applicability verified.**

- Dependabot #57: CVE-2025-61765, pickle deserialization RCE.
- Package: python-socketio==4.4.0, retained for Python 2.7.
- Vulnerability affects inter-server message queue managers
  that deserialize messages using pickle.loads().
- Exploitation requires prior access to the inter-server queue.
- Audited PADIT application sources and Socket.IO configuration.
- No RedisManager, KombuManager or KafkaManager usage identified.
- No message_queue or client_manager configuration identified.
- PADIT production initialization:
  waptserver/server_socketio.py.
- Flask-SocketIO initialized without an inter-server queue.
- Dynamic verification using Unix Bookworm W25 runtime:
  manager = socketio.base_manager.BaseManager.
- Dynamic verification:
  async_mode = eventlet.
- Local BaseManager selected: PASS.
- No inter-server message queue configured: PASS.
- Existing W23 CVE-2026-48804 security backport preserved.
- Dependabot #57 dismissed, reason not_used.
- Dismissal verified through GitHub API.
- No new patch or runtime reconstruction required.
- Scope: current validated PADIT configuration only.
- Vulnerable pickle handling remains in optional queue managers.
- Reassess if Redis, Kombu, Kafka or other inter-server
  messaging is introduced, or if deployment topology changes.
- Three protected Debian artifacts preserved.
- Remaining open Dependabot alerts: 12.
- Inventory: 11 cryptography, 1 pyOpenSSL.

**Next**

- W28: investigate pyOpenSSL #66 / CVE-2026-27448.
- Then review remaining cryptography alerts.
- Reuse validated Bookworm server security backports.
- Preserve existing Unix and Windows runtimes.

## W28 - pyOpenSSL 19.0.0 / CVE-2026-27448 (2026-11-03)

**Status: PASS - Unix Bookworm and Windows x86/VC9 validated.**

### Security remediation

- Dependabot #66 / CVE-2026-27448.
- Vulnerability: an unhandled exception in the TLS SNI callback could allow a TLS connection to be accepted.
- Existing Bookworm backport reused unchanged:
  `utils/patch-pyopenssl-19.0.0/CVE-2026-27448.patch`.
- Patch SHA256:
  `30aa14431d2f886ab8a4caf421c8e4811938fd7b1c32d98ec5e9ffcccad171d0`.
- Regression test:
  `utils/patch-pyopenssl-19.0.0/test-CVE-2026-27448.py`.
- Test SHA256:
  `d5fe1693f07184deb77bb451f6bf721f1e29d89bcfcefb80176667cbec5c85c0`.

### Windows validation

- VM106 / Python 2.7.18 / Windows x86 / MSC v.1500 (VC9).
- W26 vulnerable baseline: normal SNI handshake accepted; handshake also accepted when the SNI callback raised an exception.
- Windows builder integration commit: `6875d54f`.
- Build-order fix commit: `ed8e35a6`.
- Final autonomous runtime:
  `C:\padit-runtime-1.8.3-W28-pyopenssl-v2`.
- W28-v2 build: SUCCESS.
- Normal SNI callback: TLS handshake accepted, PASS.
- Exception in SNI callback: TLS handshake rejected on client and server, PASS.
- CVE-2026-27448 TLS regression: PASS.
- pyOpenSSL 19.0.0 / Python 2.7.18 x86/VC9: PASS.
- OpenSSL executable: 1.0.2u.
- `pip check`: PASS (no broken requirements).
- Historical W26 and incomplete first W28 runtimes preserved.

### Dependabot

- Alert #66 dismissed with reason `fix_started`.
- Direct alert state: `dismissed`.
- Fresh open-alert inventory: 11, all for `cryptography`.
- Previous GitHub listing lag resolved on fresh query.

### Next

- W29: inventory and classify the 11 remaining cryptography alerts.
- Compare with existing Bookworm security backports.
- Preserve validated server and Windows runtimes.
- Do not rebuild unnecessarily or modify protected Debian artifacts.

## W29 - OpenSSL 3.5.9 Unix agent runtime (2026-11-04)

**Status: PASS - complete Unix agent runtime build validated.**

### Validated construction

- Branch: `release/1.8.3`.
- Python 2.7.18 / isolated OpenSSL 3.5.9.
- Python OpenSSL 3 version detection patch:
  commit `984fa58b`.
- OpenSSL and Unix agent builder integration:
  commit `393bd748`.
- OpenSSL 3.5.9 compiled from verified upstream sources.
- Reproducible OpenSSL builder:
  `tools/build-openssl-bookworm.sh`.
- Existing Unix agent main builder updated:
  `tools/build-python2-runtime-agent-unix-bookworm.sh`.
- Existing crypto sub-builder updated:
  `tools/build-agent-unix-crypto-bookworm.sh`.
- Temporary build modes: `system` and `isolated`.
- Python 2 bootstrap uses local verified wheels in isolated mode.
- Modernized dependencies: wheel 0.37.1,
  pycparser 2.21, enum34 1.1.10.
- CFFI 1.15.1 and cryptography 3.3.2 rebuilt with
  PADIT compatibility and security patches.
- Cryptography native module and PADIT X.509 source
  integrity verified before and after other installations.
- OpenSSL 3.5.9 runtime linkage verified without
  `LD_LIBRARY_PATH`.
- All loaded libssl/libcrypto libraries originate from
  the isolated OpenSSL prefix.
- Existing Unix agent security backports retained.
- Waitress W20 and RPyC W22 regressions: PASS.
- Final `pip check`: PASS.
- Full automated build W29-O74: PASS.
- Final consolidation W29-O75: PASS.

### Reproducibility references

- Runtime:
  `/opt/padit-lab/runtime-agent-unix-openssl35-W29`.
- Runtime size: approximately 226 MiB as reported by `du -sh`.
- OpenSSL prefix:
  `/opt/padit-lab/openssl-3.5.9-builder`.
- Build workspace:
  `/opt/padit-lab/work/agent-unix-openssl35-W29`.
- Build log:
  `/opt/padit-lab/logs/W29-O74-agent-unix-openssl35.log`.
- Build log SHA256:
  `79e2909499d4e64a5244f2325455b9503ea986eeb62492bc0c5d7d546f9d670c`.
- System OpenSSL 3.0.22 preserved.
- Previously validated server, Unix and Windows runtimes preserved.
- Three protected Debian packaging artifacts preserved.

### Remaining limitations

- Build validated; autonomous Debian package not yet validated.
- Runtime still depends on laboratory OpenSSL absolute paths.
- Relocatable OpenSSL packaging and `$ORIGIN` linkage remain.
- Some dependencies still require network access during builds.
- Windows x86/VC9 compatibility with OpenSSL 3.5.9
  has not been established.
- Eleven Dependabot cryptography alerts remain to investigate.
- No Python 3 migration in this milestone.

### Builder rationalization decision

- Long-term goal: one public build entry point per product:
  Unix agent, Windows agent, Bookworm server.
- Each product follows three stages:
  Environment / Runtime / Build.
- Retain automated security regressions, source checksums,
  binary provenance checks and final PASS/FAIL validations.
- Consolidate specialized dependency sub-builders where useful.
- Avoid a new monolithic constructor or unnecessary new scripts.
- Remove transitional `system` / `isolated` complexity only
  after the autonomous standard build is validated.
- Do not refactor validated builders while establishing
  the next functional baseline.

### Next

1. Preserve W29 validated runtime and builder commits.
2. Establish portable isolated OpenSSL linkage and packaging.
3. Validate autonomous Unix agent Debian installation.
4. Consolidate build orchestration with Environment / Runtime / Build.
5. Reuse the validated crypto architecture for Bookworm server.
6. Investigate remaining cryptography alerts and Windows compatibility.

## W30 - Autonomous Unix agent build and packaging (2026-11-04)

**Status: PASS - build and extracted package validation.**

- Branch: `release/1.8.3`.
- Environment/Runtime commit: `f9d3c4f1`.
- Portable packaging commit: `42b3bdc5`.
- Debian 12 Bookworm amd64.
- Python 2.7.18 / isolated OpenSSL 3.5.9.
- Full fresh runtime reconstruction: PASS.
- Runtime: `/tmp/padit-w30-fresh-build/runtime` (225 MiB).
- OpenSSL: `/tmp/padit-w30-fresh-build/openssl`.
- Runtime build log SHA256:
  `18cf37621aa7e1337d14cad9d77de5b5ba769c2c03e1bf58daffaed4dd579faf`.
- Environment / Runtime / Build architecture retained.
- Sources and bootstrap wheels acquired with pinned SHA256.
- OpenSSL 3.5.9 bundled in the Debian package.
- ELF RUNPATH relocated using patchelf during staging.
- Extracted package loads only bundled OpenSSL: PASS.
- Native Debian dependencies calculated by dpkg-shlibdeps.
- No system libssl3 dependency or package self-dependency.
- Bundled certifi CA bundle loads successfully.
- Systemd service includes SSL_CERT_FILE and REQUESTS_CA_BUNDLE.
- Pilot package: `tis-waptagent_1.8.3.7494+unixpilot1_amd64.deb`.
- Package location:
  `/tmp/padit-w30-autonomous-products-r2/`.
- Package SHA256:
  `346f853d47d3cbe02c023a05a88b9ea32364750bbb8e0e99840b64305c7059d7`.
- Three protected Debian artifacts preserved.

**Not yet validated**

- Installation on a separate clean Debian 12 machine.
- Agent startup, registration, service operation and real TLS.
- Compatibility with internal CA and administrator CA overrides.
- Complete functional runtime dependency coverage.

**Next**

1. Test installation on clean Debian 12.
2. Verify agent commands, service and TLS trust.
3. Consolidate Unix build orchestration and documentation.
4. Apply the same architecture review to Debian server and Windows agent.

## W31 - Clean Debian 12 Unix agent reproduction (2026-11-04)

**Status: PASS - full Git-to-Debian-package reconstruction.**

Build host: `padit`, independent Debian 12 amd64 VM.

- Git source: `release/1.8.3`, commit `ef79946a`.
- Source retrieved from GitHub without using local waptworm files.
- Initial recursive clone exposed inaccessible legacy Enterprise submodule.
- Community build does not require Enterprise submodules.
- Environment: PASS.
- Clean-build gap: missing libpq-dev / pg_config.
- Environment fix committed: `ef79946a`.
- Runtime R2: PASS.
- Python 2.7.18, OpenSSL 3.5.9, cryptography 3.3.2.
- Runtime size: 225 MiB.
- Runtime log SHA256:
  `3efcb113b4919a3c1905991e9129d13fce3fc72bf7b050461fc9ab9a7b65d0c5`.
- Build: PASS.
- Native Debian dependencies automatically calculated.
- Package size: approximately 39 MiB.
- Package SHA256:
  `82c4ceccd5aac6990e2ed22dc903e75ca6817c6126c5d2b2d7c5d603df9cb096`.
- Package build log SHA256:
  `07c7ddb41254529cf060db71d52077602a7d5a2906a231565eae90e29627badc`.
- Output: `/tmp/padit-w31-products/tis-waptagent_1.8.3.7494+unixpilot1_amd64.deb`.

**Follow-up**

- Exclude relocatable python.o from dpkg-shlibdeps ELF inventory.
- Validate package installation on a clean Debian 12 test VM.
- Validate agent CLI, systemd service, TLS trust and registration.
- Maintain Environment / Runtime / Build orchestration.

---

## W32-H56 — Reprise ALPN OpenSSL 3.5.9

Date : 2026-11-06
Machine de compilation : VM106
Machine de test : VM107
Branche : feature/w32-openssl-3.5.9
Commit de base : 9e7b57879794377957f8ff36f0faab3e837d51d2
Version produit : 1.8.3.7687

### Acquis W32

- OpenSSL 3.5.9 Windows x86 construit et validé : 4283 tests PASS.
- CPython 2.7.18 : extensions _ssl.pyd et _hashlib.pyd reconstruites.
- Runtime cryptography 3.3.2 adapté à OpenSSL 3.5.9.
- Installateur Windows reconstruit avec les 9 artefacts Lazarus signés.
- Signature Authenticode Thouet Software Code Signing validée.
- Installation et démarrage de la console sur VM107 : PASS.
- Création du certificat personnel depuis la console : PASS.
- Console fonctionnelle : PASS.
- VM104 avec ancien agent : Reachable, confirme le fonctionnement du serveur Bookworm.

### Problèmes identifiés sur VM107

- WAPTService sous NSSM : processus waptpython.exe instable.
- Plantages natifs répétés : exception 0xC0000005.
- SQLite : OperationalError database is locked dans les journaux.
- HTTPS requests 2.27.1 / urllib3 1.26.20 : échec lors de load_default_certs().
- Erreur SSL : unknown error (_ssl.c:2938).
- HTTPS natif Python 2.7 / OpenSSL 3.5.9 avec SNI : PASS.
- HTTPS natif complet vers waptworm : HTTP 200, exit code 0.
- urllib3 avec contexte SSL explicite : HTTP 200, puis crash 0xC0000005.

### Diagnostic ALPN — H51 à H54

Reproducer minimal sur VM107 :

    import ssl
    context = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(['http/1.1'])
    del context

Résultat avant correction : crash 0xC0000005.

Cause identifiée dans CPython 2.7.18 Modules/_ssl.c,
fonction _set_alpn_protocols() :

- Ligne 2495 : PyBuffer_Release(&protos)
- Ligne 2501 : second PyBuffer_Release(&protos)
- Double libération du même Py_buffer.
- La suppression du second appel reste à valider par recompilation.

### Correctif H55-F — PASS

Fichier Git modifié :

    tools/02-build-windows-runtime.ps1

- Correctif intégré après vérification SHA256 des sources originales.
- Suppression du second PyBuffer_Release() dans _set_alpn_protocols().
- Motif regex corrigé pour accepter la ligne vide entre les instructions.
- Correctif également appliqué aux sources de travail déjà extraites.
- git diff --check : PASS.
- Un seul fichier suivi modifié, NON COMMITÉ.

Source de travail corrigée :

    C:\padit-build-kit\runtime\openssl\work\W32-1911a18b74c44fd1910dcb6a9b566cd7\python-source\Python-2.7.18\Modules\_ssl.c

### Reprise obligatoire — W32-H57

Objectif immédiat :

1. Recompiler uniquement _ssl.c et rééditer les liens de _ssl.pyd.
2. Utiliser MSVC 2022 x86 et les bibliothèques OpenSSL 3.5.9 déjà construites.
3. Tester le nouveau module dans un environnement isolé sur VM106.
4. Rejouer le reproducer ALPN H51 : code retour 0 attendu.
5. Rejouer HTTPS urllib3 et vérifier l'absence de crash natif.
6. Investiguer séparément load_default_certs() et le magasin Windows.
7. Après validation, intégrer le correctif au runtime, reconstruire le setup et retester VM107.

Contraintes :

- NE PAS reconstruire OpenSSL 3.5.9 ni relancer ses 4283 tests.
- NE PAS reconstruire cryptography ou le produit complet à ce stade.
- NE PAS modifier le runtime W32 gelé avant validation du module.
- NE PAS perdre la modification Git non commitée du constructeur 02.
- Préserver les artefacts signés et les résultats déjà validés.
- Pas de nettoyage automatique des répertoires de VM106.

État final : W32 GUI PASS ; W32 SERVICE FAIL ; ALPN PATCH APPLIQUÉ MAIS NON ENCORE COMPILÉ.

## W32-H57-AO - Cloture SSL / TLS Windows

Date : 2026-11-06
Branche : feature/w32-openssl-3.5.9
Commit de base : 9e7b57879

### 1. Contexte

- Python 2.7.18 x86 conserve son runtime VC9 / MSVCR90.
- OpenSSL 3.5.9 x86 : build MSVC 2022 deja valide.
- cryptography 3.3.2 : build existant preserve.
- Extension _ssl.pyd : compilation MSVC 2022 x86.
- Aucun rebuild complet OpenSSL/cryptography pendant H57.

### 2. Defauts corriges

H55-F :
- Suppression d'un PyBuffer_Release redondant dans
  _set_alpn_protocols().

H57-AD2 :
- Correction de trois appels PyMem_FREE en PyMem_Free.
- Un appel dans le destructeur NPN.
- Un appel dans le destructeur ALPN.
- Un appel dans le remplacement des protocoles ALPN.
- Objectif : eviter la liberation d'allocations Python
  par le CRT MSVC 2022.

### 3. Diagnostic natif

- Crash initial : 0xC0000005.
- WinDbg CDB x86 : HEAP_CORRUPTION.
- Pile : _ssl.pyd -> ucrtbase!free -> ntdll!RtlFreeHeap.
- Cause identifiee : incompatibilite des allocateurs
  pour les buffers NPN/ALPN.
- Dump de diagnostic conserve dans H57/crash-dumps.

### 4. Validations

- H57-AD3 : correctifs source PASS.
- H57-AE : compilation _ssl.pyd PASS.
- H57-AF : 10/10 tests HTTPS PASS, exit code 0.
- H57-AH : integration constructeur PASS.
- H57-AI : validation statique constructeur PASS.
- H57-AK : certificat serveur inspecte.
- H57-AL : certificat PEM de test exporte.
- H57-AM4 : HTTPS CERT_REQUIRED, HTTP 200, PASS.
- H57-AN : mauvais nom DNS correctement rejete, PASS.

SHA256 source _ssl.c corrige :
934F53355AAF582C3A5E6C8FB2D46A7997D1CED60A1BB2C18655A249C92063F0

### 5. TLS laboratoire

Serveur : waptworm
Identite TLS : waptdev.genevoix-signoret-vinci.fr.lan
Certificat autosigne, explicitement approuve pour le test.
Verification du nom effectuee avec assert_hostname.
Aucune modification des magasins de certificats Windows.
Ne pas generaliser cette configuration au produit.

### 6. Etat et reprise

- Correctifs integres dans tools/02-build-windows-runtime.ps1.
- WAPT_CHECKPOINT.md conserve comme reference.
- Deux fichiers Git modifies, aucun commit demande.
- Anciens binaires et artefacts conserves.
- Validation globale du runtime encore a effectuer.
- Python 2.7 / VC9 reste une dependance technique.
- Prochaine action : reprendre la feuille de route W32
  sans reconstruire OpenSSL ni cryptography.

Statut : W32-H57-AN PASS / H57 cloture sur perimetre teste.
## W32-H60 — Clôture OpenSSL 3.5.9 Windows x86 / VM107 (2026-11-06)

Statut : PASS — validation fonctionnelle sur VM107.

### Correctifs intégrés

- H55-F : suppression du double PyBuffer_Release dans CPython _ssl.c.
- H57-AD2 : remplacement des libérations PyMem_FREE incorrectes par PyMem_Free, pour la compatibilité VC9 / UCRT.
- H60 : PADIT-COMPAT-PY27-OPENSSL35-003, conversion DER vers PEM pour le chargement des certificats Windows dans Lib/ssl.py.
- Les correctifs sont intégrés dans tools/02-build-windows-runtime.ps1.
- Contrôle Authenticode des exécutables Lazarus intégré dans tools/03-build-windows-product.ps1.

### Livrable Windows

- Version : 1.8.3.7687.
- Runtime : C:\padit-runtime-1.8.3-W32-H60
- Produit : C:\padit-product-1.8.3-W32-H60
- Installateur : waptsetup\waptsetup.exe
- Signature Authenticode : Valid.
- SHA256 : EDAEC40AA0FB900DE2B7495567697DB7281DF9C69102B414E2F03E1BFEF5CCAC

### Validation VM107

- Installation par-dessus la version précédente : PASS.
- Chargement des certificats Windows CA/ROOT : PASS.
- urllib3 et requests avec le correctif DER vers PEM : HTTP 200.
- Console PADIT : PASS.
- Edition des profils VM104 et VM107 : PASS.
- Reachable VM107 : PASS.
- WAPTService sous NSSM : Running.
- Processus waptpython.exe : présent.
- W32-H60-L : aucun crash natif récent détecté ; aucune erreur SSL détectée dans les dernières lignes du journal.

### Dette de compatibilité

Les adaptations Python 2.7 / OpenSSL 3.5.9 doivent rester identifiables et réévaluables lors d'une migration Python 3 / modernisation de la chaîne Windows.

Ne pas supprimer ces correctifs sans tests de régression sur la nouvelle chaîne.

### Reprise

- Reprendre l'inventaire et la remédiation des CVE restantes.
- Ne pas recommencer les validations H55-H60 acquises.
- Aucun commit créé à cette étape.
