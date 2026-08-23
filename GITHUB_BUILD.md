# Build on GitHub without Xcode or Motion

The end-user route is now GitHub-hosted: GitHub supplies an Intel Mac and Xcode,
the workflow installs Apple’s FxPlug SDK for that temporary runner, compiles the
plug-in, and creates a zip containing the plug-in, pre-generated Final Cut effect
template, thumbnails, installer, uninstaller, and notices. Nothing is installed
on the user’s Mac except the finished effect.

Final Cut Pro itself is not available on GitHub runners, so a successful build
proves compilation and packaging, not that the effect loads or renders correctly
in FCP 10.6.10 on Monterey.

## Why one Apple secret is still needed

Apple distributes FxPlug separately from Xcode through authenticated Developer
Downloads. Current GitHub Intel images include Xcode and the Metal compiler but
not `FxPlug.sdk`, `FxPlug.framework`, or `PluginManager.framework`. The repository
must therefore receive a short-lived `ADCDownloadAuth` cookie so its private
Actions job can download the official disk image directly from Apple.

The workflow never asks for an Apple ID password, never prints the cookie, never
uploads the SDK, and is guarded so only the repository owner can run it. Treat
the cookie like a password while it is valid.

## One-time browser setup

1. In a browser, sign in to [Apple Developer Downloads](https://developer.apple.com/download/all/?q=FxPlug)
   with an Apple ID that can access the FxPlug download page.
2. Open the browser’s developer tools on that signed-in page:
   - Chrome/Edge: **Application > Storage > Cookies > developer.apple.com**.
   - Safari: enable the Develop menu, then choose **Show Web Inspector >
     Storage > Cookies**.
3. Find the cookie named `ADCDownloadAuth` and copy **only its value**. Do not
   paste the value into this repository, an issue, a workflow input, or chat.
4. Open the repository’s **Settings > Secrets and variables > Actions**, choose
   **New repository secret**, name it exactly `ADC_DOWNLOAD_AUTH`, paste the
   value, and save it.
5. Run **Actions > Hosted Intel release build > Run workflow**. Keep the default
   FxPlug SDK version `4.1` and Xcode path on the first attempt.
6. After the successful run, delete `ADC_DOWNLOAD_AUTH` from repository secrets.
   Add a fresh value later if another build is needed after the cookie expires.

The optional SHA-256 workflow input may be filled when an authoritative checksum
for the exact Apple disk image is available. Even without it, the workflow uses
HTTPS, verifies the DMG structure, and requires Apple’s signed installer package
before installation.

## Download and install the result

1. Open the successful workflow run and download the artifact named
   `FCP-Plasma-Grader-x86_64-<commit>`.
2. Unzip the downloaded artifact, then unzip
   `FCP-Plasma-Grader-x86_64.zip` inside it.
3. Open `README-FIRST.txt` and double-click
   `Install FCP Plasma Grader.command`.
4. Test the effect in Final Cut Pro using [TESTING.md](TESTING.md).

The zip is ad-hoc signed, not Developer ID notarized. The installer clears the
download quarantine attribute only from the two exact validated payloads it
installs. A later public release should use a Developer ID Application identity
and Apple notarization if frictionless Gatekeeper distribution is required.

## What the hosted probe established

The public `Hosted macOS build probe` passed on GitHub’s `macos-15-intel` image.
It observed Intel `x86_64`, macOS 15.7.7, Xcode 16.4, a Metal compiler, and no
preinstalled FxPlug SDK/frameworks. It also verified that Xcode can parse and
list this project after the build-setting syntax correction. That is useful
environment evidence, but it is not an FxPlug compilation.

Xcode 16.4 is newer than the canonical Xcode 14.2 toolchain for Monterey. If the
hosted build exposes Swift importer differences, fix those against the requested
FxPlug 4.1 headers without raising the deployment target. If Apple no longer
serves the 4.1 disk image at its historical official URL, stop and investigate;
do not silently substitute a newer SDK and call it Monterey-compatible.

## Other workflows

- `Structural checks` runs on Ubuntu for every push and pull request. It checks
  project references/settings, plists, stable IDs, Swift/Metal uniform parity,
  effect-template structure, installer payloads, stage order, and independent
  colour-math references. It does not compile Swift or Metal.
- `Canonical Intel Monterey build` remains available for a trusted self-hosted
  Mac labeled `cst-grade`. It enforces macOS 12, Xcode 14.2, Intel hardware, and
  the locally installed FxPlug 4.1 SDK. It is the exact-toolchain fallback, not
  a requirement for an end user.
- `Hosted macOS build probe` is diagnostic only and produces no release.

GitHub’s standard hosted runners are ephemeral. The workflow’s repository-owner
guard and manual trigger must remain in place while an Apple download secret is
configured.
