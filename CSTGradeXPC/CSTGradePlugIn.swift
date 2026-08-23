//
// CSTGradePlugIn.swift
//
// FxPlug 4 shell for the CST Grade colour effect.
//
// The host-facing lifecycle is deliberately narrow:
//   - addParameters() declares the persistent inspector controls.
//   - properties() requests gamma-video/project-gamut pixels at the FxPlug
//     boundary because this effect owns the input transfer-function decode.
//   - pluginState() retrieves parameters and derives all CPU matrices once per
//     render state. No host API is touched from the render callback.
//   - sourceTileRect()/destinationImageRect() describe a 1:1 colour filter.
//   - renderDestinationImage() encodes one Metal compute dispatch for the full
//     decode → gamut → grade → tone-map → output chain.
//
// Apple documents that FxPlug 4 uses FxTileableEffect for out-of-process
// rendering and that parameter retrieval APIs are valid while building
// pluginState, not during render:
// https://developer.apple.com/documentation/professional-video-applications/fxtileableeffect
// https://developer.apple.com/documentation/professional-video-applications/communicating-with-the-plug-in-state
//

import CoreMedia
import AppKit
import Foundation
import Metal
import FxPlug

private final class CSTMetalResources {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    private var lutTextures: [UInt64: MTLTexture] = [:]
    private var lutTextureOrder: [UInt64] = []
    private let lutLock = NSLock()
    private let maximumLUTTextures = 4

    init(device: MTLDevice) throws {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw CSTGradeError("Metal command queue creation failed")
        }
        guard let library = device.makeDefaultLibrary() else {
            throw CSTGradeError("CSTGrade.metallib was not found in the XPC bundle")
        }
        guard let function = library.makeFunction(name: "cstGradeKernel") else {
            throw CSTGradeError("Metal function cstGradeKernel was not found")
        }
        self.commandQueue = commandQueue
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Returns a cached 3D GPU texture for the immutable parsed LUT. Parsing
    /// happens while pluginState is built; render never reads a file. ID 0 is
    /// a cached identity texture used whenever no valid LUT is selected.
    func textureForLUT(identifier: UInt64) throws -> (texture: MTLTexture, valid: Bool) {
        lutLock.lock()
        defer { lutLock.unlock() }
        if let existing = lutTextures[identifier] {
            if identifier != 0 {
                lutTextureOrder.removeAll { $0 == identifier }
                lutTextureOrder.append(identifier)
            }
            return (existing, identifier != 0)
        }

        if identifier != 0, let parsed = CSTLUTParsedCache.shared.value(for: identifier) {
            let texture = try makeTexture(for: parsed)
            lutTextures[identifier] = texture
            lutTextureOrder.removeAll { $0 == identifier }
            lutTextureOrder.append(identifier)
            while lutTextureOrder.count > maximumLUTTextures {
                let old = lutTextureOrder.removeFirst()
                lutTextures.removeValue(forKey: old)
            }
            return (texture, true)
        }

        // A pluginState with a valid LUT should have populated the parsed
        // cache. If it did not, fail closed: the shader receives identity and
        // its valid flag is cleared by the caller.
        let identity: MTLTexture
        if let existingIdentity = lutTextures[0] {
            identity = existingIdentity
        } else {
            identity = try makeTexture(for: CSTMetalResources.identityLUT())
            lutTextures[0] = identity
        }
        guard identifier == 0 else { return (identity, false) }
        return (identity, false)
    }

    private func makeTexture(for parsed: CSTParsedLUT) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = MTLTextureType.type3D
        descriptor.pixelFormat = MTLPixelFormat.rgba32Float
        descriptor.width = parsed.dimension
        descriptor.height = parsed.dimension
        descriptor.depth = parsed.dimension
        descriptor.mipmapLevelCount = 1
        descriptor.usage = MTLTextureUsage.shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw CSTGradeError("Could not allocate the LUT 3D Metal texture")
        }
        let values = parsed.rgbaFloatValues()
        let bytesPerPixel = 4 * MemoryLayout<Float>.stride
        let bytesPerRow = parsed.dimension * bytesPerPixel
        let bytesPerImage = parsed.dimension * bytesPerRow
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: parsed.dimension, height: parsed.dimension, depth: parsed.dimension)
        )
        values.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                slice: 0,
                withBytes: UnsafeRawPointer(baseAddress),
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }
        return texture
    }

    private static func identityLUT() -> CSTParsedLUT {
        var values: [Float] = []
        for blue in 0...1 {
            for green in 0...1 {
                for red in 0...1 {
                    values.append(contentsOf: [Float(red), Float(green), Float(blue)])
                }
            }
        }
        return CSTParsedLUT(identifier: 0, dimension: 2, rgbValues: values)
    }
}

@objc(CSTGradePlugIn)
final class CSTGradePlugIn: NSObject, FxTileableEffect, FxCustomParameterViewHost_v2 {
    private let apiManager: PROAPIAccessing
    // FxPlug's custom-view bridge expects the returned NSView to remain alive
    // after createView(forParameterID:) returns. Keep every host-created view
    // strongly until the plugin instance itself is released.
    private var lutParameterViews: [CSTLUTParameterView] = []

    // FxPlug can call the same instance concurrently. Metal objects are
    // immutable after construction; the lock protects only lazy construction
    // of one resource set per host Metal registry ID.
    private var metalResources: [UInt64: CSTMetalResources] = [:]
    private let metalResourcesLock = NSLock()

    required init?(apiManager: PROAPIAccessing) {
        self.apiManager = apiManager
        super.init()
    }

    // MARK: Parameters

    func addParameters() throws {
        guard let parameterAPI = apiManager.api(for: FxParameterCreationAPI_v5.self)
                as? FxParameterCreationAPI_v5 else {
            throw CSTGradeError("FxParameterCreationAPI_v5 is unavailable")
        }

        let defaultFlags = FxParameterFlags(kFxParameterFlag_DEFAULT)
        // These three controls are numeric triples, not colour values. Without
        // DONT_REMAP_COLORS, FCP would convert the displayed sRGB values into
        // its current working colour space before returning them.
        let numericColorFlags = FxParameterFlags(
            kFxParameterFlag_DEFAULT | kFxParameterFlag_DONT_REMAP_COLORS
        )

        func require(_ result: Bool, _ parameterName: String) throws {
            guard result else {
                throw CSTGradeError("Final Cut Pro rejected parameter: \(parameterName)")
            }
        }

        // FxParameterCreationAPI_v5 provides host-native subgroups. They keep
        // the inspector in the same order as the render pipeline, put each
        // stage toggle beside that stage's controls, and avoid inventing a
        // private UI/parameter protocol. The subgroup IDs are stable constants
        // in CSTParameterIDs.swift for the same persistence reason as control
        // IDs.
        // UNVERIFIED: confirm that the Xcode 14.2 FxPlug 4.1 Swift importer
        // exposes the documented unlabeled first String argument spelling.
        func startGroup(_ name: String, id: UInt32) throws {
            try require(
                parameterAPI.startParameterSubGroup(
                    name,
                    parameterID: id,
                    parameterFlags: defaultFlags
                ),
                "parameter group \(name)"
            )
        }

        func endGroup(_ name: String) throws {
            try require(parameterAPI.endParameterSubGroup(), "end parameter group \(name)")
        }

        try startGroup("1. Input Decode", id: CSTParameterID.inputDecodeGroup)
        try require(parameterAPI.addToggleButton(
            withName: "Input Decode Enabled",
            parameterID: CSTParameterID.inputDecodeEnabled,
            defaultValue: true,
            parameterFlags: defaultFlags
        ), "Input Decode Enabled")

        let transferEntries: [NSString] = [
            "Rec.709",
            "sLog3",
            "V-Log",
            "ARRI LogC3 (EI 800)",
            "Gamma 2.2",
            "Samsung Log"
        ]
        try require(parameterAPI.addPopupMenu(
            withName: "Input Transfer",
            parameterID: CSTParameterID.inputTransfer,
            defaultValue: CSTInputTransfer.rec709.rawValue,
            menuEntries: transferEntries,
            parameterFlags: defaultFlags
        ), "Input Transfer")
        try endGroup("1. Input Decode")

        try startGroup("2. Gamut Transform", id: CSTParameterID.gamutTransformGroup)
        try require(parameterAPI.addToggleButton(
            withName: "Gamut Transform Enabled",
            parameterID: CSTParameterID.gamutTransformEnabled,
            defaultValue: true,
            parameterFlags: defaultFlags
        ), "Gamut Transform Enabled")

        let primariesEntries: [NSString] = [
            "S-Gamut3.cine",
            "V-Gamut",
            "ARRI Wide Gamut (AWG)",
            "Rec.709",
            "Rec.2020"
        ]
        try require(parameterAPI.addPopupMenu(
            withName: "Source Primaries",
            parameterID: CSTParameterID.sourcePrimaries,
            defaultValue: CSTSourcePrimaries.rec709.rawValue,
            menuEntries: primariesEntries,
            parameterFlags: defaultFlags
        ), "Source Primaries")
        try endGroup("2. Gamut Transform")

        try startGroup("3. Linear Grade", id: CSTParameterID.linearGradeGroup)
        try require(parameterAPI.addToggleButton(
            withName: "Grade Enabled",
            parameterID: CSTParameterID.gradeEnabled,
            defaultValue: true,
            parameterFlags: defaultFlags
        ), "Grade Enabled")

        try require(parameterAPI.addFloatSlider(
            withName: "Exposure (stops)",
            parameterID: CSTParameterID.exposureStops,
            defaultValue: 0.0,
            parameterMin: -8.0,
            parameterMax: 8.0,
            sliderMin: -8.0,
            sliderMax: 8.0,
            delta: 0.01,
            parameterFlags: defaultFlags
        ), "Exposure (stops)")

        try require(parameterAPI.addFloatSlider(
            withName: "White Balance Temperature",
            parameterID: CSTParameterID.whiteBalanceTemperature,
            defaultValue: 0.0,
            parameterMin: -1.0,
            parameterMax: 1.0,
            sliderMin: -1.0,
            sliderMax: 1.0,
            delta: 0.001,
            parameterFlags: defaultFlags
        ), "White Balance Temperature")

        try require(parameterAPI.addFloatSlider(
            withName: "White Balance Tint",
            parameterID: CSTParameterID.whiteBalanceTint,
            defaultValue: 0.0,
            parameterMin: -1.0,
            parameterMax: 1.0,
            sliderMin: -1.0,
            sliderMax: 1.0,
            delta: 0.001,
            parameterFlags: defaultFlags
        ), "White Balance Tint")

        try require(parameterAPI.addFloatSlider(
            withName: "Contrast",
            parameterID: CSTParameterID.contrast,
            defaultValue: 1.0,
            parameterMin: 0.0,
            parameterMax: 4.0,
            sliderMin: 0.0,
            sliderMax: 4.0,
            delta: 0.01,
            parameterFlags: defaultFlags
        ), "Contrast")

        try require(parameterAPI.addFloatSlider(
            withName: "Contrast Pivot",
            parameterID: CSTParameterID.contrastPivot,
            defaultValue: 0.18,
            parameterMin: 0.01,
            parameterMax: 1.0,
            sliderMin: 0.01,
            sliderMax: 1.0,
            delta: 0.001,
            parameterFlags: defaultFlags
        ), "Contrast Pivot")

        try require(parameterAPI.addFloatSlider(
            withName: "Shadows",
            parameterID: CSTParameterID.shadows,
            defaultValue: 0.0,
            parameterMin: -1.0,
            parameterMax: 1.0,
            sliderMin: -1.0,
            sliderMax: 1.0,
            delta: 0.001,
            parameterFlags: defaultFlags
        ), "Shadows")

        try require(parameterAPI.addFloatSlider(
            withName: "Highlights",
            parameterID: CSTParameterID.highlights,
            defaultValue: 0.0,
            parameterMin: -1.0,
            parameterMax: 1.0,
            sliderMin: -1.0,
            sliderMax: 1.0,
            delta: 0.001,
            parameterFlags: defaultFlags
        ), "Highlights")

        try require(parameterAPI.addFloatSlider(
            withName: "Saturation",
            parameterID: CSTParameterID.saturation,
            defaultValue: 1.0,
            parameterMin: 0.0,
            parameterMax: 3.0,
            sliderMin: 0.0,
            sliderMax: 3.0,
            delta: 0.01,
            parameterFlags: defaultFlags
        ), "Saturation")

        try require(parameterAPI.addFloatSlider(
            withName: "Color Boost (Vibrance)",
            parameterID: CSTParameterID.colorBoost,
            defaultValue: 0.0,
            parameterMin: -1.0,
            parameterMax: 1.0,
            sliderMin: -1.0,
            sliderMax: 1.0,
            delta: 0.001,
            parameterFlags: defaultFlags
        ), "Color Boost (Vibrance)")

        try require(parameterAPI.addFloatSlider(
            withName: "Hue Rotation (degrees)",
            parameterID: CSTParameterID.hueRotation,
            defaultValue: 0.0,
            parameterMin: -180.0,
            parameterMax: 180.0,
            sliderMin: -180.0,
            sliderMax: 180.0,
            delta: 0.1,
            parameterFlags: defaultFlags
        ), "Hue Rotation (degrees)")

        try require(parameterAPI.addColorParameter(
            withName: "Lift",
            parameterID: CSTParameterID.lift,
            defaultRed: 0.5,
            defaultGreen: 0.5,
            defaultBlue: 0.5,
            parameterFlags: numericColorFlags
        ), "Lift")

        try require(parameterAPI.addColorParameter(
            withName: "Gamma",
            parameterID: CSTParameterID.gamma,
            defaultRed: 0.5,
            defaultGreen: 0.5,
            defaultBlue: 0.5,
            parameterFlags: numericColorFlags
        ), "Gamma")

        try require(parameterAPI.addColorParameter(
            withName: "Gain",
            parameterID: CSTParameterID.gain,
            defaultRed: 0.5,
            defaultGreen: 0.5,
            defaultBlue: 0.5,
            parameterFlags: numericColorFlags
        ), "Gain")

        try require(parameterAPI.addColorParameter(
            withName: "Offset",
            parameterID: CSTParameterID.offset,
            defaultRed: 0.5,
            defaultGreen: 0.5,
            defaultBlue: 0.5,
            parameterFlags: numericColorFlags
        ), "Offset")
        try endGroup("3. Linear Grade")

        try startGroup("4. Tone Map", id: CSTParameterID.toneMapGroup)
        try require(parameterAPI.addToggleButton(
            withName: "Tone Map Enabled",
            parameterID: CSTParameterID.toneMapEnabled,
            defaultValue: true,
            parameterFlags: defaultFlags
        ), "Tone Map Enabled")

        let toneMapEntries: [NSString] = ["None", "Reinhard", "Filmic"]
        try require(parameterAPI.addPopupMenu(
            withName: "Tone Map",
            parameterID: CSTParameterID.toneMap,
            defaultValue: CSTToneMap.reinhard.rawValue,
            menuEntries: toneMapEntries,
            parameterFlags: defaultFlags
        ), "Tone Map")

        try require(parameterAPI.addFloatSlider(
            withName: "Highlight Knee",
            parameterID: CSTParameterID.highlightKnee,
            defaultValue: 1.0,
            parameterMin: 0.1,
            parameterMax: 8.0,
            sliderMin: 0.1,
            sliderMax: 8.0,
            delta: 0.01,
            parameterFlags: defaultFlags
        ), "Highlight Knee")
        try endGroup("4. Tone Map")

        try startGroup("5. Output Encode", id: CSTParameterID.outputEncodeGroup)
        try require(parameterAPI.addToggleButton(
            withName: "Output Encode Enabled",
            parameterID: CSTParameterID.outputEncodeEnabled,
            defaultValue: true,
            parameterFlags: defaultFlags
        ), "Output Encode Enabled")

        try require(parameterAPI.addToggleButton(
            withName: "Display-Referred 2.4 Gamma",
            parameterID: CSTParameterID.displayReferred,
            defaultValue: false,
            parameterFlags: defaultFlags
        ), "Display-Referred 2.4 Gamma")
        try endGroup("5. Output Encode")

        // The custom parameter replaces the standard inspector control with a
        // compact summary and an AppKit LUT Library button. Its value is the
        // secure-coded file identity/bookmark, not a transient filesystem path.
        try startGroup("6. Creative LUT", id: CSTParameterID.creativeLUTGroup)
        let lutFlags = FxParameterFlags(
            kFxParameterFlag_DEFAULT |
            kFxParameterFlag_CUSTOM_UI |
            kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD |
            kFxParameterFlag_NOT_ANIMATABLE
        )
        try require(parameterAPI.addCustomParameter(
            withName: "LUT Library",
            parameterID: CSTParameterID.lutSelection,
            defaultValue: CSTLUTSelection.none(),
            parameterFlags: lutFlags
        ), "LUT Library")

        try require(parameterAPI.addToggleButton(
            withName: "Creative LUT Enabled",
            parameterID: CSTParameterID.lutEnabled,
            defaultValue: true,
            parameterFlags: defaultFlags
        ), "Creative LUT Enabled")

        try require(parameterAPI.addPercentSlider(
            withName: "Creative LUT Amount",
            parameterID: CSTParameterID.lutAmount,
            defaultValue: 1.0,
            parameterMin: 0.0,
            parameterMax: 1.0,
            sliderMin: 0.0,
            sliderMax: 1.0,
            delta: 0.01,
            parameterFlags: defaultFlags
        ), "Creative LUT Amount")
        try endGroup("6. Creative LUT")

        try startGroup("Utilities", id: CSTParameterID.utilityGroup)
        try require(parameterAPI.addToggleButton(
            withName: "Global Bypass",
            parameterID: CSTParameterID.globalBypass,
            defaultValue: false,
            parameterFlags: defaultFlags
        ), "Global Bypass")

        // UNVERIFIED: addPushButton/selector is documented, but confirm the
        // Xcode 14.2 FxPlug SDK importer accepts this exact target-action form
        // and calls resetAllControls(_:) from FCP 10.6.5.
        try require(parameterAPI.addPushButton(
            withName: "Reset All Controls",
            parameterID: CSTParameterID.resetAll,
            selector: #selector(resetAllControls(_:)),
            parameterFlags: defaultFlags
        ), "Reset All Controls")
        try endGroup("Utilities")
    }

    // MARK: Custom LUT parameter bridge

    // UNVERIFIED: the Swift spelling is taken from Apple's
    // FxCustomParameterViewHost_v2 documentation. If the Xcode 14.2 headers
    // expose an implicitly-unwrapped or optional return differently, use the
    // generated protocol declaration from FxPlug.framework as the authority.
    func createView(forParameterID parameterID: UInt32) -> NSView! {
        guard parameterID == CSTParameterID.lutSelection else { return nil }
        let view = CSTLUTParameterView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        view.onCommit = { [weak self, weak view] selection in
            self?.commitLUTSelection(selection, sender: view)
        }
        lutParameterViews.append(view)
        return view
    }

    func `class`(forCustomParameterID parameterID: UInt32) -> AnyClass {
        parameterID == CSTParameterID.lutSelection ? CSTLUTSelection.self : NSObject.self
    }

    func classes(forCustomParameterID parameterID: UInt32) -> Set<AnyHashable> {
        guard parameterID == CSTParameterID.lutSelection else { return [] }
        // Keep NSSet<Class> creation on the Objective-C side so the class
        // object crosses Foundation's Set<AnyHashable> bridge intact.
        return CSTLUTSelection.allowedClasses()
    }

    func parameterChanged(_ paramID: UInt32, at time: CMTime) throws {
        guard let retrievalAPI = apiManager.api(for: FxParameterRetrievalAPI_v6.self)
                as? FxParameterRetrievalAPI_v6,
              let settingAPI = apiManager.api(for: FxParameterSettingAPI_v5.self)
                as? FxParameterSettingAPI_v5 else { return }

        let availabilityIDs: Set<UInt32> = [
            CSTParameterID.inputDecodeEnabled,
            CSTParameterID.gamutTransformEnabled,
            CSTParameterID.gradeEnabled,
            CSTParameterID.toneMapEnabled,
            CSTParameterID.toneMap,
            CSTParameterID.outputEncodeEnabled,
            CSTParameterID.lutSelection,
            CSTParameterID.lutEnabled
        ]
        guard availabilityIDs.contains(paramID) else { return }

        var value: (NSCopying & NSSecureCoding & NSObjectProtocol)?
        let hasSelection = retrievalAPI.getCustomParameterValue(
            &value,
            fromParameter: CSTParameterID.lutSelection,
            at: time
        )
        let selection = hasSelection ? (value as? CSTLUTSelection ?? .none()) : .none()

        if paramID == CSTParameterID.lutSelection {
            DispatchQueue.main.async { [weak self] in
                self?.lutParameterViews.forEach { $0.setSelection(selection) }
            }
            CSTLUTLibraryStore.shared.markUsed(selection)
        }

        // These flags are host-native affordances rather than a second UI
        // system: a stage toggle remains editable while controls that have no
        // effect in the current mode are visibly disabled. This is called from
        // a host parameter-change callback, so it does not start a custom
        // action (starting one here could hang the host).
        updateParameterAvailability(
            retrievalAPI: retrievalAPI,
            settingAPI: settingAPI,
            selection: selection,
            at: time
        )
    }

    private func updateParameterAvailability(
        retrievalAPI: FxParameterRetrievalAPI_v6,
        settingAPI: FxParameterSettingAPI_v5,
        selection: CSTLUTSelection,
        at time: CMTime
    ) {
        let inputDecodeEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.inputDecodeEnabled, at: time
        )
        let gamutEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.gamutTransformEnabled, at: time
        )
        let gradeEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.gradeEnabled, at: time
        )
        let toneMapEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.toneMapEnabled, at: time
        )
        let toneMapValue = UInt32(clamping: intValue(
            retrievalAPI,
            parameterID: CSTParameterID.toneMap,
            at: time,
            defaultValue: Int32(CSTToneMap.reinhard.rawValue)
        ))
        let outputEncodeEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.outputEncodeEnabled, at: time
        )
        let lutEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.lutEnabled, at: time
        )

        let standardFlags = FxParameterFlags(kFxParameterFlag_DEFAULT)
        let numericColorFlags = FxParameterFlags(
            kFxParameterFlag_DEFAULT | kFxParameterFlag_DONT_REMAP_COLORS
        )
        let disabledStandardFlags = FxParameterFlags(
            kFxParameterFlag_DEFAULT | kFxParameterFlag_DISABLED
        )
        let disabledNumericColorFlags = FxParameterFlags(
            kFxParameterFlag_DEFAULT |
            kFxParameterFlag_DONT_REMAP_COLORS |
            kFxParameterFlag_DISABLED
        )

        func setDisabled(_ id: UInt32, _ disabled: Bool, numericColor: Bool = false) {
            let flags: FxParameterFlags
            if disabled {
                flags = numericColor ? disabledNumericColorFlags : disabledStandardFlags
            } else {
                flags = numericColor ? numericColorFlags : standardFlags
            }
            _ = settingAPI.setParameterFlags(flags, toParameter: id)
        }

        setDisabled(CSTParameterID.inputTransfer, !inputDecodeEnabled)
        setDisabled(CSTParameterID.sourcePrimaries, !gamutEnabled)

        for id in [
            CSTParameterID.exposureStops,
            CSTParameterID.whiteBalanceTemperature,
            CSTParameterID.whiteBalanceTint,
            CSTParameterID.contrast,
            CSTParameterID.contrastPivot,
            CSTParameterID.shadows,
            CSTParameterID.highlights,
            CSTParameterID.saturation,
            CSTParameterID.colorBoost,
            CSTParameterID.hueRotation
        ] {
            setDisabled(id, !gradeEnabled)
        }
        for id in [
            CSTParameterID.lift,
            CSTParameterID.gamma,
            CSTParameterID.gain,
            CSTParameterID.offset
        ] {
            setDisabled(id, !gradeEnabled, numericColor: true)
        }

        setDisabled(CSTParameterID.toneMap, !toneMapEnabled)
        setDisabled(
            CSTParameterID.highlightKnee,
            !toneMapEnabled || toneMapValue == CSTToneMap.none.rawValue
        )
        setDisabled(CSTParameterID.displayReferred, !outputEncodeEnabled)
        setDisabled(
            CSTParameterID.lutAmount,
            !outputEncodeEnabled || !lutEnabled || selection.identifier == 0
        )
    }

    private func commitLUTSelection(_ selection: CSTLUTSelection, sender: Any?) {
        guard let actionAPI = apiManager.api(for: FxCustomParameterActionAPI_v4.self)
                as? FxCustomParameterActionAPI_v4,
              let settingAPI = apiManager.api(for: FxParameterSettingAPI_v5.self)
                as? FxParameterSettingAPI_v5 else { return }
        let actionSender: Any = sender ?? self
        let time = actionAPI.currentTime()
        actionAPI.startAction(actionSender)
        _ = settingAPI.setCustomParameterValue(
            selection,
            toParameter: CSTParameterID.lutSelection,
            at: time
        )
        actionAPI.endAction(actionSender)
        CSTLUTLibraryStore.shared.markUsed(selection)
    }

    // UNVERIFIED: Final Cut Pro's push-button selector is documented, but the
    // exact time/action context for a selector callback is not described in
    // the public FxPlug 4 pages. Confirm this against FxSimpleColorCorrector
    // in the installed SDK. The implementation keeps all setting calls in a
    // single action so Reset is one undoable operation when the host permits
    // custom-action APIs from a push-button selector.
    @objc(resetAllControls:)
    private func resetAllControls(_ sender: Any?) {
        guard let actionAPI = apiManager.api(for: FxCustomParameterActionAPI_v4.self)
                as? FxCustomParameterActionAPI_v4,
              let settingAPI = apiManager.api(for: FxParameterSettingAPI_v5.self)
                as? FxParameterSettingAPI_v5 else { return }
        let actionSender: Any = sender ?? self
        let time = actionAPI.currentTime()
        actionAPI.startAction(actionSender)

        func setBool(_ id: UInt32, _ value: Bool) {
            _ = settingAPI.setBoolValue(value, toParameter: id, at: time)
        }
        func setFloat(_ id: UInt32, _ value: Double) {
            _ = settingAPI.setFloatValue(value, toParameter: id, at: time)
        }
        func setInt(_ id: UInt32, _ value: Int32) {
            _ = settingAPI.setIntValue(value, toParameter: id, at: time)
        }
        func setColor(_ id: UInt32, _ red: Double, _ green: Double, _ blue: Double) {
            _ = settingAPI.setRedValue(
                red,
                greenValue: green,
                blueValue: blue,
                toParameter: id,
                at: time
            )
        }

        setBool(CSTParameterID.inputDecodeEnabled, true)
        setInt(CSTParameterID.inputTransfer, Int32(CSTInputTransfer.rec709.rawValue))
        setBool(CSTParameterID.gamutTransformEnabled, true)
        setInt(CSTParameterID.sourcePrimaries, Int32(CSTSourcePrimaries.rec709.rawValue))
        setBool(CSTParameterID.gradeEnabled, true)
        setFloat(CSTParameterID.exposureStops, 0)
        setFloat(CSTParameterID.whiteBalanceTemperature, 0)
        setFloat(CSTParameterID.whiteBalanceTint, 0)
        setFloat(CSTParameterID.contrast, 1)
        setFloat(CSTParameterID.contrastPivot, 0.18)
        setFloat(CSTParameterID.shadows, 0)
        setFloat(CSTParameterID.highlights, 0)
        setFloat(CSTParameterID.saturation, 1)
        setFloat(CSTParameterID.colorBoost, 0)
        setFloat(CSTParameterID.hueRotation, 0)
        setColor(CSTParameterID.lift, 0.5, 0.5, 0.5)
        setColor(CSTParameterID.gamma, 0.5, 0.5, 0.5)
        setColor(CSTParameterID.gain, 0.5, 0.5, 0.5)
        setColor(CSTParameterID.offset, 0.5, 0.5, 0.5)
        setBool(CSTParameterID.toneMapEnabled, true)
        setInt(CSTParameterID.toneMap, Int32(CSTToneMap.reinhard.rawValue))
        setFloat(CSTParameterID.highlightKnee, 1)
        setBool(CSTParameterID.outputEncodeEnabled, true)
        setBool(CSTParameterID.displayReferred, false)
        _ = settingAPI.setCustomParameterValue(
            CSTLUTSelection.none(),
            toParameter: CSTParameterID.lutSelection,
            at: time
        )
        setBool(CSTParameterID.lutEnabled, true)
        setFloat(CSTParameterID.lutAmount, 1)
        setBool(CSTParameterID.globalBypass, false)

        actionAPI.endAction(actionSender)
        lutParameterViews.forEach { $0.setSelection(.none()) }
    }

    // MARK: Host properties and scheduling

    func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
        // Input transfer decoding is intentionally owned by the plugin, so ask
        // FCP for gamma-video pixels. FCP still chooses Rec.709 or Rec.2020
        // gamut from the project; pluginState reads that choice via
        // FxColorGamutAPI_v2 and performs the final host-boundary conversion.
        let values: [String: Any] = [
            kFxPropertyKey_MayRemapTime: NSNumber(booleanLiteral: false),
            kFxPropertyKey_NeedsFullBuffer: NSNumber(booleanLiteral: false),
            kFxPropertyKey_VariesWhenParamsAreStatic: NSNumber(booleanLiteral: false),
            kFxPropertyKey_ChangesOutputSize: NSNumber(booleanLiteral: false),
            kFxPropertyKey_PixelTransformSupport: NSNumber(value: kFxPixelTransform_ScaleTranslate),
            kFxPropertyKey_DesiredProcessingColorInfo: NSNumber(value: kFxImageColorInfo_RGB_GAMMA_VIDEO)
        ]
        properties?.pointee = NSDictionary(dictionary: values)
    }

    /// This colour effect needs exactly the current source frame. The request
    /// also asks FCP to include leading filters already applied upstream.
    ///
    /// The initializer and source constant are documented by Apple here:
    /// https://developer.apple.com/documentation/professional-video-applications/fxtileableeffect/scheduleinputs(_:withpluginstate:at:)
    func scheduleInputs(
        _ inputImageRequests: AutoreleasingUnsafeMutablePointer<NSArray?>?,
        withPluginState pluginState: Data?,
        at renderTime: CMTime
    ) throws {
        guard let request = FxImageTileRequest(
            source: kFxImageTileRequestSourceEffectClip,
            time: renderTime,
            includeFilters: true,
            parameterID: 0
        ) else {
            throw CSTGradeError("Could not create the source-frame request")
        }
        inputImageRequests?.pointee = NSArray(object: request)
    }

    func destinationImageRect(
        _ destinationImageRect: UnsafeMutablePointer<FxRect>,
        sourceImages: [FxImageTile],
        destinationImage: FxImageTile,
        pluginState: Data?,
        at renderTime: CMTime
    ) throws {
        guard let firstSource = sourceImages.first else {
            destinationImageRect.pointee = kFxRect_Empty
            return
        }
        destinationImageRect.pointee = firstSource.imagePixelBounds
    }

    func sourceTileRect(
        _ sourceTileRect: UnsafeMutablePointer<FxRect>,
        sourceImageIndex: UInt,
        sourceImages: [FxImageTile],
        destinationTileRect: FxRect,
        destinationImage: FxImageTile,
        pluginState: Data?,
        at renderTime: CMTime
    ) throws {
        // UNVERIFIED: confirm the generated Swift signature in the installed
        // FxTileableEffect.h. Apple’s Xcode-era FxPlug 4 examples use UInt
        // here (the Objective-C header uses NSUInteger).
        guard sourceImageIndex == 0 else {
            sourceTileRect.pointee = kFxRect_Empty
            return
        }
        // Every output pixel reads only the corresponding source pixel.
        sourceTileRect.pointee = destinationTileRect
    }

    // MARK: Plugin state

    func pluginState(
        _ pluginState: AutoreleasingUnsafeMutablePointer<NSData>?,
        at renderTime: CMTime,
        quality qualityLevel: UInt
    ) throws {
        // UNVERIFIED: confirm that the FxPlug 4.1 Swift importer exposes the
        // quality argument as UInt on the target SDK. Apple’s manual FxPlug 4
        // example uses UInt; the protocol documentation also names FxQuality.
        _ = qualityLevel
        guard let retrievalAPI = apiManager.api(for: FxParameterRetrievalAPI_v6.self)
                as? FxParameterRetrievalAPI_v6 else {
            throw CSTGradeError("FxParameterRetrievalAPI_v6 is unavailable")
        }

        let inputDecodeEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.inputDecodeEnabled, at: renderTime
        )
        let inputTransferValue = UInt32(clamping: intValue(
            retrievalAPI, parameterID: CSTParameterID.inputTransfer, at: renderTime,
            defaultValue: Int32(CSTInputTransfer.rec709.rawValue)
        ))
        let sourcePrimariesValue = UInt32(clamping: intValue(
            retrievalAPI, parameterID: CSTParameterID.sourcePrimaries, at: renderTime,
            defaultValue: Int32(CSTSourcePrimaries.rec709.rawValue)
        ))
        let sourcePrimaries = CSTSourcePrimaries(rawValue: sourcePrimariesValue) ?? .rec709
        let toneMapValue = UInt32(clamping: intValue(
            retrievalAPI, parameterID: CSTParameterID.toneMap, at: renderTime,
            defaultValue: Int32(CSTToneMap.reinhard.rawValue)
        ))

        let gamutEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.gamutTransformEnabled, at: renderTime
        )
        let gradeEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.gradeEnabled, at: renderTime
        )
        let toneMapEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.toneMapEnabled, at: renderTime
        )
        let outputEncodeEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.outputEncodeEnabled, at: renderTime
        )
        let displayReferred = boolValue(
            retrievalAPI, parameterID: CSTParameterID.displayReferred, at: renderTime
        )
        let lutEnabled = boolValue(
            retrievalAPI, parameterID: CSTParameterID.lutEnabled, at: renderTime
        )
        let globalBypass = boolValue(
            retrievalAPI, parameterID: CSTParameterID.globalBypass, at: renderTime
        )

        var customValue: (NSCopying & NSSecureCoding & NSObjectProtocol)?
        let hasCustomLUT = retrievalAPI.getCustomParameterValue(
            &customValue,
            fromParameter: CSTParameterID.lutSelection,
            at: renderTime
        )
        let lutSelection = hasCustomLUT
            ? (customValue as? CSTLUTSelection ?? .none())
            : .none()
        let requestedLUTAmount = floatValue(
            retrievalAPI, parameterID: CSTParameterID.lutAmount, at: renderTime, defaultValue: 1
        )
        let lutAmount = min(max(requestedLUTAmount, 0), 1)

        let sourceRows = CSTColorScience.sourceToWorking(sourcePrimaries).asMetalRows()
        let workingRows = CSTColorScience.workingToRec709.asMetalRows()

        // The host's working gamut is a project setting. The FxPlug colour
        // gamut API is the documented way to distinguish Rec.709 from wide
        // gamut Rec.2020. Do not silently assume Rec.709 when the API is
        // missing: that would write pixels in a possibly wrong host gamut.
        let projectIsRec2020: UInt32
        // UNVERIFIED: confirm FxColorGamutAPI_v2 and colorPrimaries() in the
        // exact FxPlug 4.1 headers. This is the latest API documented for the
        // Rec.709/Rec.2020 project-gamut query.
        guard let gamutAPI = apiManager.api(for: FxColorGamutAPI_v2.self) as? FxColorGamutAPI_v2 else {
            throw CSTGradeError("FxColorGamutAPI_v2 is unavailable; project gamut cannot be determined")
        }
        projectIsRec2020 = gamutAPI.colorPrimaries() == UInt(kFxColorPrimaries_Rec2020) ? 1 : 0
        let boundaryMatrix = projectIsRec2020 == 1
            ? CSTColorScience.rec709ToRec2020
            : CSTMatrix3x3.identity
        let boundaryRows = boundaryMatrix.asMetalRows()

        var uniforms = CSTUniforms()
        uniforms.sourceToWorkingRow0 = sourceRows.0
        uniforms.sourceToWorkingRow1 = sourceRows.1
        uniforms.sourceToWorkingRow2 = sourceRows.2
        uniforms.workingToRec709Row0 = workingRows.0
        uniforms.workingToRec709Row1 = workingRows.1
        uniforms.workingToRec709Row2 = workingRows.2
        uniforms.rec709ToProjectRow0 = boundaryRows.0
        uniforms.rec709ToProjectRow1 = boundaryRows.1
        uniforms.rec709ToProjectRow2 = boundaryRows.2

        uniforms.exposureStops = floatValue(
            retrievalAPI, parameterID: CSTParameterID.exposureStops, at: renderTime, defaultValue: 0
        )
        uniforms.temperature = floatValue(
            retrievalAPI, parameterID: CSTParameterID.whiteBalanceTemperature, at: renderTime, defaultValue: 0
        )
        uniforms.tint = floatValue(
            retrievalAPI, parameterID: CSTParameterID.whiteBalanceTint, at: renderTime, defaultValue: 0
        )
        uniforms.contrast = floatValue(
            retrievalAPI, parameterID: CSTParameterID.contrast, at: renderTime, defaultValue: 1
        )
        uniforms.saturation = floatValue(
            retrievalAPI, parameterID: CSTParameterID.saturation, at: renderTime, defaultValue: 1
        )
        uniforms.pivot = floatValue(
            retrievalAPI, parameterID: CSTParameterID.contrastPivot, at: renderTime, defaultValue: 0.18
        )
        uniforms.highlightKnee = floatValue(
            retrievalAPI, parameterID: CSTParameterID.highlightKnee, at: renderTime, defaultValue: 1
        )
        uniforms.outputGamma = 2.4
        uniforms.colorBoost = floatValue(
            retrievalAPI, parameterID: CSTParameterID.colorBoost, at: renderTime, defaultValue: 0
        )
        uniforms.hueRotation = floatValue(
            retrievalAPI, parameterID: CSTParameterID.hueRotation, at: renderTime, defaultValue: 0
        )
        uniforms.shadows = floatValue(
            retrievalAPI, parameterID: CSTParameterID.shadows, at: renderTime, defaultValue: 0
        )
        uniforms.highlights = floatValue(
            retrievalAPI, parameterID: CSTParameterID.highlights, at: renderTime, defaultValue: 0
        )
        uniforms.liftControl = colorValue(
            retrievalAPI, parameterID: CSTParameterID.lift, at: renderTime
        )
        uniforms.gammaControl = colorValue(
            retrievalAPI, parameterID: CSTParameterID.gamma, at: renderTime
        )
        uniforms.gainControl = colorValue(
            retrievalAPI, parameterID: CSTParameterID.gain, at: renderTime
        )
        uniforms.offsetControl = colorValue(
            retrievalAPI, parameterID: CSTParameterID.offset, at: renderTime
        )

        // Resolve and parse the selected file while the host APIs are legal.
        // The parsed value enters the bounded process cache here; the render
        // callback only uses the content key to find a GPU texture.
        var lutDimension: Float = 0
        var lutIsValid: Float = 0
        if lutEnabled && lutAmount > 0 && lutSelection.identifier != 0 {
            do {
                if let parsed = try CSTLUTLibraryStore.shared.parsedLUT(for: lutSelection) {
                    lutDimension = Float(parsed.dimension)
                    lutIsValid = 1
                }
            } catch {
                // Invalid, missing, moved, or changed files fail closed to the
                // clean pre-LUT value. The custom browser reports the issue;
                // this path must never substitute a different LUT in a render.
            }
        }
        uniforms.lutParameters = SIMD4(
            lutAmount,
            lutDimension,
            lutIsValid,
            lutEnabled ? 1 : 0
        )
        uniforms.lutKey = SIMD4(
            UInt32(truncatingIfNeeded: lutSelection.identifier),
            UInt32(truncatingIfNeeded: lutSelection.identifier >> 32),
            0,
            0
        )

        var stageFlags: UInt32 = 0
        if inputDecodeEnabled { stageFlags |= CSTStageBit.inputDecode }
        if gamutEnabled { stageFlags |= CSTStageBit.gamutTransform }
        if gradeEnabled { stageFlags |= CSTStageBit.grade }
        if toneMapEnabled { stageFlags |= CSTStageBit.toneMap }
        if outputEncodeEnabled { stageFlags |= CSTStageBit.outputEncode }
        if displayReferred { stageFlags |= CSTStageBit.displayReferred }
        if globalBypass { stageFlags |= CSTStageBit.globalBypass }
        uniforms.stageFlags = stageFlags
        uniforms.inputTransfer = inputTransferValue
        uniforms.toneMap = toneMapValue
        uniforms.projectIsRec2020 = projectIsRec2020

        // The host retains a new NSData object. Never cache and reuse this
        // object: Apple explicitly permits concurrent pluginState calls.
        var state = uniforms
        let stateData = Data(bytes: &state, count: MemoryLayout<CSTUniforms>.stride)
        pluginState?.pointee = stateData as NSData
    }

    // MARK: Metal render

    func renderDestinationImage(
        _ destinationImage: FxImageTile,
        sourceImages: [FxImageTile],
        pluginState: Data?,
        at renderTime: CMTime
    ) throws {
        _ = renderTime
        guard let sourceImage = sourceImages.first else {
            throw CSTGradeError("CST Grade received no source image")
        }
        guard let pluginState else {
            throw CSTGradeError("CST Grade received no plugin state")
        }

        var uniforms = try decodeUniforms(from: pluginState)
        let resources = try resourcesForDevice(registryID: destinationImage.deviceRegistryID)
        guard let sourceTexture = sourceImage.metalTexture(for: resources.device) else {
            throw CSTGradeError("Could not create Metal source texture from FxImageTile")
        }
        guard let destinationTexture = destinationImage.metalTexture(for: resources.device) else {
            throw CSTGradeError("Could not create Metal destination texture from FxImageTile")
        }

        let lutIdentifier = UInt64(uniforms.lutKey.x)
            | (UInt64(uniforms.lutKey.y) << 32)
        let lutGPU = try resources.textureForLUT(identifier: lutIdentifier)
        if !lutGPU.valid {
            // A state blob can outlive a process-local cache entry after an
            // XPC restart. Fail closed instead of sampling an identity texture
            // while claiming that a user LUT is valid.
            uniforms.lutParameters.z = 0
        }

        uniforms.sourceOriginX = Int32(sourceImage.tilePixelBounds.left)
        uniforms.sourceOriginY = Int32(sourceImage.tilePixelBounds.bottom)
        uniforms.destinationOriginX = Int32(destinationImage.tilePixelBounds.left)
        uniforms.destinationOriginY = Int32(destinationImage.tilePixelBounds.bottom)

        guard let commandBuffer = resources.commandQueue.makeCommandBuffer() else {
            throw CSTGradeError("Could not create Metal command buffer")
        }
        commandBuffer.label = "CST Grade single-pass compute"
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw CSTGradeError("Could not create Metal compute encoder")
        }

        encoder.setComputePipelineState(resources.pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        encoder.setTexture(lutGPU.texture, index: 2)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CSTUniforms>.stride,
            index: 0
        )

        let grid = MTLSize(width: destinationTexture.width, height: destinationTexture.height, depth: 1)
        let threadWidth = max(1, resources.pipeline.threadExecutionWidth)
        let threadHeight = max(
            1,
            resources.pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        let group = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()

        commandBuffer.commit()
        // The FxPlug render callback must not return while the host can still
        // consume an IOSurface that this command buffer is writing. This wait
        // trades CPU/GPU overlap for deterministic correctness on the target's
        // low-power Intel GPU; the effect remains a single bandwidth pass.
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status == .error {
            throw commandBuffer.error ?? CSTGradeError("Metal command buffer failed")
        }
    }

    // MARK: Parameter retrieval helpers

    private func floatValue(
        _ api: FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        at time: CMTime,
        defaultValue: Double
    ) -> Float {
        var value = defaultValue
        _ = api.getFloatValue(&value, fromParameter: parameterID, at: time)
        return Float(value)
    }

    private func intValue(
        _ api: FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        at time: CMTime,
        defaultValue: Int32
    ) -> Int32 {
        var value = defaultValue
        _ = api.getIntValue(&value, fromParameter: parameterID, at: time)
        return value
    }

    private func boolValue(
        _ api: FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        at time: CMTime
    ) -> Bool {
        // FxParameterRetrievalAPI_v6 imports Objective-C BOOL* as ObjCBool*;
        // using a Swift Bool pointer is not ABI-compatible with that method.
        var value: ObjCBool = false
        _ = api.getBoolValue(&value, fromParameter: parameterID, at: time)
        return value.boolValue
    }

    private func colorValue(
        _ api: FxParameterRetrievalAPI_v6,
        parameterID: UInt32,
        at time: CMTime
    ) -> SIMD4<Float> {
        var red = 0.5
        var green = 0.5
        var blue = 0.5
        _ = api.getRedValue(
            &red,
            greenValue: &green,
            blueValue: &blue,
            fromParameter: parameterID,
            at: time
        )
        return SIMD4(Float(red), Float(green), Float(blue), 1.0)
    }

    // MARK: State/Metal helpers

    private func decodeUniforms(from data: Data) throws -> CSTUniforms {
        guard data.count >= MemoryLayout<CSTUniforms>.stride else {
            throw CSTGradeError("CST Grade plugin state has the wrong size")
        }
        var result = CSTUniforms()
        _ = withUnsafeMutableBytes(of: &result) { destination in
            data.copyBytes(to: destination, count: MemoryLayout<CSTUniforms>.stride)
        }
        return result
    }

    private func resourcesForDevice(registryID: UInt64) throws -> CSTMetalResources {
        metalResourcesLock.lock()
        defer { metalResourcesLock.unlock() }
        if let existing = metalResources[registryID] {
            return existing
        }

        // FxImageTile documents deviceRegistryID as the registry ID of the
        // Metal device that owns its IOSurface texture. Matching it matters on
        // Macs with more than one Metal device; the target Mac normally has a
        // single integrated GPU.
        let device = MTLCopyAllDevices().first(where: { $0.registryID == registryID })
            ?? MTLCreateSystemDefaultDevice()
        guard let device else {
            throw CSTGradeError("No Metal device is available")
        }
        let created = try CSTMetalResources(device: device)
        metalResources[registryID] = created
        return created
    }
}
