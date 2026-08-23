#!/usr/bin/env python3
"""Dependency-free structural and reference-math checks for CST Grade.

This intentionally does not pretend to compile Swift, Metal, or FxPlug on
Linux. The canonical compilation gate is the self-hosted Monterey workflow.
"""

from __future__ import annotations

import math
import plistlib
import re
import sys
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FAILURES: list[str] = []
CHECKS = 0


def check(condition: bool, message: str) -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        FAILURES.append(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def parse_plist(relative: str) -> dict:
    try:
        with (ROOT / relative).open("rb") as handle:
            value = plistlib.load(handle)
    except Exception as error:  # pragma: no cover - diagnostic path
        FAILURES.append(f"{relative} is not a valid plist: {error}")
        return {}
    check(isinstance(value, dict), f"{relative} root must be a dictionary")
    return value


def inverse3(matrix: list[list[float]]) -> list[list[float]]:
    a, b, c = matrix[0]
    d, e, f = matrix[1]
    g, h, i = matrix[2]
    cofactors = [
        [e * i - f * h, -(d * i - f * g), d * h - e * g],
        [-(b * i - c * h), a * i - c * g, -(a * h - b * g)],
        [b * f - c * e, -(a * f - c * d), a * e - b * d],
    ]
    determinant = a * cofactors[0][0] + b * cofactors[0][1] + c * cofactors[0][2]
    if abs(determinant) <= 1.0e-12:
        raise ValueError("singular matrix")
    return [[cofactors[column][row] / determinant for column in range(3)] for row in range(3)]


def multiply3(left: list[list[float]], right: list[list[float]]) -> list[list[float]]:
    return [
        [sum(left[row][k] * right[k][column] for k in range(3)) for column in range(3)]
        for row in range(3)
    ]


def matrix_vector(matrix: list[list[float]], vector: list[float]) -> list[float]:
    return [sum(matrix[row][column] * vector[column] for column in range(3)) for row in range(3)]


def rgb_to_xyz(primaries: tuple[tuple[float, float], ...]) -> list[list[float]]:
    red, green, blue, white = primaries
    columns = []
    for x, y in (red, green, blue):
        columns.append([x / y, 1.0, (1.0 - x - y) / y])
    unscaled = [[columns[column][row] for column in range(3)] for row in range(3)]
    wx, wy = white
    white_xyz = [wx / wy, 1.0, (1.0 - wx - wy) / wy]
    scales = matrix_vector(inverse3(unscaled), white_xyz)
    return [[unscaled[row][column] * scales[column] for column in range(3)] for row in range(3)]


def check_reference_math() -> None:
    slog3 = (10 ** (((420 / 1023) * 1023 - 420) / 261.5)) * 0.19 - 0.01
    vlog_code = 433 / 1023
    vlog = (10 ** ((vlog_code - 0.598206) / 0.241514)) - 0.00873
    logc_code = 400 / 1023
    logc = ((10 ** ((logc_code - 0.385537) / 0.247190)) - 0.052272) / 5.555556
    rec709 = ((0.5 + 0.099) / 1.099) ** (1 / 0.45)

    samsung_transition = 0.206561909
    samsung_low_join = -(10 ** ((samsung_transition - (-0.24597)) / -0.20942)) + 0.016904
    samsung_high_join = (
        10 ** ((samsung_transition - 0.720504856) / 0.258984868)
    ) - 0.0003645
    samsung_gray_code = (
        0.258984868 * math.log10(0.18 + 0.0003645) + 0.720504856
    )
    samsung_gray = (
        10 ** ((samsung_gray_code - 0.720504856) / 0.258984868)
    ) - 0.0003645
    check(abs(slog3 - 0.18) < 1e-12, "sLog3 18-percent reference value drifted")
    check(abs(vlog - 0.179916274162) < 1e-9, "V-Log reference value drifted")
    check(abs(logc - 0.180000018677) < 1e-9, "LogC3 EI 800 reference value drifted")
    check(abs(rec709 - 0.259589400506) < 1e-9, "Rec.709 inverse reference value drifted")
    check(abs(samsung_high_join - 0.01) < 1e-9, "Samsung Log transition value drifted")
    check(abs(samsung_low_join - samsung_high_join) < 3e-7, "Samsung Log branches are discontinuous")
    check(abs(samsung_gray_code - 0.527859237029) < 1e-12, "Samsung Log 18-percent code value drifted")
    check(abs(samsung_gray - 0.18) < 1e-12, "Samsung Log 18-percent round trip drifted")

    luma_weights = [0.2627, 0.6780, 0.0593]
    basis1_raw = [luma_weights[1], -luma_weights[0], 0.0]
    basis1_length = math.sqrt(sum(value * value for value in basis1_raw))
    basis1 = [value / basis1_length for value in basis1_raw]
    basis2_raw = [
        luma_weights[1] * basis1[2] - luma_weights[2] * basis1[1],
        luma_weights[2] * basis1[0] - luma_weights[0] * basis1[2],
        luma_weights[0] * basis1[1] - luma_weights[1] * basis1[0],
    ]
    basis2_length = math.sqrt(sum(value * value for value in basis2_raw))
    basis2 = [value / basis2_length for value in basis2_raw]

    source_rgb = [0.8, 0.2, 0.1]
    source_luma = sum(channel * weight for channel, weight in zip(source_rgb, luma_weights))
    source_chroma = [channel - source_luma for channel in source_rgb]
    coordinate1 = sum(channel * basis for channel, basis in zip(source_chroma, basis1))
    coordinate2 = sum(channel * basis for channel, basis in zip(source_chroma, basis2))
    angle = math.radians(137.0)
    rotated_rgb = [
        source_luma
        + basis1[index] * (coordinate1 * math.cos(angle) - coordinate2 * math.sin(angle))
        + basis2[index] * (coordinate1 * math.sin(angle) + coordinate2 * math.cos(angle))
        for index in range(3)
    ]
    rotated_luma = sum(channel * weight for channel, weight in zip(rotated_rgb, luma_weights))
    check(abs(rotated_luma - source_luma) < 1e-12, "hue rotation does not preserve Rec.2020 luma")
    neutral_rgb = [0.35, 0.35, 0.35]
    neutral_luma = sum(channel * weight for channel, weight in zip(neutral_rgb, luma_weights))
    check(abs(neutral_luma - 0.35) < 1e-12, "Rec.2020 luma weights do not preserve neutral gray")

    d65 = (0.3127, 0.3290)
    spaces = {
        "Rec.709": ((0.640, 0.330), (0.300, 0.600), (0.150, 0.060), d65),
        "Rec.2020": ((0.708, 0.292), (0.170, 0.797), (0.131, 0.046), d65),
        "S-Gamut3.cine": ((0.766, 0.275), (0.225, 0.800), (0.089, -0.087), d65),
        "V-Gamut": ((0.730, 0.280), (0.165, 0.840), (0.100, -0.030), d65),
        "ARRI Wide Gamut": ((0.6840, 0.3130), (0.2210, 0.8480), (0.0861, -0.1020), d65),
    }
    xyz_to_2020 = inverse3(rgb_to_xyz(spaces["Rec.2020"]))
    for name, values in spaces.items():
        transform = multiply3(xyz_to_2020, rgb_to_xyz(values))
        neutral = matrix_vector(transform, [1.0, 1.0, 1.0])
        check(max(abs(channel - 1.0) for channel in neutral) < 1e-9, f"{name} matrix does not preserve D65 neutral")
        if name == "Rec.2020":
            identity_error = max(
                abs(transform[row][column] - (1.0 if row == column else 0.0))
                for row in range(3)
                for column in range(3)
            )
            check(identity_error < 1e-9, "Rec.2020-to-working transform is not identity")


def main() -> int:
    project = read("CSTGrade.xcodeproj/project.pbxproj")
    ids_source = read("CSTGradeXPC/CSTParameterIDs.swift")
    plugin_source = read("CSTGradeXPC/CSTGradePlugIn.swift")
    uniforms_source = read("CSTGradeXPC/CSTUniforms.swift")
    shader = read("CSTGradeXPC/CSTShaders.metal")
    lut_source = read("CSTGradeXPC/CSTLUTLibrary.swift")
    self_hosted_workflow = read(".github/workflows/build-self-hosted.yml")
    readme = read("README.md")
    testing = read("TESTING.md")

    wrapper_plist = parse_plist("CSTGrade/Info.plist")
    xpc_plist = parse_plist("CSTGradeXPC/Info.plist")
    check(wrapper_plist.get("CFBundlePackageType") == "APPL", "wrapper plist package type must be APPL")
    url_types = wrapper_plist.get("CFBundleURLTypes", [])
    schemes = [scheme for item in url_types for scheme in item.get("CFBundleURLSchemes", [])]
    check("cstgrade" in schemes, "wrapper plist must register the cstgrade URL scheme")
    check(xpc_plist.get("PlugInKit", {}).get("PrincipalClass") == "FxPrincipal", "XPC PrincipalClass must be FxPrincipal")
    plugins = xpc_plist.get("ProPlugPlugInList", [])
    check(len(plugins) == 1, "XPC plist must register exactly one FxPlug")
    if plugins:
        check(plugins[0].get("className") == "CSTGradePlugIn", "registered class must be CSTGradePlugIn")
        try:
            uuid.UUID(plugins[0].get("plugInUUID", ""))
        except ValueError:
            check(False, "plugInUUID must be a valid UUID")

    required_build_settings = [
        'ADDITIONAL_SDKS = "/Library/Developer/SDKs/FxPlug.sdk";',
        "ARCHS = x86_64;",
        "EXCLUDED_ARCHS[sdk=macosx*] = arm64;",
        '"/Library/Frameworks",',
        "MACOSX_DEPLOYMENT_TARGET = 11.0;",
        "ONLY_ACTIVE_ARCH = NO;",
        "WRAPPER_EXTENSION = fxplug;",
        "WRAPPER_EXTENSION = pluginkit;",
    ]
    for setting in required_build_settings:
        check(setting in project, f"project is missing required build setting: {setting}")
    check("ARCHS_STANDARD" not in project, "project must not use ARCHS_STANDARD")
    check(project.count("kernel void") == 0, "Metal kernels do not belong in the project file")
    check("workflow_dispatch:" in self_hosted_workflow, "self-hosted build must remain manually dispatched")
    check("pull_request:" not in self_hosted_workflow, "public pull requests must never reach the self-hosted runner")
    check(
        "if: github.actor == github.repository_owner" in self_hosted_workflow,
        "self-hosted public-repository build must remain restricted to the repository owner",
    )

    source_files = sorted(
        list((ROOT / "CSTGrade").glob("*.swift"))
        + list((ROOT / "CSTGradeXPC").glob("*.swift"))
        + list((ROOT / "CSTGradeXPC").glob("*.metal"))
    )
    for source_file in source_files:
        check(source_file.name in project, f"Xcode project does not reference {source_file.name}")

    id_block = re.search(r"enum CSTParameterID\s*\{(.*?)\n\}", ids_source, re.DOTALL)
    check(id_block is not None, "CSTParameterID enum is missing")
    parameter_ids = re.findall(r"static let\s+(\w+): UInt32 = (\d+)", id_block.group(1) if id_block else "")
    values = [int(value) for _, value in parameter_ids]
    check(len(parameter_ids) == 36, "expected 36 stable control/group parameter IDs")
    check(len(values) == len(set(values)), "parameter IDs must be unique")
    check(values == list(range(1, 37)), "parameter IDs must remain the ordered 1...36 contract")

    expected_popups = {
        "CSTInputTransfer": [0, 1, 2, 3, 4, 5],
        "CSTSourcePrimaries": [0, 1, 2, 3, 4],
        "CSTToneMap": [0, 1, 2],
    }
    for enum_name, expected_values in expected_popups.items():
        block = re.search(rf"enum {enum_name}: UInt32\s*\{{(.*?)\n\}}", ids_source, re.DOTALL)
        actual = [int(value) for value in re.findall(r"case\s+\w+\s*=\s*(\d+)", block.group(1) if block else "")]
        check(actual == expected_values, f"{enum_name} persisted popup values changed")

    transfer_block = re.search(
        r"let transferEntries: \[NSString\] = \[(.*?)\n\s*\]",
        plugin_source,
        re.DOTALL,
    )
    transfer_labels = re.findall(r'"([^"]+)"', transfer_block.group(1) if transfer_block else "")
    check(
        transfer_labels == [
            "Rec.709",
            "sLog3",
            "V-Log",
            "ARRI LogC3 (EI 800)",
            "Gamma 2.2",
            "Samsung Log",
        ],
        "Input Transfer labels no longer match their persisted popup values",
    )

    swift_block = re.search(r"struct CSTUniforms\s*\{(.*?)\n\}", uniforms_source, re.DOTALL)
    metal_block = re.search(r"struct CSTUniforms\s*\{(.*?)\n\};", shader, re.DOTALL)
    check(swift_block is not None and metal_block is not None, "Swift and Metal uniform structs must both exist")
    swift_fields: list[tuple[str, str]] = []
    if swift_block:
        for name, explicit_type, expression in re.findall(
            r"^\s*var\s+(\w+)(?:\s*:\s*([^=]+?))?\s*=\s*(.+)$",
            swift_block.group(1),
            re.MULTILINE,
        ):
            swift_type = explicit_type.strip() if explicit_type else expression.strip().split("(", 1)[0]
            normalized = {
                "SIMD4<Float>": "float4",
                "SIMD4<UInt32>": "uint4",
                "Float": "float",
                "UInt32": "uint",
                "Int32": "int",
            }.get(swift_type, swift_type)
            swift_fields.append((normalized, name))
    metal_fields = re.findall(r"^\s*(float4|uint4|float|uint|int)\s+(\w+);", metal_block.group(1) if metal_block else "", re.MULTILINE)
    check(swift_fields == metal_fields, f"Swift/Metal uniform layouts differ: {swift_fields!r} != {metal_fields!r}")
    check(len(swift_fields) == 35, "CSTUniforms must retain its 35-field, 320-byte layout")

    check(len(re.findall(r"\bkernel\s+void\s+", shader)) == 1, "shader must contain exactly one Metal kernel")
    check("kernel void cstGradeKernel" in shader, "single kernel must be named cstGradeKernel")
    kernel = shader[shader.find("kernel void cstGradeKernel") :]
    pipeline_markers = [
        "decodeInput(rgb",
        "u.sourceToWorkingRow0",
        "applyGrade(rgb",
        "applyToneMap(rgb",
        "u.workingToRec709Row0",
        "encodeOutputTransfer(rgb",
        "applyCreativeLUT(rgb",
        "rgb = clamp(rgb, 0.0f, 1.0f)",
    ]
    positions = [kernel.find(marker) for marker in pipeline_markers]
    check(all(position >= 0 for position in positions), "shader is missing a fixed-pipeline stage")
    check(positions == sorted(positions), "shader pipeline stages are out of order")
    check("encodeRec709(projectLinear)" not in shader, "encodeRec709 has no float3 overload")
    check("destination.write(float4(rgb, input.a), gid)" in kernel, "shader must preserve source alpha")
    for marker in [
        "inline float decodeSamsungLog",
        "case 5u: return float3(decodeSamsungLog",
        "applyShadowsHighlights(rgb",
        "applyColorBoost(rgb",
        "applyHueRotation(rgb",
        "u.offsetControl.xyz",
    ]:
        check(marker in shader, f"shader is missing primary-grade behavior: {marker}")

    for marker in ["LUT_3D_SIZE", "2...64", ".withSecurityScope", "content changed since it was selected"]:
        check(marker in lut_source, f"LUT implementation is missing required behavior: {marker}")
    cache_lookup = lut_source.find("CSTLUTParsedCache.shared.value(for: identifier)")
    content_check = lut_source.find("identifier == selection.identifier")
    check(content_check >= 0 and cache_lookup > content_check, "LUT bytes must be validated before parsed-cache reuse")

    scheme_path = ROOT / "CSTGrade.xcodeproj/xcshareddata/xcschemes/CSTGrade.xcscheme"
    try:
        scheme = ET.parse(scheme_path)
        references = scheme.findall(".//BuildableReference")
        check(any(item.get("BlueprintName") == "CSTGrade" for item in references), "shared scheme must build CSTGrade")
    except Exception as error:
        check(False, f"shared Xcode scheme is invalid XML: {error}")

    for marker in [
        "FCP Plasma Grader",
        "macOS deployment target: 11.0",
        "x86_64",
        "Final Cut Pro 10.6.10",
        "LUT Library",
        "Samsung Log",
        "DaVinci Resolve primary-tool coverage",
        "What I am unsure about",
    ]:
        check(marker in readme, f"README is missing required documentation: {marker}")
    for marker in [
        "Numerical transfer-function reference check",
        "Samsung Log",
        "Color Boost",
        "Stage A/B bypasses",
        "Rec.709 versus wide-gamut library",
        "Creative LUT",
    ]:
        check(marker in testing, f"TESTING.md is missing a required acceptance section: {marker}")

    check_reference_math()

    if FAILURES:
        print("FCP Plasma Grader structural verification: FAIL", file=sys.stderr)
        for failure in FAILURES:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"FCP Plasma Grader structural verification: PASS ({CHECKS} checks)")
    print("Note: this is not a Swift/Metal/FxPlug compilation or an FCP runtime test.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
