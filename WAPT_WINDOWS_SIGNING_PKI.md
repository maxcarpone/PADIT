# WAPT Windows Signing PKI

## 1. Purpose and scope

This document describes the private Public Key Infrastructure (PKI) used to
Authenticode-sign WAPT Windows executables.

Its objectives are to:

- provide a stable signing identity for WAPT Windows executables;
- allow autonomous deployment without dependency on an Active Directory domain
  or an external PKI service;
- protect the Root CA private key by keeping it offline during normal operation;
- document the annual Code Signing certificate renewal procedure;
- preserve one previous Code Signing generation for operational recovery;
- document the public Root CA distribution and trust bootstrap mechanism.

The PKI described here is the signing infrastructure currently used for the
WAPT Community 1.8.3 modernization work.

The PKI creation and renewal tool is:

    tools/create-windows-signing-pki.ps1

The `Create` and `RenewCodeSigning` workflows were functionally validated using
a disposable test PKI before being committed.

## 2. PKI architecture

The Authenticode hierarchy contains two certificate levels:

    Thouet Software Signing Root CA
        |
        +-- Thouet Software Code Signing
                |
                +-- WAPT Windows executables

### Root CA

Current Root CA identity:

    Subject:     CN=Thouet Software Signing Root CA
    Issuer:      CN=Thouet Software Signing Root CA
    Thumbprint:  DE744EACCC9F4E7D96611608BEEE52033B8FDD2A
    Validity:    2026-09-25 to 2036-09-25
    Key:         RSA 4096
    Hash:        SHA-256

The Root CA is long-lived and is not used for normal Windows builds.

Its private key is stored in a password-protected PFX and must remain offline
except when a new Code Signing certificate is issued.

The public Root CA certificate may be distributed freely.

### Code Signing certificate

Current Code Signing identity:

    Subject:     CN=Thouet Software Code Signing
    Issuer:      CN=Thouet Software Signing Root CA
    Thumbprint:  20B9EFB1891AFD28DD7695F0E6F3C1F3A8C020E5
    Validity:    2026-09-25 to 2027-09-25
    Key:         RSA 3072
    Hash:        SHA-256

The Code Signing certificate is the normal private signing identity used by the
Windows build process.

It is renewed annually while keeping the same Root CA.

The renewal policy keeps:

    N     = current Code Signing certificate
    N - 1 = previous Code Signing certificate

Older Code Signing generations are not retained by the renewal mechanism.

### Timestamping

Authenticode signatures use RFC 3161 timestamping.

Current timestamp service:

    http://timestamp.sectigo.com/rfc3161

A valid timestamp allows a signature created while the Code Signing certificate
was valid to remain verifiable after that certificate expires, subject to the
normal Windows Authenticode trust rules.

## 3. Separation from other WAPT certificates

The Windows Authenticode PKI is independent from the other certificate uses
inside WAPT.

Three mechanisms must not be confused.

### Windows Authenticode signing

Purpose:

    Establish the Windows publisher identity and executable integrity.

Hierarchy:

    Thouet Software Signing Root CA
        -> Thouet Software Code Signing
            -> Windows executable

Windows must trust the public Root CA for this private Authenticode hierarchy
to be trusted.

### WAPT package signing

WAPT package signing uses its own certificates and trust mechanisms.

Certificates stored in WAPT directories such as `{app}\ssl` belong to the WAPT
package-signing infrastructure. They do not establish Windows Authenticode
trust for `waptconsole.exe`, `waptagent.exe`, `waptsetup.exe`, or other Windows
executables.

Migration of the historical WAPT package-signing identity is outside the scope
of this document and is deferred to the future replacement of that identity.

### HTTPS certificates

TLS/HTTPS certificates used to authenticate the WAPT server are also separate
from the Authenticode PKI.

Changing or trusting the Authenticode Root CA does not replace or modify the
HTTPS server certificate verification mechanism.

## 4. Files and storage locations

The default locations used by the PKI tool are:

### Offline Root CA private material

    C:\private-wapt-signing\root\
        Thouet-Software-Signing-Root-CA.pfx

This PFX contains the Root CA private key.

It must never be:

- committed to Git;
- copied into the WAPT build kit;
- included in a WAPT installer;
- published by the WAPT server;
- left permanently on an ordinary build workstation.

After PKI creation or Code Signing renewal, the Root CA PFX must return to its
protected offline storage.

### Code Signing private material

    C:\private-wapt-signing\codesigning\
        Thouet-Software-Code-Signing.pfx

This PFX contains the current Code Signing private key.

It is the private identity required for normal Authenticode signing.

After a renewal, the previous generation is stored as:

    C:\private-wapt-signing\codesigning\archive\
        previous.cer
        previous.pfx

The archive is intentionally limited to one previous generation.

### Public certificates

Default public directory:

    C:\wapt-build-kit\signing\public\

Current public files:

    Thouet-Software-Signing-Root-CA.cer
    Thouet-Software-Code-Signing.cer

The Root CA `.cer` contains no private key and may be distributed to Windows
systems that must trust WAPT Authenticode signatures.

Reference SHA-256 for the current public Root CA certificate:

    5BB7881D601856F1EE55C7A7B88E988751751779DEE1AB08D21DD319B1690E7A

The private Root CA PFX must never accompany this public certificate.
## 5. Initial PKI creation

Initial creation is performed only when establishing a new signing PKI.

It creates:

- a new long-lived Root CA;
- a new Code Signing certificate issued by that Root CA;
- the public certificates;
- the corresponding password-protected private PFX files.

Run from the repository root:

    .\tools\create-windows-signing-pki.ps1 -Action Create

The script interactively requests:

1. a password for the Root CA PFX;
2. a password for the Code Signing PFX.

Passwords are not stored by the script.

The `Create` action refuses to overwrite existing PKI material. It must not be
used to renew an existing Code Signing certificate.

After creation:

1. verify the Root and Code Signing certificate identities;
2. verify that the Code Signing certificate was issued by the new Root CA;
3. securely archive the Root CA PFX offline;
4. retain the Code Signing PFX on the controlled signing/build workstation;
5. publish only the public Root CA certificate where required.

Creating a replacement Root CA is not part of the normal annual renewal
procedure.

## 6. Normal Windows build signing

Normal Windows builds use only the current Code Signing private key.

The Root CA private key is not required and must remain offline.

The canonical Code Signing PFX is:

    C:\private-wapt-signing\codesigning\
        Thouet-Software-Code-Signing.pfx

The public Root CA used by the build and distribution process is:

    C:\wapt-build-kit\signing\public\
        Thouet-Software-Signing-Root-CA.cer

The normal signing hierarchy is therefore:

    offline Root CA
        |
        +-- current Code Signing PFX
                |
                +-- SignTool
                        |
                        +-- WAPT Windows executable

The build/signing process must use SHA-256 for the Authenticode signature and
RFC 3161 timestamping.

The Root CA PFX must not be copied onto the build workstation merely to perform
a normal build.

## 7. Annual Code Signing certificate renewal

The Code Signing certificate is designed to be renewed annually while retaining
the existing long-lived Root CA.

Renewal is performed with:

    .\tools\create-windows-signing-pki.ps1 -Action RenewCodeSigning

The Root CA PFX must be made temporarily available at its expected private
location before starting the operation:

    C:\private-wapt-signing\root\
        Thouet-Software-Signing-Root-CA.pfx

The corresponding public Root CA certificate must also be available:

    C:\wapt-build-kit\signing\public\
        Thouet-Software-Signing-Root-CA.cer

The renewal action:

1. verifies that the required Root and current Code Signing files exist;
2. requests the Root CA PFX password;
3. requests a password for the new Code Signing PFX;
4. temporarily imports the Root CA private key into the current user's Windows
   certificate store;
5. verifies that the imported Root matches the expected public Root
   certificate;
6. verifies that the current Code Signing certificate identifies this Root as
   its issuer;
7. creates a new RSA 3072 / SHA-256 Code Signing certificate;
8. exports the new public certificate and password-protected PFX;
9. validates the exported public certificate;
10. archives the current Code Signing generation as N-1;
11. promotes the new generation to the canonical filenames;
12. removes the temporary Root and Code Signing certificates from the Windows
    certificate store;
13. removes temporary `.new` files.

The Root CA is imported without making its private key exportable.

A successful operation ends with:

    [PASS] Code Signing certificate renewed.

After renewal:

- return the Root CA PFX immediately to protected offline storage;
- verify the new Code Signing certificate;
- update the securely stored Code Signing PFX password as required by local
  operational procedures;
- perform a test Authenticode signature before using the new certificate for a
  release.

The renewal operation must not be performed merely to test the script against
the production PKI. Development and validation tests must use a disposable PKI.

## 8. N + N-1 retention policy

The Code Signing renewal mechanism deliberately retains only two generations:

    N     current Code Signing certificate and PFX
    N-1   immediately previous certificate and PFX

The current generation uses the canonical paths:

    C:\private-wapt-signing\codesigning\
        Thouet-Software-Code-Signing.pfx

    C:\wapt-build-kit\signing\public\
        Thouet-Software-Code-Signing.cer

The previous generation is stored as:

    C:\private-wapt-signing\codesigning\archive\
        previous.cer
        previous.pfx

At the next renewal, the existing N-1 archive is replaced by the certificate
that was N immediately before renewal.

The renewal tool does not accumulate an indefinite history of expired private
Code Signing keys.

The N-1 generation exists for controlled operational recovery. It must receive
the same private-key protection as the current Code Signing PFX.

The Root CA is not part of this rotation. It remains unchanged until a separate,
planned Root CA replacement is required.

## 9. Root CA handling and offline storage

The Root CA private key is the most sensitive element of the Authenticode PKI.

Its canonical private file is:

    C:\private-wapt-signing\root\
        Thouet-Software-Signing-Root-CA.pfx

This path is the working location expected by the PKI tool. It must not be
interpreted as permanent storage for the Root CA private key.

During normal operation, the Root CA PFX must be kept offline in protected
storage and must not remain on the build workstation.

The Root CA private key is required only for:

- initial PKI creation;
- annual Code Signing certificate renewal;
- a future planned replacement or recovery operation involving the signing PKI.

For an annual renewal:

1. retrieve the Root CA PFX from protected offline storage;
2. place it temporarily at the expected working location;
3. run `RenewCodeSigning`;
4. verify that renewal completed successfully;
5. remove the working copy of the Root CA PFX;
6. return the authoritative Root CA PFX to protected offline storage.

The Root CA PFX password must be managed separately from the PFX itself.

The password must not be:

- committed to Git;
- written in this document;
- embedded in build scripts;
- stored beside the Root CA PFX as plain text;
- included in WAPT backup archives or installation media.

The public Root CA certificate is not secret and may remain in the build kit,
Git-controlled product sources where explicitly required, and WAPT distribution
locations.

The Root CA private key must never be distributed to WAPT clients.

## 10. Secure transfer to another build workstation

A second authorized build workstation may require the current Code Signing
private identity.

The Root CA private key is not required for this operation.

Transfer only the material required for normal signing:

    Thouet-Software-Code-Signing.pfx

The PFX must remain protected by a strong password during transfer and storage.

The PFX and its password must be transferred using separate protected channels
according to the organization's operational security procedures.

After transfer:

1. place the Code Signing PFX in the controlled private signing directory;
2. provide the required public Root CA certificate to the build kit;
3. verify the Code Signing certificate subject, issuer and thumbprint;
4. verify that the destination workstation trusts the intended public Root CA
   when local Authenticode verification is required;
5. perform a test signature and verify it before producing release artifacts.

Do not transfer the Root CA PFX merely to provision another normal build
workstation.

If the destination workstation must also perform annual certificate renewal,
Root CA access must remain a separate, temporary offline-key operation.

## 11. Public Root CA distribution and trust bootstrap

Because this Authenticode hierarchy uses a private Root CA, Windows does not
trust it automatically.

The public Root CA certificate is therefore distributed with the WAPT product
and is also published by the WAPT server.

The public certificate is:

    Thouet-Software-Signing-Root-CA.cer

Current reference SHA-256:

    5BB7881D601856F1EE55C7A7B88E988751751779DEE1AB08D21DD319B1690E7A

### WAPTSetup bootstrap

The WAPTSetup installer contains the public Root CA certificate.

During an interactive installation, WAPTSetup asks the administrator for
confirmation before adding this certificate to the Windows Local Machine
Trusted Root Certification Authorities store.

If the administrator refuses the operation, installation is aborted.

During silent or very-silent installation, the bootstrap is performed without
the interactive confirmation prompt.

Only the public Root CA certificate is installed. The Root CA private key is
never included in WAPTSetup.

### Server publication

The WAPT server publishes the public Root CA certificate so that administrators
can retrieve, verify and deploy it independently when required.

This permits alternative deployment mechanisms such as centrally managed trust
deployment while preserving autonomous installation capability.

Trusting certificates found in WAPT package-signing directories such as
`{app}\ssl` does not replace this Windows Root CA trust requirement.

## 12. Disaster recovery considerations

The public Authenticode Root CA certificate is part of the WAPT server
distribution state and must survive a WAPT disaster-recovery restore.

The validated Debian 10 DR restore procedure preserves the published public
Root CA certificate together with the Windows setup and deployment artifacts.

The Root CA private PFX is deliberately excluded from the WAPT server DR scope.

It must be recovered from its independent protected offline storage.

The current Code Signing private PFX is also private signing material and must
be protected independently from the public WAPT server repository.

After a disaster-recovery operation, verify independently that:

- the published Root CA `.cer` is the expected certificate;
- its SHA-256 matches the controlled reference;
- restored WAPTSetup and WAPTDeploy artifacts are the intended versions;
- Windows clients can establish the expected Authenticode trust chain;
- no Root CA private key has been introduced into the server repository or DR
  archive.

The Authenticode PKI recovery procedure remains separate from WAPT package
signing certificate recovery and from HTTPS server certificate recovery.

## 13. Validation checklist

### After initial PKI creation

Verify:

- the Root CA subject is the expected identity;
- the Root CA is self-issued;
- the Code Signing certificate has the expected subject;
- the Code Signing certificate issuer is the Root CA;
- the Root CA and Code Signing thumbprints have been recorded;
- the Root CA public certificate has been exported;
- the Root CA private PFX has been moved to protected offline storage;
- the Code Signing PFX is available only to authorized signing/build systems;
- no private key material has been added to Git.

### After annual Code Signing renewal

Verify:

- the Root CA thumbprint is unchanged;
- the new Code Signing thumbprint differs from the previous generation;
- the new Code Signing certificate issuer is the expected Root CA;
- the new Code Signing validity period is correct;
- the canonical `.cer` represents the new current generation;
- the canonical `.pfx` represents the new current private identity;
- `archive\previous.cer` represents the immediately preceding generation;
- `archive\previous.pfx` is present;
- no older Code Signing generations remain in the renewal archive;
- no `.new` files remain;
- the temporary Root CA certificate/private key has been removed from the
  current user's Windows certificate store;
- the Root CA PFX has been returned to protected offline storage.

Before using the renewed identity for a release, sign a test executable and
verify:

- Authenticode status is valid;
- signer subject is the expected Code Signing identity;
- issuer is the expected Root CA;
- the signature uses SHA-256;
- an RFC 3161 timestamp is present;
- verification succeeds on a machine trusting the intended Root CA.

### Before a Windows release

Verify:

- the intended Code Signing PFX is being used;
- WAPTSetup contains the intended public Root CA certificate;
- the public Root CA SHA-256 matches the controlled reference;
- the generated Windows executables are signed;
- timestamping succeeded;
- the published server artifacts are byte-identical to the validated release
  artifacts where byte identity is expected.

## 14. Security rules

The following rules are mandatory for this private Authenticode PKI.

1. Never commit a private PFX, PEM or private key to Git.
2. Never publish the Root CA private key.
3. Never include the Root CA private PFX in WAPTSetup, WAPTAgent, the build kit
   or the WAPT server repository.
4. Keep the Root CA private key offline except during an authorized operation
   that explicitly requires it.
5. Keep the Root CA PFX password separate from the PFX.
6. Do not place signing passwords in scripts, documentation or source control.
7. Use the Code Signing private key, not the Root CA private key, for normal
   executable signing.
8. Protect the current and N-1 Code Signing PFX files as private key material.
9. Verify certificate identity before signing release artifacts.
10. Use SHA-256 Authenticode signatures and RFC 3161 timestamping.
11. Do not confuse Windows Authenticode trust with WAPT package-signing trust.
12. Do not confuse either signing mechanism with HTTPS server certificate
    verification.
13. Test PKI tooling against disposable PKI material rather than the production
    Root CA.
14. Treat unexpected changes to the Root CA thumbprint as a stop condition
    requiring investigation.

Compromise or suspected compromise of the Root CA private key requires a
separate Root CA replacement and trust-migration procedure. Annual
`RenewCodeSigning` is not a recovery mechanism for a compromised Root CA.

Compromise or suspected compromise of a Code Signing private key must not be
handled as an ordinary scheduled renewal without first assessing already signed
artifacts, key exposure and the required certificate replacement actions.

## 15. Open-source / BYO-PKI considerations

The current WAPT Community 1.8.3 modernization release uses the Thouet Software
private Authenticode hierarchy documented above.

This identity is a deployment choice, not a requirement that every downstream
build of the source code use the same private PKI.

A future generic or redistributed build workflow should support a
bring-your-own-PKI model in which an organization can provide:

- its own Authenticode Root CA or other trusted certificate hierarchy;
- its own Code Signing certificate and private key;
- its own public trust bootstrap mechanism where a private Root CA is used;
- its own secure key-storage and renewal procedures;
- an appropriate timestamp service.

Private Thouet Software signing keys must never be distributed as part of such
a workflow.

The existing PKI helper provides a reference implementation for creating and
renewing a private two-level Authenticode hierarchy. Generalizing that helper
for arbitrary downstream identities is a separate modernization task and must
not weaken the protection of the current production signing material.

A downstream organization using a publicly trusted Code Signing certificate may
not require the private Root CA bootstrap mechanism described in this document.

Likewise, organizations with an existing managed enterprise PKI may choose to
deploy Authenticode trust through their own administrative infrastructure.

These alternatives do not change the fundamental separation between:

    Windows Authenticode signing
    WAPT package signing
    HTTPS server authentication

Each trust mechanism must continue to be configured and managed independently.
