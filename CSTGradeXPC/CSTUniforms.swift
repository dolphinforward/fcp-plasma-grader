//
// CSTUniforms.swift
//
// This structure must remain byte-for-byte identical to CSTUniforms in
// CSTShaders.metal. It deliberately uses SIMD4<Float> for every vector and
// only 32-bit scalar fields after the vectors. That gives Metal and Swift the
// same 16-byte vector alignment and avoids a float3/packed-struct mismatch.
//
// The three matrices are stored as rows:
//   sourceToWorking: source primaries -> fixed linear Rec.2020
//   workingToRec709: fixed linear Rec.2020 -> linear Rec.709
//   rec709ToProject: Rec.709 -> the host's project gamut for the final host
//                    boundary conversion (identity for a Rec.709 project)
// The LUT parameter vector is (amount, dimension, valid, enabled). The LUT key
// is two UInt32 halves of the FNV-1a-64 content hash. The key is not used by
// Metal; it lets the render callback select the cached 3D texture belonging to
// this immutable plugin state without reading the filesystem. With 15 vectors,
// 12 floats, 4 UInt32s, and 4 Int32s, the matching structs are 320 bytes.

import simd

struct CSTUniforms {
    var sourceToWorkingRow0 = SIMD4<Float>(repeating: 0)
    var sourceToWorkingRow1 = SIMD4<Float>(repeating: 0)
    var sourceToWorkingRow2 = SIMD4<Float>(repeating: 0)

    var workingToRec709Row0 = SIMD4<Float>(repeating: 0)
    var workingToRec709Row1 = SIMD4<Float>(repeating: 0)
    var workingToRec709Row2 = SIMD4<Float>(repeating: 0)

    var rec709ToProjectRow0 = SIMD4<Float>(repeating: 0)
    var rec709ToProjectRow1 = SIMD4<Float>(repeating: 0)
    var rec709ToProjectRow2 = SIMD4<Float>(repeating: 0)

    // Grade colour controls are numeric triples, not colour swatches. The
    // DONT_REMAP_COLORS flag makes the host deliver these values verbatim.
    var liftControl = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
    var gammaControl = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
    var gainControl = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
    var offsetControl = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
    var lutParameters = SIMD4<Float>(0, 0, 0, 0)
    var lutKey = SIMD4<UInt32>(0, 0, 0, 0)

    var exposureStops: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var pivot: Float = 0.18
    var highlightKnee: Float = 1
    var outputGamma: Float = 2.4
    var colorBoost: Float = 0
    var hueRotation: Float = 0
    var shadows: Float = 0
    var highlights: Float = 0

    var stageFlags: UInt32 = 0
    var inputTransfer: UInt32 = CSTInputTransfer.rec709.rawValue
    var toneMap: UInt32 = CSTToneMap.reinhard.rawValue
    var projectIsRec2020: UInt32 = 0

    // Full-image pixel coordinates of the local IOSurface tiles. Colour math
    // is position independent, but these origins are needed when the host
    // supplies source and destination tiles with different local rectangles.
    var sourceOriginX: Int32 = 0
    var sourceOriginY: Int32 = 0
    var destinationOriginX: Int32 = 0
    var destinationOriginY: Int32 = 0
}
