# Build on GitHub without Xcode, Motion, or an Apple cookie

The end-user route is GitHub-hosted: GitHub supplies an Intel Mac and Xcode,
compiles the plug-in, and creates a zip containing the plug-in, pre-generated
Final Cut effect template, thumbnails, installer, uninstaller, and notices.
The user never installs Xcode, Motion, or the FxPlug SDK.

Final Cut Pro is not available on GitHub runners. A successful build therefore
proves compilation and packaging, not that the effect loads or renders correctly
in Final Cut Pro 10.6.5 on Monterey.

## Private SDK input

Apple's visible Developer Downloads catalog currently provides FxPlug SDK
4.3.4 rather than the exact-era 4.1 SDK. The owner supplied the official 4.3.4
disk image directly, with this SHA-256:

```text
47f43137cf7ddff275b22c9f41a0545258ca574f77f9fbce9b40e8055b1c565b
```

For the v1.0 build, the disk image was staged only in a private build-assets
repository. The public workflow received a temporary read-only deploy key scoped
to that repository and could not write to either repository. The workflow
verified the checksum, DMG, Apple installer signature, installed framework
signatures, and SDK layout before compiling. After the final artifact was
downloaded and independently verified, the deploy-key secret, deploy key, and
private SDK repository were removed. A future owner build must deliberately
recreate that private staging and secret.

The SDK and deploy key must never be committed to this public repository.

## Monterey compatibility bridge

Inspection of FxPlug SDK 4.3.4 established that both its FxPlug and
PluginManager runtime binaries have an `LC_BUILD_VERSION` minimum of macOS 13.0.
They cannot run on the target Monterey Mac and are never included in the release.

The hosted workflow uses 4.3.4 as follows:

1. Install and signature-check the official SDK on the temporary macOS runner.
2. Confirm the supplied runtime frameworks still declare macOS 13.0.
3. Change only the ephemeral sparse SDK's text-based `.tbd` link-stub deployment
   metadata to 11.0.
4. Compile an Intel-only plug-in with a macOS 11.0 deployment target.
5. Assert that neither Ventura-only runtime framework is embedded.
6. Package the plug-in with an installer that verifies the expected Apple Mac
   App Store identities of the FCP 10.6.5 executable and its matching FxPlug
   and PluginManager frameworks, then copies those frameworks into the staged
   plug-in before ad-hoc signing it. The check is intentionally scoped to code
   the installer consumes rather than unrelated nested FCP resources.

Final Cut Pro itself is never modified. This bridge avoids redistributing an
incompatible runtime and keeps the plug-in runtime in the same generation as
the host. It is still an explicit compatibility experiment: only installation,
registration, and render tests on the target FCP 10.6.5 Mac can prove it works.

## Verified hosted result

The first full release build succeeded in
[GitHub Actions run 32659341596](https://github.com/dolphinforward/fcp-plasma-grader/actions/runs/32659341596)
at source commit `fa399fcf6672f3bcdf3c3eff1f53342860b56aec`. It compiled Swift,
Objective-C, and Metal, produced only x86_64 Mach-O executables with a macOS
11.0 minimum, confirmed the two expected runtime-framework load commands,
confirmed neither SDK runtime framework was embedded, validated the ad-hoc
bundle signature, and uploaded a checksum-manifested installer archive. The
downloaded archive then passed its SHA-256 and ZIP integrity checks independently.

## Run and download

1. Run **Actions > Hosted Intel release build > Run workflow** as the repository
   owner.
2. Download the artifact named
   `FCP-Plasma-Grader-x86_64-<commit>` from the successful run.
3. Unzip the artifact, then unzip `FCP-Plasma-Grader-x86_64.zip`.
4. Read `README-FIRST.txt` and double-click
   `Install FCP Plasma Grader.command` on the FCP 10.6.5 Mac.
5. Complete the checks in [TESTING.md](TESTING.md).

The release is ad-hoc signed, not Developer ID notarized. The installer clears
download quarantine only from the two exact validated payloads it installs.

## Other workflows

- `Structural checks` validates project references/settings, plists, stable IDs,
  Swift/Metal uniform parity, template structure, installer safeguards, stage
  order, and independent colour-math references. It is not a compilation.
- `Canonical Intel Monterey build` remains the exact-toolchain fallback for a
  trusted self-hosted Intel Mac with macOS 12, Xcode 14.2, and FxPlug SDK 4.1.
- `Hosted macOS build probe` records the GitHub runner environment and does not
  produce a release.

All workflows that can access private build material are manually dispatched
and restricted to the repository owner.
