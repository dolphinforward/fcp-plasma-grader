# Additional user requirements: intuitive UX and visual LUT library

These requirements were added by the user after implementation began. They are part
of the required scope and must be addressed before the project is called complete.

## Overall usability

- The effect must be approachable to an editor who is not a colour scientist.
- Organize controls in the visible pipeline order with plain-language section names,
  concise help text/tooltips, sensible safe defaults, and predictable reset actions.
- Keep advanced details out of the main path. Disable or hide controls that do not
  apply to the current mode.
- Make bypass/A-B comparison obvious. Each stage toggle must be adjacent to its
  controls, and the complete effect needs a one-click bypass/reset path.
- Use human-readable menu labels; never expose enum integers, implementation names,
  matrix jargon, or unexplained abbreviations in the UI.
- Preserve parameter IDs and saved-project compatibility. New parameters need new,
  stable IDs in the central ID file.
- Stay usable at normal Final Cut inspector widths on the target 2015 Intel Mac.

## mLUT-style visual LUT picker and organizer

Create an original UI inspired by the useful interaction pattern of MotionVFX mLUT,
not a copy of its branding, assets, or exact visual design.

The effect should have a clearly labelled **LUT Library** button and a compact inspector
summary showing the selected LUT. The library should provide:

- A visual thumbnail grid that previews LUTs, ideally using the current clip/frame;
  if FxPlug cannot reliably provide that image to a browser UI, use a documented,
  representative built-in reference image and clearly state the limitation.
- Click-to-preview before committing, explicit Apply/Cancel behaviour, and an obvious
  no-LUT choice.
- Import of individual standard `.cube` files and recursive folder import.
- Folder/category browsing, search by name, favorites (star), recents, and user-created
  collections. Collections and favorites should be metadata and must not move or
  duplicate the user's source LUT files without an explicit action.
- Sort by name and recently added. Preserve the last useful browser view.
- Previous/next LUT navigation from the inspector for fast auditioning.
- LUT enable/bypass, selected-LUT name, and a clearly labelled Amount control from
  0-100%, with 100% as the normal full look and 0% as a mathematically clean bypass.
- Friendly handling of invalid, unsupported, duplicate, moved, or missing LUT files;
  show a useful message rather than silently falling back to another look.
- Persistent access to imported locations using the correct macOS sandbox/bookmark
  mechanism if required by FxPlug/XPC. Never depend on a transient absolute path alone.

Use a local, dependency-free metadata store compatible with macOS 11.0. Do not require
an account, network connection, cloud service, subscription, or bundled proprietary LUTs.

## Colour and render behaviour for LUTs

- Treat the first LUT mode as a **creative Rec.709 display LUT**. Document exactly where
  it sits in the CST pipeline and what input/output domain it expects. The intended
  default is after tone mapping and Rec.709 display encoding, before the final output
  clamp. Do not silently apply a display LUT to scene-linear values.
- When the LUT stage is disabled, the existing CST pipeline must remain bit-for-bit
  unaffected apart from unavoidable floating-point details.
- Apply the LUT and its Amount blend in the existing single Metal kernel. Upload LUT
  data as a GPU texture/buffer once when selection changes; never parse or read a LUT
  from disk for every frame.
- Clamp only the coordinates required for safe LUT lookup. Do not overwrite the
  unclamped pipeline value merely to perform the lookup; blend against the original
  pre-LUT value and retain the final-output clamp rule.
- State which `.cube` features and sizes are supported. Validate dimensions and data
  counts before upload, and add numerical/manual tests for identity LUT, full amount,
  zero amount, interpolation, and missing-file recovery.
- If supporting technical/input LUTs would make colour-domain behaviour ambiguous,
  omit that mode from v1 and state the limitation instead of guessing.

## Performance and feasibility boundary

- Design for the specified 2015 Intel Mac with 8 GB RAM and a weak integrated GPU:
  lazy thumbnail generation, bounded caches, cancellation during fast scrolling/search,
  and no eager rendering of an entire large library.
- Keep the render path one-pass. Browser thumbnail work must not stall Final Cut
  playback or allocate an unbounded number of full-resolution frames/textures.
- If FxPlug 4 on Final Cut Pro 10.6.5 cannot host the full browser safely inside the
  inspector, use the existing FxPlug wrapper application as the library/organizer and
  expose a simple Library button/selection bridge in the effect. Document the exact
  limitation and workflow. Do not invent an FxPlug custom-view API signature.
- Update the Xcode project, README, TESTING.md, uncertainty section, and source comments
  for this feature. Linux-side structural checks are welcome, but do not claim macOS,
  Xcode, Metal, or Final Cut verification.

## Samsung Log and primary grading extensions

- Append Samsung Log to the persisted Input Transfer menu without reordering any
  existing choice. Decode with Samsung's documented analytic curve and validate its
  branch join and 18% gray value independently.
- Keep transfer and source primaries as explicit controls. Document the normal Samsung
  Log pairing with the existing Rec.2020 source-primaries option.
- Cover the essential DaVinci-style primary workflow with adjustable contrast pivot,
  shadows, highlights, saturation, color boost/vibrance, hue rotation, and
  Lift/Gamma/Gain/Offset while retaining the existing exposure and white-balance tools.
- Do not claim proprietary Resolve math or attempt to hide suite-level limitations.
  Map masks, tracking, scopes, presets, keyframes, and serial effect instances to Final
  Cut Pro; document advanced Resolve-only systems that a single FxPlug does not replace.
- Publish the repository as `fcp-plasma-grader`. Keep the original CST Grade bundle,
  registration UUID, and persisted parameter identity so the repository rename does not
  break projects.
