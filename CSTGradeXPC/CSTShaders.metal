//
// CSTShaders.metal
//
// One kernel performs the complete pixel chain. There are no intermediate
// textures and no second render/compute pass. Values stay float and are not
// clamped between stages. Only a successful output encode clamps to [0, 1].
//
// Uniform layout must match CSTUniforms.swift exactly: 14 vector values
// (the last is uint4), followed by 8 float values, 4 uint values, and 4 int
// values (288 bytes with the 16-byte vector alignment used by both languages).
//

#include <metal_stdlib>
using namespace metal;

struct CSTUniforms {
    float4 sourceToWorkingRow0;
    float4 sourceToWorkingRow1;
    float4 sourceToWorkingRow2;

    float4 workingToRec709Row0;
    float4 workingToRec709Row1;
    float4 workingToRec709Row2;

    float4 rec709ToProjectRow0;
    float4 rec709ToProjectRow1;
    float4 rec709ToProjectRow2;

    float4 liftControl;
    float4 gammaControl;
    float4 gainControl;
    float4 lutParameters;
    uint4 lutKey;

    float exposureStops;
    float temperature;
    float tint;
    float contrast;
    float saturation;
    float pivot;
    float highlightKnee;
    float outputGamma;

    uint stageFlags;
    uint inputTransfer;
    uint toneMap;
    uint projectIsRec2020;

    int sourceOriginX;
    int sourceOriginY;
    int destinationOriginX;
    int destinationOriginY;
};

constant uint kStageInputDecode = 1u << 0;
constant uint kStageGamut = 1u << 1;
constant uint kStageGrade = 1u << 2;
constant uint kStageToneMap = 1u << 3;
constant uint kStageOutputEncode = 1u << 4;
constant uint kStageDisplayReferred = 1u << 5;
constant uint kStageGlobalBypass = 1u << 6;

inline bool stageIsEnabled(uint flags, uint bit) {
    return (flags & bit) != 0u;
}

inline float signedPower(float value, float exponent) {
    // A signed extension lets negative/out-of-gamut values survive the
    // pipeline instead of producing NaNs from pow(negative, fractional).
    float sign = value < 0.0f ? -1.0f : 1.0f;
    return sign * pow(abs(value), exponent);
}

inline float3 signedPower(float3 value, float3 exponent) {
    return float3(
        signedPower(value.x, exponent.x),
        signedPower(value.y, exponent.y),
        signedPower(value.z, exponent.z)
    );
}

inline float3 multiplyRows(float4 row0, float4 row1, float4 row2, float3 value) {
    return float3(
        dot(row0.xyz, value),
        dot(row1.xyz, value),
        dot(row2.xyz, value)
    );
}

// -------------------------------------------------------------------------
// Input transfer functions
// -------------------------------------------------------------------------

inline float decodeRec709(float encoded) {
    // Inverse of the piecewise BT.709 OETF, normalized to [0,1]. The
    // threshold is 0.081 encoded / 0.018 linear. The curve is specified by
    // ITU-R BT.709; the normalized form is also described by Apple colour
    // management documentation.
    // https://www.itu.int/rec/R-REC-BT.709
    return encoded <= 0.081f
        ? encoded / 4.5f
        : signedPower((encoded + 0.099f) / 1.099f, 1.0f / 0.45f);
}

inline float decodeGamma22(float encoded) {
    // Plain power-law input. This is intentionally not an sRGB/BT.709 curve.
    return signedPower(encoded, 2.2f);
}

inline float decodeSLog3(float encoded) {
    // Sony S-Log3 inverse, with the texture's normalized value converted to a
    // 10-bit code value. Constants are from Sony's S-Log3 technical summary:
    //   https://download.pro.sony/FNGP/protein/1237494271390/1237494271406.pdf
    // The formula maps the nominal 18% gray code value 420 to 0.18. It assumes
    // full-range normalized code values; legal-range scaling is not guessed.
    const float code = encoded * 1023.0f;
    const float threshold = 171.2102946929f;
    if (code >= threshold) {
        return pow(10.0f, (code - 420.0f) / 261.5f) * 0.19f - 0.01f;
    }
    return (code - 95.0f) * 0.01125f / (threshold - 95.0f);
}

inline float decodeVLog(float encoded) {
    // Panasonic V-Log inverse. Constants are from Panasonic's V-Log/V-Gamut
    // technical document:
    // https://pro-av.panasonic.net/jp/cinema_camera_varicam_eva/support/pdf/VARICAM_V-Log_V-Gamut.pdf
    // The low branch remains linear for negative extended-range values.
    const float cut = 0.181f;
    const float b = 0.00873f;
    const float c = 0.241514f;
    const float d = 0.598206f;
    return encoded < cut
        ? (encoded - 0.125f) / 5.6f
        : pow(10.0f, (encoded - d) / c) - b;
}

inline float decodeLogC3EI800(float encoded) {
    // ARRI LogC3 inverse, using the EI 800 parameter set because the requested
    // UI has one LogC3 entry and no exposure-index control. ARRI's document
    // gives the general curve and the EI 800 values used here:
    // https://www.arri.com/resource/blob/31918/66f56e6abb6e5b6553929edf9aa7483e/2017-03-alexa-logc-curve-in-vfx-data.pdf
    const float cut = 0.010591f;
    const float a = 5.555556f;
    const float b = 0.052272f;
    const float c = 0.247190f;
    const float d = 0.385537f;
    const float e = 5.367655f;
    const float f = 0.092809f;
    const float threshold = e * cut + f;
    return encoded > threshold
        ? (pow(10.0f, (encoded - d) / c) - b) / a
        : (encoded - f) / e;
}

inline float3 decodeInput(float3 encoded, uint transfer) {
    switch (transfer) {
        case 1u: return float3(decodeSLog3(encoded.x), decodeSLog3(encoded.y), decodeSLog3(encoded.z));
        case 2u: return float3(decodeVLog(encoded.x), decodeVLog(encoded.y), decodeVLog(encoded.z));
        case 3u: return float3(decodeLogC3EI800(encoded.x), decodeLogC3EI800(encoded.y), decodeLogC3EI800(encoded.z));
        case 4u: return float3(decodeGamma22(encoded.x), decodeGamma22(encoded.y), decodeGamma22(encoded.z));
        case 0u:
        default:
            return float3(decodeRec709(encoded.x), decodeRec709(encoded.y), decodeRec709(encoded.z));
    }
}

// -------------------------------------------------------------------------
// Linear grade and tone mapping
// -------------------------------------------------------------------------

inline float3 applyWhiteBalance(float3 rgb, float temperature, float tint) {
    // This is a neutral-preserving artistic gain model in linear light. It is
    // intentionally documented rather than pretending to be a camera CAT:
    // temperature moves red/blue in opposite directions and tint moves green
    // against the red/blue pair. The controls are normalized [-1,1].
    float3 gains = exp2(float3(
        0.25f * temperature + 0.10f * tint,
        -0.20f * tint,
        -0.25f * temperature + 0.10f * tint
    ));
    return rgb * gains;
}

inline float3 applySaturation(float3 rgb, float saturation) {
    // Rec.2020 luma coefficients (the Y row implied by BT.2020 primaries).
    // https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2020-0-201208-S!!PDF-E.pdf
    float luma = dot(rgb, float3(0.2627f, 0.6780f, 0.0593f));
    return luma + (rgb - luma) * saturation;
}

inline float3 applyGrade(float3 rgb, constant CSTUniforms &u) {
    rgb *= exp2(u.exposureStops);
    rgb = applyWhiteBalance(rgb, u.temperature, u.tint);
    rgb = (rgb - u.pivot) * u.contrast + u.pivot;
    rgb = applySaturation(rgb, u.saturation);

    // Lift is an offset of +/-0.1 around the neutral UI value 0.5. Gamma is a
    // signed power exponent (neutral 1.0 at 0.5). Gain is a multiplicative
    // factor (neutral 1.0 at 0.5). No clamp occurs here.
    float3 lift = (u.liftControl.xyz - 0.5f) * 0.20f;
    float3 gammaExponent = exp2(0.5f - u.gammaControl.xyz);
    float3 gain = exp2((u.gainControl.xyz - 0.5f) * 2.0f);
    rgb += lift;
    rgb = signedPower(rgb, gammaExponent);
    rgb *= gain;
    return rgb;
}

inline float3 applyReinhard(float3 rgb, float knee) {
    // A knee value of 1.0 maps +1.0 to 0.5. Signed form preserves negative
    // extended values until the final output encode.
    float safeKnee = max(knee, 0.0001f);
    return rgb / (1.0f + abs(rgb) / safeKnee);
}

inline float hableCurve(float x) {
    // Uncharted 2/Hable filmic curve constants. They are the published tone
    // mapping fit, not camera primaries:
    // https://www.gdcvault.com/play/1012351/Uncharted-2-HDR
    const float A = 0.15f;
    const float B = 0.50f;
    const float C = 0.10f;
    const float D = 0.20f;
    const float E = 0.02f;
    const float F = 0.30f;
    return ((x * (A * x + C * B) + D * E) /
            (x * (A * x + B) + D * F)) - E / F;
}

inline float3 applyFilmic(float3 rgb, float knee) {
    const float whitePoint = hableCurve(11.2f);
    float safeKnee = max(knee, 0.0001f);
    float3 magnitude = abs(rgb) / safeKnee;
    float3 mapped = float3(
        hableCurve(magnitude.x) / whitePoint,
        hableCurve(magnitude.y) / whitePoint,
        hableCurve(magnitude.z) / whitePoint
    );
    float3 sign = float3(
        rgb.x < 0.0f ? -1.0f : 1.0f,
        rgb.y < 0.0f ? -1.0f : 1.0f,
        rgb.z < 0.0f ? -1.0f : 1.0f
    );
    return sign * mapped;
}

inline float3 applyToneMap(float3 rgb, uint mode, float knee) {
    switch (mode) {
        case 1u: return applyReinhard(rgb, knee);
        case 2u: return applyFilmic(rgb, knee);
        case 0u:
        default: return rgb;
    }
}

// -------------------------------------------------------------------------
// Output transfer functions
// -------------------------------------------------------------------------

inline float encodeRec709(float linear) {
    // BT.709 OETF. The linear segment is 4.5*L up to L=0.018; the power
    // segment uses gamma 1/0.45. This function does not clamp.
    return linear <= 0.018f
        ? 4.5f * linear
        : 1.099f * signedPower(linear, 0.45f) - 0.099f;
}

inline float3 encodeDisplayGamma24(float3 linear, float gamma) {
    return float3(
        signedPower(linear.x, 1.0f / gamma),
        signedPower(linear.y, 1.0f / gamma),
        signedPower(linear.z, 1.0f / gamma)
    );
}

inline float3 decodeOutputTransfer(float3 encoded, bool displayReferred, float gamma) {
    if (displayReferred) {
        return float3(
            signedPower(encoded.x, gamma),
            signedPower(encoded.y, gamma),
            signedPower(encoded.z, gamma)
        );
    }
    return float3(
        decodeRec709(encoded.x),
        decodeRec709(encoded.y),
        decodeRec709(encoded.z)
    );
}

inline float3 encodeOutputTransfer(float3 linear, bool displayReferred, float gamma) {
    if (displayReferred) {
        return encodeDisplayGamma24(linear, gamma);
    }
    return float3(
        encodeRec709(linear.x),
        encodeRec709(linear.y),
        encodeRec709(linear.z)
    );
}

inline float3 readLUTTexel(
    texture3d<float, access::read> lutTexture,
    uint3 coordinate
) {
    return lutTexture.read(coordinate).rgb;
}

inline float3 sampleCreativeLUT(
    texture3d<float, access::read> lutTexture,
    float3 coordinate,
    uint dimension
) {
    // Do trilinear interpolation explicitly. This avoids relying on the
    // target Intel GPU's hardware-filter capability for rgba32Float 3D
    // textures while keeping every sampled value in float.
    uint maxIndex = dimension - 1u;
    float3 position = coordinate * float(maxIndex);
    uint3 low = uint3(position);
    uint3 high = min(low + uint3(1u), uint3(maxIndex));
    float3 fraction = position - float3(low);

    float3 c000 = readLUTTexel(lutTexture, uint3(low.x, low.y, low.z));
    float3 c100 = readLUTTexel(lutTexture, uint3(high.x, low.y, low.z));
    float3 c010 = readLUTTexel(lutTexture, uint3(low.x, high.y, low.z));
    float3 c110 = readLUTTexel(lutTexture, uint3(high.x, high.y, low.z));
    float3 c001 = readLUTTexel(lutTexture, uint3(low.x, low.y, high.z));
    float3 c101 = readLUTTexel(lutTexture, uint3(high.x, low.y, high.z));
    float3 c011 = readLUTTexel(lutTexture, uint3(low.x, high.y, high.z));
    float3 c111 = readLUTTexel(lutTexture, uint3(high.x, high.y, high.z));

    float3 c00 = mix(c000, c100, fraction.x);
    float3 c10 = mix(c010, c110, fraction.x);
    float3 c01 = mix(c001, c101, fraction.x);
    float3 c11 = mix(c011, c111, fraction.x);
    float3 c0 = mix(c00, c10, fraction.y);
    float3 c1 = mix(c01, c11, fraction.y);
    return mix(c0, c1, fraction.z);
}

inline float3 applyCreativeLUT(
    float3 encoded709,
    texture3d<float, access::read> lutTexture,
    constant CSTUniforms &u
) {
    const float amount = clamp(u.lutParameters.x, 0.0f, 1.0f);
    const bool enabled = u.lutParameters.w > 0.5f;
    const bool valid = u.lutParameters.z > 0.5f && u.lutParameters.y >= 2.0f;
    if (!enabled || !valid || amount <= 0.0f) {
        // The amount-zero branch is deliberate: it preserves the pre-LUT
        // result without even sampling the texture, making a zero amount a
        // true clean bypass of this stage.
        return encoded709;
    }

    // A .cube LUT is defined over normalized display-referred coordinates.
    // This is the sole clamp before final output: it protects the texture
    // address, while the original out-of-range encoded709 value is retained
    // for the blend below.
    float3 coordinate = clamp(encoded709, 0.0f, 1.0f);
    uint dimension = uint(u.lutParameters.y + 0.5f);
    float3 mapped = sampleCreativeLUT(lutTexture, coordinate, dimension);
    return encoded709 + (mapped - encoded709) * amount;
}

kernel void cstGradeKernel(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    texture3d<float, access::read> lutTexture [[texture(2)]],
    constant CSTUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }

    int2 absolutePixel = int2(gid) + int2(u.destinationOriginX, u.destinationOriginY);
    int2 sourcePixel = absolutePixel - int2(u.sourceOriginX, u.sourceOriginY);
    if (sourcePixel.x < 0 || sourcePixel.y < 0 ||
        sourcePixel.x >= int(source.get_width()) || sourcePixel.y >= int(source.get_height())) {
        destination.write(float4(0.0f), gid);
        return;
    }

    float4 input = source.read(uint2(sourcePixel));
    float3 rgb = input.rgb;

    if (stageIsEnabled(u.stageFlags, kStageGlobalBypass)) {
        destination.write(input, gid);
        return;
    }

    if (stageIsEnabled(u.stageFlags, kStageInputDecode)) {
        rgb = decodeInput(rgb, u.inputTransfer);
    }

    if (stageIsEnabled(u.stageFlags, kStageGamut)) {
        rgb = multiplyRows(
            u.sourceToWorkingRow0,
            u.sourceToWorkingRow1,
            u.sourceToWorkingRow2,
            rgb
        );
    }

    if (stageIsEnabled(u.stageFlags, kStageGrade)) {
        rgb = applyGrade(rgb, u);
    }

    if (stageIsEnabled(u.stageFlags, kStageToneMap)) {
        rgb = applyToneMap(rgb, u.toneMap, u.highlightKnee);
    }

    if (stageIsEnabled(u.stageFlags, kStageOutputEncode)) {
        // User-visible output stage: fixed linear Rec.2020 working space to
        // linear Rec.709, then Rec.709 or display gamma encoding.
        rgb = multiplyRows(
            u.workingToRec709Row0,
            u.workingToRec709Row1,
            u.workingToRec709Row2,
            rgb
        );
        bool useDisplayGamma = stageIsEnabled(u.stageFlags, kStageDisplayReferred);
        rgb = encodeOutputTransfer(rgb, useDisplayGamma, u.outputGamma);
        rgb = applyCreativeLUT(rgb, lutTexture, u);

        // FxPlug's output is interpreted by FCP in the project's working
        // gamut. In a wide-gamut project, convert the encoded Rec.709 result
        // back to linear, transform its primaries to Rec.2020, and encode the
        // host's gamma-video boundary. This keeps the effect's output stage a
        // true Rec.709 display transform while respecting the host contract.
        if ((u.projectIsRec2020 & 0x1u) != 0u) {
            float3 projectLinear = decodeOutputTransfer(rgb, useDisplayGamma, u.outputGamma);
            projectLinear = multiplyRows(
                u.rec709ToProjectRow0,
                u.rec709ToProjectRow1,
                u.rec709ToProjectRow2,
                projectLinear
            );
            rgb = float3(
                encodeRec709(projectLinear.x),
                encodeRec709(projectLinear.y),
                encodeRec709(projectLinear.z)
            );
        }

        // This is the only clamp in the entire shader. It is deliberately
        // after the final host-boundary encoding.
        rgb = clamp(rgb, 0.0f, 1.0f);
    }

    destination.write(float4(rgb, input.a), gid);
}
