# FCP Plasma Grader — CST Grade FxPlug 4 colour grading effect

This repository is published as **FCP Plasma Grader** and contains a from-scratch
FxPlug 4 effect named **CST Grade**. The installed bundle, registration name,
UUID, and parameter IDs retain the original CST Grade compatibility identity;
the public repository name does not invalidate saved Final Cut Pro projects.
The shell is Swift, the pixel work is one Metal compute kernel, and the build is
locked to the requested Intel Monterey target:

- macOS deployment target: 11.0
- architecture: `x86_64` only
- intended host: Final Cut Pro 10.6.10 / macOS 12 Monterey
- intended IDE: Xcode 14.2
- no FxPlug 3, OpenGL, OpenCL, or third-party dependency

The Linux authoring environment cannot run Xcode, the Metal compiler, macOS, or
Final Cut Pro. The project has therefore not been compiled or tested here. The
first build and all host behaviour remain target-Mac checks; see [TESTING.md](TESTING.md).

The repository also includes automatic Linux-side structural checks and a
manual self-hosted Monterey build workflow. See [GITHUB_BUILD.md](GITHUB_BUILD.md)
for the exact GitHub setup and its security/toolchain boundaries.

## Important packaging fact: FxPlug registration versus the FCP browser

FxPlug 4 is an out-of-process application wrapper containing a PlugInKit XPC
service. The outer product in this project is deliberately named
`CSTGrade.fxplug`, as required for the installation location in this brief. It
contains `Contents/PlugIns/CSTGradeXPC.pluginkit`.

Final Cut Pro does not create a user-facing Effects-browser item or category
from the raw FxPlug registration alone. Apple’s workflow is to make a Final Cut
Effect template in Motion that contains the FxPlug filter and publishes its
parameters. This is a host document/template step, not source code that can be
represented reliably as a hand-written plist. Apple documents that an FxPlug
must be placed in a Motion Final Cut Effect to be used in Final Cut Pro:
[Creating FxPlug Plug-ins for Final Cut Pro](https://developer.apple.com/library/archive/documentation/AppleApplications/Conceptual/FXPlug_overview/FxPlugsFCPx/FxPlugsFCPx.html).

After the first successful install, perform the one-time Motion step below:

1. Open Motion and create a **Final Cut Effect** project.
2. Add the registered **CST Grade** FxPlug filter. In Motion’s Library/Filters
   view it should be listed under the `CST Grade` registration group.
3. Publish the parameters you want visible in Final Cut Pro. The source plugin
   declares all controls; publishing is the template author’s choice.
4. Save the template with category **CST Grade** and name **CST Grade** under
   the user Motion Templates Effects folder. The expected result is similar to:

   `~/Movies/Motion Templates/Effects/CST Grade/CST Grade.moef`

5. Restart Final Cut Pro and look under the custom **CST Grade** category.

If Motion cannot see the raw plugin, do not continue to the FCP template step:
fix registration/install/signing first and use the checks in [TESTING.md](TESTING.md).

## Architecture and render lifecycle

The outer application target is only a bundle wrapper. The XPC service calls
`FxPrincipal.startServicePrincipal()`. `CSTGradePlugIn` is an `NSObject` that
conforms to `FxTileableEffect`, which is the FxPlug 4 protocol for tiled,
out-of-process effects. This is the current Apple model; FxPlug 3’s `FxFilter`
and `FxImage` rendering APIs are intentionally absent. See Apple’s
[FxPlug overview](https://developer.apple.com/documentation/professional-video-applications/fxplug)
and [manual FxPlug 4 build guide](https://developer.apple.com/documentation/professional-video-applications/building-an-fxplug-plug-in-manually).

The per-frame sequence is:

1. `addParameters()` declares the inspector controls using
   `FxParameterCreationAPI_v5`.
2. `properties()` requests gamma-video processing so the plugin can own the
   selected input transfer decode.
3. `pluginState()` retrieves all controls using
   `FxParameterRetrievalAPI_v6`, derives matrices on the CPU, and packages one
   `CSTUniforms` value as `NSData`. Parameter IDs are in
   `CSTGradeXPC/CSTParameterIDs.swift`; do not renumber them.
4. `scheduleInputs()` requests the current effect clip frame, including leading
   filters.
5. `sourceTileRect()` and `destinationImageRect()` describe a same-size,
   one-pixel-in/one-pixel-out colour filter.
6. `renderDestinationImage()` obtains IOSurface-backed Metal textures and
   dispatches exactly one `cstGradeKernel` compute pass. No parameter API is
   touched from this callback.

Apple’s [FxTileableEffect documentation](https://developer.apple.com/documentation/professional-video-applications/fxtileableeffect)
and [FxImageTile documentation](https://developer.apple.com/documentation/professional-video-applications/fximagetile)
describe the tile and Metal-texture contracts.

## Fixed colour pipeline

The shader runs this order for every pixel:

`input decode → source-primary matrix → linear grade → tone map → Rec.709 output encode → creative Rec.709 LUT → project-boundary conversion → final clamp`

Each processing stage has an independent toggle. The LUT stage has an enable
toggle and a 0–100% amount control; **Global Bypass** returns the original
source pixel, including its alpha and extended-range RGB, before any stage.
Disabled stages are true A/B bypasses.
The normal defaults enable every stage, choose Rec.709 input, Rec.709 source
primaries, Reinhard tone mapping, and the Rec.709 output transfer.

### Input decode

The popup supports:

- Rec.709 inverse OETF
- Sony sLog3 inverse, using Sony’s normalized full-range/10-bit formula
- Panasonic V-Log inverse
- ARRI LogC3 inverse using the EI 800 parameter set
- a plain 2.2 power law
- Samsung Log inverse using Samsung’s published piecewise curve

The implementation assumes that the texture contains full-range normalized
code values (`0.0` to `1.0` nominally). It does not silently reinterpret legal
video range as full range. Out-of-range values are passed through the analytic
branches and remain unclamped, except that Samsung’s specified inverse maps an
encoded value below zero to its linear floor `-0.05`.

For untouched Samsung Log footage, choose **Samsung Log** for Input Transfer
and **Rec.2020** for Source Primaries. Samsung specifies BT.2020/D65 source
colour for the profile. The two menus remain independent so selecting a
transfer never silently changes an existing project’s gamut setting.

Turning **Input Decode Enabled** off means “the incoming RGB is already scene
linear”; it does not apply a hidden transfer. Turning **Gamut Transform
Enabled** off leaves the decoded/linear coordinates untouched, so that mode is
also an intentional diagnostic bypass rather than a claim that arbitrary source
coordinates are Rec.2020.

The exact source documents and constants are cited beside the shader formulas:
[Sony S-Log3 technical summary](https://download.pro.sony/FNGP/protein/1237494271390/1237494271406.pdf),
[Panasonic V-Log/V-Gamut](https://pro-av.panasonic.net/jp/cinema_camera_varicam_eva/support/pdf/VARICAM_V-Log_V-Gamut.pdf),
[ARRI LogC3 curve/data](https://www.arri.com/resource/blob/31918/66f56e6abb6e5b6553929edf9aa7483e/2017-03-alexa-logc-curve-in-vfx-data.pdf),
and [Samsung Log profiles and reference LUTs](https://developer.samsung.com/mobile/samsung-log-video.html).

### Gamut transform and working space

The fixed internal working space is **linear Rec.2020, D65**. The source popup
supports S-Gamut3.cine, V-Gamut, ARRI Wide Gamut (AWG), Rec.709, and Rec.2020.

`CSTColorScience.swift` derives each source-to-working matrix as:

1. Convert each `(x,y)` primary to an unscaled XYZ column
   `(x/y, 1, (1-x-y)/y)`.
2. Solve the 3x3 primary matrix against the D65 white XYZ.
3. Scale the columns by that solution.
4. Multiply `RGB_source → XYZ` by `XYZ → RGB_Rec2020`.

The same derivation creates the Rec.2020→Rec.709 and Rec.709→Rec.2020
matrices. The primaries are documented in the source comments with links to
[Apple’s Rec.709 values](https://developer.apple.com/documentation/quicktime-file-format/color_parameter_atom),
[ITU-R BT.2020](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2020-0-201208-S!!PDF-E.pdf),
Sony, Panasonic, and ARRI.

### Linear grade

The grade stage operates after decode and the source→Rec.2020 matrix:

- exposure: multiplication by `2^stops`
- white balance: documented neutral-preserving red/green/blue gain model
- offset: a whole-image RGB offset, neutral at `0.5` per channel
- contrast: `(value - pivot) * contrast + pivot`, with an adjustable pivot
- shadows/highlights: smooth overlapping luma masks with no hard threshold
- saturation: Rec.2020 luma coefficients `0.2627, 0.6780, 0.0593`
- color boost/vibrance: preferential chroma adjustment for less-saturated pixels
- hue rotation: luma-preserving rotation around the neutral axis
- lift: numeric RGB offset around UI neutral `0.5`
- gamma: signed per-channel power around neutral exponent `1.0`
- gain: per-channel multiplication around UI neutral `1.0`

Lift/gamma/gain/offset are numeric triples, not colour swatches. They use
`kFxParameterFlag_DONT_REMAP_COLORS`, so FCP does not convert their values as
display colours. Negative and extended values remain possible in the shader.

### DaVinci Resolve primary-tool coverage

Blackmagic’s Color page identifies Lift/Gamma/Gain/Offset plus contrast,
pivot, saturation, hue, temperature, tint, color boost, shadows, and highlights
as its everyday primary grading controls. FCP Plasma Grader includes that core
set in one linear-light stage, while keeping its own documented math rather
than claiming bit-for-bit Resolve behavior. See Blackmagic’s
[official Color page](https://www.blackmagicdesign.com/products/davinciresolve/color).

The host and the effect divide the rest of the workflow deliberately:

| Grading need | Where it lives |
| --- | --- |
| Transfer decode, gamut conversion, primary balance, tone rolloff, LUT looks | FCP Plasma Grader |
| Lift/Gamma/Gain/Offset and primary adjustment controls | FCP Plasma Grader |
| Shape/color masks, object tracking, parameter keyframes, and video scopes | Final Cut Pro |
| Reusable grades | Final Cut Pro effect presets and the plugin’s LUT collections/favorites |
| Serial corrections | Multiple effect instances in Final Cut Pro’s effect stack |

Resolve’s custom curves, HSL qualifier UI, HDR zone wheels, Color Warper, node
graph, gallery/shot matching, camera-RAW controls, AI tools, and spatial noise
reduction are application-level systems, not silently approximated by this one
FxPlug. Midtone Detail is also spatial edge processing; use FCP’s native detail
or sharpening effect rather than a mislabeled per-pixel substitute. This keeps
the plugin intuitive and preserves the one-kernel, low-memory design for the
target 2015 Intel Mac.

### Tone map and output

Tone-map choices are none, Reinhard, and a Hable/Uncharted-style filmic curve.
`Highlight Knee` is the scene-linear scale used by those curves; it is not a
hard clip. The output stage first maps linear Rec.2020 to linear Rec.709, then
uses either the BT.709 OETF or a pure display-referred power of 2.4. Only after
that final output encoding does the shader clamp to `[0,1]`.

When output encoding is disabled, the shader intentionally returns unclamped
linear Rec.2020 values. That mode is for A/B/debugging and is not a normal
display output.

### Creative LUT library

The LUT stage is deliberately a **creative display LUT**, not an input/technical
camera LUT. It receives the shader’s encoded Rec.709 display values after tone
mapping and output transfer. In a Rec.2020 project, that LUT result is then
converted to the project’s gamma-video boundary. The LUT is skipped when Output
Encode is disabled because there is no display-referred Rec.709 value to which
it can correctly apply.

The custom **LUT Library** inspector control is compact in the inspector. Its
button first opens the outer `CSTGrade.fxplug` wrapper as a standard-AppKit LUT
organizer and bridges an **Apply** selection back to the live FxPlug custom
parameter through a request-tokened distributed notification. If the target
host refuses that wrapper/URL route, the same button falls back to opening the
ordinary AppKit browser from the XPC service:

- Click a card to preview it; **Apply** commits the choice and **Cancel** leaves
  the parameter unchanged.
- The browser includes a “No LUT” clean-bypass card, search, sort by name or
  recently added, favorites, a recently-used filter, user-created collections,
  previous/next selection, individual `.cube` import, and recursive folder import.
- Cards and the larger preview show a deterministic reference chart. FxPlug’s
  public custom-parameter API does not provide a safe documented “current FCP
  frame for browser thumbnail” callback, so these are not live clip previews.
- The parser accepts standard UTF-8 3D `.cube` files with `LUT_3D_SIZE` from 2
  through 64 and the default `DOMAIN_MIN 0 0 0` / `DOMAIN_MAX 1 1 1`. It rejects
  1D/shaper/matrix LUTs, non-default domains, malformed data, and wrong sample
  counts with no fallback to another LUT.
- The amount is a true blend: 100% is the LUT result, 0% is the original
  pre-LUT encoded value. The shader clamps only the LUT lookup coordinate; it
  blends the original unclamped value and performs the only output clamp at the
  final host-boundary encode.

The selected LUT’s content hash and security-scoped bookmark are saved in the
custom parameter; library metadata is stored at
`~/Library/Application Support/CSTGrade/lut-library.json`. User files are never
moved. CPU parsing is done while building plugin state, with a four-entry LRU
cache; GPU textures are created lazily once per LUT/device and the browser shows
at most 100 cards at a time. This bounds memory and keeps folder import and
thumbnail parsing away from the render callback on the low-power 2015 Intel GPU.
Queued thumbnail work is canceled when the search/filter/sort view changes;
already-running parses are generation-checked before their images are installed.

The LUT texture and lookup are part of the same `cstGradeKernel` dispatch. There
is no second render pass.

No LUT files are bundled with this project. The library is local and offline: it
does not require an account, network connection, cloud service, subscription, or
proprietary assets. The editor-facing library button includes tooltips, and the
FxPlug parameters are placed in host-native groups named `1. Input Decode`,
`2. Gamut Transform`, `3. Linear Grade`, `4. Tone Map`, `5. Output Encode`,
`6. Creative LUT`, and `Utilities`.
The FxPlug standard-parameter creation API has no per-slider tooltip argument
in this SDK generation, so standard controls use concise names, explicit
ranges, and documented defaults; the custom LUT controls provide AppKit
tooltips.

The wrapper organizer is also launchable directly by opening the installed
`CSTGrade.fxplug` bundle. Direct launching is a fallback workflow, not a second
rendering implementation: it uses the same metadata/bookmark store and the same
Apply/Cancel UI. It does not bypass FxPlug parameter actions.

## FCP colour-management boundary

This is the most important host assumption in the project.

`properties()` sets `kFxPropertyKey_DesiredProcessingColorInfo` to
`kFxImageColorInfo_RGB_GAMMA_VIDEO`, because a plugin that receives linear
pixels cannot also decode a user-selected sLog3/V-Log/LogC3/Samsung Log
transfer function.
Apple documents that the desired processing type combined with the project
gamut determines the working colour space, and that the host passes input in
that working space and expects output in the same working space. See
[Managing color space and gamut in plug-ins](https://developer.apple.com/documentation/professional-video-applications/managing-color-space-and-gamut-in-plug-ins).

Therefore, at the FxPlug boundary:

- In a Rec.709 project/library, FCP is expected to hand the plugin gamma-video
  Rec.709 working-gamut RGB and expects gamma-video Rec.709 RGB back. The
  normal Rec.709 source setting is appropriate only if those pixels still
  represent Rec.709-encoded source data.
- In a wide-gamut project/library, FCP is expected to hand gamma-video Rec.2020
  working-gamut RGB and expects gamma-video Rec.2020 RGB back. The plugin still
  converts its decoded source values into its fixed internal linear Rec.2020
  space. After the user-visible Rec.709 output stage, the single kernel converts
  that Rec.709 display result into the project gamut and gamma-video boundary so
  FCP receives the gamut it says it expects.

The creative LUT therefore stays in its documented encoded Rec.709 domain in
both library types; the Rec.2020 boundary conversion happens after the LUT.
This is an explicit product choice, not a claim that FCP’s viewer and export
color-management settings are identical.

There is an unavoidable semantic limitation: FCP may already have interpreted
camera metadata and transformed a clip into its project working space before the
FxPlug sees it. A third-party effect cannot recover the original log transfer or
camera primaries from pixels that have already been transformed. The source
transfer/primaries controls are consequently an explicit **input contract**:
use them only when the incoming pixels still contain that source encoding, and
disable any upstream camera LUT/transform that would make the contract false.
The wide-gamut and metadata cases are mandatory manual tests, not assumptions
to skip.

This plugin does not query or rewrite FCP’s clip metadata. It also assumes
straight RGB alpha. If the host supplies premultiplied RGB or an sRGB-encoded
Metal texture format, the target-Mac tests must confirm whether an
unpremultiply/texture-format adaptation is required.

## Prerequisites

On the target Mac, install:

1. macOS 12 Monterey on the Intel 2015 MacBook Pro.
2. Xcode 14.2. Do not select Xcode 14.3 or newer for this target.
3. Final Cut Pro 10.6.10 for host testing.
4. The FxPlug 4.1 SDK from Apple Developer Downloads. Search Apple’s download
   portal for **FxPlug**; an Apple Developer account may be required. The
   FxPlug 4.1 installer must provide:

   `/Library/Developer/SDKs/FxPlug.sdk`

   The sparse SDK change and the required Additional SDK path are documented by
   Apple in [Migrating FxPlug 3 plug-ins to FxPlug 4](https://developer.apple.com/documentation/professional-video-applications/migrating-fxplug-3-plug-ins-to-fxplug-4).

Before opening the project, verify the SDK and framework locations in Finder or
Terminal. This project intentionally uses the required sparse-SDK settings:

```text
ADDITIONAL_SDKS = /Library/Developer/SDKs/FxPlug.sdk
FRAMEWORK_SEARCH_PATHS = /Library/Frameworks $(inherited)
```

The module maps use the FxPlug 4.1 sparse-SDK header paths under
`/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks`. The Xcode framework
references and copy phase use `/Library/Frameworks`, matching the target
configuration requirement. If the SDK installer on the target Mac places the
runtime framework reference somewhere else, resolve that path in Xcode before
building and keep the required `/Library/Frameworks $(inherited)` search-path
entry present.

The source deliberately uses only APIs available on the macOS 11 deployment
floor. It does not call macOS 12/13/14-only APIs, use OpenGL/OpenCL, or emit an
Apple Silicon slice. The target Mac still has to confirm the exact FxPlug 4.1
headers and FCP behavior.

## Build on the Mac

Do these steps on the Monterey Mac; they are intentionally not automated here.

1. Open `CSTGrade.xcodeproj` in Xcode 14.2.
2. Select the `CSTGrade` wrapper target/scheme, configuration **Release**, and
   destination **My Mac**.
3. In Build Settings, confirm:
   - Architectures is exactly `x86_64`.
   - `EXCLUDED_ARCHS[sdk=macosx*]` contains `arm64`.
   - Deployment Target is `11.0`.
   - `ADDITIONAL_SDKS` is `/Library/Developer/SDKs/FxPlug.sdk`.
   - Framework Search Paths contains `/Library/Frameworks` followed by
     `$(inherited)`.
   - The XPC target’s Wrapper Extension is `pluginkit`.
   - The wrapper target’s Wrapper Extension is `fxplug`.
4. Choose **Product > Build**. Do not run the wrapper as an ordinary GUI app;
   FxPrincipal is started by the embedded XPC service when the host connects.
5. In Xcode’s Products/Build Products folder, locate:

   `CSTGrade.fxplug`

   Inspecting its package should show:

   `CSTGrade.fxplug/Contents/PlugIns/CSTGradeXPC.pluginkit`

   and the XPC bundle’s embedded `FxPlug.framework` and `PluginManager.framework`.

If Xcode does not show a shared scheme, choose **Product > Scheme > Manage
Schemes**, add a scheme for the `CSTGrade` application target, and select the
Release configuration. No `xcodebuild` or `metal` script is supplied or needed;
Xcode compiles the `.metal` source as part of the XPC target.

## Install and register

Quit Final Cut Pro and Motion before replacing an installed copy. Use the exact
user plug-in directory requested for this project:

```sh
mkdir -p "$HOME/Library/Plug-Ins/FxPlug"
cp -R "/path/to/Build/Products/Release/CSTGrade.fxplug" \
  "$HOME/Library/Plug-Ins/FxPlug/"
```

If a previous copy exists, remove or move only this exact bundle before copying
the new one. Do not delete the whole `FxPlug` directory; it may contain other
users’ plugins.

Launch the installed wrapper once if PlugInKit does not register it
automatically, then verify registration:

```sh
pluginkit -m -v -p FxPlug | grep CSTGrade
```

Restart Final Cut Pro after every install or replacement. FCP caches plugin
discovery and will not reliably pick up a changed bundle in an already-running
process. Complete the Motion `.moef` step above before expecting a custom FCP
Effects-browser category.

The LUT library metadata is separate from the plug-in bundle, so reinstalling
the effect does not lose imported LUT bookmarks, favorites, or collections. If
a source LUT is moved or deleted, the browser reports it as unavailable and
rendering fails closed to the clean pre-LUT value; it never silently selects a
different file.

## Uninstall

Quit Final Cut Pro and Motion, then remove only the installed CST Grade bundle
and its optional Motion template:

```sh
rm -rf "$HOME/Library/Plug-Ins/FxPlug/CSTGrade.fxplug"
rm -rf "$HOME/Movies/Motion Templates/Effects/CST Grade/CST Grade.moef"
```

Restart the host applications. The first command removes the registered FxPlug
bundle; the second removes the FCP browser template. The LUT metadata file is
not removed by these commands; remove only
`~/Library/Application Support/CSTGrade/lut-library.json` if you also want to
discard the library’s favorites and collections. Neither command is run by this
repository.

## What I am unsure about

These are deliberate, visible risk points rather than hidden API guesses:

1. **Exact installed SDK layout.** The sparse SDK module maps follow the FxPlug
   4.1 example layout, but the physical framework symlink location can depend on
   the SDK installer. Confirm the two absolute framework paths in the target
   SDK and adjust only the file references if needed.
   The XPC plist uses Apple’s documented `_NSApplication` run-loop value; if the
   Xcode 14.2 FxPlug 4.1 example installed on the target uses a different exact
   spelling, copy that SDK example’s value.
2. **Wrapper extension acceptance.** Apple’s current manual-build article shows
   an application product named with `.app`, while this brief explicitly
   requires a built `.fxplug` bundle installed in `~/Library/Plug-Ins/FxPlug/`.
   This project keeps the FxPlug 4 application/XPC internals but sets the outer
   wrapper extension to `fxplug`. If PlugInKit on the target rejects that outer
   extension, the header/Apple template result must take precedence; record the
   observed bundle requirement before changing packaging.
3. **Swift importer spellings.** The source uses the Xcode-era Apple FxPlug
   examples’ `sourceImageIndex: UInt` and `quality: UInt` spellings. If the
   installed FxPlug 4.1 header imports either as `Int` or `FxQuality`, change the
   method declaration to the exact generated protocol signature shown by
   `FxTileableEffect.h`; the `// UNVERIFIED` points in the source identify this
   boundary.
4. **`FxColorGamutAPI_v2` availability in the exact SDK/FCP pairing.** The wide-
   gamut adapter requests v2 and now fails the frame state rather than silently
   writing an unknown project gamut when the API is unavailable. Confirm the
   protocol name and `colorPrimaries()` return type in the installed headers.
5. **FCP’s treatment of recognized camera log media.** Apple documents that FCP
   passes a plugin its already-converted working-space image. It is not possible
   to guarantee from the public API that an arbitrary recognized camera log clip
   reaches this plugin as untouched log code values. The manual metadata test is
   required before relying on the input popups in production.
6. **Wide-gamut boundary transfer.** The shader converts its Rec.709 display
   result back into project Rec.2020 gamma-video for FCP’s documented working
   space. The exact display/result appearance must be checked in a Rec.2020
   library on the target FCP release.
7. **Texture format and alpha convention.** FxImageTile supplies Metal textures,
   but the exact pixel format and premultiplication used by FCP 10.6.10 for each
   render quality are host details. The shader preserves alpha and treats RGB as
   straight numeric components; the tests include format/alpha checks.
8. **LogC3 exposure index.** “LogC3” is not a single curve independent of EI.
   This implementation labels the control `ARRI LogC3 (EI 800)` and uses the
   published EI 800 parameters because the requested UI has no EI control.
9. **Range and metadata normalization.** Camera log formulas are applied to
   normalized full-range values. Legal-range Y'CbCr/video-range input or a host
   camera LUT needs an explicit upstream conversion; it is not inferred.
   Samsung Log’s piecewise inverse and numerical boundary/18%-gray checks are
   included, but the result still needs a target-Mac comparison against
   Samsung’s official Log-to-Linear 1D LUT and known camera footage.
10. **White-balance model.** Temperature/tint are a documented linear gain
    control, not a claim to implement a particular camera vendor’s chromatic
    adaptation transform. Replace it with a specified CAT only if that product
    behaviour is required later, without changing parameter IDs.
11. **Custom parameter bridge on this vintage host.** Apple documents
    `FxCustomParameterViewHost_v2`, `FxCustomParameterInterpolation_v2`, and
    `FxCustomParameterActionAPI_v4`, and the source follows those names. The
    Xcode 14.2 Swift importer, FCP 10.6.10’s viewbridge, and ARC lifetime
    behavior for an AppKit custom view must be confirmed from the installed
    headers and by the Motion test. The source retains views strongly and marks
    the uncertain selector/class-set spellings.
12. **Separate LUT browser window.** The public API documents an embedded
    `NSView`, not a dedicated FCP LUT-browser surface. The primary path now uses
    the outer wrapper application as the organizer, with the custom view reduced
    to a compact button and a documented URL/notification bridge. The XPC-hosted
    AppKit browser remains a fallback for hosts that allow it; its
    `NSOpenPanel`/child-window behavior still requires the target-Mac test.
13. **Custom-value interpolation semantics.** LUT choices are discrete and the
    custom value uses hold/step interpolation. Confirm that the target SDK wants
    `FxCustomParameterInterpolation_v2` on `CSTLUTSelection` (the value object)
    rather than on the effect class; this is the interpretation implied by the
    left-value/right-value API shape.
14. **`.cube` dialect and texture upload.** v1 intentionally rejects 1D/shaper,
    matrix, non-default-domain, and vendor-extension files. Confirm the Xcode
    14.2 Metal importer accepts the macOS 11 3D `rgba32Float` texture upload and
    the `replace(region:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:)`
    signature. The manual LUT tests are required before shipping.
15. **LUT thumbnail source.** The reference chart is intentional; live FCP-frame
    previews are not claimed because no documented safe browser-frame callback
    was found. The visual test checks that this limitation is clearly labeled.
16. **Push-button action timing.** `Reset All Controls` uses the documented
    custom action/setting APIs, but Apple warns that `startAction` can hang when
    called from host callbacks. Confirm the selector callback context in the
    SDK’s FxSimpleColorCorrector sample; if it is host-owned, move reset logic
    to the host-supported parameter-change path.

17. **Parameter subgroup importer.** Current FxPlug documentation exposes
    `startParameterSubGroup(_:parameterID:parameterFlags:)` and
    `endParameterSubGroup()`. Confirm the exact first-argument label in the
    Xcode 14.2 FxPlug 4.1 Swift importer. If it differs, change only the two
    helper calls in `addParameters()`; the controls and their IDs remain stable.

18. **Organizer bridge delivery.** The URL-scheme launch and
    `DistributedNotificationCenter` round trip are standard macOS APIs, but the
    exact PlugInKit/XPC sandbox and application-activation behavior on Monterey
    must be confirmed. If the notification is blocked, use the embedded AppKit
    fallback and record that result; no parameter is changed until the FxPlug
    action/setting API runs.

19. **Security-scoped bookmark boundary.** This project does not request the
    App Sandbox entitlement, so the wrapper organizer and XPC fallback share the
    documented user Application Support metadata store. Imported selections still
    carry security-scoped bookmark data so they are not dependent on a transient
    absolute path. Confirm bookmark resolution and the host’s file-access policy
    on Monterey; if a distribution environment requires App Sandbox, give both
    targets the same signed application-group arrangement rather than enabling
    it for only one target.

None of these points was compiled or exercised on the target machine in this
environment. Treat the first Mac build and [TESTING.md](TESTING.md) as the
acceptance gate.
