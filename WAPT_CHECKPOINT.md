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

