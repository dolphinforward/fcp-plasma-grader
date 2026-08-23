# FCP Plasma Grader / CST Grade manual test plan

These tests must be run on the target Intel MacBook Pro with macOS 12 Monterey
and Final Cut Pro 10.6.5. An end user does not need Xcode, Motion, or the FxPlug
SDK. Build-only checks may run on GitHub or on the canonical Xcode 14.2/FxPlug
4.1 development setup. Record the exact OS/FCP/build artifact versions and keep
one known-good test library before changing the plugin.

Before the first launch, confirm that the bundled `.moef` declares
`<displayversion>5.6.3</displayversion>` and contains neither `DRTSupport` nor
`HDR White Level`. Those later template fields are outside the FCP 10.6.5-era
Motion document baseline.

For every visual test, also inspect the Console output and the FCP render
quality being used. A failed registration/API test should be fixed before
interpreting colour results.

## 1. Build configuration and architecture

Action:

1. Build with the hosted workflow or the canonical local Xcode 14.2 setup.
2. Unzip the release artifact.
3. In Terminal, inspect the built executable and bundles:

```sh
file "/path/to/CSTGrade.fxplug/Contents/MacOS/CSTGrade"
lipo -info "/path/to/CSTGrade.fxplug/Contents/MacOS/CSTGrade"
codesign --verify --deep --strict --verbose=2 "/path/to/CSTGrade.fxplug"
```

Correct result:

- the wrapper and XPC executable report `x86_64` only;
- no `arm64` slice is listed;
- the nested service is `Contents/PlugIns/CSTGradeXPC.pluginkit`;
- the deep signature check passes, or the explicitly selected development
  signing identity explains the result.

Failure caught: accidental `$(ARCHS_STANDARD)`, an arm64 slice, wrong wrapper
extension, missing nested XPC service, missing embedded frameworks, or an
unsigned/partially signed nested bundle.

## 2. PlugInKit discovery

Action:

1. Quit Final Cut Pro.
2. Run `Install FCP Plasma Grader.command` from the release. Confirm that it
   reports both the plug-in and effect-template destination without requesting
   Xcode or Motion.
3. Run:

```sh
pluginkit -m -v -p FxPlug | grep CSTGrade
```

Correct result: PlugInKit lists the CST Grade registration, its UUID, version,
and path inside the user FxPlug directory. The XPC service is not reported as
an unrelated generic plugin.

Failure caught: malformed `PlugInKit`/`ProPlug` plist keys, wrong principal
class, wrong bundle nesting, duplicate UUIDs, stale installed copy, signing,
or a wrapper extension that the target PlugInKit rejects.

## 3. FCP instantiation and parameter declaration

Action:

1. Restart Final Cut Pro after registration succeeds.
2. Find **FCP Plasma Grader** in the Effects browser and apply it to a short
   test clip.
3. Open FCP’s inspector and verify every published control exists exactly once:

- Native sections appear in this order: 1. Input Decode, 2. Gamut Transform,
  3. Linear Grade, 4. Tone Map, 5. Output Encode, 6. Creative LUT, Utilities.

- Input Decode Enabled, Input Transfer (in order: Rec.709, sLog3, V-Log,
  ARRI LogC3 EI 800, Gamma 2.2, Samsung Log)
- Gamut Transform Enabled, Source Primaries
- Grade Enabled, Exposure, Temperature, Tint, Contrast, Contrast Pivot,
  Shadows, Highlights, Saturation, Color Boost, Hue Rotation, Lift, Gamma,
  Gain, Offset
- Tone Map Enabled, Tone Map, Highlight Knee
- Output Encode Enabled, Display-Referred 2.4 Gamma
- LUT Library, Creative LUT Enabled, Creative LUT Amount
- Global Bypass, Reset All Controls

Correct result: FCP instantiates the XPC service, displays the controls in
pipeline order with each stage toggle adjacent to its controls, and shows the
intended defaults without an “effect missing” or “cannot load plug-in” alert.
Turning a stage off visibly disables only that stage’s controls; Tone Map
`Highlight Knee`, Display-Referred Gamma, and Creative LUT Amount also disable
when their parent mode does not apply. Re-enabling the mode restores them.

Failure caught: `FxPrincipal` startup, module import, class name, protocol name,
parameter creation/setting API versions, subgroup importer spelling, bad popup
entries, bad colour-parameter flags, or a mismatched
`CSTParameterIDs.swift`/plist class name.

## 4. Motion-free installation and Effects-browser category

Action:

1. On a user account that does not have Motion or Xcode installed, run the
   release installer and restart Final Cut Pro.
2. Search the Effects browser for the **FCP Plasma Grader** category and apply
   the effect to a short test clip.
3. Quit and reopen FCP, then reopen the project and verify the applied effect and
   its settings persist.

Correct result: FCP Plasma Grader appears under the custom category, applies to
a clip, and the published controls are editable in FCP without Motion or Xcode.

Failure caught: missing or incompatible generated `.moef`, wrong template
folder/category, an unserializable custom LUT default, FCP cache not restarted,
or a raw FxPlug registration being mistaken for an Effects-browser template.

## 5. Numerical transfer-function reference check

This is an equation check independent of visual judgement. It also gives the
expected numbers for a GPU frame capture or a future tiny test harness.

Action: on the Mac, run this read-only arithmetic in Terminal:

```sh
awk 'BEGIN {
  v = 420 / 1023
  code = v * 1023
  slog3 = (10 ^ ((code - 420) / 261.5)) * 0.19 - 0.01

  v = 433 / 1023
  vlog = (v < 0.181) ? ((v - 0.125) / 5.6) : (10 ^ ((v - 0.598206) / 0.241514) - 0.00873)

  v = 400 / 1023
  cut = 5.367655 * 0.010591 + 0.092809
  logc3 = (v > cut) ? ((10 ^ ((v - 0.385537) / 0.247190) - 0.052272) / 5.555556) : ((v - 0.092809) / 5.367655)

  samsungTransition = 0.206561909
  samsungAtTransition = 10 ^ ((samsungTransition - 0.720504856) / 0.258984868) - 0.0003645
  samsungGrayCode = 0.258984868 * (log(0.18 + 0.0003645) / log(10)) + 0.720504856
  samsungGray = 10 ^ ((samsungGrayCode - 0.720504856) / 0.258984868) - 0.0003645

  rec709 = ((0.5 + 0.099) / 1.099) ^ (1 / 0.45)
  printf "sLog3 code 420/1023 -> %.12f\n", slog3
  printf "V-Log code 433/1023 -> %.12f\n", vlog
  printf "LogC3 EI800 code 400/1023 -> %.12f\n", logc3
  printf "Samsung Log transition -> %.12f linear\n", samsungAtTransition
  printf "Samsung Log 18%% code %.12f -> %.12f linear\n", samsungGrayCode, samsungGray
  printf "Rec.709 encoded 0.5 -> %.12f linear\n", rec709
}'
```

Expected output, to the shown precision:

- sLog3 `420/1023` → `0.180000000000`
- V-Log `433/1023` → approximately `0.179916274162`
- LogC3 EI 800 `400/1023` → approximately `0.180000018677`
- Samsung Log `0.206561909` → approximately `0.010000000010` linear
- Samsung Log 18% gray code `0.527859237029` → `0.180000000000` linear
- Rec.709 encoded `0.5` → approximately `0.259589400506` linear

For a GPU-level check, use a 1-pixel floating-point source or an Xcode Metal
frame capture and set: input transfer to sLog3, source primaries to Rec.2020,
Input Decode ON, Gamut ON, Grade OFF, Tone Map OFF, Output Encode OFF. A source
RGB value of exactly `420/1023` must produce RGB `0.18` (within about `2e-4`)
because Rec.2020→Rec.2020 is the identity. With a linear input of exactly
`0.18`, all grade/tone stages off, and Output Encode ON in a Rec.709 project,
the BT.709 output should be approximately `0.409007728864` before final
quantization. With linear `1.0`, Reinhard and knee `1.0` must produce exactly
`0.5` before output encoding.

Repeat the decode capture with Input Transfer **Samsung Log** and Source
Primaries **Rec.2020**. Encoded RGB `0.527859237029` must produce RGB `0.18`,
and the branch transition `0.206561909` must produce approximately `0.01`.

Failure caught: wrong code normalization, a transfer constant typo, premature
clamping, wrong stage order, accidental matrix application, incorrect tone-map
knee, or a Swift/Metal uniform-layout mismatch. If the GPU capture cannot be
attached to FCP’s XPC process, retain the `awk` result as the independent
formula check and use the remaining host tests.

## 6. Stage A/B bypasses

Action: use a high-contrast chart containing neutral gray, saturated primary
colours, highlights above 1.0, and shadows below 0.0 where the host permits it.
Change one control at a time while saving a before/after FCP project state.

Correct result:

- each stage toggle alone bypasses all of that stage’s controls;
- changing a disabled stage’s controls does not change the frame;
- enabling the stage changes only its documented operation;
- re-enabling restores the same result without restarting FCP.

Failure caught: a toggle bit shifted into the wrong uniform field, controls
read during render instead of `pluginState`, stale state, or a stage executed
out of the required order.

## 7. Matrix and neutral-axis test

Action:

1. Use neutral gray values and set Input Transfer to Gamma 2.2 or disable input
   decode for a known linear test source.
2. Test each source primaries popup with Gamut Transform ON.
3. Keep grade neutral, Tone Map OFF, Output Encode OFF.

Correct result: equal R/G/B input remains equal R/G/B after every D65 source
matrix within floating-point tolerance. A Rec.2020 source matrix is the
identity for the fixed working space. No channel should be silently clipped.

Failure caught: transposed matrix upload, wrong primary order, missing white
point scaling, wrong matrix multiplication direction, or a `float3`/`float4`
uniform alignment error.

## 8. Grade controls and pivot

Action:

1. Disable input decode, gamut, tone map, and output encode to inspect the
   linear grade path directly.
2. Set Grade ON and all controls neutral.
3. Test Exposure at +1 stop and -1 stop; then set Contrast to 2.0 and use a
   linear sample exactly equal to the selected Contrast Pivot.
4. Move Shadows and Highlights separately across a grayscale ramp.
5. Compare Saturation with Color Boost on a chart containing both subtle and
   already-saturated colors; rotate Hue by 180 degrees and back to zero.
6. Move each Lift/Gamma/Gain/Offset channel separately.

Correct result:

- +1 stop doubles every signed linear component; -1 stop halves it;
- a value exactly equal to Contrast Pivot remains unchanged when only contrast changes;
- Shadows changes the lower ramp smoothly, Highlights changes the upper ramp
  smoothly, and neither creates a hard seam;
- Color Boost affects the low-saturation patches proportionally more than the
  saturated patches; Hue Rotation preserves a neutral gray and returns exactly
  to the original image at zero;
- temperature/tint move channels according to the documented gain model;
- lift/gamma/gain/offset respond per channel and neutral `0.5` is identity.

Failure caught: exposure implemented in encoded space, contrast pivot wrong,
hard tonal-mask boundaries, non-neutral hue math, color boost behaving like a
second saturation knob, gamma using an unsigned `pow`, color controls remapped
by FCP, or channel order swapped.

## 9. Tone-map curves and knee

Action: use a linear HDR test source with values near `0.18`, `1.0`, `4.0`, and
`10.0`. Keep the grade neutral and output encoding off while inspecting the
tone-map result.

Correct result:

- None is an exact pass-through, including values above 1.0;
- Reinhard with knee `1.0` maps `1.0` to `0.5`;
- increasing the knee postpones highlight compression;
- Filmic is monotonic for positive inputs and does not introduce NaNs;
- negative extended values remain finite until a final output encode is chosen.

Failure caught: an implicit clamp before tone mapping, wrong popup indexing,
division by zero at a knee near the minimum, filmic white-point error, or NaN
generation from negative values.

## 10. Output and display-referred toggle

Action:

1. In a Rec.709 project, use a neutral linear test and enable only Output Encode
   after the earlier stages are configured.
2. Compare BT.709 output with Display-Referred 2.4 Gamma ON.
3. Test values below 0 and above 1.

Correct result: output is Rec.709, the display toggle changes the transfer curve
only, and the final image contains no values outside the destination’s valid
encoded range. No earlier stage is clipped merely because output encoding is
enabled.

Failure caught: output matrix in the wrong direction, double encoding, early
clamp, a display toggle that changes gamut, or an sRGB texture-format conversion
being applied in addition to the shader transfer.

## 11. Rec.709 versus wide-gamut library

Action:

1. Duplicate the test library/project.
2. Run the same clip/effect in a standard Rec.709 library and a wide-gamut HDR
   Rec.2020 library.
3. Check scopes and an exported still in addition to the viewer.

Correct result:

- the plugin receives the project’s documented working gamut;
- the Rec.709 project returns gamma-video Rec.709 at the host boundary;
- the wide-gamut project uses the Rec.709 display stage but returns the
  project-gamut boundary conversion from the single kernel;
- switching libraries does not change parameter values or crash the XPC
  service.

Failure caught: unavailable `FxColorGamutAPI_v2`, incorrect project-gamut
comparison, output interpreted as the wrong gamut, or FCP having already
transformed camera log media before the plugin. If camera metadata has been
automatically managed, repeat with that transform disabled and document the
observed FCP behaviour.

## 12. Tiling, proxy, and non-square-pixel behaviour

Action: in FCP, test the same effect at full and proxy resolution,
with a small viewer/timeline tile, with a non-square-pixel source, and with
fields if the host exposes that setting. Also render a frame where the source
and destination tile origins are not zero.

Correct result: no seams at tile boundaries, no shift or flip, no dependence on
viewer zoom, and the same colour result at full versus proxy resolution apart
from expected quantization.

Failure caught: assuming local texture coordinates are full-image coordinates,
wrong FxRect origin field, hidden multi-pass dependency, or an unsupported pixel
transform being silently applied.

## 13. Alpha and extended range

Action: use a clip with transparent edges or an image well with known alpha and
extended-range highlights. Compare alpha with the input using a compositing
checkerboard.

Correct result: alpha is copied unchanged; RGB is graded independently; values
outside nominal `[0,1]` remain usable until output encoding; no black fringe
appears around transparent pixels.

Failure caught: accidental alpha grading, premultiplied/straight mismatch,
unexpected source texture format, or a clamp before the output stage.

## 14. Parameter persistence and ID compatibility

Action:

1. Set distinctive non-default values for every control and save a project.
2. Quit/relaunch FCP, reopen the project, and verify every value.
3. Undo/redo several parameter changes and save again.

Correct result: every control returns to its own value; no old control appears
under another name; undo/redo does not make the render state stale.

Failure caught: changed integer IDs, duplicate IDs, state packing mistakes, or
parameter retrieval at the wrong time.

## 15. LUT browser and preview-before-commit

Action:

1. Open the LUT Library control in FCP’s inspector.
2. Confirm the compact view shows `No LUT`, a readable summary, previous/next
   buttons, and a clearly labeled **LUT Library…** button within the normal
   inspector width.
3. Import one valid `.cube` file and open the browser. Click its card, inspect
   the deterministic reference chart, then choose **Cancel**.
4. Confirm the effect still reports `No LUT`. Repeat and choose **Apply**.

Correct result: card clicks only change the pending preview; Cancel leaves the
parameter and rendered image unchanged; Apply changes the selection and the
compact summary. The preview says reference chart rather than implying a live
FCP frame.

Failure caught: custom-view lifetime loss, wrong custom parameter class,
premature parameter mutation, an unsafe live-frame assumption, broken
viewbridge/AppKit window handling, or a browser wider than the inspector
requires.

## 16. `.cube` import, recursion, duplicates, and invalid files

Action:

1. Import a valid UTF-8 3D `.cube` with `LUT_3D_SIZE 2`.
2. Import the same file again and then import a folder containing it plus nested
   valid `.cube` files.
3. Try a `LUT_1D_SIZE` file, a wrong sample count, a non-default domain, a
   malformed triplet, and a non-UTF-8 file.

Correct result: valid files appear once; recursive import finds nested files;
duplicate content is skipped; invalid files are listed as rejected and never
become selectable. No source file is moved or copied.

Failure caught: parser ordering/size mistakes, unbounded or main-thread folder
enumeration, duplicate metadata, unsupported vendor syntax being accepted as
valid, or a missing security-scoped bookmark.

## 17. Numerical constant-LUT check

This test is independent of visual judgment and checks the LUT stage’s domain,
amount, interpolation, and final placement.

Action: create a text file containing exactly this constant 2×2×2 LUT:

```text
TITLE "CST constant test"
LUT_3D_SIZE 2
0.25 0.50 0.75
0.25 0.50 0.75
0.25 0.50 0.75
0.25 0.50 0.75
0.25 0.50 0.75
0.25 0.50 0.75
0.25 0.50 0.75
0.25 0.50 0.75
```

In a Rec.709 project, enable output encoding, set the LUT to 100%, and use a
floating-point frame capture or the host’s numeric pixel inspector on a pixel
whose encoded output is in range. The encoded RGB after the LUT and final clamp
must be `(0.25, 0.50, 0.75)` within the capture’s quantization tolerance. Set
LUT Amount to 0%; the result must match the same effect with LUT Enabled off.

Failure caught: sampling the wrong `.cube` axis/order, applying the LUT before
tone/output encoding, a broken 3D texture upload, wrong amount normalization,
or a second color conversion after the LUT.

## 18. LUT identity, interpolation, and clean bypass

Action:

1. Use a 2×2×2 identity LUT with samples in red-fastest order:

```text
LUT_3D_SIZE 2
0 0 0
1 0 0
0 1 0
1 1 0
0 0 1
1 0 1
0 1 1
1 1 1
```

2. Test it at 100% and compare with LUT Enabled off.
3. Use a known encoded sample `(0.25, 0.50, 0.75)` or a reference chart and
   inspect the numeric result.
4. Set Amount to 0%, toggle LUT Enabled off, select No LUT, and enable Global
   Bypass independently.

Correct result: the identity LUT is unchanged within float/host quantization;
the midpoint uses trilinear interpolation rather than nearest-neighbor steps;
Amount 0% and LUT disabled are clean pre-LUT bypasses; No LUT never activates a
different cached LUT; Global Bypass returns the original source pixel exactly.

Failure caught: green/blue axis reversal, nearest-neighbor sampling, blending
against a clamped value, stale texture selection, or a bypass that still runs a
stage.

## 19. LUT range and stage-order check

Action: use a creative LUT containing output values below 0 and above 1, and an
input/grade combination that produces highlights above 1. Test LUT amounts 0%,
50%, and 100%, with Tone Map and Output Encode toggled in turn.

Correct result: LUT lookup coordinates are clamped only for addressing; the
pre-LUT encoded value remains the blend input; the final output clamp occurs
only after the LUT and wide-gamut boundary conversion. The LUT has no effect
when Output Encode is off, and a tone-map change affects the LUT’s input because
the fixed order is decode → gamut → grade → tone → output encode → LUT.

Failure caught: an early clamp, applying the LUT to scene-linear data, output
LUT before tone mapping, accidental input/technical LUT behavior, or a second
render pass.

## 20. LUT persistence, bookmarks, and missing sources

Action:

1. Select a LUT, add it to a collection, favorite it, save an FCP
   project, quit FCP, and reopen the project.
2. Move or rename the source `.cube` file, then reopen the browser and render.
3. Restore the file or use the browser’s import path to create a new selection.

Correct result: selection, amount, enabled state, favorite, collection, search,
sort, and recent-use view persist. A moved/missing/changed source is reported as
unavailable; rendering fails closed to the clean pre-LUT value and does not
silently use a different file. Restoring/reimporting a valid file makes it
available again.

Failure caught: custom `NSSecureCoding` archive failure, bookmark resolution
failure, content-hash mismatch handling, unsafe path fallback, or a stale GPU
texture being used for a new file.

## 21. Favorites, search, recents, collections, and navigation

Action: import at least five LUTs with distinct names. Mark two favorites, make
two collections, assign records, search by a partial name, switch between Name
and Recent Added sorting, try the Recents filter, and use Previous/Next from the
compact inspector view. Also
open the wrapper organizer through the LUT Library button and audition a card
there.

Correct result: each filter is deterministic, favorites and collections survive
relaunch, Recent changes after Apply, search narrows the visible set, and
Previous/Next cycles through the same sorted choices including No LUT without
crashing. Organizer card clicks do not change the effect until Apply; Apply
returns the selected item to the inspector.

Failure caught: unpersisted organizer state, wrong selection identity, stale
card closures, duplicate records, blocked wrapper/notification bridge,
unbounded thumbnail creation, or navigation that commits a preview unexpectedly.

## 22. LUT cache and low-power behavior

Action: import several large but valid 3D LUTs, open and close the browser,
scroll through the visible cards, apply different LUTs, and watch Activity
Monitor’s memory pressure on the 8 GB 2015 MacBook Pro. Render a short 4K clip
while changing Amount during playback.

Correct result: folder import and card parsing remain responsive; only the
bounded visible set is thumbnailized; parsed CPU entries are bounded; GPU
textures are reused per device/content identity; render work remains one Metal
kernel pass with no steady unbounded memory growth.

Failure caught: reading files from the render callback, caching full frames,
allocating one texture per preview repeatedly, browser stalls, a second pass, or
memory pressure that makes FCP terminate the XPC service.

## 23. XPC restart and low-power GPU stability

Action: render a short clip, stop/force-quit only the CST Grade XPC process from
Activity Monitor, then ask FCP to render again. Repeat no more than twice within
30 seconds, because Apple warns hosts may mark repeatedly killed plugins as
unresponsive. Test a 4K timeline with the 2015 MacBook’s integrated GPU while
watching memory pressure.

Correct result: FCP respawns the service, the effect renders again, there is no
steady memory growth, and one compute pass is visible in a Metal capture.

Failure caught: resources held only in invalid process state, missing default
Metal library, unsafe mutable shared state, multiple passes/textures, or a
command buffer returned before its IOSurface writes completed.

## 24. Remove-and-reinstall check

Action: quit both hosts, remove only the CST Grade `.fxplug` and `.moef`, restart
FCP, then reinstall and restart again.

Correct result: the custom category disappears after removal and returns after
reinstallation; unrelated FxPlug plugins remain present.

Failure caught: installing to the wrong directory, stale PlugInKit registration,
template cache confusion, or an uninstall instruction that removes unrelated
plugins.
