#!/usr/bin/env python3
"""Prepare newer FxPlug link stubs for a legacy deployment-only build.

FxPlug SDK 4.3.4 ships runtime frameworks and text-based link stubs with a
macOS 13 floor. FCP Plasma Grader never distributes those runtime binaries for
the Monterey build. The end-user installer instead copies the matching runtime
frameworks from the user's signed Final Cut Pro 10.6.5 application.

This helper changes only the ephemeral runner's text-based .tbd link stubs so
Xcode can emit an x86_64 executable with a macOS 11 deployment target. It does not patch, copy, or weaken the SDK's signed runtime framework binaries.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


FRAMEWORK_STUBS = (
    ("FxPlug.framework", "Versions/A/FxPlug.tbd"),
    ("PluginManager.framework", "Versions/B/PluginManager.tbd"),
)


def patch_stub(path: Path, target_minimum: str) -> None:
    document = json.loads(path.read_text(encoding="utf-8"))
    library = document.get("main_library")
    if not isinstance(library, dict):
        raise ValueError(f"{path}: missing main_library")

    target_info = library.get("target_info")
    if not isinstance(target_info, list) or not target_info:
        raise ValueError(f"{path}: missing target_info")

    targets = {entry.get("target") for entry in target_info if isinstance(entry, dict)}
    expected_targets = {"x86_64-macos", "arm64-macos"}
    if targets != expected_targets:
        raise ValueError(f"{path}: unexpected targets {sorted(str(item) for item in targets)}")

    original_minimums = {
        entry.get("min_deployment") for entry in target_info if isinstance(entry, dict)
    }
    if original_minimums != {"13.0"}:
        raise ValueError(
            f"{path}: expected untouched FxPlug 4.3.4 macOS 13 stubs, got "
            f"{sorted(str(item) for item in original_minimums)}"
        )

    for entry in target_info:
        entry["min_deployment"] = target_minimum

    path.write_text(
        json.dumps(document, ensure_ascii=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )

    verified = json.loads(path.read_text(encoding="utf-8"))
    verified_minimums = {
        entry.get("min_deployment")
        for entry in verified["main_library"]["target_info"]
    }
    if verified_minimums != {target_minimum}:
        raise ValueError(f"{path}: failed to set deployment floor")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sdk",
        type=Path,
        default=Path("/Library/Developer/SDKs/FxPlug.sdk"),
    )
    parser.add_argument("--target-minimum", default="11.0")
    arguments = parser.parse_args()

    framework_root = arguments.sdk / "Library/Frameworks"
    for framework, relative_stub in FRAMEWORK_STUBS:
        stub = framework_root / framework / relative_stub
        if not stub.is_file():
            raise FileNotFoundError(stub)
        patch_stub(stub, arguments.target_minimum)
        print(f"Prepared {stub} for macOS {arguments.target_minimum} linking")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
