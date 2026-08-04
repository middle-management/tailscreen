# winget manifest templates

Templates for submitting Tailscreen to [microsoft/winget-pkgs] under the
package id **`Tailscreen.Tailscreen`** (manifest schema **1.6**, installer type
**msix**, x64 + arm64). These are *templates*, not submittable manifests — the
`@…@` tokens below must be substituted per release, and until they are, the
files intentionally fail winget's schema validation (`InstallerSha256` expects
64 hex chars, not a token).

| Token           | Replace with                                                        |
|-----------------|---------------------------------------------------------------------|
| `@VERSION@`     | The release version, e.g. `1.0.0` (the tag without the `v` prefix)  |
| `@URL_X64@`     | Release-asset URL of `Tailscreen-<version>-windows-x64.msix`        |
| `@URL_ARM64@`   | Release-asset URL of `Tailscreen-<version>-windows-arm64.msix`      |
| `@SHA256_X64@`  | SHA-256 of the x64 MSIX (see `checksums-windows-x64.txt`)           |
| `@SHA256_ARM64@`| SHA-256 of the arm64 MSIX (see `checksums-windows-arm64.txt`)       |

## What a submission requires

1. **A published GitHub Release carrying both MSIX assets.** The
   `Release (Windows)` workflow (`.github/workflows/release-windows.yml`)
   uploads `Tailscreen-<version>-windows-{x64,arm64}.msix` plus per-arch
   checksum files on every published release — those are the `InstallerUrl` /
   `InstallerSha256` inputs.

2. **A signature winget accepts.** For `InstallerType: msix`, winget validates
   the package signature: the MSIX must be signed with a certificate chaining
   to a root trusted on end-user machines. **A self-signed MSIX — which is
   what the release workflow currently produces — will be rejected** at
   winget-pkgs validation. Before the first submission, the workflow's signing
   step must be replaced with a real code-signing service (SignPath's free
   OSS tier, or an equivalent cert on FIPS 140-2 hardware — see
   `plans/viewer-windows-plan.md` W8).

3. **The `wingetcreate` / PR flow.** First submission:

   ```
   wingetcreate new <URL_X64> <URL_ARM64>
   ```

   answering the prompts from these templates (or copy the token-substituted
   files into `manifests/t/Tailscreen/Tailscreen/<version>/` in a winget-pkgs
   fork and open the PR by hand). Subsequent releases are one command:

   ```
   wingetcreate update Tailscreen.Tailscreen \
     --version <version> \
     --urls <URL_X64> <URL_ARM64> \
     --submit
   ```

   `wingetcreate` downloads the MSIXes, computes the hashes, and fills in the
   MSIX-derived fields itself. Validate locally with
   `winget validate --manifest <dir>` before submitting.

## Identity coupling — fields that must agree with the MSIX

winget cross-checks the manifest against the package it downloads, so these
are not free-form:

- **`PackageIdentifier`** (`Tailscreen.Tailscreen`) matches the MSIX
  `<Identity Name="Tailscreen.Tailscreen">` in
  `Apps/windows/packaging/AppxManifest.xml`. Keeping them the same string is
  deliberate; renaming either means renaming both (and a new winget package
  id is a new package).
- **`PackageFamilyName`** (installer manifest, currently commented out) is
  `<Identity Name>_<hash>` where the hash is derived from the signing
  certificate's Subject. It cannot be known until the production certificate
  exists — `wingetcreate` computes it from the uploaded MSIX; fill it in on
  first real submission and it stays stable as long as the cert Subject does.
- **`Publisher`** (locale manifest) is the display name and should match the
  MSIX's `PublisherDisplayName` ("Tailscreen"). The MSIX `Identity Publisher`
  (the certificate Subject, templated as `@PUBLISHER@` in AppxManifest.xml and
  stamped by `scripts/windows/make-msix.ps1` from the actual signing cert)
  must be the production cert's Subject — a mismatch fails at install, which
  is why make-msix.ps1 derives it rather than hardcoding it.

[microsoft/winget-pkgs]: https://github.com/microsoft/winget-pkgs
