# GitHub build setup

GitHub is useful here for public source control, review, structural checks, and
repeatable artifacts. It cannot replace the target Mac for Final Cut Pro testing.

## Why the canonical build is self-hosted

The required combination is Xcode 14.2, the separately installed FxPlug 4.1
sparse SDK, Intel `x86_64`, and macOS Monterey. GitHub's current standard Intel
hosted runners use newer macOS images and do not provide this exact toolchain.
The repository therefore has two deliberately separate workflows:

- `Structural checks` runs automatically on GitHub's Ubuntu runner. It validates
  plists, Xcode references/settings, stable IDs, Swift/Metal uniform parity,
  single-kernel stage order, and independent colour-math references. It does not
  claim to compile the plugin.
- `Canonical Intel Monterey build` runs only when manually dispatched and only
  by the repository owner on a self-hosted runner labeled `cst-grade`. It
  refuses to build unless it sees Intel hardware, macOS 12, Xcode 14.2, and the
  FxPlug SDK/frameworks. Public pull requests cannot invoke this job.

## One-time target-Mac setup

1. Install Xcode 14.2 and the FxPlug 4.1 SDK on the Monterey Intel Mac as
   described in `README.md`.
2. In the GitHub repository, open **Settings > Actions > Runners > New
   self-hosted runner**, choose macOS/x64, and follow GitHub's generated commands
   on the Mac. Those commands contain a short-lived registration token; never
   commit it.
3. During `config.sh`, add the custom label `cst-grade`. The runner's resulting
   labels must include `self-hosted`, `macOS`, `X64`, and `cst-grade`.
4. Prefer a dedicated, non-admin macOS account. This repository is public, so
   do not add `pull_request`, `pull_request_target`, or automatic `push` triggers
   to the self-hosted workflow, and do not remove its repository-owner guard.
   Allow only trusted collaborators to edit workflows and stop the runner when
   builds are not needed. A self-hosted runner executes repository workflow
   code on that Mac.

GitHub documents self-hosted macOS 11 or later and x64 as supported, so Monterey
fits the runner requirements. The exact FxPlug/Xcode environment remains yours
to install because it is not part of a GitHub image.

## Run and download a build

1. Start the self-hosted runner on the Mac.
2. Open **Actions > Canonical Intel Monterey build > Run workflow**.
3. Leave the default Xcode path or enter the actual absolute Xcode 14.2 app path,
   such as `/Applications/Xcode_14.2.app`.
4. When the job succeeds, download `CSTGrade-x86_64-<commit>` from the run's
   **Artifacts** section. It contains `CSTGrade.fxplug.zip` and
   `SHA256SUMS.txt`.
5. Verify the checksum, unzip the bundle, then follow `README.md` and
   `TESTING.md`. The CI product is intentionally unsigned; sign it with the
   appropriate development or distribution identity before relying on strict
   code-signing validation.

The build workflow is manual so a commit cannot leave an unavailable home Mac
job queued for 24 hours. Final Cut Pro registration, Motion template creation,
visual output, exports, performance, and security-scoped bookmark behavior still
require the manual acceptance plan on the target Mac.
