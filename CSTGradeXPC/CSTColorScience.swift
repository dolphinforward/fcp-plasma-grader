//
// CSTColorScience.swift
//
// CPU-side colour science. This file intentionally derives RGB↔XYZ matrices
// from chromaticities instead of embedding unexplained 3x3 constants.
//
// The working space is fixed to linear Rec.2020 with a D65 white point. The
// shader receives source→working, working→Rec.709, and Rec.709→project-gamut
// matrices generated here for each plugin state.
//
// Primary/white-point sources:
//   Rec.709 chromaticities: Apple QuickTime color parameter atom
//   https://developer.apple.com/documentation/quicktime-file-format/color_parameter_atom
//   Rec.2020 chromaticities: ITU-R BT.2020
//   https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2020-0-201208-S!!PDF-E.pdf
//   S-Gamut3.Cine chromaticities: Sony S-Gamut3/S-Log3 technical summary
//   https://pro.sony/s3/cms-static-content/uploadfile/06/1237494271406.pdf
//   V-Gamut chromaticities: Panasonic V-Log/V-Gamut technical information
//   https://pro-av.panasonic.net/jp/cinema_camera_varicam_eva/support/pdf/VARICAM_V-Log_V-Gamut.pdf
//   ARRI Wide Gamut chromaticities: ARRI LogC3 curve/data document
//   https://www.arri.com/resource/blob/31918/66f56e6abb6e5b6553929edf9aa7483e/2017-03-alexa-logc-curve-in-vfx-data.pdf
//
// All listed camera spaces use D65 here. No chromatic adaptation is therefore
// required before the RGB→XYZ→RGB conversion. If a future space has another
// white point, adaptation must be added explicitly; do not silently reuse this
// same-white-point derivation.

import Foundation
import simd

struct CSTChromaticities {
    let red: SIMD2<Double>
    let green: SIMD2<Double>
    let blue: SIMD2<Double>
    let white: SIMD2<Double>
}

/// A small, explicit row-major 3x3 matrix used only on the CPU.
/// Metal receives rows as three float4 values, avoiding float3 alignment traps.
struct CSTMatrix3x3 {
    var m00: Double
    var m01: Double
    var m02: Double
    var m10: Double
    var m11: Double
    var m12: Double
    var m20: Double
    var m21: Double
    var m22: Double

    static let identity = CSTMatrix3x3(
        m00: 1, m01: 0, m02: 0,
        m10: 0, m11: 1, m12: 0,
        m20: 0, m21: 0, m22: 1
    )

    init(
        m00: Double, m01: Double, m02: Double,
        m10: Double, m11: Double, m12: Double,
        m20: Double, m21: Double, m22: Double
    ) {
        self.m00 = m00
        self.m01 = m01
        self.m02 = m02
        self.m10 = m10
        self.m11 = m11
        self.m12 = m12
        self.m20 = m20
        self.m21 = m21
        self.m22 = m22
    }

    init(columns: SIMD3<Double>...) {
        precondition(columns.count == 3)
        self.init(
            m00: columns[0].x, m01: columns[1].x, m02: columns[2].x,
            m10: columns[0].y, m11: columns[1].y, m12: columns[2].y,
            m20: columns[0].z, m21: columns[1].z, m22: columns[2].z
        )
    }

    func multiplied(by other: CSTMatrix3x3) -> CSTMatrix3x3 {
        CSTMatrix3x3(
            m00: m00 * other.m00 + m01 * other.m10 + m02 * other.m20,
            m01: m00 * other.m01 + m01 * other.m11 + m02 * other.m21,
            m02: m00 * other.m02 + m01 * other.m12 + m02 * other.m22,
            m10: m10 * other.m00 + m11 * other.m10 + m12 * other.m20,
            m11: m10 * other.m01 + m11 * other.m11 + m12 * other.m21,
            m12: m10 * other.m02 + m11 * other.m12 + m12 * other.m22,
            m20: m20 * other.m00 + m21 * other.m10 + m22 * other.m20,
            m21: m20 * other.m01 + m21 * other.m11 + m22 * other.m21,
            m22: m20 * other.m02 + m21 * other.m12 + m22 * other.m22
        )
    }

    func multiply(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            m00 * vector.x + m01 * vector.y + m02 * vector.z,
            m10 * vector.x + m11 * vector.y + m12 * vector.z,
            m20 * vector.x + m21 * vector.y + m22 * vector.z
        )
    }

    /// Returns nil only for a singular matrix. The source primary sets here
    /// are well-conditioned, but failing loudly is safer than uploading NaNs.
    func inverted() -> CSTMatrix3x3? {
        let c00 = m11 * m22 - m12 * m21
        let c01 = -(m10 * m22 - m12 * m20)
        let c02 = m10 * m21 - m11 * m20
        let c10 = -(m01 * m22 - m02 * m21)
        let c11 = m00 * m22 - m02 * m20
        let c12 = -(m00 * m21 - m01 * m20)
        let c20 = m01 * m12 - m02 * m11
        let c21 = -(m00 * m12 - m02 * m10)
        let c22 = m00 * m11 - m01 * m10

        let determinant = m00 * c00 + m01 * c01 + m02 * c02
        guard abs(determinant) > 1.0e-12 else { return nil }
        let inverseDeterminant = 1.0 / determinant

        // Transpose of the cofactor matrix divided by the determinant.
        return CSTMatrix3x3(
            m00: c00 * inverseDeterminant,
            m01: c10 * inverseDeterminant,
            m02: c20 * inverseDeterminant,
            m10: c01 * inverseDeterminant,
            m11: c11 * inverseDeterminant,
            m12: c21 * inverseDeterminant,
            m20: c02 * inverseDeterminant,
            m21: c12 * inverseDeterminant,
            m22: c22 * inverseDeterminant
        )
    }

    func asMetalRows() -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        (
            SIMD4(Float(m00), Float(m01), Float(m02), 0),
            SIMD4(Float(m10), Float(m11), Float(m12), 0),
            SIMD4(Float(m20), Float(m21), Float(m22), 0)
        )
    }
}

enum CSTColorScience {
    static let d65 = SIMD2<Double>(0.3127, 0.3290)

    static let rec709 = CSTChromaticities(
        red: SIMD2(0.640, 0.330),
        green: SIMD2(0.300, 0.600),
        blue: SIMD2(0.150, 0.060),
        white: d65
    )

    static let rec2020 = CSTChromaticities(
        red: SIMD2(0.708, 0.292),
        green: SIMD2(0.170, 0.797),
        blue: SIMD2(0.131, 0.046),
        white: d65
    )

    static let sGamut3Cine = CSTChromaticities(
        red: SIMD2(0.766, 0.275),
        green: SIMD2(0.225, 0.800),
        blue: SIMD2(0.089, -0.087),
        white: d65
    )

    static let vGamut = CSTChromaticities(
        red: SIMD2(0.730, 0.280),
        green: SIMD2(0.165, 0.840),
        blue: SIMD2(0.100, -0.030),
        white: d65
    )

    static let arriWideGamut = CSTChromaticities(
        red: SIMD2(0.6840, 0.3130),
        green: SIMD2(0.2210, 0.8480),
        blue: SIMD2(0.0861, -0.1020),
        white: d65
    )

    /// Derives RGB→XYZ using the standard primary/white-point construction:
    ///
    ///   1. For each primary (x,y), form an unscaled XYZ column
    ///      (x/y, 1, (1-x-y)/y).
    ///   2. Solve the 3x3 system M * scale = XYZ_white.
    ///   3. Scale each primary column by its solved white-point scale.
    ///
    /// This is the derivation used instead of storing a precomputed matrix.
    static func rgbToXYZ(_ chromaticities: CSTChromaticities) -> CSTMatrix3x3 {
        let r = SIMD3(
            chromaticities.red.x / chromaticities.red.y,
            1.0,
            (1.0 - chromaticities.red.x - chromaticities.red.y) / chromaticities.red.y
        )
        let g = SIMD3(
            chromaticities.green.x / chromaticities.green.y,
            1.0,
            (1.0 - chromaticities.green.x - chromaticities.green.y) / chromaticities.green.y
        )
        let b = SIMD3(
            chromaticities.blue.x / chromaticities.blue.y,
            1.0,
            (1.0 - chromaticities.blue.x - chromaticities.blue.y) / chromaticities.blue.y
        )

        let unscaled = CSTMatrix3x3(columns: r, g, b)
        let whiteXYZ = SIMD3(
            chromaticities.white.x / chromaticities.white.y,
            1.0,
            (1.0 - chromaticities.white.x - chromaticities.white.y) / chromaticities.white.y
        )
        guard let scale = unscaled.inverted()?.multiply(whiteXYZ) else {
            preconditionFailure("Singular RGB primary matrix")
        }

        return CSTMatrix3x3(columns: r * scale.x, g * scale.y, b * scale.z)
    }

    static func xyzToRGB(_ chromaticities: CSTChromaticities) -> CSTMatrix3x3 {
        guard let inverse = rgbToXYZ(chromaticities).inverted() else {
            preconditionFailure("Singular RGB-to-XYZ matrix")
        }
        return inverse
    }

    static func sourceToWorking(_ source: CSTSourcePrimaries) -> CSTMatrix3x3 {
        let sourcePrimaries: CSTChromaticities
        switch source {
        case .sGamut3Cine: sourcePrimaries = sGamut3Cine
        case .vGamut: sourcePrimaries = vGamut
        case .arriWideGamut: sourcePrimaries = arriWideGamut
        case .rec709: sourcePrimaries = rec709
        case .rec2020: sourcePrimaries = rec2020
        }

        // RGB_source → XYZ → RGB_linear_Rec2020.
        return xyzToRGB(rec2020).multiplied(by: rgbToXYZ(sourcePrimaries))
    }

    static let workingToRec709: CSTMatrix3x3 =
        xyzToRGB(rec709).multiplied(by: rgbToXYZ(rec2020))

    static let rec709ToRec2020: CSTMatrix3x3 =
        xyzToRGB(rec2020).multiplied(by: rgbToXYZ(rec709))
}
