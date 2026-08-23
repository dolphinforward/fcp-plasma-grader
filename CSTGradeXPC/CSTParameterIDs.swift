//
// CSTParameterIDs.swift
//
// This file is part of the on-disk project compatibility contract.
//
// NEVER CHANGE, REUSE, OR REORDER THESE PARAMETER IDs.
// Final Cut Pro stores parameter values by integer ID in its projects. A later
// build that changes an ID silently reads an old control as a different control.
// If a control must be retired, leave its number unused. New controls must use
// new numbers in the range 1...9998. These numbers are deliberately declared in
// one place so an accidental renumbering is difficult.
//
// Apple reference: FxParameterCreationAPI_v5 explains that parameter IDs are
// persisted in project files and must not be changed between plug-in versions.
// https://developer.apple.com/documentation/professional-video-applications/fxparametercreationapi_v5
//

import Foundation

enum CSTParameterID {
    // Input decode stage.
    static let inputDecodeEnabled: UInt32 = 1
    static let inputTransfer: UInt32 = 2

    // Gamut transform stage.
    static let gamutTransformEnabled: UInt32 = 3
    static let sourcePrimaries: UInt32 = 4

    // Linear-light grade stage.
    static let gradeEnabled: UInt32 = 5
    static let exposureStops: UInt32 = 6
    static let whiteBalanceTemperature: UInt32 = 7
    static let whiteBalanceTint: UInt32 = 8
    static let contrast: UInt32 = 9
    static let saturation: UInt32 = 10
    static let lift: UInt32 = 11
    static let gamma: UInt32 = 12
    static let gain: UInt32 = 13

    // Tone-map stage.
    static let toneMapEnabled: UInt32 = 14
    static let toneMap: UInt32 = 15
    static let highlightKnee: UInt32 = 16

    // Output stage.
    static let outputEncodeEnabled: UInt32 = 17
    static let displayReferred: UInt32 = 18

    // Creative Rec.709 display-LUT stage. These IDs were added without
    // changing any existing number; existing CST projects remain compatible.
    static let lutSelection: UInt32 = 19
    static let lutEnabled: UInt32 = 20
    static let lutAmount: UInt32 = 21

    // Whole-effect utility controls.
    static let globalBypass: UInt32 = 22
    static let resetAll: UInt32 = 23

    // Parameter subgroup IDs. These are host-visible parameter IDs too: keep
    // them stable for the same reason as the controls above. They intentionally
    // occupy new numbers after the v1 controls rather than reusing a control ID.
    static let inputDecodeGroup: UInt32 = 24
    static let gamutTransformGroup: UInt32 = 25
    static let linearGradeGroup: UInt32 = 26
    static let toneMapGroup: UInt32 = 27
    static let outputEncodeGroup: UInt32 = 28
    static let creativeLUTGroup: UInt32 = 29
    static let utilityGroup: UInt32 = 30
}

// Popup values are also persisted as integers. They are part of the same
// compatibility contract: append new modes; do not change the existing order.
enum CSTInputTransfer: UInt32 {
    case rec709 = 0
    case sLog3 = 1
    case vLog = 2
    case logC3EI800 = 3
    case gamma22 = 4
}

enum CSTSourcePrimaries: UInt32 {
    case sGamut3Cine = 0
    case vGamut = 1
    case arriWideGamut = 2
    case rec709 = 3
    case rec2020 = 4
}

enum CSTToneMap: UInt32 {
    case none = 0
    case reinhard = 1
    case filmic = 2
}

enum CSTStageBit {
    static let inputDecode: UInt32 = 1 << 0
    static let gamutTransform: UInt32 = 1 << 1
    static let grade: UInt32 = 1 << 2
    static let toneMap: UInt32 = 1 << 3
    static let outputEncode: UInt32 = 1 << 4
    static let displayReferred: UInt32 = 1 << 5
    static let globalBypass: UInt32 = 1 << 6
}
